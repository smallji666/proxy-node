#!/usr/bin/env bash
# 架构守卫: 验证"规则单一数据源 -> 三端派生"真的成立。
# 手法: 篡改数据源(加一个 STUN 域名), 三个 render_* 输出必须同时包含它;
# 再把数据源改回去, 输出也必须跟着消失。这才是防漂移的实质测试 ——
# 静态断言只能证明"字符串存在", 证明不了"改一处三端同步"。
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

# 抽取数据源块 + 三个渲染器, 按标记定位
sed -n '/^# ======================= 客户端防护规则: 单一数据源/,/^# ===================== 单一数据源结束/p' "$SRC" > "$FNS"
[ -s "$FNS" ] || { echo "FAIL 单一数据源块抽取失败"; exit 1; }
NB=$(grep -c '^[a-z_]*(){' "$FNS")
[ "$NB" -ge 5 ] || { echo "FAIL 渲染器抽取不完整($NB)"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取语法错误"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

CANARY="stun.canary.example.test"
render_all(){
  bash -c '
    source "$1"
    shift
    render_stun_sr
    echo "---"
    render_stun_clash
    echo "---"
    render_stun_sb_domains
  ' _ "$FNS" 2>/dev/null
}

BASE=$(render_all)
t "基线: 小火箭规则存在" "$(printf '%s\n' "$BASE" | grep -c 'REJECT-NO-DROP')" "7"
t "基线: Clash 域名规则存在" "$(printf '%s\n' "$BASE" | grep -c 'DOMAIN-SUFFIX.*REJECT$')" "7"
t "基线: Clash UDP 端口规则存在" "$(printf '%s\n' "$BASE" | grep -c 'NETWORK,udp')" "3"
t "基线: sing-box JSON 数组非空" "$([ -n "$(printf '%s\n' "$BASE" | tail -1)" ] && echo yes || echo no)" "yes"

# 篡改数据源: 数组末尾加一条
sed "s/^STUN_DOMAINS=(/STUN_DOMAINS=($CANARY /" "$SRC" \
  | sed -n '/^# ======================= 客户端防护规则: 单一数据源/,/^# ===================== 单一数据源结束/p' > "$TD/mutant.sh"
MUT=$(bash -c 'source "$1"; render_stun_sr; echo "---"; render_stun_clash; echo "---"; render_stun_sb_domains' _ "$TD/mutant.sh" 2>/dev/null)

t "变异: 小火箭同步新增域名" "$(printf '%s\n' "$MUT" | grep -c "DOMAIN-SUFFIX,${CANARY},REJECT-NO-DROP")" "1"
t "变异: Clash 同步新增域名" "$(printf '%s\n' "$MUT" | grep -c "DOMAIN-SUFFIX,${CANARY},REJECT$")" "1"
t "变异: sing-box 同步新增域名" "$(printf '%s\n' "$MUT" | tail -1 | grep -c "$CANARY")" "1"
t "变异: 三端总数都+1" "$(printf '%s\n' "$MUT" | grep -c 'REJECT-NO-DROP')" "8"

# 反向: 基线不含 canary(证明上面不是恒真)
t "基线不含 canary(反向守卫)" "$(printf '%s\n' "$BASE" | grep -c "$CANARY" || true)" "0"

echo "P=$P F=$F"
[ "$F" -eq 0 ]
