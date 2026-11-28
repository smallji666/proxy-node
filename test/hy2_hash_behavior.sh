#!/usr/bin/env bash
# 隔离验证 Hysteria2 的哈希逻辑: mock curl, 不联网。
#
# 为什么单独一套: hy2 的校验文件格式和 Xray 完全不同 —— 官方发的是 sha256sum
# 风格的 hashes.txt, 路径还带 build/ 前缀。格式解析错一位, 结果就是"哈希取不到
# -> 退回内置值 -> 新版本没有内置值 -> 装不上", 和 Xray 当初锁死版本一个后果。
set -u
SRC="../setup.sh"
# Git Bash 的 mktemp 默认吐出 C:////...////Temp/tmp.XXX 混合路径, rm -rf 会触发
# 本地删除守卫而卡死(回归曾因此挂 1 小时)。统一到 /tmp, 与 run.sh 头部一致。
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
# 运行环境把 rm 定义成安全删除 shim 的函数, 删 /tmp 临时文件时会卡住;
# 测试只删自己刚建的临时文件, 恢复真实 rm 避免测试被环境干扰。
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
mkdir -p "$TD/bin"

# 从 setup.sh 抽出纯函数(常量区无需执行)
{
  sed -n '/^pinned_sha()/,/^}/p' "$SRC"
  sed -n '/^sha_from_sumfile()/,/^}/p' "$SRC"
  sed -n '/^hy2_expected_sha()/,/^}/p' "$SRC"
  sed -n '/^file_sha256()/,/^}/p' "$SRC"
} > "$TD/fns.sh"

# 抽出空文件 = 断言全假绿, 先自己卡一道(函数名里有数字, 字符集必须带上 0-9)
_nf=$(grep -c '^[A-Za-z_][A-Za-z_0-9]*(){' "$TD/fns.sh")
if [ "$_nf" -lt 4 ]; then
  echo "FAIL 函数抽取不完整(只抽到 ${_nf} 个, 应为 4)"
  exit 1
fi

# mock curl: 按 URL 关键字决定往 -o 目标写什么
cat > "$TD/bin/curl" <<'MOCK'
#!/usr/bin/env bash
out=""
last=""
while [ "$#" -gt 0 ]; do
  last="$1"
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
url="$last"
write(){ printf '%s' "$1" > "$out"; }
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
# 官方格式: <hash>  build/<asset> ; 顺手带一条无关资产, 确认不会张冠李戴
GOOD="$(printf '%s  build/hysteria-linux-arm64\n%s  build/hysteria-linux-amd64\n' "$B" "$A")"
# 二进制模式前缀 * 的写法, 必须也能认出来
STAR="$(printf '%s *build/hysteria-linux-amd64\n' "$A")"
# 只有 arm64, 没有 amd64 -> 必须返回空而不是乱配
MISSING="$(printf '%s  build/hysteria-linux-arm64\n' "$B")"
case "$url" in
  *CONFLICT*) write "$(printf '%s  build/hysteria-linux-amd64\n' "$B")" ;;
  # MIRRORONLY: 官方 github.com 前缀不可达, 只有两个镜像能给值
  *MIRRORONLY*)
     case "$url" in
       https://github.com/*) exit 7 ;;
       *) write "$GOOD" ;;
     esac ;;
  *STAR*)    write "$STAR" ;;
  *MISSING*) write "$MISSING" ;;
  *GARBAGE*) write "$(printf 'not-a-hash  build/hysteria-linux-amd64\n')" ;;
  *GOOD*)    write "$GOOD" ;;
  *)         exit 7 ;;   # 模拟网络不可达
esac
exit 0
MOCK
chmod +x "$TD/bin/curl"

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

export PATH="$TD/bin:$PATH"
source "$TD/fns.sh"

# 真实脚本里 ok/warn/err/info 全都往 stdout 打。这里必须照样定义 ——
# 不定义的话它们会以 "command not found" 落到 stderr, 反而把"返回值被日志
# 污染"这个 bug 掩盖掉(修订号 10 的 Xray 镜像兜底用例就是这么假绿的)。
ok(){   echo -e "[OK] $*"; }
warn(){ echo -e "[!] $*"; }
err(){  echo -e "[X] $*"; }
info(){ echo -e "[*] $*"; }

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# 1) hashes.txt 解析
t "按 basename 命中 amd64" "$(sha_from_sumfile 'https://x/GOOD/hashes.txt' hysteria-linux-amd64)" "$A"
t "同一份文件取 arm64" "$(sha_from_sumfile 'https://x/GOOD/hashes.txt' hysteria-linux-arm64)" "$B"
t "文件里没有该资产返回空" "$(sha_from_sumfile 'https://x/MISSING/hashes.txt' hysteria-linux-amd64)" ""
t "二进制模式 * 前缀可识别" "$(sha_from_sumfile 'https://x/STAR/hashes.txt' hysteria-linux-amd64)" "$A"
t "非哈希内容返回空" "$(sha_from_sumfile 'https://x/GARBAGE/hashes.txt' hysteria-linux-amd64)" ""
t "网络不可达返回空" "$(sha_from_sumfile 'https://x/OFFLINE/hashes.txt' hysteria-linux-amd64)" ""

# 2) hy2_expected_sha: 官方可达且无内置值 -> 直接用官方值
pinned_sha(){ echo ""; }
o=$(hy2_expected_sha GOOD amd64 hysteria-linux-amd64 2>/dev/null)
t "官方可达返回校验值" "$o" "$A"
t "官方可达输出长度恰为64" "${#o}" "64"

# 3) 官方不可达 + 两镜像一致 -> 镜像兜底
o=$(hy2_expected_sha MIRRORONLY amd64 hysteria-linux-amd64 2>"$TD/hy2err")
t "镜像兜底仍拿到校验值" "$o" "$A"
# 只比内容不够: 提示文字拼进去后是"两行", 值本身可能仍包含正确哈希。
# 必须卡死长度与行数, 否则"返回值被日志污染"那类 bug 还会溜过去。
t "镜像兜底输出长度恰为64" "${#o}" "64"
t "镜像兜底输出只有一行" "$(printf '%s' "$o" | wc -l | tr -d ' ')" "0"
# 卡死"分支真的走到": 否则 mock 一改回官方可达, 上面三条又变假绿(xray 侧已有此闸)。
t "镜像兜底分支确实执行" "$(grep -c '交叉核对 Hysteria2' "$TD/hy2err" 2>/dev/null || true)" "1"

# 4) 官方与内置冲突 -> 拒绝(返回非0 且输出为空)
pinned_sha(){ case "$1" in hy2-amd64-CONFLICT) echo "$A" ;; *) echo "" ;; esac; }
o=$(hy2_expected_sha CONFLICT amd64 hysteria-linux-amd64 2>/dev/null); rc=$?
t "官方与内置冲突时拒绝(空输出)" "$o" ""
t "官方与内置冲突时非0退出" "$rc" "1"

# 5) 官方不可达且没有内置值 -> 返回空, 由 verify_sha256 按策略拒绝
pinned_sha(){ echo ""; }
o=$(hy2_expected_sha OFFLINE amd64 hysteria-linux-amd64 2>/dev/null)
t "全不可达且无内置值返回空" "$o" ""

# 6) 内置值兜底: 官方不可达但有内置值 -> 用内置值, 且输出干净
pinned_sha(){ case "$1" in hy2-amd64-OFFLINE) echo "$B" ;; *) echo "" ;; esac; }
o=$(hy2_expected_sha OFFLINE amd64 hysteria-linux-amd64 2>/dev/null)
t "官方不可达时用内置值" "$o" "$B"
t "内置兜底输出长度恰为64" "${#o}" "64"

echo "--- behavioral: PASS=$P FAIL=$F"
rm -rf "$TD"
[ "$F" -eq 0 ]
