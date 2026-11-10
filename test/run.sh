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
t "SCRIPT_VERSION" "$VER" "1.0.0"
t "SCRIPT_EPOCH" "$EPOCH" "4"
t "version 子命令" "$(bash "$SRC" version 2>/dev/null)" "proxy-node v1.0.0 (2026-11-10)"

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

# 版本引用对齐
yesno "README 向导标题对齐 v1.0.0" "$(has "$(cat README.md)" 'Proxy Node Installer v1.0.0')"
yesno "docs badge 对齐 v1.0.0" "$(has "$(cat docs/index.html)" 'class="badge">v1.0.0')"

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
    grep '^STATE_KEYS=' "$SRC"
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
              valid_bind valid_domain valid_port sanitize_node_name \
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

EGRESS_URL=""
if load_state; then pass "load_state 读回"; else bad "load_state 返回失败"; fi
t "注入串原样读回(没有被当成代码)" "$EGRESS_URL" "$INJ"
if [ ! -e "$MARK" ]; then pass "load_state 不执行注入"; else bad "load_state 执行了注入(P0 回归)"; fi

# 非白名单键的命令照样不该执行
printf "EVIL='x'; touch %s; #\n" "$MARK" >> "$STATE_FILE"
load_state >/dev/null 2>&1
if [ ! -e "$MARK" ]; then pass "非白名单行被忽略, 不执行"; else bad "非白名单行被执行"; fi
t "state_get 拒绝非白名单键" "$(r state_get "$STATE_FILE" EVIL)" "no"

# ---- update_state_kv: 引号/管道/&/反斜杠/换行都不能写坏文件 ----
for v in "a'b" 'x|y&z/\' "$INJ" "line
break" "100% \$HOME"; do
  update_state_kv EGRESS_URL "$v"
  if bash -n "$STATE_FILE" 2>/dev/null; then :; else bad "update_state_kv 写出坏语法: [$v]"; fi
  EGRESS_URL=""
  load_state >/dev/null 2>&1
  want=$(printf '%s' "$v" | tr '\n\r\t' '  ')
  t "update_state_kv 往返 [$want]" "$EGRESS_URL" "$want"
done
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

# ---------------------------------------------------------------- 汇总
say ""
say "================================================"
say "  PASS ${PASS}   FAIL ${FAIL}"
say "================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
