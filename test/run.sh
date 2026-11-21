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
# 把一段子进程输出里的 PASS/FAIL 计数并入全局。
# 第 3 个参数是"至少应跑几条断言": 子进程若在打印任何断言前就退出(函数抽取坏、
# 语法错、提前 die), 光看 p=0/f=0/rc=0 会假绿 —— 必须按零断言判失败。
tally(){
  local out="$1" rc="$2" min="$3" label="$4" p f
  p=$(printf '%s\n' "$out" | grep -c '^PASS ' || true)
  f=$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)
  PASS=$((PASS + p)); FAIL=$((FAIL + f))
  [ "$p" -ge "$min" ] || fail "${label}: 断言数不足(${p} < ${min}), 测试桩可能没跑起来"
  [ "$rc" -eq 0 ] || fail "${label} 非零退出($rc)"
}
t(){ if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got=[$2] want=[$3])"; fi; }
has(){ case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
no(){ case "$1" in *"$2"*) echo no ;; *) echo yes ;; esac; }
yesno(){ t "$1" "$2" yes; }
# CI 里出现 SKIP 就是假绿: 工具链 / 环境能力缺失必须判失败。
# 本地开发仍允许跳过(Windows 上建不了 symlink 属正常现象)。
CI_MODE="${CI:-}"
skip(){ if [ -n "$CI_MODE" ]; then fail "$1 (CI 下不允许 SKIP)"; else say "SKIP $1"; fi; }

TD=$(mktemp -d 2>/dev/null) || { echo "无法创建临时目录"; exit 1; }
trap 'rm -rf "$TD" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------- 1. 静态检查
say "== 1. 语法 / 一致性 / 版本 =="

bash -n "$SRC" 2>/dev/null && pass "bash -n setup.sh" || fail "bash -n setup.sh"
# 仓库内始终带一份同字节的 setup-proxy.sh, 让"两份脚本是否同步"在 CI 里也
# 真的被查 —— 以前只查工作区外层那份, CI 里文件不存在就永久 SKIP, 等于假绿。
a=$(md5sum "$SRC" | awk '{print $1}')
if [ -f setup-proxy.sh ]; then
  bash -n setup-proxy.sh 2>/dev/null && pass "bash -n setup-proxy.sh" || fail "bash -n setup-proxy.sh"
  b=$(md5sum setup-proxy.sh | awk '{print $1}')
  t "setup.sh 与仓库内 setup-proxy.sh 逐字节一致" "$a" "$b"
else
  fail "仓库内缺少 setup-proxy.sh(副本一致性闸门不可跳过)"
fi
# 工作区外层那份(不入库)若存在, 顺带一起查, 防止本地开发忘了同步。
if [ -f ../setup-proxy.sh ]; then
  bash -n ../setup-proxy.sh 2>/dev/null && pass "bash -n ../setup-proxy.sh" || fail "bash -n ../setup-proxy.sh"
  c=$(md5sum ../setup-proxy.sh | awk '{print $1}')
  t "setup.sh 与工作区外层副本逐字节一致" "$a" "$c"
fi

VER=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$SRC" | head -1)
t "SCRIPT_VERSION" "$VER" "1.0"
yesno "脚本里不再有 SCRIPT_EPOCH(世代/内部修订号)" "$(no "$(cat "$SRC")" 'SCRIPT_EPOCH')"
t "version 子命令" "$(bash "$SRC" version 2>/dev/null | head -1)" "proxy-node v1.0 (2026-11-21)"
# version 输出只报版本号 + 日期, 不带任何世代号/内部修订号
yesno "version 不含世代字样" "$(no "$(bash "$SRC" version 2>/dev/null)" '世代')"

# 去掉整行注释再查: 我们自己的说明文字里会提到老的写法, 那不算代码。
CODE=$(sed '/^[[:space:]]*#/d' "$SRC")
yesno "代码里不再 source state.env" "$(no "$CODE" '. "$STATE_FILE"')"
yesno "healthcheck 里不再 source state.env" "$(no "$CODE" '. "$ST"')"
# healthcheck 必须读取并校验 REALITY_FP: 否则用户设 firefox 时探活仍用 chrome,
# 握手失败被当成服务故障, 连续2次触发无谓重启。
yesno "healthcheck 白名单含 REALITY_FP" "$(has "$CODE" 'UUID=*|REALITY_FP=*)')"
yesno "healthcheck 校验 REALITY_FP 防JSON注入" "$(has "$CODE" 'REALITY_FP=chrome ;;')"
# 探测用的临时 xray 还没监听就去 curl, 拿到的是 000, 连吃两次就判"隧道连续不可用"
# 并重启一次用户的连接 —— 探测手段自己没准备好, 却去重启被探测的服务。
yesno "healthcheck 等临时 xray 端口就绪" "$(has "$CODE" '/dev/tcp/127.0.0.1/10896')"
# 探针进程必须在起新的之前先清残留。上一轮被 systemd 超时杀掉时临时 xray 会一直
# 占着 10896: 本轮的端口等待立刻通过(连到残留进程), kill 只杀新起的那个, 残留的
# 永远留着。清理要按探针自己的配置路径匹配, 不能宽到碰正式服务。
yesno "healthcheck 起探针前清理残留进程" \
  "$(has "$CODE" "pkill -f '^/usr/local/bin/xray -c /run/_hc.json'")"
# cmd_name 改备注时 token 可能重生成, save_state 必须在 gen_sub_files 之后并重启订阅。
yesno "cmd_name 改备注后 save_state 在 gen_sub_files 之后" "$(awk '
  /^cmd_name\(\)/ { in_fn=1 }
  in_fn && /gen_sub_files/ { g=NR }
  in_fn && /save_state/   { s=NR }
  in_fn && /^}/           { in_fn=0 }
  END { print (g && s && g < s) ? "yes" : "no" }
' "$SRC")"
yesno "订阅 unit 用 EnvironmentFile" "$(has "$CODE" 'EnvironmentFile=-${STATE_DIR}/sub.env')"
yesno "订阅 unit 不再明文写 SUB_TOKEN" "$(no "$CODE" 'Environment=SUB_TOKEN=')"
# 一键命令是三处手抄的同一串(脚本 ONELINER / README / docs), 任何一处漏了一段,
# 用户在那条路径上就会撞上对应的失败。三处一起守, 防止下次只改一处。
yesno "脚本一键命令用 mktemp 随机文件" "$(has "$CODE" 'ONELINER="f=\$(mktemp)&&')"
yesno "README 一键命令用 mktemp" "$(has "$(cat README.md)" 'f=$(mktemp)')"
yesno "docs 一键命令用 mktemp" "$(has "$(cat docs/index.html)" 'f=$(mktemp)')"
yesno "脚本一键命令带超时" "$(has "$CODE" 'curl -fsSL --connect-timeout 10 -m 120')"
yesno "README 一键命令带超时" "$(has "$(cat README.md)" 'curl -fsSL --connect-timeout 10 -m 120')"
yesno "docs 一键命令带超时" "$(has "$(cat docs/index.html)" 'curl -fsSL --connect-timeout 10 -m 120')"
# 长度闸门。这条命令是用户看到的第一行东西, 每加一道"保险"都在劝退第一次用的人;
# 而"保险"这个词很容易变成"再加一条也不亏" —— 给它一个上限, 让每次加都有代价。
# 用真展开(不是数源码字符): 源码里是 ${SCRIPT_URL}, 数它没意义。
oneliner=$(SCRIPT_URL="https://raw.githubusercontent.com/smallji666/proxy-node/main/setup.sh" \
  bash -c 'eval "$(grep -m1 "^ONELINER=" setup.sh)"; printf "%s" "$ONELINER"' 2>/dev/null)
ol_len=${#oneliner}
# 下界 100 是防 eval 失败拿到空串假绿; 上界 230 是给"以后真需要加一段"留的余量。
yesno "一键命令长度 ${ol_len} 在 100~230 字符之间" \
  "$([ "$ol_len" -ge 100 ] && [ "$ol_len" -le 230 ] && echo yes || echo no)"
# 落盘这一步不能省: 脚本用 readlink -f "$0" 找自己, 跑 /tmp 下的临时文件会把
# proxy 软链指到 /tmp, 紧接着 cleanup_stale_scripts 就把它清掉。
yesno "一键命令先 bash -n 再落盘" "$(has "$oneliner" 'bash -n "$f"&&install -m755')"
yesno "一键命令落到 /root/setup-proxy.sh" "$(has "$oneliner" 'install -m755 "$f" /root/setup-proxy.sh')"
# install 是复制不是移动: 少了 rm, 每次安装都在 /tmp 留一个 200KB 的脚本副本。
yesno "一键命令清掉临时文件" "$(has "$oneliner" '&&rm "$f"&&')"
# CI 里有一道"一键命令 URL 必须等于 REPO_URL 拼出来的那条"的闸门。以前它写的是
# 死字符串 `curl -fsSL <url>`, 而超时参数正好夹在 -fsSL 和 URL 中间 —— 给三处补
# 超时时把 CI 打红了, 本地却全绿。这里把 CI 的判定条件同步过来, 同一行里既有
# curl -fsSL 又有那条 URL 才算过, 推到远端之前就能发现。
onliner_url="https://raw.githubusercontent.com/$(sed -n 's/^REPO_URL="https:\/\/github.com\/\([^"]*\)".*/\1/p' "$SRC")/main/setup.sh"
yesno "README 一键命令的 URL 与 REPO_URL 同源" \
  "$(awk -v u="$onliner_url" 'index($0,u) && index($0,"curl -fsSL") {f=1} END{print (f?"yes":"no")}' README.md)"
yesno "TUIC 不再被当 TCP+UDP 放行" "$(no "$CODE" '${TUIC_PORT}/tcp')"
yesno "sysctl -p 返回码被接住" "$(has "$CODE" 'sysctl -p /etc/sysctl.d/99-proxy-optimize.conf 2>&1); sysrc=$?')"
yesno "sysctl 逐项回读" "$(has "$CODE" 'sysctl -n "$k"')"
yesno "端口跳跃规则会枚举清理" "$(has "$CODE" 'hop_cleanup_rules')"
yesno "防火墙规则会撤回" "$(has "$CODE" 'firewall_undo')"
yesno "clean 会删句柄数配置" "$(has "$CODE" '99-proxy-nofile.conf')"
yesno "clean 会删旧 hysteria.service" "$(has "$CODE" '/etc/systemd/system/hysteria.service')"
yesno "自更新有多源哈希交叉比对" "$(has "$CODE" 'fetch_script_verified')"
# 修订号 7: fetch_script_verified 里官方源必须独立优先, 不能和镜像混在同一循环
# (download_with_mirror / fetch_remote_version 用 for p in "" ... 是"官方优先失败换源",
#  不做哈希比对, 没有误拒问题, 不能一并要求改)
yesno "自更新官方源独立优先下载" "$(has "$CODE" 'curl -fsSL --connect-timeout 8 --max-time 90 -o "$tmp" "${SCRIPT_URL}"')"
yesno "自更新镜像不一致才放弃" "$(has "$CODE" '两个镜像源给出的脚本哈希不一致')"
yesno "节点名截断到 64 字符" "$(has "$CODE" '${n:0:64}')"
yesno "user add 卡名字长度" "$(has "$CODE" '名字太长(最多 64 字符)')"
yesno "base64 失败会中止" "$(has "$CODE" '订阅 base64 编码失败')"
yesno "不再开 ip_forward" "$(no "$CODE" 'net.ipv4.ip_forward=1')"

# ---- 前代逐文件复查后的加固(静态闸门, 已并入 v1.0) ----
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

# 版本引用对齐: 对外只有一个当前版本, 不留版本流水账(README 已精简)
yesno "README 标当前版本 v1.0" "$(has "$(cat README.md)" '当前 **v1.0**')"
yesno "docs badge 对齐 v1.0" "$(has "$(cat docs/index.html)" 'class="badge">v1.0')"
yesno "README 无历史版本流水账" "$(no "$(cat README.md)" 'v1.4（')"
yesno "README 无世代字样" "$(no "$(cat README.md)" '世代')"

# 敏感信息扫描: 只查明显像令牌的字面量
SECRETS=$(grep -nE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}' \
            "$SRC" README.md docs/index.html 2>/dev/null | head -5)
t "源码/文档无硬编码凭据" "${SECRETS:-}" ""

# ---- DNS 泄露面 / IPv6 屏蔽收口(静态闸门) ----
yesno "Xray DNS 不再回落 localhost" "$(no "$CODE" '"servers": [ "1.1.1.1", "8.8.8.8", "localhost" ]')"
yesno "Xray DNS 只留两个境外解析器" "$(has "$CODE" '"servers": [ "1.1.1.1", "8.8.8.8" ]')"
yesno "sing-box 服务端定义 block 出站" "$(has "$CODE" '"type": "block", "tag": "block"')"
yesno "sing-box 服务端拦 IPv6 目标" "$(has "$CODE" '"ip_version": 6')"
yesno "sing-box 不用 1.13 才有的 reject" "$(no "$CODE" '"action": "reject"')"
yesno "sing-box v6 规则有整条撤回保险" "$(has "$CODE" 'for v6try in 1 0; do')"
yesno "Hysteria2 出站强制 IPv4" "$(has "$CODE" 'echo "      mode: 4"')"
yesno "Hysteria2 两段配置分级回退" "$(has "$CODE" 'write_hy2_config 1 0')"
yesno "Hysteria2 不用会误杀域名的 ACL" "$(no "$CODE" 'reject(::/0)')"
yesno "audit 有 DNS 归属实测段" "$(has "$CODE" 'DNS 解析归属实测')"
yesno "audit 有 whoami TXT 回显" "$(has "$CODE" 'o-o.myaddr.l.google.com')"
yesno "audit 检查 Xray DNS 是否被回退" "$(has "$CODE" '已回退系统解析')"
yesno "audit 提示 egress 下 DNS 不走上游" "$(has "$CODE" 'DNS 查询仍由 VPS 直发, 不经 egress')"
yesno "audit 给出客户端 dnsleaktest 验证" "$(has "$CODE" 'https://dnsleaktest.com')"
yesno "订阅页提示纯链接不带 DNS" "$(has "$CODE" '是纯节点列表, 本身不带 DNS 配置')"
yesno "客户端指南有 DNS 泄露自检" "$(has "$(cat "$SRC")" '连上之后自己验一次 DNS 有没有漏')"
yesno "README 说明关 IPv6 防绕过" "$(has "$(cat README.md)" '关 IPv6 防 AAAA 绕过')"
yesno "README 写明服务端测不到客户端泄露" "$(has "$(cat README.md)" '客户端到底用了哪个 DNS，服务端测不到')"
yesno "README 提到 dnstest" "$(has "$(cat README.md)" 'proxy dnstest')"

# ---- 修订号 7 增量: Claude 风控 / 小火箭 DNS 走代理 / 已核实 bug 修复 ----
yesno "client-guide 有 Claude 风控章" "$(has "$(cat "$SRC")" 'Claude / Anthropic: 风控看什么')"
yesno "README 有 Claude 风控章" "$(has "$(cat README.md)" '### Claude / Anthropic 风控')"
yesno "audit 客户端清单提示 Claude 断线" "$(has "$(cat "$SRC")" '用 Claude 时小火箭切全局代理')"
yesno "小火箭 DNS 走代理用 direct-dns-server" "$(has "$(cat "$SRC")" 'direct-dns-server = 223.5.5.5')"
yesno "小火箭 dns-server 带 proxy 参数" "$(has "$CODE" '#proxy=${dnsname}')"
yesno "README 同步小火箭 DNS 走代理" "$(has "$(cat README.md)" '#proxy=节点名')"
yesno "HY2_HOP 校验挡多段区间" "$(has "$CODE" '*-*-*) _hop_bad=1')"
yesno "users.txt 末行无换行也读" "$(has "$CODE" 'read -r u name _ || [ -n "$u" ]')"
yesno "clients JSON 末行无换行也读" "$(has "$CODE" 'read -r u n _ || [ -n "$u" ]')"
yesno "user list 末行无换行也读" "$(has "$CODE" 'read -r u n d || [ -n "$u" ]')"
yesno "diag 设备循环末行无换行也读" "$(has "$CODE" 'read -r du _ || [ -n "$du" ]')"
yesno "egress off 检查 apply 失败" "$(has "$CODE" '关闭上游出口时服务未能启动')"
yesno "只开 hy2 时 egress 不再误报生效" "$(has "$(cat "$SRC")" '不支持上游代理; 未保存出口设置')"
yesno "update 已是最新也跑后续动作" "$(has "$(cat "$SRC")" '即使已是最新版, 后续动作也必须照跑')"
yesno "诊断 grep 无匹配有提示" "$(has "$CODE" '没有 xray/hysteria/sing-box 在监听')"

# ---- 修订号 8: 纠正错误铁律 + 逐行复查修的 5 个 bug ----
# 不能再用不存在的 26.9.8 当"强制门槛"; 提示里要讲清是自动协商 + 客户端指纹
yesno "不再宣称 26.9.8 强制 MLKEM" "$(no "$(cat "$SRC")" '26.9.8: REALITY 强制要求')"
yesno "不再说升级必然打不开网页" "$(no "$(cat "$SRC")" '升级后会「开关变绿但网页打不开」')"
yesno "升级提示讲清自动协商" "$(has "$(cat "$SRC")" 'REALITY 自 v25.5.16 起')"
yesno "README 不再写锁死 Xray" "$(no "$(cat README.md)" '锁死 Xray 26.3.27')"
yesno "README 不宣称小火箭无开关" "$(no "$(cat README.md)" '小火箭发不出且无开关')"
yesno "README 给出 mihomo MLKEM 解法" "$(has "$(cat README.md)" 'support-x25519mlkem768: true')"
yesno "README apple 黑名单项非官方警告" "$(no "$(cat README.md)" 'Xray 官方警告易致封 IP')"
# print_links 必须显示当前生效 UUID, 不能是 state.env 里的初始值
yesno "print_links 显示主 UUID" "$(has "$CODE" 'UUID      : ${PRIMARY_UUID:-$(primary_uuid)}')"
yesno "print_links 不再直接打印初始 UUID" "$(no "$CODE" 'echo "UUID      : ${UUID}"')"
# Brutal 显示要先过合法性检查
yesno "订阅信息 Brutal 检查合法性" "$(has "$CODE" '_biu="${HY2_BW_UP:-}"')"
# restore 缺 DEST 要有兜底
yesno "restore 补 DEST 默认值" "$(has "$CODE" 'DEST="${DEST:-www.bing.com}"')"
# user add 重名检查只按名字精确匹配
yesno "user add 不按 UUID 前缀查重名" "$(has "$CODE" "awk -F'|' -v n=\"\$name\" '\$2==n")"
# verify 全局重置
yesno "verify 重置 VERIFY_FIX" "$(has "$CODE" 'VERIFY_FIX=""')"
# 测试 harness 零断言假绿闸门

# ---- 修订号 9: REALITY 抗封增强 ----
yesno "指纹白名单函数存在" "$(has "$CODE" 'valid_reality_fp()')"
yesno "指纹默认 chrome" "$(has "$CODE" 'REALITY_FP="${REALITY_FP:-chrome}"')"
yesno "指纹进 STATE_KEYS" "$(has "$(cat "$SRC")" 'DEFAULT_NODE REALITY_FP CERT_SPKI_B64')"
yesno "指纹写进 VLESS 链接" "$(has "$CODE" 'sni=${DEST}&fp=${REALITY_FP:-chrome}')"
yesno "指纹写进 sing-box 订阅" "$(has "$CODE" '"fingerprint": "${REALITY_FP:-chrome}"')"
yesno "指纹非法回退 chrome" "$(has "$CODE" '不是 Xray 认识的指纹, 已回退 chrome')"
yesno "伪装站池统一常量" "$(has "$CODE" 'REALITY_DESTS="www.samsung.com www.nvidia.com')"
yesno "两处挑选共用池子" "$(has "$CODE" 'cands+=($REALITY_DESTS)')"
yesno "池子含冷门技术站" "$(has "$CODE" 'www.python.org www.kernel.org')"
# 这一版是**回退到最初那 20 个**(用户要求: 他认得这些站), 只剔了套 CF 的 suse。
# 闸门守两件事: (1) 最初那批站别又被"优化"掉; (2) suse 别被加回来。
yesno "池子含顶级流量站(adobe 59)" "$(has "$CODE" 'www.adobe.com')"
# amazon(28) 硬判据全过, 但没进池子: 加它不改变分散度(N = 档内数量/3, 18 个时是 6,
# 加一个还是 6), 用户也说"不好用就别加"。这条闸门防的是有人拿排名当理由又塞回去 ——
# 要加就先说明分散度怎么变。
yesno "amazon 没进池子(加它不增加分散度)" "$(no "$CODE" 'REALITY_DESTS="www.amazon.com')"
# $CODE 是去掉整行注释后的源码, 查注释要用原文。
# 池子里 13 个站是 Akamai 边缘, amazon 是 CloudFront —— "CDN 边缘终止 TLS"是常态。
# 这条闸门守的是"别把 CF 判据扩大成'凡是 CDN 都拦'", 那会把 13 个站一起误伤。
yesno "注释里写明 Akamai 是常态(别扩大 CF 判据)" "$(has "$(cat "$SRC")" 'Akamai 边缘')"
# nginx(104) / ibm(282) 曾被"行业重挑"和一次探测失败误伤, 排名比池子一半的站都高。
yesno "池子含 nginx(104)" "$(has "$CODE" 'www.apache.org www.nginx.com www.postgresql.org')"
yesno "池子含 ibm(282)" "$(has "$CODE" 'www.amd.com www.ibm.com www.tesla.com')"
yesno "池子含 dell/hp/intel(硬件大厂)" \
  "$(has "$CODE" 'www.oracle.com www.dell.com www.hp.com www.intel.com')"
yesno "池子含 tesla" "$(has "$CODE" 'www.tesla.com www.adobe.com')"
# bing 只到 TLS1.2, 会进档位 2, 而档位 1 有 18 个候选 —— 永远选不到。留一个永远
# 选不到的站只会让"池子里全是 TLS1.3"变成假话, 还得在每个文档里加例外。所以剔掉。
yesno "只到 TLS1.2 的 bing 不在池子里" "$(no "$CODE" 'www.mysql.com www.bing.com')"
yesno "注释里写了 bing 的剔除理由" "$(has "$(cat "$SRC")" '只协商到 TLS 1.2')"
# suse 套 CF(实测 Server: cloudflare + CF-RAY), 用户自己定的规则是"千万不能套 CF"。
yesno "套 CF 的 suse 没在池子里" "$(no "$CODE" 'www.debian.org www.suse.com')"
yesno "池子与黑名单无 google" "$(no "$CODE" 'REALITY_DESTS="www.google.com')"
# 池子规模: 回退到最初那批, 就是 19 个(20 减 suse)。上限 22 是防止有人又往里堆。
# 下限 15: 再少的话档位 1 剩不下几个, 分散度(每档取前 N 随机)就没意义了。
dest_n=$(bash -c 'eval "$(grep -m1 "^REALITY_DESTS=" setup.sh)"; set -- $REALITY_DESTS; echo $#' 2>/dev/null)
yesno "伪装站池在 15~22 个之间(当前 ${dest_n})" \
  "$([ -n "$dest_n" ] && [ "$dest_n" -ge 15 ] && [ "$dest_n" -le 22 ] && echo yes || echo no)"
# 池子里每个域名都必须有 dest_note 说明。SNI 是必须一字不差抄进客户端的一行 ——
# 看到陌生域名又没有任何线索, 抄错了也只会得到"连接超时"。这条闸门保证以后
# 往池子里加站的人顺手补上说明, 而不是靠记得。
note_fn=$(awk '/^dest_note\(\)\{/,/^\}/' "$SRC")
dest_list=$(bash -c 'eval "$(grep -m1 "^REALITY_DESTS=" setup.sh)"; echo $REALITY_DESTS' 2>/dev/null)
note_missing=$(bash -c '
eval "$1"
shift
for d in "$@"; do dest_note "$d" >/dev/null 2>&1 || printf "%s " "$d"; done
' _ "$note_fn" $dest_list 2>/dev/null)
yesno "池子里每个站都有 dest_note 说明${note_missing:+ (缺: ${note_missing})}" \
  "$([ -n "$note_fn" ] && [ -z "$note_missing" ] && echo yes || echo no)"
yesno "info 文件里写出伪装目标与说明" "$(has "$CODE" 'echo "伪装目标: ${DEST}${dn:+  (${dn})}"')"
# 用户自定义 REALITY_DEST 时 dest_note 取不到说明 —— 括号里不写, 但"必须一字不差"
# 那两行必须照常输出。自定义域名更容易抄错, 更需要这句提醒, 不能因为查不到说明就
# 把整段(含警告)一起跳过。
yesno "自定义域名时警告不被跳过" "$(has "$CODE" 'dn=$(dest_note "$DEST" 2>/dev/null) || dn=""')"
yesno "终端 SNI 下面补站点说明" "$(has "$CODE" 'print_dest_note')"
# 用户看到不认识的域名, 除了"这是什么站"还想知道"还有哪些可选、能不能换"。
# proxy dest 只读, 不偷偷改配置(换站要重签证书 + 重写订阅, 那是 install 的活)。
yesno "dest 子命令已注册" "$(has "$CODE" 'dest)           cmd_dest')"
yesno "proxy dest 会列出整个池子" "$(has "$CODE" '伪装目标候选池')"
yesno "proxy dest 给了换站命令" "$(has "$CODE" 'REALITY_DEST=www.oracle.com bash /root/setup-proxy.sh install')"
# 池子里没有例外了, 列表末尾可以直说"全部 TLS1.3 + h2"。以前有 bing 时这里必须
# 加限定语 —— 一句不准确的总结比没有总结更糟。
yesno "proxy dest 的总结与池子一致" "$(has "$CODE" '全部实测: TLS 1.3 + ALPN h2')"
yesno "proxy dest 在帮助里" "$(has "$CODE" 'dest [list]      查看当前伪装目标站')"
# 每档取样数必须随档内数量浮动。写死 3 的话池子扩到多少都白扩。
yesno "每档随机数随档内数量浮动" "$(has "$CODE" 'n_rand=$(( ${#grp[@]} / 3 ))')"
yesno "每档随机数上限 8" "$(has "$CODE" '[ "$n_rand" -gt 8 ] && n_rand=8')"
# 一个候选站只握手一次。以前拆成"查 CF"+"查版本"两个函数各跑一次 openssl
# s_client —— 同一个握手跑两遍, 池子一扩这个浪费就乘上去。
yesno "候选站探测只握手一次" "$(has "$CODE" 'read -r pv pa pi <<< "$(dest_probe "$d")"')"
yesno "CF 检测走独立函数(不再只看证书)" "$(has "$CODE" 'dest_behind_cf(){')"
# CF 现在的边缘证书由 Google Trust Services 签发(实测 www.cloudflare.com 的 issuer
# 就是 GTS), 证书里没有 "Cloudflare" 字样 —— 只查 issuer 会整片漏掉套 CF 的站。
# 必须同时看响应头。实测池子里 suse/redis/w3/nodejs 四个都是 CF, 老逻辑一个都没拦。
yesno "CF 检测看响应头不只查证书" "$(has "$CODE" 'server:[[:space:]]*cloudflare|cf-ray:')"
yesno "CF 检测也认 cf-ray" "$(has "$CODE" 'cf-ray:')"
# 行为验证(用桩, 不联网): 只查"字符串在不在"证明不了逻辑对 —— 这次的漏洞正是
# "代码在, 但判据不覆盖真实情况"(只看 issuer, 而 CF 的边缘证书由 GTS 签发)。
# 这里把 curl 换成固定返回的桩, 真的调一次 dest_behind_cf 看判定结果。
cf_fn=$(awk '/^dest_behind_cf\(\)\{/,/^\}/' "$SRC")
cf_hit=$(bash -c 'curl(){ printf "HTTP/1.1 200 OK\r\nserver: cloudflare\r\ncf-ray: 1\r\n\r\n"; }
'"$cf_fn"'
dest_behind_cf example.com "" && echo CF || echo NO' 2>/dev/null)
t "CF 响应头被识别(桩)" "$cf_hit" "CF"
cf_ray=$(bash -c 'curl(){ printf "HTTP/1.1 200 OK\r\ncf-ray: 8a1b2c\r\n\r\n"; }
'"$cf_fn"'
dest_behind_cf example.com "" && echo CF || echo NO' 2>/dev/null)
t "只有 cf-ray 也被识别(桩)" "$cf_ray" "CF"
cf_miss=$(bash -c 'curl(){ printf "HTTP/1.1 200 OK\r\nserver: nginx\r\n\r\n"; }
'"$cf_fn"'
dest_behind_cf example.com "" && echo CF || echo NO' 2>/dev/null)
t "普通响应头被放过(桩)" "$cf_miss" "NO"
cf_iss=$(bash -c 'curl(){ :; }
'"$cf_fn"'
dest_behind_cf example.com "issuer=O=Cloudflare, Inc." && echo CF || echo NO' 2>/dev/null)
t "证书 issuer 命中(桩)" "$cf_iss" "CF"
cf_none=$(bash -c 'curl(){ :; }
'"$cf_fn"'
dest_behind_cf example.com "issuer=O=Google Trust Services, CN=WE1" && echo CF || echo NO' 2>/dev/null)
t "GTS 签发但无 CF 头时放过(桩)" "$cf_none" "NO"
yesno "client-guide 有 Reality 专属排障" "$(has "$(cat "$SRC")" 'Reality 单独连不上、Hysteria2 却能用')"
yesno "README 有 Reality 专属 FAQ" "$(has "$(cat README.md)" 'Reality 连不上、HY2 能用')"
yesno "README 有 REALITY_FP 变量" "$(has "$(cat README.md)" '| `REALITY_FP` | `chrome` |')"

# ---- 修订号 10: Xray 追最新 + 官方 dgst 校验 + v2rayN pin 纠错 ----
yesno "Xray 默认 latest" "$(has "$CODE" 'XRAY_VERSION="${XRAY_VERSION:-latest}"')"
yesno "有内置兜底基线版本" "$(has "$CODE" 'XRAY_FALLBACK_VERSION="26.3.27"')"
yesno "有解析官方 dgst 的函数" "$(has "$CODE" 'xray_dgst_sha()')"
yesno "dgst 用官方同款解析" "$(has "$CODE" "/256=/ {print \$2}")"
yesno "有统一的期望哈希函数" "$(has "$CODE" 'xray_expected_sha()')"
yesno "install 用官方哈希校验" "$(has "$CODE" '_want_sha=$(xray_expected_sha "$XRAY_VERSION"')"
yesno "upgrade 用官方哈希校验" "$(has "$CODE" '_want_sha=$(xray_expected_sha "$target"')"
yesno "API 不通沿用本机不降级" "$(has "$CODE" '沿用本机版本')"
yesno "显式版本仍可固定" "$(has "$CODE" 'XRAY_VERSION="$_RAW_XRAY_VERSION"')"
yesno "load_state 不锁死历史版本" "$(has "$CODE" 'XRAY_VERSION="latest"')"
yesno "README XRAY_VERSION 默认 latest" "$(has "$(cat README.md)" '| `XRAY_VERSION` | `latest` |')"
yesno "README 讲官方 dgst 校验" "$(has "$(cat README.md)" '用官方 `.dgst` 校验')"
# v2rayN pinSHA256: 纠正"一律不识别"的过时说法
yesno "不再说 v2rayN 不识别 pinSHA256" "$(no "$(cat "$SRC")" 'v2rayN 不识别 pinSHA256, 此条无身份验证')"
yesno "v2rayn 订阅用带 pin 主链接" "$(has "$CODE" 'proto_on hy2 && printf '"'"'%s\n'"'"' "$HY2_LINK"')"
yesno "保留 oldv2rayN 兜底链接" "$(has "$CODE" '-oldv2rayN')"
yesno "client-guide 讲新版支持" "$(has "$(cat "$SRC")" '新版已支持')"
# v2rayN pinSHA256 的识别能力由上面的源码断言(234-237)验证;
# 不在 README 里钉死这句文案, 避免为测试把文档撑长。
# 纯节点列表不带 DNS 是格式限制, 要讲清
yesno "订阅提示说清是格式限制" "$(has "$CODE" '分享链接格式的限制')"
yesno "订阅提示指向带 DNS 的配置" "$(has "$CODE" '导入 clash.yaml / singbox.json')"

# ---- 修订号 11: 返回值不许被日志污染 / version 标签与退出码 ----
# xray_expected_sha 的 stdout 就是哈希本身, 里面的提示必须走 stderr
yesno "xray 镜像核对提示走 stderr" "$(has "$CODE" '已用两个镜像交叉核对 Xray v${ver} 哈希" >&2')"
yesno "xray 内置兜底提示走 stderr" "$(has "$CODE" '改用脚本内置哈希校验 Xray v${ver}" >&2')"
yesno "xray 冲突详情走 stderr" "$(has "$CODE" '官方校验值与脚本内置值不一致, 拒绝安装:" >&2')"
# effective_default_node 的 stdout 就是节点名
yesno "默认节点警告走 stderr" "$(has "$CODE" '但本次未启用 hysteria2, 仍用 ${pick}" >&2')"
yesno "非法 DEFAULT_NODE 警告走 stderr" "$(has "$CODE" '不认识(可选 reality / hy2), 按 ${pick} 处理" >&2')"
# 没启用 REALITY 时不能照报 reality: 那个出站不存在, 订阅里也没有对应节点
yesno "默认节点跟随实际启用的协议" "$(has "$CODE" 'if proto_on reality; then pick=reality')"
# version 的哈希标签必须是 sha256
yesno "version 不再把 sha256 标成 md5" "$(no "$CODE" 'echo "md5 :')"
yesno "version 用 sha256 标签" "$(has "$CODE" 'echo "sha256: $(file_sha256')"
# 管道运行时 version 也必须 exit 0
if bash -c 'cat "$1" | bash -s version >/dev/null 2>&1' _ "$SRC"; then
  pass "管道运行 version 退出码为 0"
else
  fail "管道运行 version 退出码为 0(实为非 0, 会让调用方误判失败)"
fi
# pipefail 下 grep -q 触发 SIGPIPE 的同类隐患
yesno "sing-box 已装判断不用管道 grep -q" "$(no "$CODE" '"$SB_BIN" version 2>/dev/null | grep -qF')"
yesno "ufw 判断统一走 ufw_active" "$(has "$CODE" 'ufw_active(){')"
yesno "不再直接 ufw status | grep -q" "$(no "$CODE" 'ufw status 2>/dev/null | grep -q')"
yesno "timesyncd 判断先落变量" "$(has "$CODE" '_ufs=$(systemctl list-unit-files')"

# ---- 修订号 12: Hysteria2 追最新 + 官方 hashes.txt 动态校验 ----
yesno "HY2 默认 latest" "$(has "$CODE" 'HY2_VERSION="${HY2_VERSION:-latest}"')"
yesno "HY2 有内置兜底基线版本" "$(has "$CODE" 'HY2_FALLBACK_VERSION="2.13.0"')"
yesno "有 hashes.txt 解析函数" "$(has "$CODE" 'sha_from_sumfile()')"
yesno "sumfile 按 basename 匹配" "$(has "$CODE" 'seg[n] == want')"
yesno "sumfile 剥掉二进制 * 前缀" "$(has "$CODE" 'sub(/^\*/, "", f)')"
yesno "有 HY2 期望哈希函数" "$(has "$CODE" 'hy2_expected_sha()')"
yesno "有 HY2 最新版解析" "$(has "$CODE" 'hy2_latest_version()')"
yesno "install 用 HY2 官方哈希校验" "$(has "$CODE" '_hy2_want=$(hy2_expected_sha "$HY2_VERSION"')"
yesno "HY2 不再直接用内置哈希校验" "$(no "$CODE" 'verify_sha256 "$htmp/hy2.bin" "$(pinned_sha')"
yesno "HY2 只追 2.x(跨大版本不自动跟)" "$(has "$CODE" '已跨出 2.x; 服务端配置格式可能不兼容')"
yesno "HY2 API 不通沿用本机不降级" "$(has "$CODE" '查询 Hysteria2 最新版失败')"
yesno "HY2 显式版本仍可固定" "$(has "$CODE" 'HY2_VERSION="$_RAW_HY2_VERSION"')"
yesno "HY2 不信任 state 历史值" "$(has "$CODE" '_RAW_HY2_VERSION')"
yesno "HY2 镜像兜底提示走 stderr" "$(has "$CODE" '交叉核对 Hysteria2 v${ver} 哈希" >&2')"
yesno "HY2 冲突详情走 stderr" "$(has "$CODE" '官方校验值与脚本内置值不一致, 拒绝安装:" >&2')"
yesno "usage 讲 HY2 追最新" "$(has "$CODE" '留空=追官方最新 2.x, 用官方 hashes.txt 校验')"
yesno "README 讲 HY2 用 hashes.txt" "$(has "$(cat README.md)" 'hashes.txt')"
if [ -f test/hy2_hash_behavior.sh ] && [ -f test/hy2_resolve_behavior.sh ]; then
  pass "有 hy2 哈希/解析行为验证脚本"
else
  fail "有 hy2 哈希/解析行为验证脚本"
fi

# ---- 修订号 13: 全项目逐行审查(修真 bug + 堵假绿) ----
# 假绿根源: mock 没真拦到官方 URL, 镜像兜底分支从未执行
# dest_rank 的 stdout 是选站数据, 4 条 warn 都不许混进去
yesno "dest_rank 排除名单警告走 stderr" "$(has "$CODE" 'warn "$d 在排除名单(被墙域名/CDN 共用证书链), 跳过" >&2')"
yesno "dest_rank CF 警告走 stderr" "$(has "$CODE" '套了 Cloudflare(响应头 server/cf-ray 或证书), 跳过" >&2')"
yesno "dest_rank 弱 TLS 警告走 stderr" "$(has "$CODE" '抗主动探测略弱, 列为备选" >&2')"
yesno "dest_rank 探测失败警告走 stderr" "$(has "$CODE" '交给真实握手判定" >&2')"
# restore 失败回滚必须连证书一起还原
yesno "restore 备份证书回滚点" "$(has "$CODE" '_RESTORE_CERT_BACKUP="${STATE_DIR}.before-restore.certs"')"
yesno "restore 回滚时还原证书" "$(has "$CODE" '_RESTORE_CERT_BACKUP/hysteria/.')"
yesno "clean 删掉证书回滚点" "$(has "$CODE" '"${STATE_DIR}.before-restore.certs"')"
# upgrade --rollback 不许假成功
yesno "回滚检查 cp 返回值" "$(has "$CODE" '回滚失败: 无法覆盖 ${XRAY_BIN}')"
yesno "回滚后核对版本" "$(has "$CODE" '回滚后无法读取 xray 版本')"
# verify --fix 不许把不可修项也清零
yesno "verify 记录不可修权限问题" "$(has "$CODE" 'VERIFY_UNFIXABLE=$((VERIFY_UNFIXABLE + 1))')"
yesno "verify --fix 只清可修项" "$(has "$CODE" '[ "$VERIFY_UNFIXABLE" -eq 0 ]')"
# 订阅/info 的指纹必须跟实际配置同源
yesno "clash 指纹不再硬编码 chrome" "$(no "$CODE" 'echo "    client-fingerprint: chrome"')"
yesno "clash 指纹跟随 REALITY_FP" "$(has "$CODE" 'client-fingerprint: ${REALITY_FP:-chrome}')"
yesno "info 指纹跟随 REALITY_FP" "$(has "$CODE" 'echo "fp       : ${REALITY_FP:-chrome}"')"
# 同类 SIGPIPE 残留
yesno "HY2 端口等待不用管道 grep -q" "$(has "$CODE" '_sl=$(ss -ltn 2>/dev/null || true)')"
yesno "Xray 版本读取先落变量" "$(has "$CODE" '_iv=$("$XRAY_BIN" version 2>/dev/null) || _iv=""')"

# ---- 修订号 14: shadowrocket.conf 开箱即用 DNS 配置 ----
yesno "有 shadowrocket 配置文件生成器" "$(has "$CODE" 'write_shadowrocket_conf()')"
yesno "有 shadowrocket 配置校验器" "$(has "$CODE" 'sub_shadowrocket_ok()')"
yesno "订阅生成时写出 shadowrocket.conf" "$(has "$CODE" 'write_shadowrocket_conf "$tdir/shadowrocket.conf"')"
yesno "订阅完整性校验含 shadowrocket.conf" "$(has "$CODE" 'sub_shadowrocket_ok "$tdir/shadowrocket.conf"')"
yesno "订阅清单列出 shadowrocket.conf" "$(has "$CODE" 'shadowrocket.conf iOS 小火箭专用')"
# 防泄露主力: 境外域名远端解析(不依赖节点名)
yesno "小火箭配置有 force-remote-dns" "$(has "$CODE" 'FINAL,PROXY,force-remote-dns')"
yesno "小火箭配置 DNS 走隧道" "$(has "$CODE" '#proxy=${dnsname}')"
yesno "小火箭节点名自动 URI 编码" "$(has "$CODE" 'dnfrag=$(uri_fragment "$NODE_NAME")')"
yesno "小火箭 DNS 节点跟随默认节点" "$(has "$CODE" 'dnsname="${dnfrag}-HY2"')"
# hijack-dns 错误写法必须清除, 全部改 :53
# 配置行是 echo "..." 形式, 必须检查生成语句本身; 顶格裸行永远匹配不到, 断言会假绿。
yesno "旧错误 hijack-dns=true 已移除(setup)" "$(no "$CODE" 'echo "hijack-dns = true"')"
yesno "hijack-dns 用 :53(setup)" "$(has "$CODE" 'echo "hijack-dns = :53"')"
yesno "旧错误 hijack-dns=true 已移除(README)" "$(no "$(grep '^hijack-dns = true$' README.md)" 'hijack-dns = true')"
# hijack-dns 的具体写法由上面的源码断言(336-337)验证;
# README 只讲效果("DNS 已配好"), 不钉死语法文案。
yesno "禁系统 DNS 回退" "$(has "$CODE" 'dns-fallback-system = false')"
yesno "禁直连系统 DNS" "$(has "$CODE" 'dns-direct-system = false')"
yesno "关 IPv6" "$(has "$CODE" 'prefer-ipv6 = false')"
yesno "防 QUIC 绕过" "$(has "$CODE" 'block-quic = all-proxy')"
yesno "Apple 服务直连" "$(has "$CODE" 'DOMAIN-SUFFIX,apple.com,DIRECT')"
yesno "有 shadowrocket 行为验证脚本" "$([ -f test/shadowrocket_conf_behavior.sh ] && echo yes || echo no)"
yesno "STUN 返回假IP防WebRTC泄漏" "$(has "$CODE" 'stun-response-ip = 1.1.1.1')"
yesno "STUN v6 返回假IP" "$(has "$CODE" 'stun-response-ipv6 = ::1')"
yesno "UDP不支持转发时拒绝" "$(has "$CODE" 'udp-policy-not-supported-behaviour = REJECT')"
yesno "校验器纳入STUN防漏检" "$(has "$CODE" "grep -q 'stun-response-ip = 1.1.1.1'")"

# ---- 架构升级: 三端规则单一数据源 + 渲染器, 不再三份硬编码 ----
yesno "STUN 域名单一数据源" "$(has "$CODE" 'STUN_DOMAINS=(stun.l.google.com')"
yesno "STUN 域名只声明一次" "$([ "$(grep -c '^STUN_DOMAINS=' "$SRC")" = 1 ] && echo yes || echo no)"
yesno "小火箭用渲染器" "$(has "$CODE" 'render_stun_sr')"
yesno "Clash 用渲染器" "$(has "$CODE" 'render_stun_clash')"
yesno "sing-box 用渲染器" "$(has "$CODE" 'render_stun_sb_domains')"
yesno "校验器共用数据源(小火箭)" "$(has "$CODE" '_stun_first=$(stun_sr_first)')"
yesno "校验器共用数据源(Clash)" "$(has "$CODE" '_stun_first=$(stun_clash_first)')"
yesno "三端不再硬编码 STUN 域名" "$([ "$(grep -c 'DOMAIN-SUFFIX,stun\.l\.google\.com' "$SRC")" -le 1 ] && echo yes || echo no)"
yesno "clash DNS 境外 DoH 经代理" "$(has "$CODE" 'https://cloudflare-dns.com/dns-query#PROXY')"
yesno "clash DNS 国内域名分流" "$(has "$CODE" 'geosite:cn,private')"
yesno "clash nameserver-policy 段" "$(has "$CODE" 'nameserver-policy:')"
yesno "clash STUN UDP 端口拦截" "$(has "$CODE" 'STUN_WEBRTC_PORTS')"
yesno "clash 校验器纳入 STUN 顺序" "$(has "$CODE" 'DST-PORT,3478.*REJECT')"
yesno "singbox STUN 域名拦截" "$(has "$CODE" 'render_stun_sb_domains')"
yesno "singbox STUN UDP 端口拦截" "$(has "$CODE" 'render_stun_sb_ports')"
# 端口列表也只能有一份: 以前 sing-box 的 "port"/"port_range" 是手写常量,
# 等于把 STUN_WEBRTC_PORTS 抄了第二遍, 改了上面漏了下面就是静默失效。
yesno "singbox 端口从同一份数据源现算" "$(has "$CODE" '"port_range": [%s]')"
yesno "不再有手写的 sing-box 端口常量" "$(no "$CODE" 'STUN_SB_PORTS=')"
yesno "singbox STUN 用 block 出站(兼容1.12)" "$(has "$CODE" '"outbound": "block"')"

# ---- 三端 writer 结构对称: 每端一个独立生成函数, 都能单独跑测试 ----
# 以前 clash.yaml 内嵌在 gen_sub_files 里, 靠外层局部变量传 Brutal 带宽和
# 默认节点, 单独调用就跑不起来, 于是三端里只有它没有行为测试。
yesno "小火箭有独立 writer" "$(has "$CODE" 'write_shadowrocket_conf(){')"
yesno "sing-box 有独立 writer" "$(has "$CODE" 'write_sb_client(){')"
yesno "Clash 有独立 writer" "$(has "$CODE" 'write_clash_yaml(){')"
yesno "gen_sub_files 调用 clash writer" "$(has "$CODE" 'write_clash_yaml "$tdir/clash.yaml"')"
yesno "clash writer 用渲染器" "$([ "$(awk '/^write_clash_yaml\(\)\{/,/^}/' "$SRC" | grep -c 'render_stun_clash')" = 1 ] && echo yes || echo no)"
yesno "clash writer 从数据源取 DNS" "$([ "$(awk '/^write_clash_yaml\(\)\{/,/^}/' "$SRC" | grep -c 'DNS_DOH_FOREIGN')" -ge 1 ] && echo yes || echo no)"
yesno "clash writer 不再硬编码 DoH" "$([ "$(awk '/^write_clash_yaml\(\)\{/,/^}/' "$SRC" | grep -c 'cloudflare-dns.com')" = 0 ] && echo yes || echo no)"
yesno "有 clash 行为验证脚本" "$([ -f test/clash_yaml_behavior.sh ] && echo yes || echo no)"

# ---- v1.6: v2rayN 独立路由配置(补纯链接的防护短板) ----
yesno "生成 v2rayn-routed.json" "$(has "$CODE" 'cp -f "$tdir/singbox.json" "$tdir/v2rayn-routed.json"')"
yesno "v2rayn-routed 在订阅白名单" "$(has "$CODE" '"v2rayn-routed.json"')"
yesno "client-guide 引导 v2rayN 首选 routed" "$(has "$CODE" '首选：导入 \`v2rayn-routed.json\`')"
yesno "订阅清单标 v2rayN 首选" "$(has "$CODE" 'v2rayN 首选 (sing-box 内核导入')"

# ---- 修订号 16: 小火箭国内域名直连(修 GEOIP,no-resolve 漏掉域名请求) ----
yesno "小火箭内置 .cn 直连" "$(has "$CODE" 'DOMAIN-SUFFIX,cn,DIRECT')"
yesno "小火箭内置淘宝直连" "$(has "$CODE" 'DOMAIN-SUFFIX,taobao.com,DIRECT')"
yesno "小火箭内置B站直连" "$(has "$CODE" 'DOMAIN-SUFFIX,bilibili.com,DIRECT')"
yesno "小火箭内置微信QQ直连" "$(has "$CODE" 'DOMAIN-SUFFIX,qq.com,DIRECT')"
yesno "v1.2补充域名-唯品会" "$(has "$CODE" 'DOMAIN-SUFFIX,vip.com,DIRECT')"
yesno "v1.2补充域名-华为" "$(has "$CODE" 'DOMAIN-SUFFIX,huawei.com,DIRECT')"
yesno "v1.2补充域名-豆瓣" "$(has "$CODE" 'DOMAIN-SUFFIX,douban.com,DIRECT')"
yesno "v1.2补充域名-得物" "$(has "$CODE" 'DOMAIN-SUFFIX,dewu.com,DIRECT')"
yesno "补充域名全在FINAL之前" "$(awk '
  /echo "DOMAIN-SUFFIX,vip.com,DIRECT"/ { if (!c) c=NR }
  /echo "DOMAIN-SUFFIX,kingsoft.com,DIRECT"/ { if (!l) l=NR }
  /echo "FINAL,PROXY,force-remote-dns"/    { if (!f) f=NR }
  END { print (c && l && f && c < l && l < f) ? "yes" : "no" }
' "$SRC")"
yesno "国内域名规则位置早于 FINAL" "$(awk '
  /echo "DOMAIN-SUFFIX,taobao.com,DIRECT"/ { if (!c) c=NR }
  /echo "FINAL,PROXY,force-remote-dns"/    { if (!f) f=NR }
  END { print (c && f && c < f) ? "yes" : "no" }
' "$SRC")"
yesno "校验器有国内域名顺序闸门" "$(has "$CODE" 'cn < fin')"

# ---- v1.3: 关键词规则补长尾, 只能是域名字符串匹配, 不能退化成 IP 地理规则 ----
yesno "v1.3关键词-百度" "$(has "$CODE" 'DOMAIN-KEYWORD,baidu,DIRECT')"
yesno "v1.3关键词-豆瓣" "$(has "$CODE" 'DOMAIN-KEYWORD,douban,DIRECT')"
yesno "v1.3关键词-淘宝" "$(has "$CODE" 'DOMAIN-KEYWORD,taobao,DIRECT')"
yesno "v1.3关键词-飞猪" "$(has "$CODE" 'DOMAIN-KEYWORD,fliggy,DIRECT')"
yesno "关键词全在FINAL之前" "$(awk '
  /echo "DOMAIN-KEYWORD,baidu,DIRECT"/  { if (!c) c=NR }
  /echo "DOMAIN-KEYWORD,fliggy,DIRECT"/ { if (!l) l=NR }
  /echo "FINAL,PROXY,force-remote-dns"/    { if (!f) f=NR }
  END { print (c && l && f && c < l && l < f) ? "yes" : "no" }
' "$SRC")"
yesno "GEOIP规则一条不漏都带no-resolve" "$(awk '
  /echo "GEOIP,CN,DIRECT"/ { if ($0 !~ /no-resolve/) bad=1 }
  END { print bad ? "no" : "yes" }
' "$SRC")"
yesno "关键词不含误伤境外域名的oppo" "$(no "$CODE" 'DOMAIN-KEYWORD,oppo,DIRECT')"
yesno "关键词不含短词mi" "$(no "$CODE" 'DOMAIN-KEYWORD,mi,DIRECT')"
yesno "关键词不含短词vip" "$(no "$CODE" 'DOMAIN-KEYWORD,vip,DIRECT')"
yesno "关键词不含英文常用词honor" "$(no "$CODE" 'DOMAIN-KEYWORD,honor,DIRECT')"
yesno "校验器有关键词顺序闸门(查最后一条)" "$(has "$CODE" 'last < fin')"
yesno "校验器拒绝危险短词" "$(has "$CODE" "DOMAIN-KEYWORD,(mi|vip|oppo|honor|dji|cn|com|app|www),DIRECT")"
SR=$(printf '%s\n' "$CODE" | sed -n '/^write_shadowrocket_conf()/,/^}/p')
# 抽取完整性: 函数改名/签名变化会让 SR 为空, 下面两条 no 断言随即假绿。
grep -q '^write_shadowrocket_conf()' <<<"$SR" || fail "SR 抽取不完整(空抽取会让 RULE-SET/GEOSITE 断言假绿)"
yesno "小火箭配置不依赖外部 RULE-SET" "$(no "$SR" 'RULE-SET')"
yesno "小火箭配置不用未文档化 GEOSITE" "$(no "$SR" 'GEOSITE')"
yesno "README 说明国内域名规则原因" "$(has "$(cat README.md)" '又会让域名请求跳过该规则')"

# ---- v1.1: Claude/TikTok 域名覆盖说明 + IP-CIDR 不照抄 ----
yesno "文档: Claude 第三方域名由兜底代理覆盖" "$(has "$(cat README.md)" 'intercom 客服')"
yesno "文档: 别切全局改为分场景" "$(has "$(cat README.md)" '用配置模式就不用切全局')"
yesno "文档: 明确不能照抄 IP-CIDR" "$(has "$(cat README.md)" '别照抄清单里的 IP-CIDR')"
yesno "文档: TikTok 域名不用单列" "$(has "$(cat README.md)" 'TikTok 域名不用单独列')"
yesno "客户端指南: 同步分场景建议" "$(has "$CODE" '第三方域名一个都不用列就全在代理里')"

# ---- 全项目加固回归: A-C 数据安全 / 自更新 / egress ----
yesno "凭据按字段补齐而非整组重生成" "$(has "$CODE" 'need_uuid=0 need_sid=0 need_keys=0')"
yesno "UUID 变更会打标记" "$(has "$CODE" 'CREDS_UUID_CHANGED=1')"
yesno "users.txt 首行跟随 UUID 同步" "$(has "$CODE" 'tail -n +2 "$USERS_FILE"')"
yesno "reset 会快照服务配置" "$(has "$CODE" '_RESET_SVC_BACKUP=')"
yesno "restore 回滚连服务配置一起还原" "$(has "$CODE" '_reset_svc_restore')"
# 重置会重新挑伪装站, CN 变了就重签证书, 而 state.env 里存的是旧证书的指纹。
# 只回滚 state.env + 服务配置 = 磁盘新证书配旧指纹, 客户端握手全挂,
# 提示却说"已自动回滚"。与修订 13 修的 restore 是同一个形态。
yesno "reset 回滚会快照证书" \
  "$(has "$(awk '/^_reset_svc_snapshot\(\)\{/,/^}/' "$SRC")" 'certs/hy2-cert.pem')"
yesno "reset 回滚会还原证书" \
  "$(has "$(awk '/^_reset_svc_restore\(\)\{/,/^}/' "$SRC")" 'certs/hy2-cert.pem')"
yesno "reset 回滚先还原证书再重启服务" \
  "$([ "$(awk '/^_reset_svc_restore\(\)\{/,/^}/' "$SRC" | grep -n 'certs/hy2-cert.pem\|systemctl restart' | head -1 | cut -d: -f1)" -lt \
      "$(awk '/^_reset_svc_restore\(\)\{/,/^}/' "$SRC" | grep -n 'systemctl restart' | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
yesno "restore 回滚保留原状态副本" "$(has "$CODE" '已自动回滚到恢复前的状态')"
yesno "设备变更后订阅生成失败会报错" "$(has "$CODE" 'if ! gen_sub_files; then')"
yesno "设备变更后会刷新订阅服务" "$(has "$CODE" 'maybe_sub_http')"
yesno "自更新用同目录随机临时文件" "$(has "$CODE" '.pn-update.XXXXXXXXXX')"
yesno "自更新落盘前验语法" "$(has "$CODE" 'bash -n "$stmp"')"
yesno "自更新保留 .prev 备份" "$(has "$CODE" '${self}.prev')"
yesno "自更新支持 rollback" "$(has "$CODE" 'rollback|revert|--rollback')"
yesno "rollback 前验备份语法" "$(has "$CODE" '备份版本语法损坏, 拒绝回滚')"
yesno "update 刷新派生组件" "$(has "$CODE" 'FORCE_UNIT_REFRESH=1')"
yesno "update 刷新 healthcheck" "$(has "$CODE" 'install_healthcheck')"
yesno "出口 IP 有合法性校验" "$(has "$CODE" 'valid_ipv4(){')"
yesno "出口 IP 从响应里提取" "$(has "$CODE" 'extract_ipv4(){')"
# 断言必须限定在 apply_egress 函数体内: 以前查的是全文, 而别处(重启后健康检查)
# 也有同样的 systemctl 判活语句, 于是 apply_egress 改成轮询之后这条仍然假绿。
yesno "apply_egress 验活 REALITY" \
  "$([ "$(awk '/^apply_egress\(\)\{/,/^}/' "$SRC" | grep -c 'wait_active xray')" = 1 ] && echo yes || echo no)"
yesno "apply_egress 验活 sing-box" \
  "$([ "$(awk '/^apply_egress\(\)\{/,/^}/' "$SRC" | grep -c 'wait_active sing-box')" = 1 ] && echo yes || echo no)"
yesno "服务就绪用轮询不用死等" "$(has "$CODE" 'wait_active(){')"
# 固定 sleep 后立刻判活是一类系统性缺陷, 不是个别笔误: 慢机器上服务还没绑定
# 端口就被判"启动失败", 代价分别是 —— 安装中途 die / 回滚一次成功的升级 /
# 白丢 IPv4-only 与 sniff 两层防护 / 误报"内核重载异常"。
# 这里扫全文: 任何 `sleep N` 之后两行内出现 is-active 都算回归。
fixedwait=$(awk '
  { L[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      if (L[i] !~ /^[[:space:]]*sleep[[:space:]]+[0-9]/) continue
      if (L[i] ~ /^[[:space:]]*#/) continue
      for (j = i + 1; j <= i + 2 && j <= NR; j++)
        if (L[j] ~ /systemctl is-active/ && L[j] !~ /^[[:space:]]*#/) printf "%d ", i
    }
  }
' "$SRC")
yesno "没有固定等待后直接判活${fixedwait:+ (行:${fixedwait})}" \
  "$([ -z "$fixedwait" ] && echo yes || echo no)"

# 静态检查指令的语法。写 `# shellcheck disable=SC2086  (说明文字)` 时, 括号里
# 那段会被当成下一个 key=value, 报 SC1125 并**整条忽略** —— 你以为屏蔽了, 其实
# 一条都没屏蔽, 而它自己那条报错还混在 warning 噪音里没人看。这类错只有"恰好
# 有人去读 shellcheck 输出"才会暴露, 所以单独做成闸门。
# 注意这段注释本身不能以 `# shellcheck` 开头: 那会被当成指令去解析, 直接报
# SC1073/SC1072 —— 这个坑我自己在这行上面又踩了一次。
# 所以闸门同时扫 setup.sh 和本文件: 本文件里也写着指令, 一样会被静默忽略。
bad_directive=""
for _df in "$SRC" test/run.sh; do
  bad_directive="${bad_directive}$(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck' "$_df" \
    | grep -vE '^[0-9]+:[[:space:]]*# shellcheck (disable=SC[0-9]+(,SC[0-9]+)*|shell=[a-z]+|source=[^[:space:]]+)$' \
    | cut -d: -f1 | sed "s|^|${_df}:|" | tr '\n' ' ')"
done
yesno "shellcheck 指令语法正确${bad_directive:+ (位置:${bad_directive})}" \
  "$([ -z "$bad_directive" ] && echo yes || echo no)"

# 数组变量与全局颜色常量重名。文件顶部 R/G/Y/B/M/D/N 是颜色常量; 某个函数里写
# `local -a B=()` 会把它在该函数内遮成数组, 之后任何 "${B}" 取到的都是数组第一个
# 元素而不是颜色。ver_gt 里就真的这么写过 —— 只是那个函数恰好不打印颜色才没炸,
# 而静态检查会在别处莫名报 SC2128。改名(va/vb)把隐患消掉, 这里从根上堵住。
# 扫的是 CODE(已去掉整行注释): 否则上面这句"别写 local -a B=()"的说明自己就会被
# 判成冲突 —— 第一版就是这么假红的。
arrnames=$(
  { printf '%s\n' "$CODE" | grep -oE '[A-Za-z_][A-Za-z_0-9]*=\(\)' | sed 's/=()$//'
    printf '%s\n' "$CODE" | grep -oE 'local[[:space:]]+-a[[:space:]]+[A-Za-z_][A-Za-z_0-9]*' | awk '{print $3}'
    printf '%s\n' "$CODE" | grep -oE 'read[[:space:]]+-[a-zA-Z]*a[a-zA-Z]*[[:space:]]+[A-Za-z_][A-Za-z_0-9]*' | awk '{print $2}'
  } | sort -u
)
clash=""
for _cv in R G Y B M D N; do
  printf '%s\n' "$arrnames" | grep -qx "$_cv" && clash="${clash} ${_cv}"
done
yesno "数组变量不与颜色常量重名${clash:+ (冲突:${clash})}" \
  "$([ -z "$clash" ] && echo yes || echo no)"

# 零告警闸门。上面所有闸门都是"针对某个已知实例"的, 而静态检查覆盖的是
# "这一整类"写法问题 —— 它以前在 CI 里是 continue-on-error 的参考项, 所以每类
# 缺陷都只能靠人想起来去扫, 这就是"每次都能翻出旧问题"的结构性原因。
# 本地没装就跳过(Windows 上不常见), CI 里会先装钉死版本, 缺了直接判失败。
if command -v shellcheck >/dev/null 2>&1; then
  if sc_out=$(shellcheck -S warning "$SRC" 2>&1); then
    pass "shellcheck -S warning setup.sh 零告警"
  else
    fail "shellcheck -S warning setup.sh 有告警"
    printf '%s\n' "$sc_out" | head -20 >&2
  fi
else
  skip "shellcheck 未安装, 跳过零告警检查(CI 会装钉死版本)"
fi

yesno "egress 失败会回滚旧出口" "$(has "$CODE" 'EGRESS_URL="$old_egress"')"
yesno "egress 端口做范围校验" "$(has "$CODE" '-gt 65535')"
yesno "egress 探测有备用端点" "$(has "$CODE" 'for ep in https://api.ipify.org https://ifconfig.me')"
yesno "egress 走隧道端到端复测" "$(has "$CODE" 'eip=$(egress_ip_via_proxy)')"
yesno "hy2 绕过 egress 会明确告知" "$(has "$CODE" 'Hysteria2 不支持上游代理')"
yesno "audit 不再把代理可达当出口可用" "$(has "$CODE" '上游代理可达')"

# ---- DNS 泄露自检(proxy dnstest) ----
# 全部价值在"别骗人": 静态审计读真实产物、DoH 探测要求 Status:0 且有 Answer、
# 隧道真起真收。这三条任何一条退化, 用户就会拿着一个假绿灯继续泄露。
yesno "有 dnstest 子命令" "$(has "$CODE" 'cmd_dnstest(){')"
# 分发必须把参数传进去: 少了 shift/\"$@\", `dnstest --client` 的 --client 会被吞掉,
# 用户敲了跟没敲一样 —— 静默失效比报错更难发现。
yesno "dnstest 分发传参" "$(has "$CODE" 'dnstest|dns)    shift || true; cmd_dnstest "$@"')"
yesno "dnstest 进用法表" "$(has "$CODE" 'dnstest [--client]  DNS 泄露自检')"
yesno "有客户端自检清单函数" "$(has "$CODE" 'print_client_checklist(){')"
yesno "dnstest 支持 --client" "$(has "$CODE" '--client|-c) mode="client"')"
# 这份清单会被复制到手机上读, 带上颜色变量或 printf %b 就会粘出一堆 [1;32m。
yesno "清单不带颜色(便于粘到手机)" \
  "$([ "$(awk '/^print_client_checklist\(\)\{/,/^}/' "$SRC" | grep -cE 'echo -e|%b|\$\{[GRNYMBCD]\}')" = 0 ] && echo yes || echo no)"
yesno "清单订阅地址跟随监听地址" "$(has "$CODE" 'base="http://127.0.0.1:${SUB_PORT:-}/${SUB_TOKEN}"')"
yesno "有三端订阅 DNS 审计函数" "$(has "$CODE" 'sub_dns_issues(){')"
yesno "clash nameserver 逐条查(不只查存在)" "$(has "$CODE" '有 nameserver 条目没经代理')"
yesno "DoH 探测要求 Status:0" "$(has "$CODE" '"Status":0')"
yesno "DoH 探测要求有 Answer" "$(has "$CODE" '"Answer"')"
yesno "隧道抽成 start/stop 复用" "$(has "$CODE" 'tunnel_start(){')"
yesno "隧道配置单独成函数(可测)" "$(has "$CODE" 'tunnel_config_json(){')"
yesno "出口实测复用同一套隧道" \
  "$([ "$(awk '/^egress_ip_via_proxy\(\)\{/,/^}/' "$SRC" | grep -c 'tunnel_start')" = 1 ] && echo yes || echo no)"
yesno "dnstest 明确划出客户端边界" "$(has "$CODE" '客户端侧(服务端测不到')"
yesno "有 dnstest 行为验证脚本" "$([ -f test/dnstest_behavior.sh ] && echo yes || echo no)"

# ---- 证书指纹: 两种算法都要真的算出来 ----
# hysteria2 的 pinSHA256 要整证书 DER 的 hex, sing-box 要公钥 SPKI 的 base64。
# 曾经这里只剩 SPKI 一项、CERT_HEX 全脚本没人赋值 —— compute_cert_pins 恒失败,
# ensure_hy2 每次都 die, 默认组合 reality,hy2 根本装不完。这条断言守的就是它。
yesno "compute_cert_pins 真的算整证书 hex" \
  "$(has "$CODE" 'CERT_HEX=$(openssl x509 -in "$cert" -noout -fingerprint -sha256')"
yesno "compute_cert_pins 真的算 SPKI base64" \
  "$(has "$CODE" 'CERT_SPKI_B64=$(openssl x509 -in "$cert" -pubkey -noout')"
yesno "证书指纹函数可传路径(可测)" "$(has "$CODE" 'local cert="${1:-/etc/hysteria/cert.pem}"')"
yesno "HY2 的 pin 取自整证书 hex" "$(has "$CODE" 'HY2_PIN="${CERT_HEX:-}"')"
yesno "有证书指纹行为验证脚本" "$([ -f test/cert_pin_behavior.sh ] && echo yes || echo no)"

# 凭据键"只读不写"是这一类缺陷的共同形态: 键被写进 state.env、被 safe_cred_scalars
# 校验、被 die 分支当成功条件, 却没有任何一处真的给它赋值。用 KEY="" 清空也算赋值,
# 所以这里要求赋值右侧不是空串。CRED_KEYS 里每个键都必须有一条这样的赋值。
cred_noassign=""
for _ck in $(sed -n 's/^CRED_KEYS="\(.*\)"/\1/p' "$SRC"); do
  grep -qE "(^|[[:space:];])(local[[:space:]]+)?${_ck}=(\"|')?[^\"'[:space:];]" "$SRC" \
    || cred_noassign="${cred_noassign} ${_ck}"
done
yesno "凭据键都有真实赋值来源${cred_noassign:+ (缺:${cred_noassign})}" \
  "$([ -z "$cred_noassign" ] && echo yes || echo no)"

# state.env 三方闭合: STATE_KEYS(白名单) == save_state 写入 == 真的有人读。
# 多写少读 = 死字段(每次安装白算一遍、白占一行、白多校验一个值);
# 少写多读 = 读回来永远是空值(配置里少一行, 客户端连不上)。
# 实际抓到过 SB_HEX: 算了、写了、进了 CRED_KEYS, 全脚本却没人读。
st_save=$(awk '/^save_state\(\)\{/,/^}/' "$SRC" | sed -n 's/^[[:space:]]*state_line \([A-Za-z_0-9]*\) .*/\1/p' | sort -u)
st_keys=$(sed -n 's/^STATE_KEYS="\(.*\)"/\1/p' "$SRC" | tr ' ' '\n' | sed '/^$/d' | sort -u)
t "STATE_KEYS 与 save_state 写入一致" "$(printf '%s\n' "$st_keys")" "$(printf '%s\n' "$st_save")"
# 读的地方要把 save_state / load_state 两段排除掉, 否则它们自己就算"读过"。
st_read=$(awk '
  /^(save_state|load_state)\(\)\{/ { skip=1 }
  skip && /^\}/ { skip=0; next }
  !skip { print }
' "$SRC" | grep -oE '\$\{?[A-Z_][A-Z_0-9]*' | sed 's/^\${*//' | sort -u)
st_dead=""
for _k in $st_keys; do
  printf '%s\n' "$st_read" | grep -qx "$_k" || st_dead="${st_dead} ${_k}"
done
yesno "状态字段都有读取方(无只写不读)${st_dead:+ (残留:${st_dead})}" \
  "$([ -z "$st_dead" ] && echo yes || echo no)"

# ---- 死代码: 定义了却没有任何调用点的函数 ----
# 精简是硬要求, 而"重构后忘了删旧函数"是最容易积累的一类。这里数引用次数:
# 注释行不算; 定义行本身也会匹配到自己的名字, 所以要扣掉一次 —— 不扣的话
# 每个函数都至少"有 1 次引用", 这条断言永远为真。
deadfns=$(awk '
  /^[A-Za-z_][A-Za-z_0-9]*\(\)\{/ { name=$0; sub(/\(\).*/,"",name); def[name]=NR; order[++n]=name }
  { body[NR]=$0 }
  END {
    for (i=1;i<=n;i++) {
      name=order[i]; cnt=0
      for (j=1;j<=NR;j++) {
        line=body[j]
        if (line ~ /^[[:space:]]*#/) continue
        if (line !~ ("(^|[^A-Za-z_0-9-])" name "([^A-Za-z_0-9]|$)")) continue
        cnt++
      }
      if (cnt > 0 && def[name]) cnt--
      if (cnt <= 0) printf "%s ", name
    }
  }
' "$SRC")
yesno "没有从未被调用的死函数${deadfns:+ (残留:${deadfns})}" \
  "$([ -z "$deadfns" ] && echo yes || echo no)"

# ---- 全项目加固回归: D-F 内核兼容 / 自检 / 失败聚合 / 链接 ----
yesno "sing-box 真实探测 AF_INET6" "$(has "$CODE" 'socket.AF_INET6')"
yesno "sing-box 启动失败回退 v4" "$(has "$CODE" 'SB_FORCE_V4=1')"
yesno "包管理器失败不再全吞" "$(has "$CODE" '包管理器执行失败')"
yesno "缺依赖时明确 die" "$(has "$CODE" 'die "缺少必需依赖')"
yesno "hysteria 重装会比对版本" "$(has "$CODE" '_hy2_ver=')"
yesno "自检缺文件不再假绿" "$(has "$CODE" '文件不存在: ')"
yesno "自检检查订阅文件存在" "$(has "$CODE" 'clash.yaml 不存在')"
yesno "备份拒绝父目录符号链接" "$(has "$CODE" '备份目录是符号链接')"
yesno "备份父目录解析成物理路径" "$(has "$CODE" '备份目录解析后落在系统目录')"
yesno "user rm 用随机临时文件" "$(has "$CODE" '.users.XXXXXXXX')"
yesno "user rm 结果行数异常即中止" "$(has "$CODE" '结果异常(')"
yesno "user rm 不再无条件 mv 固定 .tmp" "$(no "$CODE" 'grep -vxF "$line" "$USERS_FILE" > "${USERS_FILE}.tmp"')"
yesno "read_tty 遇信号直接退出" "$(has "$CODE" 'exit "$__rc"')"
yesno "Google 地区在 cc 为空时不假红" "$(has "$CODE" '无法判定是否换区')"
yesno "出口探测用独立进程组" "$(has "$CODE" 'setsid "$XRAY_BIN"')"
yesno "出口探测轮询端口就绪" "$(has "$CODE" 'kill -0 "$pid"')"
yesno "隧道先查端口占用" \
  "$([ "$(awk '/^tunnel_start\(\)\{/,/^}/' "$SRC" | grep -c '/dev/tcp/127.0.0.1/${TUNNEL_PORT}')" -ge 2 ] && echo yes || echo no)"
yesno "出口探测不再固定 sleep 3 + 裸 kill" "$(no "$CODE" 'kill $pid >/dev/null 2>&1')"
yesno "HY2_HOP 非法区间统一清空" "$(has "$CODE" '不是合法的端口区间')"
yesno "URI fragment 做百分号编码" "$(has "$CODE" 'uri_fragment(){')"
yesno "分享链接改用编码后的 fragment" "$(has "$CODE" '#${_frag}-')"
yesno "分享链接不再直接拼 NODE_NAME" "$(no "$CODE" '#${NODE_NAME}-')"
yesno "v2rayn TUIC 复用标准链接" "$(has "$CODE" 'proto_on tuic   && printf')"
yesno "v2rayn 不再手拼漏参数的 TUIC" "$(no "$CODE" '&alpn=h3&allow_insecure=1#%s-TUIC')"
yesno "订阅 JSON 生成后有结构校验" "$(has "$CODE" 'sub_json_ok(){')"
yesno "订阅 YAML 生成后有结构校验" "$(has "$CODE" 'sub_yaml_ok(){')"
yesno "订阅写盘失败会中止" "$(has "$CODE" '订阅文件生成后校验失败')"
yesno "防火墙失败会被聚合" "$(has "$CODE" 'setup_firewall || deploy_bad=1')"
yesno "部署有失败横幅" "$(has "$CODE" '部署完成, 但有项目失败')"
yesno "部署失败返回非 0 退出码" "$(has "$CODE" 'return "$deploy_bad"')"
yesno "向导不吞 install 的失败码" "$(has "$CODE" 'cmd_install || return 1')"

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
    # harness 是非交互的: stdin 必须断开。Windows 下 mktemp -d 会返回
    # C:\...\Temp/tmp.XXX 这种混合路径, grep 等工具遇到判为无效的文件参数会回退
    # 读 stdin; 而 harness 的 stdin 是上游管道, 于是一直等下去 —— 整套回归直接卡死。
    echo 'exec </dev/null'
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
    # harness 内也会遇到工具缺失; CI 下必须判失败, 不能用 say SKIP 蒙混过关
    echo 'skip(){ if [ -n "${CI:-}" ]; then bad "$1 (CI 下不允许 SKIP)"; else say "SKIP $1"; fi; }'
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
  local h="$1" sd="$2" out rc
  out=$(bash "$h" "$sd" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^(PASS|FAIL|DIE)' || true
  tally "$out" "$rc" 1 "harness $h"
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

# safe_state_scalars: 控制字符/换行必须清空, 否则会跨行写坏 state.env 与 systemd unit。
# 以前只被 load_state 间接覆盖, 函数本身改坏(比如循环写错键名)测试不会红。
NODE_NAME=$'evil\nname'
DEST=$'bad\tdomain'
safe_state_scalars
t "safe_state_scalars 清掉 NODE_NAME 换行" "$NODE_NAME" ""
t "safe_state_scalars 清掉 DEST 制表符" "$DEST" ""
NODE_NAME="Tokyo-1"; DEST="www.bing.com"
safe_state_scalars
t "safe_state_scalars 不动正常值" "$NODE_NAME|$DEST" "Tokyo-1|www.bing.com"

# 节点名长度上限: 超长会拼出超限 URI, 必须截到 64
_long=$(printf 'a%.0s' $(seq 1 100))
_sn=$(sanitize_node_name "$_long")
t "sanitize_node_name 截到 64 字符" "${#_sn}" "64"

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
# load_state 会调 safe_cred_scalars: 带 shell 元字符的 EGRESS_URL
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
if mk_harness "$H2" hop_cleanup_rules setup_firewall firewall_undo ufw_active; then
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
  tally "$(cat "$TD/rules.out")" "$rc" 1 "规则 harness"
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
    SUBROOT="$TD/sub"; mkdir -p "$SUBROOT/tok123" "$SUBROOT/othertok"
    printf 'hello\n' > "$SUBROOT/tok123/clash.yaml"
    printf '[General]\n' > "$SUBROOT/tok123/shadowrocket.conf"
    printf '{}\n' > "$SUBROOT/tok123/v2rayn-routed.json"
    printf 'secret\n' > "$SUBROOT/tok123/private.txt"
    # 穿越测试要真能暴露漏洞: 把秘密文件放在"能被 ../ 够到"的位置。
    # 以前只在 tok123/ 里建文件, ../clash.yaml 归一到 /clash.yaml 本就不存在,
    # 404 是"文件不存在"给的, 路径校验坏了也照样绿。
    printf 'ROOT_SECRET\n' > "$SUBROOT/clash.yaml"
    printf 'OTHER_SECRET\n' > "$SUBROOT/othertok/clash.yaml"

    # 单进程内起服务 + 发真实 HTTP 请求。以前用 `python server.py &` + curl:
    # 后台服务会挂住整个命令直到被 SIGTERM, 而且 Windows Python 打不开 MSYS
    # 形式的脚本路径。这里用 importlib 加载产品源码(__name__ != "__main__",
    # main() 不会自动跑), 线程起 ThreadingHTTPServer, http.client 发未经
    # 规范化的原始路径(等价 curl --path-as-is), 结束前 shutdown, 不留孤儿进程。
    cat > "$TD/sub_test.py" <<'PYTEST'
import http.client, importlib.util, os, socket, sys, threading, time

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
    ("/tok123/shadowrocket.conf", 200, "小火箭配置在订阅白名单 -> 200"),
    ("/tok123/v2rayn-routed.json", 200, "v2rayN路由配置在订阅白名单 -> 200"),
    ("/wrongtok/clash.yaml", 404, "错 token -> 404"),
    ("/tok123/private.txt", 404, "非白名单文件 -> 404"),
    ("/", 404, "根路径不列目录 -> 404"),
    ("/tok123/../clash.yaml", 404, "目录穿越到根秘密文件 -> 404"),
    ("/tok123/../othertok/clash.yaml", 404, "穿越到别的 token -> 404"),
    ("/tok123/%2e%2e/clash.yaml", 404, "URL 编码穿越 -> 404"),
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

# 半开连接防护。ThreadingHTTPServer 一个连接一个线程, 而 BaseHTTPRequestHandler
# 的 timeout 默认是 None: 只连不发字节的客户端会让线程永远挂在 readline 上,
# 几百个就能吃光这个公网进程的内存。产品里是 30 秒, 这里用 1 秒的子类实测机制
# 真的生效 —— 只断言"属性被设了"证明不了标准库会照它关连接。
tmo = getattr(mod.Handler, "timeout", None)
print("PASS 订阅服务设置了连接超时(%s 秒)" % tmo if tmo else "FAIL 订阅服务没有连接超时")
if not tmo:
    bad += 1

class Fast(mod.Handler):
    timeout = 1

srv2 = mod.ThreadingHTTPServer(("127.0.0.1", 0), Fast)
p2 = srv2.server_address[1]
threading.Thread(target=srv2.serve_forever, daemon=True).start()
sock = socket.create_connection(("127.0.0.1", p2), timeout=6)
sock.settimeout(6)
t0 = time.time()
try:
    closed = sock.recv(100) == b""
except Exception:
    closed = False
el = time.time() - t0
sock.close()
srv2.shutdown()
srv2.server_close()
ok_half = closed and el < 5
print(("PASS 半开连接被超时关闭 (%.1fs)" % el) if ok_half
      else ("FAIL 半开连接没被关闭 (%.1fs)" % el))
if not ok_half:
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
    tally "$(cat "$TD/sub.out")" "$rc" 1 "订阅服务驱动"
    if [ "$rc" -ne 0 ]; then
      cat "$TD/sub.out" >&2
      fail "订阅服务驱动脚本非零退出(rc=${rc}, 124=超时/挂死)"
    fi
  else
    fail "订阅服务源码抽取失败(测试桩坏了)"
  fi
else
  skip "python3 不可用"
fi

# ---------------------------------------------------------------- 6. 前代加固行为回归
say "== 6. 前代加固行为回归 =="
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
  # Windows / 部分容器建不了 symlink。不静默 SKIP —— 改查源码里那道"父目录
  # 解析成物理路径再比对前缀"的闸门, 保证这个安全性质仍然被断言覆盖。
  # 这里是 harness 进程, $CODE 不可用, 直接读仓库根下的 setup.sh。
  if grep -qF 'realdir=$(cd -P "$(dirname "$out")" 2>/dev/null && pwd -P)' setup.sh; then
    pass "父目录按物理路径解析(静态)"
  else bad "父目录按物理路径解析(静态)"; fi
  if grep -qF '诊断报告目录解析后不在 /root/ 或 /tmp/ 下' setup.sh; then
    pass "父目录解析结果限定安全前缀(静态)"
  else bad "父目录解析结果限定安全前缀(静态)"; fi
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

# 诊断报告是要外发的。CRED_KEYS 里每一个凭据都必须登记进脱敏清单, 漏一个就等于
# 把整套连接凭据的一部分公开出去。按数据源自动比对: 以后往 CRED_KEYS 加字段
# 而忘了登记脱敏, 这里会当场报红。
# 注意这条必须在 harness 的 heredoc 之外 —— 里面没有 $SRC, set -u 会直接退出。
diag_miss=""
for _dk in $(sed -n 's/^CRED_KEYS="\(.*\)"/\1/p' "$SRC") UUID PRIV PUB SID EGRESS_URL; do
  grep -qF "diag_sec \"\${${_dk}:-}\"" "$SRC" || diag_miss="${diag_miss} ${_dk}"
done
yesno "诊断报告脱敏覆盖全部凭据${diag_miss:+ (漏:${diag_miss})}" \
  "$([ -z "$diag_miss" ] && echo yes || echo no)"

# ---- verify_sha256: 安全关键闸门必须真的中止(以前只有字符串反断言) ----
SD7="$TD/verify"; mkdir -p "$SD7"
H7="$TD/verify-h.sh"
if mk_harness "$H7" file_sha256 verify_sha256; then
cat >> "$H7" <<'BODY'
F="$STATE_DIR/bin.bin"
printf 'hello-world' > "$F"
GOOD=$(file_sha256 "$F")
t "file_sha256 长度 64" "$(printf '%s' "$GOOD" | wc -c | tr -d ' ')" "64"
t "哈希一致 -> 通过" "$(r verify_sha256 "$F" "$GOOD" test)" yes
t "哈希不一致 -> 拒绝" "$(r verify_sha256 "$F" "0000000000000000000000000000000000000000000000000000000000000000" test)" no
ALLOW_UNVERIFIED_BIN=0
t "期望为空且未放行 -> 拒绝" "$(r verify_sha256 "$F" "" test)" no
ALLOW_UNVERIFIED_BIN=1
t "显式 ALLOW_UNVERIFIED_BIN=1 -> 放行" "$(r verify_sha256 "$F" "" test)" yes
BODY
  run_harness "$H7" "$SD7"
else
  fail "verify harness 生成失败"
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
ck("默认命令仍用 mktemp 随机路径", base.indexOf("f=$(mktemp)") >= 0);
ck("默认命令仍做 bash -n", base.indexOf('bash -n "$f"') >= 0);
ck("默认命令先验语法再落盘", base.indexOf('bash -n "$f"&&install -m755') >= 0);
ck("默认命令会清临时文件", base.indexOf('&&rm "$f"') >= 0);
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
ck("注入后命令仍完整可执行", evil.indexOf("f=$(mktemp)") >= 0);
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
// 从落盘+清临时文件那一步之后截到 "bash /root/setup-proxy.sh" 之前。
const anchor = 'install -m755 "$f" /root/setup-proxy.sh&&rm "$f"&&';
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
  tally "$(cat "$TD/docs.out")" "$rc" 1 "命令生成器驱动"
  if [ "$rc" -ne 0 ]; then
    cat "$TD/docs.out" >&2
    fail "命令生成器驱动非零退出(rc=${rc}, 124=超时/挂死)"
  fi
else
  skip "node 不可用(静态断言已在第 1 节覆盖)"
fi

# ---------------------------------------------------------------- 8. DNS / IPv6 加固行为回归
say "== 8. DNS / IPv6 加固行为回归 =="
H="$TD/hy2-cfg-h.sh"
if mk_harness "$H" write_hy2_config; then
cat >> "$H" <<'BODY'
has(){ case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
no(){ case "$1" in *"$2"*) echo no ;; *) echo yes ;; esac; }
HY2_CFG="$STATE_DIR/hy2.yaml"
ENABLE_OBFS=0
HY2_PORT=443
HY2_PASS="x"
DEST="www.bing.com"

write_hy2_config 1 1
f=$(cat "$HY2_CFG")
t "全开: 有 sniff"                "$(has "$f" 'rewriteDomain: true')" yes
t "全开: 有 mode 4"              "$(has "$f" 'mode: 4')" yes
t "全开: 有 outbounds"           "$(has "$f" 'outbounds:')" yes

write_hy2_config 1 0
f=$(cat "$HY2_CFG")
t "只丢 IPv4: sniff 仍在"         "$(has "$f" 'rewriteDomain: true')" yes
t "只丢 IPv4: mode 4 已去掉"     "$(no "$f" 'mode: 4')" yes

write_hy2_config 0 0
f=$(cat "$HY2_CFG")
t "两级全丢: sniff 已去掉"        "$(no "$f" 'rewriteDomain: true')" yes
t "两级全丢: mode 4 已去掉"       "$(no "$f" 'mode: 4')" yes
t "两级全丢: 配置骨架仍完整"      "$(has "$f" 'masquerade:')" yes
BODY
  run_harness "$H" "$TD"
else
  fail "hy2 配置 harness 生成失败"
fi

# 服务端 sing-box 配置是手写拼的 JSON, 多一条规则就多一处逗号风险。
# 这里真跑一次 write_singbox_config(桩掉内核 check), 把产物交给 json 解析器验。
H="$TD/sb-cfg-h.sh"
if mk_harness "$H" write_singbox_config; then
cat >> "$H" <<'BODY'
has(){ case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
no(){ case "$1" in *"$2"*) echo no ;; *) echo yes ;; esac; }
sb_enabled(){ return 0; }
sb_listen_addr(){ echo "::"; }
proto_on(){ [ "$1" = "ss2022" ]; }
sb_users_json(){ printf '[]'; }
parse_egress(){ return 1; }
DEST="www.bing.com"
SB_CERT="/tmp/c.pem"; SB_KEY="/tmp/k.pem"
SB_CFG="$STATE_DIR/sb.json"
SB_BIN="$(command -v true 2>/dev/null || echo /bin/true)"
SS2022_PORT=8443
SS2022_PASS="x"
UUID="u"

write_singbox_config
f=$(cat "$SB_CFG")
t "服务端配置含 IPv6 拦截"      "$(has "$f" '"ip_version": 6')" yes
t "服务端配置含 block 出站"     "$(has "$f" '"tag": "block"')" yes
t "服务端配置含 sniff"          "$(has "$f" '"action": "sniff"')" yes
t "服务端配置 final 指向 direct" "$(has "$f" '"final": "direct"')" yes
t "服务端配置无 1.13 的 reject" "$(no "$f" '"action": "reject"')" yes
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SB_CFG" >/dev/null 2>&1 \
    && pass "服务端配置是合法 JSON" || bad "服务端配置不是合法 JSON"
else
  skip "python3 不可用, 未校验服务端 JSON"
fi
BODY
  run_harness "$H" "$TD"
else
  fail "sing-box 配置 harness 生成失败"
fi

# ---------------------------------------------------------------- 9. 加固后纯函数行为回归
say "== 9. 加固后纯函数行为回归 =="
H="$TD/hardening-h.sh"
if mk_harness "$H" uri_fragment valid_ipv4 extract_ipv4 sub_json_ok sub_yaml_ok \
               install_script_file ver_gt script_newer; then
cat >> "$H" <<'BODY'
r(){ if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

# --- URI fragment 百分号编码 ---
t "fragment: ASCII 安全字符不变"    "$(uri_fragment 'Node-1_A.2~x')" 'Node-1_A.2~x'
t "fragment: 百分号被编码"          "$(uri_fragment '100%')" '100%25'
t "fragment: 斜杠被编码"            "$(uri_fragment 'A/B')" 'A%2FB'
t "fragment: 问号被编码"            "$(uri_fragment 'A?B')" 'A%3FB'
t "fragment: 中文按 UTF-8 逐字节"   "$(uri_fragment '一号')" '%E4%B8%80%E5%8F%B7'
t "fragment: 空串不报错"            "$(uri_fragment '')" ''

# --- 出口 IP 校验 ---
t "valid_ipv4: 正常"               "$(r valid_ipv4 1.2.3.4)" yes
t "valid_ipv4: 超 255 拒绝"        "$(r valid_ipv4 1.2.3.999)" no
t "valid_ipv4: 段数不足拒绝"       "$(r valid_ipv4 1.2.3)" no
t "valid_ipv4: 字母拒绝"           "$(r valid_ipv4 1.2.3.a)" no
t "valid_ipv4: 空值拒绝"           "$(r valid_ipv4 '')" no
t "extract_ipv4: 噪声里取合法 IP"  "$(extract_ipv4 'HTTP 500 1.2.3.999 then 8.8.8.8 ok')" '8.8.8.8'
t "extract_ipv4: 全噪声返回失败"   "$(r extract_ipv4 'no ip here')" no

# --- 订阅产物结构校验 ---
printf '{"outbounds":[{"type":"direct"}]}\n' > "$STATE_DIR/good.json"
printf '{"outbounds":['                    > "$STATE_DIR/bad.json"
printf '{"foo":1}\n'                       > "$STATE_DIR/noout.json"
: > "$STATE_DIR/empty.json"
t "sub_json_ok: 合法 JSON 通过"     "$(r sub_json_ok "$STATE_DIR/good.json")" yes
t "sub_json_ok: 截断 JSON 拒绝"     "$(r sub_json_ok "$STATE_DIR/bad.json")" no
t "sub_json_ok: 空文件拒绝"         "$(r sub_json_ok "$STATE_DIR/empty.json")" no
t "sub_json_ok: 无 outbounds 拒绝"  "$(r sub_json_ok "$STATE_DIR/noout.json")" no
printf 'proxies:\n  - name: "N-VLESS"\ndns:\n  enhanced-mode: fake-ip\n  nameserver-policy:\n    "geosite:cn,private":\n      - https://doh.pub/dns-query\n  nameserver:\n    - https://cloudflare-dns.com/dns-query#PROXY\nrules:\n  - AND,((NETWORK,udp),(DST-PORT,3478)),REJECT\n  - MATCH,PROXY\n' > "$STATE_DIR/good.yaml"
printf 'proxies:\n  - name: "N"\n' > "$STATE_DIR/bad.yaml"
: > "$STATE_DIR/empty.yaml"
t "sub_yaml_ok: 完整订阅通过"       "$(r sub_yaml_ok "$STATE_DIR/good.yaml")" yes
t "sub_yaml_ok: 缺 rules 拒绝"      "$(r sub_yaml_ok "$STATE_DIR/bad.yaml")" no
t "sub_yaml_ok: 空文件拒绝"         "$(r sub_yaml_ok "$STATE_DIR/empty.yaml")" no

# --- 自更新同目录原子替换 ---
SELF="$STATE_DIR/setup.sh"; TMP="$STATE_DIR/new.sh"
printf '#!/usr/bin/env bash\necho old\n' > "$SELF"
printf '#!/usr/bin/env bash\necho new\n' > "$TMP"
t "install_script_file: 成功返回 0" "$(r install_script_file "$TMP" "$SELF")" yes
t "install_script_file: 内容已替换" "$(tail -1 "$SELF")" 'echo new'
t "install_script_file: .prev 留旧版" "$(tail -1 "${SELF}.prev")" 'echo old'
t "install_script_file: 临时文件已清理" "$(r test -e "$TMP")" no
printf '#!/usr/bin/env bash\nif [ ;\n' > "$TMP"
t "install_script_file: 语法坏版被拒" "$(r install_script_file "$TMP" "$SELF")" no
t "install_script_file: 拒绝后原文件不动" "$(tail -1 "$SELF")" 'echo new'

# --- 纯版本号严格递增: script_newer 只认版本号, 不再有世代号 ---
SCRIPT_VERSION="1.0"
t "ver_gt: 1.0 不比 1.1 新"          "$(r ver_gt 1.0 1.1)" no
t "ver_gt: 1.1 比 1.0 新"            "$(r ver_gt 1.1 1.0)" yes
t "script_newer: 版本号更高即更新"    "$(r script_newer 1.1)" yes
t "script_newer: 同版本号不判更新"    "$(r script_newer 1.0)" no
t "script_newer: 低版本号不判更新"    "$(r script_newer 0.9)" no
t "script_newer: 第三段递增也识别"    "$(r script_newer 1.0.1)" yes
BODY
  run_harness "$H" "$TD"
else
  fail "加固纯函数 harness 生成失败"
fi

# build_clients_json 以前少了 `|| [ -n "$u" ]`: users.txt 末行无换行时
# 最后一台设备被静默丢出 Xray clients。这里真跑一次函数验证, 不只查字符串。
H="$TD/clients-h.sh"
if mk_harness "$H" json_esc build_clients_json; then
cat >> "$H" <<'BODY'
has(){ case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
USERS_FILE="$STATE_DIR/users.txt"
UUID="main-uuid"
# 故意让最后一行不带换行
printf 'aaa|phone|2026-01-01\nbbb|laptop|2026-01-02' > "$USERS_FILE"
build_clients_json
t "末行无换行: 首台设备在 clients 里"  "$(has "$CLIENTS_JSON" 'aaa')" yes
t "末行无换行: 末台设备也在 clients 里" "$(has "$CLIENTS_JSON" 'bbb')" yes
t "末行无换行: 设备名带上"          "$(has "$CLIENTS_JSON" '"email": "laptop"')" yes
t "末行无换行: 仍是合法 JSON 数组"    "$(printf '%s' "$CLIENTS_JSON" | python -c 'import json,sys; print("yes" if isinstance(json.load(sys.stdin),list) else "no")' 2>/dev/null)" yes
BODY
  run_harness "$H" "$TD"
else
  fail "build_clients_json harness 生成失败"
fi

# 读取侧兜住了"末行无换行", 写入侧以前没有: `user add` 直接 printf >> 会粘在
# 最后一行后面, 两台设备的凭据合成一行 —— 老设备失效, 新设备显示成乱码,
# 两边都不报错。这里真跑 ensure_users_file, 验证它会把缺的换行补上。
H2U="$TD/users-h.sh"
if mk_harness "$H2U" ensure_users_file; then
cat >> "$H2U" <<'BODY'
USERS_FILE="$STATE_DIR/users.txt"
UUID="main-uuid"
CREDS_UUID_CHANGED=0
printf 'aaa|phone|2026-01-01\nbbb|laptop|2026-01-02' > "$USERS_FILE"
ensure_users_file
# 必须在追加之前查: 追加语句自己带 \n, 追加之后再查永远为真, 断言就没有意义了。
# `tail -c 1` 输出为空 == 最后一个字节是换行(命令替换会吃掉末尾换行)。
t "末行无换行: ensure_users_file 补齐了换行" \
  "$([ -z "$(tail -c 1 "$USERS_FILE")" ] && echo yes || echo no)" yes
# 补完换行之后, 模拟 user add 的追加
printf '%s|%s|%s\n' "ccc" "tablet" "2026-01-03" >> "$USERS_FILE"
t "末行无换行: 追加后行数为 3(没和末行合并)" "$(wc -l < "$USERS_FILE" | tr -d ' ')" 3
t "末行无换行: 原末行设备名仍完整" \
  "$(sed -n '2p' "$USERS_FILE" | awk -F'|' '{print $2}')" laptop
t "末行无换行: 新设备独占一行" \
  "$(sed -n '3p' "$USERS_FILE" | awk -F'|' '{print $2}')" tablet
# 已经以换行结尾的文件不该被再加一个空行
printf 'aaa|phone|2026-01-01\n' > "$USERS_FILE"
ensure_users_file
t "已有换行: 不会多加空行" "$(wc -l < "$USERS_FILE" | tr -d ' ')" 1
BODY
  run_harness "$H2U" "$TD"
else
  fail "ensure_users_file harness 生成失败"
fi

# ---------------------------------------------------------------- 10. 行为验证脚本(mock, 不联网)
# 每个脚本登记"至少应跑多少条断言"。阈值取实际条数附近: 以前统一写 5,
# 而真实是 8~55 条, 脚本跑到一半就退也能混过闸门。改断言数时同步这里。
say ""
say "== 10. 行为验证脚本 =="
for pair in \
  "xray_hash_behavior.sh:10" \
  "hy2_hash_behavior.sh:17" \
  "hy2_resolve_behavior.sh:8" \
  "shadowrocket_conf_behavior.sh:55" \
  "rule_source_behavior.sh:15" \
  "clash_yaml_behavior.sh:41" \
  "egress_behavior.sh:32" \
  "dnstest_behavior.sh:38" \
  "cert_pin_behavior.sh:13"; do
  bt="${pair%%:*}"; bmin="${pair##*:}"
  if [ ! -f "test/$bt" ]; then
    fail "缺少行为验证脚本 test/$bt"
    continue
  fi
  # 不能 `|| true` 吞掉退出码: 行为脚本用末尾的 `[ "$F" -eq 0 ]` 表达成败。
  # 只数 PASS/FAIL 文本的话, 脚本打印若干 PASS 后异常退出也会被判绿。
  brc=0
  bout=$( cd test && bash "$bt" 2>&1 ) || brc=$?
  bp=$(printf '%s\n' "$bout" | grep -c '^PASS ' || true)
  bf=$(printf '%s\n' "$bout" | grep -c '^FAIL ' || true)
  PASS=$((PASS + bp)); FAIL=$((FAIL + bf))
  [ "$bp" -ge "$bmin" ] || fail "$bt: 断言数不足(${bp} < ${bmin}), 测试桩可能没跑起来"
  [ "$brc" -eq 0 ] || fail "$bt: 退出码 ${brc}(非0), 断言计数达标也不算通过"
  if [ "$bf" -gt 0 ]; then
    printf '%s\n' "$bout" | grep '^FAIL ' | sed 's/^/    /'
  fi
done

# ---------------------------------------------------------------- 11. CI 工作流自检
# CI 的 run: 默认是 bash -e -o pipefail。以前步骤里写了
#   out=$(bash setup.sh version | head -1)
# head 读够一行就关管道, 还在往 stdout 写的 setup.sh 收到 SIGPIPE(exit 141),
# 整条管道判失败、-e 直接中止 —— CI 从建库起就是红的, 而且卡在第二个步骤,
# 后面的回归套件根本没跑过。闸门本身坏了比没有闸门更糟: 它给人"有在检查"的错觉。
say ""
say "== 11. CI 工作流自检 =="
CIY=".github/workflows/ci.yml"
if [ -f "$CIY" ]; then
  yesno "CI 里没有 | head 管道(SIGPIPE 会让步骤假失败)" \
    "$([ "$(grep -cE '\| *head -[n]? *[0-9]' "$CIY")" = 0 ] && echo yes || echo no)"
  yesno "CI 用参数展开截首行而非 head" "$(has "$(cat "$CIY")" 'out=${out%%')"
  yesno "CI 校验两份脚本语法" "$(has "$(cat "$CIY")" 'bash -n setup-proxy.sh')"
  yesno "CI 回归套件注入 CI=true" "$(has "$(cat "$CIY")" 'CI: "true"')"
  yesno "CI 有 LF 闸门" "$(has "$(cat "$CIY")" "printf '\\r'")"
  yesno "CI 有敏感信息扫描" "$(has "$(cat "$CIY")" 'BEGIN [A-Z ]*PRIVATE KEY')"
  # 静态检查以前是 continue-on-error 的"参考项", 等于没有闸门 —— 每一类写法
  # 问题都只能靠人想起来去扫, 这就是"每次都能翻出旧问题"的结构性原因。
  # 现在它是硬闸门, 这里守住"别被降级回去": 出现 continue-on-error 或"参考项"
  # 字样就判失败。
  # 只认 YAML 键(`continue-on-error:` 顶格或缩进开头), 不认注释里提到的字样 ——
  # 否则上面那段说明"以前是 continue-on-error"的注释自己就会把闸门打红。
  yesno "CI 的 shellcheck 是硬闸门(没有 continue-on-error)" \
    "$([ "$(grep -cE '^[[:space:]]*continue-on-error:' "$CIY")" = 0 ] && echo yes || echo no)"
  yesno "CI 装了 shellcheck 并钉死版本" "$(has "$(cat "$CIY")" 'shellcheck-${SC_VER}.linux.x86_64.tar.xz')"
  yesno "CI 断言 shellcheck 版本没漂移" "$(has "$(cat "$CIY")" 'shellcheck 版本漂移')"
else
  fail "缺少 CI 工作流文件 $CIY"
fi

# ---------------------------------------------------------------- 汇总
say ""
say "================================================"
say "  PASS ${PASS}   FAIL ${FAIL}"
say "================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
