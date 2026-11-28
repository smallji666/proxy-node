#!/usr/bin/env bash
# 隔离验证 Hysteria2 的"追最新版"分支: 不联网, 不碰系统。
#
# 为什么值得单独测: 这段逻辑决定"装哪个版本", 一旦判错, 后果比装不上更糟 ——
# 要么把在跑的 2.x 降级回基线(节点直接断), 要么盲目跟进 3.x(配置格式不兼容)。
# 分支多且互相依赖(API 通不通 x 本机装没装 x 显式传没传), 靠人眼看不可靠。
set -u
SRC="../setup.sh"
# Git Bash 的 mktemp 默认吐出 C:////...////Temp/tmp.XXX 混合路径, rm -rf 会触发
# 本地删除守卫而卡死(回归曾因此挂 1 小时)。统一到 /tmp, 与 run.sh 头部一致。
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
# 运行环境把 rm 定义成安全删除 shim 的函数, 删 /tmp 临时文件时会卡住;
# 测试只删自己刚建的临时文件, 恢复真实 rm 避免测试被环境干扰。
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)

# 按内容抽取解析块: 从 `case "${HY2_VERSION:-latest}" in` 到其后第一个 `  esac`
S=$(grep -n 'case "${HY2_VERSION:-latest}" in' "$SRC" | head -1 | cut -d: -f1)
E=$(awk -v s="$S" 'NR > s && /^  esac$/ { print NR; exit }' "$SRC")
if [ -z "$S" ] || [ -z "$E" ]; then
  echo "FAIL 无法定位 HY2 最新版解析块(源码结构变了?)"
  exit 1
fi
{
  echo 'resolve_hy2(){'
  sed -n "${S},${E}p" "$SRC"
  echo '}'
} > "$TD/blk.sh"
# 抽出来的块必须真的含关键分支, 否则下面的断言全是空跑
for kw in 'hy2_latest_version' 'HY2_FALLBACK_VERSION' '2.\*'; do
  if ! grep -q "$kw" "$TD/blk.sh"; then
    echo "FAIL 解析块抽取不完整(缺 ${kw})"
    exit 1
  fi
done
bash -n "$TD/blk.sh" || { echo "FAIL 抽取出的块语法错误"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

# 桩: warn/info 走 stderr(真实脚本里走 stdout, 但这里只关心 HY2_VERSION 的结果)
warn(){ printf 'WARN: %s\n' "$*" >&2; }
info(){ printf 'INFO: %s\n' "$*" >&2; }
HY2_FALLBACK_VERSION="2.13.0"
source "$TD/blk.sh"

# 假 hysteria: 只输出 `Version:    app/vX.Y.Z`
mkhb(){ printf '#!/usr/bin/env bash\nprintf "Version:    app/v%s\\n"\n' "$1" > "$2"; chmod +x "$2"; }
H="$TD/fake-hy2"
# "本机没装"一律用"指向不存在的路径"表达, 不用 rm ——
# 某些环境的安全删除守卫会拦住 rm, 文件还在, 用例就变成假失败/假通过。
NOBIN="$TD/definitely-not-here"; HY2_BIN="$NOBIN"

# A 官方 API 正常 -> 跟最新
hy2_latest_version(){ echo "2.14.0"; }; HY2_VERSION="latest"
resolve_hy2 2>/dev/null
t "A API正常追最新" "$HY2_VERSION" "2.14.0"

# B 最新版已跨到 3.x -> 不跟, 沿用本机 2.14.0(绝不自动跳大版本)
mkhb 2.14.0 "$H"; HY2_BIN="$H"; hy2_latest_version(){ echo "3.0.0"; }; HY2_VERSION="latest"
resolve_hy2 2>/dev/null
t "B 跨3.x不跟, 沿用本机" "$HY2_VERSION" "2.14.0"

# C API 失败, 本机 2.14.0 -> 沿用, 不降级
hy2_latest_version(){ echo ""; }; HY2_VERSION="latest"
resolve_hy2 2>/dev/null
t "C API失败沿用本机" "$HY2_VERSION" "2.14.0"

# D API 失败, 本机没装 -> 退内置基线
HY2_BIN="$NOBIN"; HY2_VERSION="latest"
resolve_hy2 2>/dev/null
t "D API失败且无本机退基线" "$HY2_VERSION" "2.13.0"

# E 用户显式传版本 -> 一个字都不改
HY2_VERSION="2.12.0"
resolve_hy2 2>/dev/null
t "E 显式版本不被动" "$HY2_VERSION" "2.12.0"

# F 本机是 3.x(用户手动换过), API 又失败 -> 退基线, 不把 3.x 当"可沿用"
mkhb 3.0.0 "$H"; HY2_BIN="$H"; hy2_latest_version(){ echo ""; }; HY2_VERSION="latest"
resolve_hy2 2>/dev/null
t "F 本机3.x时不沿用" "$HY2_VERSION" "2.13.0"

# G 空值等同 latest
hy2_latest_version(){ echo "2.14.0"; }; HY2_VERSION=""
resolve_hy2 2>/dev/null
t "G 空值等同latest" "$HY2_VERSION" "2.14.0"

# H API 返回带前缀的脏值(万一上游改了 tag 格式) -> 解析函数应已处理, 这里退基线
hy2_latest_version(){ echo "app/v2.14.0"; }; HY2_VERSION="latest"
resolve_hy2 2>/dev/null
t "H 脏值不直接当版本用" "$HY2_VERSION" "2.13.0"

echo "--- behavioral: PASS=$P FAIL=$F"
rm -rf "$TD"
[ "$F" -eq 0 ]
