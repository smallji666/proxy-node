#!/usr/bin/env bash
# 隔离验证修订号 10 的 Xray 哈希逻辑: mock curl, 不联网。
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

# 从 setup.sh 抽出三个纯函数(常量区无需执行)
{
  sed -n '/^pinned_sha()/,/^}/p' "$SRC"
  sed -n '/^xray_dgst_sha()/,/^}/p' "$SRC"
  sed -n '/^xray_expected_sha()/,/^}/p' "$SRC"
  sed -n '/^file_sha256()/,/^}/p' "$SRC"
} > "$TD/fns.sh"

# 抽取完整性自检: 函数名一改 / 文件截断, 下面就会拿到空桩, 断言可能反而假绿。
_nf=$(grep -c '^[a-z_][a-z_0-9]*(){' "$TD/fns.sh" 2>/dev/null || echo 0)
if [ "$_nf" -lt 4 ]; then
  echo "FAIL 函数抽取不完整(只抽到 $_nf 个)"
  exit 1
fi

# mock curl: 按 URL 里的关键字决定往 -o 目标写什么
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
case "$url" in
  *CONFLICT*) printf 'SHA256= bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$out" ;;
  # MIRRORONLY: 官方 github.com 前缀不可达, 只有 ghfast.top/gh-proxy.com 镜像能给值。
  # 官方 URL 是 https://github.com/XTLS/...; 镜像 URL 是
  # https://ghfast.top/https://github.com/XTLS/... —— 也含 github.com/。
  # 所以必须匹配完整前缀 https://github.com/, 不能写 github.com/* (一个都拦不到),
  # 也不能写 *github.com/* (把镜像也拦掉)。
  *MIRRORONLY*)
     case "$url" in
       https://github.com/*) exit 7 ;;
       *) printf 'SHA256= aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$out" ;;
     esac ;;
  *GOOD*)  printf 'SHA256= aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$out" ;;
  *BAD*)   printf 'SHA512= zzz\n' > "$out" ;;
  *)       exit 7 ;;   # 模拟网络不可达
esac
exit 0
MOCK
chmod +x "$TD/bin/curl"

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

export PATH="$TD/bin:$PATH"
export MOCK_MODE=official
source "$TD/fns.sh"

# 真实脚本里 ok/warn/err/info 全都往 stdout 打。这里必须照样定义 ——
# 不定义的话它们会以 "command not found" 落到 stderr, 反而把"返回值被日志
# 污染"这个 bug 掩盖掉: 修订号 10 的镜像兜底用例就是因为没定义而假绿, 直到
# 修订号 11 才发现 _want_sha 里混进了 "[OK] ..." 那行, 导致国内 VPS 装不上。
ok(){   echo -e "[OK] $*"; }
warn(){ echo -e "[!] $*"; }
err(){  echo -e "[X] $*"; }
info(){ echo -e "[*] $*"; }

# 1) 官方 dgst 解析: 只认 256= 行且必须是 64 位 hex
t "官方 dgst 正确解析" "$(xray_dgst_sha 'https://x/GOOD.dgst')" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
t "无 256= 行返回空" "$(xray_dgst_sha 'https://x/BAD.dgst')" ""
t "网络不可达返回空" "$(xray_dgst_sha 'https://x/OFFLINE.dgst')" ""

# 2) xray_expected_sha: 覆盖 pinned_sha 让它对 GOOD 内置同值
pinned_sha(){ case "$1" in xray-64-GOOD) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";; *) echo "";; esac; }

# 官方可达且一致 -> 返回官方值
o=$(xray_expected_sha GOOD 64 Xray-linux-64.zip 2>/dev/null)
t "官方可达返回校验值" "$o" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# 3) 官方不可达 + 两镜像一致 -> 镜像兜底拿到校验值
#    MIRRORONLY: mock 让 github.com 前缀失败, 两个镜像前缀返回同值
o=$(xray_expected_sha MIRRORONLY 64 Xray-linux-64.zip 2>"$TD/err")
t "镜像兜底仍拿到校验值" "$o" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# 只比内容不够: 提示文字拼进去后是"两行", 值本身可能仍然包含正确哈希。
# 必须卡死长度与行数, 否则这个 bug 还会溜过去。
t "镜像兜底输出长度恰为64" "${#o}" "64"
t "镜像兜底输出只有一行" "$(printf '%s' "$o" | wc -l | tr -d ' ')" "0"
# 卡死"分支真的走到": 否则 mock 一改回官方可达, 上面三条又变假绿。
t "镜像兜底分支确实执行" "$(grep -c '已用两个镜像交叉核对' "$TD/err" 2>/dev/null || true)" "1"

# 4) 官方与内置冲突 -> 拒绝(返回非0 且输出为空)
#    CONFLICT 版本官方 dgst 给出 bbbb, 内置给 aaaa -> 不一致必须拒绝
pinned_sha(){ case "$1" in xray-64-CONFLICT) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";; *) echo "";; esac; }
o=$(xray_expected_sha CONFLICT 64 Xray-linux-64.zip 2>/dev/null); rc=$?
t "官方与内置冲突时拒绝(空输出)" "$o" ""
t "官方与内置冲突时非0退出" "$rc" "1"

echo "--- behavioral: PASS=$P FAIL=$F"
rm -rf "$TD"
[ "$F" -eq 0 ]
