#!/usr/bin/env bash
# proxy-node 回归套件
#
# 设计原则(踩过的坑, 别改回去):
#   1) 只做静态检查 + 把函数体抽出来在沙箱里跑, 绝不真的安装 / 起服务 / 改 iptables。
#   2) 不用 eval 拼测试桩; 路径只出现在 bash 变量里, 不进 sed 的替换串(Windows
#      下 mktemp 可能给出反斜杠路径, 会毁掉 sed)。
#   3) 抽出来的函数体先 bash -n 再 source, 并确认每个函数都真的抽到了 —— 否则
#      "全绿" 可能只是空文件。
#   4) 断言不许出现 "没输出 = 通过": 桩本身也要被验证是活的。
set -uo pipefail

# Git Bash 下 mktemp 默认吐出带盘符的 Windows 路径: 既会触发本机删除守卫,
# Windows Python 也认不出这个路径。统一到 /tmp(Linux CI 本来就是 /tmp)。
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi

cd "$(dirname "$0")/.." || exit 1
SRC=setup.sh
PASS=0
FAIL=0

say(){ printf '%s\n' "$*"; }
pass(){ printf 'PASS %s\n' "$*"; PASS=$((PASS + 1)); }
fail(){ printf 'FAIL %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
t(){ if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got=[$2] want=[$3])"; fi; }
has(){ case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
no(){ case "$1" in *"$2"*) echo no ;; *) echo yes ;; esac; }
yesno(){ t "$1" "$2" yes; }

TD=$(mktemp -d 2>/dev/null) || { echo "无法创建临时目录"; exit 1; }
trap 'rm -rf "$TD" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------- 1. 静态检查
say "== 1. 语法 / 一致性 / 版本 =="

bash -n "$SRC" 2>/dev/null && pass "bash -n setup.sh" || fail "bash -n setup.sh"
if [ -f ../setup-proxy.sh ]; then
  bash -n ../setup-proxy.sh 2>/dev/null && pass "bash -n setup-proxy.sh" || fail "bash -n setup-proxy.sh"
  a=$(md5sum "$SRC" | awk '{print $1}')
  b=$(md5sum ../setup-proxy.sh | awk '{print $1}')
  t "setup.sh 与外层副本逐字节一致" "$a" "$b"
else
  say "SKIP 外层副本不存在(CI 场景, 仓库内只有 setup.sh)"
fi

VER=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$SRC" | head -1)
EPOCH=$(sed -n 's/^SCRIPT_EPOCH="\([^"]*\)".*/\1/p' "$SRC" | head -1)
t "SCRIPT_VERSION" "$VER" "1.0.1"
t "SCRIPT_EPOCH" "$EPOCH" "5"
t "version 子命令" "$(bash "$SRC" version 2>/dev/null)" "proxy-node v1.0.1 (2026-11-11)"

# 去掉整行注释再查: 我们自己的说明文字里会提到老的写法, 那不算代码。
CODE=$(sed '/^[[:space:]]*#/d' "$SRC")
yesno "代码里不再 source state.env" "$(no "$CODE" '. "$STATE_FILE"')"
yesno "healthcheck 里不再 source state.env" "$(no "$CODE" '. "$ST"')"
yesno "订阅 unit 用 EnvironmentFile" "$(has "$CODE" 'EnvironmentFile=-${STATE_DIR}/sub.env')"
yesno "订阅 unit 不再明文写 SUB_TOKEN" "$(no "$CODE" 'Environment=SUB_TOKEN=')"
yesno "一键命令用 mktemp 随机路径" "$(has "$CODE" 'mktemp /tmp/pn.XXXXXXXXXX')"
yesno "文档一键命令用 mktemp" "$(has "$(cat README.md)" 'mktemp /tmp/pn.XXXXXXXXXX')"
yesno "docs 一键命令用 mktemp" "$(has "$(cat docs/index.html)" 'mktemp /tmp/pn.XXXXXXXXXX')"
yesno "TUIC 不再被当 TCP+UDP 放行" "$(no "$CODE" '${TUIC_PORT}/tcp')"
yesno "sysctl -p 返回码被接住" "$(has "$CODE" 'sysctl -p /etc/sysctl.d/99-proxy-optimize.conf 2>&1); sysrc=$?')"
yesno "sysctl 逐项回读" "$(has "$CODE" 'sysctl -n "$k"')"
yesno "端口跳跃规则会枚举清理" "$(has "$CODE" 'hop_cleanup_rules')"
yesno "防火墙规则会撤回" "$(has "$CODE" 'firewall_undo')"
yesno "clean 会删句柄数配置" "$(has "$CODE" '99-proxy-nofile.conf')"
yesno "clean 会删旧 hysteria.service" "$(has "$CODE" '/etc/systemd/system/hysteria.service')"
yesno "自更新有多源哈希交叉比对" "$(has "$CODE" 'fetch_script_verified')"
yesno "base64 失败会中止" "$(has "$CODE" '订阅 base64 编码失败')"
yesno "不再开 ip_forward" "$(no "$CODE" 'net.ipv4.ip_forward=1')"

# ---- v1.0.1 逐文件复查后的加固(静态闸门) ----
yesno "凭据键白名单已定义" "$(has "$CODE" 'CRED_KEYS="HY2_PASS')"
yesno "load_state 走凭据字符检查" "$(has "$CODE" 'safe_cred_scalars')"
yesno "非法端口回退默认端口" "$(has "$CODE" '_d=$(port_default "$_k")')"
yesno "重置有 EXIT 回滚 trap" "$(has "$CODE" 'trap _reset_rollback EXIT')"
yesno "重置成功会撤销 trap" "$(has "$CODE" 'trap - EXIT')"
yesno "诊断路径闸门可独立验证" "$(has "$CODE" 'diag_out_path(){')"
yesno "诊断拒绝符号链接" "$(has "$CODE" '[ ! -L "$out" ]')"
yesno "诊断失败原因不会被子 shell 吞掉" "$(has "$CODE" 'diag_out_path "${1:-}" || die "${DIAG_PATH_ERR}"')"
yesno "订阅端口纳入防火墙放行" "$(has "$CODE" '${SUB_PORT}/tcp')"
yesno "向导用 read -ra 避免 glob" "$(has "$CODE" 'read -ra toks <<< "$sel"')"
yesno "菜单重新部署会查远端版本" "$(has "$CODE" 'f|F) CLEAN=1; export CLEAN; maybe_self_update install; cmd_install ;;')"
# 命令生成器的 P1: 旧写法直接把输入框内容拼进 root 命令, 必须被反断言钉死。
DOCS=$(cat docs/index.html)
yesno "docs 生成器有非法值收集" "$(has "$DOCS" 'var ISSUES = [];')"
yesno "docs q() 无条件单引号包裹" "$(has "$DOCS" 'String(v == null ? "" : v).replace')"
yesno "docs 端口值过白名单" "$(has "$DOCS" 'var v = safePort(val(f.port), f.name + " 端口");')"
yesno "docs 跳跃区间过白名单" "$(has "$DOCS" 'var hop = safeText(val("hop"), RE_HOP,')"
yesno "docs 常量也经 q()" "$(has "$DOCS" 'env.push("SUB_HTTP=" + q("1"));')"
yesno "docs 不再直接拼 HY2_HOP" "$(no "$DOCS" '"HY2_HOP=" + val("hop")')"
yesno "docs 不再直接拼 SUB_PORT" "$(no "$DOCS" '"SUB_PORT=" + val("subPort")')"

# 版本引用对齐
yesno "README 向导标题对齐 v1.0.1" "$(has "$(cat README.md)" 'Proxy Node Installer v1.0.1')"
yesno "docs badge 对齐 v1.0.1" "$(has "$(cat docs/index.html)" 'class="badge">v1.0.1')"

# 敏感信息扫描: 只查明显像令牌的字面量
SECRETS=$(grep -nE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}' \
            "$SRC" README.md docs/index.html 2>/dev/null | head -5)
t "源码/文档无硬编码凭据" "${SECRETS:-}" ""

if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  git diff --check >/dev/null 2>&1 && pass "git diff --check" || fail "git diff --check"
fi

# ---------------------------------------------------------------- 2. 通用 harness 生成
# $1 = 输出文件, 其余 = 要从 SRC 抽取的函数名
mk_harness(){
  local h="$1"; shift
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'STATE_DIR="$1"; STATE_FILE="$STATE_DIR/state.env"'
    echo 'warn(){ :; }; ok(){ :; }; info(){ :; }; err(){ :; }'
    echo 'die(){ printf "DIE: %s\n" "$*" >&2; exit 9; }'
    echo 'pass(){ printf "PASS %s\n" "$*"; }'
    echo 'bad(){ printf "FAIL %s\n" "$*"; }'
    echo 't(){ if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 (got=[$2] want=[$3])"; fi; }'
    echo 'yesno(){ t "$1" "$2" yes; }'
    echo 'r(){ if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }'
    echo 'rej(){ if "$@" >/dev/null 2>&1; then echo no; else echo yes; fi; }'
    echo 'say(){ printf "NOTE %s\n" "$*"; }'
    grep '^STATE_KEYS=' "$SRC"
    grep '^CRED_KEYS=' "$SRC"
    grep '^FW_RULES=' "$SRC"
    local fn
    for fn in "$@"; do
      awk -v n="$fn" '$0 ~ "^" n "\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC"
    done
  } > "$h"
  if ! bash -n "$h" 2>/dev/null; then
    fail "harness 语法错误: $h"; return 1
  fi
  for fn in "$@"; do
    if ! grep -q "^${fn}(){" "$h" 2>/dev/null; then
      fail "函数抽取失败(测试桩坏了, 结果不可信): $fn"; return 1
    fi
  done
  return 0
}

run_harness(){
  local h="$1" sd="$2" out rc p f
  out=$(bash "$h" "$sd" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^(PASS|FAIL|DIE)' || true
  p=$(printf '%s\n' "$out" | grep -c '^PASS ' || true)
  f=$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)
  PASS=$((PASS + p)); FAIL=$((FAIL + f))
  [ "$rc" -eq 0 ] || fail "harness 非零退出($rc): $h"
}

# ---------------------------------------------------------------- 3. P0: state.env 注入链
say "== 3. state.env 安全回归 =="
SD="$TD/state"; mkdir -p "$SD"
H="$TD/state-h.sh"
if mk_harness "$H" sh_quote state_decode state_line state_get safe_state_scalars \
              safe_cred_scalars valid_bind valid_domain valid_port sanitize_node_name \
              load_state save_state update_state_kv; then
cat >> "$H" <<'BODY'

MARK="$STATE_DIR/PWNED"
INJ="socks5://u:p@1.2.3.4:1080'; touch ${MARK}; #"

t "sh_quote 普通值" "$(sh_quote hello)" "'hello'"
t "state_decode 普通值" "$(state_decode "'hello'")" "hello"
t "单引号往返" "$(state_decode "$(sh_quote "a'b")")" "a'b"
t "反斜杠往返" "$(state_decode "$(sh_quote 'back\slash')")" 'back\slash'
t "美元/反引号往返" "$(state_decode "$(sh_quote 'x$(id)`id`')")" 'x$(id)`id`'
t "换行被压成空格" "$(sh_quote "line
break")" "'line break'"

# valid_bind / valid_domain
yesno "valid_bind 127.0.0.1" "$(r valid_bind 127.0.0.1)"
yesno "valid_bind ::1" "$(r valid_bind ::1)"
# 注意方向: r() 对"拒绝"返回 no, 所以拒绝类断言走 rej(), 不要写成 yesno "$(r ...)",
# 否则产品代码正确拒绝反而被判成失败(第一版踩过)。
yesno "valid_bind 拒绝注入串" "$(rej valid_bind 'evil; touch /tmp/x')"
yesno "valid_bind 拒绝 999.1.1.1" "$(rej valid_bind 999.1.1.1)"
yesno "valid_domain 接受 www.example.com" "$(r valid_domain www.example.com)"
yesno "valid_domain 拒绝尾点 a.com." "$(rej valid_domain 'a.com.')"

# ---- P0: 写入带注入串的状态, 从任何路径读都不会执行 ----
EGRESS_URL="$INJ"
NODE_NAME="Node"
SUB_BIND="127.0.0.1"
PROTOCOLS="reality,hy2"
XRAY_VERSION="26.3.27"
INSTALLED_AT="2026-11-10 00:00:00"
save_state

if bash -n "$STATE_FILE" 2>/dev/null; then pass "写出的是合法 shell(证明 bash -n 不是防线)"; else bad "写出的 state.env 语法坏了"; fi
# grep -c 无匹配时会输出 0 但返回 1, 接 `|| echo 0` 会得到 "0\n0"(假 FAIL)。
n=$(grep -c '^EGRESS_URL=' "$STATE_FILE" 2>/dev/null || true)
t "EGRESS_URL 只有一行" "${n:-0}" "1"
n=$(grep -c '^touch ' "$STATE_FILE" 2>/dev/null || true)
t "state.env 里没有多出的命令行" "${n:-0}" "0"

# 双保险: 就算有人绕过 load_state 直接 source, 也不该执行命令
( . "$STATE_FILE" ) >/dev/null 2>&1
if [ ! -e "$MARK" ]; then pass "直接 source 也不执行注入(sh_quote 生效)"; else bad "直接 source 仍会执行注入"; fi
rm -f "$MARK"

EGRESS_URL="__sentinel__"
if load_state; then pass "load_state 读回"; else bad "load_state 返回失败"; fi
# v1.0.1 起 load_state 会调 safe_cred_scalars: 带 shell 元字符的 EGRESS_URL
# 直接丢弃, 而不是"原样读回去等下游转义"。断言必须跟着改, 否则会把新增的
# 防线当成回归。底层数据层本身仍要求能原样往返。
t "注入串被白名单丢弃(不进配置)" "$EGRESS_URL" ""
t "state_decode 仍能原样还原注入串" "$(state_decode "$(sh_quote "$INJ")")" "$INJ"
if [ ! -e "$MARK" ]; then pass "load_state 不执行注入"; else bad "load_state 执行了注入(P0 回归)"; fi

# 非白名单键的命令照样不该执行
printf "EVIL='x'; touch %s; #\n" "$MARK" >> "$STATE_FILE"
load_state >/dev/null 2>&1
if [ ! -e "$MARK" ]; then pass "非白名单行被忽略, 不执行"; else bad "非白名单行被执行"; fi
t "state_get 拒绝非白名单键" "$(r state_get "$STATE_FILE" EVIL)" "no"

# ---- update_state_kv: 引号/管道/&/反斜杠/换行都不能写坏文件 ----
# 脏值写进文件必须仍是合法 shell 且不产生多余命令行; 读回来时会被
# safe_cred_scalars 丢弃, 所以断言"被清空"而不是"原样往返"。
for v in "a'b" 'x|y&z/\' "$INJ" "line
break" "100% \$HOME"; do
  update_state_kv EGRESS_URL "$v"
  want=$(printf '%s' "$v" | tr '\n\r\t' '  ')
  if bash -n "$STATE_FILE" 2>/dev/null; then pass "脏值写出合法 shell [$want]"; else bad "update_state_kv 写出坏语法: [$want]"; fi
  n=$(grep -c '^touch ' "$STATE_FILE" 2>/dev/null || true)
  t "脏值不产生多出的命令行 [$want]" "${n:-0}" "0"
  EGRESS_URL="__sentinel__"
  load_state >/dev/null 2>&1
  t "脏值被白名单丢弃 [$want]" "$EGRESS_URL" ""
done
# 合法 URL 必须完整往返, 否则白名单把正常功能也砍了。
update_state_kv EGRESS_URL "socks5://u:p@1.2.3.4:1080"
EGRESS_URL=""
load_state >/dev/null 2>&1
t "合法 EGRESS_URL 完整往返" "$EGRESS_URL" "socks5://u:p@1.2.3.4:1080"
n=$(grep -c '^EGRESS_URL=' "$STATE_FILE" 2>/dev/null || true)
t "update_state_kv 不重复追加行" "${n:-0}" "1"
before=$(wc -l < "$STATE_FILE")
if update_state_kv NOT_A_KEY x; then bad "update_state_kv 接受了非白名单键"; else pass "update_state_kv 拒绝非白名单键"; fi
after=$(wc -l < "$STATE_FILE")
t "拒绝后文件行数不变" "$after" "$before"
BODY
  run_harness "$H" "$SD"
fi

# ---------------------------------------------------------------- 4. 端口跳跃规则枚举清理
say "== 4. 端口跳跃 / 防火墙规则回归 =="
SD2="$TD/rules"; mkdir -p "$SD2" "$SD2/bin"
H2="$TD/rules-h.sh"
if mk_harness "$H2" hop_cleanup_rules setup_firewall firewall_undo; then
cat >> "$H2" <<'BODY'

IPT_RULES="$STATE_DIR/ipt.rules"
IPT_LOG="$STATE_DIR/ipt.log"
UFW_LOG="$STATE_DIR/ufw.log"
: > "$IPT_LOG"; : > "$UFW_LOG"
cat > "$IPT_RULES" <<'RULES'
-P PREROUTING ACCEPT
-A PREROUTING -p udp -m udp --dport 20000:30000 -j REDIRECT --to-ports 443
-A PREROUTING -p udp -m udp --dport 30000:40000 -j REDIRECT --to-ports 443
-A PREROUTING -p tcp -m tcp --dport 8443 -j REDIRECT --to-ports 1080
-A PREROUTING -p udp -m udp --dport 8443 -j REDIRECT --to-ports 443
RULES

# 桩本身必须是活的: 先确认它能吐出规则
iptables(){
  case "$*" in
    "-t nat -S"*) cat "$IPT_RULES" ;;
    "-t nat -D"*) printf '%s\n' "$*" >> "$IPT_LOG" ;;
  esac
  return 0
}
n=$(iptables -t nat -S | grep -c '^-A PREROUTING ' || true)
t "iptables 桩可用(4 条规则)" "$n" "4"

hop_cleanup_rules
n=$(wc -l < "$IPT_LOG")
t "只删 2 条区间规则" "$n" "2"
yesno "删掉旧区间 20000:30000" "$(case "$(cat "$IPT_LOG")" in *20000:30000*) echo yes;; *) echo no;; esac)"
yesno "删掉旧区间 30000:40000" "$(case "$(cat "$IPT_LOG")" in *30000:40000*) echo yes;; *) echo no;; esac)"
yesno "不碰 tcp 规则" "$(case "$(cat "$IPT_LOG")" in *'-p tcp'*) echo no;; *) echo yes;; esac)"
yesno "不碰单端口 udp 规则" "$(case "$(cat "$IPT_LOG")" in *'--dport 8443 -j'*) echo no;; *) echo yes;; esac)"

# ---- setup_firewall: 只增不减的旧行为必须被修掉 ----
proto_on(){ case ",${PROTOCOLS}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
VLESS_PORT=443; HY2_PORT=443; SS2022_PORT=8445; ANYTLS_PORT=8444; TUIC_PORT=8443
PROTOCOLS="reality,hy2,tuic"
setup_firewall
yesno "首轮放行 443/tcp" "$(case "$(cat "$UFW_LOG")" in *'allow 443/tcp'*) echo yes;; *) echo no;; esac)"
yesno "首轮放行 443/udp" "$(case "$(cat "$UFW_LOG")" in *'allow 443/udp'*) echo yes;; *) echo no;; esac)"
yesno "TUIC 只放行 UDP" "$(case "$(cat "$UFW_LOG")" in *'allow 8443/udp'*) echo yes;; *) echo no;; esac)"
yesno "TUIC 没有多放行 TCP" "$(case "$(cat "$UFW_LOG")" in *'allow 8443/tcp'*) echo no;; *) echo yes;; esac)"

: > "$UFW_LOG"
PROTOCOLS="reality"
setup_firewall
yesno "换协议后撤回 443/udp" "$(case "$(cat "$UFW_LOG")" in *'delete allow 443/udp'*) echo yes;; *) echo no;; esac)"
yesno "换协议后撤回 8443/udp" "$(case "$(cat "$UFW_LOG")" in *'delete allow 8443/udp'*) echo yes;; *) echo no;; esac)"
t "FW_RULES 记录当前放行项" "$(cat "$FW_RULES")" "443/tcp"

: > "$UFW_LOG"
firewall_undo
yesno "clean 撤回 443/tcp" "$(case "$(cat "$UFW_LOG")" in *'delete allow 443/tcp'*) echo yes;; *) echo no;; esac)"
if [ -f "$FW_RULES" ]; then bad "firewall_undo 没删记录文件"; else pass "firewall_undo 删掉记录文件"; fi
BODY

  # ufw 必须是外部命令(command -v 才能命中)
  cat > "$SD2/bin/ufw" <<'EOS'
#!/usr/bin/env bash
case "$1" in status) echo "Status: active" ;; *) printf '%s\n' "$*" >> "$UFW_LOG" ;; esac
exit 0
EOS
  chmod +x "$SD2/bin/ufw"
  UFW_LOG="$SD2/ufw.log" PATH="$SD2/bin:$PATH" bash "$H2" "$SD2" > "$TD/rules.out" 2>&1
  rc=$?
  cat "$TD/rules.out" | grep -E '^(PASS|FAIL|DIE)' || true
  p=$(grep -c '^PASS ' "$TD/rules.out" || true)
  f=$(grep -c '^FAIL ' "$TD/rules.out" || true)
  PASS=$((PASS + p)); FAIL=$((FAIL + f))
  [ "$rc" -eq 0 ] || fail "规则 harness 非零退出($rc)"
fi

# ---------------------------------------------------------------- 5. 订阅 HTTP 服务(真实本地请求)
say "== 5. 订阅 HTTP 白名单回归 =="
PY=$(command -v python3 2>/dev/null || echo "")
# Windows Python 不认 MSYS 的 /tmp 路径(os.path.realpath('/tmp') == 'C:\tmp'),
# 传给它的脚本路径 / 订阅根目录都要转成原生路径; Linux CI 上原样返回。
winpath(){ if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
if [ -n "$PY" ]; then
  # 源码里 cat 行带缩进, 正则必须允许前导空格; 否则抽到空文件 = 假绿。
  awk '/^[[:space:]]*cat > "\$srv" <<.PYSRV.$/{p=1;next} p&&/^PYSRV$/{exit} p{print}' "$SRC" > "$TD/sub_server.py"
  SUBLINES=$(wc -l < "$TD/sub_server.py")
  if [ "$SUBLINES" -gt 40 ] && grep -q 'hmac.compare_digest' "$TD/sub_server.py" \
     && grep -q 'ALLOW = {' "$TD/sub_server.py"; then
    pass "抽出订阅服务源码(${SUBLINES} 行, 桩是活的)"
    SUBROOT="$TD/sub"; mkdir -p "$SUBROOT/tok123"
    printf 'hello\n' > "$SUBROOT/tok123/clash.yaml"
    printf 'secret\n' > "$SUBROOT/tok123/private.txt"

    # 单进程内起服务 + 发真实 HTTP 请求。以前用 `python server.py &` + curl:
    # 后台服务会挂住整个命令直到被 SIGTERM, 而且 Windows Python 打不开 MSYS
    # 形式的脚本路径。这里用 importlib 加载产品源码(__name__ != "__main__",
    # main() 不会自动跑), 线程起 ThreadingHTTPServer, http.client 发未经
    # 规范化的原始路径(等价 curl --path-as-is), 结束前 shutdown, 不留孤儿进程。
    cat > "$TD/sub_test.py" <<'PYTEST'
import http.client, importlib.util, os, sys, threading

root, src = sys.argv[1], sys.argv[2]
os.environ["SUB_ROOT"] = root
os.environ["SUB_TOKEN"] = "tok123"
spec = importlib.util.spec_from_file_location("sub_server_under_test", src)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

srv = mod.ThreadingHTTPServer(("127.0.0.1", 0), mod.Handler)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()


def status(path):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        resp.read()
        return resp.status
    except Exception:
        return 0
    finally:
        conn.close()


cases = [
    ("/tok123/clash.yaml", 200, "正确 token + 白名单文件 -> 200"),
    ("/wrongtok/clash.yaml", 404, "错 token -> 404"),
    ("/tok123/private.txt", 404, "非白名单文件 -> 404"),
    ("/", 404, "根路径不列目录 -> 404"),
    ("/tok123/../clash.yaml", 404, "目录穿越 -> 404"),
]
bad = 0
for path, want, name in cases:
    got = status(path)
    print("%s %s (got=%s want=%s)" % ("PASS" if got == want else "FAIL", name, got, want))
    if got != want:
        bad += 1
alive = status("/tok123/clash.yaml") == 200
print("PASS 订阅服务确实起来了(桩可用)" if alive else "FAIL 订阅服务没响应(桩坏了)")
if not alive:
    bad += 1
srv.shutdown()
srv.server_close()
sys.exit(1 if bad else 0)
PYTEST
    # timeout 是防挂死闸门: 服务端万一没退出, 不能让整个套件被拖到工具超时。
    # -u 保证超时时 sub.out 里仍能看到进度, 而不是一片空白。
    timeout 30 "$PY" -u "$(winpath "$TD/sub_test.py")" \
      "$(winpath "$SUBROOT")" "$(winpath "$TD/sub_server.py")" > "$TD/sub.out" 2>&1
    rc=$?
    grep -E '^(PASS|FAIL)' "$TD/sub.out" || true
    p=$(grep -c '^PASS ' "$TD/sub.out" || true)
    f=$(grep -c '^FAIL ' "$TD/sub.out" || true)
    PASS=$((PASS + p)); FAIL=$((FAIL + f))
    if [ "$rc" -ne 0 ]; then
      cat "$TD/sub.out" >&2
      fail "订阅服务驱动脚本非零退出(rc=${rc}, 124=超时/挂死)"
    fi
  else
    fail "订阅服务源码抽取失败(测试桩坏了)"
  fi
else
  say "SKIP python3 不可用"
fi

# ---------------------------------------------------------------- 6. v1.0.1 加固行为回归
say "== 6. v1.0.1 加固行为回归 =="
SD6="$TD/v101"; mkdir -p "$SD6"
H6="$TD/v101-h.sh"
if mk_harness "$H6" port_default safe_cred_scalars valid_bind valid_port \
              diag_out_path _reset_rollback; then
cat >> "$H6" <<'BODY'

# ---- port_default: 非法端口必须回退具体默认值, 绝不能清空 ----
t "VLESS_PORT 默认" "$(port_default VLESS_PORT)" "443"
t "HY2_PORT 默认" "$(port_default HY2_PORT)" "443"
t "SS2022_PORT 默认" "$(port_default SS2022_PORT)" "8445"
t "ANYTLS_PORT 默认" "$(port_default ANYTLS_PORT)" "8444"
t "TUIC_PORT 默认" "$(port_default TUIC_PORT)" "8443"
t "SUB_PORT 默认空" "$(port_default SUB_PORT)" ""
t "未知键返回空" "$(port_default NO_SUCH_PORT)" ""

# ---- safe_cred_scalars: 手改 state.env 的脏凭据必须被丢弃 ----
HY2_PASS="ab'cd; touch /tmp/pwn #"
SUB_TOKEN="tok;rm -rf /"
TUIC_UUID="ok-UUID_123"
EGRESS_URL="socks5://u:p@1.2.3.4:1080'; touch /tmp/pwn; #"
safe_cred_scalars
t "带引号/分号的 HY2_PASS 被清空" "$HY2_PASS" ""
t "带分号的 SUB_TOKEN 被清空" "$SUB_TOKEN" ""
t "合法 TUIC_UUID 保留" "$TUIC_UUID" "ok-UUID_123"
t "EGRESS_URL 注入串被忽略" "$EGRESS_URL" ""
EGRESS_URL="socks5://u:p@1.2.3.4:1080"
safe_cred_scalars
t "合法 EGRESS_URL 保留" "$EGRESS_URL" "socks5://u:p@1.2.3.4:1080"

# ---- valid_bind: 伪 IPv6 / 超长 / 注入串 ----
yesno "valid_bind 接受 127.0.0.1" "$(r valid_bind 127.0.0.1)"
yesno "valid_bind 接受 ::1" "$(r valid_bind ::1)"
yesno "valid_bind 拒绝 ::::" "$(rej valid_bind '::::')"
yesno "valid_bind 拒绝 9 组 IPv6" "$(rej valid_bind '1:2:3:4:5:6:7:8:9')"
yesno "valid_bind 拒绝超长地址" "$(rej valid_bind "$(printf '1%.0s' {1..60})")"
yesno "valid_bind 拒绝端口形式" "$(rej valid_bind '1.2.3.4:80')"
yesno "valid_port 接受 443" "$(r valid_port 443)"
yesno "valid_port 拒绝 70000" "$(rej valid_port 70000)"

# ---- diag_out_path: root 写文件的路径闸门 ----
if diag_out_path "$STATE_DIR/report.txt"; then
  t "接受 /tmp 下的报告路径" "$DIAG_OUT" "$STATE_DIR/report.txt"
else bad "合法报告路径被拒绝: $DIAG_PATH_ERR"; fi
yesno "拒绝 /etc/shadow" "$(rej diag_out_path /etc/shadow)"
yesno "拒绝 /etc/passwd" "$(rej diag_out_path /etc/passwd)"
yesno "拒绝含 .. 的路径" "$(rej diag_out_path '/root/../etc/passwd')"
yesno "拒绝不存在的目录" "$(rej diag_out_path "$STATE_DIR/nope/x.txt")"
yesno "拒绝空文件名" "$(rej diag_out_path '/tmp/')"
if diag_out_path ""; then
  case "$DIAG_OUT" in /root/proxy-diag-*.txt) pass "默认报告路径在 /root 下" ;; *) bad "默认路径不对: $DIAG_OUT" ;; esac
else bad "默认报告路径被拒绝"; fi
if ln -s /etc/passwd "$STATE_DIR/link" 2>/dev/null && [ -L "$STATE_DIR/link" ]; then
  yesno "拒绝符号链接目标" "$(rej diag_out_path "$STATE_DIR/link")"
else
  say "SKIP 符号链接(本机不允许创建 symlink)"
fi

# ---- _reset_rollback: 中途失败要把清空前的状态整份恢复 ----
BK="${STATE_DIR}.before-reset"
mkdir -p "$BK"
printf "UUID='keep-me'\n" > "$BK/state.env"
printf "dev1|uuid1\n" > "$BK/users.txt"
rm -f "$STATE_DIR/state.env" "$STATE_DIR/users.txt"
_RESET_BACKUP="$BK"
_reset_rollback
t "回滚恢复 state.env" "$(cat "$STATE_DIR/state.env" 2>/dev/null)" "UUID='keep-me'"
t "回滚恢复 users.txt" "$(cat "$STATE_DIR/users.txt" 2>/dev/null)" "dev1|uuid1"
_RESET_BACKUP=""
BODY
  run_harness "$H6" "$SD6"
fi

# ---------------------------------------------------------------- 7. 命令生成器(真实 JS 行为)
say "== 7. 命令生成器注入防护 =="
NODE=$(command -v node 2>/dev/null || echo "")
if [ -n "$NODE" ]; then
  cat > "$TD/docs_test.js" <<'JSTEST'
const fs = require("fs"), vm = require("vm");
const html = fs.readFileSync("docs/index.html", "utf8");
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.log("FAIL 抽不到 <script> (测试桩坏了)"); process.exit(1); }
const code = m[1].replace(/\}\)\(\);\s*$/,
  "globalThis.__PN__={q:q,build:build,render:render,state:state};})();");
if (code === m[1]) { console.log("FAIL 找不到 IIFE 结尾 (测试桩坏了)"); process.exit(1); }

const store = {};
function elt(id) {
  if (!store[id]) store[id] = {
    id, value: "", checked: false, innerHTML: "", textContent: "",
    classList: { add(){}, remove(){}, toggle(){} },
    addEventListener(){}, querySelectorAll(){ return []; },
    closest(){ return null; }, dataset: {}
  };
  return store[id];
}
const defaults = {
  pReality:true, pHy2:true, pSs2022:false, pAnytls:false, pTuic:false,
  vlessPort:"443", hy2Port:"443", ss2022Port:"8445", anytlsPort:"8444", tuicPort:"8443",
  destCustom:"", hop:"", subPort:"", nodeName:"Node", subBind:"127.0.0.1",
  obfs:false, subHttp:false
};
function reset(){
  for (const k of Object.keys(store)) delete store[k];
  for (const k of Object.keys(defaults)) {
    const v = defaults[k];
    if (typeof v === "boolean") elt(k).checked = v; else elt(k).value = v;
  }
}
const sandbox = {
  document: { getElementById: elt, createElement: () => ({ style:{}, select(){} }),
              body: { appendChild(){}, removeChild(){} } },
  navigator: {}, window: { isSecureContext: false },
  setTimeout: () => 0, console
};
vm.createContext(sandbox);
vm.runInContext(code, sandbox);
const P = sandbox.__PN__;
if (!P || typeof P.build !== "function") {
  console.log("FAIL 没拿到生成器函数 (测试桩坏了)"); process.exit(1);
}
let bad = 0;
function ck(name, cond, extra){
  console.log((cond?"PASS ":"FAIL ")+name+(extra?" :: "+extra:""));
  if(!cond) bad++;
}

reset(); P.state.dest = "auto"; P.state.mode = "keep";
const base = P.build();
ck("默认命令仍用 mktemp 随机路径", base.indexOf("mktemp /tmp/pn.XXXXXXXXXX") >= 0);
ck("默认命令仍做 bash -n", base.indexOf('bash -n "$PN_TMP"') >= 0);
ck("默认命令落点为 install", /bash \/root\/setup-proxy\.sh install$/.test(base));
ck("q() 无条件单引号", P.q("abc") === "'abc'", "got="+P.q("abc"));
ck("q() 转义内部单引号", P.q("a'b") === "'a'\\''b'", "got="+P.q("a'b"));

// 所有输入框塞 shell 元字符: 命令里不能出现裸分号, 也不能带出这些值
reset(); P.state.dest = "custom"; P.state.mode = "keep";
elt("hop").value = "20000-30000;id";
elt("destCustom").value = "www.example.com;id";
elt("nodeName").value = "N; touch /tmp/pwn";
elt("subPort").value = "8080;id";
elt("vlessPort").value = "443;id";
elt("subHttp").checked = true;
const evil = P.build();
ck("注入输入不会带出裸分号", evil.indexOf(";") < 0, "cmd="+evil.slice(0,150));
ck("注入输入被丢弃(HY2_HOP)", evil.indexOf("HY2_HOP=") < 0);
ck("注入输入被丢弃(REALITY_DEST)", evil.indexOf("REALITY_DEST=") < 0);
ck("注入输入被丢弃(NODE_NAME)", evil.indexOf("NODE_NAME=") < 0);
ck("注入输入被丢弃(SUB_PORT)", evil.indexOf("SUB_PORT=") < 0);
ck("注入输入被丢弃(VLESS_PORT)", evil.indexOf("VLESS_PORT=") < 0);
ck("注入后命令仍完整可执行", evil.indexOf("mktemp /tmp/pn.XXXXXXXXXX") >= 0);
P.render();
ck("render 提示参数不合法", store.sum.innerHTML.indexOf("参数不合法") >= 0);

// 合法自定义值: env 前缀里每个 KEY= 的值都必须被单引号包住
reset(); P.state.dest = "custom"; P.state.mode = "keep";
elt("pHy2").checked = false;
elt("destCustom").value = "www.samsung.com";
elt("nodeName").value = "My Node 一号";
elt("hop").value = "20000-30000";
elt("subHttp").checked = true;
elt("subPort").value = "8080";
elt("subBind").value = "0.0.0.0";
elt("vlessPort").value = "8443";
const good = P.build();
// 环境变量前缀在命令末尾(prefix 只作用于最后那一步 bash), 不在开头。
// 从 "chmod 755 ... && " 之后截到 "bash /root/setup-proxy.sh" 之前。
const anchor = "chmod 755 /root/setup-proxy.sh && ";
const tail = good.slice(good.indexOf(anchor) + anchor.length);
const envPart = tail.slice(0, tail.lastIndexOf("bash /root/setup-proxy.sh"));
ck("找到 env 前缀锚点", good.indexOf(anchor) >= 0 && tail.lastIndexOf("bash /root/setup-proxy.sh") >= 0);
const quoted = envPart.match(/[A-Z][A-Z0-9_]*='(?:[^']|'\\'')*'/g) || [];
ck("合法输入确实生成了 env 前缀", quoted.length >= 7, "count="+quoted.length);
const leftover = envPart.replace(/[A-Z][A-Z0-9_]*='(?:[^']|'\\'')*'\s*/g, "").trim();
ck("env 前缀里没有未加引号的赋值", leftover === "", "leftover="+leftover);
ck("HY2_HOP 被保留", good.indexOf("HY2_HOP='20000-30000'") >= 0);
ck("中文节点名被保留", good.indexOf("NODE_NAME='My Node 一号'") >= 0);
ck("自定义端口被保留", good.indexOf("VLESS_PORT='8443'") >= 0);
ck("SUB_BIND 被保留", good.indexOf("SUB_BIND='0.0.0.0'") >= 0);
process.exit(bad ? 1 : 0);
JSTEST
  timeout 30 "$NODE" "$(winpath "$TD/docs_test.js")" > "$TD/docs.out" 2>&1
  rc=$?
  grep -E '^(PASS|FAIL)' "$TD/docs.out" || true
  p=$(grep -c '^PASS ' "$TD/docs.out" || true)
  f=$(grep -c '^FAIL ' "$TD/docs.out" || true)
  PASS=$((PASS + p)); FAIL=$((FAIL + f))
  if [ "$rc" -ne 0 ]; then
    cat "$TD/docs.out" >&2
    fail "命令生成器驱动非零退出(rc=${rc}, 124=超时/挂死)"
  fi
else
  say "SKIP node 不可用(静态断言已在第 1 节覆盖)"
fi

# ---------------------------------------------------------------- 汇总
say ""
say "================================================"
say "  PASS ${PASS}   FAIL ${FAIL}"
say "================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
