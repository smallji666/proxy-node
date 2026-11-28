#!/usr/bin/env bash
# 隔离验证上游出口(egress)链路: 不联网, 不碰系统。
#
# 为什么值得单独测: 这是"不被判机房"的唯一技术解, 也是全脚本里最容易
# 假成功的一处 —— 代理本身通不等于流量真的走了它。这里把三个纯函数
# (parse_egress / egress_probe_ip / wait_active) 用 mock 跑起来,
# 覆盖地址解析、端点回退、服务就绪轮询三处曾经出过错的地方。
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

{
  # proto_on / sb_enabled 也要抽: apply_egress 的守卫全靠它们判断, 少了就是假绿
  for fn in proto_on sb_enabled parse_egress valid_ipv4 extract_ipv4 egress_probe_ip wait_active apply_egress; do
    awk -v n="$fn" '$0 ~ "^" n "\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC"
  done
} > "$FNS"

# 计数正则要带上数字: valid_ipv4 / extract_ipv4 名字里有 4, 用 [a-z_]* 会漏数
NB=$(grep -c '^[a-z_0-9]*(){' "$FNS")
[ "$NB" -ge 8 ] || { echo "FAIL 函数抽取不完整(只抽到 $NB 个, 应为 8)"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取出的函数语法错误"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

cat > "$TD/r.sh" <<'EOF'
source "$1"
chk(){ if parse_egress "$1" >/dev/null 2>&1; then echo OK; else echo REJ; fi; }
chk "$2"
EOF
chk(){ bash "$TD/r.sh" "$FNS" "$1"; }

# --- 地址解析: 合法格式 ---
t "socks5 带账号密码"        "$(chk 'socks5://u:p@1.2.3.4:1080')" OK
t "socks5h 归一为 socks"     "$(chk 'socks5h://u:p@1.2.3.4:1080')" OK
t "socks 别名"               "$(chk 'socks://1.2.3.4:1080')" OK
t "http 代理"                "$(chk 'http://u:p@1.2.3.4:8080')" OK
t "https 代理"               "$(chk 'https://1.2.3.4:443')" OK
t "IPv6 字面地址"            "$(chk 'socks5://[2001:db8::1]:1080')" OK
t "无账号密码"               "$(chk 'socks5://1.2.3.4:1080')" OK

# --- 端口边界: 越界会让 xray/sing-box 起不来, 必须在入口拦掉 ---
t "端口 1 合法"              "$(chk 'socks5://1.2.3.4:1')" OK
t "端口 65535 合法"          "$(chk 'socks5://1.2.3.4:65535')" OK
t "端口 65536 拒绝"          "$(chk 'socks5://1.2.3.4:65536')" REJ
t "端口 99999 拒绝"          "$(chk 'socks5://1.2.3.4:99999')" REJ
t "端口 0 拒绝"              "$(chk 'socks5://1.2.3.4:0')" REJ
t "前导 0 拒绝(非法 JSON)"   "$(chk 'socks5://1.2.3.4:0123')" REJ
t "端口含字母拒绝"           "$(chk 'socks5://1.2.3.4:12ab')" REJ
t "缺端口拒绝"               "$(chk 'socks5://1.2.3.4')" REJ

# --- 其它非法输入 ---
t "不支持的协议拒绝"         "$(chk 'ftp://1.2.3.4:21')" REJ
t "空串拒绝"                 "$(chk '')" REJ
t "带双引号拒绝"             "$(chk 'socks5://u:p"x@1.2.3.4:1080')" REJ
t "带反斜杠拒绝"             "$(chk 'socks5://u:p\x@1.2.3.4:1080')" REJ

# --- 解析内容正确性 ---
cat > "$TD/p.sh" <<'EOF'
source "$1"
parse_egress "$2"
EOF
t "凭据里带 @ 时按最后一个 @ 切" \
  "$(bash "$TD/p.sh" "$FNS" 'socks5h://us%40er:pa@ss@1.2.3.4:1080')" 'socks|1.2.3.4|1080|us%40er|pa@ss'
t "IPv6 去方括号" \
  "$(bash "$TD/p.sh" "$FNS" 'socks5://[2001:db8::1]:1080')" 'socks|2001:db8::1|1080||'

# --- egress_probe_ip: 第一个端点失败必须回退到第二个 ---
# 部分住宅代理按域名黑名单放行, 会拦 api.ipify.org; 只测一个端点就会把
# "代理是好的"误判成"代理不可用", 用户永远配不上出口。
cat > "$TD/probe.sh" <<'EOF'
source "$1"
EGRESS_URL="$2"
LOG="$3"          # 必须存全局: 函数里的 $3 是 curl 自己的第 3 个参数
# mock curl: 记录被请求的 URL; 对 api.ipify.org 一律失败, 对 ifconfig.me 返回 IP
curl(){
  local last=""
  for a in "$@"; do case "$a" in http*) last="$a" ;; esac; done
  printf '%s\n' "$last" >> "$LOG"
  case "$last" in
    *api.ipify.org*) return 7 ;;
    *ifconfig.me*)   printf '203.0.113.77'; return 0 ;;
  esac
  return 7
}
egress_probe_ip
EOF
LOG="$TD/calls1.log"; : > "$LOG"
OUT=$(bash "$TD/probe.sh" "$FNS" 'socks5://u:p@1.2.3.4:1080' "$LOG" 2>/dev/null)
t "首端点失败回退到次端点" "$OUT" "203.0.113.77"
t "两个端点都试过"         "$(wc -l < "$LOG" | tr -d ' ')" 2

# --- 两个端点都失败时必须返回失败(不能拿限流页当 IP) ---
cat > "$TD/probe2.sh" <<'EOF'
source "$1"
EGRESS_URL="socks5://1.2.3.4:1080"
curl(){ printf 'rate limit exceeded\n'; return 0; }
if egress_probe_ip >/dev/null 2>&1; then echo OK; else echo FAIL; fi
EOF
t "返回非 IP 文本判失败" "$(bash "$TD/probe2.sh" "$FNS" 2>/dev/null)" FAIL

# --- wait_active: 服务晚于 1 秒起来也要判成功 ---
cat > "$TD/wait.sh" <<'EOF'
source "$1"
CNT=0
WANT="$2"         # 必须存全局: 函数里的 $2 是 systemctl 自己的参数(服务名)
systemctl(){
  CNT=$((CNT+1))
  [ "$CNT" -ge "$WANT" ] && return 0 || return 3
}
sleep(){ :; }
if wait_active xray; then echo OK; else echo FAIL; fi
EOF
t "服务第 1 次就绪即返回"   "$(bash "$TD/wait.sh" "$FNS" 1 2>/dev/null)" OK
t "服务第 5 次才就绪也成功" "$(bash "$TD/wait.sh" "$FNS" 5 2>/dev/null)" OK
t "服务始终不起来判失败"    "$(bash "$TD/wait.sh" "$FNS" 999 2>/dev/null)" FAIL

# --- apply_egress 的拦截条件: 只在"启用出口"时拦, 关闭时必须放行 ---
# 回归的 bug: 只开 hy2 的机器(先开 reality 配过出口, 后改成只开 hy2)
# 执行 `proxy egress off` 会被判成关闭失败并回滚, 出口永远关不掉。
cat > "$TD/apply.sh" <<'EOF'
source "$1"
PROTOCOLS="$2"
EGRESS_URL="$3"
DEST="www.bing.com"
# 桩掉真正写配置/重启服务的部分, 只看守卫逻辑
write_xray_config(){ echo "xray-called"; }
write_singbox_config(){ echo "sb-called"; }
systemctl(){ return 0; }
wait_active(){ return 0; }
if apply_egress; then echo "rc=0"; else echo "rc=1"; fi
EOF
t "关闭出口(hy2-only)必须放行" \
  "$(bash "$TD/apply.sh" "$FNS" "hy2" "" 2>/dev/null | tail -1)" "rc=0"
t "启用出口(hy2-only)必须拦住" \
  "$(bash "$TD/apply.sh" "$FNS" "hy2" "socks5://1.2.3.4:1080" 2>/dev/null | tail -1)" "rc=1"
t "启用出口(reality)放行" \
  "$(bash "$TD/apply.sh" "$FNS" "reality" "socks5://1.2.3.4:1080" 2>/dev/null | tail -1)" "rc=0"
t "关闭出口(reality)会重写 xray 配置" \
  "$(bash "$TD/apply.sh" "$FNS" "reality" "" 2>/dev/null | grep -c xray-called)" "1"
t "关闭出口(hy2-only)不碰任何配置" \
  "$(bash "$TD/apply.sh" "$FNS" "hy2" "" 2>/dev/null | grep -c 'xray-called\|sb-called')" "0"

echo "----------------------------------------"
echo "  PASS $P   FAIL $F"
[ "$F" -eq 0 ] || exit 1
