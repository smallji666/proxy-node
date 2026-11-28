#!/usr/bin/env bash
# 验证 x 菜单里"输入序号 / r / c / 域名"的解析。
#
# 为什么单独测: 这段逻辑以前根本不存在 —— 菜单写着"查看全部候选", 实际
# 只打印当前站。现在它决定用户到底换到了哪个站, 解析错了会把同一个 SNI
# 又写一遍, 或者把带空格的输入塞进 openssl 命令行。这里不碰 systemd /
# 网络, 只从 setup.sh 抽出两个纯函数跑。
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

{
  for fn in valid_domain dest_choice dest_note _dest_print_pool cmd_dest; do
    awk -v n="$fn" '$0 ~ "^" n "\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC"
  done
} > "$FNS"
grep -q '^valid_domain(){' "$FNS" || { echo "FAIL valid_domain 没抽到"; exit 1; }
grep -q '^dest_choice(){' "$FNS" || { echo "FAIL dest_choice 没抽到"; exit 1; }
grep -q '^cmd_dest(){' "$FNS" || { echo "FAIL cmd_dest 没抽到"; exit 1; }
grep -q '^_dest_print_pool(){' "$FNS" || { echo "FAIL _dest_print_pool 没抽到"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取出的函数语法错误"; exit 1; }
# 函数库路径是运行时 mktemp 出来的, shellcheck 追不到; 这里确实是故意 source。
# shellcheck disable=SC1090
source "$FNS" || { echo "FAIL 函数库无法加载"; exit 1; }

# 候选池直接取自被测脚本, 避免测试里再抄一份域名表然后慢慢写歪。
REALITY_DESTS=$(grep -m1 '^REALITY_DESTS=' "$SRC" | sed 's/^REALITY_DESTS="//; s/"$//')
[ -n "$REALITY_DESTS" ] || { echo "FAIL 没读到 REALITY_DESTS"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

pick(){ # pick <输入> -> 只把 stdout / rc 放进变量
  OUT=$(dest_choice "$1" 2>/dev/null); RC=$?
}

pick "";        t "回车=不改"                 "$RC:$OUT" "0:"
pick "0";       t "0=不改"                     "$RC:$OUT" "0:"
pick "q";       t "q=不改"                     "$RC:$OUT" "0:"
pick "Q";       t "Q=不改"                     "$RC:$OUT" "0:"
pick "r";       t "r=随机换"                   "$RC:$OUT" "0:random"
pick "R";       t "R=随机换"                   "$RC:$OUT" "0:random"
pick "random";  t "random=随机换"              "$RC:$OUT" "0:random"

first=${REALITY_DESTS%% *}
third=$(printf '%s\n' "$REALITY_DESTS" | awk '{print $3}')
last=$(printf '%s\n' "$REALITY_DESTS" | awk '{print $NF}')
pick "1";       t "序号1=池子第一个站"          "$RC:$OUT" "0:$first"
pick "3";       t "序号3=池子第三个站"          "$RC:$OUT" "0:$third"
pick "18";      t "末序号=池子最后一个站"        "$RC:$OUT" "0:$last"

pick "www.oracle.com"; t "直接填域名原样返回"    "$RC:$OUT" "0:www.oracle.com"
pick "CUSTOM.EXAMPLE"; t "大小写域名也合法"      "$RC:$OUT" "0:CUSTOM.EXAMPLE"

pick "c";       t "c 需要调用方再读域名"         "$RC" "1"
pick "99";      t "越界序号被拒"                 "$RC:$OUT" "1:"
pick "-1";      t "负数被拒"                     "$RC:$OUT" "1:"
pick "bad domain"; t "带空格的域名被拒"          "$RC:$OUT" "1:"
pick "www..example.com"; t "连续点被拒"          "$RC:$OUT" "1:"
pick "www.example.com."; t "尾点被拒"            "$RC:$OUT" "1:"
pick "-www.example.com"; t "连字符开头被拒"      "$RC:$OUT" "1:"

# --- 菜单接线: 按 x 必须真的看到候选池, 并把选择交给 change_dest ---
# 真实脚本里这些是 systemd / 证书 / 网络操作, 这里只验证"选了什么 -> 换哪个站"。
# 颜色和 DEST 是被抽出来的函数间接读取的, shellcheck 静态看不见。
# shellcheck disable=SC2034
M=''; N=''; D=''; Y=''
hr(){ printf '%s\n' '--------'; }
need_root(){ :; }
load_state(){ :; }
info(){ printf 'INFO %s\n' "$*"; }
die(){ printf 'DIE %s\n' "$*"; exit 1; }
change_dest(){ printf 'CHANGE %s\n' "${1:-}"; }
# shellcheck disable=SC2034
DEST='www.kernel.org'
# 显式"用到"一次, 免得 shellcheck 把间接引用误判成未使用变量。
: "$M" "$N" "$D" "$Y" "$DEST"

read_tty(){ printf -v "$2" '%s' ''; }
OUT=$(cmd_dest 2>&1)
t "菜单打印候选池标题" "$(printf '%s\n' "$OUT" | grep -c '伪装目标候选池')" "1"
t "菜单列出池子全部候选" "$(printf '%s\n' "$OUT" | grep -cE '^[[:space:]]+[0-9]+\. www\.')" "18"
t "菜单显示当前站" "$(printf '%s\n' "$OUT" | grep -c '域名   : www.kernel.org')" "1"
t "回车不会换站" "$(printf '%s\n' "$OUT" | grep -c '^CHANGE')" "0"

read_tty(){ printf -v "$2" '%s' '3'; }
OUT=$(cmd_dest 2>&1)
t "输入序号换到池子第三站" "$(printf '%s\n' "$OUT" | grep -c '^CHANGE www.amd.com')" "1"

read_tty(){ printf -v "$2" '%s' 'r'; }
OUT=$(cmd_dest 2>&1)
t "输入 r 触发随机换站" "$(printf '%s\n' "$OUT" | grep -c '^CHANGE random')" "1"

_TTY_CALLS=0
read_tty(){
  _TTY_CALLS=$((_TTY_CALLS + 1))
  if [ "$_TTY_CALLS" -eq 1 ]; then printf -v "$2" '%s' 'c'; else printf -v "$2" '%s' 'www.oracle.com'; fi
}
OUT=$(cmd_dest 2>&1)
t "输入 c 后自填域名生效" "$(printf '%s\n' "$OUT" | grep -c '^CHANGE www.oracle.com')" "1"

OUT=$(cmd_dest set random 2>&1)
t "非交互 set 子命令可用" "$(printf '%s\n' "$OUT" | grep -c '^CHANGE random')" "1"

echo "  PASS $P  FAIL $F"
[ "$F" -eq 0 ]
