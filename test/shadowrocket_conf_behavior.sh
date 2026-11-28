#!/usr/bin/env bash
# 隔离验证 shadowrocket.conf 生成: 不联网, 不碰系统。
#
# 为什么值得单独测: 这是给 iOS 小火箭的开箱即用 DNS 配置, 直接决定
# "DNS 泄露检测能不能变绿"。写错一个字段(比如把 hijack-dns 写成 true,
# 或节点名没做 URI 编码)用户照着导入就会 DNS 卡死或继续泄露, 而这类
# 错误在 shell 静态断言里看不出来 —— 必须真的跑一遍生成、检查产物。
set -u
SRC="../setup.sh"
# Git Bash 的 mktemp 默认吐出 C:////...////Temp/tmp.XXX 混合路径, rm -rf 会触发
# 本地删除守卫而卡死(回归曾因此挂 1 小时)。统一到 /tmp, 与 run.sh 头部一致。
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
# 运行环境把 rm 定义成安全删除 shim 的函数, 删 /tmp 临时文件时会卡住;
# 测试只删自己刚建的临时文件, 恢复真实 rm 避免测试被环境干扰。
unset -f rm 2>/dev/null || true
# 模拟真实 VPS 出口 IP: 生成器现在把 stun-response-ip 填成 SERVER_IP(让 WebRTC
# 报的 IP 与代理出口一致, 消除属地检测的"WebRTC 泄露"误报)。子 harness 都会被
# 这个导出的环境值覆盖, 因此下面的断言检查它确实被写进配置。
export SERVER_IP="203.0.113.77"
TD=$(mktemp -d)
FNS="$TD/f.sh"

# 抽出单一数据源 + 三个纯函数, 按内容定位(行号会随修订号变化)
# 数据源块必须一起抽: 生成器/校验器现在都从 STUN_DOMAINS 渲染, 少了它
# 生成出的配置没有 STUN 规则, 测试会假红(而不是假绿)。
{
  sed -n '/^# ======================= 客户端防护规则: 单一数据源/,/^# ===================== 单一数据源结束/p' "$SRC"
  sed -n '/^uri_fragment()/,/^}/p' "$SRC"
  sed -n '/^sub_shadowrocket_ok()/,/^}/p' "$SRC"
  sed -n '/^write_shadowrocket_conf()/,/^}/p' "$SRC"
} > "$FNS"

# 抽取完整性自检: 少一个函数, 下面的断言全是假绿
NB=$(grep -c '^[a-z_]*(){' "$FNS")
[ "$NB" -ge 6 ] || { echo "FAIL 函数抽取不完整(只抽到 $NB 个, 应为 6)"; exit 1; }
grep -q '^STUN_DOMAINS=' "$FNS" || { echo "FAIL 单一数据源未抽到"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取出的函数语法错误"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

cat > "$TD/t.sh" <<'EOF'
warn(){ echo "[!] $*" >&2; }
proto_on(){ [ "$1" = reality ] || [ "$1" = hy2 ]; }
source "$1"
NODE_NAME="$2"
OUT="$3"
DEF="$4"
write_shadowrocket_conf "$OUT" "$DEF"
sub_shadowrocket_ok "$OUT"
echo "rc=$?"
EOF

# --- 用例 1: 默认节点 reality, 名字含空格和 % (URI 编码的边界) ---
CFG="$TD/sr1.conf"
OUT=$(bash "$TD/t.sh" "$FNS" 'My Node 100%' "$CFG" reality 2>/dev/null | tail -1)
t "校验器对合法配置返回0" "$OUT" "rc=0"
t "dns-server 用国内 DoH(抖音就近CDN)" "$(grep -c '^dns-server = https://doh.pub/dns-query,https://dns.alidns.com/dns-query,223.5.5.5,119.29.29.29$' "$CFG")" "1"
t "dns-server 不经代理(无 #proxy=)" "$(grep -c 'dns-server.*#proxy=' "$CFG" || :)" "0"
t "全文无 #proxy=(节点名不再参与DNS)" "$(grep -c '#proxy=' "$CFG" || :)" "0"
t "direct-dns-server 国内 DNS" "$(grep -c '^direct-dns-server = 223.5.5.5, 119.29.29.29$' "$CFG")" "1"
t "hijack-dns 用官方值(只劫持谷歌DNS)" "$(grep -c '^hijack-dns = 8.8.8.8:53,8.8.4.4:53$' "$CFG")" "1"
t "hijack-dns 不是 :53(不全劫持)" "$(grep -c '^hijack-dns = :53$' "$CFG" || :)" "0"
t "没有错误的 hijack-dns=true" "$(grep -c 'hijack-dns = true' "$CFG" || :)" "0"
t "用官方 fallback-dns-server" "$(grep -c '^fallback-dns-server = 223.5.5.5,119.29.29.29$' "$CFG")" "1"
t "无死字段 dns-fallback-system" "$(grep -c 'dns-fallback-system' "$CFG" || :)" "0"
t "禁直连系统 DNS" "$(grep -c '^dns-direct-system = false$' "$CFG")" "1"
t "境外域名远端解析" "$(grep -c '^FINAL,PROXY,force-remote-dns$' "$CFG")" "1"
t "关 IPv6" "$(grep -c '^ipv6 = false$' "$CFG")" "1"
t "关 QUIC 绕过" "$(grep -c '^block-quic = all-proxy$' "$CFG")" "1"
t "Apple 直连" "$(grep -c '^DOMAIN-SUFFIX,apple.com,DIRECT$' "$CFG")" "1"
t "STUN 应答IP=真实出口IP(消除WebRTC误报)" "$(grep -c '^stun-response-ip = 203.0.113.77$' "$CFG")" "1"
t "STUN 应答IP不再是写死的1.1.1.1" "$(grep -c '^stun-response-ip = 1.1.1.1$' "$CFG" || :)" "0"
t "WebRTC 防泄漏 STUN 假IP(v6)" "$(grep -c '^stun-response-ipv6 = ::1$' "$CFG")" "1"
t "UDP 不支持转发时拒绝而非直连" "$(grep -c '^udp-policy-not-supported-behaviour = REJECT$' "$CFG")" "1"
t "有 [General] 段" "$(grep -c '^\[General\]$' "$CFG")" "1"
t "有 [Rule] 段" "$(grep -c '^\[Rule\]$' "$CFG")" "1"
# 国内域名必须显式直连: GEOIP,CN,no-resolve 只匹配 IP 目标, 域名请求会跳过
t "国内 .cn 域名直连" "$(grep -c '^DOMAIN-SUFFIX,cn,DIRECT$' "$CFG")" "1"
t "国内 taobao.com 直连" "$(grep -c '^DOMAIN-SUFFIX,taobao.com,DIRECT$' "$CFG")" "1"
t "国内 bilibili.com 直连" "$(grep -c '^DOMAIN-SUFFIX,bilibili.com,DIRECT$' "$CFG")" "1"
t "国内 qq.com 直连" "$(grep -c '^DOMAIN-SUFFIX,qq.com,DIRECT$' "$CFG")" "1"
t "国内域名规则早于 FINAL" "$(awk '
  /^DOMAIN-SUFFIX,taobao.com,DIRECT$/ { if (!c) c=NR }
  /^FINAL,PROXY,force-remote-dns$/    { if (!f) f=NR }
  END { print (c && f && c < f) ? "yes" : "no" }
' "$CFG")" "yes"
t "不用未文档化的 GEOSITE" "$(grep -c 'GEOSITE' "$CFG" || :)" "0"
t "不依赖外部 RULE-SET" "$(grep -c 'RULE-SET' "$CFG" || :)" "0"

# --- 用例 2: 不同默认节点/不同协议组合, DNS 配置都一致且不依赖节点名 ---
# 旧版 DNS 靠 #proxy=节点名, 节点名回退写错会让 DNS 卡死。现在 DNS 与节点名
# 彻底解耦: 无论 reality/hy2/anytls/tuic、无论节点名含什么字符, dns-server
# 都必须是同一份国内 DNS, 且全文不出现 #proxy=。
CFG2="$TD/sr2.conf"
bash "$TD/t.sh" "$FNS" 'My Node' "$CFG2" hy2 >/dev/null 2>&1
t "hy2默认节点下dns-server仍国内DNS" "$(grep -c '^dns-server = https://doh.pub/dns-query' "$CFG2")" "1"
t "hy2默认节点下无#proxy=" "$(grep -c '#proxy=' "$CFG2" || :)" "0"

cat > "$TD/t3b.sh" <<'EOF'
warn(){ echo "[!] $*" >&2; }
proto_on(){ [ "$1" = "$PROTO_MOCK" ]; }
source "$1"
NODE_NAME="Fallback"
write_shadowrocket_conf "$2" "$PROTO_MOCK"
EOF
CFG3B="$TD/sr3b.conf"; PROTO_MOCK=anytls bash "$TD/t3b.sh" "$FNS" "$CFG3B" >/dev/null 2>&1
t "只开anytls时dns-server仍国内DNS" "$(grep -c '^dns-server = https://doh.pub/dns-query' "$CFG3B")" "1"
t "只开anytls时无#proxy=" "$(grep -c '#proxy=' "$CFG3B" || :)" "0"
CFG3C="$TD/sr3c.conf"; PROTO_MOCK=tuic bash "$TD/t3b.sh" "$FNS" "$CFG3C" >/dev/null 2>&1
t "只开tuic时dns-server仍国内DNS" "$(grep -c '^dns-server = https://doh.pub/dns-query' "$CFG3C")" "1"
t "只开tuic时无#proxy=" "$(grep -c '#proxy=' "$CFG3C" || :)" "0"

# --- 用例 4: 校验器必须能拒绝残缺配置(假绿防护) ---
cat > "$TD/t4.sh" <<'EOF'
source "$1"
sub_shadowrocket_ok "$2"
echo "rc=$?"
EOF
echo "[General]" > "$TD/bad.conf"
BADRC=$(bash "$TD/t4.sh" "$FNS" "$TD/bad.conf" 2>/dev/null | tail -1)
t "校验器拒绝残缺配置" "$BADRC" "rc=1"
# 只缺 STUN 一项也必须拒绝 —— 否则 WebRTC 防泄漏被删了也全绿
cp "$CFG" "$TD/no-stun.conf"
sed -i '/^stun-response-ip = /d' "$TD/no-stun.conf"
NOSTUN=$(bash "$TD/t4.sh" "$FNS" "$TD/no-stun.conf" 2>/dev/null | tail -1)
t "校验器拒绝缺STUN防泄漏的配置" "$NOSTUN" "rc=1"

# --- 用例 5: 国内域名规则缺失或写在 FINAL 之后都必须拒绝(防静默失效) ---
# 用数据源第一条(cn)作标记: 校验器就是从数据源算第一条, 测试必须跟着走,
# 否则改了清单顺序, 测试和校验器各说各话(一个假绿一个假红)。
cp "$CFG" "$TD/no-cn.conf"
sed -i '/^DOMAIN-SUFFIX,cn,DIRECT$/d' "$TD/no-cn.conf"
NOCN=$(bash "$TD/t4.sh" "$FNS" "$TD/no-cn.conf" 2>/dev/null | tail -1)
t "校验器拒绝缺国内域名规则的配置" "$NOCN" "rc=1"

cp "$CFG" "$TD/cn-late.conf"
sed -i '/^DOMAIN-SUFFIX,cn,DIRECT$/d' "$TD/cn-late.conf"
printf '%s\n' 'DOMAIN-SUFFIX,cn,DIRECT' >> "$TD/cn-late.conf"
LATE=$(bash "$TD/t4.sh" "$FNS" "$TD/cn-late.conf" 2>/dev/null | tail -1)
t "校验器拒绝国内域名规则写在FINAL之后" "$LATE" "rc=1"

# --- 用例 5b: v1.3 关键词规则缺失/位置错误/含误伤短词都必须拒绝 ---
cp "$CFG" "$TD/no-kw.conf"
sed -i '/^DOMAIN-KEYWORD,taobao,DIRECT$/d' "$TD/no-kw.conf"
NOKW=$(bash "$TD/t4.sh" "$FNS" "$TD/no-kw.conf" 2>/dev/null | tail -1)
t "校验器拒绝缺关键词规则的配置" "$NOKW" "rc=1"

cp "$CFG" "$TD/kw-late.conf"
sed -i '/^DOMAIN-KEYWORD,taobao,DIRECT$/d' "$TD/kw-late.conf"
printf '%s\n' 'DOMAIN-KEYWORD,taobao,DIRECT' >> "$TD/kw-late.conf"
KWLATE=$(bash "$TD/t4.sh" "$FNS" "$TD/kw-late.conf" 2>/dev/null | tail -1)
t "校验器拒绝关键词规则写在FINAL之后" "$KWLATE" "rc=1"

cp "$CFG" "$TD/bad-kw.conf"
# 保留正常关键词, 额外塞一个短词 oppo 到末尾: 校验器应因短词拒绝(而非因缺关键词)。
printf '%s\n' 'DOMAIN-KEYWORD,oppo,DIRECT' >> "$TD/bad-kw.conf"
BADKW=$(bash "$TD/t4.sh" "$FNS" "$TD/bad-kw.conf" 2>/dev/null | tail -1)
t "校验器拒绝误伤境外域名的oppo短词" "$BADKW" "rc=1"

# --- 用例 6: 生成配置无注释(精简); 不插入 IP-CIDR(那会反向泄露) ---
t "生成配置无行内注释(精简)" "$(grep -c '^#' "$CFG" || :)" "0"
IPRULE=$(grep -c '^IP-CIDR,34\.8\.0\.0/16,PROXY' "$CFG")
t "配置未真的插入Claude的IP段" "$IPRULE" "0"

# --- 用例 6b: v1.5 STUN 域名层拦截, 必须排在 FINAL 之前 ---
t "STUN 域名拦截存在" "$(grep -c '^DOMAIN-SUFFIX,stun.l.google.com,REJECT-NO-DROP$' "$CFG")" "1"
t "STUN Mozilla 域名拦截存在" "$(grep -c '^DOMAIN-SUFFIX,stun.services.mozilla.com,REJECT-NO-DROP$' "$CFG")" "1"
t "STUN 域名规则早于 FINAL" "$(awk '
  /^DOMAIN-SUFFIX,stun\.l\.google\.com,REJECT-NO-DROP$/ { if (!s) s=NR }
  /^FINAL,PROXY,force-remote-dns$/                       { if (!f) f=NR }
  END { print (s && f && s < f) ? "yes" : "no" }
' "$CFG")" "yes"
# 变异守卫: 把 STUN 规则挪到 FINAL 之后, 校验器必须拒绝
cp "$CFG" "$TD/late-stun.conf"
awk '
  /^DOMAIN-SUFFIX,stun\.l\.google\.com,REJECT-NO-DROP$/ { next }
  { print }
  /^FINAL,PROXY,force-remote-dns$/ { print "DOMAIN-SUFFIX,stun.l.google.com,REJECT-NO-DROP" }
' "$CFG" > "$TD/late-stun.conf"
LATESTUN=$(bash "$TD/t4.sh" "$FNS" "$TD/late-stun.conf" 2>/dev/null | tail -1)
t "校验器拒绝STUN规则写在FINAL之后" "$LATESTUN" "rc=1"

# --- 用例 7: v1.2 补充的高频国内域名必须真的生成, 且排在 FINAL 之前 ---
t "生成含补充域名vip.com" "$(grep -c '^DOMAIN-SUFFIX,vip.com,DIRECT$' "$CFG")" "1"
t "生成含补充域名huawei.com" "$(grep -c '^DOMAIN-SUFFIX,huawei.com,DIRECT$' "$CFG")" "1"
t "生成含补充域名douban.com" "$(grep -c '^DOMAIN-SUFFIX,douban.com,DIRECT$' "$CFG")" "1"
VIPLINE=$(grep -n '^DOMAIN-SUFFIX,vip.com,DIRECT$' "$CFG" | head -1 | cut -d: -f1)
CNLAST=$(grep -n '^DOMAIN-SUFFIX,haodf.com,DIRECT$' "$CFG" | head -1 | cut -d: -f1)
FINLINE=$(grep -n '^FINAL,PROXY,force-remote-dns$' "$CFG" | head -1 | cut -d: -f1)
t "首个补充域名排在FINAL之前" "$([ -n "$VIPLINE" ] && [ -n "$FINLINE" ] && [ "$VIPLINE" -lt "$FINLINE" ] && echo yes || echo no)" "yes"
t "末个补充域名排在FINAL之前" "$([ -n "$CNLAST" ] && [ -n "$FINLINE" ] && [ "$CNLAST" -lt "$FINLINE" ] && echo yes || echo no)" "yes"

# --- 用例 8: v1.3 关键词规则必须真的生成, 且排在 FINAL 之前 ---
t "生成含关键词taobao" "$(grep -c '^DOMAIN-KEYWORD,taobao,DIRECT$' "$CFG")" "1"
t "生成含关键词douban" "$(grep -c '^DOMAIN-KEYWORD,douban,DIRECT$' "$CFG")" "1"
KWFIRST=$(grep -n '^DOMAIN-KEYWORD,taobao,DIRECT$' "$CFG" | head -1 | cut -d: -f1)
KWLAST=$(grep -n '^DOMAIN-KEYWORD,haodf,DIRECT$' "$CFG" | head -1 | cut -d: -f1)
t "首个关键词排在FINAL之前" "$([ -n "$KWFIRST" ] && [ -n "$FINLINE" ] && [ "$KWFIRST" -lt "$FINLINE" ] && echo yes || echo no)" "yes"
t "末个关键词排在FINAL之前" "$([ -n "$KWLAST" ] && [ -n "$FINLINE" ] && [ "$KWLAST" -lt "$FINLINE" ] && echo yes || echo no)" "yes"
# 关键词条数从数据源现算, 不在测试里写死数字(否则加一个词就假红)
KWCOUNT=$(bash -c 'source "$1"; for k in $CN_DIRECT_KEYWORDS; do echo "$k"; done' _ "$FNS" | wc -l | tr -d ' ')
t "关键词总数与数据源一致" "$(grep -c '^DOMAIN-KEYWORD,' "$CFG")" "$KWCOUNT"
t "未混入误伤境外域名的oppo关键词" "$(grep -c '^DOMAIN-KEYWORD,oppo,DIRECT$' "$CFG")" "0"
t "GEOIP规则全部带no-resolve" "$(awk '
  /^GEOIP,CN,DIRECT/ { if ($0 !~ /no-resolve/) bad=1 }
  END { print bad ? "no" : "yes" }
' "$CFG")" "yes"

echo "--- PASS=$P FAIL=$F"
[ "$F" -eq 0 ]
