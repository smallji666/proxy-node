#!/usr/bin/env bash
# 验证国内直连单一数据源 -> 三端派生, 以及用户自定义/远程名单的合并与过滤。
#
# 为什么单独测: 国内直连决定"哪些域名的 DNS 走国内明文", 收错一个境外域名
# 就是 DNS 泄露。三端(小火箭/Clash/sing-box)语法各不相同, 以前各写一份清单
# 已经漂移过。这里验证: 改一处数据源三端同步; 用户文件立刻生效; 非法行被挡在
# 配置外; 仓库里的 cn-direct.txt 与内置清单零漂移。
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

# 1) 单一数据源块(含 CN_DIRECT_* / load_cn_direct / render_cn_*)
sed -n '/^# ======================= 客户端防护规则: 单一数据源/,/^# ===================== 单一数据源结束/p' "$SRC" > "$FNS"
# 2) valid_domain(load_cn_direct / validate_rule_file 依赖)
awk '$0 ~ "^valid_domain\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC" >> "$FNS"
# 3) 规则文件强校验所需的常量 + validate_rule_file
sed -n '/^RULES_MAX_BYTES=/,/^RULES_MAGIC=/p' "$SRC" >> "$FNS"
awk '$0 ~ "^validate_rule_file\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC" >> "$FNS"

grep -q '^CN_DIRECT_SUFFIXES=' "$FNS" || { echo "FAIL 数据源没抽到"; exit 1; }
grep -q '^load_cn_direct(){' "$FNS" || { echo "FAIL load_cn_direct 没抽到"; exit 1; }
grep -q '^render_cn_sr_suffix(){' "$FNS" || { echo "FAIL render_cn_sr_suffix 没抽到"; exit 1; }
grep -q '^valid_domain(){' "$FNS" || { echo "FAIL valid_domain 没抽到"; exit 1; }
grep -q '^validate_rule_file(){' "$FNS" || { echo "FAIL validate_rule_file 没抽到"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取语法错误"; exit 1; }

# load_cn_direct 读 $STATE_DIR 下的两个文件; 指到临时目录, 绝不碰真实 /etc。
export STATE_DIR="$TD/state"
mkdir -p "$STATE_DIR"

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

# r <函数名> -> 在干净子 shell 里 source 函数库后调用, 避免相互污染变量
r(){ bash -c 'source "$1"; shift; "$@"' _ "$FNS" "$@" 2>/dev/null; }

# ---- 基线: 三端都从同一份内置清单取到 taobao.com / taobao 关键词 ----
t "小火箭后缀含 taobao.com" "$(r render_cn_sr_suffix | grep -c '^DOMAIN-SUFFIX,taobao\.com,DIRECT$')" "1"
t "Clash 后缀含 taobao.com" "$(r render_cn_clash | grep -c '^  - DOMAIN-SUFFIX,taobao\.com,DIRECT$')" "1"
t "sing-box 后缀含 .taobao.com" "$(r render_cn_sb_suffix | grep -c '\.taobao\.com')" "1"
t "小火箭关键词含 taobao" "$(r render_cn_sr_keyword | grep -c '^DOMAIN-KEYWORD,taobao,DIRECT$')" "1"
t "Clash 关键词含 taobao" "$(r render_cn_clash | grep -c '^  - DOMAIN-KEYWORD,taobao,DIRECT$')" "1"
t "sing-box 关键词含 taobao" "$(r render_cn_sb_keyword | grep -c '"taobao"')" "1"

# ---- 关键词品牌主域名必须在后缀清单(mihomo nameserver-policy 不支持关键词子串) ----
# mihomo 的 nameserver-policy 键只支持 +./*. 通配与 geosite, 不支持关键词子串。
# 只收在 CN_DIRECT_KEYWORDS 的品牌(cainiao/haier/lenovo/vipshop)若主域名不在
# 后缀清单, Clash 里会走 DIRECT 路由却用境外 DoH(路由/DNS 分裂)。补进后缀清单
# 让三端一致; 这几条断言防的是"以后整理名单又把主域名删掉"。
# vipshop 关键词的主域名是 vip.com, 它本来就在电商段, 不重复测(避免误导以为新增)。
for _d in cainiao.com haier.com lenovo.com; do
  t "关键词品牌主域名在后缀清单: ${_d}" "$(r render_cn_sr_suffix | grep -c "^DOMAIN-SUFFIX,${_d//./\\.},DIRECT$")" "1"
done
t "关键词品牌主域名 DNS 分流(clash)" "$(r render_cn_dns_clash | grep -c "'+\.cainiao\.com':")" "1"
t "关键词品牌主域名 DNS 分流(singbox)" "$(r render_cn_dns_sb_suffix | grep -c '\.lenovo\.com')" "1"

# ---- 用户自定义文件: 写进去, 三端必须同步出现 ----
printf 'user-added-domain.test\n' > "$STATE_DIR/user-direct.txt"
t "用户文件: 小火箭同步" "$(r render_cn_sr_suffix | grep -c '^DOMAIN-SUFFIX,user-added-domain\.test,DIRECT$')" "1"
t "用户文件: Clash 同步" "$(r render_cn_clash | grep -c '^  - DOMAIN-SUFFIX,user-added-domain\.test,DIRECT$')" "1"
t "用户文件: sing-box 同步" "$(r render_cn_sb_suffix | grep -c '\.user-added-domain\.test')" "1"

# ---- 静态资源域名必须在名单里(第16组) ----
# 为什么单列这几条: 国内站点的图片/JS 常常不在主域名下(淘宝 taobao.com, 图片在
# alicdn.com)。本配置的 GEOIP,CN 带 no-resolve, 域名请求只认这份白名单 ——
# 主域名进了、资源域名没进, 表现就是"页面能开、图片一直转圈"且全走代理。
# 这组断言防的是"以后清理名单时把这些不起眼的资源域名当垃圾删掉"。
for _d in alicdn.com hdslb.com sinaimg.cn zhimg.com gtimg.com bdstatic.com; do
  t "资源域名在名单: ${_d}" "$(r render_cn_sr_suffix | grep -c "^DOMAIN-SUFFIX,${_d//./\\.},DIRECT$")" "1"
done
t "资源域名三端同步(clash)" "$(r render_cn_clash | grep -c 'DOMAIN-SUFFIX,alicdn\.com,DIRECT')" "1"
t "资源域名三端同步(sing-box)" "$(r render_cn_sb_suffix | grep -c 'alicdn\.com')" "1"

# ---- 远程更新文件: 同样合并 ----
printf 'remote-added-domain.test\n' > "$STATE_DIR/remote-direct.txt"
t "远程文件: 小火箭同步" "$(r render_cn_sr_suffix | grep -c '^DOMAIN-SUFFIX,remote-added-domain\.test,DIRECT$')" "1"

# ---- 非法行必须被挡在配置外 ----
printf '*.wild.test\nbad_domain\nok-valid.test\n# 注释行\n\n' > "$STATE_DIR/user-direct.txt"
OUT=$(r render_cn_sr_suffix)
t "非法通配被过滤" "$(printf '%s\n' "$OUT" | grep -c 'wild\.test')" "0"
t "非法下划线被过滤" "$(printf '%s\n' "$OUT" | grep -c 'bad_domain')" "0"
t "合法域名保留" "$(printf '%s\n' "$OUT" | grep -c '^DOMAIN-SUFFIX,ok-valid\.test,DIRECT$')" "1"
t "注释行不当域名" "$(printf '%s\n' "$OUT" | grep -c '注释行')" "0"

# ---- 与内置重复的域名不能重复渲染 ----
printf 'taobao.com\n' > "$STATE_DIR/user-direct.txt"
t "与内置重复不重复渲染" "$(r render_cn_sr_suffix | grep -c '^DOMAIN-SUFFIX,taobao\.com,DIRECT$')" "1"

# ---- 仓库里的 cn-direct.txt 必须与内置清单零漂移(改一处忘了另一处就红) ----
INLINE=$(bash -c 'source "$1"; for d in $CN_DIRECT_SUFFIXES; do echo "$d"; done' _ "$FNS" 2>/dev/null | grep -vx 'cn' | sort)
REMOTE=$(grep -v '^[[:space:]]*#' ../cn-direct.txt | grep -v '^[[:space:]]*$' | sort)
t "内置清单非空" "$([ -n "$INLINE" ] && echo yes || echo no)" "yes"
t "cn-direct.txt 非空" "$([ -n "$REMOTE" ] && echo yes || echo no)" "yes"
t "cn-direct.txt 与内置清单完全一致" "$([ "$INLINE" = "$REMOTE" ] && echo yes || echo no)" "yes"

# ---- validate_rule_file: 真规则过, 错误页/缺头被拒 ----
t "cn-direct.txt 通过强校验" "$(bash -c 'source "$1"; validate_rule_file "$2" && echo ok || echo bad' _ "$FNS" ../cn-direct.txt 2>/dev/null)" "ok"
printf '<html>404 not found</html>\n' > "$TD/bad.txt"
t "HTML 错误页被拒" "$(bash -c 'source "$1"; validate_rule_file "$2" && echo ok || echo bad' _ "$FNS" "$TD/bad.txt" 2>/dev/null)" "bad"
printf 'taobao.com\ntmall.com\n' > "$TD/nomagic.txt"
t "缺自证头被拒" "$(bash -c 'source "$1"; validate_rule_file "$2" && echo ok || echo bad' _ "$FNS" "$TD/nomagic.txt" 2>/dev/null)" "bad"

rm -rf "$TD"
echo "P=$P F=$F"
[ "$F" -eq 0 ]
