#!/usr/bin/env bash
# 隔离验证 sing-box 的哈希逻辑与"查最新版"逻辑: mock curl, 不联网。
#
# 为什么单独一套: sing-box 既没有 hashes.txt 也没有 .dgst, 唯一的官方哈希来源是
# GitHub Release API 里每个资产的 digest 字段 —— 也就是说这里必须**解析 JSON**,
# 而脚本不许依赖 jq / python。用 awk 切字符串解析 JSON 是最容易出错的一环,
# 错了还不会报错, 只会静默退回内置值: 表面上"装上了", 实际上动态校验从未生效。
# 第一版就踩过: 只删换行不删缩进空格, 按 `},{` 一刀都切不开, 全是空值。
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
  sed -n '/^sb_api_sha()/,/^}/p' "$SRC"
  sed -n '/^sb_expected_sha()/,/^}/p' "$SRC"
  sed -n '/^sb_latest_version()/,/^}/p' "$SRC"
  sed -n '/^file_sha256()/,/^}/p' "$SRC"
} > "$TD/fns.sh"

# 抽出空文件 = 断言全假绿, 先自己卡一道(函数名里有数字, 字符集必须带上 0-9)
_nf=$(grep -c '^[A-Za-z_][A-Za-z_0-9]*(){' "$TD/fns.sh")
if [ "$_nf" -lt 5 ]; then
  echo "FAIL 函数抽取不完整(只抽到 ${_nf} 个, 应为 5)"
  exit 1
fi

# mock curl: 按 URL 关键字决定往 -o 目标写什么。
# 关键点: 这里给的是**缩进过的多行 JSON**, 和 GitHub 真实响应一样 ——
# 拿压成一行的 JSON 来测, 会把"忘了去缩进空格"这个 bug 完美掩盖掉。
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
# 两种调用形态都要支持: sb_api_sha 用 `-o 文件`, sb_latest_version 直接读 stdout。
# 只实现 -o 那种, 后者的"空结果"会被误判成解析失败, 白白排查半天。
write(){ if [ -n "$out" ]; then printf '%s\n' "$1" > "$out"; else printf '%s\n' "$1"; fi; }
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

# 真实响应结构: 外层 assets 数组, 每个元素是对象, 里面还有嵌套的 uploader 对象。
# 故意把 -glibc 变体排在纯 arm64 **前面**: 只做子串匹配的实现会先命中 glibc,
# 而 glibc 的 digest 是 C —— 于是"装错包还能校验通过", 比装不上严重得多。
JSON_GOOD=$(cat <<JSON
{
  "tag_name": "v1.14.4",
  "assets": [
    {
      "url": "https://api.github.com/x",
      "name": "sing-box-1.14.4-linux-arm64-glibc.tar.gz",
      "uploader": { "login": "SagerNet", "id": 1 },
      "size": 29724217,
      "digest": "sha256:${C}",
      "browser_download_url": "https://github.com/x"
    },
    {
      "url": "https://api.github.com/y",
      "name": "sing-box-1.14.4-linux-arm64.tar.gz",
      "uploader": { "login": "SagerNet", "id": 1 },
      "size": 29140599,
      "digest": "sha256:${B}",
      "browser_download_url": "https://github.com/y"
    },
    {
      "url": "https://api.github.com/z",
      "name": "sing-box-1.14.4-linux-amd64.tar.gz",
      "uploader": { "login": "SagerNet", "id": 1 },
      "size": 31710753,
      "digest": "sha256:${A}",
      "browser_download_url": "https://github.com/z"
    }
  ]
}
JSON
)
# 资产在, 但没有 digest 字段(万一上游改了元数据格式)
JSON_NODIGEST=$(cat <<JSON
{
  "assets": [
    { "name": "sing-box-1.14.4-linux-amd64.tar.gz", "size": 1 }
  ]
}
JSON
)
# digest 是别的算法(sha1:), 不能当 sha256 用
JSON_SHA1=$(cat <<JSON
{
  "assets": [
    { "name": "sing-box-1.14.4-linux-amd64.tar.gz", "digest": "sha1:${A}" }
  ]
}
JSON
)

case "$url" in
  *api.github.com*releases/latest*)
     write '{
  "tag_name": "v1.14.4",
  "name": "1.14.4"
}' ;;
  *releases/tags/*NODIGEST*) write "$JSON_NODIGEST" ;;
  *releases/tags/*SHA1*)     write "$JSON_SHA1" ;;
  *releases/tags/*GARBAGE*)  write 'this is not json at all' ;;
  *releases/tags/*GOOD*)     write "$JSON_GOOD" ;;
  *) exit 7 ;;   # 模拟网络不可达
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
C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

# 1) Release API 的 digest 解析
t "缩进 JSON 里取到 amd64" "$(sb_api_sha GOOD sing-box-1.14.4-linux-amd64.tar.gz)" "$A"
t "同一份响应取到 arm64" "$(sb_api_sha GOOD sing-box-1.14.4-linux-arm64.tar.gz)" "$B"
# 这一条专门卡"前缀串号": 纯 arm64 的 digest 是 B, glibc 变体是 C
t "arm64 不会误取 glibc 变体" "$(sb_api_sha GOOD sing-box-1.14.4-linux-arm64.tar.gz)" "$B"
t "资产不存在返回空" "$(sb_api_sha GOOD sing-box-1.14.4-linux-riscv64.tar.gz)" ""
t "没有 digest 字段返回空" "$(sb_api_sha NODIGEST sing-box-1.14.4-linux-amd64.tar.gz)" ""
t "sha1 摘要不当 sha256 用" "$(sb_api_sha SHA1 sing-box-1.14.4-linux-amd64.tar.gz)" ""
t "非 JSON 响应返回空" "$(sb_api_sha GARBAGE sing-box-1.14.4-linux-amd64.tar.gz)" ""
t "网络不可达返回空" "$(sb_api_sha OFFLINE sing-box-1.14.4-linux-amd64.tar.gz)" ""

# 2) sb_expected_sha: API 可达且无内置值 -> 直接用官方 digest
pinned_sha(){ echo ""; }
o=$(sb_expected_sha GOOD amd64 sing-box-1.14.4-linux-amd64.tar.gz 2>/dev/null)
t "API 可达返回校验值" "$o" "$A"
t "API 可达输出长度恰为64" "${#o}" "64"
# 只比内容不够: 提示文字拼进去后可能仍包含正确哈希。必须卡死行数。
t "API 可达输出只有一行" "$(printf '%s' "$o" | wc -l | tr -d ' ')" "0"

# 3) API 可达但和内置值冲突 -> 拒绝(返回非0 且输出为空)
pinned_sha(){ case "$1" in singbox-amd64-GOOD) echo "$B" ;; *) echo "" ;; esac; }
o=$(sb_expected_sha GOOD amd64 sing-box-1.14.4-linux-amd64.tar.gz 2>/dev/null); rc=$?
t "官方与内置冲突时拒绝(空输出)" "$o" ""
t "官方与内置冲突时非0退出" "$rc" "1"

# 4) API 与内置一致 -> 正常放行, 不因"有内置值"就跳过比对
pinned_sha(){ case "$1" in singbox-amd64-GOOD) echo "$A" ;; *) echo "" ;; esac; }
o=$(sb_expected_sha GOOD amd64 sing-box-1.14.4-linux-amd64.tar.gz 2>/dev/null); rc=$?
t "官方与内置一致时放行" "$o" "$A"
t "官方与内置一致时返回0" "$rc" "0"

# 5) API 不可达 + 有内置值 -> 内置兜底, 输出干净
pinned_sha(){ case "$1" in singbox-amd64-OFFLINE) echo "$B" ;; *) echo "" ;; esac; }
o=$(sb_expected_sha OFFLINE amd64 sing-box-1.14.4-linux-amd64.tar.gz 2>/dev/null)
t "API 不可达时用内置值" "$o" "$B"
t "内置兜底输出长度恰为64" "${#o}" "64"

# 6) API 不可达 + 没有内置值 -> 返回空, 由 verify_sha256 按策略拒绝(绝不裸奔)
pinned_sha(){ echo ""; }
o=$(sb_expected_sha OFFLINE amd64 sing-box-1.14.4-linux-amd64.tar.gz 2>/dev/null)
t "全不可达且无内置值返回空" "$o" ""

# 7) sb_latest_version: 从 /releases/latest 的 tag_name 抠版本号
t "解析 tag_name 得到版本号" "$(sb_latest_version)" "1.14.4"
# 上面那条只覆盖"正常响应"。tag 格式一旦变成 v1.15.0-beta.1 之类, 必须返回空
# (由调用方沿用本机版本), 而不是把 -beta.1 当版本号拼进下载 URL。
# 注意: sb_latest_version 不接受参数(URL 是写死的), 所以只能靠环境变量让 mock
# 换响应 —— 往函数里传 "DIRTY" 是传不进去的, 那三条断言会全部假绿。
cat > "$TD/bin/curl" <<'MOCK2'
#!/usr/bin/env bash
case "${MOCKMODE:-good}" in
  dirty) printf '%s\n' '{ "tag_name": "v1.15.0-beta.1" }' ;;
  nov)   printf '%s\n' '{ "tag_name": "v1" }' ;;
  off)   exit 7 ;;
  *)     printf '%s\n' '{ "tag_name": "v1.14.4" }' ;;
esac
exit 0
MOCK2
chmod +x "$TD/bin/curl"
MOCKMODE=dirty; export MOCKMODE
t "预发布 tag 不当作可用版本" "$(sb_latest_version)" ""
MOCKMODE=nov
t "没有小数点的 tag 不当作版本" "$(sb_latest_version)" ""
MOCKMODE=off
t "API 不可达返回空" "$(sb_latest_version)" ""

echo "--- behavioral: PASS=$P FAIL=$F"
rm -rf "$TD"
[ "$F" -eq 0 ]
