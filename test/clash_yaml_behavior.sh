#!/usr/bin/env bash
# 隔离验证 write_clash_yaml 生成: 不联网, 不碰系统。
#
# 为什么值得单独测: clash.yaml 是 Clash/mihomo/Clash Verge 用户唯一能拿到
# DNS 防泄露 + fake-ip 的入口。YAML 对缩进极敏感, 少两个空格整份订阅就
# 加载失败; 而 shell 静态断言看不出缩进对不对 —— 必须真跑一遍看产物。
# 以前这段内嵌在 gen_sub_files 里(靠外层局部变量传值), 根本没法单独跑。
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

# 按内容定位抽取(行号会随修订号变化)。单一数据源块必须一起抽:
# write_clash_yaml 里的 DNS 端点与 STUN 规则全部从它渲染, 少了它就是假红。
{
  sed -n '/^# ======================= 客户端防护规则: 单一数据源/,/^# ===================== 单一数据源结束/p' "$SRC"
  for fn in proto_on primary_uuid ss_pass_for derive_hex derive_ss_key render_stun_clash write_clash_yaml; do
    awk -v n="$fn" '$0 ~ "^" n "\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC"
  done
} > "$FNS"

NB=$(grep -c '^[a-z_]*(){' "$FNS")
[ "$NB" -ge 7 ] || { echo "FAIL 函数抽取不完整(只抽到 $NB 个, 应为 7)"; exit 1; }
grep -q '^STUN_DOMAINS=' "$FNS" || { echo "FAIL 单一数据源未抽到"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取出的函数语法错误"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

# 运行器: $1=函数库 $2=输出路径 $3=默认节点 $4=up $5=down
cat > "$TD/t.sh" <<'EOF'
warn(){ :; }
die(){ echo "DIE $*" >&2; exit 9; }
source "$1"
NODE_NAME="Test-Node"
PROTOCOLS="reality,hy2,ss2022,anytls,tuic"
SERVER_IP="203.0.113.9"; VLESS_PORT=443; HY2_PORT=8443; DEST="www.bing.com"
PUB="PUBKEY_B64"; SID="a1b2c3d4"; REALITY_FP="chrome"
UUID="11111111-2222-3333-4444-555555555555"; USERS_FILE="/nonexistent"
HY2_PASS="hy2pass"; HY2_PIN="PIN"; CERT_HEX="AABBCC"
ENABLE_OBFS="1"; OBFS_PASS="obfspass"; HY2_HOP="20000-30000"
SS2022_PORT=8388; ANYTLS_PORT=8444; TUIC_PORT=8445
write_clash_yaml "$2" "$4" "$5" "$3"
EOF

# --- 用例 1: reality 默认, 带宽齐全 ---
C="$TD/c1.yaml"
bash "$TD/t.sh" "$FNS" "$C" reality 100 200
t "产物非空" "$([ -s "$C" ] && echo yes || echo no)" yes
t "顶层 mixed-port" "$(grep -c '^mixed-port: 7890$' "$C")" 1
t "关 IPv6" "$(grep -c '^ipv6: false$' "$C")" 1
t "fake-ip 模式" "$(grep -c '^  enhanced-mode: fake-ip$' "$C")" 1
t "fake-ip 网段" "$(grep -c '^  fake-ip-range: 198.18.0.1/16$' "$C")" 1
t "DNS 境外 DoH 经代理" "$(grep -c 'https://cloudflare-dns.com/dns-query#PROXY' "$C")" 1
t "DNS 国内域名分流" "$(grep -c "geosite:cn,private" "$C")" 1
t "proxy-server-nameserver 存在" "$(grep -c '^  proxy-server-nameserver:$' "$C")" 1

# --- 结构: 三段必须都在, 且 MATCH 是最后一条规则 ---
t "proxies 段存在" "$(grep -c '^proxies:$' "$C")" 1
t "proxy-groups 段存在" "$(grep -c '^proxy-groups:$' "$C")" 1
t "rules 段存在" "$(grep -c '^rules:$' "$C")" 1
t "MATCH 是最后一条规则" "$(tail -1 "$C")" "  - MATCH,PROXY"

# --- 规则: 局域网先放行, 国内直连, STUN 拦截都在 MATCH 之前 ---
t "局域网 127/8 直连" "$(grep -c '^  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve$' "$C")" 1
t "局域网 192.168/16 直连" "$(grep -c '^  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve$' "$C")" 1
t "GEOSITE,cn 直连" "$(grep -c '^  - GEOSITE,cn,DIRECT$' "$C")" 1
t "GEOIP,CN 带 no-resolve" "$(grep -c '^  - GEOIP,CN,DIRECT,no-resolve$' "$C")" 1
t "STUN 域名拦截 7 条" "$(grep -c '^  - DOMAIN-SUFFIX,stun.*,REJECT$' "$C")" 7
t "STUN 端口 3478" "$(grep -c '^  - AND,((NETWORK,udp),(DST-PORT,3478)),REJECT$' "$C")" 1
t "STUN 端口 5349" "$(grep -c '^  - AND,((NETWORK,udp),(DST-PORT,5349)),REJECT$' "$C")" 1
t "STUN 端口段 19302-19309" "$(grep -c '^  - AND,((NETWORK,udp),(DST-PORT,19302-19309)),REJECT$' "$C")" 1
t "STUN 规则全在 MATCH 之前(7域名+3端口)" \
  "$(awk '/^  - MATCH,PROXY$/{exit} /^  - DOMAIN-SUFFIX,stun/{n++} /^  - AND,\(\(NETWORK,udp\)/{n++} END{print n+0}' "$C")" 10

# --- 各协议字段 ---
t "VLESS 带 reality-opts" "$(grep -c '^    reality-opts:$' "$C")" 1
t "VLESS 带 uTLS 指纹" "$(grep -c '^    client-fingerprint: chrome$' "$C")" 1
t "HY2 Brutal up" "$(grep -c '^    up: "100 Mbps"$' "$C")" 1
t "HY2 Brutal down" "$(grep -c '^    down: "200 Mbps"$' "$C")" 1
t "HY2 端口跳跃" "$(grep -c '^    ports: "20000-30000"$' "$C")" 1
t "HY2 混淆" "$(grep -c '^    obfs: salamander$' "$C")" 1
t "HY2 有指纹时不跳过校验" "$(grep -c '^    skip-cert-verify: false$' "$C")" 1
t "HY2 写证书指纹" "$(grep -c '^    fingerprint: AABBCC$' "$C")" 1
t "SS2022 用 2022 加密" "$(grep -c '^    cipher: 2022-blake3-aes-128-gcm$' "$C")" 1
t "AnyTLS 显式开 udp" "$(awk '/name: "Test-Node-AnyTLS"/{f=1} f&&/^    udp: true$/{print "yes"; exit}' "$C")" yes
t "TUIC 带 alpn h3" "$(grep -c '^    alpn: \[h3\]$' "$C")" 1

# --- 用例 2: DEFAULT_NODE=hy2 时 select 第一项必须是 HY2 ---
C2="$TD/c2.yaml"
bash "$TD/t.sh" "$FNS" "$C2" hy2 100 200
t "hy2 默认: select 首项是 HY2" \
  "$(awk '/^proxy-groups:$/{f=1} f&&/^      - "/{gsub(/.*- |"/,""); print; exit}' "$C2")" "Test-Node-HY2"

# --- 用例 3: 带宽为空时不能写出 up/down(空值会让 mihomo 报错) ---
C3="$TD/c3.yaml"
bash "$TD/t.sh" "$FNS" "$C3" reality "" ""
t "空带宽: 不写 up" "$(grep -c '^    up:' "$C3")" 0
t "空带宽: 不写 down" "$(grep -c '^    down:' "$C3")" 0

# --- 用例 4: 无证书指纹时退回 skip-cert-verify: true(否则连不上) ---
C4="$TD/c4.yaml"
sed 's/HY2_PIN="PIN"; CERT_HEX="AABBCC"/HY2_PIN=""; CERT_HEX=""/' "$TD/t.sh" > "$TD/t4.sh"
grep -q 'HY2_PIN=""' "$TD/t4.sh" || { echo "FAIL 用例4 的 fixture 没改成功(测试自身坏了)"; exit 1; }
bash "$TD/t4.sh" "$FNS" "$C4" reality 100 200
# AnyTLS/TUIC 本来就恒写 skip-cert-verify: true, 所以这里只看 HY2 那一段
t "无指纹: HY2 退回跳过校验" \
  "$(awk '/name: "Test-Node-HY2"/{f=1} f&&/^    skip-cert-verify: true$/{print "yes"; exit}' "$C4")" yes
t "无指纹: 不写 fingerprint" "$(grep -c '^    fingerprint:' "$C4")" 0

# --- 缩进一致性: YAML 里最致命的错误是缩进错位 ---
# 不用正则逐类匹配(键名含数字、带引号的键都会漏), 只查三条硬性不变量:
#   1) 不能有制表符 —— YAML 规范禁止用 tab 缩进
#   2) 缩进必须是 2 的倍数 —— 混入奇数空格在部分解析器上静默错层
#   3) 非空非注释行要么是列表项(- ), 要么是键值行(含 :)
t "无制表符缩进" "$(grep -cP '\t' "$C" || :)" 0
t "缩进均为偶数" \
  "$(awk '{match($0,/^ */); if(RSTART>0 && (RLENGTH%2)!=0) n++} END{print n+0}' "$C")" 0
t "每行都是键值或列表项" \
  "$(awk 'NF==0{next} /^ *#/{next} /^ *- /{next} /:/{next} {n++} END{print n+0}' "$C")" 0
t "顶层键只有预期那几个" \
  "$(awk '/^[a-zA-Z]/ && /:/{sub(/:.*/,""); print}' "$C" | tr '\n' ' ')" \
  "mixed-port allow-lan mode log-level ipv6 dns proxies proxy-groups rules "

echo "----------------------------------------"
echo "  PASS $P   FAIL $F"
[ "$F" -eq 0 ] || exit 1
