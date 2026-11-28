#!/usr/bin/env bash
# 隔离验证 write_sb_client 生成: 不联网, 不碰系统。
#
# 为什么单独测: sing-box 的 REALITY 客户端与 Xray >= 26.9.8 服务端不兼容
# (上游 SagerNet/sing-box#4520, uTLS 的 ClientHello 不带 X25519MLKEM768 key share)。
# 生成的 singbox.json 若仍把 REALITY 当默认出口, 用户导入后就是"节点在、一字节
# 不通"——而 JSON 本身完全合法, 任何格式校验都发现不了。这里锁住的是行为:
# 服务端够新时默认出口必须是 HY2。
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

{
  sed -n '/^# ======================= 客户端防护规则: 单一数据源/,/^# ===================== 单一数据源结束/p' "$SRC"
  for fn in proto_on primary_uuid ss_pass_for derive_hex derive_ss_key effective_default_node \
            hy2_bw_ok sb_tls xray_ver_ge sb_reality_ok \
            render_cn_dns_sb_suffix render_cn_dns_sb_keyword load_cn_direct valid_domain \
            write_sb_client; do
    awk -v n="$fn" '$0 ~ "^" n "\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC"
  done
} > "$FNS"

NB=$(grep -c '^[a-z_]*(){' "$FNS")
[ "$NB" -ge 15 ] || { echo "FAIL 函数抽取不完整(只抽到 $NB 个, 应为 15)"; exit 1; }
grep -q '^STUN_DOMAINS=' "$FNS" || { echo "FAIL 单一数据源未抽到"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取出的函数语法错误"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

# 运行器: $1=函数库 $2=输出路径 $3=Xray 版本 $4=PROTOCOLS $5=DEFAULT_NODE
cat > "$TD/t.sh" <<'EOF'
warn(){ :; }
die(){ echo "DIE $*" >&2; exit 9; }
source "$1"
XRAY_VERSION="$3"
PROTOCOLS="$4"
DEFAULT_NODE="${5:-reality}"
NODE_NAME="Test-Node"
SERVER_IP="203.0.113.9"; VLESS_PORT=443; HY2_PORT=8443; DEST="www.bing.com"
PUB="PUBKEY_B64"; SID="a1b2c3d4"; REALITY_FP="chrome"
UUID="11111111-2222-3333-4444-555555555555"; USERS_FILE="/nonexistent"
HY2_PASS="hy2pass"; HY2_PIN=""; CERT_HEX=""; CERT_SPKI_B64=""
ENABLE_OBFS="0"; OBFS_PASS=""; HY2_HOP=""
HY2_BW_UP=""; HY2_BW_DOWN=""
SS2022_PORT=8388; ANYTLS_PORT=8444; TUIC_PORT=8445
DNS_DOH_CN="https://doh.pub/dns-query"; DNS_DOH_CN2="https://dns.alidns.com/dns-query"
CN_DIRECT_SUFFIXES="cn douyin.com snssdk.com byteimg.com pstatp.com taobao.com"
CN_DIRECT_KEYWORDS="douyin taobao"; CN_DIRECT_ACTIVE=""
CN_DIRECT_REMOTE_FILE="/nonexistent-r"; CN_DIRECT_FILE="/nonexistent-u"
write_sb_client pinned "$2"
EOF

final_of(){ grep -o '"final": "[^"]*"' "$1" | tail -1 | sed 's/.*: "//; s/"//'; }
detour_of(){ grep -o '"detour": "[^"]*"' "$1" | head -1 | sed 's/.*: "//; s/"//'; }

# --- 用例 1: 服务端 26.11.9 (>= 26.9.8) + 有 hy2 -> 默认必须走 HY2 ---
C1="$TD/c1.json"
bash "$TD/t.sh" "$FNS" "$C1" "26.11.9" "reality,hy2" >/dev/null 2>&1
t "新版服务端: 产物非空" "$([ -s "$C1" ] && echo yes || echo no)" yes
t "新版服务端: 默认出口切到 HY2" "$(final_of "$C1")" "hy2-out"
t "新版服务端: DNS 经默认出口" "$(detour_of "$C1")" "hy2-out"
t "新版服务端: REALITY 节点仍保留" "$(grep -c '"tag": "vless-out"' "$C1")" 1
t "新版服务端: HY2 节点存在" "$(grep -c '"tag": "hy2-out"' "$C1")" 1
t "新版服务端: 仍有 block 出站" "$(grep -c '"type": "block"' "$C1")" 1
t "新版服务端: 混合入站端口" "$(grep -c '"listen_port": 2080' "$C1")" 1
t "抖音域名 DNS 走 local" "$(grep -c '"domain_suffix": \[".*\.douyin\.com".*\], "server": "local"' "$C1")" 1
t "抖音 CDN 域名 DNS 走 local" "$(grep -c 'snssdk\.com.*"server": "local"' "$C1")" 1
t "TikTok 不在国内 DNS 白名单" "$(grep -ci 'tiktok' "$C1")" 0
t "DNS final 仍是 remote(境外域名)" "$(grep -c '"final": "remote"' "$C1")" 1

# --- 用例 2: 老服务端 (< 26.9.8) -> 默认仍走 REALITY ---
C2="$TD/c2.json"
bash "$TD/t.sh" "$FNS" "$C2" "26.6.27" "reality,hy2" >/dev/null 2>&1
t "老服务端: 默认走 REALITY" "$(final_of "$C2")" "vless-out"
t "老服务端: DNS 经 REALITY" "$(detour_of "$C2")" "vless-out"

# --- 用例 3: 版本未知(latest) 按最新处理 -> 切 HY2 ---
C3="$TD/c3.json"
bash "$TD/t.sh" "$FNS" "$C3" "latest" "reality,hy2" >/dev/null 2>&1
t "latest: 默认切到 HY2" "$(final_of "$C3")" "hy2-out"

# --- 用例 4: 只开 reality -> 无从可切, 仍是 REALITY(由调用方告警) ---
C4="$TD/c4.json"
bash "$TD/t.sh" "$FNS" "$C4" "26.11.9" "reality" >/dev/null 2>&1
t "只开 reality: 仍用 REALITY" "$(final_of "$C4")" "vless-out"
t "只开 reality: 没有 HY2 出站" "$(grep -c '"tag": "hy2-out"' "$C4")" 0

# --- 用例 5: DEFAULT_NODE=hy2 的既有行为不能被破坏 ---
C5="$TD/c5.json"
bash "$TD/t.sh" "$FNS" "$C5" "26.6.27" "reality,hy2" "hy2" >/dev/null 2>&1
t "DEFAULT_NODE=hy2: 默认 HY2" "$(final_of "$C5")" "hy2-out"

# --- 用例 6: 五协议全开时, 新版服务端也只切默认出口, 其余节点不动 ---
C6="$TD/c6.json"
bash "$TD/t.sh" "$FNS" "$C6" "26.11.9" "reality,hy2,ss2022,anytls,tuic" >/dev/null 2>&1
t "全协议: 默认 HY2" "$(final_of "$C6")" "hy2-out"
t "全协议: 五个出站都在" \
  "$(grep -c '"tag": "\(vless\|hy2\|ss2022\|anytls\|tuic\)-out"' "$C6")" 5

# --- 版本比较边界: 26.9.8 就是分界线 ---
cat > "$TD/v.sh" <<'EOF'
warn(){ :; }
source "$1"
XRAY_VERSION="$2"
if sb_reality_ok; then echo ok; else echo broken; fi
EOF
for pair in "26.9.8:broken" "26.9.7:ok" "26.10.0:broken" "27.0.0:broken" \
            "26.8.99:ok" "25.12.9:ok" "26.6.27:ok" "26.11.9:broken" "latest:broken" "24.3.1:ok"; do
  v="${pair%%:*}"; want="${pair##*:}"
  got=$(bash "$TD/v.sh" "$FNS" "$v")
  t "版本边界 ${v} -> ${want}" "$got" "$want"
done

# --- JSON 结构: 不能有尾逗号/括号失衡(sing-box 会直接拒绝启动) ---
t "无尾逗号" "$(grep -cE ',[[:space:]]*[}\]]' "$C6")" 0
t "花括号配平" \
  "$(awk '{o+=gsub(/{/,"{"); c+=gsub(/}/,"}")} END{print (o==c)?"yes":"no"}' "$C6")" yes
t "方括号配平" \
  "$(awk '{o+=gsub(/\[/,"["); c+=gsub(/\]/,"]")} END{print (o==c)?"yes":"no"}' "$C6")" yes
t "首尾是对象" "$(head -c 1 "$C6")$(awk 'END{print substr($0,length($0),1)}' "$C6")" "{}"

# --- compat 模式与 pinned 的默认出口必须一致 ---
C7="$TD/c7.json"
sed 's/write_sb_client pinned "\$2"/write_sb_client compat "$2"/' "$TD/t.sh" > "$TD/t7.sh"
grep -q 'write_sb_client compat' "$TD/t7.sh" || { echo "FAIL 用例7 的 fixture 没改成功(测试自身坏了)"; exit 1; }
bash "$TD/t7.sh" "$FNS" "$C7" "26.11.9" "reality,hy2" >/dev/null 2>&1
t "compat: 默认也是 HY2" "$(final_of "$C7")" "hy2-out"

echo "----------------------------------------"
echo "  PASS $P   FAIL $F"
[ "$F" -eq 0 ] || exit 1
