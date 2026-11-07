#!/usr/bin/env bash
# ============================================================
#  Proxy Node Installer  (版本号见 SCRIPT_VERSION)
#  Reality / Hysteria2 / SS2022 / AnyTLS / TUIC v5 任选组合
#  一键部署 + 部署向导 + VPS 优化 + 日常管理 + 订阅生成
# ------------------------------------------------------------
#  适用: Debian 11/12  Ubuntu 20/22/24  CentOS/Rocky/Alma 8/9
#  用法:
#     bash setup-proxy.sh              部署向导(选协议/优化/清理), 已装=管理菜单
#     bash setup-proxy.sh install      直接安装(幂等, 不重置凭据)
#     bash setup-proxy.sh install --clean  清理旧实例后全新安装(端口冲突用)
#     bash setup-proxy.sh fresh        等同 install --clean
#     bash setup-proxy.sh optimize     一键优化 VPS(BBR/内核/swap/时间同步)
#     bash setup-proxy.sh timezone     设置时区(按出口IP自动 / 分组选择 / 手动输入)
#     bash setup-proxy.sh info         查看节点信息与链接
#     bash setup-proxy.sh sub          重新生成订阅文件
#     bash setup-proxy.sh status       服务状态
#     bash setup-proxy.sh restart      重启服务
#     bash setup-proxy.sh logs         实时日志
#     bash setup-proxy.sh reset        重置凭据(换 UUID / 密钥)
#     bash setup-proxy.sh backup       打包状态/凭据/证书, 用于迁移
#     bash setup-proxy.sh restore <f>  从备份恢复(换 VPS 时用)
#     bash setup-proxy.sh clean        清除所有配置与服务(端口占用时用这个)
#     bash setup-proxy.sh uninstall    卸载(等同 clean)
#     bash setup-proxy.sh upgrade [版本]  升级内核, --rollback 回滚
#  环境变量(首次安装生效):
#     PROTOCOLS=reality,hy2   协议组合(可选 reality hy2 ss2022 anytls tuic)
#     VLESS_PORT=443  HY2_PORT=443  REALITY_DEST=www.bing.com
#     REALITY_DEST=random  重新随机挑一个伪装站(已装好的机器换 SNI 用这个)
#     SS2022_PORT=8445  ANYTLS_PORT=8444  TUIC_PORT=8443
#     ENABLE_OBFS=1   开启 hy2 salamander 混淆
#     HY2_HOP=20000-30000   hy2 UDP 端口跳跃
#     HY2_INSECURE=1  关闭证书固定, 退回 insecure (不推荐, 仅临时调试)
#     HY2_BW_UP=50 HY2_BW_DOWN=300   Hysteria2 Brutal 带宽(Mbps), 留空=默认 BBR
#     DEFAULT_NODE=hy2  客户端默认节点改走 HY2(UDP, 速度优先); 留空=REALITY(稳妥)
#     NODE_NAME=xxx   节点备注名
#     SUB_PORT=38080  订阅 HTTP 端口(留空=随机 30000-39999)
#     SUB_HTTP=1      起一个订阅 HTTP 服务(默认关)
#     SUB_BIND=0.0.0.0  订阅服务监听地址(默认 127.0.0.1, 只允许本机/SSH 隧道)
#     HY2_VERSION=2.13.0  固定 hysteria 版本(内置 SHA-256 与之一一对应)
#     ALLOW_UNVERIFIED_BIN=1  跳过二进制校验(不推荐, 自定义版本时才需要)
#     CLEAN=1         安装前先彻底清理旧实例(解决端口被占用)
#     ASSUME_YES=1    全程不询问
# ============================================================
set -uo pipefail

# 默认 077: 新建文件只有 root 可读。凭据/私钥/临时配置散落在 /tmp 和 /etc,
# 默认 022 会让同机普通用户读到 UUID 与密码。需要公开的目录(订阅、证书)
# 在创建处显式 chmod, 不受这里影响。
umask 077

APP_NAME="proxy"
# 版本号必须和 tag 对得上 —— proxy update 靠它判断"本地是不是旧的"。
# 改代码就顺手改这里, 否则自更新会认为已经是最新。
SCRIPT_VERSION="1.0.0"
BUILD_DATE="2026-11-07"
STATE_DIR="/etc/proxy-node"
STATE_FILE="${STATE_DIR}/state.env"
USERS_FILE="${STATE_DIR}/users.txt"
BACKUP_DIR="${STATE_DIR}/backup"
SUB_DIR="/var/www/proxy-sub"
LOG_FILE="/var/log/proxy-deploy.log"
REPO_URL="https://github.com/smallji666/proxy-node"
SCRIPT_URL="${REPO_URL}/raw/main/setup.sh"
# 文档与提示里统一用这一条。为什么不是简单的 curl -o && bash:
#   直接 -o 到目标路径, 下载中断/被劫持就会把磁盘上那份能用的脚本顶成半截文件,
#   下次敲 proxy 直接报语法错。改成先下到 /tmp、bash -n 验语法、过了才 mv 覆盖,
#   任何一步失败都停在这一步, 原来的脚本毫发无损。
ONELINER="curl -fsSL ${SCRIPT_URL} -o /tmp/pn.sh && bash -n /tmp/pn.sh && mv -f /tmp/pn.sh /root/setup-proxy.sh && bash /root/setup-proxy.sh"

# ---------------- 记录用户显式传入的环境变量 ----------------
# 未传时置为哨兵值, 以便 load_state 之后判断是否需要覆盖
_RAW_VLESS_PORT="${VLESS_PORT-__unset__}"
_RAW_HY2_PORT="${HY2_PORT-__unset__}"
_RAW_XRAY_VERSION="${XRAY_VERSION-__unset__}"
_RAW_REALITY_DEST="${REALITY_DEST-__unset__}"
_RAW_ENABLE_OBFS="${ENABLE_OBFS-__unset__}"
_RAW_HY2_HOP="${HY2_HOP-__unset__}"
_RAW_HY2_INSECURE="${HY2_INSECURE-__unset__}"
_RAW_SUB_HTTP="${SUB_HTTP-__unset__}"
_RAW_SUB_PORT="${SUB_PORT-__unset__}"
_RAW_SUB_BIND="${SUB_BIND-__unset__}"
_RAW_NODE_NAME="${NODE_NAME-__unset__}"
_RAW_PROTOCOLS="${PROTOCOLS-__unset__}"
_RAW_SS2022_PORT="${SS2022_PORT-__unset__}"
_RAW_ANYTLS_PORT="${ANYTLS_PORT-__unset__}"
_RAW_TUIC_PORT="${TUIC_PORT-__unset__}"
_RAW_EGRESS="${EGRESS_URL-__unset__}"
_RAW_HY2_BW_UP="${HY2_BW_UP-__unset__}"
_RAW_HY2_BW_DOWN="${HY2_BW_DOWN-__unset__}"
_RAW_DEFAULT_NODE="${DEFAULT_NODE-__unset__}"

# ---------------- 默认参数 ----------------
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-443}"
XRAY_VERSION="${XRAY_VERSION:-26.3.27}"
HY2_VERSION="${HY2_VERSION:-2.13.0}"
REALITY_DEST="${REALITY_DEST:-}"
ENABLE_OBFS="${ENABLE_OBFS:-0}"
HY2_HOP="${HY2_HOP:-}"
HY2_INSECURE="${HY2_INSECURE:-0}"
# Hysteria2 Brutal 带宽(Mbps)。留空 = 用官方默认 BBR, 不主动抢带宽。
# 只有客户端订阅会用到这两个值, 服务端**不写 bandwidth** —— 官方文档明确说
# 自建自用可以删掉服务端 bandwidth, 由客户端指定即可; 服务端写了反而变成限速。
# 数值是"你这台客户端到 VPS 这条链路"的实际上下行, 不是 VPS 的标称带宽。
# 填高了会因补偿机制导致速度慢且不稳定, 填低了等于限速 —— 不确定就留空。
HY2_BW_UP="${HY2_BW_UP:-}"
HY2_BW_DOWN="${HY2_BW_DOWN:-}"
# 客户端订阅里默认选中的节点。reality = TCP/抗封锁优先(保持历史行为);
# hy2 = UDP/速度优先。只在确实启用了 hy2 时才允许切换, 不改服务端任何配置。
DEFAULT_NODE="${DEFAULT_NODE:-reality}"
SUB_HTTP="${SUB_HTTP:-0}"
SUB_PORT="${SUB_PORT:-}"
SUB_BIND="${SUB_BIND:-127.0.0.1}"
CLEAN="${CLEAN:-0}"
# 备注名会同时进 clash.yaml(双引号字符串)、sing-box/xray 的 JSON 和分享链接。
# 名字里带 " 或 \ 会把整份配置写坏, 直接在这层清掉, 后面就不用到处转义。
# 中英文、空格转 - 都保留, 只去掉结构性字符与控制字符。
sanitize_node_name(){
  local n
  n=$(printf '%s' "${1:-}" | tr -d '"\\' | tr -d '\000-\037\177' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$n" ] || n="Node"
  printf '%s' "${n// /-}"
}
NODE_NAME=$(sanitize_node_name "${NODE_NAME:-Node}")
ASSUME_YES="${ASSUME_YES:-0}"
# 协议组合, 逗号分隔. 默认与旧版行为一致(reality + hy2)
PROTOCOLS="${PROTOCOLS:-reality,hy2}"
SS2022_PORT="${SS2022_PORT:-8445}"
ANYTLS_PORT="${ANYTLS_PORT:-8444}"
TUIC_PORT="${TUIC_PORT:-8443}"
# 上游出口代理(住宅 IP / 中转), 形如 socks5://user:pass@host:port
EGRESS_URL="${EGRESS_URL:-}"

XRAY_BIN=/usr/local/bin/xray
XRAY_CFG=/usr/local/etc/xray/config.json
HY2_BIN=/usr/local/bin/hysteria
HY2_CFG=/etc/hysteria/config.yaml
SB_BIN=/usr/local/bin/sing-box
SB_CFG=/etc/sing-box/config.json
SB_CERT=/etc/sing-box/cert.pem
SB_KEY=/etc/sing-box/key.pem
SB_DIR=/etc/sing-box

# ---------------- 样式 ----------------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'
M='\033[0;35m'; D='\033[0;90m'; N='\033[0m'

log_line(){
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}
info(){ echo -e "${B}[*]${N} $*"; log_line "INFO $*"; }
ok(){   echo -e "${G}[OK]${N} $*"; log_line "OK   $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; log_line "WARN $*"; }
err(){  echo -e "${R}[X]${N} $*"; log_line "ERR  $*"; }
die(){  err "$*"; echo; err "部署中止。完整日志: ${LOG_FILE}"; exit 1; }
hr(){ echo -e "${D}------------------------------------------------------------${N}"; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "请用 root 运行"; }

# 协议开关: proto_on reality / proto_on ss2022 ...
proto_on(){
  case ",${PROTOCOLS}," in
    *",$1,"*) return 0 ;;
    *)        return 1 ;;
  esac
}

# 规范化协议列表: 去空格, 去重, 校验合法性
normalize_protocols(){
  local raw="${1:-}" out="" p
  raw="${raw// /}"; raw="${raw//;/,}"
  local IFS=','
  for p in $raw; do
    [ -n "$p" ] || continue
    case "$p" in
      reality|hy2|ss2022|anytls|tuic) ;;
      *) die "未知协议: ${p} (可选: reality hy2 ss2022 anytls tuic)" ;;
    esac
    case ",${out}," in
      *",$p,"*) ;;
      *) out="${out:+${out},}${p}" ;;
    esac
  done
  unset IFS
  [ -n "$out" ] || die "PROTOCOLS 不能为空"
  PROTOCOLS="$out"
}

# 把协议组合归一化成固定顺序, 用于"协议是否变更"的比较。
# 直接比字符串会把 `hy2,reality` 和 `reality,hy2` 判成不同组合, 于是向导以为
# 用户换了协议 -> 触发 do_clean -> users.txt 被删、UUID 全部重生成, 所有客户端
# 一起失效。只是输入顺序不同而已, 绝对不能走到清理那一步。
canon_protocols(){
  local raw="${1:-}" out="" p
  raw="${raw// /}"; raw="${raw//;/,}"
  for p in reality hy2 ss2022 anytls tuic; do
    case ",${raw}," in *",${p},"*) out="${out:+${out},}${p}" ;; esac
  done
  printf '%s' "$out"
}

# version_ge A B  ->  A >= B (按版本号而非字符串比较)
version_ge(){
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V 2>/dev/null | head -1)" = "$2" ]
}

# 从终端读一行。
# 关键: read -p 的提示符走 stderr, 一旦调用方 2>/dev/null 就会把提示吞掉,
# 用户只看到光标不动 -> 误判为"卡死"。所以提示符必须自己写到 /dev/tty。
# 用法: read_tty "提示语" 变量名 [默认值]
read_tty(){
  local prompt="$1" __var="$2" __def="${3:-}" __ans=""
  # 先屏蔽 stderr 再打开 /dev/tty: 打不开时 bash 的报错才不会污染输出
  if ! { printf '%b' "$prompt" 2>/dev/null >/dev/tty; }; then
    printf -v "$__var" '%s' "$__def"
    return 1
  fi
  IFS= read -r __ans 2>/dev/null </dev/tty || { printf -v "$__var" '%s' "$__def"; return 1; }
  [ -n "$__ans" ] || __ans="$__def"
  printf -v "$__var" '%s' "$__ans"
  return 0
}

ask_yes(){
  [ "$ASSUME_YES" = "1" ] && return 0
  local ans=""
  read_tty "${Y}?${N} $1 [y/N]: " ans "" || return 1
  case "$ans" in y|Y|yes|YES|是|好) return 0 ;; *) return 1 ;; esac
}

# ---------------- 状态持久化 ----------------
load_state(){
  if [ -f "$STATE_FILE" ]; then
    # state.env 被手改坏/被截断时, source 会报错但脚本会继续跑, 后面的裸
    # $DEST / $PUB 在 set -u 下直接退出。先做语法预检, 坏了就按未安装处理。
    if ! bash -n "$STATE_FILE" 2>/dev/null; then
      warn "state.env 语法损坏, 已忽略(请先检查备份): ${STATE_FILE}"
      return 1
    fi
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    # 老版本写进 state.env 的备注名可能带引号/反斜杠, 读回来必须再过一遍,
    # 否则 clash.yaml 里那行 name: "..." 会直接把整份 YAML 写坏
    NODE_NAME=$(sanitize_node_name "${NODE_NAME:-Node}")
    return 0
  fi
  return 1
}

save_state(){
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  {
    echo "# 由 proxy-installer 自动生成, 请勿手工编辑"
    # 只在首次安装时写入; 之后 save_state 被改名/加设备等调用时不能覆盖它
    echo "INSTALLED_AT='${INSTALLED_AT:-$(date '+%Y-%m-%d %H:%M:%S')}'"
    echo "XRAY_VERSION='${XRAY_VERSION}'"
    echo "NODE_NAME='${NODE_NAME}'"
    echo "SERVER_IP='${SERVER_IP:-}'"
    echo "UUID='${UUID:-}'"
    echo "PRIV='${PRIV:-}'"
    echo "PUB='${PUB:-}'"
    echo "SID='${SID:-}'"
    echo "DEST='${DEST:-}'"
    echo "VLESS_PORT='${VLESS_PORT}'"
    echo "HY2_PORT='${HY2_PORT}'"
    echo "HY2_PASS='${HY2_PASS:-}'"
    echo "ENABLE_OBFS='${ENABLE_OBFS}'"
    echo "OBFS_PASS='${OBFS_PASS:-}'"
    echo "HY2_HOP='${HY2_HOP:-}'"
    echo "HY2_PIN='${HY2_PIN:-}'"
    echo "HY2_INSECURE='${HY2_INSECURE}'"
    echo "HY2_BW_UP='${HY2_BW_UP:-}'"
    echo "HY2_BW_DOWN='${HY2_BW_DOWN:-}'"
    echo "DEFAULT_NODE='${DEFAULT_NODE:-reality}'"
    echo "CERT_SPKI_B64='${CERT_SPKI_B64:-}'"
    echo "CERT_DER_B64='${CERT_DER_B64:-}'"
    echo "CERT_HEX='${CERT_HEX:-}'"
    echo "SUB_TOKEN='${SUB_TOKEN:-}'"
    echo "SUB_PORT='${SUB_PORT:-}'"
    echo "SUB_BIND='${SUB_BIND}'"
    echo "SUB_HTTP='${SUB_HTTP}'"
    echo "PROTOCOLS='${PROTOCOLS}'"
    echo "SS2022_PORT='${SS2022_PORT}'"
    echo "ANYTLS_PORT='${ANYTLS_PORT}'"
    echo "TUIC_PORT='${TUIC_PORT}'"
    echo "SS2022_PASS='${SS2022_PASS:-}'"
    echo "ANYTLS_PASS='${ANYTLS_PASS:-}'"
    echo "TUIC_PASS='${TUIC_PASS:-}'"
    echo "TUIC_UUID='${TUIC_UUID:-}'"
    echo "XRAY_BIN_SHA='${XRAY_BIN_SHA:-}'"
    echo "HY2_BIN_SHA='${HY2_BIN_SHA:-}'"
    echo "SB_BIN_SHA='${SB_BIN_SHA:-}'"
    echo "SB_PIN='${SB_PIN:-}'"
    echo "SB_HEX='${SB_HEX:-}'"
    echo "EGRESS_URL='${EGRESS_URL:-}'"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# 只改 state.env 里的一个键。
# 为什么不用 save_state: 它会把内存里所有变量整体写回去, 而 upgrade / 换内核这类
# 操作根本没有 load_state, 直接调 save_state 等于用一堆空值把凭据抹掉。
update_state_kv(){
  local k="${1:-}" v="${2:-}" f="$STATE_FILE"
  [ -n "$k" ] || return 1
  [ -f "$f" ] || return 1
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    # 值里可能有 / 与 &, 用 | 当分隔符并转义
    local esc="${v//\\/\\\\}"; esc="${esc//|/\\|}"; esc="${esc//&/\\&}"
    sed -i "s|^${k}=.*|${k}='${esc}'|" "$f"
  else
    printf "%s='%s'\n" "$k" "$v" >> "$f"
  fi
  chmod 600 "$f" 2>/dev/null || true
}

# load_state 之后, 把用户本次显式传入的环境变量覆盖回来
apply_env_overrides(){
  [ "$_RAW_VLESS_PORT"   != "__unset__" ] && VLESS_PORT="$_RAW_VLESS_PORT"
  [ "$_RAW_HY2_PORT"     != "__unset__" ] && HY2_PORT="$_RAW_HY2_PORT"
  [ "$_RAW_XRAY_VERSION" != "__unset__" ] && XRAY_VERSION="$_RAW_XRAY_VERSION"
  [ "$_RAW_ENABLE_OBFS"  != "__unset__" ] && ENABLE_OBFS="$_RAW_ENABLE_OBFS"
  [ "$_RAW_HY2_HOP"      != "__unset__" ] && HY2_HOP="$_RAW_HY2_HOP"
  [ "$_RAW_HY2_INSECURE" != "__unset__" ] && HY2_INSECURE="$_RAW_HY2_INSECURE"
  [ "$_RAW_SUB_HTTP"     != "__unset__" ] && SUB_HTTP="$_RAW_SUB_HTTP"
  [ "$_RAW_SUB_PORT"     != "__unset__" ] && SUB_PORT="$_RAW_SUB_PORT"
  [ "$_RAW_SUB_BIND"     != "__unset__" ] && SUB_BIND="$_RAW_SUB_BIND"
  [ "$_RAW_PROTOCOLS"    != "__unset__" ] && PROTOCOLS="$_RAW_PROTOCOLS"
  [ "$_RAW_SS2022_PORT"  != "__unset__" ] && SS2022_PORT="$_RAW_SS2022_PORT"
  [ "$_RAW_ANYTLS_PORT"  != "__unset__" ] && ANYTLS_PORT="$_RAW_ANYTLS_PORT"
  [ "$_RAW_TUIC_PORT"    != "__unset__" ] && TUIC_PORT="$_RAW_TUIC_PORT"
  [ "$_RAW_EGRESS"       != "__unset__" ] && EGRESS_URL="$_RAW_EGRESS"
  if [ "$_RAW_HY2_BW_UP" != "__unset__" ]; then
    if [ -z "$_RAW_HY2_BW_UP" ] || hy2_bw_ok "$_RAW_HY2_BW_UP"; then HY2_BW_UP="$_RAW_HY2_BW_UP"
    else warn "HY2_BW_UP='${_RAW_HY2_BW_UP}' 非法, 已忽略"; fi
  fi
  if [ "$_RAW_HY2_BW_DOWN" != "__unset__" ]; then
    if [ -z "$_RAW_HY2_BW_DOWN" ] || hy2_bw_ok "$_RAW_HY2_BW_DOWN"; then HY2_BW_DOWN="$_RAW_HY2_BW_DOWN"
    else warn "HY2_BW_DOWN='${_RAW_HY2_BW_DOWN}' 非法, 已忽略"; fi
  fi
  [ "$_RAW_DEFAULT_NODE" != "__unset__" ] && DEFAULT_NODE="$_RAW_DEFAULT_NODE"
  if [ "$_RAW_NODE_NAME" != "__unset__" ]; then
    NODE_NAME=$(sanitize_node_name "$_RAW_NODE_NAME")
  fi
  # 显式指定伪装站时, 丢弃旧值重新挑选验证
  if [ "$_RAW_REALITY_DEST" != "__unset__" ]; then
    REALITY_DEST="$_RAW_REALITY_DEST"
    DEST=""
  fi
  return 0
}

backup_config(){
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d%H%M%S)
  [ -f "$XRAY_CFG" ] && cp -f "$XRAY_CFG" "$BACKUP_DIR/xray-${ts}.json" 2>/dev/null
  [ -f "$HY2_CFG" ]  && cp -f "$HY2_CFG"  "$BACKUP_DIR/hy2-${ts}.yaml" 2>/dev/null
  # sing-box 也留一份: 重装/换协议时它会被整份重写, 写坏了得有东西能对照
  [ -f "$SB_CFG" ]   && cp -f "$SB_CFG"   "$BACKUP_DIR/singbox-${ts}.json" 2>/dev/null
  ls -1t "$BACKUP_DIR"/xray-*.json 2>/dev/null | tail -n +6 | xargs -r rm -f
  ls -1t "$BACKUP_DIR"/hy2-*.yaml  2>/dev/null | tail -n +6 | xargs -r rm -f
  ls -1t "$BACKUP_DIR"/singbox-*.json 2>/dev/null | tail -n +6 | xargs -r rm -f
}

# ---------------- 系统探测 ----------------
PKG=""
detect_pkg(){
  if command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf
  elif command -v yum >/dev/null 2>&1; then PKG=yum
  else die "未识别的包管理器(需要 apt/dnf/yum)"; fi
}

install_deps(){
  info "安装依赖 (curl unzip openssl iptables)..."
  if [ "$PKG" = apt ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq curl unzip openssl ca-certificates iptables >/dev/null 2>&1
  else
    $PKG install -y -q curl unzip openssl ca-certificates iptables >/dev/null 2>&1
  fi
  command -v curl >/dev/null    || die "curl 安装失败"
  command -v unzip >/dev/null   || die "unzip 安装失败"
  command -v openssl >/dev/null || die "openssl 安装失败"
  if ! command -v qrencode >/dev/null 2>&1; then
    if [ "$PKG" = apt ]; then apt-get install -y -qq qrencode >/dev/null 2>&1 || true
    else $PKG install -y -q qrencode >/dev/null 2>&1 || true; fi
  fi
  ok "依赖就绪"
}

get_server_ip(){
  local ip=""
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
       | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [ -z "$ip" ] || echo "$ip" | grep -qE '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; then
    ip=$(curl -s4 --max-time 10 https://api.ipify.org 2>/dev/null \
      || curl -s4 --max-time 10 https://ifconfig.me 2>/dev/null || echo "")
  fi
  echo "$ip" | tr -d '[:space:]'
}

# 端口参数必须是 1-65535 的整数。写错的话 xray / sing-box 只会回一句
# "failed to load config", 用户根本看不出是哪个变量错了, 所以提前拦。
valid_port(){
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_ports(){
  local p v tl="" ul="" dup
  for p in VLESS_PORT HY2_PORT SS2022_PORT ANYTLS_PORT TUIC_PORT SUB_PORT; do
    v="${!p:-}"
    [ -n "$v" ] || continue
    valid_port "$v" || die "${p}=\"${v}\" 不合法, 端口必须是 1-65535 的整数"
    # 去掉前导零: 0443 会让 JSON 里出现 "port": 0443, 而 JSON 不允许前导零,
    # xray/sing-box 会直接报配置解析失败
    printf -v "$p" '%d' "$((10#$v))"
  done

  # 同协议族里端口撞车, 第二个服务必然 bind 失败, 提前拦住
  proto_on reality && tl="${tl} ${VLESS_PORT}:Reality"
  proto_on ss2022  && tl="${tl} ${SS2022_PORT}:SS2022" && ul="${ul} ${SS2022_PORT}:SS2022"
  proto_on anytls  && tl="${tl} ${ANYTLS_PORT}:AnyTLS"
  proto_on tuic    && tl="${tl} ${TUIC_PORT}:TUIC" && ul="${ul} ${TUIC_PORT}:TUIC"
  proto_on hy2     && ul="${ul} ${HY2_PORT}:HY2"
  if [ "$SUB_HTTP" = "1" ] && [ -n "${SUB_PORT:-}" ]; then tl="${tl} ${SUB_PORT}:订阅"; fi

  dup=$(printf '%s\n' $tl | awk -F: 'NF{print $1}' | sort | uniq -d | head -1)
  [ -z "$dup" ] || die "TCP 端口 ${dup} 被多个服务占用: $(printf '%s\n' $tl | awk -F: -v p="$dup" '$1==p{printf "%s ", $2}')"
  dup=$(printf '%s\n' $ul | awk -F: 'NF{print $1}' | sort | uniq -d | head -1)
  [ -z "$dup" ] || die "UDP 端口 ${dup} 被多个服务占用: $(printf '%s\n' $ul | awk -F: -v p="$dup" '$1==p{printf "%s ", $2}')"
  return 0
}

port_in_use(){
  local proto="${2:-tcp}" flag="-tln"
  [ "$proto" = "udp" ] && flag="-uln"
  ss "$flag" 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"
}

# 占用端口的进程, 输出 "名字(pid)"; 查不到返回空
port_owner(){
  local proto="${2:-tcp}" flag="-tlnp" out
  [ "$proto" = "udp" ] && flag="-ulnp"
  out=$(ss "$flag" 2>/dev/null | awk -v p=":${1}" '$4 ~ (p "$") {print $NF; exit}')
  [ -n "$out" ] || return 1
  echo "$out" | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1(\2)/p'
}

kill_port_owner(){
  local proto="${2:-tcp}" flag="-tlnp" pid
  [ "$proto" = "udp" ] && flag="-ulnp"
  pid=$(ss "$flag" 2>/dev/null | awk -v p=":${1}" '$4 ~ (p "$") {print $NF; exit}' \
        | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
  [ -n "$pid" ] || return 1
  kill "$pid" 2>/dev/null || true
  sleep 1
  kill -9 "$pid" 2>/dev/null || true
  return 0
}

# ---------------- 下载 ----------------
# 官方发布产物的 SHA-256, 按 "工具-架构" 索引。
# 为什么要硬编码: 下载失败时会退回 ghfast.top / gh-proxy.com 这类第三方镜像,
# 光比对"镜像自己给的哈希"没有任何意义(两个都能被换)。只有把期望值写死在脚本里,
# 镜像投毒/中间人换包才会在安装前就失败。
# 取值来源: Xray 的 *.dgst、hysteria 的 hashes.txt(均已逐字节核对),
# sing-box 官方不发校验文件, 由本脚本对 release tarball 实测后固定。
pinned_sha(){
  case "$1" in
    xray-64-26.3.27)       echo "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae" ;;
    xray-arm64-26.3.27)    echo "4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c" ;;
    hy2-amd64-2.13.0)      echo "907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691" ;;
    hy2-arm64-2.13.0)      echo "a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7" ;;
    singbox-amd64-1.14.4)  echo "699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968" ;;
    singbox-arm64-1.14.4)  echo "436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26" ;;
    *)                     echo "" ;;
  esac
}

# 取文件的 sha256。
# 必须清掉可能的前导反斜杠: GNU coreutils 在文件名含 \ 或换行时会给整行加 \ 转义前缀,
# 直接 awk 取第一列会得到 "\abc123..." 这种带前缀的串, 和基准值永远比不相等。
file_sha256(){
  sha256sum "$1" 2>/dev/null | awk '{print $1}' | tr -d '\\'
}

# 校验失败一律中止: 装上一个被换过的二进制, 比装不上严重得多
verify_sha256(){
  local file="$1" want="$2" label="$3" got
  if [ -z "$want" ]; then
    if [ "${ALLOW_UNVERIFIED_BIN:-0}" = "1" ]; then
      warn "${label}: 该版本没有内置校验值, 已按 ALLOW_UNVERIFIED_BIN=1 跳过校验"
      return 0
    fi
    err "${label}: 当前版本没有内置校验值, 无法确认完整性"
    err "  下载到的文件 sha256: $(file_sha256 "$file")"
    err "  先去官方 release 页核对这个值, 一致后再跳过校验:"
    err "    ALLOW_UNVERIFIED_BIN=1 bash setup-proxy.sh install"
    err "    ALLOW_UNVERIFIED_BIN=1 proxy upgrade <版本>"
    return 1
  fi
  got=$(file_sha256 "$file")
  if [ "$got" = "$want" ]; then
    ok "${label} 完整性校验通过 (sha256 ${got:0:16}…)"
    return 0
  fi
  err "${label} 完整性校验失败, 已拒绝安装"
  err "  期望: ${want}"
  err "  实际: ${got:-读取失败}"
  err "  说明: 下载到的文件与官方发布不一致(镜像投毒 / 中间人 / 断点续传损坏)"
  err "  处理: 重跑一次; 仍然失败请换网络, 或核对官方 release 页的哈希"
  return 1
}

download_with_mirror(){
  local url="$1" out="$2" p
  for p in "" "https://ghfast.top/" "https://gh-proxy.com/"; do
    if curl -fsSL --connect-timeout 15 --max-time 600 -o "$out" "${p}${url}"; then
      [ -s "$out" ] && return 0
    fi
    warn "下载失败, 换源重试: ${p:-官方}"
  done
  return 1
}

ensure_xray(){
  local arch asset sha_arch
  if version_ge "$XRAY_VERSION" "26.9.8"; then
    warn "Xray ${XRAY_VERSION} >= 26.9.8: REALITY 强制要求 X25519MLKEM768"
    warn "  小火箭/Stash 发不出该字段, 会「开关变绿但打不开网页」"
  fi
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)  asset="Xray-linux-64.zip";         sha_arch="64" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip";  sha_arch="arm64" ;;
    *) die "不支持的架构: $arch" ;;
  esac

  # 注意: xray version 输出形如 "Xray 26.3.27 (...)", 版本号不带 v 前缀
  #
  # 这里不能写 `xray version | head -1 | grep -qF`: 脚本开了 pipefail,
  # head/grep 提前退出会让 xray 吃到 SIGPIPE, 整条管道判失败, 结果是"明明装着
  # 也要重新下载一遍"。先整段读进变量, 再做字符串匹配。
  # 匹配时两边补空格, 避免 26.3.2 误配到 26.3.27。
  local vout=""
  if [ -x "$XRAY_BIN" ]; then
    vout=$("$XRAY_BIN" version 2>/dev/null | head -1)
  fi
  case " ${vout} " in
    *" ${XRAY_VERSION} "*)
      ok "Xray v${XRAY_VERSION} 已安装, 跳过"
      return 0 ;;
  esac

  info "下载 Xray v${XRAY_VERSION} ..."
  local tmp; tmp=$(mktemp -d)
  download_with_mirror \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${asset}" \
    "$tmp/x.zip" || die "Xray 下载失败(检查服务器能否访问 GitHub)"
  verify_sha256 "$tmp/x.zip" "$(pinned_sha "xray-${sha_arch}-${XRAY_VERSION}")" "Xray v${XRAY_VERSION}" \
    || die "Xray 校验未通过, 已中止"
  unzip -o -q "$tmp/x.zip" -d "$tmp/pkg" || die "Xray 解压失败"
  [ -f "$tmp/pkg/xray" ] || die "压缩包内未找到 xray"
  systemctl stop xray >/dev/null 2>&1 || true
  install -m 755 "$tmp/pkg/xray" "$XRAY_BIN"
  mkdir -p /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  cp -f "$tmp/pkg/geoip.dat"   /usr/local/share/xray/ 2>/dev/null || true
  cp -f "$tmp/pkg/geosite.dat" /usr/local/share/xray/ 2>/dev/null || true
  rm -rf "$tmp"
  XRAY_BIN_SHA=$(file_sha256 "$XRAY_BIN")
  ok "Xray 已安装: $($XRAY_BIN version 2>/dev/null | head -1)"
}

# 用 openssl 生成 X25519 密钥对, 结果写入全局 PRIV / PUB (base64url, 无 padding)
# REALITY 要的就是标准的 X25519 原始 32 字节, 和 xray x25519 的输出等价
gen_x25519_openssl(){
  local tmp k priv pub
  PRIV=""; PUB=""
  command -v openssl >/dev/null 2>&1 || return 1
  tmp=$(mktemp -d 2>/dev/null) || return 1
  k="${tmp}/k.pem"
  if ! openssl genpkey -algorithm X25519 -out "$k" >/dev/null 2>&1; then
    rm -rf "$tmp"; return 1
  fi
  # PKCS#8 DER 末 32 字节 = 私钥标量; SPKI DER 末 32 字节 = 公钥
  priv=$(openssl pkey -in "$k" -outform DER 2>/dev/null | tail -c 32 \
         | base64 2>/dev/null | tr -d '\n\r' | tr '+/' '-_' | tr -d '=')
  pub=$(openssl pkey -in "$k" -pubout -outform DER 2>/dev/null | tail -c 32 \
        | base64 2>/dev/null | tr -d '\n\r' | tr '+/' '-_' | tr -d '=')
  rm -rf "$tmp"
  # base64url(32 字节) 固定 43 字符, 长度不对说明 openssl 输出异常
  [ "${#priv}" = "43" ] && [ "${#pub}" = "43" ] || return 1
  PRIV="$priv"; PUB="$pub"
  return 0
}

# 读自签证书的 CN。openssl 1.1 输出 "CN = x", 3.0 输出 "CN=x", 两种都吃掉。
# 读不到(文件缺失/损坏)返回空串。
cert_cn(){
  [ -f "${1:-}" ] || return 0
  openssl x509 -in "$1" -noout -subject 2>/dev/null \
    | sed -n 's/.*CN *= *//p' | head -1
}

# 生成自签证书。
# 必须带 SAN: RFC 6125 之后客户端只认 subjectAltName, 只有 CN 的证书在浏览器里
# 直接拒 —— 一张"只有 CN、没有 SAN"的自签证书本身就是"手工 openssl 敲出来的"
# 的标记, 主动探测方拿到证书就能据此归类。openssl 1.1.1 以下没有 -addext,
# 那时退回只写 CN(功能不受影响, 客户端本来就靠指纹验身份)。
make_self_signed_cert(){
  local crt="$1" key="$2" cn="$3"
  openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null || return 1
  openssl req -new -x509 -days 3650 -key "$key" -out "$crt" \
    -subj "/CN=${cn}" -addext "subjectAltName=DNS:${cn}" 2>/dev/null && return 0
  openssl req -new -x509 -days 3650 -key "$key" -out "$crt" -subj "/CN=${cn}" 2>/dev/null
}

# 生成标准 v4 UUID; 容器里 /proc 不完整时手工拼一个
gen_uuid(){
  local u
  u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  if [ -z "$u" ]; then
    u=$(openssl rand -hex 16)
    u="${u:0:12}4${u:13:3}a${u:17:15}"
    u="${u:0:8}-${u:8:4}-${u:12:4}-${u:16:4}-${u:20:12}"
  fi
  printf '%s' "$u"
}

ensure_creds(){
  if [ -n "${UUID:-}" ] && [ -n "${PRIV:-}" ] && [ -n "${PUB:-}" ] && [ -n "${SID:-}" ]; then
    ok "复用已有凭据 (UUID: ${UUID:0:8}...)"
    return 0
  fi
  info "生成 UUID / x25519 密钥 / shortId ..."
  UUID=$(gen_uuid)
  SID=$(openssl rand -hex 8 2>/dev/null)
  [ -n "$SID" ] || SID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

  # 优先走 openssl: 全新安装时 xray 二进制还没下载, 不能依赖它
  if gen_x25519_openssl; then
    ok "新凭据已生成"
    return 0
  fi

  # 回退: 用 xray 自带的 x25519 子命令
  local keys rc
  keys=$("$XRAY_BIN" x25519 2>&1); rc=$?
  PRIV=$(printf '%s\n' "$keys" | grep -iE '^[[:space:]]*private' | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
  PUB=$(printf '%s\n' "$keys"  | grep -iE '^[[:space:]]*(public|password)' | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
  if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
    PRIV=$(printf '%s\n' "$keys" | grep -oE '[A-Za-z0-9_-]{43}' | sed -n 1p)
    PUB=$(printf '%s\n' "$keys"  | grep -oE '[A-Za-z0-9_-]{43}' | sed -n 2p)
  fi
  if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
    echo -e "${D}--- xray x25519 原始输出 (退出码 ${rc}) ---${N}" >&2
    printf '%s\n' "$keys" | head -10 >&2
    die "x25519 密钥生成失败。openssl 与 xray 都没拿到可用密钥, 请检查: ${XRAY_BIN} x25519"
  fi
  ok "新凭据已生成"
}

# ---------------- 多设备凭据 ----------------
# 每台设备一个 UUID: 丢手机时只吊销那一条, 其他设备不受影响
ensure_users_file(){
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  if [ ! -s "$USERS_FILE" ]; then
    printf '%s|%s|%s\n' "${UUID}" "default" "$(date '+%Y-%m-%d')" > "$USERS_FILE"
    chmod 600 "$USERS_FILE"
  fi
}

build_clients_json(){
  local out="" u n sep=""
  while IFS='|' read -r u n _; do
    [ -n "$u" ] || continue
    n=$(json_esc "$n")
    out="${out}${sep}{ \"id\": \"${u}\", \"flow\": \"xtls-rprx-vision\", \"email\": \"${n}\" }"
    sep=", "
  done < "$USERS_FILE"
  [ -n "$out" ] || out="{ \"id\": \"${UUID}\", \"flow\": \"xtls-rprx-vision\" }"
  CLIENTS_JSON="[ ${out} ]"
}

primary_uuid(){
  local u
  u=$(head -1 "$USERS_FILE" 2>/dev/null | cut -d'|' -f1)
  echo "${u:-$UUID}"
}

# ---------------- Xray 配置 ----------------
# WITH_DNS=1 时写入内置 DNS(解析更快更稳); 若当前 Xray 版本不接受会自动回退
WITH_DNS="${WITH_DNS:-1}"
# 解析上游出口代理 URL: scheme://[user:pass@]host:port
# 输出 "scheme|host|port|user|pass"; scheme 归一成 socks 或 http。解析失败返回 1。
#
# 用途: VPS 的 IP 段是机房, TikTok / 银行这类平台会按"机房 IP"降权。想绕开,
# 唯一的技术手段是把最终出口换成一个住宅 IP —— 也就是在服务端再接一层上游代理。
# 这一层只在服务端做, 客户端配置和分享链接都不用改。
parse_egress(){
  local u scheme rest hostport host port user="" pass=""
  # 显式传参就用参数, 不传才回落到全局 EGRESS_URL —— 传空串必须判失败,
  # 否则 "关闭出口" 时会拿旧值继续用
  if [ $# -gt 0 ]; then u="$1"; else u="${EGRESS_URL:-}"; fi
  [ -n "$u" ] || return 1
  # 这个值最终是拼进 JSON 和 state.env 的, 引号/反斜杠会直接写坏配置文件,
  # 无论从环境变量还是命令行进来, 都在这里统一拦掉。
  # 控制字符(换行/制表)同样致命: JSON 字符串里出现裸换行就是非法 JSON,
  # 而写进 state.env 会多出一行, 下次 load_state 直接 source 到垃圾。
  case "$u" in *'"'*|*"'"*|*\\*) return 1 ;; esac
  case "$u" in *[[:cntrl:]]*) return 1 ;; esac
  case "$u" in
    *://*) scheme="${u%%://*}"; rest="${u#*://}" ;;
    *)     return 1 ;;
  esac
  case "$scheme" in
    socks5|socks5h|socks) scheme="socks" ;;
    http|https)           scheme="http" ;;
    *) return 1 ;;
  esac
  # 凭据里可能出现 '@', 用最后一个 '@' 切分才稳
  case "$rest" in
    *@*) user="${rest%@*}"; hostport="${rest##*@}" ;;
    *)   user=""; hostport="$rest" ;;
  esac
  case "$hostport" in
    \[*\]:*) host="${hostport%]:*}"; host="${host#\[}"; port="${hostport##*]:}" ;;
    *:*)     host="${hostport%:*}"; port="${hostport##*:}" ;;
    *)       return 1 ;;
  esac
  if [ -n "$user" ]; then
    case "$user" in
      *:*) pass="${user#*:}"; user="${user%%:*}" ;;
    esac
  fi
  [ -n "$host" ] && [ -n "$port" ] || return 1
  case "$port" in *[!0-9]*) return 1 ;; esac
  printf '%s|%s|%s|%s|%s' "$scheme" "$host" "$port" "$user" "$pass"
}

# 通过上游代理查一次出口 IP, 用来验证填的地址能不能用
egress_probe_ip(){
  local line scheme host port user pass args=()
  line=$(parse_egress) || return 1
  IFS='|' read -r scheme host port user pass <<< "$line"
  [ -n "$user" ] && args=(-U "${user}:${pass}")
  if [ "$scheme" = "socks" ]; then
    curl -s "${args[@]}" --socks5-hostname "${host}:${port}" --max-time 15 https://api.ipify.org 2>/dev/null
  else
    curl -s "${args[@]}" -x "http://${host}:${port}" --max-time 15 https://api.ipify.org 2>/dev/null
  fi
}

write_xray_config(){
  local dest="$1" dns_json=""
  ensure_users_file
  build_clients_json
  if [ "$WITH_DNS" = "1" ]; then
    dns_json='  "dns": { "servers": [ "1.1.1.1", "8.8.8.8", "localhost" ], "queryStrategy": "UseIPv4" },'
  fi
  # 配了上游出口(住宅 IP)时, 把 egress 放 outbounds 首位 —— xray 的默认出站就是
  # 第一个, 这样除下面两条黑名单规则外的流量全部走它。客户端不用改任何配置。
  local ob_json eg_line eg_scheme eg_host eg_port eg_user eg_pass eg_users=""
  if eg_line=$(parse_egress); then
    IFS='|' read -r eg_scheme eg_host eg_port eg_user eg_pass <<< "$eg_line"
    [ -n "$eg_user" ] && eg_users=", \"users\": [ { \"user\": \"${eg_user}\", \"pass\": \"${eg_pass}\" } ]"
    ob_json="    { \"protocol\": \"${eg_scheme}\", \"tag\": \"egress\", \"settings\": { \"servers\": [ { \"address\": \"${eg_host}\", \"port\": ${eg_port}${eg_users} } ] } },
    { \"protocol\": \"freedom\", \"tag\": \"direct\", \"settings\": { \"domainStrategy\": \"UseIPv4\" } },
    { \"protocol\": \"blackhole\", \"tag\": \"block\" }"
  else
    ob_json="    { \"protocol\": \"freedom\", \"tag\": \"direct\", \"settings\": { \"domainStrategy\": \"UseIPv4\" } },
    { \"protocol\": \"blackhole\", \"tag\": \"block\" }"
  fi
  cat > "$XRAY_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
${dns_json}
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": ${CLIENTS_JSON},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}:443",
          "xver": 0,
          "serverNames": [ "${dest}" ],
          "privateKey": "${PRIV}",
          "shortIds": [ "${SID}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
${ob_json}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": [ "::/0" ], "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }
    ]
  }
}
EOF
  # 配置里是全部设备的 UUID —— 就是凭据本身。默认 umask 022 会留下 644,
  # 同机任何用户都能读走所有设备凭据, 所以必须收紧到 600。
  chmod 600 "$XRAY_CFG"

  # 带 DNS 块的配置若不被当前版本接受, 自动去掉 DNS 块重写一次
  if [ -n "$dns_json" ] && ! $XRAY_BIN run -test -c "$XRAY_CFG" >/dev/null 2>&1; then
    warn "内置 DNS 配置不被当前 Xray 版本接受, 回退为系统解析"
    WITH_DNS=0
    write_xray_config "$dest"
    return 0
  fi
  # 写完必须过一遍官方校验: 端口写错、名字里带引号这类问题会在这里暴露,
  # 而不是等到 systemctl restart 之后对着 "未启动" 猜原因
  local tlog; tlog=$(mktemp)
  if ! $XRAY_BIN run -test -c "$XRAY_CFG" >"$tlog" 2>&1; then
    err "Xray 配置校验失败:"
    sed -n '1,5p' "$tlog" | sed 's/^/    /' >&2
    rm -f "$tlog"
    die "请检查端口参数 (VLESS_PORT=${VLESS_PORT}) 与设备名是否含特殊字符"
  fi
  rm -f "$tlog"
}

# 起一个临时 xray 客户端, 走本地 REALITY 隧道探测一个 URL, 返回 HTTP 码。
# $1=URL  $2=serverName(默认 $DEST)  $3=socks 端口(默认 10899)
# 探测用的客户端是临时的: 起、测、杀, 不留常驻进程, 也不占用端口给别人复用。
reality_probe(){
  local url="$1" dest="${2:-${DEST}}" port="${3:-10899}" code pid tdir
  [ -x "$XRAY_BIN" ] || { printf '000'; return 0; }
  # 临时目录而不是 /tmp/_tc.json: 固定路径 + 可预测名字等于给同机普通用户
  # 留了读取 UUID 和软链接攻击的口子
  tdir=$(mktemp -d 2>/dev/null) || { printf '000'; return 0; }
  cat > "$tdir/c.json" <<EOF
{
  "log": { "loglevel": "error" },
  "inbounds": [ { "port": ${port}, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ {
    "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": ${VLESS_PORT},
      "users": [ { "id": "$(primary_uuid)", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "${dest}", "fingerprint": "chrome",
        "publicKey": "${PUB}", "shortId": "${SID}", "spiderX": "/" } }
  } ]
}
EOF
  "$XRAY_BIN" -c "$tdir/c.json" >"$tdir/c.log" 2>&1 &
  pid=$!
  sleep 3
  code=$(curl -s --socks5-hostname "127.0.0.1:${port}" -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null)
  kill "$pid" >/dev/null 2>&1; wait "$pid" 2>/dev/null
  rm -rf "$tdir"
  printf '%s' "${code:-000}"
}

# 验证隧道是否真的通了。不能拿 dest 自己当探测目标: REALITY 在认证失败时会
# 把连接原样转给 dest, 探 dest 照样能拿到 200, 分不清"隧道通了"和"被降级转发了"。
# 也不能只探一个站: VPS 到自己连不上 google 时, 所有候选都会被误判成握手失败。
verify_reality(){
  local dest="$1" code u
  for u in "https://www.google.com/generate_204" "http://cp.cloudflare.com/generate_204"; do
    code=$(reality_probe "$u" "$dest")
    case "$code" in 200|204|301|302) return 0 ;; esac
  done
  return 1
}

# 黑名单: 实测不能用作 REALITY 伪装目标
# Google 系不能当 dest: 这些域名在国内本身就是被墙的, 正常中国用户不会主动连,
# GFW 看到 SNI=dl.google.com 反而更容易把连接挑出来。apple/cloudflare 是 CDN 共用证书链。
BLOCKED_DESTS="www.cloudflare.com cloudflare.com 1.1.1.1 www.apple.com apple.com www.icloud.com icloud.com www.microsoft.com microsoft.com dl.google.com www.google.com google.com www.youtube.com youtube.com"
is_blocked(){
  local d="$1" b
  for b in $BLOCKED_DESTS; do [ "$d" = "$b" ] && return 0; done
  return 1
}

# Google 各地本地域名。proxy audit 靠它判断"有没有被换区"。
# 只列 ccTLD, 不含裸 google.com —— 裸 .com 要单独按"Google 决定不换区"处理,
# 混在一起会被页面里满地的 google.com 链接带偏。
GOOGLE_TLD_RE='(https?://)?(www\.)?google\.(com\.hk|com\.tw|com\.sg|com\.my|com\.ph|com\.vn|com\.br|com\.mx|com\.ar|com\.au|com\.tr|com\.sa|co\.jp|co\.kr|co\.uk|co\.in|co\.nz|co\.za|co\.th|co\.id|co\.il|cn|de|fr|nl|it|es|ru|pl|se|no|dk|fi|ch|at|be|cz|ie|ae|ca|cl)[/"]'

# 检测目标站是否套在 Cloudflare 后面(看证书签发者)
# 用于拦住"用户把自己套了 CF 的域名填进来"这种情况
dest_behind_cloudflare(){
  local d="$1" issuer
  issuer=$(timeout 8 openssl s_client -connect "${d}:443" -servername "$d" </dev/null 2>/dev/null \
           | openssl x509 -noout -issuer 2>/dev/null)
  [ -n "$issuer" ] || return 1
  echo "$issuer" | grep -qi "cloudflare"
}

# 探测目标站的 TLS 版本与 ALPN, 输出 "TLSv1.3|h2" / "TLSv1.2|h2" / "none|none"。
# 一次握手取两个信息, 比开两次连接快。
#
# 两个坑都踩过:
# 1) 输出里有二进制(session ticket), 必须落文件再 grep, 直接塞进 $() 会丢 null byte。
# 2) TLS 版本行的缩进随 openssl 版本变: 3.2+ 会在摘要区多打一行顶格的
#    "Protocol: TLSv1.3"; 而 Debian 12 / Ubuntu 22.04 的 openssl 3.0 和 1.1.1
#    只有 SSL-Session 段里缩进的 "    Protocol  : TLSv1.3" (冒号前还有两个空格)。
#    所以既不能锚定行首, 也不能按 "Protocol:" 去 sed, 否则老系统上永远读到空值,
#    表现就是所有候选站都被判成 "不可达或不支持 H2(none|h2)" 而全部跳过。
dest_tls_info(){
  local d="$1" f v a
  f=$(mktemp 2>/dev/null) || { printf 'none|none'; return 0; }
  timeout 8 openssl s_client -connect "${d}:443" -servername "$d" -alpn h2 </dev/null >"$f" 2>/dev/null
  v=$(grep -a -m1 -E '^[[:space:]]*Protocol[[:space:]]*:' "$f" 2>/dev/null \
      | sed 's/^[[:space:]]*Protocol[[:space:]]*:[[:space:]]*//' | tr -d '\r')
  a=$(grep -a -m1 'ALPN protocol:' "$f" 2>/dev/null \
      | sed 's/.*ALPN protocol:[[:space:]]*//' | tr -d '\r')
  rm -f "$f"
  printf '%s|%s' "${v:-none}" "${a:-none}"
}

# TLS 握手耗时(毫秒), 用来在同一档候选里排序。
# 只算 DNS 之后到 TLS 完成的这段: 排除 DNS 缓存造成的抖动, 剩下的才是
# "未认证探测被回落到目标站时, 探测方真正等的那段时间"。
# 测不到返回空串, 调用方按"排在本档最后"处理, 不淘汰 —— 探测失败不等于站不能用。
dest_rtt(){
  local d="$1" out tn ta
  out=$(curl -sI -o /dev/null --max-time 8 \
        -w '%{time_namelookup} %{time_appconnect}' "https://$d/" 2>/dev/null)
  # 必须是两个数, 少一个说明 curl 没给全(老版本不支持这些变量)
  case "$out" in *" "*) ;; *) return 0 ;; esac
  tn="${out%% *}"
  ta="${out##* }"
  case "$tn" in ''|*[!0-9.]*) return 0 ;; esac
  case "$ta" in ''|*[!0-9.]*) return 0 ;; esac
  # +0.5 是四舍五入: curl 给的是秒, 相减后浮点会留尾巴(0.06-0.01=49.9999…),
  # 直接 %d 截断会变成 49ms, 排序时同档位站点容易互相错位
  awk -v a="$ta" -v n="$tn" 'BEGIN{ v=(a-n)*1000; if (v<0) v=0; printf "%d", v+0.5 }'
}

# 给候选站打分排序。输出每行 "档位|耗时ms|域名", 已按 档位 -> 耗时 升序排好。
#
# 排序依据, 依次比较:
#   1) TLS 1.3 + ALPN h2   REALITY 的硬要求, 不满足的排到后面
#   2) TLS 握手耗时(ms)    越低越好 —— 未认证探测被回落到目标站时, 探测方等的
#                          就是这段; 300ms 和 20ms 的站, 观感完全是两回事
#
# 关键原则: 探测失败 ≠ 站点不可用。这里只是决定"先试谁", 真正的判据是后面的
# REALITY 握手。之前把探测失败当淘汰条件, 结果 openssl 3.0 上读不到版本号,
# 11 个候选站全被跳过, 安装直接死在"所有目标站握手失败"。
dest_rank(){
  local d info_t tier rtt
  local -a rows=() tiers=() names=()
  local seen="|" have_good=0 i
  for d in "$@"; do
    # 去重: REALITY_DEST 若填的正好是候选池里的域名, 同一个站会被探两次 ——
    # 白花两次往返, 还会在本档里产生一条重复记录
    case "$seen" in *"|${d}|"*) continue ;; esac
    seen="${seen}${d}|"
    is_blocked "$d" && { warn "$d 在排除名单(被墙域名/CDN 共用证书链), 跳过"; continue; }
    dest_behind_cloudflare "$d" && { warn "$d 证书由 Cloudflare 签发(站点套了 CF), TLS 行为不稳定, 跳过"; continue; }
    info_t=$(dest_tls_info "$d")
    case "$info_t" in
      "TLSv1.3|h2") tier=1 ;;
      *\|h2)        tier=2; warn "$d 只有 ${info_t}, 抗主动探测略弱, 列为备选" ;;
      *)            tier=3; warn "$d TLS 探测无结果(${info_t}), 交给真实握手判定" ;;
    esac
    [ "$tier" -le 2 ] && have_good=1
    tiers+=("$tier"); names+=("$d")
  done
  [ "${#names[@]}" -gt 0 ] || return 0

  for i in "${!names[@]}"; do
    d="${names[$i]}"; tier="${tiers[$i]}"; rtt=""
    # 只给档位 1/2 测耗时: 档位 3 本来就是"探测没结果"的站, 再花一次 8s 超时去量
    # 一个注定排最后的值不值得 —— 出站被封时这就是 11×8s 的纯等待。
    #
    # 但"一个能探的都没有"时必须照测: 那种情况(比如系统没装 openssl)所有行都会是
    # 9999, 排序退化成按域名首字母, 全网又挑到同一批站 —— 正是分档要避免的事。
    if [ "$tier" -le 2 ] || [ "$have_good" = "0" ]; then
      rtt=$(dest_rtt "$d")
    fi
    rows+=("${tier}|${rtt:-9999}|${d}")
  done
  printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1n -k2,2n -k3,3
}

# 打散候选顺序。
# pick_dest 原来是按固定顺序试, 第一个握手通过的就用 —— 而候选列表是写死的,
# 于是每台用本脚本装的机器都会选中同一个站(大概率是 www.bing.com)。
# 几百台 VPS 的 REALITY SNI 全是 www.bing.com, 而它们的 ASN 都不属于微软:
# 只要统计"哪些 IP 在跟 bing 握手但 ASN 对不上", 就能把这批机器整段捞出来。
# 随机起点即可打散这个特征, 成本为零。
shuffle_words(){
  [ $# -gt 1 ] || { printf '%s\n' ${1+"$@"}; return 0; }
  if command -v shuf >/dev/null 2>&1; then
    printf '%s\n' "$@" | shuf
  else
    # 没有 shuf(极简系统)时用 awk 排序打散, 效果一样
    printf '%s\n' "$@" | awk 'BEGIN{srand()} {print rand()"\t"$0}' | sort -n | cut -f2-
  fi
}

pick_dest(){
  local cands=() d h
  # REALITY_DEST=random 表示"重新随机挑一个": 不把它当候选塞进去, 只走默认池。
  # 没有这个取值的话, 已装好的机器想换 SNI 只能点名指定某个站, 没法随机。
  [ -n "$REALITY_DEST" ] && [ "$REALITY_DEST" != "random" ] && cands+=("$REALITY_DEST")
  # 只用国内能直连的站: dest 若被墙, 用户发 SNI 时就先被 GFW 拦了, 根本到不了握手
  cands+=(www.bing.com www.samsung.com www.nvidia.com www.amd.com \
          www.ibm.com www.tesla.com www.adobe.com www.oracle.com \
          www.dell.com www.hp.com www.intel.com)

  info "挑选伪装目标站(按 TLS 版本分档、档内测握手耗时, 需通过真实 REALITY 握手)..."

  # openssl 缺失/被裁掉时, TLS 版本探测必然拿不到值。这时不能把所有候选都判死,
  # 只能跳过排序, 全部交给第二遍的真实握手去筛。
  if ! command -v openssl >/dev/null 2>&1; then
    warn "系统没有 openssl, 跳过 TLS 预筛, 全部候选走真实握手验证"
  fi

  # 第一遍: 打分排序(见 dest_rank)。只决定"先试谁", 不做淘汰。
  #
  # 第二遍才真正起服务验证。
  #
  # 顺序 = 档位优先, 档内按握手耗时从快到慢; 但每档只取**最快的 3 个**来随机。
  #
  # 为什么不直接取最快的那个: 候选池是写死的, 全网几十万台机器都取第一, 结果
  # 所有 REALITY 机器的 SNI 会集中到同一个域名上 —— 统计"哪些机房 IP 在跟这个站
  # 握手"就能整段捞出来。
  # 为什么也不纯随机: 明明有个 20ms 的站, 随机到 300ms 的那个, 回落体验白差一截。
  # 取前三再随机, 两头都照顾到。
  #
  # 用户显式指定的 REALITY_DEST 必须排在最前, 否则会被别的站抢先命中,
  # 等于把"我就要这个站"的意图丢掉了。
  local reachable="" pin=""
  # 黑名单里的站不能当 pin: 它们要么被墙、要么是 CDN 共用证书链, 拿来当 SNI
  # 反而更容易被识别。
  if [ -n "$REALITY_DEST" ] && [ "$REALITY_DEST" != "random" ]; then
    if is_blocked "$REALITY_DEST"; then
      warn "REALITY_DEST=${REALITY_DEST} 在排除名单里, 忽略, 改用自动挑选"
    else
      pin="$REALITY_DEST"
    fi
  fi

  local -a order=() sorted=() grp=() top=()
  local line t2 r2 d2 item tier
  [ -n "$pin" ] && order+=("${pin}|?")
  while IFS= read -r line; do [ -n "$line" ] && sorted+=("$line"); done \
    < <(dest_rank "${cands[@]}")
  for tier in 1 2 3; do
    grp=()
    for line in ${sorted[@]+"${sorted[@]}"}; do
      IFS='|' read -r t2 r2 d2 <<< "$line"
      [ "$t2" = "$tier" ] && grp+=("${d2}|${r2}")
    done
    [ "${#grp[@]}" -gt 0 ] || continue
    # 只把本档最快的 3 个拿出来随机
    top=("${grp[@]:0:3}")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [ "${line%%|*}" = "$pin" ] && continue
      order+=("$line")
    done < <(shuffle_words ${top[@]+"${top[@]}"})
    # 前三名真实握手都失败时, 按耗时顺序补上本档剩下的 —— 不能因为"没被随机到"
    # 就丢掉一个 TLS1.3 的站, 转头去试 TLS1.2 的
    for line in ${grp[@]:3}; do
      [ "${line%%|*}" = "$pin" ] && continue
      order+=("$line")
    done
  done

  for item in ${order[@]+"${order[@]}"}; do
    d2="${item%%|*}"; r2="${item##*|}"
    h=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 "https://$d2/" 2>/dev/null)
    [ "$h" = "000" ] && { warn "$d2 不可达, 跳过"; continue; }
    [ -n "$reachable" ] || reachable="$d2"
    write_xray_config "$d2"
    $XRAY_BIN run -test -c "$XRAY_CFG" >/dev/null 2>&1 || { warn "$d2 配置校验失败, 跳过"; continue; }
    systemctl restart xray >/dev/null 2>&1
    sleep 2
    systemctl is-active --quiet xray || { warn "$d2: xray 启动失败, 跳过"; continue; }
    if verify_reality "$d2"; then
      DEST="$d2"
      if [ "$r2" = "?" ]; then
        ok "$d2 握手通过 (HTTP $h)"
      else
        ok "$d2 握手通过 (HTTP $h, TLS 握手 ${r2}ms)"
      fi
      return 0
    fi
    warn "$d2 握手失败, 换下一个"
  done

  # 握手验证全挂但至少有一个站能直连: 兜底装上, 不要因为"验证手段"失效就中止整个安装。
  # 握手失败更可能是本机出站 443 受限 / 系统时间偏差 / 探测用的临时 xray 起不来,
  # 而不是 dest 不能用 —— REALITY 只在上游探测时才走 dest 回落, 认证客户端照样能连。
  if [ -n "$reachable" ]; then
    DEST="$reachable"
    warn "所有候选站的 REALITY 握手验证都没通过, 用 ${DEST} 兜底继续安装"
    warn "常见原因: 本机出站 443 受限 / 系统时间偏差 / 临时探测实例起不来"
    warn "装完请用客户端实测; 若不通, 换端口重装: VLESS_PORT=8443 bash $(basename "$0") install"
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1
    return 0
  fi

  # 一个都连不上: 把服务恢复到上一次能用的配置, 不要留在最后一个失败配置上
  local last
  last=$(ls -1t "$BACKUP_DIR"/xray-*.json 2>/dev/null | head -1)
  if [ -n "$last" ]; then
    cp -f "$last" "$XRAY_CFG"
    systemctl restart xray >/dev/null 2>&1
    warn "已回滚到上一次可用配置: $(basename "$last")"
  fi
  return 1
}

# 不开 REALITY 时的伪装目标挑选: 只做 HTTPS 可达性检查, 不依赖 xray。
# 用途: hy2 的 masquerade 站点 / 自签证书 CN, anytls 与 tuic 的 SNI。
pick_dest_simple(){
  local d h pin=""
  # 和 pick_dest 同一套打分: 显式指定优先, 其余按 档位 -> 握手耗时 排序,
  # 只在前三名里随机。纯 shuffle 的问题是明明有 20ms 的站却可能选到 300ms 的;
  # 固定取第一又会把全网 SNI 挤到同一个域名上。
  if [ -n "$REALITY_DEST" ] && [ "$REALITY_DEST" != "random" ] && ! is_blocked "$REALITY_DEST"; then
    pin="$REALITY_DEST"
  fi
  local -a pool=() sorted=() top=() order=()
  local line t d2 found i
  for d in www.bing.com www.samsung.com www.nvidia.com www.amd.com \
           www.ibm.com www.tesla.com www.adobe.com www.oracle.com www.dell.com; do
    [ "$d" = "$pin" ] && continue
    pool+=("$d")
  done
  [ -n "$pin" ] && order+=("$pin")
  while IFS= read -r line; do [ -n "$line" ] && sorted+=("$line"); done \
    < <(dest_rank ${pool[@]+"${pool[@]}"})
  # 打分后最快的 3 个, 打散再依次试
  i=0
  for line in ${sorted[@]+"${sorted[@]}"}; do
    [ "$i" -ge 3 ] && break
    top+=("${line##*|}")
    i=$((i + 1))
  done
  if [ "${#top[@]}" -gt 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      order+=("$line")
    done < <(shuffle_words ${top[@]+"${top[@]}"})
  fi
  # 前三个都不通时, 其余按打分顺序兜底
  for line in ${sorted[@]+"${sorted[@]}"}; do
    d2="${line##*|}"
    found=0
    for t in ${order[@]+"${order[@]}"}; do
      [ "$t" = "$d2" ] && { found=1; break; }
    done
    [ "$found" = "1" ] && continue
    order+=("$d2")
  done

  for d in ${order[@]+"${order[@]}"}; do
    is_blocked "$d" && { warn "$d 在排除名单, 跳过"; continue; }
    h=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 "https://$d/" 2>/dev/null)
    [ "$h" = "000" ] && { warn "$d 不可达, 跳过"; continue; }
    DEST="$d"; ok "伪装目标: ${d} (HTTP ${h})"; return 0
  done
  DEST="www.bing.com"
  warn "候选站全部不可达, 回退伪装目标: ${DEST}"
  return 0
}

ensure_xray_service(){
  if [ ! -f /etc/systemd/system/xray.service ] || ! grep -q 'PrivateTmp=true' /etc/systemd/system/xray.service; then
    cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictNamespaces=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
# 内核/配置/二进制目录一律只读: 服务只负责收发流量, 不需要写系统
ProtectSystem=full
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
UMask=0077
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi
  systemctl enable xray >/dev/null 2>&1
}

# ---------------- Hysteria2 ----------------
# 写 hysteria2 配置。$1=1 时带 sniff 段。
# 单独抽出来是因为要能重写: 老版本不认 sniff 时启动会失败, 那时得去掉重写一次,
# 而不是让整个安装死在这里。
write_hy2_config(){
  local sniff="$1"
  {
    echo "listen: :${HY2_PORT}"
    echo ""
    echo "tls:"
    echo "  cert: /etc/hysteria/cert.pem"
    echo "  key: /etc/hysteria/key.pem"
    # 不校验客户端 SNI: 客户端用什么 SNI 都能连, 身份由 auth 密码保证。
    # 这也是 hysteria cert 示例配置的做法, 避免客户端 SNI 与证书 CN 不一致时连不上。
    echo "  sniGuard: disable"
    echo ""
    echo "auth:"
    echo "  type: password"
    echo "  password: ${HY2_PASS}"
    echo ""
    if [ "$sniff" = "1" ]; then
      # 嗅探并把"IP 目标"改写回域名。
      # xray 侧靠 inbound 的 sniffing + routeOnly:false 做这件事: 客户端即使在本地
      # 解析了域名, 服务端也能从 TLS SNI / HTTP Host 里把域名捞回来, 再用服务端 DNS
      # 重新解析。hysteria2 默认不做 —— 客户端发 IP 就只能连那个 IP, 等于用客户端的
      # 解析结果上网, 这正是送中的一条路径。rewriteDomain 补上这一步。
      echo "sniff:"
      echo "  enable: true"
      echo "  timeout: 2s"
      echo "  rewriteDomain: true"
      echo ""
    fi
    if [ "$ENABLE_OBFS" = "1" ]; then
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: ${OBFS_PASS}"
      echo ""
    fi
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: https://${DEST}/"
    echo "    rewriteHost: true"
    echo ""
    echo "quic:"
    echo "  initStreamReceiveWindow: 8388608"
    echo "  maxStreamReceiveWindow: 8388608"
    echo "  initConnReceiveWindow: 20971520"
    echo "  maxConnReceiveWindow: 20971520"
  } > "$HY2_CFG"
  chmod 600 "$HY2_CFG"
}

ensure_hy2(){
  local arch asset sha_arch url ok_dl=0
  # 兜底: 没有伪装目标时证书 CN 与 masquerade 都会是空的
  DEST="${DEST:-www.bing.com}"
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)  asset="hysteria-linux-amd64"; sha_arch="amd64" ;;
    aarch64|arm64) asset="hysteria-linux-arm64"; sha_arch="arm64" ;;
    *) die "不支持的架构: $arch" ;;
  esac

  if [ -x "$HY2_BIN" ]; then
    ok "Hysteria2 已安装, 跳过"
  else
    info "下载 Hysteria2 v${HY2_VERSION} ..."
    # 固定版本而不是 latest: 否则每次重装内核都可能换版本, 行为不可复现,
    # 内置哈希也就失去意义。tag 历史上有 app/ 前缀, 两种形式都试。
    local htmp; htmp=$(mktemp -d)
    for url in \
      "https://github.com/apernet/hysteria/releases/download/app/v${HY2_VERSION}/${asset}" \
      "https://github.com/apernet/hysteria/releases/download/v${HY2_VERSION}/${asset}" ; do
      if download_with_mirror "$url" "$htmp/hy2.bin"; then ok_dl=1; break; fi
    done
    [ "$ok_dl" = "1" ] || { rm -rf "$htmp"; die "Hysteria2 下载失败"; }
    verify_sha256 "$htmp/hy2.bin" "$(pinned_sha "hy2-${sha_arch}-${HY2_VERSION}")" "Hysteria2 v${HY2_VERSION}" \
      || { rm -rf "$htmp"; die "Hysteria2 校验未通过, 已中止"; }
    chmod 700 "$htmp/hy2.bin"
    systemctl stop hysteria-server >/dev/null 2>&1 || true
    install -m 755 "$htmp/hy2.bin" "$HY2_BIN"
    rm -rf "$htmp"
    HY2_BIN_SHA=$(file_sha256 "$HY2_BIN")
    ok "Hysteria2 已安装: $($HY2_BIN version 2>/dev/null | head -1)"
  fi

  # 96 位熵对在线爆破已经够用, 但 hy2 密码会明文出现在客户端配置里,
  # 128 位不增加任何成本, 直接用满。
  [ -n "${HY2_PASS:-}" ] || HY2_PASS=$(openssl rand -hex 16)
  if [ "$ENABLE_OBFS" = "1" ] && [ -z "${OBFS_PASS:-}" ]; then
    OBFS_PASS=$(openssl rand -hex 16)
  fi

  mkdir -p /etc/hysteria
  # 证书只在"缺失"时生成是不够的: 换了伪装站(REALITY_DEST=random / 上一个站被墙)
  # 之后, 证书 CN 还是旧站, 而配置里的 server_name / masquerade 已经指向新站 ——
  # 主动探测一比对就是破绽, 部分客户端也会因此握手异常。
  if [ ! -f /etc/hysteria/cert.pem ] || [ ! -f /etc/hysteria/key.pem ] \
     || [ "$(cert_cn /etc/hysteria/cert.pem)" != "$DEST" ]; then
    info "生成 hysteria2 自签证书 (CN=${DEST})"
    make_self_signed_cert /etc/hysteria/cert.pem /etc/hysteria/key.pem "$DEST" \
      || die "证书生成失败"
  fi
  chmod 600 /etc/hysteria/key.pem

  write_hy2_config 1

  if [ ! -f /etc/systemd/system/hysteria-server.service ] || ! grep -q 'NoNewPrivileges=true' /etc/systemd/system/hysteria-server.service; then
    cat > /etc/systemd/system/hysteria-server.service <<'UNIT'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
User=root
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictNamespaces=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
# 内核/配置/二进制目录一律只读: 服务只负责收发流量, 不需要写系统
ProtectSystem=full
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
UMask=0077
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi
  systemctl enable hysteria-server >/dev/null 2>&1
  systemctl restart hysteria-server >/dev/null 2>&1
  sleep 2
  # sniff 段是较新版本才有的。起不来就去掉重写一次, 而不是让整个安装失败 ——
  # 少了 sniff 只是丢一层防送中兜底, 少了 hysteria 就是没网可用, 两者不对等。
  if ! systemctl is-active --quiet hysteria-server; then
    warn "带 sniff 的 hysteria2 配置未能启动, 去掉 sniff 段重试(该版本可能不支持)"
    write_hy2_config 0
    systemctl restart hysteria-server >/dev/null 2>&1
    sleep 2
  fi
  systemctl is-active --quiet hysteria-server || die "Hysteria2 未能启动, 查看: journalctl -u hysteria-server -n 30"
  ok "Hysteria2 运行中, 监听 UDP ${HY2_PORT}"

  # 自签证书必须靠指纹固定来验证身份, 否则 insecure 等于对中间人完全敞开。
  # hysteria2 的 pinSHA256 = 整张证书 DER 的 SHA-256, 小写 hex 无冒号(64 字符)。
  # 这一点由 `hysteria cert` 的输出直接确认过, 不是 SPKI、也不是 base64。
  # 客户端配置必须 insecure:true + pinSHA256 同时给: insecure 负责跳过 CA 校验,
  # pinSHA256 才是真正的身份校验(官方示例就是这么配的)。
  compute_cert_pins || die "证书指纹计算失败, 拒绝以 insecure 方式部署 (确需跳过请显式加 HY2_INSECURE=1)"
  if [ "$HY2_INSECURE" = "1" ]; then
    HY2_PIN=""
    warn "HY2_INSECURE=1: 客户端将跳过证书验证, 链路上可被冒充(仅建议临时调试)"
  else
    HY2_PIN="${CERT_HEX:-}"
    [ -n "$HY2_PIN" ] || die "无法计算证书指纹(SHA-256 hex)"
    ok "证书固定已启用: ${HY2_PIN:0:24}..."
    if verify_hy2 "$HY2_PIN"; then
      ok "本机握手自测: 通过 (证书固定已验证)"
    else
      warn "本机握手自测未通过, 配置仍使用证书固定, 不回退 insecure"
      warn "  常见原因: 出站测试站不可达 / UDP 回环受限 / 客户端启动慢"
      warn "  客户端若报证书错误, 核对服务端指纹:"
      echo -e "    ${D}openssl x509 -in /etc/hysteria/cert.pem -noout -fingerprint -sha256${N}"
    fi
  fi
}

# ---------------- sing-box 内核: ss2022 / anytls / tuic ----------------
# 这三个协议由同一个 sing-box 进程承载, 端口各自独立, 共用一份自签证书
SB_VERSION="${SB_VERSION:-1.14.4}"

sb_enabled(){ proto_on ss2022 || proto_on anytls || proto_on tuic; }

sb_port_summary(){
  local p=""
  proto_on ss2022 && p="${p} SS2022/${SS2022_PORT}"
  proto_on anytls && p="${p} AnyTLS/${ANYTLS_PORT}"
  proto_on tuic   && p="${p} TUIC/${TUIC_PORT}"
  echo "${p# }"
}

ensure_singbox(){
  sb_enabled || return 0
  local arch asset tmp bin
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
  asset="sing-box-${SB_VERSION}-linux-${arch}.tar.gz"

  if [ -x "$SB_BIN" ] && "$SB_BIN" version 2>/dev/null | grep -qF "$SB_VERSION"; then
    ok "sing-box v${SB_VERSION} 已安装, 跳过"
    return 0
  fi

  info "下载 sing-box v${SB_VERSION} ..."
  tmp=$(mktemp -d)
  download_with_mirror \
    "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${asset}" \
    "$tmp/sb.tar.gz" || die "sing-box 下载失败(检查服务器能否访问 GitHub)"
  verify_sha256 "$tmp/sb.tar.gz" "$(pinned_sha "singbox-${arch}-${SB_VERSION}")" "sing-box v${SB_VERSION}" \
    || { rm -rf "$tmp"; die "sing-box 校验未通过, 已中止"; }
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || die "sing-box 解压失败"
  bin=$(find "$tmp" -type f -name sing-box 2>/dev/null | head -1)
  [ -n "$bin" ] || die "压缩包内未找到 sing-box"
  systemctl stop sing-box >/dev/null 2>&1 || true
  install -m 755 "$bin" "$SB_BIN"
  rm -rf "$tmp"
  mkdir -p "$SB_DIR"; chmod 700 "$SB_DIR"
  SB_BIN_SHA=$(file_sha256 "$SB_BIN")
  ok "sing-box 已安装: $($SB_BIN version 2>/dev/null | head -1)"
}

ensure_sb_cert(){
  sb_enabled || return 0
  mkdir -p "$SB_DIR"; chmod 700 "$SB_DIR"
  local cn="${DEST:-www.bing.com}"
  # 与 hysteria2 侧同理: 换了伪装站要跟着换证书, 否则 CN 与 server_name 对不上。
  if [ ! -f "$SB_CERT" ] || [ ! -f "$SB_KEY" ] \
     || [ "$(cert_cn "$SB_CERT")" != "$cn" ]; then
    make_self_signed_cert "$SB_CERT" "$SB_KEY" "$cn" || die "sing-box 证书生成失败"
  fi
  chmod 600 "$SB_KEY"; chmod 644 "$SB_CERT"
  SB_PIN=$(openssl x509 -in "$SB_CERT" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary | openssl base64 -A)
  SB_HEX=$(openssl x509 -in "$SB_CERT" -noout -fingerprint -sha256 2>/dev/null \
    | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')
  [ -n "$SB_PIN" ] || warn "sing-box 证书指纹计算失败, 客户端将无法固定校验"
}

# 由 UUID 无状态派生密码: 不额外占状态字段, 换 UUID 即换密码
derive_hex(){
  printf '%s' "$1" | openssl dgst -sha256 -hex 2>/dev/null | sed 's/^.*= *//' | cut -c1-32
}

# SS2022 要求 base64 编码的 16 字节密钥
derive_ss_key(){
  printf '%s' "$1" | openssl dgst -sha256 -binary 2>/dev/null | head -c 16 | openssl base64 -A
}

# SS2022 多用户模式下客户端的真实密码。
# 服务端配了 users 数组就走 EIH 多用户模式, 客户端密码必须是
# "服务端密钥:设备密钥"(冒号分隔, 两段都是 base64 16 字节)。
# 只给设备密钥会被服务端直接拒掉 —— 这一点由 sing-shadowsocks2 的
# NewMethod 源码确认: strings.Split(password, ":") 得到 pskList,
# 长度 > 1 才走 EIH, 长度 == 1 就是单用户模式, 与多用户服务端不匹配。
ss_pass_for(){
  local u="${1:-${UUID}}"
  if [ -n "${SS2022_PASS:-}" ]; then
    printf '%s:%s' "$SS2022_PASS" "$(derive_ss_key "$u")"
  else
    derive_ss_key "$u"
  fi
}

ensure_sb_creds(){
  sb_enabled || return 0
  [ -n "${SS2022_PASS:-}" ] || SS2022_PASS=$(openssl rand -base64 16)
  [ -n "${ANYTLS_PASS:-}" ] || ANYTLS_PASS=$(openssl rand -hex 16)
  [ -n "${TUIC_PASS:-}" ]   || TUIC_PASS=$(openssl rand -hex 16)
  [ -n "${TUIC_UUID:-}" ]   || TUIC_UUID=$(gen_uuid)
}

# JSON 字符串转义。设备名来自 users.txt, 可能是历史遗留或手改的,
# 这里兜一道: 名字里带 " 或 \ 不会把整份 sing-box 配置写坏。
json_esc(){
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037\177'
}

# 生成 sing-box users 数组. kind: tuic | anytls | ss
sb_users_json(){
  local kind="$1" out="" u name
  if [ -f "$USERS_FILE" ]; then
    while IFS='|' read -r u name _; do
      [ -n "$u" ] || continue
      name=$(json_esc "$name")
      case "$kind" in
        tuic)   out="${out}{\"uuid\":\"${u}\",\"password\":\"$(derive_hex "$u")\"}," ;;
        anytls) out="${out}{\"name\":\"${name}\",\"password\":\"$(derive_hex "$u")\"}," ;;
        ss)     out="${out}{\"name\":\"${name}\",\"password\":\"$(derive_ss_key "$u")\"}," ;;
      esac
    done < "$USERS_FILE"
  fi
  if [ -z "$out" ]; then
    case "$kind" in
      tuic)   out="{\"uuid\":\"${TUIC_UUID}\",\"password\":\"${TUIC_PASS}\"}," ;;
      anytls) out="{\"name\":\"default\",\"password\":\"${ANYTLS_PASS}\"}," ;;
      ss)     out="{\"name\":\"default\",\"password\":\"$(derive_ss_key "${UUID:-default}")\"}," ;;
    esac
  fi
  printf '[%s]' "${out%,}"
}

# sing-box 的 listen 用 "::" 才能同时吃 v4/v6, 但在 disable_ipv6=1 的机器上
# bind 会直接失败, 那种机器必须退成 0.0.0.0, 否则三个协议一起起不来。
sb_listen_addr(){
  if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] \
     && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ]; then
    echo "0.0.0.0"
  else
    echo "::"
  fi
}

write_singbox_config(){
  sb_enabled || return 0
  local tls_h2 tls_h3 dest sb_listen
  # server_name 不能空: 证书 CN 那边已经兜底成 www.bing.com, 这里必须跟着一致
  dest="${DEST:-www.bing.com}"
  sb_listen=$(sb_listen_addr)

  tls_h2=$(printf '{"enabled":true,"server_name":"%s","certificate_path":"%s","key_path":"%s","alpn":["h2","http/1.1"]}' \
    "$dest" "$SB_CERT" "$SB_KEY")
  tls_h3=$(printf '{"enabled":true,"server_name":"%s","certificate_path":"%s","key_path":"%s","alpn":["h3"]}' \
    "$dest" "$SB_CERT" "$SB_KEY")

  # 生成 inbounds 数组。$1 是要追加到每个 inbound 末尾的字段:
  #   空串                                  -> 什么都不加
  #   ,\n "sniff": true, ...                -> 旧版 sing-box 的 inbound 级嗅探
  # 追加点放在每个对象最后一个字段之后, 空串时 JSON 依然合法。
  #
  # 为什么需要两种写法: route 里的 {"action":"sniff"} 是 1.11 才有的; 1.8~1.10
  # 只有 inbound 上的 sniff + sniff_override_destination。原实现只试新写法,
  # 老内核上直接放弃嗅探 —— 等于 ss2022/anytls/tuic 三个协议在服务端看不到域名,
  # 客户端本地解析出来的 IP 一路带到底, 这正是送中的一条路。
  sb_inbounds_json(){
    local sf="${1:-}" parts=()
    if proto_on ss2022; then
      parts+=("$(cat <<JSON
    {
      "type": "shadowsocks",
      "tag": "ss2022-in",
      "listen": "${sb_listen}",
      "listen_port": ${SS2022_PORT},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${SS2022_PASS}",
      "users": $(sb_users_json ss)${sf}
    }
JSON
)")
    fi
    if proto_on anytls; then
      parts+=("$(cat <<JSON
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${sb_listen}",
      "listen_port": ${ANYTLS_PORT},
      "users": $(sb_users_json anytls),
      "tls": ${tls_h2}${sf}
    }
JSON
)")
    fi
    if proto_on tuic; then
      parts+=("$(cat <<JSON
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "${sb_listen}",
      "listen_port": ${TUIC_PORT},
      "users": $(sb_users_json tuic),
      "congestion_control": "bbr",
      "tls": ${tls_h3}${sf}
    }
JSON
)")
    fi
    [ "${#parts[@]}" -gt 0 ] || { printf ''; return 0; }
    printf '%s\n' "$(printf '%s,\n' "${parts[@]}" | sed '$ s/,$//')"
  }

  # 上游出口: 与 xray 侧同样处理, 只是这里用 route.final 指定默认出站
  local sb_ob sb_final="direct" sb_line sb_scheme sb_host sb_port sb_user sb_pass sb_cred=""
  if sb_line=$(parse_egress); then
    IFS='|' read -r sb_scheme sb_host sb_port sb_user sb_pass <<< "$sb_line"
    [ -n "$sb_user" ] && sb_cred=", \"username\": \"${sb_user}\", \"password\": \"${sb_pass}\""
    sb_ob="  \"outbounds\": [
    { \"type\": \"${sb_scheme}\", \"tag\": \"egress\", \"server\": \"${sb_host}\", \"server_port\": ${sb_port}${sb_cred} },
    { \"type\": \"direct\", \"tag\": \"direct\" }
  ],"
    sb_final="egress"
  else
    sb_ob='  "outbounds": [ { "type": "direct", "tag": "direct" } ],'
  fi

  # 域名嗅探。客户端如果先本地把域名解析成 IP 再发过来, 服务端就只能连那个 IP;
  # 解析结果一旦是境外 CDN 的地址, Google 反查就落到客户端所在地 —— 也就是送中。
  #   xray        : inbound sniffing + routeOnly:false
  #   hysteria2   : sniff + rewriteDomain
  #   sing-box    : 1.11+ 用 route 的 sniff 动作; 1.8~1.10 只有 inbound 级嗅探
  # 三种写法按新到旧依次试, check 通过就用。全都不认才放弃 —— 而不是像原来那样
  # 只试新写法, 老内核上直接把嗅探丢了。
  local attempt sb_route sb_sf slog
  slog=$(mktemp)
  for attempt in 1 2 0; do
    case "$attempt" in
      1)
        sb_route="  \"route\": { \"rules\": [ { \"action\": \"sniff\" } ], \"final\": \"${sb_final}\" }"
        sb_sf=""
        ;;
      2)
        sb_route="  \"route\": { \"final\": \"${sb_final}\" }"
        sb_sf=$',\n      "sniff": true,\n      "sniff_override_destination": true'
        ;;
      *)
        sb_route="  \"route\": { \"final\": \"${sb_final}\" }"
        sb_sf=""
        ;;
    esac
    {
      echo "{"
      echo '  "log": { "level": "warn", "timestamp": true },'
      printf '  "inbounds": [\n%s\n  ],\n' "$(sb_inbounds_json "$sb_sf")"
      printf '%s\n' "$sb_ob"
      printf '%s\n' "$sb_route"
      echo "}"
    } > "$SB_CFG"

    if "$SB_BIN" check -c "$SB_CFG" >"$slog" 2>&1; then
      case "$attempt" in
        2) warn "sing-box 不认 route 的 sniff 动作, 已改用 inbound 级嗅探(能防送中, 但建议 proxy upgrade 升到 1.11+)" ;;
        0) warn "sing-box 不支持任何形式的域名嗅探, 已跳过域名还原(ss2022/anytls/tuic 会按客户端发来的 IP 直连)" ;;
      esac
      break
    fi
    if [ "$attempt" = "0" ]; then
      err "sing-box 配置校验失败:"
      sed -n '1,5p' "$slog" | sed 's/^/    /' >&2
      rm -f "$slog"
      die "请把上面几行发给我"
    fi
  done
  rm -f "$slog"
  chmod 600 "$SB_CFG"
}

ensure_singbox_service(){
  sb_enabled || return 0
  if [ ! -f /etc/systemd/system/sing-box.service ] \
     || ! grep -q 'NoNewPrivileges=true' /etc/systemd/system/sing-box.service; then
    cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box Server
After=network.target

[Service]
Type=simple
User=root
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictNamespaces=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
# 内核/配置/二进制目录一律只读: 服务只负责收发流量, 不需要写系统
ProtectSystem=full
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
UMask=0077
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi
  systemctl enable sing-box >/dev/null 2>&1
  systemctl restart sing-box >/dev/null 2>&1
  sleep 2
  systemctl is-active --quiet sing-box \
    || die "sing-box 未能启动, 查看: journalctl -u sing-box -n 30 --no-pager"
  ok "sing-box 运行中: $(sb_port_summary)"
}

# 自签证书的三种指纹表示, 对应不同客户端字段(算法不同, 不能混用):
#   整证书 SHA-256 (hex)    -> hysteria2 URI / 配置里的 pinSHA256; mihomo 的 fingerprint
#                              已用 `hysteria cert` 的输出核对过, 就是整证书 DER 的 hex
#   SPKI 公钥 SHA-256 (b64) -> sing-box 的 certificate_public_key_sha256
#   整证书 SHA-256 (b64)    -> 部分实现按整证书 base64 校验, 作为兜底
compute_cert_pins(){
  local cert=/etc/hysteria/cert.pem
  [ -f "$cert" ] || return 1
  CERT_SPKI_B64=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A 2>/dev/null)
  CERT_DER_B64=$(openssl x509 -in "$cert" -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A 2>/dev/null)
  CERT_HEX=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null \
    | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')
  [ -n "$CERT_SPKI_B64" ] && [ -n "$CERT_DER_B64" ] && [ -n "$CERT_HEX" ]
}

# 用真实握手验证一条 pin 是否被服务端接受; pin 为空则测 insecure
# 注意: 这个测试只用于"确认/诊断", 不参与是否启用证书固定的决策
verify_hy2(){
  local pin="${1:-}" code i pid
  [ -x "$HY2_BIN" ] || return 1

  # 自测配置里有 hy2 明文密码, 不能放在 /tmp: 世界可写的目录里
  # 既会被同机用户读到, 也能被预先做成软链接。改用 0700 的 /run 子目录。
  local hcd=/run/proxy-hc
  mkdir -p "$hcd" 2>/dev/null; chmod 700 "$hcd" 2>/dev/null

  # 清掉上次可能残留的客户端, 否则 10898 端口会假就绪
  pkill -f "hysteria client -c ${hcd}/hc.yaml" >/dev/null 2>&1 || true

  {
    echo "server: 127.0.0.1:${HY2_PORT}"
    echo "auth: ${HY2_PASS}"
    echo "tls:"
    echo "  sni: ${DEST}"
    if [ -n "$pin" ]; then
      # 官方示例: insecure 跳过 CA 校验, pinSHA256 做真正的身份校验
      echo "  insecure: true"
      echo "  pinSHA256: ${pin}"
    else
      echo "  insecure: true"
    fi
    if [ "$ENABLE_OBFS" = "1" ]; then
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: ${OBFS_PASS}"
    fi
    echo "socks5:"
    echo "  listen: 127.0.0.1:10898"
  } > "$hcd/hc.yaml"

  : > "$hcd/hc.log"
  chmod 600 "$hcd/hc.yaml" "$hcd/hc.log" 2>/dev/null
  "$HY2_BIN" client -c "$hcd/hc.yaml" >>"$hcd/hc.log" 2>&1 &
  pid=$!

  # 等 socks5 端口真正起来, 最多 10 秒(原来固定 sleep 4 经常不够)
  for i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    if command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | grep -q ':10898 ' && break
    else
      sleep 0.5
    fi
    sleep 0.5
  done

  code=$(curl -s --socks5-hostname 127.0.0.1:10898 -o /dev/null -w '%{http_code}' --max-time 15 https://www.gstatic.com/generate_204 2>/dev/null)
  case "$code" in
    000|"") code=$(curl -s --socks5-hostname 127.0.0.1:10898 -o /dev/null -w '%{http_code}' --max-time 20 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) ;;
  esac

  kill "$pid" >/dev/null 2>&1; wait "$pid" 2>/dev/null

  case "$code" in
    2*|3*) rm -rf "$hcd"; return 0 ;;
  esac

  # 失败必须把客户端输出带出来, 否则永远不知道为什么不通
  if [ -s "$hcd/hc.log" ]; then
    echo -e "    ${D}--- hysteria client 输出 ---${N}" >&2
    tail -6 "$hcd/hc.log" | sed 's/^/    /' >&2
  fi
  rm -rf "$hcd"
  return 1
}

# ---------------- 端口跳跃 ----------------
setup_hy2_hop(){
  if [ -z "${HY2_HOP:-}" ]; then
    # 关掉端口跳跃: 之前开过就必须真的停。hy2-hop 是 oneshot + RemainAfterExit,
    # ExecStop 才会删那条 iptables REDIRECT; 只 disable 不 stop 的话规则一直留着,
    # 那一段 UDP 端口对公网始终是开的。
    if [ -f /etc/systemd/system/hy2-hop.service ]; then
      if systemctl is-active --quiet hy2-hop 2>/dev/null \
         || systemctl is-enabled --quiet hy2-hop 2>/dev/null; then
        systemctl disable --now hy2-hop >/dev/null 2>&1 \
          && warn "已停用端口跳跃 (HY2_HOP 为空, NAT 规则已清理)"
      fi
    fi
    return 0
  fi
  local start end
  start="${HY2_HOP%%-*}"; end="${HY2_HOP##*-}"
  if ! echo "${start}${end}" | grep -qE '^[0-9]+$'; then
    warn "HY2_HOP 格式错误(应为 20000-30000), 跳过端口跳跃"; return 0
  fi
  cat > /etc/systemd/system/hy2-hop.service <<EOF
[Unit]
Description=Hysteria2 UDP port hopping (${HY2_HOP} -> ${HY2_PORT})
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports ${HY2_PORT} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports ${HY2_PORT}'
ExecStop=/bin/sh -c 'iptables -t nat -D PREROUTING -p udp --dport ${start}:${end} -j REDIRECT --to-ports ${HY2_PORT} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable hy2-hop >/dev/null 2>&1
  systemctl restart hy2-hop >/dev/null 2>&1
  if systemctl is-active --quiet hy2-hop; then
    ok "端口跳跃已启用: UDP ${HY2_HOP} -> ${HY2_PORT}"
    warn "云安全组必须放行 UDP ${HY2_HOP}, 否则跳跃无效"
  else
    warn "端口跳跃启动失败(可能缺少 iptables nat 支持), 已跳过"
  fi
}

# ---------------- 系统优化 ----------------
# $1: all(默认) | bbr | swap | time | log
optimize_system(){
  local what="${1:-all}"

  case "$what" in
  all|bbr)
    info "内核参数与 BBR ..."
    cat > /etc/sysctl.d/99-proxy-optimize.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
# 缓冲区上限要盖过 hysteria 的 QUIC 窗口(配置里是 8MB/20MB),
# 否则内核会把 SO_RCVBUF 截断, UDP 大流量跑不满带宽
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
# 短连接复用 TIME_WAIT, 代理场景下能少占端口
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=10000 65000
net.ipv4.tcp_mtu_probing=1
net.ipv4.ip_forward=1
# 空闲后不重置拥塞窗口, 长连接(视频/直播)不会每隔一阵子重新慢启动
net.ipv4.tcp_slow_start_after_idle=0
# 降低小包发送延迟, 对交互类流量更跟手
net.ipv4.tcp_notsent_lowat=16384
# 并发连接能力
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_syncookies=1
fs.file-max=1048576
# 连接跟踪表上限(模块未加载时该行会被内核忽略)
net.netfilter.nf_conntrack_max=65536
# UDP 收发内存: hysteria2 / TUIC 全靠 UDP, 默认上限在小机器上会直接丢包,
# 表现为"带宽跑不满 + 偶发卡顿"。单位是页(4KB), 这里是 128MB/192MB/256MB 的上限。
net.ipv4.udp_mem=32768 49152 65536
# 网卡收包队列: 突发流量下默认 1000 太小, 会在这里丢包(ip -s link 的 dropped 会涨)
net.core.netdev_max_backlog=16384
# 主动关闭的连接早点回收, 代理场景下 TIME_WAIT 少堆一点
net.ipv4.tcp_fin_timeout=15
SYSCTL
    sysctl -p /etc/sysctl.d/99-proxy-optimize.conf >/dev/null 2>&1

    # 这里必须真的核对一遍: 内核 < 4.9 或模块没编进去时, 写 bbr 会静默失败,
    # 之前无论成没成都打印 "ok BBR: ...", 看起来调好了其实还是 cubic。
    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ "$cc" = "bbr" ]; then
      ok "拥塞控制: bbr (队列: ${qd:-未知})"
    else
      warn "拥塞控制: ${cc:-未知} —— 当前内核不支持 BBR(需 4.9+), 高速率下会明显掉速"
      warn "查一下可用算法: sysctl net.ipv4.tcp_available_congestion_control"
    fi

    # conntrack 上限已写进 sysctl 持久化, 这里补一次运行时生效
    if [ -w /proc/sys/net/netfilter/nf_conntrack_max ]; then
      echo 65536 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
      ok "conntrack_max: $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
    fi

    # 进程句柄数: 高并发下默认 1024 会成为瓶颈
    if [ -d /etc/security/limits.d ]; then
      cat > /etc/security/limits.d/99-proxy-nofile.conf <<'LIMITS'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
LIMITS
      ok "句柄数上限: 65535"
    fi
    ;;&
  all|log)
    # journald 限容: 小硬盘机器最容易被日志写满
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-proxy-size.conf <<'JOURNAL'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=20M
JOURNAL
    systemctl restart systemd-journald >/dev/null 2>&1 && ok "journald 日志上限: 100M"
    ;;&
  all|swap)
    if [ "$(free -m | awk '/Swap:/{print $2}')" = "0" ] && [ ! -f /swapfile ]; then
      fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null
      chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      ok "已添加 1GB swap"
    else
      ok "swap 已就绪 ($(free -m | awk '/Swap:/{print $2}')MB)"
    fi
    ;;&
  all|time)
    # REALITY 依赖时间偏差, 差几分钟就会握手失败
    if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd.service'; then
      systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
      if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
        ok "时间同步: 已同步"
      else
        warn "时间同步: 服务已启用, 但尚未完成同步(等 1 分钟再查)"
      fi
    else
      warn "系统没有 systemd-timesyncd, 跳过时间同步"
    fi
    ;;&
  esac
}

cmd_optimize(){
  need_root
  local what="${1:-all}"
  case "$what" in
    all|bbr|swap|time|log) ;;
    *) die "未知优化项: ${what} (可选: all bbr swap time log)" ;;
  esac

  echo
  echo -e "${M}============================================================${N}"
  echo -e "${M}   VPS 优化${N}"
  echo -e "${M}============================================================${N}"
  echo
  case "$what" in
    all)  echo "  将执行: BBR + 内核参数 + 句柄数 + 日志限容 + swap + 时间同步" ;;
    bbr)  echo "  将执行: BBR + 内核参数 + 句柄数" ;;
    log)  echo "  将执行: journald 日志限容" ;;
    swap) echo "  将执行: 1GB swap (已有则跳过)" ;;
    time) echo "  将执行: 时间同步" ;;
  esac
  echo -e "  ${D}只改系统网络参数, 不动任何已有服务配置${N}"
  echo
  if [ "$ASSUME_YES" != "1" ]; then
    ask_yes "开始优化?" || { info "已取消"; return 0; }
    echo
  fi

  optimize_system "$what"
  echo
  ok "优化完成"
  echo -e "  ${D}当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${N}"
  echo -e "  ${D}当前 swap: $(free -m | awk '/Swap:/{print $2}')MB${N}"
  if [ "$what" = "all" ] || [ "$what" = "bbr" ]; then
    echo -e "  ${D}已运行的 UDP 服务是在旧 socket 缓冲区下创建的; 要吃满新参数请执行: proxy restart${N}"
  fi
  if [ "$what" = "all" ] || [ "$what" = "time" ]; then
    echo -e "  ${D}时区未改动, 当前: $(cur_timezone)  (要按机器所在地区设置用 proxy timezone)${N}"
  fi
  echo
}

# ---------------- 时区 ----------------
# 注意: NTP 同步(把 UTC 校准) 和 时区(本地怎么显示) 是两件事。
# TLS / REALITY 只认 UTC 时间戳, 时区设成什么都能正常握手。
# 但时区是平台风控的软信号: IP 在东京、系统时区是上海, 等于自己承认人不在这个区。
# 所以原则是"这台机器在哪就设哪", 不是"一律设美国"。
cur_timezone(){
  timedatectl show -p Timezone --value 2>/dev/null \
    || cat /etc/timezone 2>/dev/null \
    || echo "unknown"
}

# 探测出口 IP 所在时区; 失败返回空(不阻塞, 菜单里可手动选)
# 注意: 这一步会把本机 IP 交给第三方, 只在你主动选"自动匹配"时才会用到
# $1 可选: 指定要查的 IP。审计里要查的是"平台实际看到的那个 IP",
# 配了上游出口时它和本机 IP 不是同一个, 不传就会查错对象。
# 三个来源依次试: ip-api 最快但会限速; ipinfo 稳; ipwho.is 兜底。
# 任何一家能给出合法时区就停, 不要为了"多源校验"把三次请求都打出去。
detect_exit_tz(){
  local tz="" ip="${1:-}" cand src
  command -v curl >/dev/null 2>&1 || { printf ''; return 0; }

  for src in ipapi ipinfo ipwho; do
    case "$src" in
      ipapi)
        cand=$(curl -s --max-time 4 "http://ip-api.com/line/${ip}?fields=timezone" 2>/dev/null \
               | head -1 | tr -d '\r') ;;
      ipinfo)
        cand=$(curl -s --max-time 4 "https://ipinfo.io/${ip}/timezone" 2>/dev/null \
               | tr -d '\r\n') ;;
      ipwho)
        # JSON 里的斜杠可能被转义成 \/ , 先去掉反斜杠再取 timezone.id
        cand=$(curl -s --max-time 5 "https://ipwho.is/${ip}" 2>/dev/null \
               | tr -d '\\' \
               | grep -o '"timezone":{[^}]*}' | head -1 \
               | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4) ;;
    esac
    case "$cand" in */*) tz="$cand"; break ;; esac
  done

  # 必须在本机 zoneinfo 里真的存在才返回。接口偶尔给出 "Asia/Calcutta" 这类
  # 别名、或者干脆是脏数据, 直接交给 set_timezone 会让用户 die 在一个
  # 看不懂的错上。查不到就当没探到, 菜单里手动选。
  if [ -n "$tz" ] && [ -f "/usr/share/zoneinfo/${tz}" ]; then
    printf '%s' "$tz"
  fi
  return 0
}

# 国家代码 -> 中文名, 只列常见的。查不到返回空, 不硬造名字。
cc_note(){
  case "$1" in
    US) printf ' (美国)' ;;      HK) printf ' (中国香港)' ;;  MO) printf ' (中国澳门)' ;;
    TW) printf ' (中国台湾)' ;;  JP) printf ' (日本)' ;;      KR) printf ' (韩国)' ;;
    SG) printf ' (新加坡)' ;;    MY) printf ' (马来西亚)' ;;  TH) printf ' (泰国)' ;;
    ID) printf ' (印尼)' ;;      VN) printf ' (越南)' ;;      PH) printf ' (菲律宾)' ;;
    IN) printf ' (印度)' ;;      AE) printf ' (阿联酋)' ;;    TR) printf ' (土耳其)' ;;
    DE) printf ' (德国)' ;;      GB|UK) printf ' (英国)' ;;   NL) printf ' (荷兰)' ;;
    FR) printf ' (法国)' ;;      CH) printf ' (瑞士)' ;;      AT) printf ' (奥地利)' ;;
    SE) printf ' (瑞典)' ;;      NO) printf ' (挪威)' ;;      DK) printf ' (丹麦)' ;;
    FI) printf ' (芬兰)' ;;      PL) printf ' (波兰)' ;;      CZ) printf ' (捷克)' ;;
    IT) printf ' (意大利)' ;;    ES) printf ' (西班牙)' ;;    IE) printf ' (爱尔兰)' ;;
    RU) printf ' (俄罗斯)' ;;    CA) printf ' (加拿大)' ;;    AU) printf ' (澳洲)' ;;
    NZ) printf ' (新西兰)' ;;    BR) printf ' (巴西)' ;;      MX) printf ' (墨西哥)' ;;
    CN) printf ' (中国大陆)' ;;
  esac
  return 0
}

# 出口国家 -> 该国的 Google 本地域名。表里没有的国家返回 google.com:
# Google 只在部分国家换域名, 其余国家直接用 .com。
google_cc_tld(){
  case "$1" in
    HK|MO) echo google.com.hk ;;
    JP) echo google.co.jp ;;      KR) echo google.co.kr ;;
    TW) echo google.com.tw ;;     SG) echo google.com.sg ;;
    GB|UK) echo google.co.uk ;;   IE) echo google.ie ;;
    DE) echo google.de ;;         FR) echo google.fr ;;
    NL) echo google.nl ;;         IT) echo google.it ;;
    ES) echo google.es ;;         CH) echo google.ch ;;
    AT) echo google.at ;;         BE) echo google.be ;;
    SE) echo google.se ;;         NO) echo google.no ;;
    DK) echo google.dk ;;         FI) echo google.fi ;;
    PL) echo google.pl ;;         CZ) echo google.cz ;;
    RU) echo google.ru ;;         TR) echo google.com.tr ;;
    IN) echo google.co.in ;;      AU) echo google.com.au ;;
    NZ) echo google.co.nz ;;      CA) echo google.ca ;;
    BR) echo google.com.br ;;     MX) echo google.com.mx ;;
    AR) echo google.com.ar ;;     CL) echo google.cl ;;
    TH) echo google.co.th ;;      MY) echo google.com.my ;;
    ID) echo google.co.id ;;      VN) echo google.com.vn ;;
    PH) echo google.com.ph ;;     IL) echo google.co.il ;;
    AE) echo google.ae ;;         SA) echo google.com.sa ;;
    ZA) echo google.co.za ;;
    *) echo google.com ;;
  esac
}

# IP 反查只能查到"这段 IP 登记在谁名下", 查不到"你把钱付给了谁"。
# RackNerd / CloudCone / AlphaVPS 这类转售商自己没有 ASN, 机器和 IP 都租自
# ColoCrossing(2023 年被 HostPapa 收购, AS36352 的登记名已改成 HostPapa)、
# Psychz、QuadraNet 等批发商, 所以反查必然返回批发商的名字。
# 命中这张表时说明"这个结果大概不是你买的商家", 装完提示用户自己改。
vendor_is_upstream(){
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    hostpapa|colocrossing|psychz|quadranet|internap|cogent|hurricane|level3|lumen|zayo|equinix|voxility|datacamp|servercentral|telia|gtt|ntt|tata) return 0 ;;
  esac
  return 1
}

# 从出口 IP 反查 VPS 厂商, 用作节点备注名
# 目标: 客户端列表里显示 "RackNerd-VLESS" 而不是 "Node-VLESS", 一眼看出是哪台机器
# 只取一个短词: 去 AS 号 / 去逗号分支 / 跳过法律后缀与冠词 / 去 .com 尾巴
detect_vendor(){
  local raw="" name="" out="" tok second="" resp="" isp="" asn=""

  command -v curl >/dev/null 2>&1 || { printf ''; return 0; }

  # 一次请求同时拿 isp 与 as: 免费接口连发两次会被限速
  resp=$(curl -s --max-time 5 "http://ip-api.com/line/?fields=isp,as" 2>/dev/null | tr -d '\r')
  isp=$(printf '%s\n' "$resp" | sed -n 1p)
  asn=$(printf '%s\n' "$resp" | sed -n 2p)

  raw="$isp"
  case "$raw" in ""|*"not assigned"*|*"Reserved"*) raw="$asn" ;; esac
  if [ -z "$raw" ]; then
    raw=$(curl -s --max-time 5 "https://ipinfo.io/org" 2>/dev/null | tr -d '\r\n')
  fi
  [ -n "$raw" ] || { printf ''; return 0; }

  # "AS36352 ColoCrossing" -> "ColoCrossing"; 只有 AS 号没有名字则放弃
  case "$raw" in
    AS[0-9]*)
      name="${raw#AS}"
      case "$name" in
        *" "*) name="${name#* }" ;;
        *)     name="" ;;
      esac
      ;;
    *) name="$raw" ;;
  esac
  [ -n "$name" ] || { printf ''; return 0; }

  # "Amazon.com, Inc." -> "Amazon.com"
  name="${name%%,*}"

  # 取第一个有意义的词: 跳过 LLC / Inc / GmbH / The 之类
  for tok in $name; do
    case "$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]' | tr -d '.,')" in
      the|a|an|llc|ltd|inc|incorporated|corp|corporation|co|company|limited|gmbh|bv|nv|sa|sas|sarl|pte|pty|plc|ag|oy|ab|as|kft|sp|zoo) continue ;;
    esac
    out="$tok"
    break
  done
  [ -n "$out" ] || out="${name%% *}"

  # 国名前缀: "China Mobile" 只取第一个词会变成没意义的 "China", 拼上第二个词
  case "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" in
    china|hong|korea|japan|singapore|india|vietnam|thai|taiwan)
      for tok in $name; do
        if [ "$tok" != "$out" ]; then second="$tok"; break; fi
      done
      [ -n "$second" ] && out="${out}${second}"
      ;;
  esac

  out="${out%.com}"; out="${out%.net}"; out="${out%.org}"
  out=$(printf '%s' "$out" | sed 's/[^A-Za-z0-9._-]//g')

  # 拿不到有效组织名时不要造出 "Reserved" / "Unknown" 这种备注
  case "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" in
    ""|reserved|unknown|private|localhost|none|na) printf ''; return 0 ;;
  esac

  # 少量映射: ASN 组织名和用户认知差得比较远的几家
  case "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" in
    choopa|constant|vultr*)      out="Vultr" ;;
    amazon|aws*)                 out="AWS" ;;
    tencent*)                    out="Tencent" ;;
    alibaba|aliyun*)             out="Aliyun" ;;
    chinanet*|chinatelecom*)     out="ChinaTelecom" ;;
    chinaunicom*|cucc*)          out="ChinaUnicom" ;;
    chinamobile*|cmcc*)          out="ChinaMobile" ;;
    oracle*)                     out="Oracle" ;;
    google*)                     out="Google" ;;
    microsoft*)                  out="Azure" ;;
    linode*|akamai*)             out="Linode" ;;
  esac

  printf '%s' "$out"
}

set_timezone(){
  local tz="$1" after
  if [ -z "$tz" ]; then return 1; fi
  if [ ! -f "/usr/share/zoneinfo/${tz}" ]; then
    warn "未知时区: ${tz}"
    echo -e "  ${D}查可用时区: timedatectl list-timezones | grep -i tokyo${N}"
    echo -e "  ${D}格式是 大洲/城市, 例如 Asia/Tokyo、Europe/Berlin${N}"
    return 1
  fi
  if ! timedatectl set-timezone "$tz" >/dev/null 2>&1; then
    # 容器/精简系统里 timedatectl 可能不可用, 直接改链接
    ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null \
      && echo "$tz" > /etc/timezone 2>/dev/null \
      || { warn "设置时区失败, 请手动执行: timedatectl set-timezone ${tz}"; return 1; }
  fi
  after=$(cur_timezone)
  if [ "$after" = "$tz" ]; then
    ok "时区已设为: ${tz}"
  else
    warn "已写入, 但当前读到的仍是: ${after} (可能需要在 SSH 里重新登录)"
  fi
  echo -e "  当前时间: ${Y}$(date '+%Y-%m-%d %H:%M:%S %Z (%z)')${N}"
}

# 时区分组候选。只列常见地区 —— 不在表里的用"手动输入"直接写时区名,
# set_timezone 会拿 /usr/share/zoneinfo 校验, 输错不会写坏系统。
# 每行格式: 时区|中文说明
tz_group(){
  case "$1" in
    asia) cat <<'TZL'
Asia/Hong_Kong|中国香港
Asia/Macau|中国澳门
Asia/Taipei|中国台湾
Asia/Tokyo|日本
Asia/Seoul|韩国
Asia/Singapore|新加坡
Asia/Kuala_Lumpur|马来西亚
Asia/Bangkok|泰国
Asia/Ho_Chi_Minh|越南
Asia/Jakarta|印尼
Asia/Manila|菲律宾
Asia/Kolkata|印度
Asia/Dubai|阿联酋 / 中东
Australia/Sydney|澳洲
TZL
      ;;
    europe) cat <<'TZL'
Europe/London|英国
Europe/Dublin|爱尔兰
Europe/Berlin|德国
Europe/Amsterdam|荷兰
Europe/Paris|法国
Europe/Zurich|瑞士
Europe/Vienna|奥地利
Europe/Stockholm|瑞典
Europe/Oslo|挪威
Europe/Helsinki|芬兰
Europe/Warsaw|波兰
Europe/Prague|捷克
Europe/Madrid|西班牙
Europe/Rome|意大利
Europe/Moscow|俄罗斯
TZL
      ;;
    america) cat <<'TZL'
America/Los_Angeles|美西 洛杉矶 / 圣何塞 / 西雅图
America/Denver|美西 山地 (丹佛 / 盐湖城)
America/Chicago|美中 达拉斯 / 芝加哥
America/New_York|美东 纽约 / 阿什本
America/Toronto|加拿大 东部
America/Vancouver|加拿大 西部
America/Sao_Paulo|巴西
TZL
      ;;
  esac
}

# 二级菜单: 选组里的某一项
tz_pick(){
  local grp="$1" title="$2" i sel line
  local -a items=()
  while IFS= read -r line; do [ -n "$line" ] && items+=("$line"); done < <(tz_group "$grp")
  [ ${#items[@]} -gt 0 ] || return 1
  while true; do
    echo
    echo -e "  ${M}${title}${N}"
    i=0
    for line in "${items[@]}"; do
      i=$((i + 1))
      printf '  %2d) %-22s %s\n' "$i" "${line%%|*}" "${line#*|}"
    done
    echo "   0) 返回上一级"
    read_tty "  选择 [回车=0]: " sel "0" || return 1
    case "$sel" in 0|"") return 1 ;; esac
    case "$sel" in *[!0-9]*) warn "无效选项: ${sel}"; continue ;; esac
    if [ "$sel" -ge 1 ] && [ "$sel" -le "${#items[@]}" ]; then
      line="${items[$((sel - 1))]}"
      set_timezone "${line%%|*}"
      return 0
    fi
    warn "无效选项: ${sel}"
  done
}

cmd_timezone(){
  need_root
  local tz="${1:-}" cur exit_tz sel

  # 直接指定: proxy timezone Europe/Berlin
  if [ -n "$tz" ] && [ "$tz" != "auto" ]; then
    set_timezone "$tz"
    return $?
  fi

  # 按出口 IP 自动: proxy timezone auto
  if [ "$tz" = "auto" ]; then
    exit_tz=$(detect_exit_tz)
    [ -n "$exit_tz" ] || die "探测失败, 请手动指定: proxy timezone Asia/Tokyo"
    set_timezone "$exit_tz"
    return 0
  fi

  while true; do
    cur=$(cur_timezone)
    exit_tz=$(detect_exit_tz)
    echo
    echo -e "${M}============================================================${N}"
    echo -e "${M}   时区设置${N}"
    echo -e "${M}============================================================${N}"
    echo
    echo -e "  当前时区: ${Y}${cur}${N}"
    echo -e "  本地时间: $(date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
    echo -e "  UTC 时间: $(date -u '+%Y-%m-%d %H:%M:%S')"
    if [ -n "$exit_tz" ]; then
      echo -e "  出口 IP 所在时区: ${G}${exit_tz}${N}"
      [ "$exit_tz" = "$cur" ] && echo -e "  ${D}已一致, 一般不用改${N}"
    fi
    echo
    echo -e "  ${D}原则: 这台机器在哪个区就设哪个区。时区只影响日志和 date 显示,${N}"
    echo -e "  ${D}不影响 TLS/REALITY 握手, 但和 IP 对不上是平台风控的软信号。${N}"
    echo
    if [ -n "$exit_tz" ] && [ "$exit_tz" != "$cur" ]; then
      echo -e "   1) ${G}按出口 IP 自动匹配 → ${exit_tz}${N}   (推荐)"
    else
      echo -e "   1) 按出口 IP 自动匹配          ${D}(当前已一致)${N}"
    fi
    echo "   2) 亚洲 / 大洋洲"
    echo "   3) 欧洲"
    echo "   4) 美洲"
    echo "   5) UTC                         标准时间, 不随夏令时变化"
    echo "   6) 手动输入时区名              ${D}例如 Asia/Tokyo、Europe/Berlin${N}"
    echo "   0) 返回"
    echo
    read_tty "  ${B}请选择${N} [回车=0 返回]: " sel "0" || return 0
    case "$sel" in
      0|"") return 0 ;;
      1)
        if [ -n "$exit_tz" ]; then set_timezone "$exit_tz"
        else warn "没探测到出口时区, 请手动选"; fi ;;
      2) tz_pick asia "亚洲 / 大洋洲" ;;
      3) tz_pick europe "欧洲" ;;
      4) tz_pick america "美洲" ;;
      5) set_timezone "UTC" ;;
      6)
        echo
        echo -e "  ${D}可用时区列表: timedatectl list-timezones | grep -i 关键词${N}"
        read_tty "  输入时区名 [回车=取消]: " tz "" || return 0
        [ -n "$tz" ] && set_timezone "$tz" ;;
      *) warn "无效选项: ${sel}" ;;
    esac
    echo
  done
}

# ---------------- 健康检查 ----------------
install_healthcheck(){
  cat > /usr/local/bin/proxy-healthcheck.sh <<'HEALTH'
#!/usr/bin/env bash
# 由 proxy-installer 安装
# 每 5 分钟查进程/端口; 每 6 次(约 30 分钟)做一次真实隧道探测, 连续失败才重启
set -u
# 探测用的临时配置里有设备 UUID, /run 是所有用户可读的, 必须收紧
umask 077
ST=/etc/proxy-node/state.env
FAIL=/run/proxy-healthcheck.fail
TICK=/run/proxy-healthcheck.tick
[ -f "$ST" ] || exit 0
# shellcheck disable=SC1090
. "$ST"

PROTOCOLS=${PROTOCOLS:-reality,hy2}
on(){
  case ",${PROTOCOLS}," in
    *",$1,"*) return 0 ;;
    *)        return 1 ;;
  esac
}
sb_on(){ on ss2022 || on anytls || on tuic; }

restart_xray(){
  systemctl restart xray >/dev/null 2>&1
  logger -t proxy-healthcheck "xray 异常($1), 已重启"
  echo 0 > "$FAIL" 2>/dev/null || true
}
restart_svc(){
  systemctl restart "$1" >/dev/null 2>&1
  logger -t proxy-healthcheck "$1 异常($2), 已重启"
}
listen_tcp(){ ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"; }
listen_udp(){ ss -uln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"; }

if on reality; then
  systemctl is-active --quiet xray || restart_xray "进程不在"
  listen_tcp "${VLESS_PORT}" || restart_xray "端口未监听"
fi
if on hy2; then
  systemctl is-active --quiet hysteria-server || restart_svc hysteria-server "进程不在"
  listen_udp "${HY2_PORT}" || restart_svc hysteria-server "UDP 端口未监听"
fi
if sb_on; then
  if ! systemctl is-active --quiet sing-box; then
    restart_svc sing-box "进程不在"
  else
    on ss2022 && { listen_tcp "${SS2022_PORT}" || restart_svc sing-box "SS2022 端口未监听"; }
    on anytls && { listen_tcp "${ANYTLS_PORT}" || restart_svc sing-box "AnyTLS 端口未监听"; }
    on tuic   && { listen_udp "${TUIC_PORT}"   || restart_svc sing-box "TUIC 端口未监听"; }
  fi
fi

n=$(cat "$TICK" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$(( n + 1 ))
echo "$n" > "$TICK" 2>/dev/null || true

if on reality && [ $(( n % 6 )) -eq 0 ]; then
  U=$(head -1 /etc/proxy-node/users.txt 2>/dev/null | cut -d'|' -f1)
  U=${U:-${UUID:-}}
  if [ -n "$U" ] && [ -n "${DEST:-}" ]; then
    cat > /run/_hc.json <<JSON
{ "log": { "loglevel": "error" },
  "inbounds": [ { "port": 10896, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ { "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": ${VLESS_PORT},
      "users": [ { "id": "${U}", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "${DEST}", "fingerprint": "chrome",
        "publicKey": "${PUB:-}", "shortId": "${SID:-}", "spiderX": "/" } } } ] }
JSON
    /usr/local/bin/xray -c /run/_hc.json >/dev/null 2>&1 &
    hp=$!
    sleep 3
    code=$(curl -s --socks5-hostname 127.0.0.1:10896 -o /dev/null -w '%{http_code}' --max-time 10 https://www.gstatic.com/generate_204 2>/dev/null)
    kill "$hp" >/dev/null 2>&1
    rm -f /run/_hc.json
    case "$code" in
      2*|3*) echo 0 > "$FAIL" 2>/dev/null || true ;;
      *)
        f=$(cat "$FAIL" 2>/dev/null || echo 0)
        case "$f" in ''|*[!0-9]*) f=0 ;; esac
        f=$(( f + 1 ))
        echo "$f" > "$FAIL" 2>/dev/null || true
        logger -t proxy-healthcheck "隧道探测失败(HTTP ${code:-000}), 连续 ${f} 次"
        [ "$f" -ge 2 ] && restart_xray "隧道连续不可用"
        ;;
    esac
  fi
fi
HEALTH
  chmod 755 /usr/local/bin/proxy-healthcheck.sh

  cat > /etc/systemd/system/proxy-healthcheck.service <<'UNIT'
[Unit]
Description=Proxy health check (one shot)

[Service]
Type=oneshot
# 只需要读状态文件 + 调 systemctl + 跑一次探测, 其余一律关掉
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictNamespaces=true
SystemCallArchitectures=native
UMask=0077
ExecStart=/usr/local/bin/proxy-healthcheck.sh
UNIT

  cat > /etc/systemd/system/proxy-healthcheck.timer <<'UNIT'
[Unit]
Description=Run proxy health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now proxy-healthcheck.timer >/dev/null 2>&1
  if systemctl is-active --quiet proxy-healthcheck.timer; then
    ok "健康检查已启用(每 5 分钟, 异常自动重启)"
  else
    warn "健康检查定时器启动失败, 已跳过"
  fi
}

setup_firewall(){
  local ports="" p
  proto_on reality && ports="${ports} ${VLESS_PORT}/tcp"
  proto_on hy2     && ports="${ports} ${HY2_PORT}/udp"
  proto_on ss2022  && ports="${ports} ${SS2022_PORT}/tcp ${SS2022_PORT}/udp"
  proto_on anytls  && ports="${ports} ${ANYTLS_PORT}/tcp"
  proto_on tuic    && ports="${ports} ${TUIC_PORT}/tcp ${TUIC_PORT}/udp"
  [ -n "$ports" ] || return 0

  local failed=""
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in $ports; do ufw allow "$p" >/dev/null 2>&1 || failed="${failed} ${p}"; done
    if [ -n "$failed" ]; then warn "ufw 放行失败:${failed}"; else ok "ufw 已放行:${ports}"; fi
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in $ports; do firewall-cmd --permanent --add-port="$p" >/dev/null 2>&1 || failed="${failed} ${p}"; done
    firewall-cmd --reload >/dev/null 2>&1
    if [ -n "$failed" ]; then warn "firewalld 放行失败:${failed}"; else ok "firewalld 已放行:${ports}"; fi
  else
    ok "本机防火墙未启用, 请确认云安全组已放行:${ports}"
  fi
}

# 关掉"这次没选"的协议服务。
# 以前 PROTOCOLS 从 reality,hy2 改成 reality 再装一次, hy2 会继续跑: state.env 里
# 已经没有它, 订阅不再列它, proxy status 也不显示 —— 但进程和端口都还在。
# 用户以为关了其实没关, 这比"没装"更糟: 多一个没人看管的对公网端口。
stop_unused_services(){
  local unit stopped="" was
  if ! proto_on reality && [ -f /etc/systemd/system/xray.service ]; then
    was=""
    systemctl is-active --quiet xray 2>/dev/null && was=1
    systemctl is-enabled --quiet xray 2>/dev/null && was=1
    if [ -n "$was" ]; then
      systemctl disable --now xray >/dev/null 2>&1
      stopped="${stopped} xray"
    fi
  fi
  if ! proto_on hy2; then
    for unit in hysteria-server hysteria; do
      [ -f "/etc/systemd/system/${unit}.service" ] || continue
      was=""
      systemctl is-active --quiet "$unit" 2>/dev/null && was=1
      systemctl is-enabled --quiet "$unit" 2>/dev/null && was=1
      if [ -n "$was" ]; then
        systemctl disable --now "$unit" >/dev/null 2>&1
        stopped="${stopped} ${unit}"
      fi
      break
    done
  fi
  if ! sb_enabled && [ -f /etc/systemd/system/sing-box.service ]; then
    was=""
    systemctl is-active --quiet sing-box 2>/dev/null && was=1
    systemctl is-enabled --quiet sing-box 2>/dev/null && was=1
    if [ -n "$was" ]; then
      systemctl disable --now sing-box >/dev/null 2>&1
      stopped="${stopped} sing-box"
    fi
  fi
  [ -n "$stopped" ] && warn "已停用本次未启用的协议服务:${stopped}  (配置与凭据保留, 重新启用用 proxy wizard)"
  return 0
}

# ---------------- 链接生成 ----------------
gen_links(){
  PRIMARY_UUID=$(primary_uuid)
  VLESS_LINK=""; HY2_LINK=""; HY2_LINK_COMPAT=""
  SS_LINK=""; ANYTLS_LINK=""; TUIC_LINK=""

  if proto_on reality; then
    VLESS_LINK="vless://${PRIMARY_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${NODE_NAME}-VLESS"
  fi

  if proto_on hy2; then
    local hb="hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=${DEST}"
    if [ -n "${HY2_HOP:-}" ]; then hb="${hb}&mport=${HY2_HOP}"; fi
    if [ "$ENABLE_OBFS" = "1" ]; then
      hb="${hb}&obfs=salamander&obfs-password=${OBFS_PASS}"
    fi
    if [ -n "${HY2_PIN:-}" ]; then
      # pin 是 64 位小写 hex, 放进 query 无需转义。
      # 同时带 insecure=1: hysteria2 用 insecure 跳过自签证书的 CA 校验,
      # 真正的身份校验由 pinSHA256 完成(与官方 cert 命令给出的示例配置一致)。
      HY2_LINK="${hb}&insecure=1&pinSHA256=${HY2_PIN}#${NODE_NAME}-HY2"
      # v2rayN 7.x 不识别 pinSHA256(二进制中无此字符串), 只认 insecure, 故单独给一条兼容链接
      HY2_LINK_COMPAT="${hb}&insecure=1#${NODE_NAME}-HY2-v2rayN"
    else
      HY2_LINK="${hb}&insecure=1#${NODE_NAME}-HY2"
      HY2_LINK_COMPAT=""
    fi
  fi

  # 以下 AnyTLS / TUIC 两个协议用自签证书, URI 标准里没有证书指纹字段,
  # 只能 insecure; SS2022 没有 TLS, 根本不需要证书固定。三者的分享链接
  # 都别当成"已固定证书", 真固定只在 singbox.json(1.13+)里。
  if sb_enabled; then
    local pu pn ss_ui
    pu="$PRIMARY_UUID"
    pn=$(awk -F'|' -v u="$pu" '$1==u{print $2; exit}' "$USERS_FILE" 2>/dev/null)
    [ -n "$pn" ] || pn="default"

    if proto_on ss2022; then
      # SIP002: base64url(method:password), 去掉 padding
      # 密码是 "服务端密钥:设备密钥", 整段一起 base64, 客户端按第一个冒号切分
      ss_ui=$(printf '2022-blake3-aes-128-gcm:%s' "$(ss_pass_for "$pu")" \
        | openssl base64 -A | tr '+/' '-_' | tr -d '=')
      SS_LINK="ss://${ss_ui}@${SERVER_IP}:${SS2022_PORT}#${NODE_NAME}-SS2022"
    fi
    if proto_on anytls; then
      ANYTLS_LINK="anytls://$(derive_hex "$pu")@${SERVER_IP}:${ANYTLS_PORT}?sni=${DEST}&insecure=1#${NODE_NAME}-AnyTLS"
    fi
    if proto_on tuic; then
      TUIC_LINK="tuic://${pu}:$(derive_hex "$pu")@${SERVER_IP}:${TUIC_PORT}?sni=${DEST}&alpn=h3&congestion_control=bbr&allow_insecure=1#${NODE_NAME}-TUIC"
    fi
  fi
}

# ---------------- 订阅文件 ----------------
# ---------------------------------------------------------------------------
# sing-box 客户端配置
#
# sing-box 的 DNS 与路由格式在 1.12 / 1.13 / 1.14 连着改了三次, 一份配置喂
# 不了所有版本。实测(官方 1.11.0 / 1.12.0 / 1.13.0 / 1.14.4 四个二进制):
#
#   | 配置形态                              | 1.11 | 1.12 | 1.13 | 1.14 |
#   |---------------------------------------|------|------|------|------|
#   | 新 DNS(type+server)+hijack-dns       | 致命 | 通过 | 通过 | 通过 |
#   |   + default_domain_resolver           |      |      |      |      |
#   |   + certificate_public_key_sha256     |      | 致命 | 通过 | 通过 |
#   | 旧 DNS(address)+dns-out              | 致命 | 致命 | 致命 | 致命 |
#   |   (1.14 起彻底移除, 1.12 需开废弃开关) |      |      |      |      |
#
# 所以订阅里给两份:
#   singbox.json         新 DNS + 证书指纹(certificate_public_key_sha256) -> 1.13+
#   singbox-compat.json  新 DNS + insecure                                  -> 1.12 (1.13/1.14 也能用)
# 1.11 及更早不认新 DNS 格式, 改用 clash.yaml (mihomo 内核)。
# ---------------------------------------------------------------------------

# 单个协议的 TLS 段
# $1 = anytls|tuic|hy2   $2 = pinned|compat
sb_tls(){
  local kind="$1" mode="$2" pin="" alpn=""
  case "$kind" in
    # hy2 要跟 hysteria 服务端的 pinSHA256 保持一致: HY2_INSECURE=1 时 HY2_PIN 是空的,
    # 这时客户端配置也退回 insecure, 不能一个走指纹一个不走。
    hy2)    pin="${CERT_SPKI_B64:-}"; [ -n "${HY2_PIN:-}" ] || pin="" ;;
    anytls) pin="${SB_PIN:-}"; alpn='"alpn": ["h2", "http/1.1"], ' ;;
    tuic)   pin="${SB_PIN:-}"; alpn='"alpn": ["h3"], ' ;;
    *)      echo '"tls": { "enabled": true }'; return 0 ;;
  esac
  # pinned 模式且有指纹才用真固定; compat 模式给 1.12 用(它没有这个字段)
  if [ "$mode" = "pinned" ] && [ -n "$pin" ]; then
    echo "\"tls\": { \"enabled\": true, \"server_name\": \"${DEST}\", ${alpn}\"certificate_public_key_sha256\": [\"${pin}\"] }"
  else
    echo "\"tls\": { \"enabled\": true, \"server_name\": \"${DEST}\", ${alpn}\"insecure\": true }"
  fi
}

# 生成 sing-box 客户端配置文件
# $1 = pinned|compat   $2 = 输出路径
write_sb_client(){
  local mode="$1" out="$2"
  local first_tag="" ob=()
  # 单独被调用(proxy selftest)时没有 gen_sub_files 那层校验, 这里自己兜一次,
  # 否则 state.env 被手改坏会写出 "up_mbps": abc 这种非法 JSON。
  local _sb_up="${HY2_BW_UP:-}" _sb_down="${HY2_BW_DOWN:-}" _sb_bad=0 _sbv
  for _sbv in "$_sb_up" "$_sb_down"; do
    [ -n "$_sbv" ] || continue
    hy2_bw_ok "$_sbv" || { _sb_bad=1; break; }
  done
  if [ "$_sb_bad" = "1" ]; then
    warn "HY2_BW_UP/DOWN 非法, 本次 sing-box 订阅按默认 BBR 生成"
    _sb_up=""; _sb_down=""
  fi
  # PRIMARY_UUID 平时是 gen_links 里算好的。这里自己兜一次, 否则单独调用
  # (比如 proxy selftest 只生成一份客户端配置)会撞上 set -u 直接退出。
  local pu="${PRIMARY_UUID:-$(primary_uuid)}"

  local tls_hy2 tls_anytls tls_tuic
  tls_hy2="$(sb_tls hy2 "$mode")"
  tls_anytls="$(sb_tls anytls "$mode")"
  tls_tuic="$(sb_tls tuic "$mode")"

  if proto_on reality; then
    first_tag="vless-out"
    ob+=("$(cat <<JSON
    {
      "type": "vless", "tag": "vless-out",
      "server": "${SERVER_IP}", "server_port": ${VLESS_PORT},
      "uuid": "${pu}", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "${DEST}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "${PUB}", "short_id": "${SID}" }
      }
    }
JSON
)")
  fi

  if proto_on hy2; then
    [ -n "$first_tag" ] || first_tag="hy2-out"
    # 混淆和端口跳跃以前只写进了分享链接和 clash.yaml, 漏了 sing-box —— 开了
    # ENABLE_OBFS=1 之后用 sing-box 客户端导入订阅会直接连不上(服务端要求混淆,
    # 客户端不带)。端口跳跃同理, 客户端不写 server_ports 就用不上。
    local sb_hy2_extra="" sb_hy2_bw=""
    # sing-box 用 up_mbps/down_mbps(整数)开启 Brutal, 语义与 mihomo 的 up/down 一致。
    [ -n "$_sb_up" ]   && sb_hy2_bw="${sb_hy2_bw}\"up_mbps\": ${_sb_up}, "
    [ -n "$_sb_down" ] && sb_hy2_bw="${sb_hy2_bw}\"down_mbps\": ${_sb_down}, "
    if [ "$ENABLE_OBFS" = "1" ] && [ -n "${OBFS_PASS:-}" ]; then
      sb_hy2_extra="\"obfs\": { \"type\": \"salamander\", \"password\": \"${OBFS_PASS}\" },"
    fi
    if [ -n "${HY2_HOP:-}" ]; then
      # 配置里是 20000-30000, sing-box 要 20000:30000
      sb_hy2_extra="${sb_hy2_extra}\"server_ports\": [ \"${HY2_HOP/-/:}\" ],"
    fi
    ob+=("$(cat <<JSON
    {
      "type": "hysteria2", "tag": "hy2-out",
      "server": "${SERVER_IP}", "server_port": ${HY2_PORT},
      "password": "${HY2_PASS}",
      ${sb_hy2_bw}
      ${sb_hy2_extra}
      ${tls_hy2}
    }
JSON
)")
  fi

  if proto_on ss2022; then
    [ -n "$first_tag" ] || first_tag="ss2022-out"
    ob+=("$(cat <<JSON
    {
      "type": "shadowsocks", "tag": "ss2022-out",
      "server": "${SERVER_IP}", "server_port": ${SS2022_PORT},
      "method": "2022-blake3-aes-128-gcm",
      "password": "$(ss_pass_for "$pu")"
    }
JSON
)")
  fi

  if proto_on anytls; then
    [ -n "$first_tag" ] || first_tag="anytls-out"
    ob+=("$(cat <<JSON
    {
      "type": "anytls", "tag": "anytls-out",
      "server": "${SERVER_IP}", "server_port": ${ANYTLS_PORT},
      "password": "$(derive_hex "$pu")",
      ${tls_anytls}
    }
JSON
)")
  fi

  if proto_on tuic; then
    [ -n "$first_tag" ] || first_tag="tuic-out"
    ob+=("$(cat <<JSON
    {
      "type": "tuic", "tag": "tuic-out",
      "server": "${SERVER_IP}", "server_port": ${TUIC_PORT},
      "uuid": "${pu}", "password": "$(derive_hex "$pu")",
      "congestion_control": "bbr",
      ${tls_tuic}
    }
JSON
)")
  fi

  [ ${#ob[@]} -gt 0 ] || die "没有任何可用协议, 检查 PROTOCOLS"

  {
    echo "{"
    echo '  "log": { "level": "info" },'
    # DNS 必须自己接管。不配的话 sing-box 走系统 DNS, 在国内就是运营商 DNS:
    # 客户端在本地解析出 IP 再发给服务端, 服务端只能连那个 IP,
    # Google 反查到的就是你的本地解析结果, 直接判成中国区。
    # remote 走代理出去(境外解析), local 走直连(国内解析, 只用于 .lan/.local 这类)。
    # 两个 server 都写 IP: 用域名会跟 default_domain_resolver 形成循环解析。
    echo '  "dns": {'
    echo '    "servers": ['
    printf '      { "type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "%s" },\n' "$first_tag"
    # local 用 UDP 明文 DNS 直连国内, 只负责 .lan/.local/.arpa 这类本地域名。
    # detour 必须指向一个"非空"的 direct 出站: 空 direct 会被 sing-box 拒绝启动
    # (detour to an empty direct outbound makes no sense)。
    echo '      { "type": "udp", "tag": "local", "server": "223.5.5.5", "detour": "direct" }'
    echo '    ],'
    echo '    "rules": ['
    # 这里必须用裸 server, 不能加 "action": "route" —— 加了反而规则不生效,
    # .local 会落到 final(remote) 走代理解析。
    echo '      { "domain_suffix": [".lan", ".local", ".arpa"], "server": "local" }'
    echo '    ],'
    echo '    "final": "remote",'
    echo '    "strategy": "ipv4_only"'
    echo '  },'
    echo '  "inbounds": ['
    echo '    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080 }'
    echo '  ],'
    # 默认出口与 clash.yaml 的 select 第一项保持一致; 默认仍是 vless-out(TCP)。
    if [ "$(effective_default_node)" = "hy2" ]; then
      first_tag="hy2-out"
    fi
    printf '  "outbounds": [\n%s,\n    { "type": "direct", "tag": "direct", "network_strategy": "default" }\n  ],\n' \
      "$(printf '%s,\n' "${ob[@]}" | sed '$ s/,$//')"
    # 劫持 DNS 只能用 "port": 53, 不能用 "protocol": "dns" —— 后者在 sing-box 1.12+
    # 匹配不到 UDP/53, 流量会直接走 final 出站(等于没接管, 仍会本地解析泄漏)。
    printf '  "route": {\n    "rules": [\n      { "port": 53, "action": "hijack-dns" }\n    ],\n    "final": "%s",\n    "auto_detect_interface": true,\n    "default_domain_resolver": "local"\n  }\n' "$first_tag"
    echo "}"
  } > "$out"
}

# ---------------- 客户端订阅的统一校验 ----------------
# 不用算术比较(如 [ "$v" -gt 某个上限 ]): 超大整数会让 test 返回 2(报错)而不是 0/1,
# 这个返回值在 if 里被当成"假", 反而把非法值放过去写进 JSON/YAML。
# 只允许 1..10000, 用长度 + 字符串判断, 不受算术溢出影响。
hy2_bw_ok(){
  local v="$1"
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || return 1
  [ "${#v}" -le 4 ] && return 0
  [ "$v" = "10000" ] && return 0
  return 1
}

# 客户端默认选中的节点。DEFAULT_NODE=hy2 且确实启用了 hy2 才切 UDP;
# 其余一律 reality(抗封锁优先)。非法值只警告, 绝不改变行为。
effective_default_node(){
  case "${DEFAULT_NODE:-reality}" in
    hy2|hysteria2)
      if proto_on hy2; then echo hy2; else
        warn "DEFAULT_NODE=hy2 但本次未启用 hysteria2, 仍用 reality"
        echo reality
      fi ;;
    reality|vless|"") echo reality ;;
    *) warn "DEFAULT_NODE='${DEFAULT_NODE}' 不认识(可选 reality / hy2), 按 reality 处理"
       echo reality ;;
  esac
  return 0
}

gen_sub_files(){
  PRIMARY_UUID="${PRIMARY_UUID:-$(primary_uuid)}"
  # Brutal 带宽填错比不填更糟: 官方明确说填高了会因丢包补偿导致"连接速度慢、
  # 不稳定且浪费流量"。这里只清洗**本次生成用的局部值**, 不动全局变量 ——
  # 之前一出错就把全局清空, 紧接着的 save_state 会把用户已保存的设置抹掉。
  # 局部值同时供本函数内的 clash.yaml 与被调用的 write_sb_client 使用。
  local _bw_up="${HY2_BW_UP:-}" _bw_down="${HY2_BW_DOWN:-}" _bw_bad=0 _bv
  for _bv in "$_bw_up" "$_bw_down"; do
    [ -n "$_bv" ] || continue
    hy2_bw_ok "$_bv" || { _bw_bad=1; break; }
  done
  if [ "$_bw_bad" = "1" ]; then
    warn "HY2_BW_UP/DOWN 必须是 1-10000 的整数(Mbps), 本次按默认 BBR 生成(已保存的设置不变)"
    _bw_up=""; _bw_down=""
  elif { [ -n "$_bw_up" ] && [ -z "$_bw_down" ]; } || { [ -z "$_bw_up" ] && [ -n "$_bw_down" ]; }; then
    # Brutal 是按"客户端实际链路带宽"做补偿的, 两边都要有值才有意义:
    # 只填一个时 sing-quic 拿不到发送速率, 会静默退回 BBR —— 用户以为开了其实没开。
    warn "Brutal 建议 up 与 down 一起填(现在只填了一个), 否则部分客户端会静默退回 BBR"
  fi
  local _dn
  _dn=$(effective_default_node)
  mkdir -p "$SUB_DIR"
  # 父目录只放 index.html 和 token 目录, 但目录名就是 token —— 没开 HTTP 服务时
  # 也没必要让同机用户 ls 出 token, 跟着 SUB_HTTP 一起收紧。
  if [ "${SUB_HTTP:-0}" = "1" ]; then chmod 755 "$SUB_DIR"; else chmod 700 "$SUB_DIR"; fi
  # 放一个 index.html 遮住目录列表, 否则访问根路径会把 token 目录名列出来
  if [ ! -f "$SUB_DIR/index.html" ]; then
    cat > "$SUB_DIR/index.html" <<'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>404</title></head>
<body><h1>Not Found</h1><p>The requested URL was not found on this server.</p></body></html>
HTML
    chmod 644 "$SUB_DIR/index.html"
  fi
  # token 为空会让订阅目录变成 $SUB_DIR 本身, 而 HTTP 服务只认两段路径 ——
  # 表现是订阅一直 404, 而且很难看出原因。openssl 挂了就用内核熵源兜底。
  if [ -z "${SUB_TOKEN:-}" ]; then
    SUB_TOKEN=$(openssl rand -hex 16 2>/dev/null)
    [ -n "$SUB_TOKEN" ] || SUB_TOKEN=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ -n "$SUB_TOKEN" ] || die "无法生成订阅 token (openssl 与 /dev/urandom 都不可用)"
  fi
  local tdir="${SUB_DIR}/${SUB_TOKEN}"
  mkdir -p "$tdir"; chmod 755 "$tdir"

  local links=()
  proto_on reality && links+=("$VLESS_LINK")
  proto_on hy2     && links+=("$HY2_LINK")
  proto_on ss2022  && links+=("$SS_LINK")
  proto_on anytls  && links+=("$ANYTLS_LINK")
  proto_on tuic    && links+=("$TUIC_LINK")
  [ ${#links[@]} -gt 0 ] || die "没有任何可用协议, 检查 PROTOCOLS"
  printf '%s\n' "${links[@]}" > "$tdir/links.txt"

  { printf '%s\n' "${links[@]}" | base64 -w0; echo ""; } > "$tdir/base64.txt"

  {
    echo "mixed-port: 7890"
    echo "allow-lan: false"
    echo "mode: rule"
    echo "log-level: info"
    # 关掉 IPv6: 客户端有公网 v6 时, 部分应用会绕过代理直连 AAAA 记录,
    # Google 一旦看到真实的中国 v6 出口就会把会话判成中国区(即"送中")
    echo "ipv6: false"
    # DNS 必须自己接管。不写这段的话 Clash 会用系统 DNS(国内运营商/114),
    # 在 TUN 模式下先本地解析再把 IP 发给服务端 —— 服务端只能看到 IP,
    # Google 反向查到的就是你本地的解析结果, 于是判定成中国用户。
    # fake-ip 让所有域名拿到 198.18.x.x 的假地址, 真域名原样透传给服务端解析。
    echo "dns:"
    echo "  enable: true"
    echo "  ipv6: false"
    echo "  enhanced-mode: fake-ip"
    echo "  fake-ip-range: 198.18.0.1/16"
    echo "  fake-ip-filter:"
    echo '    - "+.lan"'
    echo '    - "+.local"'
    echo '    - "+.arpa"'
    echo '    - "+.msftconnecttest.com"'
    echo '    - "+.msftncsi.com"'
    echo '    - "localhost.ptlogin2.qq.com"'
    # fake-ip-filter 里的域名(局域网/系统探测)才需要真解析, 用国内 DoH 最快最稳。
    # 其余域名不在这里解析, 由服务端解析, 所以这里不需要填 8.8.8.8。
    echo "  default-nameserver:"
    echo "    - 223.5.5.5"
    echo "    - 119.29.29.29"
    echo "  nameserver:"
    echo "    - https://dns.alidns.com/dns-query"
    echo "    - https://doh.pub/dns-query"
    echo "  proxy-server-nameserver:"
    echo "    - https://dns.alidns.com/dns-query"
    echo "proxies:"
    if proto_on reality; then
      echo "  - name: \"${NODE_NAME}-VLESS\""
      echo "    type: vless"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${VLESS_PORT}"
      echo "    uuid: ${PRIMARY_UUID}"
      echo "    network: tcp"
      echo "    udp: true"
      echo "    tls: true"
      echo "    flow: xtls-rprx-vision"
      echo "    servername: ${DEST}"
      echo "    client-fingerprint: chrome"
      echo "    reality-opts:"
      echo "      public-key: ${PUB}"
      echo "      short-id: ${SID}"
    fi
    if proto_on hy2; then
      echo "  - name: \"${NODE_NAME}-HY2\""
      echo "    type: hysteria2"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${HY2_PORT}"
      echo "    password: \"${HY2_PASS}\""
      echo "    sni: ${DEST}"
      # mihomo 的 up/down 是客户端的上传/下载带宽, 填了才启用 Brutal 拥塞控制。
      # 只写进订阅文件: hysteria2:// 分享链接标准里没有这两个参数。
      [ -n "$_bw_up" ]   && echo "    up: \"${_bw_up} Mbps\""
      [ -n "$_bw_down" ] && echo "    down: \"${_bw_down} Mbps\""
      if [ -n "${HY2_PIN:-}" ] && [ -n "${CERT_HEX:-}" ]; then
        echo "    skip-cert-verify: false"
        echo "    fingerprint: ${CERT_HEX}"
      else
        echo "    skip-cert-verify: true"
      fi
      [ -n "${HY2_HOP:-}" ] && echo "    ports: \"${HY2_HOP}\""
      if [ "$ENABLE_OBFS" = "1" ]; then
        echo "    obfs: salamander"
        echo "    obfs-password: \"${OBFS_PASS}\""
      fi
    fi
    if proto_on ss2022; then
      echo "  - name: \"${NODE_NAME}-SS2022\""
      echo "    type: ss"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${SS2022_PORT}"
      echo "    cipher: 2022-blake3-aes-128-gcm"
      echo "    password: \"$(ss_pass_for "$PRIMARY_UUID")\""
      echo "    udp: true"
    fi
    if proto_on anytls; then
      echo "  - name: \"${NODE_NAME}-AnyTLS\""
      echo "    type: anytls"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${ANYTLS_PORT}"
      echo "    password: \"$(derive_hex "$PRIMARY_UUID")\""
      echo "    sni: ${DEST}"
      # mihomo 的 anytls 默认 udp=false, 不写这条该节点不承载 UDP:
      # QUIC / HTTP3 / 语音会静默回落, 表现成"这条线某些应用特别慢"。
      echo "    udp: true"
      echo "    skip-cert-verify: true"
    fi
    if proto_on tuic; then
      echo "  - name: \"${NODE_NAME}-TUIC\""
      echo "    type: tuic"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${TUIC_PORT}"
      echo "    uuid: ${PRIMARY_UUID}"
      echo "    password: \"$(derive_hex "$PRIMARY_UUID")\""
      echo "    sni: ${DEST}"
      echo "    alpn: [h3]"
      echo "    congestion-controller: bbr"
      echo "    skip-cert-verify: true"
    fi
    echo "proxy-groups:"
    echo "  - name: PROXY"
    echo "    type: select"
    echo "    proxies:"
    # select 的第一项就是客户端默认选中的节点。DEFAULT_NODE=hy2 时把 UDP
    # 节点排到最前(速度优先), 其余协议与顺序完全不变。
    if [ "$_dn" = "hy2" ]; then
      echo "      - \"${NODE_NAME}-HY2\""
    fi
    proto_on reality && echo "      - \"${NODE_NAME}-VLESS\""
    if proto_on hy2 && [ "$_dn" != "hy2" ]; then
      echo "      - \"${NODE_NAME}-HY2\""
    fi
    proto_on ss2022  && echo "      - \"${NODE_NAME}-SS2022\""
    proto_on anytls  && echo "      - \"${NODE_NAME}-AnyTLS\""
    proto_on tuic    && echo "      - \"${NODE_NAME}-TUIC\""
    echo "rules:"
    # 国内直连必须写进订阅里。只写 MATCH,PROXY 的话, 淘宝/B站/微信也会
    # 绕一圈出国再回来 —— 慢是小事, 很多国内服务直接拒绝境外 IP, 表现为
    # "开了代理国内网站打不开"。
    #
    # 局域网地址先放行: allow-lan 关了只影响别人连你, 不影响你访问 NAS / 打印机,
    # 后者要是不放行会一起被塞进代理, 表现为本地设备连不上。
    # 这里用 IP-CIDR 而不是 GEOIP,LAN —— 后者不是所有 Clash 内核都认,
    # 一条不认的规则会让整份订阅加载失败, 代价太大。
    echo "  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"
    echo "  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"
    echo "  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve"
    echo "  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"
    # GEOSITE,cn 是纯域名规则, 匹配阶段不解析域名 —— 所以 fake-ip 语义不受
    # 影响: 国内域名命中后直连, 由 nameserver(国内 DoH) 正常解析出国内 IP。
    # GEOIP,CN 后面加 no-resolve: 只处理"连接目标本身就是 IP"的情况,
    # 不去主动解析域名, 避免把 fake-ip 打穿。
    echo "  - GEOSITE,cn,DIRECT"
    echo "  - GEOIP,CN,DIRECT,no-resolve"
    echo "  - MATCH,PROXY"
  } > "$tdir/clash.yaml"

  # sing-box 客户端配置: 两份, 适配不同内核版本(见 write_sb_client 上方说明)
  write_sb_client pinned "$tdir/singbox.json"
  write_sb_client compat "$tdir/singbox-compat.json"

  # v2rayN 兼容订阅: 这三条链接带 insecure / allow_insecure, 新版 v2rayN 会持续
  # 提示"不安全", 且拿不到证书校验。保留只为兼容老客户端, 新装请用下面的 safe 版。
  {
    # Hysteria2: 直接复用 gen_links 拼好的链接。手拼版本漏过 obfs 与 mport ——
    # 开了 salamander 混淆或端口跳跃时, v2rayN 导入后 QUIC 握手被服务端直接丢弃,
    # 表现成"节点在但连不上", 极难排查。v2rayN 不认 pinSHA256, 所以优先用兼容链接。
    proto_on hy2 && printf '%s\n' "${HY2_LINK_COMPAT:-${HY2_LINK}}"
    proto_on anytls && {
      # AnyTLS: v2rayN 不支持指纹参数，只能 insecure=1
      printf 'anytls://%s@%s:%s?sni=%s&insecure=1#%s-AnyTLS\n' \
        "$(derive_hex "$PRIMARY_UUID")" "$SERVER_IP" "$ANYTLS_PORT" "$DEST" "$NODE_NAME"
    }
    proto_on tuic && {
      # TUIC v5: v2rayN 不支持指纹参数，只能用 allow_insecure=1
      printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&allow_insecure=1#%s-TUIC\n' \
        "$PRIMARY_UUID" "$(derive_hex "$PRIMARY_UUID")" "$SERVER_IP" "$TUIC_PORT" "$DEST" "$NODE_NAME"
    }
    # REALITY/SS2022 不需要指纹(REALITY 用短ID+公钥, SS2022 用密钥派生)
    proto_on reality && printf '%s\n' "$VLESS_LINK"
    proto_on ss2022  && printf '%s\n' "$SS_LINK"
  } > "$tdir/v2rayn.txt"

  # 新版 v2rayN(Xray-core v26.2.6 起移除 TLS allowInsecure)对带 insecure 的节点
  # 会持续提示"不安全"; 用户若在设置里勾了"默认跳过证书验证", 新导入的配置还会全挂。
  # 这份订阅只给不含 TLS 跳过验证的节点: REALITY 靠 pbk/sid 验身份、SS2022 没有 TLS,
  # 两者都不受该变更影响, 导入后干净可用。
  # 两个都没开时不生成空文件 —— 空的订阅会让客户端报错。
  local safe_links=""
  proto_on reality && safe_links="${safe_links}${VLESS_LINK}"$'\n'
  proto_on ss2022  && safe_links="${safe_links}${SS_LINK}"$'\n'
  # tdir 是持久订阅目录(不是临时目录), 条件生成前先删旧文件: 否则关掉
  # reality/ss2022 后重新 sub, 旧的 safe 订阅会残留, 客户端还在导入一条
  # 服务端已经不再提供的 REALITY 链接。
  rm -f "$tdir/v2rayn-safe.txt"
  [ -n "$safe_links" ] && printf '%s' "$safe_links" > "$tdir/v2rayn-safe.txt"

  local gsum=""
  proto_on reality && gsum="${gsum}   VLESS/TCP ${VLESS_PORT}"
  proto_on hy2     && gsum="${gsum}   Hysteria2/UDP ${HY2_PORT}"
  proto_on ss2022  && gsum="${gsum}   SS2022/TCP+UDP ${SS2022_PORT}"
  proto_on anytls  && gsum="${gsum}   AnyTLS/TCP ${ANYTLS_PORT}"
  proto_on tuic    && gsum="${gsum}   TUIC/TCP+UDP ${TUIC_PORT}"

  cat > "$tdir/client-guide.md" <<GUIDE
# 客户端配置指南

节点: ${SERVER_IP}${gsum}
伪装域名: ${DEST}

## 一、Hysteria2 是自签证书, 靠指纹固定验证身份

服务端没有公共 CA 证书。正确做法是 **跳过 CA 校验 + 固定指纹** 两件事一起做:
跳过 CA 让连接能建立, 固定指纹才保证对端真的是这台服务器 —— 指纹只能来自
这台服务器, 链路上换不了, 安全性等同于正式证书。

这不是折中, 而是 hysteria2 官方 \`hysteria cert\` 命令给出的标准配置:
\`insecure: true\` 与 \`pinSHA256\` 同时出现。

| 客户端 | 怎么填 |
|---|---|
| hysteria2 官方客户端 | tls 下同时写 \`insecure: true\` 和 \`pinSHA256: <证书 SHA-256 hex>\` |
| 小火箭 / Stash | 用下面带 pinSHA256 的链接(链接里已含 insecure=1) |
| sing-box | tls.certificate_public_key_sha256 填 SPKI 那行(这是另一个字段, 用 base64) |
| mihomo / Clash Verge | skip-cert-verify: false + fingerprint 填 hex 那行 |
| v2rayN 7.x | **不识别 pinSHA256**, 只能用下面的兼容链接 |
| v2rayN | **导入 \`v2rayn-safe.txt\`**：只有 REALITY / SS2022，不含跳过证书验证，新版不弹提示（只开 hy2/anytls/tuic 时没有这个文件） |

v2rayN 的 Hysteria2 界面只有"跳过证书验证"一个勾选框, 没有指纹字段,
URI 里的 \`pinSHA256\` 它也不识别。**分享链接标准里的 \`fp\`(如 \`fp=chrome\`)
是 uTLS 浏览器指纹, 不是证书指纹** —— 这两个别混了。

Xray-core v26.2.6 起移除了 TLS 的 \`allowInsecure\`, 改用 \`pinnedPeerCertSha256\`。
REALITY 节点不受影响(靠 pbk/sid 验身份); 带 \`insecure=1\` 的 HY2 / AnyTLS / TUIC
在 v2rayN 里由 sing-box 内核承载, 不会导致内核启动失败, 只是会持续弹"不安全"提示,
且这三条线路本来就没有证书校验。

**推荐**: 导入 \`v2rayn-safe.txt\`(干净、无提示), 或改用 \`singbox.json\`
(1.13+ 的 \`certificate_public_key_sha256\` 真固定)。注意 \`clash.yaml\` 只有
Hysteria2 一条带 \`fingerprint\`, AnyTLS / TUIC 仍是 \`skip-cert-verify: true\`,
不能把整份 clash 订阅当成"已固定证书"。若坚持用 \`v2rayn.txt\`, 遇到下列情况照着处理:
  - 弹"不安全"提示: 正常, 忽略; **别**去设置里勾"默认跳过证书验证", 那会让新导入配置全挂
  - 报 "allowInsecure has been removed": 说明该节点被 Xray 内核接管了, 删掉它改用 safe 订阅
  - 批量真连接全是 -1: 删掉含 insecure 的节点再测, 别让一条坏节点拖垮整批

Hysteria2 链接(带 pinSHA256, 小火箭 / Stash / 官方客户端用):

${HY2_LINK:-当前未生成}

v2rayN 兼容链接(它不识别 pinSHA256, 这条没有身份验证):

${HY2_LINK_COMPAT:-${HY2_LINK:-当前未生成}}

指纹 pinSHA256 (整证书 SHA-256, 64 位 hex, 上面第一条链接里已带):
${HY2_PIN:-未启用, 当前为 insecure}

指纹 SPKI (sing-box certificate_public_key_sha256, base64) —— 项目里有两张
自签证书, 别填错:
  Hysteria2 用这张:  ${CERT_SPKI_B64:-未计算}
  AnyTLS / TUIC 用:  ${SB_PIN:-未计算}

## 二、TUN 模式必看的四个设置

TUN 出问题基本都在这四项里, 按顺序核对:

1. MTU 填 1500
   sing-box 默认 9000, 而家宽/Wi-Fi 实际 MTU 只有 1500 或 1492。
   9000 会让大包被丢弃, 典型症状是"显示已连接, 但网页打不开"。

2. 关闭"严格路由"(strict_route)
   开着时出站一旦不通, 全部流量被黑洞, DNS 也一起被劫持进 TUN,
   表现为整台机器断网, 而不只是代理不通。

3. 用管理员权限运行
   TUN 需要创建虚拟网卡, 没权限会静默失败; 而客户端此时已经把系统代理关了,
   于是变成"TUN 没起来 + 系统代理也没了"的双重断网。

4. DNS 用订阅里配好的那份, 别在客户端里另配
   订阅文件已经设好 fake-ip + 国内 DoH 引导。若客户端里另配 DNS,
   常见错误是"所有域名都走 cloudflare-dns.com 并经代理出去":
   节点一抖 DNS 全超时, 表现同样是全断。原理见第五节。

## 三、卡住时怎么定位

TUN 开着的情况下依次执行(Windows):

    ping 1.1.1.1             通 -> 路由正常, 问题在 DNS; 不通 -> 网卡或路由没起来
    ipconfig /all            看是否多出一块 TUN 网卡、是否拿到 IP
    route print              看默认路由 0.0.0.0 指向哪块网卡
    nslookup www.baidu.com   看 DNS 是否可用

## 四、Windows: v2rayN 要核对的七项

v2rayN 各版本界面差异比小火箭大, 下面按"功能"写, 标签名可能略有不同。
菜单基本都在顶部「设置」里。

**① 订阅用 \`v2rayn-safe.txt\`，别用 \`base64.txt\`**

\`v2rayn-safe.txt\` 只含 REALITY / SS2022, 不含任何"跳过证书验证",
新版 v2rayN 导入后不会弹"不安全"提示, 也不会踩 Xray 移除 allowInsecure 的坑。
(只开 hy2 / anytls / tuic 时这个文件不会生成, 那种组合只能用下面的 singbox.json。)
想用 Hysteria2 / AnyTLS / TUIC **且**要证书校验, 请导入 \`singbox.json\`(1.13+);
\`clash.yaml\` 只有 Hysteria2 带 \`fingerprint\`, 另外两条是 \`skip-cert-verify: true\`;
\`base64.txt\` 是全部节点, 其中 hy2 / anytls / tuic 三条是兼容链接, 能连但**没有**证书校验。

**② TUN 模式: MTU 填 1500, 关掉"严格路由"**

默认 MTU 是 sing-box 的 9000, 家宽/Wi-Fi 实际只有 1500 或 1492, 大包会被丢弃,
典型症状是"显示已连接但网页打不开"。严格路由开着时出站一断就整机断网,
DNS 也会被一起劫持进 TUN。

**③ bin\\sing_box\\wintun.dll 必须存在**

v2rayN 的 TUN 由 sing-box 内核实现, 缺这个文件虚拟网卡根本创建不出来。
若没有, 把 bin\\xray\\wintun.dll 复制过去即可。TUN 还要以管理员身份运行。

**④ DNS 设置: 远程 DNS 用境外 DoH**

设置 → DNS 设置 → DNS 基础设置:

    直连 DNS   : 223.5.5.5 或 119.29.29.29   国内域名走直连, 用国内的最快
    远程 DNS   : https://1.1.1.1/dns-query   走代理的域名, 必须是境外
    Bootstrap  : 223.5.5.5                   只用来解析上面那个域名, 必须填 IP

远程 DNS 写成 IP 形式(\`https://1.1.1.1/dns-query\`)可以绕开 Bootstrap,
链路少一环; 写成域名形式(\`https://cloudflare-dns.com/dns-query\`)也能用,
Bootstrap 被污染时 TLS 证书校验会拦住, 不会真的被中间人。

**代理目标解析策略保持 Default —— 这项最关键**

界面上写得很清楚: "当未选择或 AsIs 时, 由远程服务器端 DNS 解析"。
Default 就是我们要的: 域名原样发到服务端再解析。

一旦改成 \`UseIP\` / \`UseIPv4\`, 就变成客户端本地解析 —— 域名先被解析成
国内 CDN 的 IP 再发出去, **这就是送中**。

直连目标解析策略同样保持 Default, 直连域名交给系统 DNS 最快。

另外三个标签页(DNS 进阶设置 / v2ray 自定义 DNS / sing-box 自定义 DNS)
保持默认, 不要在里面再配一套 —— 会覆盖上面的基础设置, 症状是"改了没生效"。

**⑤ 路由设置里的域名解析策略: 选 IPIfNonMatch, 不要选 AsIs**

设置 → 路由设置 → 域名解析策略。

这一项和上一条(④)不是同一件事, 别混:

    IPIfNonMatch   -> 前面的域名规则都没命中时, 才在本地解析一次跑 geoip 分流。选这个。
    AsIs           -> 完全不解析。基于 IP 的分流规则(geoip:cn)会全部失效。
    IPOnDemand     -> 每次连接都解析, 没必要, 还慢。

早期版本这里写的是 AsIs, 那是错的。它的前提是"全部流量都走代理", 而你
要同时访问国内网站和 App 时, AsIs 会让 geoip 分流失效 —— 淘宝 / B站 / 微信
也跟着绕出国再回来, 表现就是"开了代理, 国内网站打不开"。

会不会因为本地解析而送中? 不会。域名被本地解析成 IP 发到服务端之后,
服务端 inbound 的 sniffing 会从 TLS SNI 里把域名捞回来, 再用服务端 DNS
重新解析一次(见 write_xray_config 的 destOverride 与 routeOnly: false)。
多这一层兜底, 本地解析不会把地区带偏。

**⑥ 路由模式用"绕过大陆", 不要用"全局"**

设置 → 路由设置 → 路由。选全局的话国内站点一样走代理, 和上一条是同一类问题:
国外能上、国内打不开。脚本生成的 clash.yaml 自带分流规则
(局域网 + GEOSITE,cn + GEOIP,CN 直连, 其余走代理), 用订阅的话不用再手动配。

**⑦ 系统代理: TUN 模式下选"不改变系统代理"**

TUN 已经接管全部流量, 再叠加一层系统代理属于重复代理。虽然通常不会坏,
但会让排障变复杂, 而且部分应用会因此走错路径。

## 五、送中与判机房是两件事, 一件能修一件不能

### 送中: 多数是 DNS 泄漏, 订阅里已经修好

Google 判断你在哪个国家, 看的是**它看到你从哪个 IP 来**。如果客户端先在本地
把 google.com 解析成国内 CDN 的地址, 再把那个 IP 发给服务端, 服务端就只能连
那个 IP, Google 看到的对端就成了国内节点, 于是把你判成中国用户。

订阅文件里已经配好两件事:

- \`dns.enhanced-mode: fake-ip\`(Clash) / \`dns.final: remote\`(sing-box)
  所有域名先拿到一个 198.18.x.x 的假地址, **真域名原样送到服务端再解析**
- \`ipv6: false\`
  客户端有公网 v6 时, 部分应用会绕过代理直连 AAAA 记录, 真实位置就漏出去了

你要做的是别在客户端里把这两项改回去。手动导入链接(不用订阅)时,
务必自己打开 fake-ip、关掉 IPv6。

**Clash 必须用 mihomo 内核**(Clash Verge Rev / Clash Meta / FlClash 都是)。
老版 Clash(原版 openclash 之前的 Clash for Windows)不支持 \`enhanced-mode: fake-ip\`,
导入 clash.yaml 后 DNS 会静默回退到系统 DNS —— 症状就是"节点能用, 但 Google
还是判中国"。这时换内核, 不要去改别的地方。

### 小火箭(Shadowrocket): 七项设置要手动核对

\`base64.txt\` 是纯节点列表, 不带任何 DNS 配置。小火箭自己**有** fake-ip
(返回 198.18.0.2 假地址), 所以不需要额外的 fake-ip 配置; 但下面这七项
默认值不一定对, 逐项核对一遍。前六项在底部 **配置** 标签里, 第七项在首页。

**① 配置 → 通用 → DNS 覆写: 留空, 或填国内 DNS**

这一项和 v2rayN 完全不同, 别照搬 v2rayN 的配法。

v2rayN 有"直连 DNS / 远程 DNS"两个入口, 能按规则分开走。小火箭只有
**一个** DNS 覆写, 而且它是**全局生效**的: 不管域名是国内还是国外,
都拿它去解析。

填境外 DNS(1.1.1.1 / 8.8.8.8)会出事: 你的规则里只要有 \`GEOIP,CN,DIRECT\`,
小火箭就必须先解析域名才知道是不是国内 —— 用 1.1.1.1 解析 taobao.com,
拿到的是境外 CDN 的 IP, 判定"不是 CN", 于是国内流量也进了代理。
症状就是"国外正常, 淘宝 / B站 / 微信 / 国内 App 打不开"。

正确填法:

\`\`\`
DNS 覆写: 留空(用系统 DNS)   或   223.5.5.5
备用 DNS: 留空
\`\`\`

**防送中不靠这一项。** 小火箭自带 fake-ip(返回 198.18.0.2), 走代理的域名
本来就不会被真正解析, 域名原样发到服务端; 就算被解析了, 服务端 inbound
的 sniffing 也会从 TLS SNI 里把域名捞回来重新解析。两头都有兜底。

真正要防的是"某些 App 绕过 fake-ip 自己用系统 DNS 解析 google.com" ——
那种情况改小火箭的 DNS 覆写也拦不住(它压根不经过小火箭的 DNS), 要靠
关掉 App 自带的 DoH, 见下面"客户端自己带 DoH 的必须关掉"。

**② 配置 → 通用 → 启用 IPv6** → 关

手机拿到公网 v6 后, 部分 App 会绕过代理直连 AAAA 记录, 真实位置就漏了。
\`首选 IPv6\` 关掉不够, \`启用 IPv6\` 本身也要关。

**③ 配置 → UDP → 禁用 STUN** → 开

打开这个等于关掉 WebRTC 泄漏, 比在桌面浏览器里改注册表省事。不开的话,
浏览器 WebRTC 可能绕过代理暴露真实 IP。

**④ 配置 → UDP → 启用转发** → 必须开

hysteria2 / TUIC 全部走 UDP, 这项关了这两个协议直接不通。默认是开的, 别关。

**⑤ 配置 → TCP → 指纹** → 保持默认

iOS 上默认是 \`Safari26_x\`, 这**比 chrome 更自然** —— iOS 设备本来就该发出
Safari 的 ClientHello, 改成 chrome 反而违和。REALITY 服务端不校验指纹具体值,
只要 ClientHello 能原样转发就行。别动它。

**⑥ 私有 IP 应答** → 保持开

关掉会让内网域名(路由器后台、NAS)强制走代理, 反而访问不了。

**⑦ 全局路由: 选"配置", 不要选"代理"**

首页 → 全局路由。三个选项里:
    配置  -> 按规则分流, 国内直连、国外走代理。选这个。
    代理  -> 全部走代理, 国内网站也会绕出国再回来, 表现为"开了代理国内打不开"。
    直连  -> 等于没开代理。

注意: 如果你确认自己一直用的是"配置"、国内网站还是打不开, 那问题不在这一项,
在 ①(DNS 覆写填了境外 DNS, 导致 GEOIP 把国内域名判成国外)。两项要分开查:
    DNS 覆写留空 + 全局路由选"配置"   -> 国内直连, 国外走代理

如果哪天在界面里找不到这些项, 也可以直接编辑配置文件, 在 [General] 段写:

\`\`\`
[General]
dns-server = 223.5.5.5
ipv6 = false
prefer-ipv6 = false
\`\`\`

\`dns-server\` 这一行干脆不写也行(用系统 DNS)。写境外 DNS 会破坏 GEOIP 分流,
原因见 ①。

### sing-box 用哪个文件

订阅里给了两份 sing-box 配置, 按你客户端的版本选:

| 文件 | 内核版本 | 证书校验方式 |
|---|---|---|
| \`singbox.json\` | 1.13 及以上 | \`certificate_public_key_sha256\` 真固定 |
| \`singbox-compat.json\` | 1.12 | \`insecure: true\`(1.12 还没有指纹字段) |

sing-box **1.11 及更早**不认 1.12 起的新 DNS 格式, 直接导入会报配置错误,
这类版本请改用 \`clash.yaml\`(mihomo 内核)。
注意: 启用了 AnyTLS 时 \`clash.yaml\` 需要 **mihomo 1.19+**, 旧内核会报
"unsupported proxy type" 并**整份**订阅加载失败(不只是那一个节点) ——
这种情况请改用 \`singbox.json\`。
另外三项在客户端, 脚本管不到, 但影响一样大:

| 项 | 正确值 |
|---|---|
| 浏览器语言 | 英文或目标地区语言, 不要 zh-CN |
| 系统时区 | 与节点所在地区一致 |
| WebRTC | 关掉, 否则会暴露真实内网/公网地址 |

**浏览器自带的"安全 DNS"必须关掉。** Chrome / Edge 的 Secure DNS(DoH)、
Firefox 的"加密 DNS"、以及各类 App 内置的 DoH, 都会**绕过系统 DNS 和代理的
fake-ip 映射**, 自己在本地把 google.com 解析成国内 CDN 的 IP, 再连那个 IP。
这种情况 fake-ip 救不了 —— 域名压根没经过代理。
关掉后浏览器才用系统的 DNS, 才会走进 fake-ip 那条路。

| 浏览器 | 关在哪 |
|---|---|
| Chrome / Edge | 设置 → 隐私和安全 → 安全 → 使用安全 DNS → 关 |
| Firefox | 设置 → 隐私与安全 → 网络设置 → 加密 DNS → 关或改"手动" |
| Safari (macOS/iOS) | 系统设置 → 网络 → DNS → 关"加密 DNS" |

服务端这边可以随时确认 Google 怎么认这台机器:

    proxy audit

看 \`Google 地区\` 那一行。判定拿**出口国家做基准**:

    跳 google.com.hk 且出口在 HK/MO   -> 正常, 这是当地域名
    跳 google.co.jp 且出口在 JP       -> 正常
    跳 google.com.hk 但出口在 US      -> 送中, IP 本身在 Google 库里的归属有问题
                                        客户端怎么配都没用, 只能换 IP
    连不上 (HTTP 000)                 -> 服务端出不去, 先修出口

这一项会用真实浏览器 UA, 分别以 zh-CN 和 en-US 各探一次, 先看 HTTP 跳转、
再看页面里的域名 —— 因为 Google 现在多数情况不再回 302, 而是回 200 加
页面内 JS 跳转, 只看响应头会漏报。两种语言都试也是为了贴近真实浏览器:
你用的是中文系统, Google 对"IP 归属模糊 + 中文用户"会额外偏向港区。

### 判机房: 改不了, 这是 IP 的属性

TikTok / Google 判断 VPS 的依据是 **这段 IP 登记成什么类型**: hosting(机房)
还是 ISP(家宽)。它写在 IP 注册信息里, 和你用什么协议、哪个端口、哪个 SNI 无关。

同样用 \`proxy audit\` 看:

    IP 类型: 机房段 (hosting=true)  ->  平台会按机房处理你

注意这一行是**参考口径**(来自 ip-api 的公开库), 和平台自己的风控库不一定一致:
同一台机器这里显示 hosting=false, TikTok 那边照样按机房处理。
所以真正确定有没有被判机房, 只能拿实际账号试。

想让 TikTok 把你当普通用户, 只有三条路:

1. 换一台"原生 IP / 住宅 IP"的机器, 商家会明确标注, 通常贵不少
2. 服务端再套一层住宅代理做出口, 慢且要额外付费
3. 接受现状 —— 浏览一般能用, 登录和发布会被风控

用 Cloudflare WARP 做出口**解决不了**: WARP 的段同样被标成机房,
而且用的人太多, 风控等级比普通 VPS 还高。
GUIDE
  chmod 644 "$tdir/client-guide.md"

  # 订阅目录里是全部节点凭据。只有真的起了 HTTP 服务(以 nobody 运行)时
  # 才需要让其它用户可读; 默认 SUB_HTTP=0 时按 700/600 收紧, 别白白摊给同机用户。
  # 之前无条件 755/644, 连没开 HTTP 的机器也把 UUID / 密码暴露给同机任意用户。
  if [ "${SUB_HTTP:-0}" = "1" ]; then
    chmod 755 "$tdir"
    find "$tdir" -type f -exec chmod 644 {} + 2>/dev/null
  else
    chmod 700 "$tdir"
    find "$tdir" -type f -exec chmod 600 {} + 2>/dev/null
  fi
  SUB_TOKEN_DIR="$tdir"
  ok "订阅文件已生成: ${tdir}"
}

maybe_sub_http(){
  if [ "$SUB_HTTP" != "1" ]; then
    # 之前开过 HTTP 订阅、这次关了: 必须真的把服务停掉。不停的话端口还开着,
    # 而订阅目录已经收紧到 700, 服务只会一直回 403 —— 用户以为关了, 实际
    # 还占着一个公网端口。只在它确实在跑/被 enable 时才提示, 避免每次 sub 都刷屏。
    if [ -f /etc/systemd/system/proxy-sub.service ]; then
      if systemctl is-active --quiet proxy-sub 2>/dev/null \
         || systemctl is-enabled --quiet proxy-sub 2>/dev/null; then
        systemctl disable --now proxy-sub >/dev/null 2>&1 \
          && warn "已停用订阅 HTTP 服务 (SUB_HTTP=0, 端口已释放)"
      fi
    fi
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "未安装 python3, 跳过订阅 HTTP 服务"
    return 0
  fi
  [ -n "${SUB_PORT:-}" ] || SUB_PORT=$(( (RANDOM % 10000) + 30000 ))

  # 不能用 python3 -m http.server: 它会在根路径返回目录列表, 而目录名就是订阅
  # token —— 任何人扫到这个端口, GET / 一次就把全部凭据拿走了。
  # 换成只认 /<token>/<已知文件名> 的小服务, 其余一律 404, 不列目录。
  local srv=/usr/local/lib/proxy-sub/server.py
  mkdir -p /usr/local/lib/proxy-sub
  cat > "$srv" <<'PYSRV'
#!/usr/bin/env python3
"""订阅服务: 只响应 /<token>/<已知文件名>, 其余一律 404, 绝不列目录。

替代 python3 -m http.server —— 后者会在 "/" 返回目录列表, 而目录名就是 token。
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.realpath(os.environ.get("SUB_ROOT", "/var/www/proxy-sub"))
ALLOW = {
    "clash.yaml", "singbox.json", "singbox-compat.json",
    "base64.txt", "v2rayn.txt", "v2rayn-safe.txt", "links.txt", "client-guide.md",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "sub"
    sys_version = ""
    # 默认是 HTTP/1.0(每请求一次连接)。1.1 + Content-Length 才能复用连接,
    # 部分订阅客户端对 1.0 响应处理得不好。
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        parts = [p for p in self.path.split("?", 1)[0].split("/") if p]
        # 必须正好两段, 且第一段不能是 . / .. (防目录穿越)
        if len(parts) != 2 or parts[0] in (".", "..") or parts[1] not in ALLOW:
            self.send_error(404)
            return
        full = os.path.realpath(os.path.join(ROOT, parts[0], parts[1]))
        if not full.startswith(ROOT + os.sep):
            self.send_error(404)
            return
        try:
            with open(full, "rb") as fh:
                body = fh.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 30800
    bind = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    ThreadingHTTPServer((bind, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
PYSRV
  chmod 644 "$srv"

  cat > /etc/systemd/system/proxy-sub.service <<EOF
[Unit]
Description=Proxy Subscription HTTP
After=network.target

[Service]
Type=simple
# 只读地发几个静态文件, 没有任何理由用 root 跑
User=nobody
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
# 允许绑 1024 以下的端口(用户把 SUB_PORT 设成 80/443 时), 其余能力一律不要
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
WorkingDirectory=${SUB_DIR}
Environment=SUB_ROOT=${SUB_DIR}
ExecStart=$(command -v python3) ${srv} ${SUB_PORT} ${SUB_BIND}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable proxy-sub >/dev/null 2>&1
  systemctl restart proxy-sub >/dev/null 2>&1
  sleep 1
  if systemctl is-active --quiet proxy-sub; then
    ok "订阅服务已启动: ${SUB_BIND}:${SUB_PORT}"
    if [ "$SUB_BIND" = "127.0.0.1" ]; then
      echo -e "${D}仅监听本机, 取订阅请先建 SSH 隧道:${N}"
      echo -e "${D}  ssh -N -L ${SUB_PORT}:127.0.0.1:${SUB_PORT} root@${SERVER_IP:-<服务器IP>}${N}"
      echo -e "${D}  然后访问 http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN:-<token>}/clash.yaml${N}"
    else
      warn "订阅服务已对 ${SUB_BIND} 开放: token 即凭据, 请勿外传"
    fi
    echo -e "${D}停用: systemctl disable --now proxy-sub${N}"
  else
    warn "订阅服务启动失败, 已跳过"
  fi
}

# ---------------- 输出 ----------------
# 把节点信息写到 /root/proxy-info.txt
# 只写当前真正启用的协议: 以前是固定模板, 单开 hy2 时也会出现 VLESS 段,
# 而 SS2022 / AnyTLS / TUIC 反而完全不出现。
write_info_file(){
  local pu="${PRIMARY_UUID:-$UUID}"
  {
    echo "=========== 节点信息 ==========="
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "服务器 IP: ${SERVER_IP}"
    echo "启用协议: ${PROTOCOLS}"
    echo
    if proto_on reality; then
      echo "[VLESS + REALITY]  TCP ${VLESS_PORT}"
      echo "UUID     : ${pu}"
      echo "Flow     : xtls-rprx-vision"
      echo "SNI      : ${DEST}"
      echo "pbk      : ${PUB}"
      echo "shortId  : ${SID}"
      echo "fp       : chrome"
      echo "链接     : ${VLESS_LINK}"
      echo
    fi
    if proto_on hy2; then
      echo "[Hysteria2]  UDP ${HY2_PORT}"
      echo "密码     : ${HY2_PASS}"
      echo "SNI      : ${DEST}"
      if [ -n "${HY2_PIN:-}" ]; then
        # HY2_PIN 就是整证书的 SHA-256 hex, mihomo 的 fingerprint 填同一个值
        echo "证书固定 : 已启用"
        echo "指纹     : ${HY2_PIN}"
        echo "           (链接里的 pinSHA256 与 mihomo 的 fingerprint 都填这一行)"
        echo "SPKI     : ${CERT_SPKI_B64:-未计算}   (sing-box 的 certificate_public_key_sha256 用这行)"
      else
        echo "insecure : 1   (已显式关闭证书固定)"
      fi
      [ -n "${HY2_HOP:-}" ] && echo "端口跳跃 : ${HY2_HOP}"
      [ "$ENABLE_OBFS" = "1" ] && echo "混淆     : salamander / ${OBFS_PASS}"
      echo "链接     : ${HY2_LINK}"
      [ -n "${HY2_LINK_COMPAT:-}" ] && echo "v2rayN用 : ${HY2_LINK_COMPAT}  (v2rayN 不识别 pinSHA256, 此条无身份验证)"
      echo
    fi
    if proto_on ss2022; then
      echo "[Shadowsocks-2022]  TCP+UDP ${SS2022_PORT}"
      echo "加密方式 : 2022-blake3-aes-128-gcm"
      echo "服务端密钥: ${SS2022_PASS:-未设置}"
      echo "设备密码 : $(ss_pass_for "$pu")   (服务端密钥:设备密钥)"
      echo "链接     : ${SS_LINK}"
      echo
    fi
    if proto_on anytls; then
      echo "[AnyTLS]  TCP ${ANYTLS_PORT}"
      echo "SNI      : ${DEST}"
      echo "密码     : $(derive_hex "$pu")"
      echo "SPKI     : ${SB_PIN:-未计算}   (订阅 singbox.json 里已固定, 链接只能 insecure)"
      echo "链接     : ${ANYTLS_LINK}"
      echo
    fi
    if proto_on tuic; then
      echo "[TUIC v5]  TCP+UDP ${TUIC_PORT}"
      echo "UUID     : ${pu}"
      echo "密码     : $(derive_hex "$pu")"
      echo "SNI      : ${DEST}"
      echo "SPKI     : ${SB_PIN:-未计算}   (订阅 singbox.json 里已固定, 链接只能 insecure)"
      echo "链接     : ${TUIC_LINK}"
      echo
    fi
    echo "[管理]"
    echo "proxy info | name | sub | status | verify | restart | logs | audit"
    echo "proxy user | reset | backup | upgrade | optimize | timezone | wizard | clean"
    echo "订阅目录: ${SUB_TOKEN_DIR:-${SUB_DIR}}"
  } 2>/dev/null > /root/proxy-info.txt || {
    warn "写入 /root/proxy-info.txt 失败, 其余步骤不受影响"
    return 0
  }
  chmod 600 /root/proxy-info.txt 2>/dev/null || true
}

print_links(){
  echo
  if proto_on reality; then
    hr
    echo -e "${M}VLESS + REALITY${N}   TCP ${VLESS_PORT}"
    hr
    echo "UUID      : ${UUID}"
    echo "Flow      : xtls-rprx-vision"
    echo "SNI       : ${DEST}"
    echo "公钥 pbk  : ${PUB}"
    echo "shortId   : ${SID}"
    echo "指纹 fp   : chrome"
    echo
    echo -e "${G}${VLESS_LINK}${N}"
    echo
  fi

  if proto_on hy2; then
    hr
    echo -e "${M}Hysteria2${N}   UDP ${HY2_PORT}"
    hr
    echo "密码      : ${HY2_PASS}"
    echo "SNI       : ${DEST}"
    if [ -n "${HY2_PIN:-}" ]; then
      echo -e "证书固定  : ${G}已启用${N} (pinSHA256, 证书 SHA-256)"
      echo "  指纹    : ${HY2_PIN}"
      echo -e "  ${D}链接里的 insecure=1 只负责跳过 CA 校验, 身份由 pinSHA256 校验${N}"
      echo "  mihomo  : fingerprint: ${HY2_PIN}"
    else
      echo -e "${Y}跳过证书验证: 开启 (insecure=1) —— 链路上可被冒充${N}"
    fi
    [ -n "${HY2_HOP:-}" ] && echo "端口跳跃  : ${HY2_HOP}"
    [ "$ENABLE_OBFS" = "1" ] && echo "混淆      : salamander / ${OBFS_PASS}"
    echo
    echo -e "${G}${HY2_LINK}${N}"
    if [ -n "${HY2_LINK_COMPAT:-}" ]; then
      echo
      echo -e "${D}v2rayN 不识别 pinSHA256, 请改用下面这条(无身份验证):${N}"
      echo -e "${D}${HY2_LINK_COMPAT}${N}"
    fi
    echo
  fi

  if proto_on ss2022; then
    hr
    echo -e "${M}Shadowsocks-2022${N}   TCP+UDP ${SS2022_PORT}"
    hr
    echo "加密方式  : 2022-blake3-aes-128-gcm"
    echo "服务端密钥: ${SS2022_PASS:-未设置}"
    echo "设备密码  : $(ss_pass_for "$(primary_uuid)")"
    echo -e "${D}  多用户模式: 客户端密码 = 服务端密钥:设备密钥, 链接里已拼好${N}"
    echo -e "${D}  每个设备一段不同的设备密钥, 用 proxy user link <名字> 取对应链接${N}"
    echo
    echo -e "${G}${SS_LINK}${N}"
    echo
  fi

  if proto_on anytls; then
    hr
    echo -e "${M}AnyTLS${N}   TCP ${ANYTLS_PORT}"
    hr
    echo "SNI       : ${DEST}"
    echo -e "${Y}自签证书: 分享链接只能 insecure; 订阅 singbox.json 真固定, singbox-compat.json 走 insecure${N}"
    echo
    echo -e "${G}${ANYTLS_LINK}${N}"
    echo
  fi

  if proto_on tuic; then
    hr
    echo -e "${M}TUIC v5${N}   TCP+UDP ${TUIC_PORT}"
    hr
    echo "UUID      : $(primary_uuid)"
    echo "SNI       : ${DEST}"
    echo -e "${Y}自签证书: 分享链接只能 insecure; 订阅 singbox.json 真固定, singbox-compat.json 走 insecure${N}"
    echo
    echo -e "${G}${TUIC_LINK}${N}"
    echo
  fi
}

print_qr(){
  command -v qrencode >/dev/null 2>&1 || return 0
  if proto_on reality && [ -n "${VLESS_LINK:-}" ]; then
    echo -e "${B}--- VLESS 二维码 ---${N}"
    qrencode -t ANSIUTF8 -m 1 "$VLESS_LINK" 2>/dev/null || true
    echo
  fi
  if proto_on hy2 && [ -n "${HY2_LINK:-}" ]; then
    echo -e "${B}--- Hysteria2 二维码 ---${N}"
    qrencode -t ANSIUTF8 -m 1 "$HY2_LINK" 2>/dev/null || true
    echo
  fi
  if proto_on ss2022 && [ -n "${SS_LINK:-}" ]; then
    echo -e "${B}--- SS2022 二维码 ---${N}"
    qrencode -t ANSIUTF8 -m 1 "$SS_LINK" 2>/dev/null || true
    echo
  fi
}

print_sub_info(){
  echo
  hr
  echo -e "${M}订阅文件${N}"
  hr
  echo "目录: ${SUB_TOKEN_DIR:-${SUB_DIR}}"
  echo "  links.txt      原始链接(每条节点一行)"
  echo "  base64.txt     通用订阅, 小火箭 / v2rayN / v2rayNG 可直接导入"
  echo "  clash.yaml       Clash / mihomo / Clash Verge (含 fake-ip)"
  echo "  singbox.json     sing-box 1.13+ (含证书指纹固定)"
  echo "  singbox-compat.json  sing-box 1.12 (DNS 格式相同, 证书走 insecure)"
  echo "  v2rayn.txt       v2rayN 兼容版 (含 HY2/AT/TUIC, 会提示不安全)"
  # 只开 hy2/anytls/tuic 时 gen_sub_files 不会生成 safe 订阅, 列出来会 404
  if proto_on reality || proto_on ss2022; then
    echo "  v2rayn-safe.txt  v2rayN 推荐版 (只含 REALITY/SS2022, 无提示)"
  fi
  echo "  client-guide.md  客户端配置指南(证书固定 / TUN / 提速 / 排障)"
  echo "  默认节点     : $(effective_default_node) (DEFAULT_NODE=hy2 proxy sub 可切到 UDP 提速)"
  if [ -n "${HY2_BW_UP:-}" ] || [ -n "${HY2_BW_DOWN:-}" ]; then
    echo -e "  ${G}Brutal 已启用${N}: up=${HY2_BW_UP:-未设} down=${HY2_BW_DOWN:-未设} Mbps (clash.yaml / singbox*.json)"
  else
    echo -e "  ${D}提示: 大流量慢可开 Hysteria2 Brutal, 见 README「速度与调优」${N}"
  fi
  if [ "$SUB_HTTP" = "1" ] && [ -n "${SUB_PORT:-}" ] && [ -n "${SUB_TOKEN:-}" ]; then
    echo
    if [ "${SUB_BIND:-127.0.0.1}" = "127.0.0.1" ]; then
      echo "订阅服务(仅监听本机), 先在本地建隧道:"
      echo "  ssh -N -L ${SUB_PORT}:127.0.0.1:${SUB_PORT} root@${SERVER_IP}"
      echo "  Clash   : http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN}/clash.yaml"
      echo "  通用    : http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN}/base64.txt"
      echo "  singbox : http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN}/singbox.json"
    else
      echo "订阅服务(${SUB_BIND}:${SUB_PORT}, 需安全组放行 TCP ${SUB_PORT}):"
      echo "  Clash   : http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}/clash.yaml"
      echo "  通用    : http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}/base64.txt"
      echo "  singbox : http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}/singbox.json"
    fi
  else
    echo
    echo -e "${D}未启用 HTTP 订阅。用 FinalShell 文件面板把需要的文件下载到本机导入即可。${N}"
  fi
  echo
}

# 用订阅里同一套生成逻辑起一个临时 sing-box 客户端, 实测某个协议能不能通。
# 关键在于"用用户真正会导入的那份配置": 另写一套测试配置的话,
# 订阅生成与服务端不一致的问题(hy2 混淆漏写 / 端口跳跃漏写)永远测不出来。
selftest_sb_proto(){
  local proto="$1" tmp rc pid
  [ -x "$SB_BIN" ] || return 2
  tmp=$(mktemp -d 2>/dev/null) || return 2
  ( PROTOCOLS="$proto"; write_sb_client pinned "$tmp/c.json" ) >/dev/null 2>&1 \
    || { rm -rf "$tmp"; return 2; }
  # 本机连自己的公网 IP 依赖 hairpin NAT, 不少商家不支持 —— 直接改走回环。
  # 端口也从 2080 挪开, 避免和用户本机已有客户端撞车。
  sed -i "s/\"server\": \"${SERVER_IP}\"/\"server\": \"127.0.0.1\"/g" "$tmp/c.json" 2>/dev/null
  sed -i 's/"listen_port": 2080/"listen_port": 20801/' "$tmp/c.json" 2>/dev/null
  "$SB_BIN" run -c "$tmp/c.json" >"$tmp/log" 2>&1 &
  pid=$!
  sleep 2
  rc=$(curl -s --socks5-hostname 127.0.0.1:20801 -o /dev/null -w '%{http_code}' \
       --max-time 12 http://cp.cloudflare.com/generate_204 2>/dev/null)
  kill "$pid" >/dev/null 2>&1; wait "$pid" 2>/dev/null
  grep -qi 'FATAL' "$tmp/log" 2>/dev/null && rc="cfg"
  rm -rf "$tmp"
  case "$rc" in 200|204) return 0 ;; cfg) return 3 ;; *) return 1 ;; esac
}

# 逐个协议真连一次。返回不通的个数, 结果放在 SELFTEST_PASS/FAIL/SKIP。
selftest_protocols(){
  local pass=0 fail=0 skip=0 p
  if proto_on reality; then
    printf '  %-10s ' "REALITY"
    if [ ! -x "$XRAY_BIN" ]; then
      printf '%s\n' "跳过(未安装)"; skip=$((skip + 1))
    elif verify_reality "${DEST:-}"; then
      printf '%b%s%b\n' "$G" "通" "$N"; pass=$((pass + 1))
    else
      printf '%b%s%b\n' "$R" "不通" "$N"; fail=$((fail + 1))
    fi
  fi
  for p in hy2 ss2022 anytls tuic; do
    proto_on "$p" || continue
    printf '  %-10s ' "$p"
    selftest_sb_proto "$p"
    case $? in
      0) printf '%b%s%b\n' "$G" "通" "$N"; pass=$((pass + 1)) ;;
      2) printf '%s\n' "跳过(缺 sing-box)"; skip=$((skip + 1)) ;;
      3) printf '%b%s%b\n' "$R" "订阅配置非法" "$N"; fail=$((fail + 1)) ;;
      *) printf '%b%s%b\n' "$R" "不通" "$N"; fail=$((fail + 1)) ;;
    esac
  done
  SELFTEST_PASS=$pass; SELFTEST_FAIL=$fail; SELFTEST_SKIP=$skip
  return "$fail"
}

# 只读速度体检: 把"为什么慢"拆成能逐项核对的事实, 不改任何配置。
# 大多数"比别人的一键脚本慢"不是服务端配置差, 而是(1) 默认节点走 REALITY/TCP,
# 跨境丢包链路上抢不过 UDP; (2) Hysteria2 没开 Brutal; (3) 客户端把国内流量也塞进代理。
cmd_speed(){
  load_state 2>/dev/null || warn "未读到 state.env, 部分项会显示未知"
  apply_env_overrides

  echo -e "${M}速度与调优体检${N}"
  hr
  echo "[1] 内核网络参数(读的是真正生效的值, 不是配置文件里写了什么)"
  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  printf '  拥塞控制     : %s\n' "${cc:-未知}"
  # sysctl 里的 default_qdisc 只是"默认值", 真正生效的队列要读 tc。两者不一致时
  # 打印实际值, 免得出现"配置写着 fq、实际还是 pfifo_fast"的假绿灯。
  local dev="" real_qd=""
  dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [ -n "$dev" ] && real_qd=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$2=="root"{print $3; exit}')
  printf '  队列规则     : %s\n' "${real_qd:-${qd:-未知}}${real_qd:+ (sysctl 值: ${qd:-未知})}"
  printf '  可用算法     : %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 未知)"
  printf '  rmem/wmem max: %s / %s\n' \
    "$(sysctl -n net.core.rmem_max 2>/dev/null || echo '?')" \
    "$(sysctl -n net.core.wmem_max 2>/dev/null || echo '?')"
  if [ "$cc" = "bbr" ]; then
    ok "BBR 已生效"
  else
    warn "当前是 ${cc:-未知}, 不是 bbr —— 先跑一次: proxy optimize bbr"
  fi

  echo
  echo "[2] 协议与拥塞控制"
  printf '  启用协议     : %s\n' "${PROTOCOLS:-未知}"
  if proto_on hy2; then
    # 只看合法值: state.env 被手改成 abc 时订阅实际按默认 BBR 生成,
    # 这里不能再显示 "Brutal up=abc" 骗人。
    local _spu="${HY2_BW_UP:-}" _spd="${HY2_BW_DOWN:-}"
    if [ -n "$_spu" ] && ! hy2_bw_ok "$_spu"; then _spu=""; fi
    if [ -n "$_spd" ] && ! hy2_bw_ok "$_spd"; then _spd=""; fi
    if [ -n "$_spu" ] || [ -n "$_spd" ]; then
      printf '  Hysteria2    : Brutal  up=%s Mbps  down=%s Mbps\n' \
        "${_spu:-未设}" "${_spd:-未设}"
      ok "Brutal 已写进客户端订阅(仅 clash.yaml / singbox*.json 有效)"
    else
      echo "  Hysteria2    : 默认 BBR, 未开 Brutal"
      echo "                 晚高峰/丢包链路上抢带宽能力弱 —— 这是和纯 hy2 一键脚本体感差距最大的一项"
      echo "                 开启: HY2_BW_UP=<上行> HY2_BW_DOWN=<下行> proxy sub   (单位 Mbps)"
    fi
  fi
  echo "  REALITY      : $(proto_on reality && echo 'TCP/Vision, 稳但跨境高丢包时吞吐低于 UDP' || echo 未启用)"

  echo
  echo "[3] 客户端默认节点(最容易忽略的一项)"
  local _dn _def_desc="未知"
  _dn=$(effective_default_node)
  if [ "$_dn" = "hy2" ]; then
    _def_desc="HY2 / hy2-out (UDP, 速度优先)"
  elif proto_on reality; then
    _def_desc="VLESS/REALITY / vless-out (TCP, 抗封锁优先)"
  elif proto_on ss2022; then
    _def_desc="SS2022 / ss2022-out"
  elif proto_on anytls; then
    _def_desc="AnyTLS / anytls-out"
  elif proto_on tuic; then
    _def_desc="TUIC / tuic-out"
  fi
  echo "  clash.yaml    : select 第一项 = ${_def_desc}"
  echo "  singbox.json  : route.final   = ${_def_desc}"
  if [ "$_dn" = "hy2" ]; then
    echo "  节点已优先走 UDP; 若你的运营商限速 UDP, 用 DEFAULT_NODE=reality proxy sub 切回 TCP。"
  elif proto_on hy2; then
    echo "  TCP 在高丢包链路上吞吐低于 UDP —— 这是和纯 hy2 一键脚本体感差距最大的一项。"
    echo "  切到 UDP 提速: DEFAULT_NODE=hy2 proxy sub   (切回: DEFAULT_NODE=reality proxy sub)"
  fi

  echo
  echo "[4] 其它常见减速项"
  echo "  - singbox.json 是全代理配置, 国内站点也绕一圈; 要国内直连请用 clash.yaml"
  echo "  - TUN 模式 MTU 填 1500(默认 9000 会丢大包), 并关掉严格路由"
  echo "  - obfs / 端口跳跃会多一层开销; 不需要时可关"
  echo "  - 单核小机器用 top 看 hysteria 是否吃满一个核, 吃满就是 CPU 到顶了"

  echo
  echo "[5] 服务端出口带宽(想实测时手动跑)"
  echo '  curl -o /dev/null -s -w "%{speed_download}\n" "https://speed.cloudflare.com/__down?bytes=10000000"'
  echo "  结果是字节/秒, 乘 8 得 bit/s。它测的是 VPS 出口, 不是你本地到 VPS 的链路。"

  echo
  echo "本命令只读, 不修改任何配置。具体提速步骤见 README「速度与调优」。"
}

cmd_selftest(){
  need_root
  load_state || die "尚未安装"
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  echo
  hr
  echo -e "${M}协议连通性实测${N}  ${D}(用订阅里同一份配置, 从本机回环发起)${N}"
  hr
  selftest_protocols || true
  echo
  if [ "${SELFTEST_FAIL:-0}" = "0" ]; then
    ok "全部通过: ${SELFTEST_PASS} 个协议"
  else
    warn "${SELFTEST_FAIL} 个协议不通, 按顺序排查:"
    echo "    proxy status        看进程与端口是否在监听"
    echo "    proxy logs sb       看 sing-box 报错"
    echo "    proxy logs hy2      看 hysteria 报错"
    echo "    云安全组/防火墙      是否放行了对应端口(TCP/UDP 别搞混)"
  fi
  [ "${SELFTEST_SKIP:-0}" != "0" ] && info "${SELFTEST_SKIP} 项跳过"
  echo
  return 0
}

self_check(){
  info "部署后自检 ..."
  echo
  hr
  echo -e "${M}协议连通性实测${N}  ${D}(用订阅里同一份配置, 从本机回环发起)${N}"
  hr
  selftest_protocols || true
  echo
  if [ "${SELFTEST_FAIL:-0}" = "0" ]; then
    ok "全部协议本机自测通过"
  else
    warn "${SELFTEST_FAIL} 个协议本机自测未通过 —— 少数 VPS 限制回环出站, 以客户端实测为准"
    echo -e "    ${D}排查: proxy status / proxy logs sb / proxy logs hy2 / proxy selftest${N}"
  fi
}

# ---------------- 安装前预检 ----------------
preflight(){
  local mem_mb ntp ipv6cnt
  mem_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
  if [ -n "$mem_mb" ] && [ "$mem_mb" -lt 400 ]; then
    warn "内存仅 ${mem_mb}MB: Xray + Hysteria2 同时跑会吃紧, 脚本会自动补 1GB swap"
  fi

  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "")
  if [ "$ntp" = "no" ]; then
    warn "系统时间未同步: REALITY 对时间敏感, 建议 systemctl enable --now systemd-timesyncd"
  fi

  ipv6cnt=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)
  if [ "${ipv6cnt:-0}" -gt 0 ]; then
    info "检测到公网 IPv6: 客户端 v6 目标已被路由规则拦截, 建议在服务商侧也关掉"
  fi
}

# ---------------- 安装主流程 ----------------
cmd_install(){
  need_root
  # 注意: 这里不要预先 mkdir $STATE_DIR。
  # 安装中途失败(下载失败/断网/Ctrl+C)会留下空目录, 下次重跑就会被误判成"残缺安装"弹确认。
  # 状态目录统一由 save_state 在真正写凭据时才创建。
  echo
  echo -e "${M}============================================================${N}"
  echo -e "${M}   Proxy Node Installer v${SCRIPT_VERSION}   (${BUILD_DATE})${N}"
  echo -e "${M}============================================================${N}"
  echo

  # 自动更新被跳过(网络不通 / PN_NO_SELFUPDATE=1)时, 至少把"有新版"这件事说清楚。
  # 能自动更新成功的话这里远端版本已经等于本地, 不会重复提示。
  hint_script_update

  detect_pkg
  . /etc/os-release 2>/dev/null || true
  info "系统: ${PRETTY_NAME:-unknown}  架构: $(uname -m)  内存: $(free -m | awk '/Mem:/{print $2}')MB"

  local fresh=0
  if load_state; then
    apply_env_overrides
    ok "检测到已有安装 (${INSTALLED_AT:-未知}), 复用凭据与端口"
    [ -n "${DEST:-}" ] && info "沿用伪装目标: ${DEST}"
  else
    fresh=1
    info "全新安装"
  fi

  normalize_protocols "$PROTOCOLS"
  info "启用协议: ${PROTOCOLS}"
  # 订阅端口若留空, 必须在这里就定下来再参与 validate_ports 的冲突检查。
  # 之前是在 maybe_sub_http 里随机的, 那时校验早跑完了, 有可能撞上协议端口
  # 导致 proxy-sub 起不来, 而安装过程毫无提示。只在真要开 HTTP 时才占端口。
  if [ "${SUB_HTTP:-0}" = "1" ] && [ -z "${SUB_PORT:-}" ]; then
    SUB_PORT=$(( (RANDOM % 10000) + 30000 ))
  fi
  # 端口先校验: 数字写错 / 两个协议撞同一个端口, 都在这里就中止,
  # 不要等到服务起不来再去猜
  validate_ports

  install_deps
  preflight

  # 清理决策内嵌在安装流程里: 正常安装→默认幂等; 残缺安装→主动问清理
  if ! install_clean_gate "$([ "$fresh" = "1" ] && echo 0 || echo 1)"; then
    # 清掉内存里的旧凭据, 否则会"复用"刚删掉的那套
    UUID=""; PRIV=""; PUB=""; SID=""; DEST=""
    HY2_PASS=""; OBFS_PASS=""; SUB_TOKEN=""; SERVER_IP=""
    HY2_PIN=""; CERT_SPKI_B64=""; CERT_DER_B64=""; CERT_HEX=""
    SS2022_PASS=""; ANYTLS_PASS=""; TUIC_PASS=""; TUIC_UUID=""; SB_PIN=""; SB_HEX=""
    fresh=1
  fi

  # 端口占用: 逐个检查已启用协议的端口
  local plist="" p port proto2 owner=""
  proto_on reality && plist="${plist} ${VLESS_PORT}/tcp"
  proto_on hy2     && plist="${plist} ${HY2_PORT}/udp"
  proto_on ss2022  && plist="${plist} ${SS2022_PORT}/tcp ${SS2022_PORT}/udp"
  proto_on anytls  && plist="${plist} ${ANYTLS_PORT}/tcp"
  proto_on tuic    && plist="${plist} ${TUIC_PORT}/tcp ${TUIC_PORT}/udp"

  for p in $plist; do
    port="${p%%/*}"; proto2="${p##*/}"
    owner=$(port_owner "$port" "$proto2") || owner=""
    [ -n "$owner" ] || continue
    if [ "$fresh" = "0" ] && echo "$owner" | grep -qE '^(xray|hysteria|sing-box)'; then
      info "$(echo "$proto2" | tr a-z A-Z) ${port} 由本服务自身监听, 继续"
      continue
    fi
    warn "$(echo "$proto2" | tr a-z A-Z) ${port} 已被占用: ${owner}"
    if echo "$owner" | grep -qE '^(xray|hysteria|sing-box)'; then
      if ask_yes "这是本脚本残留的实例, 清理后继续?"; then
        do_clean 0; sleep 1
      fi
    else
      if ask_yes "结束该进程(${owner})并继续?"; then
        kill_port_owner "$port" "$proto2"; sleep 1
      fi
    fi
    if port_in_use "$port" "$proto2"; then
      die "端口 ${port}/${proto2} 仍被占用。重装试试: bash $(basename "$0") install --clean; 或换端口: VLESS_PORT=8443 bash $(basename "$0") install"
    fi
  done

  # 内核参数必须在**任何服务启动之前**生效。之前 optimize_system 排在所有
  # restart 之后: rmem_max 仍是默认 208KB 时 HY2 / TUIC 已经建好了 UDP socket,
  # 事后改 sysctl 不会扩大已创建 socket 的 SO_RCVBUF, QUIC 的 8MB/20MB 窗口
  # 被内核钳死 —— 跨洲高 BDP 链路上吞吐直接跑不满。这就是「装完慢、重启后好些」。
  optimize_system

  # xray 必须先就位: openssl 不可用时要回退到 xray x25519 生成密钥
  if proto_on reality; then
    ensure_xray
  fi

  ensure_creds
  # 设备凭据文件统一在这里创建: 只开 ss2022/anytls/tuic 时不会走 write_xray_config,
  # 少了这一步 users.txt 就不存在, sing-box 的 users 会退化成单用户分支。
  ensure_users_file
  if proto_on reality; then
    ensure_xray_service
  fi

  SERVER_IP=$(get_server_ip)
  [ -n "$SERVER_IP" ] || die "无法获取公网 IPv4。若这台机器是纯 IPv6(无 v4 地址), 本脚本暂不支持 —— 链接里需要带方括号的 IPv6 写法, 各协议得分别处理, 不是改一行能解决的"
  ok "服务器 IP: ${SERVER_IP}"

  # 节点备注名默认用 VPS 厂商简称: 客户端列表里显示 "RackNerd-VLESS" 比 "Node-VLESS" 有用
  # 用户显式给了 NODE_NAME 就尊重用户的选择, 不再覆盖
  if [ "$_RAW_NODE_NAME" = "__unset__" ] && [ "${NODE_NAME}" = "Node" ]; then
    local vn
    vn=$(detect_vendor)
    if [ -n "$vn" ]; then
      NODE_NAME="${vn// /-}"
      if vendor_is_upstream "$vn"; then
        # 直营用户看到这个名字正好, 转售商用户会以为认错了 —— 两种都说明白, 别让人猜
        warn "IP 段持有者: ${NODE_NAME} —— 这是机房/批发商, 不一定是卖你机器的商家"
        info "RackNerd / CloudCone 这类转售商没有自己的 ASN, 反查只会返回上游机房"
        info "如果认错了, 装完执行一次即可改名(不用重装): proxy name RackNerd"
      else
        ok "节点备注: ${NODE_NAME}  (链接名形如 ${NODE_NAME}-VLESS / ${NODE_NAME}-HY2)"
      fi
    else
      info "未识别出 VPS 厂商, 节点备注沿用 ${NODE_NAME} (可自定义: NODE_NAME=我的机器)"
    fi
  fi

  backup_config

  # 复用旧 DEST 前必须复查排除名单。旧版本里 dl.google.com / www.youtube.com
  # 这类被墙域名也进过候选表, 留着它 = ClientHello 出不了国, 直接被判机房。
  if [ -n "${DEST:-}" ] && is_blocked "$DEST"; then
    warn "当前伪装目标 ${DEST} 在排除名单里(被墙域名, 或与代理共用证书链), 重新挑一个"
    DEST=""
  fi

  # REALITY 必须做真实握手验证; 只开 hy2/anytls/tuic 时只需要一个可用的 SNI 目标。
  # 之前只按 reality 判断, 单开 hy2 会留下空的 DEST: 证书 CN 为空、
  # masquerade url 变成 https:/// , 链接里 sni 也是空的。
  if proto_on reality; then
    if [ -z "${DEST:-}" ]; then
      if ! pick_dest; then
        err "所有候选伪装站都不可达(连 HTTPS 都打不开), 不是握手问题而是出站被拦:"
        echo "    1) 先确认 443 出站:  curl -sI https://www.samsung.com  看是否 000"
        echo "    2) 再确认时间已同步:  timedatectl"
        echo "    3) 指定自己的域名:    REALITY_DEST=你的域名 bash setup-proxy.sh"
        die  "伪装目标选择失败, 完整探测过程见 /var/log/proxy-deploy.log"
      fi
    else
      info "复用伪装目标: ${DEST}"
    fi
  elif proto_on hy2 || proto_on anytls || proto_on tuic; then
    if [ -z "${DEST:-}" ]; then
      pick_dest_simple
    else
      info "复用伪装目标: ${DEST}"
    fi
  fi

  if proto_on reality; then
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1
    sleep 2
    if ! systemctl is-active --quiet xray; then
      owner=$(port_owner "$VLESS_PORT" tcp) || owner=""
      if [ -n "$owner" ]; then
        die "Xray 启动失败: TCP ${VLESS_PORT} 被 ${owner} 占用。执行 bash $(basename "$0") install --clean 清理后重装, 或换端口: VLESS_PORT=8443 bash $(basename "$0") install"
      fi
      die "Xray 启动失败, 查看: journalctl -u xray -n 30 --no-pager"
    fi
    ok "Xray 运行中: TCP ${VLESS_PORT}, 伪装目标 ${DEST}"
  fi

  if proto_on hy2; then
    ensure_hy2
    setup_hy2_hop
  fi

  if sb_enabled; then
    ensure_singbox
    ensure_sb_cert
    ensure_sb_creds
    write_singbox_config
    ensure_singbox_service
  fi

  # 本次没选的协议要真的关掉, 否则端口还开着、用户以为已经关了
  stop_unused_services
  # optimize_system 已提前到服务启动之前, 这里不再重复调用
  setup_firewall
  install_healthcheck

  save_state
  gen_links
  gen_sub_files
  maybe_sub_http
  save_state

  write_info_file
  print_links
  print_qr
  print_sub_info
  self_check

  local self_path
  self_path=$(readlink -f "$0" 2>/dev/null || echo "")
  if [ -z "$self_path" ] || [ ! -f "$self_path" ]; then
    # curl | bash 且自动更新被跳过: 脚本没有落盘, 建不了软链
    warn "以管道方式运行, 未创建 ${APP_NAME} 命令"
    echo -e "    ${D}想要管理命令的话, 下次改用:${N}"
    echo -e "    ${D}${ONELINER}${N}"
  else
    # 关键: 按文档用 curl -o 下载再 bash 运行时, 脚本权限是 644(没有执行位)。
    # 软链过去之后 proxy 指向的是一个不可执行的文件, 一敲就是 Permission denied
    # —— root 也一样, 内核要求至少有一个 x 位。安装时顺手补上。
    [ -x "$self_path" ] || chmod 755 "$self_path" 2>/dev/null
    if [ "$self_path" = "/usr/local/bin/${APP_NAME}" ]; then
      # 脚本本身就是装在管理命令位置上的实体文件, 不需要再建软链。
      # 之前这个分支会走到 else 里报"以管道方式运行", 完全是误导。
      ok "管理命令已就位: ${APP_NAME}  (例如 ${APP_NAME} info)"
    elif ln -sf "$self_path" "/usr/local/bin/${APP_NAME}" 2>/dev/null && [ -x "/usr/local/bin/${APP_NAME}" ]; then
      ok "已安装管理命令: ${APP_NAME}  (例如 proxy info)"
    else
      warn "管理命令创建失败, 手动执行:"
      echo -e "    ${D}chmod +x ${self_path} && ln -sf ${self_path} /usr/local/bin/${APP_NAME}${N}"
    fi
    # 软链重指之后再做清理: 此时 proxy 已经指向正在运行的这份,
    # 删掉其它副本不会把管理命令一起删掉。
    cleanup_stale_scripts
  fi

  echo
  echo -e "${G}============================================================${N}"
  echo -e "${G}   部署完成${N}"
  echo -e "${G}============================================================${N}"
  echo -e "  节点信息: ${Y}cat /root/proxy-info.txt${N}"
  echo -e "  管理菜单: ${Y}proxy${N}"
  echo -e "  加装协议: ${Y}proxy wizard${N}      优化 VPS: ${Y}proxy optimize${N}"
  echo
  local fw=""
  proto_on reality && fw="${fw} TCP ${VLESS_PORT}"
  proto_on hy2     && fw="${fw} UDP ${HY2_PORT}"
  proto_on ss2022  && fw="${fw} TCP+UDP ${SS2022_PORT}"
  proto_on anytls  && fw="${fw} TCP ${ANYTLS_PORT}"
  proto_on tuic    && fw="${fw} TCP+UDP ${TUIC_PORT}"
  echo -e "${Y}必做${N}: 云安全组放行${Y}${fw}${N}"
  [ -n "${HY2_HOP:-}" ] && echo -e "        以及 ${Y}UDP ${HY2_HOP}${N} (端口跳跃)"
  echo
}

# ---------------- 管理子命令 ----------------
cmd_info(){
  need_root
  load_state || die "尚未安装, 先执行: bash setup-proxy.sh install"
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  if [ -n "${SUB_TOKEN:-}" ]; then
    SUB_TOKEN_DIR="${SUB_DIR}/${SUB_TOKEN}"
  fi
  gen_links
  write_info_file
  print_links
  print_qr
  print_sub_info
}

# 改节点备注名。只改客户端显示, 不碰服务端配置, 所以不用重装也不用重启内核
cmd_name(){
  need_root
  load_state || die "尚未安装, 先执行: bash $(basename "$0") install"

  local nn="${1:-}"
  if [ -z "$nn" ]; then
    echo
    echo -e "当前备注: ${G}${NODE_NAME}${N}"
    echo -e "${D}链接名形如 ${NODE_NAME}-VLESS / ${NODE_NAME}-HY2 / ${NODE_NAME}-SS2022${N}"
    echo
    read_tty "新备注名 (回车取消): " nn ""
  fi
  [ -n "$nn" ] || { info "未改动"; return 0; }

  nn=$(sanitize_node_name "$nn")
  if [ "$nn" = "$NODE_NAME" ]; then
    info "和当前一样, 未改动"
    return 0
  fi

  NODE_NAME="$nn"
  save_state

  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  gen_links
  gen_sub_files
  write_info_file

  ok "备注名已改为 ${NODE_NAME}"
  echo -e "${D}链接和订阅里的名字已同步, 服务端配置一行没动, 客户端重新导入一次即可${N}"
  echo
  print_links
  print_sub_info
}

cmd_sub(){
  need_root
  load_state || die "尚未安装"
  # sub 允许本次用环境变量指定 Brutal 带宽(会由 save_state 写入 state.env, 之后沿用)。
  # load_state 会 source state.env
  # 把环境变量冲掉, 所以按脚本开头记下的 _RAW_* 回盖。这里只回盖这两个变量,
  # 不调用 apply_env_overrides —— 那会连带清空 DEST, 对"只重生成订阅"风险太大。
  # 值非法就不覆盖(保留 state.env 里的原值), gen_sub_files 内还有一层兜底校验。
  local _u="" _d="" _ok=1 _v
  [ "$_RAW_HY2_BW_UP"   != "__unset__" ] && _u="$_RAW_HY2_BW_UP"
  [ "$_RAW_HY2_BW_DOWN" != "__unset__" ] && _d="$_RAW_HY2_BW_DOWN"
  for _v in "$_u" "$_d"; do
    [ -n "$_v" ] || continue
    hy2_bw_ok "$_v" || _ok=0
  done
  if [ "$_ok" = "1" ]; then
    [ "$_RAW_HY2_BW_UP"   != "__unset__" ] && HY2_BW_UP="$_u"
    [ "$_RAW_HY2_BW_DOWN" != "__unset__" ] && HY2_BW_DOWN="$_d"
  else
    warn "HY2_BW_UP/DOWN 必须是 1-10000 的整数(Mbps), 本次保持原有设置不变"
  fi
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  # DEFAULT_NODE 同理必须回盖: state.env 里存着上一次的值, load_state 一 source
  # 就把本次环境变量冲掉了。不补这一段, README 里主推的
  # `DEFAULT_NODE=hy2 proxy sub` 会"执行成功但没切换" —— 和带宽那次是同一个坑。
  if [ "$_RAW_DEFAULT_NODE" != "__unset__" ]; then
    case "$_RAW_DEFAULT_NODE" in
      reality|vless|hy2|hysteria2) DEFAULT_NODE="$_RAW_DEFAULT_NODE" ;;
      *) warn "DEFAULT_NODE='${_RAW_DEFAULT_NODE}' 不认识(可选 reality / hy2), 本次保持原有设置不变" ;;
    esac
  fi
  gen_links
  gen_sub_files
  maybe_sub_http
  save_state
  print_sub_info
}

cmd_status(){
  need_root
  load_state || die "尚未安装"
  echo
  hr
  echo -e "${M}服务状态${N}"
  hr
  echo -e "${D}启用协议: ${PROTOCOLS:-reality,hy2}${N}"
  proto_on reality && printf 'xray            : %s / %s\n' "$(systemctl is-active xray 2>/dev/null)" "$(systemctl is-enabled xray 2>/dev/null)"
  proto_on hy2     && printf 'hysteria-server : %s / %s\n' "$(systemctl is-active hysteria-server 2>/dev/null)" "$(systemctl is-enabled hysteria-server 2>/dev/null)"
  sb_enabled       && printf 'sing-box        : %s / %s\n' "$(systemctl is-active sing-box 2>/dev/null)" "$(systemctl is-enabled sing-box 2>/dev/null)"
  [ -n "${HY2_HOP:-}" ] && printf 'hy2-hop         : %s\n' "$(systemctl is-active hy2-hop 2>/dev/null)"
  [ "$SUB_HTTP" = "1" ] && printf 'proxy-sub       : %s\n' "$(systemctl is-active proxy-sub 2>/dev/null)"
  echo
  echo -e "${M}监听端口${N}"
  local plist="" p
  proto_on reality && plist="${plist}|${VLESS_PORT}"
  proto_on hy2     && plist="${plist}|${HY2_PORT}"
  proto_on ss2022  && plist="${plist}|${SS2022_PORT}"
  proto_on anytls  && plist="${plist}|${ANYTLS_PORT}"
  proto_on tuic    && plist="${plist}|${TUIC_PORT}"
  if [ -n "$plist" ]; then
    ss -tulnp 2>/dev/null | grep -E "(${plist#|})[[:space:]]" || echo "(未找到匹配端口)"
  else
    echo "(无)"
  fi
  echo
  echo -e "${M}出口 IPv4${N} : ${SERVER_IP:-未知}"
  [ -x "$XRAY_BIN" ] && echo -e "${M}Xray 版本${N} : $($XRAY_BIN version 2>/dev/null | head -1)"
  [ -x "$SB_BIN" ]   && echo -e "${M}sing-box${N}  : $($SB_BIN version 2>/dev/null | head -1)"
  echo -e "${M}拥塞控制${N}  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo -e "${M}设备凭据${N}  : $([ -f "$USERS_FILE" ] && wc -l < "$USERS_FILE" || echo 0) 条 (proxy user list)"
  # 版本 + 脚本路径 + 修改时间一起给: 只给版本号看不出"这份是什么时候下的",
  # 而"一直在跑几个月前的旧脚本"正是最容易踩的坑。有新版会单独提示。
  local _sp _sm
  _sp=$(running_script_path)
  echo -e "${M}脚本版本${N}  : ${SCRIPT_VERSION} (${BUILD_DATE})"
  if [ -n "$_sp" ]; then
    _sm=$(date -r "$_sp" '+%Y-%m-%d %H:%M' 2>/dev/null)
    echo -e "${M}脚本文件${N}  : ${_sp}${_sm:+  (改于 ${_sm})}"
  fi
  echo
}

# ---------------- 自检 ----------------
# 三件事: 二进制有没有被换过 / 配置还能不能被内核接受 / 凭据文件权限有没有被放宽
VERIFY_FIX=""

chk_bin_sha(){
  local file="$1" want="$2" label="$3" got
  [ -x "$file" ] || return 0
  got=$(file_sha256 "$file")
  if [ -z "$want" ]; then
    printf '  %b%-10s%b %s\n' "$Y" "未记录" "$N" "${label}  (重装一次即可建立基准)"
    return 0
  fi
  if [ "$got" = "$want" ]; then
    printf '  %b%-10s%b %s\n' "$G" "一致" "$N" "${label}"
    return 0
  fi
  printf '  %b%-10s%b %s\n' "$R" "被改动" "$N" "${label}"
  printf '      %b基准 %s%b\n' "$D" "${want:0:32}" "$N"
  printf '      %b当前 %s%b\n' "$D" "${got:0:32}" "$N"
  printf '      %b这台机器上的二进制和安装时不一致, 可能被人替换。%b\n' "$D" "$N"
  printf '      %b确认无误可重装覆盖: bash setup-proxy.sh install --clean%b\n' "$D" "$N"
  return 1
}

chk_perm(){
  local f="$1" want="$2" label="$3" got
  [ -e "$f" ] || return 0
  got=$(stat -c '%a' "$f" 2>/dev/null)
  [ -n "$got" ] || return 0
  if [ "$got" = "$want" ]; then
    printf '  %b%-10s%b %s\n' "$G" "正常" "$N" "$label"
    return 0
  fi
  printf '  %b%-10s%b %s  (当前 %s, 应为 %s)\n' "$R" "过宽" "$N" "$label" "$got" "$want"
  VERIFY_FIX="${VERIFY_FIX}${f}|${want}"$'\n'
  return 1
}

cmd_verify(){
  need_root
  load_state || die "尚未安装, 先执行: bash $(basename "$0") install"
  local fix=0 a bad=0 perm_bad=0

  for a in "$@"; do
    case "$a" in --fix|-f) fix=1 ;; esac
  done

  echo
  hr
  echo -e "${M}安全自检${N}   ${D}检查项: 二进制指纹 / 配置合法性 / 凭据权限 / 端口监听${N}"
  hr

  echo
  echo -e "${B}1. 二进制指纹${N}  ${D}(安装时记录, 之后被替换就能看出来)${N}"
  if proto_on reality; then
    chk_bin_sha "$XRAY_BIN" "${XRAY_BIN_SHA:-}" "xray      $($XRAY_BIN version 2>/dev/null | head -1)" || bad=1
  fi
  if proto_on hy2; then
    chk_bin_sha "$HY2_BIN" "${HY2_BIN_SHA:-}" "hysteria  $($HY2_BIN version 2>/dev/null | head -1)" || bad=1
  fi
  if sb_enabled; then
    chk_bin_sha "$SB_BIN" "${SB_BIN_SHA:-}" "sing-box  $($SB_BIN version 2>/dev/null | head -1)" || bad=1
  fi

  echo
  echo -e "${B}2. 配置合法性${N}"
  if proto_on reality && [ -x "$XRAY_BIN" ]; then
    if "$XRAY_BIN" run -test -c "$XRAY_CFG" >/dev/null 2>&1; then
      printf '  %b%-10s%b xray config.json\n' "$G" "通过" "$N"
    else
      printf '  %b%-10s%b xray config.json\n' "$R" "失败" "$N"; bad=1
    fi
  fi
  if sb_enabled && [ -x "$SB_BIN" ]; then
    if "$SB_BIN" check -c "$SB_CFG" >/dev/null 2>&1; then
      printf '  %b%-10s%b sing-box config.json\n' "$G" "通过" "$N"
    else
      printf '  %b%-10s%b sing-box config.json\n' "$R" "失败" "$N"; bad=1
    fi
  fi
  if proto_on hy2; then
    # hysteria 没有 config check 子命令, 只做必填项存在性检查
    if [ -f "$HY2_CFG" ] && grep -q '^listen:' "$HY2_CFG" && grep -q '^auth:' "$HY2_CFG" \
       && grep -q '^tls:' "$HY2_CFG"; then
      printf '  %b%-10s%b hysteria config.yaml (listen/auth/tls 齐全)\n' "$G" "通过" "$N"
    else
      printf '  %b%-10s%b hysteria config.yaml\n' "$R" "缺项" "$N"; bad=1
    fi
  fi

  echo
  echo -e "${B}3. 凭据文件与订阅目录权限${N}  ${D}(xray 配置里就是全部设备的 UUID)${N}"
  proto_on reality && { chk_perm "$XRAY_CFG" 600 "xray 配置" || perm_bad=1; }
  proto_on hy2     && { chk_perm "$HY2_CFG" 600 "hysteria 配置(含密码)" || perm_bad=1; }
  proto_on hy2     && { chk_perm /etc/hysteria/key.pem 600 "hysteria 私钥" || perm_bad=1; }
  sb_enabled       && { chk_perm "$SB_CFG" 600 "sing-box 配置(含密码)" || perm_bad=1; }
  sb_enabled       && { chk_perm "$SB_KEY" 600 "sing-box 私钥" || perm_bad=1; }
  chk_perm "$STATE_FILE" 600 "state.env(全部凭据)" || perm_bad=1
  chk_perm "$USERS_FILE" 600 "users.txt(设备列表)" || perm_bad=1
  chk_perm /root/proxy-info.txt 600 "proxy-info.txt" || perm_bad=1
  chk_perm "$STATE_DIR" 700 "状态目录" || perm_bad=1

  # 目录里任何一个文件对其它用户可读都算问题
  local loose
  loose=$(find "$STATE_DIR" -type f -perm /o+r 2>/dev/null | head -3)
  if [ -n "$loose" ]; then
    printf '  %b%-10s%b 下列文件对其它用户可读:\n' "$R" "泄露" "$N"
    printf '%s\n' "$loose" | sed 's/^/      /'
    while IFS= read -r a; do [ -n "$a" ] && VERIFY_FIX="${VERIFY_FIX}${a}|600"$'\n'; done <<< "$loose"
    perm_bad=1
  fi

  # 订阅目录同样是全量凭据: links.txt / clash.yaml / singbox*.json 里有 UUID、
  # HY2 / SS2022 / AnyTLS / TUIC 密码和 REALITY 公钥。默认(SUB_HTTP=0)应该
  # 700/600; 只有真开了 HTTP 订阅服务才需要 755/644 让服务进程读到。
  # 这一段以前只在 README 里写了, 代码没查, 属于文档承诺与实现不一致。
  local sdir="${SUB_DIR:-/var/www/proxy-sub}/${SUB_TOKEN:-}" sub_loose=""
  if [ -n "${SUB_TOKEN:-}" ] && [ -d "$sdir" ]; then
    if [ "${SUB_HTTP:-0}" = "1" ]; then
      chk_perm "$sdir" 755 "订阅目录(HTTP 服务需要可读)" || perm_bad=1
    else
      chk_perm "$sdir" 700 "订阅目录(未开 HTTP 服务)" || perm_bad=1
      sub_loose=$(find "$sdir" -type f -perm /o+r 2>/dev/null | head -3)
      if [ -n "$sub_loose" ]; then
        printf '  %b%-10s%b 订阅文件对其它用户可读(token 与全部密码):\n' "$R" "泄露" "$N"
        printf '%s\n' "$sub_loose" | sed 's/^/      /'
        while IFS= read -r a; do [ -n "$a" ] && VERIFY_FIX="${VERIFY_FIX}${a}|600"$'\n'; done <<< "$sub_loose"
        perm_bad=1
      fi
    fi
  fi

  echo
  echo -e "${B}4. 服务与监听${N}"
  # 只要求「当前协议组合真的会用到」的服务是活的。
  # 老版本这里是无条件判活: 用户按第 6 节建议 systemctl disable --now proxy-sub
  # 关掉订阅服务, 回到这里又被标红, 自检自己打自己。
  local svc want
  for svc in xray hysteria-server sing-box proxy-sub hy2-hop; do
    systemctl cat "${svc}.service" >/dev/null 2>&1 || continue
    case "$svc" in
      xray)            want=$(proto_on reality && echo 1 || echo 0) ;;
      hysteria-server) want=$(proto_on hy2     && echo 1 || echo 0) ;;
      sing-box)        want=$(sb_enabled       && echo 1 || echo 0) ;;
      proxy-sub)       want=$([ "${SUB_HTTP:-0}" = "1" ] && echo 1 || echo 0) ;;
      hy2-hop)         want=$([ -n "${HY2_HOP:-}" ] && echo 1 || echo 0) ;;
      *)               want=1 ;;
    esac
    if systemctl is-active --quiet "$svc"; then
      if [ "$want" = "1" ]; then
        printf '  %b%-10s%b %s\n' "$G" "运行中" "$N" "$svc"
      else
        # 配置说用不到它, 它却在跑 = 多一个对公网的监听端口。不算致命(不改退出码),
        # 但要指出来: 关协议 / 关订阅 HTTP 之后最容易漏的就是这一步。
        printf '  %b%-10s%b %s  %s\n' "$Y" "多余" "$N" "$svc" "(当前配置不需要, 建议 proxy restart)"
      fi
    elif [ "$want" = "1" ]; then
      printf '  %b%-10s%b %s\n' "$R" "未运行" "$N" "$svc"; bad=1
    else
      # 当前协议组合用不到它, 停着才是对的
      printf '  %b%-10s%b %s  %s\n' "$D" "已停用" "$N" "$svc" "(当前配置不需要, 符合预期)"
    fi
  done
  if systemctl cat proxy-healthcheck.timer >/dev/null 2>&1; then
    if systemctl is-active --quiet proxy-healthcheck.timer; then
      printf '  %b%-10s%b proxy-healthcheck.timer (每 5 分钟)\n' "$G" "运行中" "$N"
    else
      printf '  %b%-10s%b proxy-healthcheck.timer\n' "$R" "未运行" "$N"
    fi
  fi

  echo
  echo -e "${B}5. 订阅 DNS 配置${N}  ${D}(缺了会被 Google 判成中国大陆)${N}"
  local tdir="${SUB_DIR:-/var/www/proxy-sub}/${SUB_TOKEN:-}"
  if [ -z "${SUB_TOKEN:-}" ] || [ ! -d "$tdir" ]; then
    echo "  跳过: 没找到订阅目录 (执行 proxy sub 重新生成订阅)"
  else
    local dsub=0
    if [ -f "$tdir/clash.yaml" ]; then
      if grep -q 'enhanced-mode:[[:space:]]*fake-ip' "$tdir/clash.yaml" \
         && grep -q 'ipv6:[[:space:]]*false' "$tdir/clash.yaml"; then
        printf '  %b%-10s%b clash.yaml 已启用 fake-ip + 关闭 IPv6\n' "$G" "通过" "$N"
      else
        printf '  %b%-10s%b clash.yaml 缺 fake-ip/IPv6 配置\n' "$R" "缺失" "$N"; dsub=1
      fi
    fi
    if [ -f "$tdir/singbox.json" ]; then
      if grep -q '"dns"' "$tdir/singbox.json" && grep -q 'hijack-dns' "$tdir/singbox.json"; then
        printf '  %b%-10s%b singbox.json DNS 已接管\n' "$G" "通过" "$N"
      else
        printf '  %b%-10s%b singbox.json 缺 DNS 接管\n' "$R" "缺失" "$N"; dsub=1
      fi
    fi
    if [ "$dsub" = "1" ]; then
      echo -e "  ${Y}执行 proxy sub 可重新生成带 DNS 的订阅${N}"
      bad=1
    fi
  fi

  echo -e "${B}6. 订阅服务暴露面${N}  ${D}(token 即凭据)${N}"
  if [ "$SUB_HTTP" = "1" ] && systemctl is-active --quiet proxy-sub 2>/dev/null; then
    if [ "${SUB_BIND:-127.0.0.1}" = "127.0.0.1" ]; then
      printf '  %b%-10s%b 只监听 127.0.0.1, 需 SSH 隧道才能取订阅\n' "$G" "通过" "$N"
    else
      printf '  %b%-10s%b 对 %s:%s 开放, 且是明文 HTTP —— token 在链路上可见\n' \
        "$Y" "注意" "$N" "$SUB_BIND" "${SUB_PORT:-?}"
      echo -e "  ${D}只在自己可信的网络里用; 不想开放就 systemctl disable --now proxy-sub${N}"
    fi
    # 老版本用的是 python3 -m http.server, 会在根路径列目录 = 直接泄露 token
    if grep -q 'http\.server' /etc/systemd/system/proxy-sub.service 2>/dev/null; then
      printf '  %b%-10s%b 订阅服务仍是旧版(http.server 会列目录, token 会泄露)\n' "$R" "危险" "$N"
      echo -e "  ${Y}执行 proxy sub 换成不列目录的新服务${N}"
      bad=1
    fi
  else
    echo "  未启用订阅 HTTP 服务"
  fi

  # 权限类问题可以就地修
  if [ -n "$VERIFY_FIX" ]; then
    if [ "$fix" = "1" ]; then
      echo
      while IFS='|' read -r a a2; do
        [ -n "$a" ] && chmod "$a2" "$a" 2>/dev/null && echo -e "  ${G}已修正${N} $a -> $a2"
      done <<< "$VERIFY_FIX"
      # 只清权限这一类问题, 不能把配置/服务/DNS 的失败一起抹掉
      perm_bad=0
    else
      echo
      echo -e "  ${Y}加 --fix 可自动修正上面的权限问题:${N} proxy verify --fix"
    fi
  fi
  [ "$perm_bad" = "1" ] && bad=1

  echo
  if [ "$bad" = "0" ]; then
    ok "自检通过: 二进制未被替换, 配置合法, 凭据权限正常, 订阅 DNS 已接管, 订阅服务未泄露"
  else
    warn "自检发现上面标红的问题, 按提示处理后再跑一次 proxy verify"
  fi
  echo
  return "$bad"
}

# ---------------- 诊断报告 ----------------
# 「用不了」的时候, 让用户在服务器上跑一条命令, 把结果整段贴出来。
# 报告是要外发的, 所以凭据一律先脱敏再落盘 —— 宁可少给点信息, 也不能把 UUID 带出去。
DIAG_SECRETS=()

# 登记一个需要脱敏的值; 太短的值(端口、1、0)会把正文误伤, 只收 8 位以上
diag_sec(){
  local s="${1:-}"
  [ "${#s}" -ge 8 ] && DIAG_SECRETS+=("$s")
  return 0
}

diag_redact(){
  local line s
  while IFS= read -r line || [ -n "$line" ]; do
    for s in ${DIAG_SECRETS[@]+"${DIAG_SECRETS[@]}"}; do
      # 引号包住 pattern: 密码里的 * ? 不会被当成通配符
      line="${line//"$s"/<已隐去>}"
    done
    printf '%s\n' "$line"
  done
}

strip_ansi(){ sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'; }

# 三个内核的 version 输出格式各不相同, 统一抠出版本号:
#   xray      -> "Xray 26.3.27 (Xray, Penetrates Everything.)"
#   hysteria  -> "v2.13.0"
#   sing-box  -> "sing-box version 1.14.4"
bin_ver(){
  local b="$1" v
  [ -x "$b" ] || { printf '无'; return 0; }
  v=$("$b" version 2>/dev/null | head -1 \
      | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1)
  printf '%s' "${v#v}" | grep . || printf '未知'
}

cmd_diag(){
  need_root
  local out="${1:-/root/proxy-diag-$(date +%Y%m%d-%H%M%S).txt}"
  local raw installed=0 u act en rst found
  raw=$(mktemp 2>/dev/null) || die "无法创建临时文件"

  load_state >/dev/null 2>&1 && installed=1
  SERVER_IP="${SERVER_IP:-$(get_server_ip 2>/dev/null)}"

  # 先把所有凭据登记进去, 后面整份报告一次性脱敏
  diag_sec "${UUID:-}";      diag_sec "${PRIV:-}";        diag_sec "${PUB:-}"
  diag_sec "${SID:-}";       diag_sec "${HY2_PASS:-}";    diag_sec "${OBFS_PASS:-}"
  diag_sec "${SS2022_PASS:-}"; diag_sec "${ANYTLS_PASS:-}"; diag_sec "${TUIC_PASS:-}"
  diag_sec "${TUIC_UUID:-}"; diag_sec "${SUB_TOKEN:-}";   diag_sec "${EGRESS_URL:-}"
  # 多设备凭据在 users.txt 里(每个设备一个 UUID), 只登记 state 里的主 UUID 不够,
  # 否则 [9]/[10] 段把内核日志原文贴出去时, 别的设备 UUID 会原样外泄。
  local du
  if [ -f "$USERS_FILE" ]; then
    while IFS='|' read -r du _; do [ -n "$du" ] && diag_sec "$du"; done < "$USERS_FILE"
  fi

  info "收集诊断信息 (大约 20-40 秒) ..."

  {
    echo "Proxy Node 诊断报告"
    echo "================================================================"
    printf '脚本版本 : %s (%s)\n' "$SCRIPT_VERSION" "$BUILD_DATE"
    printf '脚本路径 : %s\n' "$(running_script_path)"
    printf '生成时间 : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '主机名   : %s\n' "$(hostname 2>/dev/null)"
    printf '报告说明 : 所有 UUID / 密码 / token 已替换为 <已隐去>\n'
  } >> "$raw"

  {
    echo
    echo "[1] 系统"
    printf '  发行版   : %s\n' "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-未知}")"
    printf '  内核     : %s\n' "$(uname -r)"
    printf '  架构     : %s\n' "$(uname -m)"
    printf '  虚拟化   : %s\n' "$(systemd-detect-virt 2>/dev/null || echo 未知)"
    printf '  运行时长 : %s\n' "$(uptime -p 2>/dev/null || echo 未知)"
    printf '  内存     : %s\n' "$(free -m 2>/dev/null | awk '/Mem:/{printf "%sMB 总 / %sMB 可用", $2, $7}')"
    printf '  磁盘     : %s\n' "$(df -h / 2>/dev/null | awk 'NR==2{printf "%s 总 / %s 可用 (%s)", $2, $4, $5}')"
    printf '  负载     : %s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    printf '  swap     : %s\n' "$(free -m 2>/dev/null | awk '/Swap:/{printf "%sMB", $2}')"
  } >> "$raw"

  {
    echo
    echo "[2] 安装状态"
    if [ "$installed" = "1" ]; then
      printf '  状态     : 已安装\n'
      printf '  安装时间 : %s\n' "${INSTALLED_AT:-未知}"
      printf '  协议组合 : %s\n' "${PROTOCOLS:-未知}"
      printf '  备注名   : %s\n' "${NODE_NAME:-未知}"
      printf '  伪装目标 : %s\n' "${DEST:-未设置}"
      printf '  端口     : reality=%s hy2=%s ss2022=%s anytls=%s tuic=%s\n' \
        "${VLESS_PORT:-?}" "${HY2_PORT:-?}" "${SS2022_PORT:-?}" "${ANYTLS_PORT:-?}" "${TUIC_PORT:-?}"
      printf '  混淆/跳跃: obfs=%s hop=%s\n' \
        "$([ "${ENABLE_OBFS:-0}" = "1" ] && echo 已开 || echo 关)" "${HY2_HOP:-关}"
      printf '  上游出口 : %s\n' "$([ -n "${EGRESS_URL:-}" ] && echo 已配置 || echo 未配置)"
      printf '  订阅服务 : %s  bind=%s port=%s\n' \
        "$([ "${SUB_HTTP:-0}" = "1" ] && echo 已启用 || echo 未启用)" "${SUB_BIND:-?}" "${SUB_PORT:-?}"
      printf '  设备数   : %s\n' "$([ -f "$USERS_FILE" ] && wc -l < "$USERS_FILE" || echo 0)"
      printf '  二进制   : xray %s | hysteria %s | sing-box %s\n' \
        "$(bin_ver "$XRAY_BIN")" "$(bin_ver "$HY2_BIN")" "$(bin_ver "$SB_BIN")"
    else
      printf '  状态     : 未安装, 或 %s 不可读\n' "$STATE_FILE"
    fi
  } >> "$raw"

  {
    echo
    echo "[3] 服务状态"
    found=0
    for u in xray hysteria-server sing-box proxy-sub hy2-hop proxy-healthcheck.timer; do
      systemctl cat "$u" >/dev/null 2>&1 || continue
      found=1
      act=$(systemctl is-active "$u" 2>/dev/null)
      en=$(systemctl is-enabled "$u" 2>/dev/null)
      rst=$(systemctl show "$u" -p NRestarts --value 2>/dev/null)
      printf '  %-26s %-9s %-9s 重启次数=%s\n' "$u" "${act:-?}" "${en:-?}" "${rst:-?}"
    done
    [ "$found" = "1" ] || echo "  (没有任何相关 systemd 单元)"
  } >> "$raw"

  {
    echo
    echo "[4] 监听端口"
    ss -tulnp 2>/dev/null | grep -E 'xray|hysteria|sing-box|python3' \
      | sed 's/^/  /' || echo "  (没有 xray/hysteria/sing-box 在监听)"
  } >> "$raw"

  {
    echo
    echo "[5] 配置校验"
    if [ "$installed" = "1" ]; then
      if proto_on reality && [ -x "$XRAY_BIN" ]; then
        if "$XRAY_BIN" run -test -c "$XRAY_CFG" >/dev/null 2>&1; then
          echo "  xray      : 通过"
        else
          echo "  xray      : 失败"
          "$XRAY_BIN" run -test -c "$XRAY_CFG" 2>&1 | tail -6 | sed 's/^/              /'
        fi
      fi
      if sb_enabled && [ -x "$SB_BIN" ]; then
        if "$SB_BIN" check -c "$SB_CFG" >/dev/null 2>&1; then
          echo "  sing-box  : 通过"
        else
          echo "  sing-box  : 失败"
          "$SB_BIN" check -c "$SB_CFG" 2>&1 | tail -6 | sed 's/^/              /'
        fi
      fi
      proto_on hy2 && echo "  hysteria  : 无 check 子命令, 见 [10] 日志"
    else
      echo "  跳过(未安装)"
    fi
  } >> "$raw"

  {
    echo
    echo "[6] 网络与出口"
    printf '  出口 IPv4      : %s\n' "$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo 获取失败)"
    printf '  state 记录 IP  : %s\n' "${SERVER_IP:-无}"
    if [ -n "${DEST:-}" ] && command -v openssl >/dev/null 2>&1; then
      printf '  伪装站握手     : %s  (版本|ALPN)\n' "$(dest_tls_info "$DEST")"
    fi
    printf '  到 Google 204  : %s\n' "$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 https://www.google.com/generate_204 2>/dev/null || echo 000)"
    printf '  到 CF 204      : %s\n' "$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 http://cp.cloudflare.com/generate_204 2>/dev/null || echo 000)"
    printf '  DNS 解析       : %s\n' "$(getent hosts www.bing.com 2>/dev/null | head -1 | awk '{print $1}' | grep . || echo 失败)"
    if [ -n "${EGRESS_URL:-}" ]; then
      local egip
      egip=$(egress_probe_ip 2>/dev/null | head -1)
      printf '  上游出口可用   : %s\n' "${egip:-探测失败}"
    fi
  } >> "$raw"

  {
    echo
    echo "[7] 时间 (偏差过大会导致 TLS 握手失败)"
    printf '  本地时间 : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '  UTC 时间 : %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf '  时区     : %s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 未知)"
    printf '  NTP 同步 : %s\n' "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 未知)"
    local srv now skew
    srv=$(curl -sI --max-time 8 https://www.cloudflare.com 2>/dev/null \
          | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r' | head -1)
    if [ -n "$srv" ]; then
      now=$(date +%s)
      skew=$(( now - $(date -d "$srv" +%s 2>/dev/null || echo "$now") ))
      if [ "${skew#-}" -gt 60 ] 2>/dev/null; then
        printf '  与 CF 时差 : %s 秒  <== 偏差过大, TLS 握手会失败, 执行 proxy optimize time 校时\n' "$skew"
      else
        printf '  与 CF 时差 : %s 秒\n' "$skew"
      fi
    fi
  } >> "$raw"

  {
    echo
    echo "[8] 防火墙"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
      ufw status 2>/dev/null | head -20 | sed 's/^/  /'
    fi
    if command -v nft >/dev/null 2>&1; then
      echo "  --- nftables (前 25 行) ---"
      nft list ruleset 2>/dev/null | head -25 | sed 's/^/    /'
    fi
    echo "  --- iptables filter (前 25 行) ---"
    iptables -S 2>/dev/null | head -25 | sed 's/^/    /' || echo "    (读不到)"
  } >> "$raw"

  {
    echo
    echo "[9] 协议实测 (用订阅里同一份配置, 从本机回环发起)"
    if [ "$installed" = "1" ]; then
      # 报告是纯文本, 颜色转义会变成一堆 ^[[32m。
      # 不能用管道过滤(子 shell 里 SELFTEST_* 会丢), 所以临时把颜色变量清空。
      local _g="$G" _r="$R" _n="$N"
      G=""; R=""; N=""
      selftest_protocols 2>&1
      G="$_g"; R="$_r"; N="$_n"
      echo "  小结: 通过 ${SELFTEST_PASS:-0} / 不通 ${SELFTEST_FAIL:-0} / 跳过 ${SELFTEST_SKIP:-0}"
    else
      echo "  跳过(未安装)"
    fi
  } >> "$raw"

  {
    echo
    echo "[10] 最近日志 (只挑告警/错误行)"
    found=0
    for u in xray hysteria-server sing-box proxy-sub; do
      systemctl cat "$u" >/dev/null 2>&1 || continue
      found=1
      echo "  --- ${u} ---"
      journalctl -u "$u" -n 300 --no-pager -o cat 2>/dev/null \
        | grep -iE 'error|warn|fail|fatal|refus|timeout|denied' | tail -12 | sed 's/^/    /'
      echo "    (最近 5 行原文)"
      journalctl -u "$u" -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/    /'
    done
    [ "$found" = "1" ] || echo "  (无相关单元)"
  } >> "$raw"

  diag_redact < "$raw" > "$out"
  rm -f "$raw"
  chmod 600 "$out"

  echo
  hr
  ok "诊断报告已生成: ${out}"
  hr
  echo -e "${D}全部凭据已脱敏, 可以直接把内容整段发出去。查看:${N}"
  echo "  cat ${out}"
  echo
  echo -e "${D}报告含服务器公网 IP 与端口, 外发前可自行再核对一遍${N}"
  echo
}

cmd_restart(){
  need_root
  load_state || die "尚未安装"
  local svcs=() s bad=0
  proto_on reality && svcs+=(xray)
  proto_on hy2     && svcs+=(hysteria-server)
  sb_enabled       && svcs+=(sing-box)
  [ ${#svcs[@]} -gt 0 ] || die "没有已启用的协议, 先执行: proxy wizard"
  systemctl restart "${svcs[@]}" 2>/dev/null
  sleep 2
  for s in "${svcs[@]}"; do
    printf '  %-16s : %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
    systemctl is-active --quiet "$s" || bad=1
  done
  if [ "$bad" = "1" ]; then
    warn "有服务未启动, 查看: proxy logs <xray|hy2|sb>"
  else
    ok "全部服务已重启"
  fi
}

cmd_logs(){
  need_root
  local which="${1:-xray}" unit=""
  case "$which" in
    hy2|hysteria)        unit="hysteria-server" ;;
    sb|singbox|sing-box) unit="sing-box" ;;
    *)                   unit="xray" ;;
  esac
  if ! systemctl cat "${unit}.service" >/dev/null 2>&1; then
    warn "${unit} 未安装(当前协议里没有它), 可用: xray / hy2 / sb"
    return 1
  fi
  journalctl -u "$unit" -f -n 50
}

# 通过本地 REALITY 隧道实测真实出口 IP
egress_ip_via_proxy(){
  local tdir; tdir=$(mktemp -d 2>/dev/null) || { echo ""; return 0; }
  cat > "$tdir/c.json" <<EOF
{
  "log": { "loglevel": "error" },
  "inbounds": [ { "port": 10897, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ {
    "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": ${VLESS_PORT},
      "users": [ { "id": "$(primary_uuid)", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "${DEST}", "fingerprint": "chrome",
        "publicKey": "${PUB}", "shortId": "${SID}", "spiderX": "/" } }
  } ]
}
EOF
  $XRAY_BIN -c "$tdir/c.json" >"$tdir/c.log" 2>&1 &
  local pid=$! ip=""
  sleep 3
  ip=$(curl -s --socks5-hostname 127.0.0.1:10897 --max-time 12 https://api.ipify.org 2>/dev/null \
    || curl -s --socks5-hostname 127.0.0.1:10897 --max-time 12 https://ifconfig.me 2>/dev/null || echo "")
  kill $pid >/dev/null 2>&1; wait $pid 2>/dev/null
  rm -rf "$tdir"
  echo "$ip" | tr -d '[:space:]'
}

# 把当前 EGRESS_URL 落到实际配置里并重启服务。客户端配置不需要改。
apply_egress(){
  # hysteria2 的 outbounds 只支持 direct/block, 没有"转发到上游代理"的能力。
  # 只开 hy2 时这个功能无解, 必须直说, 不能让人以为配好了。
  if ! proto_on reality && ! sb_enabled; then
    warn "当前只开了 Hysteria2: 它不支持上游代理, egress 不会生效"
    warn "想用住宅出口, 请再开一个 reality 或 anytls/tuic: PROTOCOLS=reality,hy2 bash setup-proxy.sh install"
    return 0
  fi
  if proto_on reality; then
    write_xray_config "${DEST:-www.bing.com}"
    systemctl restart xray >/dev/null 2>&1
  fi
  if sb_enabled; then
    write_singbox_config
    systemctl restart sing-box >/dev/null 2>&1
  fi
  sleep 1
}

# proxy egress —— 给服务端接一层上游出口
# 这是"不被 TikTok 判机房"的唯一技术解法: 换掉最终出口 IP, 而不是改协议/端口/SNI。
cmd_egress(){
  need_root
  load_state || die "尚未安装"
  local arg="${1:-}" line scheme host port ip

  if [ -z "$arg" ]; then
    if [ -n "${EGRESS_URL:-}" ]; then
      line=$(parse_egress) && IFS='|' read -r scheme host port _ <<< "$line"
      echo "上游出口      : ${scheme}://${host}:${port}   (账号密码已隐藏)"
      ip=$(egress_probe_ip)
      if [ -n "$ip" ]; then
        ok "实测出口 IP   : ${ip}"
        [ "$ip" = "$SERVER_IP" ] && warn "和本机 IP 相同, 这个代理没有真正改变出口"
      else
        warn "上游出口当前不通(地址失效 / 账号过期 / 本机到它被墙)"
      fi
    else
      info "未配置上游出口, 流量直接从本机 ${SERVER_IP} 出去"
      echo "  换住宅出口: proxy egress socks5://用户:密码@主机:端口"
      echo "  关闭出口  : proxy egress off"
    fi
    return 0
  fi

  case "$arg" in
    off|none|clear)
      [ -n "${EGRESS_URL:-}" ] || { info "本来就没配上游出口"; return 0; }
      EGRESS_URL=""
      save_state
      apply_egress
      ok "已关闭上游出口, 恢复本机直连"
      return 0 ;;
  esac

  # 配置是直接拼进 JSON 的, 引号和反斜杠会把整份配置写坏, 提前拦住
  case "$arg" in
    *'"'*|*\\*|*"'"*) die "地址里不能包含双引号 / 反斜杠 / 单引号" ;;
  esac
  if ! line=$(parse_egress "$arg"); then
    die "地址格式不对, 应形如 socks5://用户:密码@1.2.3.4:1080 或 http://用户:密码@1.2.3.4:8080"
  fi
  EGRESS_URL="$arg"
  info "测试上游出口连通性 ..."
  ip=$(egress_probe_ip)
  if [ -z "$ip" ]; then
    EGRESS_URL=""
    die "连不上这个上游代理: 检查地址/端口/账号密码, 以及本机到它是否可达"
  fi
  save_state
  apply_egress
  ok "上游出口已生效, 实测出口 IP: ${ip}"
  if [ "$ip" = "$SERVER_IP" ]; then
    warn "出口 IP 和本机相同, 说明这个代理是透明转发, 对平台判定没有帮助"
  fi
  echo "  用 proxy audit 看这个 IP 的机房/代理标记"
}

cmd_audit(){
  need_root
  load_state || die "尚未安装"
  local dnsbl=0
  [ "${1:-}" = "--dnsbl" ] && dnsbl=1
  # 换过 IP 的机器上, state.env 里存的是旧地址, 拿它查 PTR / 地区 / 时区比对
  # 全是错的。以本机当前探测到的为准, 并提示用户链接还是旧的。
  local live_ip
  live_ip=$(get_server_ip 2>/dev/null)
  if [ -n "$live_ip" ] && [ -n "$SERVER_IP" ] && [ "$live_ip" != "$SERVER_IP" ]; then
    warn "本机公网 IP 已变化: ${SERVER_IP} -> ${live_ip}"
    echo -e "  ${D}订阅链接里仍是旧 IP; 确认无误后执行 proxy install 重新生成${N}"
    SERVER_IP="$live_ip"
  fi
  SERVER_IP="${SERVER_IP:-$live_ip}"

  echo
  hr
  echo -e "${M}出口 IP 实测${N}"
  hr
  echo "节点 IP        : ${SERVER_IP}"
  # egress_ip_via_proxy 起的是 VLESS/REALITY 临时客户端; 只开 hy2 / ss2022 的
  # 机器上它必然失败 —— 那是"这个协议没启用", 不是"服务坏了", 不能报成故障。
  local eip=""
  proto_on reality && eip=$(egress_ip_via_proxy)
  if ! proto_on reality; then
    echo -e "  ${D}未启用 REALITY, 跳过隧道出口实测(该项探测走 VLESS/REALITY 链路)${N}"
  elif [ -z "$eip" ]; then
    warn "隧道实测失败, 无法确认出口(检查服务是否正常: proxy status)"
  elif [ "$eip" = "$SERVER_IP" ]; then
    ok "隧道出口 IP    : ${eip}  (与本机一致, 无中转/无泄漏)"
  else
    if [ -n "${EGRESS_URL:-}" ]; then
      ok "隧道出口 IP    : ${eip}  (已配置上游出口, 与本机 ${SERVER_IP} 不同, 符合预期)"
    else
      warn "隧道出口 IP    : ${eip}  (与本机 ${SERVER_IP} 不同!)"
      echo "   说明流量经过了中转或存在泄漏, TikTok 会看到 ${eip} 这个地址"
    fi
  fi

  echo
  hr
  echo -e "${M}IP 画像${N}"
  hr
  local ptr
  ptr=$(getent hosts "$SERVER_IP" 2>/dev/null | awk '{print $2}' | head -1)
  if [ -n "$ptr" ]; then
    echo "反向解析 PTR   : ${ptr}"
  else
    warn "反向解析 PTR   : 无记录 (会提高可疑度, 可找服务商加一条)"
  fi

  local ipv6pub
  ipv6pub=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)
  if [ "${ipv6pub:-0}" -gt 0 ]; then
    warn "公网 IPv6      : 存在 ${ipv6pub} 个地址 (客户端订阅已按 IPv4 优先生成; 代理端口可能同时监听 IPv6, 建议在服务商侧关掉)"
  else
    ok "公网 IPv6      : 无 (不会出现 IPv6 泄漏)"
  fi

  # 平台看 IP 不只看归属公司, 更看"这段是不是机房"。ip-api 的 hosting 字段
  # 是一个参考口径, 和 TikTok / Google 各自的风控库不一定一致 ——
  # 实测同一台 RackNerd 机器这里给 hosting=false, 平台侧仍按机房处理。
  # 所以这里只作参考, 不作结论。
  # 有上游出口时要查"平台真正看到的那个 IP", 查本机 IP 没有意义。
  #
  # 一次请求把后面几节要用的字段全取回来(countryCode 给 Google 判定用,
  # timezone 给时区一致性用)。免费接口 45 次/分钟, 每节各查一次很容易被限速。
  local ipq="${eip:-$SERVER_IP}"
  local pr hst prx mob cc etz
  pr=$(curl -s --max-time 6 "http://ip-api.com/line/${ipq}?fields=hosting,proxy,mobile,countryCode,timezone" 2>/dev/null | tr -d '\r')
  hst=$(printf '%s\n' "$pr" | sed -n 1p)
  prx=$(printf '%s\n' "$pr" | sed -n 2p)
  mob=$(printf '%s\n' "$pr" | sed -n 3p)
  cc=$(printf '%s\n' "$pr" | sed -n 4p | tr '[:lower:]' '[:upper:]')
  etz=$(printf '%s\n' "$pr" | sed -n 5p)
  # 校验: 接口失败时会返回 "fail" 或空行, 别让这些值流到下游
  case "$cc" in [A-Z][A-Z]) ;; *) cc="" ;; esac
  case "$etz" in */*) ;; *) etz="" ;; esac
  if [ -n "$cc" ]; then
    echo "出口国家/地区  : ${cc}$(cc_note "$cc")"
  fi
  case "$hst" in
    true)  warn "IP 类型        : 机房段 (hosting=true, 参考口径) —— 平台大概率按机房处理, 换协议换端口都改不了" ;;
    false) ok   "IP 类型        : 非机房段 (hosting=false, 参考口径) —— 平台侧更接近家宽, 但平台另有数据库, 仅供参照" ;;
    *)
      # ip-api 免费接口会限速, 也会对部分网段直接不返回(实测有机器查出来是空的)。
      # 这时不要只甩一句"查询失败"就完事 —— 上面已经拿到 PTR 了, 主机名里的
      # 机房关键字是本地就能算的第二信号, 不用再发一次请求。
      # 两段匹配: 先认机房品牌名(hostpapa/vultr/contabo 这类, 出现在哪都算),
      # 再认带边界的通用词(vps/server/dedicated...), 避免 myhostname 这种误伤。
      if printf '%s' "$ptr" | grep -qiE '(hostpapa|colocrossing|psychz|quadranet|vultr|linode|digitalocean|contabo|hetzner|amazonaws|choopa|buyvm|racknerd|hosthatch|netcup|leaseweb|serverius|worldstream|melbicom|aeza|justhost|oraclecloud|alibabacloud|tencentcloud|(^|[^a-z])(vps|vds|dedicated|bare-?metal|colo|hosting|cloud|server)([^a-z]|$))'; then
        warn "IP 类型        : 疑似机房段 (ip-api 无返回, 按 PTR \"${ptr}\" 推断)"
        echo "   依据: 主机名含机房品牌或通用词。这是本地推断, 平台侧结论以实际表现为准"
      else
        echo "IP 类型        : 查询失败(接口限速或不可达), PTR 也看不出机房特征"
      fi ;;
  esac
  [ "$prx" = "true" ] && warn "代理标记       : 已被标为 proxy/VPN (比机房标记更难绕)"
  [ "$mob" = "true" ] && echo "移动网络标记   : mobile=true"

  # Google 的"送中"是它按出口 IP 判地区。服务端直连一次就能看出它怎么认这台机器。
  # 这里踩过三个坑, 都会把"已经送中"误报成"正常":
  #  ① 连不上(HTTP 000) 和 连上但没跳转 是两回事 —— 只看 redirect_url 会把前者当成后者
  #  ② Google 现在多数情况不再回 302, 而是回 200 + 页面里 JS 跳转。只看 header 必然漏报
  #  ③ 只发 Accept-Language: en-US。真实浏览器发的是 zh-CN, Google 对"IP 归属模糊 +
  #     中文用户"会额外偏向港区 —— 拿 en-US 探等于替用户美颜。同时 curl 默认 UA 是
  #     curl/8.x, Google 见到就给一套更保守的响应。
  # 所以: 用真实 UA, 先 zh-CN 再 en-US, 每次先看 header 跳转、再看页面里的 ccTLD 域名,
  # 任一命中即判定。gdom 记命中的域名, gsrc 记是 header 还是页面命中的(输出要诚实)。
  local gcode="" gdom="" gsrc="" _lang _r _c _h
  for _lang in 'zh-CN,zh;q=0.9' 'en-US,en;q=0.9'; do
    _r=$(curl -s -o /dev/null -w '%{http_code}|%{redirect_url}' --max-time 8 \
         -H "Accept-Language: ${_lang}" \
         -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
         'https://www.google.com/' 2>/dev/null)
    _c=$(printf '%s' "$_r" | cut -d'|' -f1)
    [ -n "$_c" ] && [ "$_c" != "000" ] && gcode="$_c"
    _h=$(printf '%s' "$_r" | cut -d'|' -f2-)
    [ -n "$_h" ] && gsrc="header"
    if [ -z "$_h" ] && [ -n "$_c" ] && [ "$_c" != "000" ]; then
      _h=$(curl -s --max-time 8 -H "Accept-Language: ${_lang}" \
           -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
           'https://www.google.com/' 2>/dev/null | head -c 40000 \
           | grep -oE "$GOOGLE_TLD_RE" \
           | head -1)
      [ -n "$_h" ] && gsrc="页面"
    fi
    if [ -n "$_h" ]; then
      gdom=$(printf '%s' "$_h" | sed -E 's#^https?://##; s#^www\.##; s#[/"].*$##')
      break
    fi
  done
  case "${gcode:-000}" in
    000|"")
      warn "Google 地区    : 连不上 (HTTP ${gcode:-000}), 无法判定 —— 先修出口: proxy status" ;;
    *)
      # 判"有没有被换区"要拿出口国家做基准, 不能把 google.com.hk 一律当送中。
      # 香港 / 澳门的机器 Google 本来就该跳 .com.hk, 一律报送中等于 100% 误报。
      if [ "$cc" = "CN" ]; then
        # 出口在中国大陆 = 流量根本没出去, 这时看 Google 跳哪个域名没意义
        warn "Google 地区    : 出口 IP 在中国大陆 —— 代理没生效, 或 egress 指到了国内中转"
      else
        local gwant
        gwant=$(google_cc_tld "$cc")
        case "$gdom" in
          # google.cn 是 Google 中国的残骸, 现在一律跳 .com.hk。见到它就是送中。
          google.cn)
            warn "Google 地区    : 被判为中国大陆 (${gsrc}跳 ${gdom}) —— 这台机器的 IP 在 Google 库里是 CN" ;;
          google.com.hk)
            if [ "$cc" = "HK" ] || [ "$cc" = "MO" ]; then
              ok "Google 地区    : 跳 ${gdom} —— 出口在 ${cc}, 这是当地域名, 正常"
            else
              warn "Google 地区    : 被判为中国大陆 (${gsrc}跳 ${gdom}) —— 出口登记在 ${cc:-未知}, 但 Google 判成 CN"
            fi ;;
          # 跳到 google.com 本身(带 gws_rd=cr 那种)等于"Google 决定不换区", 属正常。
          # 不这么判的话, 一条"跳转到 google.com"的噪音会让人以为出了事。
          ""|google.com)
            if [ -z "$cc" ]; then
              echo "Google 地区    : 未跳转 (HTTP ${gcode}, 出口国家没查到, 无法比对)"
            elif [ "$gwant" = "google.com" ]; then
              ok "Google 地区    : 未跳转 (HTTP ${gcode}) —— 出口 ${cc}, 这个国家本来就用 google.com"
            else
              ok "Google 地区    : 未跳转 (HTTP ${gcode}) —— 出口 ${cc}, 预期 ${gwant} 但 Google 没换区, 通常没问题"
            fi ;;
          *)
            if [ "$gdom" = "$gwant" ]; then
              ok "Google 地区    : ${gsrc}跳 ${gdom} —— 与出口 ${cc} 一致, 正常"
            elif [ -z "$cc" ]; then
              echo "Google 地区    : ${gsrc}跳转到 ${gdom} (HTTP ${gcode}, 出口国家没查到, 无法比对)"
            else
              warn "Google 地区    : ${gsrc}跳 ${gdom}, 但出口在 ${cc} (预期 ${gwant}) —— 可能被判成 ${gdom} 所在地区"
            fi ;;
        esac
      fi ;;
  esac

  echo
  hr
  echo -e "${M}系统状态${N}"
  hr
  local ntp
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  case "$ntp" in
    yes) ok "时间同步       : 已同步 ($(date '+%Z %z'))" ;;
    no)  warn "时间同步       : 未同步 (REALITY 依赖时间校验, 请开 NTP)" ;;
    *)   echo "时间同步       : $(date '+%Z %z')" ;;
  esac

  # 说清楚: 远程平台看不到 VPS 的系统时区 —— 代理只转发字节流, TLS 报文里没有时区。
  # 这一项不是风控项, 只是排障时的可读性: 机器在东京、日志却按上海时间走,
  # 对日志容易对错时间。真正要跟 IP 对齐的是客户端(手机/浏览器)的时区。
  # etz 已经在上面那次合并请求里拿到了, 查不到才单独再探一次(走另外两家接口)。
  local ltz
  ltz=$(cur_timezone)
  [ -n "$etz" ] || etz=$(detect_exit_tz "$ipq")
  if [ -z "$etz" ]; then
    echo "时区一致性     : 出口时区查询失败, 跳过 (不影响其它结论)"
  elif [ "$etz" = "$ltz" ]; then
    ok "时区一致性     : ${ltz} (与出口 IP 一致)"
  else
    echo "时区一致性     : 系统 ${ltz} / 出口 ${etz} —— 不一致"
    echo -e "   ${D}只影响本机日志显示, 平台看不到 VPS 时区。想让日志跟 IP 对上: proxy timezone auto${N}"
  fi
  echo "拥塞控制       : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo "journald 上限  : $(journalctl --disk-usage 2>/dev/null | sed 's/.*take up //')"
  echo "磁盘占用       : $(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
  echo "内存           : $(free -m | awk '/Mem:/{print $3"MB / "$2"MB"}')"

  echo
  hr
  echo -e "${M}链路质量(判断「为什么慢」看这里)${N}"
  hr
  local ndrop retr outseg
  ndrop=$(awk 'NR>2{gsub(":"," "); s+=$5+$13} END{print s+0}' /proc/net/dev 2>/dev/null)
  echo "网卡丢包       : ${ndrop:-0}  (累计; 涨得快=带宽或收包队列不足)"
  if command -v nstat >/dev/null 2>&1; then
    retr=$(nstat -az TcpRetransSegs 2>/dev/null | awk '/TcpRetransSegs/{print $2}')
    outseg=$(nstat -az TcpOutSegs 2>/dev/null | awk '/TcpOutSegs/{print $2}')
    if [ -n "$retr" ] && [ -n "$outseg" ] && [ "$outseg" -gt 0 ] 2>/dev/null; then
      awk -v r="$retr" -v o="$outseg" 'BEGIN{
        p=r*100/o;
        printf "TCP 重传率     : %.2f%% (%d/%d)", p, r, o;
        if (p > 2) printf "  <- 偏高, 说明这条线路在丢包, 换线路比换协议有用\n";
        else printf "  (正常)\n";
      }'
    fi
  fi
  echo "UDP 缓冲上限   : $(sysctl -n net.core.rmem_max 2>/dev/null) / udp_mem $(sysctl -n net.ipv4.udp_mem 2>/dev/null | tr -s ' ' ' ')"

  if [ "$dnsbl" = "1" ]; then
    echo
    hr
    echo -e "${M}反垃圾库查询 (仅 DNS 查询, 不涉及账号)${N}"
    hr
    local rev r
    rev=$(echo "$SERVER_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
    r=$(getent hosts "${rev}.zen.spamhaus.org" 2>/dev/null | awk '{print $1}' | head -1)
    case "$r" in
      "")              ok "Spamhaus ZEN   : 未列入" ;;
      127.255.255.*)   warn "Spamhaus ZEN   : 查询被拒(公共 DNS 限制), 换本地 DNS 再试" ;;
      127.0.0.*)       warn "Spamhaus ZEN   : 已列入 ${r}" ;;
      *)               echo "Spamhaus ZEN   : ${r}" ;;
    esac
  else
    echo
    echo -e "${D}反垃圾库查询默认关闭(会把 IP 提交给第三方 DNS 库)。需要时: proxy audit --dnsbl${N}"
  fi

  echo
  hr
  echo -e "${M}客户端侧检查清单 (服务端改不了, 但直接影响账号安全)${N}"
  hr
  cat <<'CHECK'
  [ ] 关闭 WebRTC         浏览器里 WebRTC 会绕过代理暴露真实 IP
  [ ] 关闭 IPv6           手机/电脑网络设置里关掉, 避免绕过代理
  [ ] DNS 别乱改         小火箭只有一个 DNS 覆写且全局生效, 填境外 DNS 会让
                          GEOIP 分流把国内流量也判成国外; 留空最稳
                         v2rayN 有直连/远程两个入口, 才需要分开填
  [ ] 时区/语言/地区一致  做哪个区就全设那个区, 三者必须对得上
  [ ] 一号一 IP           多个账号共用同一出口 IP 是最典型的关联信号
  [ ] 固定不切换          频繁换 IP 会触发异常登录
  [ ] 指纹浏览器          多账号运营不要用同一个浏览器指纹
CHECK
  echo
}

# ---------------- 多设备凭据管理 ----------------
user_vless_link(){
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s-%s' \
    "$1" "$SERVER_IP" "$VLESS_PORT" "$DEST" "$PUB" "$SID" "$NODE_NAME" "$2"
}

# 输出某个设备的全部协议链接(只输出已启用的协议)
user_links_for(){
  local u="$1" name="$2" hb ui
  if proto_on reality; then
    user_vless_link "$u" "$name"
    echo
  fi
  if proto_on hy2; then
    hb="hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=${DEST}"
    [ -n "${HY2_HOP:-}" ] && hb="${hb}&mport=${HY2_HOP}"
    if [ "$ENABLE_OBFS" = "1" ]; then
      hb="${hb}&obfs=salamander&obfs-password=${OBFS_PASS}"
    fi
    if [ -n "${HY2_PIN:-}" ]; then
      hb="${hb}&insecure=1&pinSHA256=${HY2_PIN}"
    else
      hb="${hb}&insecure=1"
    fi
    printf '%s#%s-%s-HY2\n' "$hb" "$NODE_NAME" "$name"
  fi
  if proto_on ss2022; then
    ui=$(printf '2022-blake3-aes-128-gcm:%s' "$(ss_pass_for "$u")" \
      | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    printf 'ss://%s@%s:%s#%s-%s-SS2022\n' "$ui" "$SERVER_IP" "$SS2022_PORT" "$NODE_NAME" "$name"
  fi
  if proto_on anytls; then
    printf 'anytls://%s@%s:%s?sni=%s&insecure=1#%s-%s-AnyTLS\n' \
      "$(derive_hex "$u")" "$SERVER_IP" "$ANYTLS_PORT" "$DEST" "$NODE_NAME" "$name"
  fi
  if proto_on tuic; then
    printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr&allow_insecure=1#%s-%s-TUIC\n' \
      "$u" "$(derive_hex "$u")" "$SERVER_IP" "$TUIC_PORT" "$DEST" "$NODE_NAME" "$name"
  fi
}

# 设备增删后必须重载内核:
# 只重写 xray 的话, 新设备在 anytls/tuic/ss2022 上依然进不来,
# 被吊销的设备也还能继续用这三个协议 —— 等于吊销没生效。
reload_after_user_change(){
  local bad=0
  if proto_on reality; then
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1
  fi
  if sb_enabled; then
    write_singbox_config
    systemctl restart sing-box >/dev/null 2>&1
  fi
  sleep 2
  proto_on reality && { systemctl is-active --quiet xray || bad=1; }
  sb_enabled       && { systemctl is-active --quiet sing-box || bad=1; }
  # 订阅也要跟着重生成: 主凭据就是订阅里那一条, 增删设备后不刷新的话,
  # 新设备导入订阅看不到自己, 删掉主设备后订阅还留着旧 UUID。
  # 每次 proxy user 都是新进程, load_state 只 source state.env, 里面没有
  # VLESS_LINK / HY2_LINK 等键。少了 gen_links, gen_sub_files 里裸引用这些链接
  # 会在 set -u 下直接退出 —— 表现为增删设备后订阅没刷新、服务却已经重启了。
  gen_links
  gen_sub_files >/dev/null 2>&1 || warn "订阅重新生成失败, 手动执行一次: proxy sub"
  return "$bad"
}

# 按名字(第2列)或 UUID 前缀(第1列)找一行
find_user_line(){
  awk -F'|' -v k="$1" '$2==k || ($1!="" && index($1,k)==1) {print; exit}' "$USERS_FILE"
}

cmd_user(){
  need_root
  load_state || die "尚未安装"
  ensure_users_file
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  local sub="${1:-list}"

  case "$sub" in
    add)
      local name="${2:-}"
      [ -n "$name" ] || die "用法: proxy user add <名字>   例如 proxy user add iPhone"
      name="${name//|/_}"
      # 名字会写进 users.txt(竖线分隔) 和两份 JSON, 控制字符直接清掉
      name=$(printf '%s' "$name" | tr -d '\000-\037\177')
      [ -n "$name" ] || die "名字不能为空"
      [ -z "$(find_user_line "$name")" ] || die "已存在同名凭据: ${name}"
      local nu; nu=$(gen_uuid)
      printf '%s|%s|%s\n' "$nu" "$name" "$(date '+%Y-%m-%d')" >> "$USERS_FILE"
      reload_after_user_change || warn "内核重载异常, 凭据已写入 ${USERS_FILE}, 修好后执行 proxy restart"
      ok "已添加凭据: ${name}"
      echo
      user_links_for "$nu" "$name"
      echo
      ;;
    rm|del)
      local key="${2:-}" line
      [ -n "$key" ] || die "用法: proxy user rm <名字或UUID前缀>"
      [ "$(wc -l < "$USERS_FILE")" -gt 1 ] || die "至少保留一条凭据, 不能删光"
      line=$(find_user_line "$key")
      [ -n "$line" ] || die "未找到凭据: ${key}"
      grep -vxF "$line" "$USERS_FILE" > "${USERS_FILE}.tmp"
      mv -f "${USERS_FILE}.tmp" "$USERS_FILE"
      chmod 600 "$USERS_FILE"
      if ! reload_after_user_change; then
        warn "内核重载异常, 请检查: proxy status / proxy logs"
      fi
      ok "已吊销: $(echo "$line" | cut -d'|' -f2)  (该设备的旧链接立即失效)"
      ;;
    link)
      local key="${2:-}" line
      [ -n "$key" ] || die "用法: proxy user link <名字或UUID前缀>"
      line=$(find_user_line "$key")
      [ -n "$line" ] || die "未找到凭据: ${key}"
      user_links_for "$(echo "$line" | cut -d'|' -f1)" "$(echo "$line" | cut -d'|' -f2)"
      echo
      ;;
    *)
      echo
      hr
      echo -e "${M}设备凭据${N}  (每台设备一条, 丢设备可单独吊销)"
      hr
      printf '%-38s %-16s %s\n' "UUID" "名称" "添加日期"
      while IFS='|' read -r u n d; do
        [ -n "$u" ] || continue
        printf '%-38s %-16s %s\n' "$u" "$n" "$d"
      done < "$USERS_FILE"
      echo
      echo -e "${D}proxy user add <名字>     添加设备"
      echo -e "proxy user link <名字>    取该设备的链接"
      echo -e "proxy user rm <名字>      吊销该设备${N}"
      echo
      ;;
  esac
}

# ---------------- 备份 / 迁移 ----------------
cmd_backup(){
  need_root
  local out="${1:-/root/proxy-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/etc-proxy-node" "$tmp/etc-hysteria" "$tmp/etc-sing-box"

  [ -d "$STATE_DIR" ] && cp -a "$STATE_DIR/." "$tmp/etc-proxy-node/" 2>/dev/null
  [ -f /etc/hysteria/cert.pem ] && cp -a /etc/hysteria/cert.pem /etc/hysteria/key.pem "$tmp/etc-hysteria/" 2>/dev/null
  # sing-box 的自签证书也要带上, 否则迁移后 anytls/tuic 的指纹全变, 客户端要重导
  [ -f "$SB_CERT" ] && cp -a "$SB_CERT" "$SB_KEY" "$tmp/etc-sing-box/" 2>/dev/null
  [ -f /root/proxy-info.txt ] && cp -a /root/proxy-info.txt "$tmp/" 2>/dev/null
  # 没开对应协议时上面会留下空目录; 打包进去的话, restore 到新机器会凭空
  # 建出 /etc/hysteria、/etc/sing-box, 之后又被 residue_report 当成残留。
  rmdir "$tmp/etc-hysteria" 2>/dev/null || true
  rmdir "$tmp/etc-sing-box" 2>/dev/null || true

  if [ -z "$(ls -A "$tmp/etc-proxy-node" 2>/dev/null)" ]; then
    rm -rf "$tmp"
    die "没有可备份的内容, 先安装: bash setup-proxy.sh install"
  fi

  tar -czf "$out" -C "$tmp" . || { rm -rf "$tmp"; die "打包失败"; }
  chmod 600 "$out"
  rm -rf "$tmp"
  ok "已备份: ${out}  ($(du -h "$out" 2>/dev/null | awk '{print $1}'))"
  echo -e "${D}含全部凭据与私钥, 权限 600, 请勿外传${N}"
  echo -e "${D}迁移到新 VPS: 拷过去后 proxy restore <文件>${N}"
}

cmd_restore(){
  need_root
  local f="${1:-}" tmp
  [ -n "$f" ] && [ -f "$f" ] || die "用法: proxy restore /root/proxy-backup-xxx.tar.gz"

  # 防路径穿越: 含绝对路径或 .. 的备份包直接拒绝。
  # 不能写成 `tar -tzf "$f" | grep -q ...`: 脚本开了 pipefail, grep -q 命中后立刻退出,
  # tar 接着写就会吃到 SIGPIPE(141), 整条管道判为失败 —— 于是"包里有非法路径"这个
  # 分支反而不成立, 恶意包会被放行。先落到变量里再判断, 与管道退出码无关。
  local badpath
  badpath=$(tar -tzf "$f" 2>/dev/null | grep -E '^/|(^|/)\.\.(/|$)' | head -5)
  if [ -n "$badpath" ]; then
    printf '%s\n' "$badpath" | sed 's/^/    /' >&2
    die "备份包内含非法路径, 已中止"
  fi

  ask_yes "恢复会覆盖当前配置与凭据, 确认?" || { info "已取消"; return 0; }

  tmp=$(mktemp -d)
  tar -xzf "$f" -C "$tmp" || { rm -rf "$tmp"; die "解压失败"; }

  # 覆盖之前先验一遍包里的 state.env: 那份是坏的就等于把一套能用的安装换成
  # 一堆读不出来的凭据, 而且不可逆。校验不过时当前安装一个字都没动。
  local bstate="$tmp/etc-proxy-node/state.env" bk
  [ -f "$bstate" ] || { rm -rf "$tmp"; die "备份包内没有 state.env, 不像本脚本的备份, 已中止"; }
  bash -n "$bstate" 2>/dev/null \
    || { rm -rf "$tmp"; die "备份包内 state.env 语法损坏, 已中止(当前安装未改动)"; }
  for bk in UUID PRIV PUB SID SUB_TOKEN; do
    grep -q "^${bk}='" "$bstate" \
      || { rm -rf "$tmp"; die "备份包内 state.env 缺少 ${bk}, 已中止(当前安装未改动)"; }
  done

  # 旧状态留一份, 恢复中途失败时还能照着回滚
  if [ -d "$STATE_DIR" ]; then
    rm -rf "${STATE_DIR}.before-restore"
    cp -a "$STATE_DIR" "${STATE_DIR}.before-restore" 2>/dev/null || true
  fi

  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  [ -d "$tmp/etc-proxy-node" ] && cp -a "$tmp/etc-proxy-node/." "$STATE_DIR/" 2>/dev/null
  if [ -d "$tmp/etc-hysteria" ]; then
    mkdir -p /etc/hysteria
    cp -a "$tmp/etc-hysteria/." /etc/hysteria/ 2>/dev/null
    chmod 600 /etc/hysteria/key.pem 2>/dev/null || true
  fi
  if [ -d "$tmp/etc-sing-box" ]; then
    mkdir -p "$SB_DIR"; chmod 700 "$SB_DIR"
    cp -a "$tmp/etc-sing-box/." "$SB_DIR/" 2>/dev/null
    chmod 600 "$SB_KEY" 2>/dev/null || true
  fi
  rm -rf "$tmp"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
  [ -f "$USERS_FILE" ] && chmod 600 "$USERS_FILE"

  load_state || die "恢复后的状态文件无法读取"

  # 换 VPS 时公网 IP 会变, 重新探测, 否则链接里还是旧地址。
  # 探测不到就中止: 空 IP 写进 state.env 会让所有链接变成 uuid@:443, 之后每次
  # 启动都沿用这个空值 —— 比直接失败更难查。
  SERVER_IP=$(get_server_ip)
  [ -n "$SERVER_IP" ] || die "无法获取公网 IPv4, 恢复中止。旧状态备份在 ${STATE_DIR}.before-restore"
  info "服务器 IP: ${SERVER_IP}"

  # 新机器上内核参数还是默认值(rmem_max 208KB), 必须在服务启动前生效,
  # 否则 HY2 / TUIC 的 UDP socket 一建好就被钳死, 恢复出来的节点照样慢。
  optimize_system

  # 按恢复出来的协议组合重建服务, 不要把没启用的协议也拉起来
  if proto_on reality; then
    ensure_xray
    ensure_xray_service
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1
    sleep 2
    systemctl is-active --quiet xray || die "xray 启动失败, 查看: journalctl -u xray -n 30"
  fi
  if proto_on hy2; then
    ensure_hy2
    # 端口跳跃是 iptables NAT 规则, 不随配置文件恢复, 必须在新机器上重建,
    # 否则订阅里带 mport、服务端却没有那条 REDIRECT, 跳跃端口全连不上。
    setup_hy2_hop
  fi
  if sb_enabled; then
    ensure_singbox
    ensure_sb_cert
    ensure_sb_creds
    write_singbox_config
    ensure_singbox_service
    systemctl restart sing-box >/dev/null 2>&1
    sleep 2
    systemctl is-active --quiet sing-box || die "sing-box 启动失败, 查看: journalctl -u sing-box -n 30"
  fi
  setup_firewall
  install_healthcheck
  stop_unused_services
  save_state
  gen_links
  gen_sub_files
  maybe_sub_http
  save_state
  print_links
  ok "恢复完成, 凭据与设备列表都已沿用"
}

cmd_reset(){
  need_root
  load_state || die "尚未安装"
  warn "重置会生成新的 UUID / 密钥 / hy2 密码, 所有客户端必须重新导入!"
  ask_yes "确认重置凭据?" || { info "已取消"; return 0; }
  UUID=""; PRIV=""; PUB=""; SID=""; HY2_PASS=""; OBFS_PASS=""; DEST=""
  SS2022_PASS=""; ANYTLS_PASS=""; TUIC_PASS=""; TUIC_UUID=""; SB_PIN=""; SB_HEX=""
  HY2_PIN=""; CERT_SPKI_B64=""; CERT_DER_B64=""; CERT_HEX=""
  rm -f "$USERS_FILE"
  save_state
  info "重新生成凭据..."
  ensure_creds
  backup_config
  # 伪装目标按协议组合重新挑: 没开 reality 时不能走 REALITY 握手验证
  if proto_on reality; then
    pick_dest || die "目标站选择失败"
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1; sleep 2
  elif proto_on hy2 || proto_on anytls || proto_on tuic; then
    pick_dest_simple
  fi
  if proto_on hy2; then
    ensure_hy2
  fi
  if sb_enabled; then
    # 证书本身可以留着(客户端已固定), 但指纹要重算, 否则订阅会退回 insecure
    ensure_sb_cert
    ensure_sb_creds
    write_singbox_config
    systemctl restart sing-box >/dev/null 2>&1; sleep 2
    systemctl is-active --quiet sing-box || warn "sing-box 重启异常, 查看: proxy logs sb"
  fi
  save_state
  gen_links; gen_sub_files; maybe_sub_http; save_state
  print_links
  ok "凭据已重置, 请重新导入所有客户端"
}

# 查 Xray 最新版本号。升级路径必须先解析出确切版本, 才能和内置哈希对上;
# 直接用 /releases/latest/download/ 下载等于绕开校验。
xray_latest_version(){
  local v=""
  v=$(curl -fsSL --max-time 20 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
      | tr ',' '\n' | sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([0-9][^"]*\)".*/\1/p' | head -1)
  printf '%s' "$v"
}

# ---------------- 脚本自更新 ----------------
# 为什么必须有这个:
#   第一次按文档 curl -o 下载之后, 用户后面一直敲 proxy, 跑的就是那份下载时的
#   旧代码。脚本原来没有任何更新机制, 菜单里也看不出自己是不是旧的, 于是出现
#   "上游已经修了 bug, 机器上还在跑几个月前的脚本"。这里给一个明确入口。
# SCRIPT_URL 在文件顶部的常量区定义。

# 取远端版本号。拉整份脚本再用 sed 抠 SCRIPT_VERSION —— 比 GitHub API 稳:
# API 对单 IP 限 60 次/小时, raw 不限速。
fetch_remote_version(){
  command -v curl >/dev/null 2>&1 || return 0
  local p out
  # 必须和 download_with_mirror 用同一组镜像。
  # 以前只直连 raw.githubusercontent.com: 国内 VPS 上十有八九超时, 于是
  #   - 网络好的那天 -> 拉到版本号 -> 自动更新 -> 新界面
  #   - 网络差的那天 -> 拉不到 -> 静默跳过 -> 跑磁盘上的旧版 -> 旧界面
  # 用户看到的就是"每次选项都不一样", 而且完全找不到规律。
  # 只取前 8KB: SCRIPT_VERSION 在第 51 行。服务器不支持 Range 时会返回整份, 结果一样。
  for p in "" "https://ghfast.top/" "https://gh-proxy.com/"; do
    out=$(curl -fsSL -r 0-8191 --connect-timeout 6 --max-time 20 "${p}${SCRIPT_URL}" 2>/dev/null \
          | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1)
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  done
  return 0
}

# 版本比较: 远端比本地新返回 0。只比 x.y.z 三段数字, 脏版本号当 0 处理。
ver_gt(){
  local i x y
  local -a A=() B=()
  IFS=. read -r -a A <<< "${1:-}"
  IFS=. read -r -a B <<< "${2:-}"
  for i in 0 1 2; do
    x="${A[$i]:-0}"; y="${B[$i]:-0}"
    case "$x" in ''|*[!0-9]*) x=0 ;; esac
    case "$y" in ''|*[!0-9]*) y=0 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 1
}

# 当前正在运行的脚本路径。用 proxy 命令跑时 $0 是软链, readlink 解到真实文件。
running_script_path(){
  local p
  p=$(readlink -f "$0" 2>/dev/null || echo "")
  [ -n "$p" ] && [ -f "$p" ] && printf '%s' "$p"
}

# 界面顶部印一行"实际在跑的是哪份文件"。
# 用户反馈"每次看到的选项都不一样", 实际都是跑到了不同版本 / 不同副本 ——
# 把这行印出来, 差异一眼可见, 不用再靠猜。管道运行(curl | bash)时没有落盘文件,
# 直接标明, 免得用户以为脚本凭空变了。
ui_stamp(){
  local p=""
  p=$(running_script_path 2>/dev/null) || p=""
  printf '  %b脚本%b %s\n' "$D" "$N" "${p:-<管道运行, 未落盘>}"
}

# 清掉磁盘上残留的旧脚本副本。
#
# 场景: 第一次下到 /root/setup.sh, 后来改成 /root/setup-proxy.sh, 旧的那份就
# 一直躺在 /root 下 —— 哪天顺手敲一次 bash /root/setup.sh, 又跑回几个月前的
# 代码, 而且看起来"和文档一模一样", 极难发现。
#
# 只删同时满足三条的文件:
#   1) 文件名像我们的脚本 (setup*.sh / proxy-node*.sh)
#   2) 内容确实是这份脚本 (有 SCRIPT_VERSION= 且有 "Proxy Node Installer")
#   3) 不是当前正在运行的那一份
# 软链不碰: 指向当前文件的要保留, 指向别处的由安装流程重新指向。
cleanup_stale_scripts(){
  local self c rp n=0 cv
  self=$(running_script_path)
  [ -n "$self" ] || return 0
  self=$(readlink -f "$self" 2>/dev/null || printf '%s' "$self")

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -L "$c" ] && continue
    rp=$(readlink -f "$c" 2>/dev/null || printf '%s' "$c")
    [ "$rp" = "$self" ] && continue
    # 身份校验: 光看文件名会误删用户自己的脚本
    grep -q '^SCRIPT_VERSION=' "$c" 2>/dev/null || continue
    grep -q 'Proxy Node Installer' "$c" 2>/dev/null || continue
    # 比当前这份还新的不删。说明用户手里有更新的副本(比如这次误跑了旧路径),
    # 删掉它等于把唯一的新版扔了 —— 保留并提示, 让用户自己决定跑哪份。
    cv=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$c" 2>/dev/null | head -1)
    if [ -n "$cv" ] && ver_gt "$cv" "$SCRIPT_VERSION"; then
      echo -e "  ${D}保留更新的副本: ${c} (v${cv} > 当前 v${SCRIPT_VERSION})${N}"
      continue
    fi
    if rm -f "$c" 2>/dev/null; then
      n=$((n + 1))
      echo -e "  ${D}已删除旧脚本: ${c}${N}"
    fi
  done < <(find /root /tmp /usr/local/bin -maxdepth 2 -type f \
             \( -name 'setup*.sh' -o -name 'proxy-node*.sh' \) 2>/dev/null)

  # 别的地方可能还有一份改名后的旧副本, 但那种靠文件名找不到。
  # 这里只处理"标准位置 + 标准命名", 覆盖真实会踩的场景。
  if [ "$n" -gt 0 ]; then
    echo -e "  ${D}共清理 ${n} 份旧副本, 当前脚本: ${self}${N}"
  fi
  return 0
}

# 安装前提醒一次。只在真正要部署时查, 菜单/查看信息不查 —— 那些命令不该等网络。
hint_script_update(){
  local rv
  # maybe_self_update 已经查过一次就复用结果: 拉整份脚本两百多 KB, 没必要为了
  # 一句提示再下一次。
  if [ -n "${_PN_REMOTE_VER:-}" ]; then rv="$_PN_REMOTE_VER"; else rv=$(fetch_remote_version); fi
  [ -n "$rv" ] || return 0
  if ver_gt "$rv" "$SCRIPT_VERSION"; then
    warn "有新版本: 当前 v${SCRIPT_VERSION}, 远端 v${rv}"
    echo -e "    ${D}先更新再部署: ${APP_NAME} update install${N}"
    echo -e "    ${D}本次仍按 v${SCRIPT_VERSION} 执行${N}"
    echo
  fi
}

# 部署前把自己换成最新版, 然后 exec 新版继续跑。
#
# 为什么要在"部署入口"上做这件事, 而不是只提供一个 update 子命令:
#   用户的真实用法是"复制那条一键命令 -> 粘进 SSH"。只要他哪天改成敲 proxy
#   install, 或者用了收藏的旧命令, 跑的就是磁盘上那份老脚本。指望用户自己
#   记得先 update 是不现实的 —— 那就让脚本自己在动手前对齐到最新版。
#
# 三道保险, 任何一道不过都退回"用当前版本继续", 绝不阻塞部署:
#   1) 版本号能拉到且确实更新  2) 新文件 bash -n 能过  3) 新文件里有版本号
# PN_SELFUPDATED=1 是一次性闸门: exec 过去之后新版会看到它, 不再重复检查,
# 避免版本号解析异常时 exec 死循环。
maybe_self_update(){
  [ "${PN_NO_SELFUPDATE:-0}" = "1" ] && return 0
  [ "${PN_SELFUPDATED:-0}" = "1" ] && return 0
  # 非 root 跑不到部署那一步(need_root 会拦), 没必要为此下一次两百多 KB,
  # 更没必要因为写不进 /root 而多打一条警告。
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0

  local rv self tmp newv
  rv=$(fetch_remote_version)
  [ -n "$rv" ] || return 0                 # 拉不到(断网/被墙): 静默跳过
  # 记下来, 后面的 hint_script_update 直接复用, 不用再下一次
  _PN_REMOTE_VER="$rv"
  ver_gt "$rv" "$SCRIPT_VERSION" || return 0

  self=$(running_script_path)
  if [ -z "$self" ]; then
    # curl | bash: 没有落盘文件。落到标准位置, 顺便让后面能建 proxy 软链。
    self="/root/setup-proxy.sh"
  fi

  warn "发现新版本 v${SCRIPT_VERSION} -> v${rv}, 自动更新后继续部署"
  tmp=$(mktemp 2>/dev/null) || { warn "无法创建临时文件, 继续用 v${SCRIPT_VERSION}"; return 0; }
  if ! download_with_mirror "$SCRIPT_URL" "$tmp"; then
    rm -f "$tmp"; warn "下载失败, 继续用 v${SCRIPT_VERSION} 部署"; return 0
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"; warn "下载到的文件语法检查失败(可能被劫持), 已丢弃, 继续用 v${SCRIPT_VERSION}"; return 0
  fi
  # 半截文件也能通过 bash -n(语法恰好截断在语句边界), 加一道体积下限
  local sz
  sz=$(wc -c < "$tmp" 2>/dev/null || echo 0)
  if [ "$sz" -lt 100000 ]; then
    rm -f "$tmp"; warn "下载到的文件只有 ${sz} 字节(正常 200KB+), 已丢弃, 继续用 v${SCRIPT_VERSION}"; return 0
  fi
  newv=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp" 2>/dev/null | head -1)
  if [ -z "$newv" ]; then
    rm -f "$tmp"; warn "下载到的文件里没有版本号(多半是错误页), 已丢弃, 继续用 v${SCRIPT_VERSION}"; return 0
  fi
  # 镜像可能返回旧版 / 缓存版 / 被替换过的文件: 文件里的版本必须和刚探测到的
  # 远端版本一致, 且不能比本地还旧。cmd_update 早有这两道保护, 自动更新不能漏。
  if [ "$newv" != "$rv" ] || ver_gt "$SCRIPT_VERSION" "$newv"; then
    rm -f "$tmp"
    warn "下载到的脚本是 v${newv}(远端声明 v${rv}), 版本不一致, 已丢弃, 继续用 v${SCRIPT_VERSION}"
    return 0
  fi
  # 身份校验: 只认版本号不够 —— 一个被替换过的文件同样可以带一行 SCRIPT_VERSION。
  # 加这一条, 至少要求它确实是这份脚本(和 cleanup_stale_scripts 用的是同一组标记)。
  if ! grep -q 'Proxy Node Installer' "$tmp" 2>/dev/null; then
    rm -f "$tmp"; warn "下载到的文件不是本脚本(缺少身份标记), 已丢弃, 继续用 v${SCRIPT_VERSION}"; return 0
  fi

  # mv 而不是覆盖: 万一 $self 就是正在跑的这一份, 就地覆盖会让 bash 读到
  # 半新半旧的内容。mv 换 inode, 当前进程继续读旧 inode, 不受影响。
  chmod 755 "$tmp" 2>/dev/null
  mkdir -p "$(dirname "$self")" 2>/dev/null
  if ! mv -f "$tmp" "$self" 2>/dev/null; then
    rm -f "$tmp"; warn "写入 ${self} 失败, 继续用 v${SCRIPT_VERSION}"; return 0
  fi
  chmod 755 "$self" 2>/dev/null
  ln -sf "$self" "/usr/local/bin/${APP_NAME}" 2>/dev/null

  ok "已更新到 v${newv}, 用新版本继续"
  echo
  # 参数原样带过去(--clean / fresh 都在里面)。这一步之所以安全, 是因为调用点
  # 在 main 的最前面 —— 那时还没开始攒状态。放在 cmd_install 里就会出事:
  # 向导已经把 PROTOCOLS / CLEAN 这些攒在 shell 变量里了, exec 换进程就全丢。
  if [ "$#" -gt 0 ]; then
    PN_SELFUPDATED=1 exec bash "$self" "$@"
  fi
  PN_SELFUPDATED=1 exec bash "$self"
}

cmd_update(){
  need_root
  local next="${1:-}" extra="${2:-}" self tmp newv cur
  cur="$SCRIPT_VERSION"

  echo
  echo -e "${M}============================================================${N}"
  echo -e "${M}   更新脚本${N}"
  echo -e "${M}============================================================${N}"
  echo
  echo -e "  当前版本: ${Y}v${cur}${N} (${BUILD_DATE})"

  self=$(running_script_path)
  if [ -z "$self" ]; then
    # curl | bash 方式运行: 没有落盘的文件, 只能装到标准位置
    self="/root/setup-proxy.sh"
    warn "当前不是从文件运行的, 更新会写到 ${self}"
  fi
  echo -e "  脚本路径: ${self}"

  tmp=$(mktemp 2>/dev/null) || die "无法创建临时文件"
  info "正在下载最新版本 ..."
  # 必须走镜像回退: 国内 VPS 直连 raw.githubusercontent.com 十有八九是超时,
  # 而部署时的 maybe_self_update 早就走 download_with_mirror 了 —— 同一件事
  # 两套实现, 结果就是"一键部署能装, proxy update 更新不了"。
  if ! download_with_mirror "$SCRIPT_URL" "$tmp"; then
    rm -f "$tmp"
    die "下载失败 (网络不通或被拦截)。手动更新: curl -fsSL ${SCRIPT_URL} -o ${self}"
  fi

  # 三道校验: 语法能过、里面有版本号。缺一不可 —— 网络劫持/半截文件/错误页
  # 直接覆盖上去, 下次敲 proxy 就是一屏语法错误。
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "下载到的文件语法检查失败, 已丢弃(可能是网络劫持或文件不完整)"
  fi
  newv=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -1)
  if [ -z "$newv" ]; then
    rm -f "$tmp"
    die "下载到的文件里没有版本号, 已丢弃(多半是被替换成了错误页)"
  fi
  # 和 maybe_self_update 同一道身份校验: 镜像返回的也可能是一张 200 的错误页
  if ! grep -q 'Proxy Node Installer' "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "下载到的文件不是本脚本(缺少身份标记), 已丢弃"
  fi

  if [ "$newv" = "$cur" ]; then
    rm -f "$tmp"
    ok "已经是最新版 v${cur}, 无需更新"
    # 内容一样也顺手修一遍权限和软链 —— 之前踩过 644 导致 Permission denied
    chmod 755 "$self" 2>/dev/null
    ln -sf "$self" "/usr/local/bin/${APP_NAME}" 2>/dev/null
    return 0
  fi

  # 本地比远端还新时不能覆盖: 例如本地是还没推到仓库的开发版, 或仓库刚回滚过,
  # 这时一次 proxy update 会把刚部署的修复悄悄退回旧代码。maybe_self_update /
  # hint_script_update 都只认"远端更新", 手工命令也得守住同一条线。
  if ver_gt "$cur" "$newv"; then
    rm -f "$tmp"
    ok "本地 v${cur} 比远端 v${newv} 新, 已跳过更新(不降级)"
    echo -e "  ${D}远端可能还没发布该版本; 确实要强制回退请手动 curl -o 覆盖 ${self}${N}"
    chmod 755 "$self" 2>/dev/null
    ln -sf "$self" "/usr/local/bin/${APP_NAME}" 2>/dev/null
    # proxy update install 之类的组合命令: 更新虽跳过, 后续动作照跑
    case "$next" in
      "") ;;
      *) info "用本地 v${cur} 继续执行: ${next}"; exec bash "$self" "$next" ${extra:+"$extra"} ;;
    esac
    return 0
  fi

  # 用 mv 而不是重定向覆盖: bash 是边读边执行脚本文件的, 就地覆盖会让正在跑的
  # 这一份读到半新半旧的内容。mv 换 inode, 当前进程继续读旧 inode, 不受影响。
  chmod 755 "$tmp"
  mv -f "$tmp" "$self" || { rm -f "$tmp"; die "写入 ${self} 失败"; }
  chmod 755 "$self" 2>/dev/null
  ln -sf "$self" "/usr/local/bin/${APP_NAME}" 2>/dev/null

  ok "已更新: v${cur} -> v${newv}"
  echo -e "  ${D}本次仍由旧版跑完, 新版本从下一条命令开始生效${N}"
  # 顺手把其它位置的旧副本清掉, 免得哪天顺手 bash 了旧路径又跑回老代码
  cleanup_stale_scripts
  echo

  # proxy update install: 更新完直接接着部署, 省得再敲一遍
  case "$next" in
    "") ;;
    *)
      info "用新版本继续执行: ${next}"
      exec bash "$self" "$next" ${extra:+"$extra"}
      ;;
  esac
}

cmd_upgrade(){
  need_root
  local target="${1:-latest}" asset tmp sha_arch
  case "$(uname -m)" in
    x86_64|amd64)  asset="Xray-linux-64.zip";        sha_arch="64" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip"; sha_arch="arm64" ;;
    *) die "不支持的架构" ;;
  esac

  # 回滚: 用 upgrade 时留下的上一版二进制
  if [ "$target" = "--rollback" ] || [ "$target" = "rollback" ]; then
    [ -x "${XRAY_BIN}.prev" ] || die "没有可回滚的版本(只有执行过 upgrade 才会留下备份)"
    systemctl stop xray >/dev/null 2>&1
    cp -f "${XRAY_BIN}.prev" "$XRAY_BIN"
    systemctl start xray >/dev/null 2>&1
    sleep 2
    systemctl is-active --quiet xray || die "回滚后启动失败, 查看: journalctl -u xray -n 30"
    # 二进制换了, 安装时记的基准哈希就过期了。不同步的话, 下一次 proxy verify
    # 会报"二进制被改动, 可能被人替换" —— 自己升级造成的假警报, 比真报警更糟
    XRAY_BIN_SHA=$(file_sha256 "$XRAY_BIN")
    update_state_kv XRAY_BIN_SHA "$XRAY_BIN_SHA"
    # 版本号也必须跟着回退: ensure_xray 是按 XRAY_VERSION 判断"已装哪一版"的,
    # 只改哈希不改版本, 下一次 install / restore 会把内核下回 state 里那个旧版本。
    local rv
    rv=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' | tr -d 'v')
    if [ -n "$rv" ]; then XRAY_VERSION="$rv"; update_state_kv XRAY_VERSION "$XRAY_VERSION"; fi
    ok "已回滚: $($XRAY_BIN version 2>/dev/null | head -1)"
    return 0
  fi

  if [ "$target" = "latest" ] || version_ge "$target" "26.9.8"; then
    echo
    err "注意: Xray >= 26.9.8 会强制要求客户端携带 X25519MLKEM768"
    echo "  小火箭没有该开关, 升级后会「开关变绿但网页打不开」。"
    echo "  mihomo 系需在配置里加 reality-opts.support-x25519mlkem768: true"
    echo
  fi

  # latest 先解析成具体版本号, 否则既没法校验, 也不知道装了什么
  if [ "$target" = "latest" ]; then
    info "查询 Xray 最新版本..."
    target=$(xray_latest_version)
    if [ -z "$target" ]; then
      die "查询最新版本失败(GitHub API 不可达)。请直接指定版本: proxy upgrade 26.3.27"
    fi
    info "最新版本: ${target}"
  fi
  target="${target#v}"

  local url="https://github.com/XTLS/Xray-core/releases/download/v${target}/${asset}"

  ask_yes "安装 Xray ${target}?  当前: $($XRAY_BIN version 2>/dev/null | head -1)" || { info "已取消"; return 0; }

  tmp=$(mktemp -d)
  download_with_mirror "$url" "$tmp/x.zip" || { rm -rf "$tmp"; die "下载失败(版本号是否存在?)"; }
  # 升级同样要校验: 安装时校验再严, 一条 upgrade 也能装进被换过的内核
  verify_sha256 "$tmp/x.zip" "$(pinned_sha "xray-${sha_arch}-${target}")" "Xray ${target}" \
    || { rm -rf "$tmp"; die "Xray 校验未通过, 已中止升级"; }
  unzip -o -q "$tmp/x.zip" -d "$tmp/pkg" || { rm -rf "$tmp"; die "解压失败"; }
  [ -f "$tmp/pkg/xray" ] || { rm -rf "$tmp"; die "压缩包内未找到 xray"; }

  # 留一份当前版本, 便于 --rollback
  [ -x "$XRAY_BIN" ] && cp -f "$XRAY_BIN" "${XRAY_BIN}.prev"
  systemctl stop xray >/dev/null 2>&1
  install -m 755 "$tmp/pkg/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  systemctl start xray >/dev/null 2>&1
  sleep 2
  if ! systemctl is-active --quiet xray; then
    warn "新版本启动失败, 尝试回滚"
    if [ -x "${XRAY_BIN}.prev" ] && cp -f "${XRAY_BIN}.prev" "$XRAY_BIN" 2>/dev/null; then
      systemctl start xray >/dev/null 2>&1
      sleep 2
      if systemctl is-active --quiet xray; then
        XRAY_BIN_SHA=$(file_sha256 "$XRAY_BIN")
        update_state_kv XRAY_BIN_SHA "$XRAY_BIN_SHA"
        local rv2
        rv2=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' | tr -d 'v')
        [ -n "$rv2" ] && { XRAY_VERSION="$rv2"; update_state_kv XRAY_VERSION "$XRAY_VERSION"; }
        die "新版本启动失败, 已回滚到上一版本并恢复服务。查看: journalctl -u xray -n 30"
      fi
      die "新版本启动失败, 二进制已回滚但服务仍未起来。手动排查: journalctl -u xray -n 50"
    fi
    die "新版本启动失败, 且没有可回滚的备份(${XRAY_BIN}.prev 不存在)。手动排查: journalctl -u xray -n 50"
  fi
  ok "已安装: $($XRAY_BIN version 2>/dev/null | head -1)"
  # 同步基准哈希: 否则 proxy verify 会把这次升级当成"二进制被人替换"
  XRAY_BIN_SHA=$(file_sha256 "$XRAY_BIN")
  update_state_kv XRAY_BIN_SHA "$XRAY_BIN_SHA"
  # 版本号一起写回 state: ensure_xray 靠它判断"已装哪一版", 不写的话下一次
  # install / restore 会把内核静默下载回 26.3.27, 等于把刚升的版本降回去。
  XRAY_VERSION="$target"
  update_state_kv XRAY_VERSION "$XRAY_VERSION"
  echo -e "${D}回滚: proxy upgrade --rollback${N}"
}

# ---------------- 清理 ----------------
# 只删本脚本创建的东西; remove_script=1 时连管理命令与脚本一起删
# 列出旧实例残留项; 有残留返回 0 并把清单打到 stdout
residue_report(){
  local found=0 out=""
  [ -f /etc/systemd/system/xray.service ]            && { out+="    - systemd: xray.service"$'\n'; found=1; }
  [ -f /etc/systemd/system/hysteria-server.service ] && { out+="    - systemd: hysteria-server.service"$'\n'; found=1; }
  [ -f /etc/systemd/system/hy2-hop.service ]         && { out+="    - systemd: hy2-hop.service"$'\n'; found=1; }
  [ -f /etc/systemd/system/proxy-sub.service ]       && { out+="    - systemd: proxy-sub.service"$'\n'; found=1; }
  [ -f /etc/systemd/system/proxy-healthcheck.timer ] && { out+="    - systemd: proxy-healthcheck.timer"$'\n'; found=1; }
  [ -f /etc/systemd/system/sing-box.service ]        && { out+="    - systemd: sing-box.service"$'\n'; found=1; }
  [ -x "$SB_BIN" ]                                   && { out+="    - 二进制: $SB_BIN"$'\n'; found=1; }
  [ -d /etc/sing-box ]                               && { out+="    - 配置: /etc/sing-box"$'\n'; found=1; }
  [ -x "$XRAY_BIN" ]                                 && { out+="    - 二进制: $XRAY_BIN"$'\n'; found=1; }
  [ -x "$HY2_BIN" ]                                  && { out+="    - 二进制: $HY2_BIN"$'\n'; found=1; }
  [ -d /usr/local/etc/xray ]                         && { out+="    - 配置: /usr/local/etc/xray"$'\n'; found=1; }
  [ -d /etc/hysteria ]                               && { out+="    - 配置: /etc/hysteria"$'\n'; found=1; }
  # 状态/订阅目录若是空的(上次装一半就退出留下的壳), 直接抹掉, 不拿它打扰用户
  local d
  for d in "$STATE_DIR" "$SUB_DIR"; do
    [ -d "$d" ] || continue
    if [ -n "$(find "$d" -mindepth 1 ! -type d -print -quit 2>/dev/null)" ]; then
      out+="    - 状态: $d"$'\n'; found=1
    else
      rm -rf "$d" 2>/dev/null || true
    fi
  done
  [ "$found" = "0" ] && return 1
  printf '%s' "$out"
  return 0
}

# 安装前的清理闸门, 内嵌在 install 流程里, 不需要单独跑 clean
# $1: 1=状态文件可读(正常安装过) 0=状态缺失
# 返回 0=直接继续, 1=已清理(调用方要重置内存凭据并按全新安装处理)
install_clean_gate(){
  local state_ok="${1:-0}" items=""

  if [ "$CLEAN" = "1" ]; then
    info "CLEAN=1 / --clean: 先清理旧实例再安装"
    do_clean 0
    return 1
  fi

  # 正常安装(状态可读): 原地幂等重部署, 不弹菜单打扰
  if [ "$state_ok" = "1" ]; then
    info "如需全新安装(换凭据/清端口), 加 --clean 参数重跑"
    return 0
  fi

  # 状态缺失但有残留文件, 可能是"本脚本上次装到一半", 也可能是"这台机器上原本
  # 就有别的脚本 / 用户自己装的 xray、hysteria、sing-box"。后者绝对不能删 ——
  # 非交互模式(ASSUME_YES=1, 一键部署最常见)下以前会直接 do_clean 把它们抹掉。
  # 只认本脚本自己留下的标记。
  local ours=0
  if [ -d "$STATE_DIR" ] || [ -f /root/proxy-info.txt ] \
     || [ -e "/usr/local/bin/${APP_NAME}" ] \
     || [ -f /usr/local/bin/proxy-healthcheck.sh ]; then
    ours=1
  fi

  # 状态缺失但有残留文件 = 上次装到一半的残缺安装, 不清理必然端口冲突
  items=$(residue_report) || return 0

  if [ "$ours" != "1" ]; then
    echo
    warn "机器上已有 xray / hysteria / sing-box, 但没有本脚本的安装标记:"
    printf '%s' "$items"
    warn "这些不是本脚本装的, 不会自动清理(删掉别人的节点是不可逆的)"
    warn "若端口冲突, 先自行停用它们, 或换端口安装:"
    echo -e "    ${D}VLESS_PORT=8443 HY2_PORT=8443 bash /root/setup-proxy.sh install${N}"
    return 0
  fi

  echo
  warn "检测到残缺安装的残留文件:"
  printf '%s' "$items"
  echo
  echo -e "${D}  这些是上次安装中断留下的, 不清理会占端口导致新配置起不来。${N}"

  # 真正试着打开一次 /dev/tty 再决定要不要问, 和 read_tty 的行为保持一致
  if [ "$ASSUME_YES" = "1" ] || ! { : 2>/dev/null >/dev/tty; }; then
    warn "非交互模式: 自动清理残缺安装"
    do_clean 0
    return 1
  fi

  if ask_yes "清理这些残留并全新安装?"; then
    do_clean 0
    return 1
  fi
  die "已取消。加 --clean 参数重跑即可自动清理: bash setup-proxy.sh install --clean"
}

do_clean(){
  local remove_script="${1:-0}" hop="" hp="" p o
  local vport="" hport=""

  # 端口跳跃信息随后就被删掉, 先取出来
  # 注意: 不能在这里 source state.env, 会把命令行传入的 VLESS_PORT 等环境变量覆盖回旧值
  if [ -f "$STATE_FILE" ]; then
    [ -n "$hop" ] || hop=$(sed -n "s/^HY2_HOP='\(.*\)'\$/\1/p" "$STATE_FILE" 2>/dev/null | head -1)
    [ -n "$hp" ]  || hp=$(sed -n "s/^HY2_PORT='\(.*\)'\$/\1/p" "$STATE_FILE" 2>/dev/null | head -1)
    # 复查端口用旧配置的端口, 比内存里的更准
    [ -n "$vport" ] || vport=$(sed -n "s/^VLESS_PORT='\(.*\)'\$/\1/p" "$STATE_FILE" 2>/dev/null | head -1)
    [ -n "$hport" ] || hport=$(sed -n "s/^HY2_PORT='\(.*\)'\$/\1/p" "$STATE_FILE" 2>/dev/null | head -1)
  fi

  systemctl disable --now xray hysteria-server sing-box hy2-hop proxy-sub proxy-healthcheck.timer >/dev/null 2>&1 || true

  rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria-server.service \
        /etc/systemd/system/sing-box.service \
        /etc/systemd/system/hy2-hop.service /etc/systemd/system/proxy-sub.service \
        /etc/systemd/system/proxy-healthcheck.service /etc/systemd/system/proxy-healthcheck.timer
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true

  # 只杀本脚本自己的二进制, 不碰系统里其它程序
  pkill -f '^/usr/local/bin/xray' >/dev/null 2>&1 || true
  pkill -f '^/usr/local/bin/hysteria' >/dev/null 2>&1 || true
  pkill -f '^/usr/local/bin/sing-box' >/dev/null 2>&1 || true
  sleep 1

  # 端口跳跃的 NAT 规则(可能残留多条)。
  # iptables 的区间写法是 start:end, 而 state 里存的是 20000-30000 —— 直接用
  # 连字符去 -C 永远匹配不上, 规则会一直留在这台机器上。
  if [ -n "$hop" ] && [ -n "$hp" ]; then
    local hop_r="${hop/-/:}"
    while iptables -t nat -C PREROUTING -p udp --dport "$hop_r" -j REDIRECT --to-ports "$hp" 2>/dev/null; do
      iptables -t nat -D PREROUTING -p udp --dport "$hop_r" -j REDIRECT --to-ports "$hp" 2>/dev/null || break
    done
  fi

  rm -rf /usr/local/etc/xray /usr/local/share/xray /etc/hysteria /etc/sing-box "$SUB_DIR" "$STATE_DIR" "${STATE_DIR}.before-restore"
  # 订阅 HTTP 服务的 server.py 也在 /usr/local/lib 下, 不删就是一套没人管的订阅服务端
  rm -rf /usr/local/lib/proxy-sub
  rm -f "$XRAY_BIN" "${XRAY_BIN}.prev" "$HY2_BIN" "$SB_BIN" /root/proxy-info.txt \
        /usr/local/bin/proxy-healthcheck.sh \
        /etc/sysctl.d/99-proxy-optimize.conf \
        /etc/systemd/journald.conf.d/99-proxy-size.conf
  sysctl --system >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  rm -f /run/proxy-healthcheck.fail /run/proxy-healthcheck.tick
  rm -rf /run/proxy-hc

  if [ "$remove_script" = "1" ]; then
    rm -f "/usr/local/bin/${APP_NAME}" /root/setup-proxy.sh
  fi

  # 复查端口是否真的空了
  for p in "${vport:-${VLESS_PORT:-443}}" "${hport:-${HY2_PORT:-443}}"; do
    o=$(port_owner "$p" tcp) || o=""
    [ -n "$o" ] && warn "TCP ${p} 仍被其它进程占用: ${o}"
    o=$(port_owner "$p" udp) || o=""
    [ -n "$o" ] && warn "UDP ${p} 仍被其它进程占用: ${o}"
  done
  return 0
}

cmd_clean(){
  need_root
  local remove_script=0 force=0 a
  for a in "$@"; do
    case "$a" in
      --all|--purge)   remove_script=1 ;;
      --yes|-y|--force) force=1 ;;
    esac
  done

  echo
  err "即将清除本脚本创建的全部内容"
  echo "  服务   xray / hysteria-server / hy2-hop / proxy-sub / proxy-healthcheck"
  echo "  配置   ${XRAY_CFG}"
  echo "         ${HY2_CFG}"
  echo "         ${STATE_DIR}   (含全部凭据与设备列表)"
  echo "  订阅   ${SUB_DIR}"
  echo "  系统   sysctl 优化项 / journald 限容 / 端口跳跃 iptables 规则"
  [ "$remove_script" = "1" ] && echo "  脚本   管理命令 ${APP_NAME} 与 /root/setup-proxy.sh"
  echo
  echo -e "${D}swap 会保留(不影响重装); 不会动系统里的其它服务${N}"
  echo
  if [ "$force" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
    ask_yes "确认清除?" || { info "已取消"; return 0; }
  fi

  do_clean "$remove_script"
  ok "已清除, 端口应已释放"
  if [ "$remove_script" != "1" ]; then
    echo -e "${D}管理命令 ${APP_NAME} 仍在, 运行 ${APP_NAME} 选 1 即可重新部署${N}"
  fi
  echo
}

# ---------------- 部署向导 ----------------
# 无参数运行(或管理菜单选"部署向导")时进入: 先点选要开的协议, 再开始装
wizard(){
  local sel="" picked="" tok cur="" want_clean=0 want_opt=0 want_tz=0 bad=0

  # 没有可用终端就没法点选, 直接给出等价的非交互写法
  if ! { : 2>/dev/null >/dev/tty; }; then
    die "当前没有可交互的终端。改用: PROTOCOLS=reality,hy2 bash $(basename "$0") install"
  fi

  while true; do
    # 每轮都要重置: 清理后状态文件已删, 旧的 cur 留着会误判成"协议变更"
    sel=""; cur=""
    echo
    echo -e "${M}============================================================${N}"
    echo -e "${M}   Proxy Node Installer v${SCRIPT_VERSION}   ·   部署向导${N}"
    echo -e "${M}============================================================${N}"
    ui_stamp
    echo
    if [ -f "$STATE_FILE" ]; then
      cur=$(sed -n "s/^PROTOCOLS='\(.*\)'\$/\1/p" "$STATE_FILE" 2>/dev/null | head -1)
      echo -e "  ${D}已安装: ${G}${cur:-?}${N}${D}   $(sed -n "s/^INSTALLED_AT='\(.*\)'\$/\1/p" "$STATE_FILE" 2>/dev/null | head -1)${N}"
    else
      echo -e "  ${D}当前状态: 尚未安装${N}"
    fi
    echo
    echo -e "  ${D}选择要部署的协议, 输入编号, 可多选(如 ${Y}1 2${D} 表示两个都开):${N}"
    echo
    echo "   1) Reality       VLESS + Vision    抗封锁最强, 不需要证书"
    echo "   2) Hysteria2     UDP 高速          弱网 / 高丢包环境最强"
    echo "   3) SS2022        Shadowsocks-2022  兼容性最好, 老客户端也能用"
    echo "   4) AnyTLS        抗主动探测        新一代 TLS 伪装"
    echo "   5) TUIC v5       低延迟 UDP        基于 QUIC"
    echo
    echo -e "   6) Reality + Hysteria2             ${G}推荐: TCP/UDP 双保险${N}"
    echo "   7) 全协议                          1~5 全部开启"
    echo
    echo -e "  ${D}── VPS 优化 (可单独执行, 不装代理也能用) ──────────────────${N}"
    echo -e "   8) ${G}一键优化 VPS${N}                    BBR + 内核参数 + swap + 时间同步 + 日志限容"
    echo -e "   9) 设置时区                          ${D}按机器所在地区设, 别留默认的 UTC${N}"
    echo
    echo -e "  ${D}── 维护 ────────────────────────────────────────────────────${N}"
    echo -e "   c) ${R}清理所有配置${N}                    端口被占用 / 想彻底重来时用"
    echo "   0) 退出"
    echo

    read_tty "  ${B}请选择${N} [直接回车 = ${G}6 推荐${N}]: " sel "6" || { info "无终端, 已退出"; exit 0; }
    sel="${sel//,/ }"; sel="${sel//，/ }"; sel="${sel//、/ }"

    picked=""; want_clean=0; want_opt=0; want_tz=0; bad=0
    for tok in $sel; do
      case "$tok" in
        0) info "已退出"; exit 0 ;;
        8) want_opt=1 ;;
        9) want_tz=1 ;;
        c|C) want_clean=1 ;;
        1) picked="${picked}reality," ;;
        2) picked="${picked}hy2," ;;
        3) picked="${picked}ss2022," ;;
        4) picked="${picked}anytls," ;;
        5) picked="${picked}tuic," ;;
        6) picked="${picked}reality,hy2," ;;
        7) picked="${picked}reality,hy2,ss2022,anytls,tuic," ;;
        *) warn "无效选项: ${tok}"; bad=1 ;;
      esac
    done

    # 8: 只做 VPS 优化, 不进入安装
    if [ "$want_opt" = "1" ]; then
      echo
      cmd_optimize all
      continue
    fi

    # 9: 只改时区, 不进入安装
    if [ "$want_tz" = "1" ]; then
      cmd_timezone
      continue
    fi

    # c 优先: 清理完回到向导, 让用户接着选协议
    if [ "$want_clean" = "1" ]; then
      echo
      if [ -f "$STATE_FILE" ] || residue_report >/dev/null 2>&1; then
        warn "将删除: 全部服务 / 配置 / 凭据 / 订阅 / 二进制"
        if ask_yes "确认清除所有代理配置?"; then
          do_clean 0
          CLEAN=0
          ok "已清除, 端口已释放"
        else
          info "已取消清理"
        fi
      else
        info "当前没有已安装的配置, 无需清理"
      fi
      continue
    fi

    picked="${picked%,}"
    if [ "$bad" = "1" ] || [ -z "$picked" ]; then
      [ -n "$picked" ] || warn "没有选中任何协议"
      echo
      continue
    fi

    # 已装过且协议组合变了: 必须清干净再装, 否则旧协议继续占端口。
    # 比较用归一化后的顺序: 用户把 `1 2` 敲成 `2 1` 不算换协议, 否则会误清理、
    # 把 users.txt 和全部 UUID 一起删掉。
    picked=$(canon_protocols "$picked")
    if [ -n "$cur" ] && [ "$(canon_protocols "$cur")" != "$picked" ]; then
      echo
      warn "协议变更: ${cur}  ->  ${picked}"
      warn "换协议要先清掉旧实例, 否则旧服务还在跑、端口还占着"
      if ! ask_yes "清理旧实例并按新协议部署?"; then
        info "已取消, 回到选择"
        echo
        continue
      fi
      CLEAN=1
    fi

    PROTOCOLS="$picked"
    echo
    ok "部署协议: ${PROTOCOLS}"
    echo
    # 向导里点"开始部署"也要走自动更新。必须先 export: exec 只继承环境变量,
    # 不继承 shell 变量 —— 不 export 就会变成"选了全协议却按默认组合装"。
    export PROTOCOLS CLEAN
    maybe_self_update install
    cmd_install
    return 0
  done
}

# ---------------- 菜单 ----------------
# 直接部署指定协议组合(菜单里的"一键部署"走这里)
# 已装且组合不同时必须先清理: 否则旧协议的服务还在跑、端口还占着
deploy_preset(){
  local want="$1" curp=""
  want=$(canon_protocols "$want")
  if [ -f "$STATE_FILE" ]; then
    curp=$(sed -n "s/^PROTOCOLS='\(.*\)'\$/\1/p" "$STATE_FILE" 2>/dev/null | head -1)
    curp=$(canon_protocols "$curp")
  fi
  if [ -n "$curp" ] && [ "$curp" != "$want" ]; then
    echo
    warn "当前已装协议: ${curp}"
    warn "要换成 ${want}, 必须先清掉旧实例, 否则旧协议继续占端口"
    if ! ask_yes "清理旧实例并按 ${want} 部署?"; then
      info "已取消"
      return 0
    fi
    CLEAN=1
  fi
  _RAW_PROTOCOLS="$want"
  PROTOCOLS="$want"
  # 菜单里点"重新部署"同样先对齐版本。export 的理由见 wizard 里那段注释。
  export PROTOCOLS CLEAN
  maybe_self_update install
  cmd_install
}

menu(){
  while true; do
    echo
    echo -e "${M}============================================${N}"
    echo -e "${M}   Proxy Node 管理菜单${N}   ${D}v${SCRIPT_VERSION}${N}"
    echo -e "${M}============================================${N}"
    ui_stamp
    if load_state 2>/dev/null; then
      local mp=""
      proto_on reality && mp="${mp} VLESS/${VLESS_PORT}"
      proto_on hy2     && mp="${mp} HY2/${HY2_PORT}"
      proto_on ss2022  && mp="${mp} SS/${SS2022_PORT}"
      proto_on anytls  && mp="${mp} AnyTLS/${ANYTLS_PORT}"
      proto_on tuic    && mp="${mp} TUIC/${TUIC_PORT}"
      echo -e "  节点 ${G}${NODE_NAME}${N}   IP ${SERVER_IP:-?}  ${D}${mp# }${N}"
      echo -e "  SNI  ${DEST:-?}"
    else
      echo -e "  ${Y}尚未安装${N}"
    fi
    echo
    echo -e "  ${G}1) 一键部署 Reality + Hysteria2${N}   ${D}(推荐: TCP/UDP 双保险, 直接开装)${N}"
    echo "  2) 部署向导 (选协议 / 换协议 / 重新部署)"
    echo "  3) 查看节点信息与链接"
    echo "  4) 重新生成订阅文件"
    echo "  5) 服务状态"
    echo "  6) 重启服务"
    echo "  7) 实时日志 (xray)"
    echo "  8) 实时日志 (hysteria2)"
    echo "  l) 实时日志 (sing-box: ss2022/anytls/tuic)"
    echo "  9) 线路体检 (出口 IP / PTR / 时间 / 客户端清单)"
    echo "  n) 改节点备注名 (只改客户端显示, 不用重装)"
    echo "  v) 安全自检 (二进制指纹 / 配置 / 凭据权限)"
    echo "  d) 诊断报告 (用不了时跑这个, 凭据自动脱敏)"
    echo "  a) 设备凭据 (多设备 UUID / 单独吊销)"
    echo "  r) 重置凭据 (换 UUID/密钥, 需重新导入)"
    echo "  b) 备份配置 (迁移到新 VPS 用)"
    echo "  t) 一键优化 VPS (BBR / 内核参数 / swap / 时间同步)"
    echo "  z) 设置时区 (按机器所在地区设)"
    echo -e "  y) 更新脚本 ${D}(当前 v${SCRIPT_VERSION}; 一直敲 proxy 会一直跑旧代码)${N}"
    echo "  f) 清理并全新安装 (换新凭据, 端口冲突时用)"
    echo "  c) 清除所有配置 (端口被占用时用这个)"
    echo "  u) 卸载 (等同清除; proxy 命令保留)"
    echo "  0) 退出"
    echo
    local c=""
    read_tty "${B}请选择: ${N}" c "0"
    case "$c" in
      1) deploy_preset "reality,hy2" ;;
      2) wizard ;;
      3) cmd_info ;;
      4) cmd_sub ;;
      5) cmd_status ;;
      6) cmd_restart ;;
      7) cmd_logs xray ;;
      8) cmd_logs hy2 ;;
      l|L) cmd_logs sb ;;
      9) cmd_audit ;;
      n|N) cmd_name ;;
      v|V) cmd_verify ;;
      d|D) cmd_diag ;;
      a|A) cmd_user list ;;
      r|R) cmd_reset ;;
      b|B) cmd_backup ;;
      t|T) cmd_optimize all ;;
      z|Z) cmd_timezone ;;
      y|Y) cmd_update ;;
      f|F) CLEAN=1; cmd_install ;;
      c|C) cmd_clean ;;
      u|U) cmd_clean ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

usage(){
  cat <<USAGE
Proxy Node Installer v${SCRIPT_VERSION} (${BUILD_DATE})

用法:
  bash setup-proxy.sh [命令]

命令:
  (无参数)         弹出部署向导(选协议/优化/清理); 已安装则打开管理菜单
  wizard           直接打开部署向导
  install          安装/重新部署(幂等, 保留凭据)
  install --clean  清理旧实例后全新安装(换新凭据, 端口冲突时用)
  fresh            等同 install --clean
  optimize [项]    一键优化 VPS: all(默认) / bbr / swap / time / log
  timezone [时区]  设置时区: 无参数=菜单, auto=按出口IP自动, 或直接给 Asia/Tokyo
  info             查看节点信息、链接、二维码
  sub              重新生成订阅文件
  name [名字]      改节点备注名(只影响客户端显示, 不改服务端配置)
  status           服务状态与监听端口
  verify [--fix]   安全自检: 二进制指纹 / 配置合法性 / 凭据与订阅目录权限 / 订阅 DNS
  restart          重启已启用协议对应的服务
  logs [单元]      实时日志: xray(默认) / hy2 / sb
  audit [--dnsbl]  线路体检(出口 IP / PTR / 时间 / 客户端清单)
  selftest         逐协议真连一次(用订阅同一份配置), 装完发现不通看这里
  speed            速度体检: BBR / 拥塞控制 / 默认节点 / 该开哪项(只读)
  diag [文件]      生成脱敏诊断报告(系统/服务/端口/网络/时间/日志), 用不了时贴这个
  egress [地址]    上游出口代理(住宅 IP): 不带参数=查看, off=关闭
                   例: proxy egress socks5://用户:密码@1.2.3.4:1080
  user [子命令]    多设备凭据: list(默认) / add <名字> / link <名字> / rm <名字>
  reset            重置凭据(会作废现有客户端)
  backup [文件]    打包状态/凭据/证书, 用于迁移
  restore <文件>   从备份恢复(换 VPS 时用, 会自动重新探测 IP)
  clean [--all]    清除所有配置与服务(端口被占用时用这个)
  uninstall        等同 clean
  update [命令]    更新脚本自身: 无参数=只更新, update install=更新后立刻重新部署
  upgrade [版本]   升级 Xray 内核; upgrade --rollback 回滚上一版
  version          显示脚本版本

首次安装可用的环境变量:
  PROTOCOLS=reality,hy2           协议组合, 逗号分隔
                                  可选: reality hy2 ss2022 anytls tuic
  VLESS_PORT=443  HY2_PORT=443    主协议端口
  SS2022_PORT=8445  ANYTLS_PORT=8444  TUIC_PORT=8443
                                  扩展协议端口(sing-box 承载)
  REALITY_DEST=www.bing.com      指定伪装站(留空=自动挑选)
  REALITY_DEST=random            重新随机挑一个(已装好的机器换 SNI 用这个)
  ENABLE_OBFS=1                  开启 hy2 salamander 混淆
  HY2_HOP=20000-30000            hy2 UDP 端口跳跃
  HY2_INSECURE=1                 关闭证书固定, 退回 insecure(不推荐)
  HY2_BW_UP=50 HY2_BW_DOWN=300   Hysteria2 Brutal 带宽(Mbps); 留空=默认 BBR
                                  只写进客户端订阅, 填错比不填更慢, 见 README
  DEFAULT_NODE=hy2               客户端默认节点改走 HY2(UDP 提速); 默认 reality(TCP)
                                   切回: DEFAULT_NODE=reality proxy sub
  SUB_PORT=38080                 订阅 HTTP 端口(留空=随机 30000-39999)
  NODE_NAME=xxx                  节点备注名
  SUB_HTTP=1                     起订阅 HTTP 服务
  SUB_BIND=0.0.0.0               订阅服务监听地址(默认 127.0.0.1)
  HY2_VERSION=2.13.0             固定 hysteria 版本(内置哈希与之一一对应)
  ALLOW_UNVERIFIED_BIN=1         跳过二进制完整性校验(不推荐, 仅自定义版本时用)
  CLEAN=1                        安装前先彻底清理旧实例
  ASSUME_YES=1                   全程不询问
  PN_NO_SELFUPDATE=1             部署前不做自动更新(断网环境 / 要复现旧版行为时用)

关于自动更新:
  install / fresh / 无参数向导 在动手之前会查一次远端版本, 发现更新就下载、校验、
  原子替换自己, 然后 exec 新版继续部署。下载失败或校验不过会退回当前版本继续,
  不会卡住部署。装完还会清掉 /root /tmp /usr/local/bin 下残留的旧脚本副本。

示例:
  bash setup-proxy.sh
  bash setup-proxy.sh install --clean         端口被占用时一条命令重来
  PROTOCOLS=reality,hy2,ss2022 bash setup-proxy.sh install
                                              加装 Shadowsocks-2022
  PROTOCOLS=reality,hy2,anytls,tuic bash setup-proxy.sh install
  bash setup-proxy.sh clean --all             连管理命令一起删干净
  VLESS_PORT=8443 HY2_PORT=8443 bash setup-proxy.sh install
  ENABLE_OBFS=1 HY2_HOP=20000-30000 bash setup-proxy.sh install
USAGE
}

# ---------------- 入口 ----------------
main(){
  # 部署类入口先把自己对齐到最新版, 再进真正的流程。
  #
  # 必须放在 case 之前, 不能塞进 cmd_install: 向导和菜单是先在 shell 变量里
  # 攒选择(PROTOCOLS / CLEAN / 各端口), 攒完才调 cmd_install。在那里 exec 换
  # 进程, 这些变量不会跟过去 —— 用户明明选了全协议, 更新完却按默认组合装。
  case "${1:-}" in
    install|fresh|wizard|setup)
      maybe_self_update "$@" ;;
    "")
      # 已装过的机器会进菜单, 那种不该为了查版本卡在网络上;
      # 未装过的一定会进向导, 这里提前更新, 免得向导填完才发现跑的是旧版。
      [ -f "$STATE_FILE" ] || maybe_self_update ;;
  esac

  case "${1:-}" in
    install)
      shift || true
      local a
      for a in "$@"; do
        case "$a" in --clean|--fresh|-c) CLEAN=1 ;; esac
      done
      cmd_install
      ;;
    fresh)          CLEAN=1; cmd_install ;;
    info)           cmd_info ;;
    name|rename)    cmd_name "${2:-}" ;;
    sub)            cmd_sub ;;
    status)         cmd_status ;;
    verify|check)   cmd_verify "${2:-}" ;;
    restart)        cmd_restart ;;
    logs)           cmd_logs "${2:-xray}" ;;
    audit)          cmd_audit "${2:-}" ;;
    egress)         cmd_egress "${2:-}" ;;
    selftest|test)  cmd_selftest ;;
    speed|perf)     cmd_speed ;;
    diag|diagnose)  cmd_diag "${2:-}" ;;
    user)           cmd_user "${2:-list}" "${3:-}" ;;
    reset)          cmd_reset ;;
    backup)         cmd_backup "${2:-}" ;;
    restore)        cmd_restore "${2:-}" ;;
    clean|uninstall|purge) cmd_clean "${2:-}" "${3:-}" ;;
    optimize|opt)   cmd_optimize "${2:-all}" ;;
    timezone|tz)    cmd_timezone "${2:-}" ;;
    wizard|setup)   wizard ;;
    upgrade)        cmd_upgrade "${2:-}" ;;
    update|selfupdate) cmd_update "${2:-}" "${3:-}" ;;
    version|-V|--version) echo "proxy-node v${SCRIPT_VERSION} (${BUILD_DATE})" ;;
    help|-h|--help) usage ;;
    "")
      if load_state 2>/dev/null; then
        menu
      elif [ "$_RAW_PROTOCOLS" != "__unset__" ]; then
        # 显式指定了 PROTOCOLS -> 自动化场景, 直接按指定协议装
        cmd_install
      elif { : 2>/dev/null >/dev/tty; }; then
        # 有终端: 出部署向导, 先选协议再装
        wizard
      else
        # 无终端(CI/管道调用): 用默认协议装, 不阻塞
        cmd_install
      fi
      ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
