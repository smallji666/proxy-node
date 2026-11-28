#!/usr/bin/env bash
# 隔离验证 DNS 泄露自检: 不联网, 不碰系统。
#
# 为什么值得单独测: 这一项的全部价值就是"别骗人"。
#   - 静态审计必须读**真实生成**的订阅产物(不是手写 fixture, 否则产物写坏了测不出来)
#   - DoH 探测必须要求 Status:0 且有 Answer, 只判"有响应"会把 403/限流页当成功
#   - 隧道必须真起得来、真收得干净, 否则所有"经隧道"的结论都是假的
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
# 运行环境把 rm 包成了安全删除 shim, 删临时目录会卡住; 这里只删自己建的。
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

# 数据源块 + 三端 writer 及其依赖: 少了任何一个, 生成出来的产物都是残缺的,
# 审计会"通过"一份根本不存在的配置 —— 假绿。
{
  sed -n '/^# ======================= 客户端防护规则: 单一数据源/,/^# ===================== 单一数据源结束/p' "$SRC"
  for fn in uri_fragment proto_on primary_uuid ss_pass_for derive_hex derive_ss_key \
            render_stun_sr render_stun_clash render_stun_sb_domains \
            hy2_bw_ok effective_default_node sb_tls \
            write_clash_yaml write_shadowrocket_conf write_sb_client \
            sub_dns_issues doh_ok print_client_checklist; do
    awk -v n="$fn" '$0 ~ "^" n "\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC"
  done
} > "$FNS"

NB=$(grep -c '^[a-z_0-9]*(){' "$FNS")
[ "$NB" -ge 16 ] || { echo "FAIL 函数抽取不完整(只抽到 $NB 个, 应为 16)"; exit 1; }
grep -q '^STUN_DOMAINS=' "$FNS" || { echo "FAIL 单一数据源未抽到"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取出的函数语法错误"; exit 1; }
# 审计函数要在本 shell 里直接调用(生成产物则走独立子 shell), 所以这里 source 一次。
# 少了这一步, 下面每条 sub_dns_issues 都是 "command not found" —— 而且 $? 非 0,
# "被检出"类断言会全部假绿(它只判 rc>0)。
# print_client_checklist 内部调 proto_on, 后者读 $PROTOCOLS; 本文件是 set -u,
# 不预置会让 PROTOCOLS unbound 报错(历史遗留的测试桩噪音)。给个合理默认值,
# 让 checklist 走"有 reality"的正常分支。
PROTOCOLS="${PROTOCOLS:-reality,hy2}"
source "$FNS" || { echo "FAIL 函数库无法加载"; exit 1; }
command -v sub_dns_issues >/dev/null 2>&1 || { echo "FAIL sub_dns_issues 没抽到"; exit 1; }
command -v doh_ok        >/dev/null 2>&1 || { echo "FAIL doh_ok 没抽到"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

# ---------------------------------------------------------------- 用真 writer 生成三端产物
cat > "$TD/gen.sh" <<'EOF'
warn(){ :; }; die(){ echo "DIE $*" >&2; exit 9; }
source "$1"
OUT="$2"
NODE_NAME="Test-Node"
PROTOCOLS="reality,hy2,ss2022,anytls,tuic"
SERVER_IP="203.0.113.9"; VLESS_PORT=443; HY2_PORT=8443; DEST="www.bing.com"
PUB="PUBKEY_B64"; SID="a1b2c3d4"; REALITY_FP="chrome"
UUID="11111111-2222-3333-4444-555555555555"; USERS_FILE="/nonexistent"
HY2_PASS="hy2pass"; HY2_PIN="PIN"; CERT_SPKI_B64="SPKI"; CERT_HEX="AABBCC"
SB_PIN="SBPIN"; SB_HEX="SBHEX"
ENABLE_OBFS="1"; OBFS_PASS="obfspass"; HY2_HOP="20000-30000"
SS2022_PORT=8388; ANYTLS_PORT=8444; TUIC_PORT=8445
HY2_BW_UP="100"; HY2_BW_DOWN="200"; DEFAULT_NODE="reality"
PRIMARY_UUID="$UUID"
mkdir -p "$OUT"
write_clash_yaml "$OUT/clash.yaml" "$HY2_BW_UP" "$HY2_BW_DOWN" reality
write_shadowrocket_conf "$OUT/shadowrocket.conf" reality
write_sb_client pinned "$OUT/singbox.json"
EOF

GD="$TD/sub"
bash "$TD/gen.sh" "$FNS" "$GD" 2>&1 | head -5
t "clash.yaml 已生成"      "$([ -s "$GD/clash.yaml" ] && echo yes || echo no)" yes
t "shadowrocket.conf 已生成" "$([ -s "$GD/shadowrocket.conf" ] && echo yes || echo no)" yes
t "singbox.json 已生成"     "$([ -s "$GD/singbox.json" ] && echo yes || echo no)" yes

# --- 用例 1: 真实产物必须零问题(这是本测试的核心) ---
out=$(sub_dns_issues "$GD"); rc=$?
t "真实产物零问题"   "$rc" 0
t "真实产物无输出"   "$([ -z "$out" ] && echo yes || echo no)" yes

# --- 用例 2: 破坏 clash 的 #PROXY, 必须被检出 ---
D2="$TD/b2"; cp -r "$GD" "$D2"
sed -i 's/#PROXY//g' "$D2/clash.yaml"
out=$(sub_dns_issues "$D2"); rc=$?
t "clash 丢 #PROXY 被检出" "$([ "$rc" -gt 0 ] && echo yes || echo no)" yes
t "报错点名 #PROXY"        "$(printf '%s' "$out" | grep -c '没经代理')" 1

# --- 用例 2b: 两条 nameserver 只丢一条, 也必须检出 ---
# 这是审计最容易漏的形态: "文件里还有 #PROXY" 为真, 但已经有一条在本地解析了。
D2b="$TD/b2b"; cp -r "$GD" "$D2b"
awk 'BEGIN{done=0} { if(!done && index($0,"#PROXY")){ sub(/#PROXY/,""); done=1 } print }' \
  "$GD/clash.yaml" > "$D2b/clash.yaml"
t "只丢一条 #PROXY 也检出" \
  "$(sub_dns_issues "$D2b" >/dev/null 2>&1; echo $?)" 1
t "点名是'条目没经代理'" \
  "$(sub_dns_issues "$D2b" 2>/dev/null | grep -c '条目没经代理')" 1

# --- 用例 3: 破坏小火箭的 force-remote-dns ---
D3="$TD/b3"; cp -r "$GD" "$D3"
sed -i 's/^FINAL,PROXY,force-remote-dns$/FINAL,PROXY/' "$D3/shadowrocket.conf"
out=$(sub_dns_issues "$D3"); rc=$?
t "小火箭丢 force-remote-dns 被检出" "$([ "$rc" -gt 0 ] && echo yes || echo no)" yes
t "报错点名 force-remote-dns"        "$(printf '%s' "$out" | grep -c 'force-remote-dns')" 1

# --- 用例 4: sing-box 的 DNS 退回 direct ---
D4="$TD/b4"; cp -r "$GD" "$D4"
sed -i 's/"final": "remote"/"final": "direct"/' "$D4/singbox.json"
out=$(sub_dns_issues "$D4"); rc=$?
t "singbox DNS 退回 direct 被检出" "$([ "$rc" -gt 0 ] && echo yes || echo no)" yes

# --- 用例 5: 文件缺失也要报, 不能静默跳过 ---
D5="$TD/b5"; mkdir -p "$D5"; cp "$GD/clash.yaml" "$D5/"
out=$(sub_dns_issues "$D5"); rc=$?
t "缺 shadowrocket.conf 被检出" "$([ "$rc" -gt 0 ] && echo yes || echo no)" yes
t "缺 singbox.json 被检出"      "$(printf '%s' "$out" | grep -c 'singbox.json 不存在')" 1

# --- 用例 6: 小火箭 hijack-dns 写成 :53(全劫持, 会拖走国内 App 的正常查询) ---
# 修订54: 正确值已从 :53 改为官方 8.8.8.8:53,8.8.4.4:53, 这里注入旧的 :53 错写法。
D6="$TD/b6"; cp -r "$GD" "$D6"
sed -i 's/^hijack-dns = 8\.8\.8\.8:53,8\.8\.4\.4:53$/hijack-dns = :53/' "$D6/shadowrocket.conf"
out=$(sub_dns_issues "$D6"); rc=$?
t "hijack-dns=:53 全劫持被检出" "$(printf '%s' "$out" | grep -c 'hijack-dns 不是官方值')" 1

# --- 用例 6b: dns-server 被改回境外 DoH 经代理(修订53 修掉的旧架构) ---
D6B="$TD/b6b"; cp -r "$GD" "$D6B"
sed -i 's#^dns-server = .*#dns-server = https://cloudflare-dns.com/dns-query\#proxy=Node-VLESS#' "$D6B/shadowrocket.conf"
out=$(sub_dns_issues "$D6B"); rc=$?
t "dns-server 走境外代理被检出" "$(printf '%s' "$out" | grep -c 'dns-server 不是国内 DNS')" 1

# ---------------------------------------------------------------- doh_ok: 不能把错误页当成功
cat > "$TD/doh.sh" <<'EOF'
source "$1"
RESP="$2"; VIA="$3"
curl(){
  # 记录是否走了 socks
  case " $* " in *" --socks5-hostname "*) echo socks >> "$LOGF" ;; *) echo direct >> "$LOGF" ;; esac
  printf '%s' "$RESP"
  return 0
}
LOGF="$4"; : > "$LOGF"
if doh_ok "https://example/dns-query" "$VIA"; then echo OK; else echo FAIL; fi
EOF
LOG="$TD/doh.log"
t "DoH 正常响应判成功"     "$(bash "$TD/doh.sh" "$FNS" '{"Status":0,"Answer":[{"data":"1.2.3.4"}]}' "" "$LOG" 2>/dev/null)" OK
t "DoH Status:3(NXDOMAIN) 判失败" "$(bash "$TD/doh.sh" "$FNS" '{"Status":3}' "" "$LOG" 2>/dev/null)" FAIL
t "DoH 空响应判失败"       "$(bash "$TD/doh.sh" "$FNS" '' "" "$LOG" 2>/dev/null)" FAIL
t "DoH 403 页面判失败"     "$(bash "$TD/doh.sh" "$FNS" '<html>403 Forbidden</html>' "" "$LOG" 2>/dev/null)" FAIL
t "DoH 有限流字样也判失败" "$(bash "$TD/doh.sh" "$FNS" 'rate limit exceeded' "" "$LOG" 2>/dev/null)" FAIL
t "DoH 无 Answer 判失败"   "$(bash "$TD/doh.sh" "$FNS" '{"Status":0}' "" "$LOG" 2>/dev/null)" FAIL
bash "$TD/doh.sh" "$FNS" '{"Status":0,"Answer":[]}' "127.0.0.1:10897" "$LOG" >/dev/null 2>&1
t "给了代理就走 socks"     "$(cat "$LOG")" socks
bash "$TD/doh.sh" "$FNS" '{"Status":0,"Answer":[]}' "" "$LOG" >/dev/null 2>&1
t "没给代理就走直连"       "$(cat "$LOG")" direct

# ---------------------------------------------------------------- 隧道生命周期(假 xray)
if command -v python3 >/dev/null 2>&1; then
  cat > "$TD/fakexray" <<'EOF'
#!/bin/sh
port=$(sed -n 's/.*"port": \([0-9]*\), "listen".*/\1/p' "$2" | head -1)
exec python3 -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$port)); s.listen(8)
while True: time.sleep(0.2)
"
EOF
  chmod +x "$TD/fakexray"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'exec </dev/null'
    for fn in tunnel_start tunnel_stop; do
      awk -v n="$fn" '$0 ~ "^" n "\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC"
    done
    echo 'TUNNEL_PORT=10897; TUNNEL_DIR=""; TUNNEL_PID=""; TUNNEL_PG=0'
    echo 'tunnel_config_json(){ printf "%s\n" "{ \"log\": {}, \"inbounds\": [ { \"port\": 10897, \"listen\": \"127.0.0.1\" } ] }"; }'
  } > "$TD/tun.sh"
  cat >> "$TD/tun.sh" <<'EOF'
XRAY_BIN="$1"
tunnel_start || { echo "start=FAIL"; exit 0; }
echo "start=OK"
d="$TUNNEL_DIR"
tunnel_stop
echo "dir_gone=$([ -d "$d" ] && echo no || echo yes)"
echo "pid_clear=$([ -z "$TUNNEL_PID" ] && echo yes || echo no)"
EOF
  r=$(bash "$TD/tun.sh" "$TD/fakexray" 2>/dev/null)
  t "隧道起得来"       "$(printf '%s' "$r" | grep -c '^start=OK$')" 1
  t "隧道收尾删临时目录" "$(printf '%s' "$r" | grep -c '^dir_gone=yes$')" 1
  t "隧道收尾清空 pid"   "$(printf '%s' "$r" | grep -c '^pid_clear=yes$')" 1
else
  echo "SKIP 没有 python3, 跳过隧道生命周期测试"
fi

# ---------------------------------------------------------------- --client 清单
# 这份清单的用途是"从终端复制到手机上看", 所以两件事必须守住:
#   1) 不能带 ANSI 转义 —— 粘到手机上会变成 [1;32m 之类的乱码;
#   2) 订阅地址必须跟着 SUB_BIND 走 —— 监听在 127.0.0.1 时给出公网 IP 的
#      链接, 用户在手机上点开必然连不上, 却会以为是服务坏了。
CLI1=$(SUB_HTTP=1 SUB_TOKEN=tok123 SUB_PORT=8443 SUB_BIND=0.0.0.0 \
       SERVER_IP=203.0.113.9 print_client_checklist)
t "清单给出小火箭地址" "$(printf '%s' "$CLI1" | grep -c 'http://203.0.113.9:8443/tok123/shadowrocket.conf')" 1
t "清单给出 Clash 地址"  "$(printf '%s' "$CLI1" | grep -c 'http://203.0.113.9:8443/tok123/clash.yaml')" 1
t "清单给出 v2rayN 地址" "$(printf '%s' "$CLI1" | grep -c 'http://203.0.113.9:8443/tok123/v2rayn-routed.json')" 1
# ESC(0x1b) 一次都不该出现
t "清单无 ANSI 转义" \
  "$(printf '%s' "$CLI1" | od -An -c | grep -c '033')" 0
t "清单含 dnsleaktest"  "$(printf '%s' "$CLI1" | grep -c 'dnsleaktest.com')" 1
t "清单含 ipleak"       "$(printf '%s' "$CLI1" | grep -c 'ipleak.net')" 1
t "清单含 webrtc 检测"  "$(printf '%s' "$CLI1" | grep -c 'browserleaks.com/webrtc')" 1
t "清单警告别用纯链接"  "$(printf '%s' "$CLI1" | grep -c 'base64.txt')" 1

CLI2=$(SUB_HTTP=1 SUB_TOKEN=tok123 SUB_PORT=8443 SUB_BIND=127.0.0.1 \
       SERVER_IP=203.0.113.9 print_client_checklist)
t "本机监听时地址用 127.0.0.1" \
  "$(printf '%s' "$CLI2" | grep -c 'http://127.0.0.1:8443/tok123/clash.yaml')" 1
t "本机监听时不写公网 IP" \
  "$(printf '%s' "$CLI2" | grep -c '203.0.113.9')" 0

CLI3=$(SUB_HTTP=0 SUB_TOKEN=tok123 SUB_PORT=8443 SUB_BIND=0.0.0.0 \
       SERVER_IP=203.0.113.9 SUB_DIR=/var/www/proxy-sub print_client_checklist)
t "没开订阅时给文件路径" "$(printf '%s' "$CLI3" | grep -c '/var/www/proxy-sub/tok123/')" 1
t "没开订阅时不出 URL"   "$(printf '%s' "$CLI3" | grep -c 'http://')" 0

echo "----------------------------------------"
echo "  PASS $P   FAIL $F"
[ "$F" -eq 0 ] || exit 1
