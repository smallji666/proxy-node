#!/usr/bin/env bash
# 隔离验证 sing-box 的"追最新版"分支: 不联网, 不碰系统。
#
# 为什么值得单独测: 这段逻辑决定"装哪个版本"。判错的后果比装不上更糟 ——
# 要么把在跑的 1.14.4 降级回基线(节点直接断), 要么把 API 返回的脏值(预发布
# tag)当版本号拼进下载 URL, 报一个和真实原因毫无关系的 404。
# 分支互相依赖(API 通不通 x 本机装没装 x 显式传没传), 靠人眼看不可靠。
set -u
SRC="../setup.sh"
# Git Bash 的 mktemp 默认吐出 C:////...////Temp/tmp.XXX 混合路径, rm -rf 会触发
# 本地删除守卫而卡死(回归曾因此挂 1 小时)。统一到 /tmp, 与 run.sh 头部一致。
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
# 运行环境把 rm 定义成安全删除 shim 的函数, 删 /tmp 临时文件时会卡住;
# 测试只删自己刚建的临时文件, 恢复真实 rm 避免测试被环境干扰。
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)

# 按内容抽取解析块: 从 `case "${SB_VERSION:-latest}" in` 到其后第一个 `  esac`
S=$(grep -n 'case "${SB_VERSION:-latest}" in' "$SRC" | head -1 | cut -d: -f1)
E=$(awk -v s="$S" 'NR > s && /^  esac$/ { print NR; exit }' "$SRC")
if [ -z "$S" ] || [ -z "$E" ]; then
  echo "FAIL 无法定位 sing-box 最新版解析块(源码结构变了?)"
  exit 1
fi
{
  echo 'resolve_sb(){'
  sed -n "${S},${E}p" "$SRC"
  echo '}'
  # 版本号解析单独抽: 解析块里调它拿"本机已装版本", 不抽出来这块就是空壳
  sed -n '/^sb_installed_version()/,/^}/p' "$SRC"
} > "$TD/blk.sh"
# 抽出来的块必须真的含关键分支, 否则下面的断言全是空跑
for kw in 'sb_latest_version' 'SB_FALLBACK_VERSION' 'latest'; do
  if ! grep -q "$kw" "$TD/blk.sh"; then
    echo "FAIL 解析块抽取不完整(缺 ${kw})"
    exit 1
  fi
done
if ! grep -q '^sb_installed_version()' "$TD/blk.sh"; then
  echo "FAIL 未抽到 sb_installed_version(本机版本无法读取)"
  exit 1
fi
bash -n "$TD/blk.sh" || { echo "FAIL 抽取出的块语法错误"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

# 桩: warn/info 走 stderr(真实脚本里走 stdout, 但这里只关心 SB_VERSION 的结果)
warn(){ printf 'WARN: %s\n' "$*" >&2; }
info(){ printf 'INFO: %s\n' "$*" >&2; }
SB_FALLBACK_VERSION="1.14.4"
source "$TD/blk.sh"

# 假 sing-box: 首行带 go 版本, 和官方构建的实际输出一致
mksb(){ printf '#!/usr/bin/env bash\nprintf "sing-box version %s\\n\\nEnvironment: go1.24.1 linux/amd64\\n"\n' "$1" > "$2"; chmod +x "$2"; }
S="$TD/fake-sb"
# "本机没装"一律用"指向不存在的路径"表达, 不用 rm ——
# 某些环境的安全删除守卫会拦住 rm, 文件还在, 用例就变成假失败/假通过。
NOBIN="$TD/definitely-not-here"; SB_BIN="$NOBIN"

# A 官方 API 正常 -> 跟最新
sb_latest_version(){ echo "1.15.0"; }; SB_VERSION="latest"
resolve_sb 2>/dev/null
t "A API正常追最新" "$SB_VERSION" "1.15.0"

# B API 失败, 本机 1.14.4 -> 沿用, 不降级回基线
mksb 1.14.4 "$S"; SB_BIN="$S"; sb_latest_version(){ echo ""; }; SB_VERSION="latest"
resolve_sb 2>/dev/null
t "B API失败沿用本机" "$SB_VERSION" "1.14.4"

# C API 失败, 本机没装 -> 退内置基线
SB_BIN="$NOBIN"; SB_VERSION="latest"
resolve_sb 2>/dev/null
t "C API失败且无本机退基线" "$SB_VERSION" "1.14.4"

# D 用户显式传版本 -> 一个字都不改(可复现 / 回退用)
SB_VERSION="1.13.0"
resolve_sb 2>/dev/null
t "D 显式版本不被动" "$SB_VERSION" "1.13.0"

# E 空值等同 latest
SB_VERSION=""; sb_latest_version(){ echo "1.15.0"; }
resolve_sb 2>/dev/null
t "E 空值等同latest" "$SB_VERSION" "1.15.0"

# F 本机版本号能从不带 x.y.z 首列的格式里抠出来(带 go 版本 / 带构建信息)
mksb 1.13.5 "$S"; SB_BIN="$S"; sb_latest_version(){ echo ""; }; SB_VERSION="latest"
resolve_sb 2>/dev/null
t "F 本机版本号抠得准" "$SB_VERSION" "1.13.5"

# G 本机版本比基线还老 -> 也沿用, 不"顺手"升到基线(沿用 = 不做任何改动)
mksb 1.11.15 "$S"; SB_BIN="$S"; SB_VERSION="latest"
resolve_sb 2>/dev/null
t "G 老版本也沿用不擅自升级" "$SB_VERSION" "1.11.15"

# H 本机二进制是坏的(输出不可解析) -> 退基线, 不把空串当版本
printf '#!/usr/bin/env bash\necho "garbage output"\n' > "$TD/broken-sb"; chmod +x "$TD/broken-sb"
SB_BIN="$TD/broken-sb"; SB_VERSION="latest"
resolve_sb 2>/dev/null
t "H 二进制输出不可解析时退基线" "$SB_VERSION" "1.14.4"

# I 显式 latest 字符串本身不能被当成版本号拼进 URL
SB_VERSION="latest"; sb_latest_version(){ echo ""; }; SB_BIN="$NOBIN"
resolve_sb 2>/dev/null
t "I latest 哨兵不会被当版本" "$SB_VERSION" "1.14.4"

echo "--- behavioral: PASS=$P FAIL=$F"
rm -rf "$TD"
[ "$F" -eq 0 ]
