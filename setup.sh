#!/usr/bin/env bash
# ============================================================
#  Proxy Node Installer  v3
#  VLESS + REALITY (xtls-rprx-vision)  +  Hysteria2
#  一键部署 + 日常管理 + 订阅生成
# ------------------------------------------------------------
#  适用: Debian 11/12  Ubuntu 20/22/24  CentOS/Rocky/Alma 8/9
#  用法:
#     bash setup-proxy.sh              首次=自动安装, 已装=打开管理菜单
#     bash setup-proxy.sh install      直接安装(幂等, 不重置凭据)
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
#     VLESS_PORT=443  HY2_PORT=443  REALITY_DEST=www.bing.com
#     ENABLE_OBFS=1   开启 hy2 salamander 混淆
#     HY2_HOP=20000-30000   hy2 UDP 端口跳跃
#     HY2_INSECURE=1  关闭证书固定, 退回 insecure (不推荐, 仅临时调试)
#     SUB_HTTP=1      起一个订阅 HTTP 服务(默认关)
#     SUB_BIND=0.0.0.0  订阅服务监听地址(默认 127.0.0.1, 只允许本机/SSH 隧道)
#     CLEAN=1         安装前先彻底清理旧实例(解决端口被占用)
#     ASSUME_YES=1    全程不询问
# ============================================================
set -uo pipefail

APP_NAME="proxy"
SCRIPT_VERSION="3.1.0"
STATE_DIR="/etc/proxy-node"
STATE_FILE="${STATE_DIR}/state.env"
USERS_FILE="${STATE_DIR}/users.txt"
BACKUP_DIR="${STATE_DIR}/backup"
SUB_DIR="/var/www/proxy-sub"
LOG_FILE="/var/log/proxy-deploy.log"
REPO_URL="https://github.com/smallji666/proxy-node"

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

# ---------------- 默认参数 ----------------
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-443}"
XRAY_VERSION="${XRAY_VERSION:-26.3.27}"
REALITY_DEST="${REALITY_DEST:-}"
ENABLE_OBFS="${ENABLE_OBFS:-0}"
HY2_HOP="${HY2_HOP:-}"
HY2_INSECURE="${HY2_INSECURE:-0}"
SUB_HTTP="${SUB_HTTP:-0}"
SUB_PORT="${SUB_PORT:-}"
SUB_BIND="${SUB_BIND:-127.0.0.1}"
CLEAN="${CLEAN:-0}"
NODE_NAME="${NODE_NAME:-Node}"
NODE_NAME="${NODE_NAME// /-}"
ASSUME_YES="${ASSUME_YES:-0}"

XRAY_BIN=/usr/local/bin/xray
XRAY_CFG=/usr/local/etc/xray/config.json
HY2_BIN=/usr/local/bin/hysteria
HY2_CFG=/etc/hysteria/config.yaml

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

# version_ge A B  ->  A >= B (按版本号而非字符串比较)
version_ge(){
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V 2>/dev/null | head -1)" = "$2" ]
}

ask_yes(){
  [ "$ASSUME_YES" = "1" ] && return 0
  local ans=""
  read -rp "$(echo -e "${Y}?${N} $1 [y/N]: ")" ans </dev/tty 2>/dev/null || ans=""
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------- 状态持久化 ----------------
load_state(){
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    return 0
  fi
  return 1
}

save_state(){
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  {
    echo "# 由 proxy-installer 自动生成, 请勿手工编辑"
    echo "INSTALLED_AT='$(date '+%Y-%m-%d %H:%M:%S')'"
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
    echo "CERT_SPKI_B64='${CERT_SPKI_B64:-}'"
    echo "CERT_DER_B64='${CERT_DER_B64:-}'"
    echo "CERT_HEX='${CERT_HEX:-}'"
    echo "SUB_TOKEN='${SUB_TOKEN:-}'"
    echo "SUB_PORT='${SUB_PORT:-}'"
    echo "SUB_BIND='${SUB_BIND}'"
    echo "SUB_HTTP='${SUB_HTTP}'"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
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
  if [ "$_RAW_NODE_NAME" != "__unset__" ]; then
    NODE_NAME="${_RAW_NODE_NAME// /-}"
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
  ls -1t "$BACKUP_DIR"/xray-*.json 2>/dev/null | tail -n +6 | xargs -r rm -f
  ls -1t "$BACKUP_DIR"/hy2-*.yaml  2>/dev/null | tail -n +6 | xargs -r rm -f
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
  local arch asset
  if version_ge "$XRAY_VERSION" "26.9.8"; then
    warn "Xray ${XRAY_VERSION} >= 26.9.8: REALITY 强制要求 X25519MLKEM768"
    warn "  小火箭/Stash 发不出该字段, 会「开关变绿但打不开网页」"
  fi
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)  asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的架构: $arch" ;;
  esac

  # 注意: xray version 输出形如 "Xray 26.3.27 (...)", 版本号不带 v 前缀
  if [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version 2>/dev/null | head -1 | grep -qF "${XRAY_VERSION}"; then
    ok "Xray v${XRAY_VERSION} 已安装, 跳过"
    return 0
  fi

  info "下载 Xray v${XRAY_VERSION} ..."
  local tmp; tmp=$(mktemp -d)
  download_with_mirror \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${asset}" \
    "$tmp/x.zip" || die "Xray 下载失败(检查服务器能否访问 GitHub)"
  unzip -o -q "$tmp/x.zip" -d "$tmp/pkg" || die "Xray 解压失败"
  [ -f "$tmp/pkg/xray" ] || die "压缩包内未找到 xray"
  systemctl stop xray >/dev/null 2>&1 || true
  install -m 755 "$tmp/pkg/xray" "$XRAY_BIN"
  mkdir -p /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  cp -f "$tmp/pkg/geoip.dat"   /usr/local/share/xray/ 2>/dev/null || true
  cp -f "$tmp/pkg/geosite.dat" /usr/local/share/xray/ 2>/dev/null || true
  rm -rf "$tmp"
  ok "Xray 已安装: $($XRAY_BIN version 2>/dev/null | head -1)"
}

ensure_creds(){
  if [ -n "${UUID:-}" ] && [ -n "${PRIV:-}" ] && [ -n "${PUB:-}" ] && [ -n "${SID:-}" ]; then
    ok "复用已有凭据 (UUID: ${UUID:0:8}...)"
    return 0
  fi
  info "生成 UUID / x25519 密钥 / shortId ..."
  UUID=$(cat /proc/sys/kernel/random/uuid)
  SID=$(openssl rand -hex 8)
  local keys
  keys=$($XRAY_BIN x25519 2>/dev/null)
  PRIV=$(echo "$keys" | grep -i 'private' | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
  PUB=$(echo "$keys"  | grep -iE 'public|password' | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
  if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
    PRIV=$(echo "$keys" | grep -oE '[A-Za-z0-9_-]{43}' | sed -n 1p)
    PUB=$(echo "$keys"  | grep -oE '[A-Za-z0-9_-]{43}' | sed -n 2p)
  fi
  [ -n "$PRIV" ] && [ -n "$PUB" ] || die "x25519 密钥生成失败(输出格式无法解析), 请确认 xray x25519 可正常执行"
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
write_xray_config(){
  local dest="$1" dns_json=""
  ensure_users_file
  build_clients_json
  if [ "$WITH_DNS" = "1" ]; then
    dns_json='  "dns": { "servers": [ "1.1.1.1", "8.8.8.8", "localhost" ], "queryStrategy": "UseIPv4" },'
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
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "blackhole", "tag": "block" }
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
  # 带 DNS 块的配置若不被当前版本接受, 自动去掉 DNS 块重写一次
  if [ -n "$dns_json" ] && ! $XRAY_BIN run -test -c "$XRAY_CFG" >/dev/null 2>&1; then
    warn "内置 DNS 配置不被当前 Xray 版本接受, 回退为系统解析"
    WITH_DNS=0
    write_xray_config "$dest"
  fi
}

verify_reality(){
  local dest="$1" code
  cat > /tmp/_tc.json <<EOF
{
  "log": { "loglevel": "error" },
  "inbounds": [ { "port": 10899, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": false } } ],
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
  $XRAY_BIN -c /tmp/_tc.json >/tmp/_tc.log 2>&1 &
  local pid=$!
  sleep 3
  code=$(curl -s --socks5-hostname 127.0.0.1:10899 -o /dev/null -w '%{http_code}' --max-time 15 https://www.google.com 2>/dev/null)
  kill $pid >/dev/null 2>&1; wait $pid 2>/dev/null
  rm -f /tmp/_tc.json /tmp/_tc.log
  case "$code" in 200|204|301|302) return 0 ;; *) return 1 ;; esac
}

# 黑名单: 实测不能用作 REALITY 伪装目标
BLOCKED_DESTS="www.cloudflare.com cloudflare.com 1.1.1.1 www.apple.com apple.com www.icloud.com icloud.com www.microsoft.com microsoft.com"
is_blocked(){
  local d="$1" b
  for b in $BLOCKED_DESTS; do [ "$d" = "$b" ] && return 0; done
  return 1
}

# 检测目标站是否套在 Cloudflare 后面(看证书签发者)
# 用于拦住"用户把自己套了 CF 的域名填进来"这种情况
dest_behind_cloudflare(){
  local d="$1" issuer
  issuer=$(timeout 8 openssl s_client -connect "${d}:443" -servername "$d" </dev/null 2>/dev/null \
           | openssl x509 -noout -issuer 2>/dev/null)
  [ -n "$issuer" ] || return 1
  echo "$issuer" | grep -qi "cloudflare"
}

pick_dest(){
  local cands=() d h
  [ -n "$REALITY_DEST" ] && cands+=("$REALITY_DEST")
  cands+=(www.bing.com dl.google.com www.samsung.com www.amazon.com \
          www.tesla.com www.nvidia.com www.adobe.com www.ibm.com)

  info "挑选伪装目标站(需通过真实 REALITY 握手)..."
  for d in "${cands[@]}"; do
    if is_blocked "$d"; then
      warn "$d 在排除名单(CDN/证书链共用/不回显 session_id), 跳过"; continue
    fi
    if dest_behind_cloudflare "$d"; then
      warn "$d 证书由 Cloudflare 签发(站点套了 CF), TLS 行为不稳定, 跳过"; continue
    fi
    h=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 "https://$d/" 2>/dev/null)
    if [ "$h" = "000" ]; then warn "$d 不可达, 跳过"; continue; fi
    write_xray_config "$d"
    $XRAY_BIN run -test -c "$XRAY_CFG" >/dev/null 2>&1 || { warn "$d 配置校验失败, 跳过"; continue; }
    systemctl restart xray >/dev/null 2>&1
    sleep 2
    systemctl is-active --quiet xray || { warn "$d: xray 启动失败, 跳过"; continue; }
    if verify_reality "$d"; then
      DEST="$d"; ok "$d 握手通过 (HTTP $h)"; return 0
    fi
    warn "$d 握手失败, 换下一个"
  done
  # 全部失败: 把服务恢复到上一次能用的配置, 不要留在最后一个失败配置上
  local last
  last=$(ls -1t "$BACKUP_DIR"/xray-*.json 2>/dev/null | head -1)
  if [ -n "$last" ]; then
    cp -f "$last" "$XRAY_CFG"
    systemctl restart xray >/dev/null 2>&1
    warn "已回滚到上一次可用配置: $(basename "$last")"
  fi
  return 1
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
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
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
ensure_hy2(){
  local arch asset
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)  asset="hysteria-linux-amd64" ;;
    aarch64|arm64) asset="hysteria-linux-arm64" ;;
    *) die "不支持的架构: $arch" ;;
  esac

  if [ -x "$HY2_BIN" ]; then
    ok "Hysteria2 已安装, 跳过"
  else
    info "下载 Hysteria2 ..."
    download_with_mirror \
      "https://github.com/apernet/hysteria/releases/latest/download/${asset}" \
      /tmp/hy2.bin || die "Hysteria2 下载失败"
    chmod +x /tmp/hy2.bin
    systemctl stop hysteria-server >/dev/null 2>&1 || true
    install -m 755 /tmp/hy2.bin "$HY2_BIN"
    rm -f /tmp/hy2.bin
    ok "Hysteria2 已安装: $($HY2_BIN version 2>/dev/null | head -1)"
  fi

  [ -n "${HY2_PASS:-}" ] || HY2_PASS=$(openssl rand -hex 12)
  if [ "$ENABLE_OBFS" = "1" ] && [ -z "${OBFS_PASS:-}" ]; then
    OBFS_PASS=$(openssl rand -hex 10)
  fi

  mkdir -p /etc/hysteria
  if [ ! -f /etc/hysteria/cert.pem ] || [ ! -f /etc/hysteria/key.pem ]; then
    openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/key.pem 2>/dev/null || die "证书私钥生成失败"
    openssl req -new -x509 -days 3650 -key /etc/hysteria/key.pem \
      -out /etc/hysteria/cert.pem -subj "/CN=${DEST}" 2>/dev/null || die "证书生成失败"
  fi
  chmod 600 /etc/hysteria/key.pem

  {
    echo "listen: :${HY2_PORT}"
    echo ""
    echo "tls:"
    echo "  cert: /etc/hysteria/cert.pem"
    echo "  key: /etc/hysteria/key.pem"
    echo ""
    echo "auth:"
    echo "  type: password"
    echo "  password: ${HY2_PASS}"
    echo ""
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
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
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
  systemctl is-active --quiet hysteria-server || die "Hysteria2 未能启动, 查看: journalctl -u hysteria-server -n 30"
  ok "Hysteria2 运行中, 监听 UDP ${HY2_PORT}"

  # 自签证书必须靠指纹固定来验证身份, 否则 insecure 等于对中间人完全敞开
  compute_cert_pins || warn "证书指纹计算失败"
  if [ "$HY2_INSECURE" = "1" ]; then
    HY2_PIN=""
    warn "HY2_INSECURE=1: 客户端将跳过证书验证, 链路上可被冒充(仅建议临时调试)"
  elif resolve_hy2_pin; then
    if [ "${HY2_PIN_UNVERIFIED:-0}" = "1" ]; then
      warn "证书固定已写入配置, 但本机自测不通(常见于 UDP 回环受限), 以客户端实测为准"
    else
      ok "证书固定已生效: ${HY2_PIN:0:24}..."
    fi
  else
    HY2_PIN=""
    warn "证书固定自测失败, 回退 insecure; 建议检查 hysteria 版本是否支持 pinSHA256"
  fi
}

# 自签证书的三种指纹表示, 对应不同客户端字段:
#   SPKI 公钥 SHA-256 (base64) -> hysteria2 URI pinSHA256 / sing-box certificate_public_key_sha256
#   整证书 SHA-256   (base64) -> 部分实现按整证书校验, 作为兜底
#   证书指纹         (hex)    -> mihomo / Clash 系 fingerprint
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

# 用真实握手逐个验证指纹形式, 不靠猜算法
# 两种都不通时再测 insecure: 若 insecure 也不通, 说明是本机 UDP 回环问题而非指纹问题
resolve_hy2_pin(){
  local v
  HY2_PIN_UNVERIFIED=0
  for v in "${CERT_SPKI_B64:-}" "${CERT_DER_B64:-}"; do
    [ -n "$v" ] || continue
    if verify_hy2 "$v"; then HY2_PIN="$v"; return 0; fi
  done
  if ! verify_hy2 ""; then
    HY2_PIN="${CERT_SPKI_B64:-}"
    HY2_PIN_UNVERIFIED=1
    [ -n "$HY2_PIN" ]
    return $?
  fi
  return 1
}

verify_hy2(){
  local pin="${1:-}" code
  {
    echo "server: 127.0.0.1:${HY2_PORT}"
    echo "auth: ${HY2_PASS}"
    echo "tls:"
    echo "  sni: ${DEST}"
    if [ -n "$pin" ]; then
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
  } > /tmp/_hc.yaml
  $HY2_BIN client -c /tmp/_hc.yaml >/tmp/_hc.log 2>&1 &
  local pid=$!
  sleep 4
  code=$(curl -s --socks5-hostname 127.0.0.1:10898 -o /dev/null -w '%{http_code}' --max-time 15 https://www.gstatic.com/generate_204 2>/dev/null)
  case "$code" in 000|"") code=$(curl -s --socks5-hostname 127.0.0.1:10898 -o /dev/null -w '%{http_code}' --max-time 20 https://www.youtube.com 2>/dev/null) ;; esac
  kill $pid >/dev/null 2>&1; wait $pid 2>/dev/null
  rm -f /tmp/_hc.yaml /tmp/_hc.log
  case "$code" in 2*|3*) return 0 ;; *) return 1 ;; esac
}

# ---------------- 端口跳跃 ----------------
setup_hy2_hop(){
  [ -n "${HY2_HOP:-}" ] || return 0
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
optimize_system(){
  info "内核参数与 BBR ..."
  cat > /etc/sysctl.d/99-proxy-optimize.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
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
SYSCTL
  sysctl -p /etc/sysctl.d/99-proxy-optimize.conf >/dev/null 2>&1
  ok "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

  # conntrack 上限已写进 sysctl 持久化, 这里补一次运行时生效
  if [ -w /proc/sys/net/netfilter/nf_conntrack_max ]; then
    echo 65536 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
    ok "conntrack_max: $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
  fi

  # journald 限容: 小硬盘机器最容易被日志写满
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-proxy-size.conf <<'JOURNAL'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=20M
JOURNAL
  systemctl restart systemd-journald >/dev/null 2>&1 && ok "journald 日志上限: 100M"

  if [ "$(free -m | awk '/Swap:/{print $2}')" = "0" ] && [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null
    chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "已添加 1GB swap"
  else
    ok "swap 已就绪"
  fi
}

# ---------------- 健康检查 ----------------
install_healthcheck(){
  cat > /usr/local/bin/proxy-healthcheck.sh <<'HEALTH'
#!/usr/bin/env bash
# 由 proxy-installer 安装
# 每 5 分钟查进程/端口; 每 6 次(约 30 分钟)做一次真实隧道探测, 连续失败才重启
set -u
ST=/etc/proxy-node/state.env
FAIL=/run/proxy-healthcheck.fail
TICK=/run/proxy-healthcheck.tick
[ -f "$ST" ] || exit 0
# shellcheck disable=SC1090
. "$ST"

restart_xray(){
  systemctl restart xray >/dev/null 2>&1
  logger -t proxy-healthcheck "xray 异常($1), 已重启"
  echo 0 > "$FAIL" 2>/dev/null || true
}

if ! systemctl is-active --quiet xray; then restart_xray "进程不在"; fi
if ! ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${VLESS_PORT}$"; then
  restart_xray "端口未监听"
fi

n=$(cat "$TICK" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$(( n + 1 ))
echo "$n" > "$TICK" 2>/dev/null || true

if [ $(( n % 6 )) -eq 0 ]; then
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

if ! systemctl is-active --quiet hysteria-server; then
  systemctl restart hysteria-server >/dev/null 2>&1
  logger -t proxy-healthcheck "hysteria2 异常, 已重启"
fi
HEALTH
  chmod 755 /usr/local/bin/proxy-healthcheck.sh

  cat > /etc/systemd/system/proxy-healthcheck.service <<'UNIT'
[Unit]
Description=Proxy health check (one shot)

[Service]
Type=oneshot
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
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${VLESS_PORT}/tcp" >/dev/null 2>&1
    ufw allow "${HY2_PORT}/udp"  >/dev/null 2>&1
    ok "ufw 已放行 ${VLESS_PORT}/tcp, ${HY2_PORT}/udp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${VLESS_PORT}/tcp" >/dev/null 2>&1
    firewall-cmd --permanent --add-port="${HY2_PORT}/udp"  >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld 已放行"
  else
    ok "本机防火墙未启用, 请确认云安全组已放行 TCP ${VLESS_PORT} / UDP ${HY2_PORT}"
  fi
}

# ---------------- 链接生成 ----------------
gen_links(){
  PRIMARY_UUID=$(primary_uuid)
  VLESS_LINK="vless://${PRIMARY_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${NODE_NAME}-VLESS"
  local hb="hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=${DEST}"
  if [ -n "${HY2_HOP:-}" ]; then hb="${hb}&mport=${HY2_HOP}"; fi
  if [ "$ENABLE_OBFS" = "1" ]; then
    hb="${hb}&obfs=salamander&obfs-password=${OBFS_PASS}"
  fi
  if [ -n "${HY2_PIN:-}" ]; then
    # base64 里的 + 在 query 中会被解析成空格, 必须转义; / 和 = 在 query 值里合法
    HY2_LINK="${hb}&pinSHA256=${HY2_PIN//+/%2B}#${NODE_NAME}-HY2"
    # v2rayN 7.x 不识别 pinSHA256(二进制中无此字符串), 只认 insecure, 故单独给一条兼容链接
    HY2_LINK_COMPAT="${hb}&insecure=1#${NODE_NAME}-HY2-v2rayN"
  else
    HY2_LINK="${hb}&insecure=1#${NODE_NAME}-HY2"
    HY2_LINK_COMPAT=""
  fi
}

# ---------------- 订阅文件 ----------------
gen_sub_files(){
  PRIMARY_UUID="${PRIMARY_UUID:-$(primary_uuid)}"
  mkdir -p "$SUB_DIR"; chmod 755 "$SUB_DIR"
  # 放一个 index.html 遮住目录列表, 否则访问根路径会把 token 目录名列出来
  if [ ! -f "$SUB_DIR/index.html" ]; then
    cat > "$SUB_DIR/index.html" <<'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>404</title></head>
<body><h1>Not Found</h1><p>The requested URL was not found on this server.</p></body></html>
HTML
    chmod 644 "$SUB_DIR/index.html"
  fi
  [ -n "${SUB_TOKEN:-}" ] || SUB_TOKEN=$(openssl rand -hex 16)
  local tdir="${SUB_DIR}/${SUB_TOKEN}"
  mkdir -p "$tdir"; chmod 755 "$tdir"

  printf '%s\n%s\n' "$VLESS_LINK" "$HY2_LINK" > "$tdir/links.txt"

  { printf '%s\n%s\n' "$VLESS_LINK" "$HY2_LINK" | base64 -w0; echo ""; } > "$tdir/base64.txt"

  {
    echo "mixed-port: 7890"
    echo "allow-lan: false"
    echo "mode: rule"
    echo "log-level: info"
    echo "proxies:"
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
    echo "  - name: \"${NODE_NAME}-HY2\""
    echo "    type: hysteria2"
    echo "    server: ${SERVER_IP}"
    echo "    port: ${HY2_PORT}"
    echo "    password: \"${HY2_PASS}\""
    echo "    sni: ${DEST}"
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
    echo "proxy-groups:"
    echo "  - name: PROXY"
    echo "    type: select"
    echo "    proxies:"
    echo "      - \"${NODE_NAME}-VLESS\""
    echo "      - \"${NODE_NAME}-HY2\""
    echo "rules:"
    echo "  - MATCH,PROXY"
  } > "$tdir/clash.yaml"

  local sbox_hy2_tls
  if [ -n "${HY2_PIN:-}" ] && [ -n "${CERT_SPKI_B64:-}" ]; then
    sbox_hy2_tls="\"tls\": { \"enabled\": true, \"server_name\": \"${DEST}\", \"certificate_public_key_sha256\": [\"${CERT_SPKI_B64}\"] }"
  else
    sbox_hy2_tls="\"tls\": { \"enabled\": true, \"server_name\": \"${DEST}\", \"insecure\": true }"
  fi

  cat > "$tdir/singbox.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080 }
  ],
  "outbounds": [
    {
      "type": "vless", "tag": "vless-out",
      "server": "${SERVER_IP}", "server_port": ${VLESS_PORT},
      "uuid": "${PRIMARY_UUID}", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "${DEST}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "${PUB}", "short_id": "${SID}" }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-out",
      "server": "${SERVER_IP}", "server_port": ${HY2_PORT},
      "password": "${HY2_PASS}",
      ${sbox_hy2_tls}
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "vless-out" }
}
EOF

  cat > "$tdir/client-guide.md" <<GUIDE
# 客户端配置指南

节点: ${SERVER_IP}   VLESS/TCP ${VLESS_PORT}   Hysteria2/UDP ${HY2_PORT}
伪装域名: ${DEST}

## 一、Hysteria2 是自签证书, 靠指纹固定验证身份

服务端没有公共 CA 证书。客户端不要勾"跳过证书验证", 改用指纹固定 ——
指纹只能来自这台服务器, 链路上换不了, 安全性等同于正式证书。

| 客户端 | 怎么填 |
|---|---|
| sing-box | tls.certificate_public_key_sha256 填 SPKI 那行, 真固定 |
| mihomo / Clash Verge | skip-cert-verify: false + fingerprint 填 hex 那行, 真固定 |
| hysteria2 官方客户端 / 小火箭 | 用带 pinSHA256 的链接 |
| v2rayN 7.x | **不识别 pinSHA256**, 只能用下面的兼容链接 |

v2rayN 的 Hysteria2 界面只有"跳过证书验证"一个勾选框, 没有指纹字段。
想真正固定指纹, 请用 Clash Verge Rev 或 sing-box。v2rayN 兼容链接(无身份验证):

${HY2_LINK_COMPAT:-当前未生成}

指纹 pinSHA256 (hysteria2 链接里已带):
${HY2_PIN:-未启用, 当前为 insecure}

指纹 SPKI (sing-box certificate_public_key_sha256):
${CERT_SPKI_B64:-未计算}

指纹 hex (mihomo fingerprint):
${CERT_HEX:-未计算}

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

4. DNS 不要只押一个 DoH
   若所有域名都走 https://cloudflare-dns.com/dns-query 并经代理出去,
   节点一抖 DNS 就全超时, 表现同样是全断。
   建议国内域名走 223.5.5.5 直连, 只有需要代理的才走远程解析。

## 三、卡住时怎么定位

TUN 开着的情况下依次执行(Windows):

    ping 1.1.1.1             通 -> 路由正常, 问题在 DNS; 不通 -> 网卡或路由没起来
    ipconfig /all            看是否多出一块 TUN 网卡、是否拿到 IP
    route print              看默认路由 0.0.0.0 指向哪块网卡
    nslookup www.baidu.com   看 DNS 是否可用

## 四、Windows 上 v2rayN 还差一个文件

v2rayN 的 TUN 由 sing-box 内核实现, 需要 wintun.dll。
若 bin\\sing_box\\ 目录里没有该文件, 把 bin\\xray\\wintun.dll 复制过去即可,
否则 TUN 网卡根本创建不出来。
GUIDE
  chmod 644 "$tdir/client-guide.md"

  chmod -R 755 "$tdir"
  SUB_TOKEN_DIR="$tdir"
  ok "订阅文件已生成: ${tdir}"
}

maybe_sub_http(){
  [ "$SUB_HTTP" = "1" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    warn "未安装 python3, 跳过订阅 HTTP 服务"
    return 0
  fi
  [ -n "${SUB_PORT:-}" ] || SUB_PORT=$(( (RANDOM % 10000) + 30000 ))
  cat > /etc/systemd/system/proxy-sub.service <<EOF
[Unit]
Description=Proxy Subscription HTTP
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${SUB_DIR}
ExecStart=$(command -v python3) -m http.server ${SUB_PORT} --bind ${SUB_BIND} --directory ${SUB_DIR}
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
print_links(){
  echo
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
  hr
  echo -e "${M}Hysteria2${N}   UDP ${HY2_PORT}"
  hr
  echo "密码      : ${HY2_PASS}"
  echo "SNI       : ${DEST}"
  if [ -n "${HY2_PIN:-}" ]; then
    echo "证书固定  : 已启用 (pinSHA256, 无需 insecure)"
    echo "  指纹    : ${HY2_PIN}"
    [ -n "${CERT_HEX:-}" ] && echo "  mihomo  : fingerprint: ${CERT_HEX}"
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
}

print_qr(){
  command -v qrencode >/dev/null 2>&1 || return 0
  echo -e "${B}--- VLESS 二维码 ---${N}"
  qrencode -t ANSIUTF8 -m 1 "$VLESS_LINK" 2>/dev/null || true
  echo
  echo -e "${B}--- Hysteria2 二维码 ---${N}"
  qrencode -t ANSIUTF8 -m 1 "$HY2_LINK" 2>/dev/null || true
  echo
}

print_sub_info(){
  echo
  hr
  echo -e "${M}订阅文件${N}"
  hr
  echo "目录: ${SUB_TOKEN_DIR:-${SUB_DIR}}"
  echo "  links.txt      原始链接(两行)"
  echo "  base64.txt     通用订阅, 小火箭 / v2rayN / v2rayNG 可直接导入"
  echo "  clash.yaml     Clash / mihomo / Clash Verge"
  echo "  singbox.json   sing-box 客户端"
  echo "  client-guide.md 客户端配置指南(证书固定 / TUN 参数 / 排障)"
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

self_check(){
  info "部署后自检 ..."
  local code
  code=$(curl -s --socks5-hostname 127.0.0.1:10899 -o /dev/null -w '%{http_code}' --max-time 15 https://www.tiktok.com 2>/dev/null)
  info "TikTok 连通性: HTTP ${code:-000}"
  if verify_hy2 "${HY2_PIN:-}"; then
    if [ -n "${HY2_PIN:-}" ]; then ok "Hysteria2 链路: 通过 (证书固定已验证, 无 insecure)"; else ok "Hysteria2 链路: 通过 (insecure)"; fi
  else
    warn "Hysteria2 链路: 未验证通过(本机 UDP 回环可能受限, 以客户端实测为准)"
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
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  echo
  echo -e "${M}============================================================${N}"
  echo -e "${M}   Proxy Node Installer v${SCRIPT_VERSION}${N}"
  echo -e "${M}============================================================${N}"
  echo

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

  install_deps
  preflight

  if [ "$CLEAN" = "1" ]; then
    info "CLEAN=1: 先清理旧实例再安装"
    do_clean 0
    # 清掉内存里的旧凭据, 否则会"复用"刚删掉的那套
    UUID=""; PRIV=""; PUB=""; SID=""; DEST=""
    HY2_PASS=""; OBFS_PASS=""; SUB_TOKEN=""; SERVER_IP=""
    fresh=1
  fi

  if [ "$fresh" = "1" ]; then
    local owner=""
    owner=$(port_owner "$VLESS_PORT" tcp) || owner=""
    if [ -n "$owner" ]; then
      warn "TCP ${VLESS_PORT} 已被占用: ${owner}"
      ss -tlnp 2>/dev/null | awk -v p=":${VLESS_PORT}" '$4 ~ (p "$")'
      echo
      if echo "$owner" | grep -qE '^(xray|hysteria)'; then
        if ask_yes "这是本脚本残留的实例, 清理后继续?"; then
          do_clean 0
          sleep 1
        fi
      else
        if ask_yes "结束该进程(${owner})并继续?"; then
          kill_port_owner "$VLESS_PORT" tcp
          sleep 1
        fi
      fi
      if port_in_use "$VLESS_PORT" tcp; then
        die "端口仍被占用。可执行 bash setup-proxy.sh clean 清理, 或换端口: VLESS_PORT=8443 bash setup-proxy.sh install"
      fi
    fi
  fi

  ensure_xray
  ensure_xray_service
  ensure_creds

  SERVER_IP=$(get_server_ip)
  [ -n "$SERVER_IP" ] || die "无法获取公网 IP"
  ok "服务器 IP: ${SERVER_IP}"

  backup_config

  if [ -z "${DEST:-}" ]; then
    pick_dest || die "所有目标站握手失败。可手动指定: REALITY_DEST=www.samsung.com bash setup-proxy.sh"
  else
    info "复用伪装目标: ${DEST}"
  fi

  write_xray_config "$DEST"
  systemctl restart xray >/dev/null 2>&1
  sleep 2
  systemctl is-active --quiet xray || die "xray 启动失败, 查看: journalctl -u xray -n 30 --no-pager"
  ok "Xray 运行中: TCP ${VLESS_PORT}, 伪装目标 ${DEST}"

  ensure_hy2
  setup_hy2_hop
  optimize_system
  setup_firewall
  install_healthcheck

  save_state
  gen_links
  gen_sub_files
  maybe_sub_http
  save_state

  {
    echo "=========== 节点信息 ==========="
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "服务器 IP: ${SERVER_IP}"
    echo
    echo "[VLESS + REALITY]"
    echo "端口     : ${VLESS_PORT}"
    echo "UUID     : ${UUID}"
    echo "Flow     : xtls-rprx-vision"
    echo "SNI      : ${DEST}"
    echo "pbk      : ${PUB}"
    echo "shortId  : ${SID}"
    echo "fp       : chrome"
    echo "链接     : ${VLESS_LINK}"
    echo
    echo "[Hysteria2]"
    echo "端口(UDP): ${HY2_PORT}"
    echo "密码     : ${HY2_PASS}"
    echo "SNI      : ${DEST}"
    if [ -n "${HY2_PIN:-}" ]; then
      echo "证书固定 : pinSHA256"
      echo "指纹     : ${HY2_PIN}"
      echo "mihomo   : fingerprint: ${CERT_HEX:-}"
    else
      echo "insecure : 1"
    fi
    [ -n "${HY2_HOP:-}" ] && echo "端口跳跃 : ${HY2_HOP}"
    [ "$ENABLE_OBFS" = "1" ] && echo "混淆     : salamander / ${OBFS_PASS}"
    echo "链接     : ${HY2_LINK}"
    [ -n "${HY2_LINK_COMPAT:-}" ] && echo "v2rayN用 : ${HY2_LINK_COMPAT}  (v2rayN 不识别 pinSHA256, 此条无身份验证)"
    echo
    echo "[管理]"
    echo "proxy info | sub | status | restart | logs | reset | uninstall"
    echo "订阅目录: ${SUB_TOKEN_DIR:-${SUB_DIR}}"
  } > /root/proxy-info.txt
  chmod 600 /root/proxy-info.txt

  print_links
  print_qr
  print_sub_info
  self_check

  local self_path
  self_path=$(readlink -f "$0" 2>/dev/null || echo "")
  if [ -n "$self_path" ] && [ -f "$self_path" ] && [ "$self_path" != "/usr/local/bin/${APP_NAME}" ]; then
    ln -sf "$self_path" "/usr/local/bin/${APP_NAME}" 2>/dev/null && \
      ok "已安装管理命令: ${APP_NAME}  (例如 proxy info)"
  else
    warn "以管道方式运行, 未创建 ${APP_NAME} 命令"
    echo -e "    ${D}想要管理命令的话, 下次改用:${N}"
    echo -e "    ${D}curl -fsSL ${REPO_URL}/raw/main/setup.sh -o /root/setup-proxy.sh && bash /root/setup-proxy.sh${N}"
  fi

  echo
  echo -e "${G}============================================================${N}"
  echo -e "${G}   部署完成${N}"
  echo -e "${G}============================================================${N}"
  echo -e "  节点信息: ${Y}cat /root/proxy-info.txt${N}"
  echo -e "  管理菜单: ${Y}proxy${N}"
  echo
  echo -e "${Y}必做${N}: 云安全组放行 ${Y}TCP ${VLESS_PORT}${N} 和 ${Y}UDP ${HY2_PORT}${N}"
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
  print_links
  print_qr
  print_sub_info
}

cmd_sub(){
  need_root
  load_state || die "尚未安装"
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
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
  printf 'xray            : %s / %s\n' "$(systemctl is-active xray 2>/dev/null)" "$(systemctl is-enabled xray 2>/dev/null)"
  printf 'hysteria-server : %s / %s\n' "$(systemctl is-active hysteria-server 2>/dev/null)" "$(systemctl is-enabled hysteria-server 2>/dev/null)"
  [ -n "${HY2_HOP:-}" ] && printf 'hy2-hop         : %s\n' "$(systemctl is-active hy2-hop 2>/dev/null)"
  [ "$SUB_HTTP" = "1" ] && printf 'proxy-sub       : %s\n' "$(systemctl is-active proxy-sub 2>/dev/null)"
  echo
  echo -e "${M}监听端口${N}"
  ss -tulnp 2>/dev/null | grep -E ":(443|8443|54321|${VLESS_PORT}|${HY2_PORT})[[:space:]]" || echo "(未找到匹配端口)"
  echo
  echo -e "${M}出口 IPv4${N} : ${SERVER_IP:-未知}"
  echo -e "${M}Xray 版本${N} : $($XRAY_BIN version 2>/dev/null | head -1)"
  echo -e "${M}拥塞控制${N}  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo -e "${M}设备凭据${N}  : $(wc -l < "$USERS_FILE" 2>/dev/null || echo 0) 条 (proxy user list)"
  echo -e "${M}脚本版本${N}  : ${SCRIPT_VERSION}"
  echo
}

cmd_restart(){
  need_root
  load_state || die "尚未安装"
  systemctl restart xray hysteria-server 2>/dev/null
  sleep 2
  ok "xray: $(systemctl is-active xray)   hysteria-server: $(systemctl is-active hysteria-server)"
}

cmd_logs(){
  need_root
  local which="${1:-xray}"
  case "$which" in
    hy2|hysteria) journalctl -u hysteria-server -f -n 50 ;;
    *)            journalctl -u xray -f -n 50 ;;
  esac
}

# 通过本地 REALITY 隧道实测真实出口 IP
egress_ip_via_proxy(){
  cat > /tmp/_ec.json <<EOF
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
  $XRAY_BIN -c /tmp/_ec.json >/tmp/_ec.log 2>&1 &
  local pid=$! ip=""
  sleep 3
  ip=$(curl -s --socks5-hostname 127.0.0.1:10897 --max-time 12 https://api.ipify.org 2>/dev/null \
    || curl -s --socks5-hostname 127.0.0.1:10897 --max-time 12 https://ifconfig.me 2>/dev/null || echo "")
  kill $pid >/dev/null 2>&1; wait $pid 2>/dev/null
  rm -f /tmp/_ec.json /tmp/_ec.log
  echo "$ip" | tr -d '[:space:]'
}

cmd_audit(){
  need_root
  load_state || die "尚未安装"
  local dnsbl=0
  [ "${1:-}" = "--dnsbl" ] && dnsbl=1
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"

  echo
  hr
  echo -e "${M}出口 IP 实测${N}"
  hr
  echo "节点 IP        : ${SERVER_IP}"
  local eip; eip=$(egress_ip_via_proxy)
  if [ -z "$eip" ]; then
    warn "隧道实测失败, 无法确认出口(检查服务是否正常: proxy status)"
  elif [ "$eip" = "$SERVER_IP" ]; then
    ok "隧道出口 IP    : ${eip}  (与本机一致, 无中转/无泄漏)"
  else
    warn "隧道出口 IP    : ${eip}  (与本机 ${SERVER_IP} 不同!)"
    echo "   说明流量经过了中转或存在泄漏, TikTok 会看到 ${eip} 这个地址"
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
    warn "公网 IPv6      : 存在 ${ipv6pub} 个地址 (已由路由规则拦截, 但建议在服务商侧关掉)"
  else
    ok "公网 IPv6      : 无 (不会出现 IPv6 泄漏)"
  fi

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
  echo "拥塞控制       : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo "journald 上限  : $(journalctl --disk-usage 2>/dev/null | sed 's/.*take up //')"
  echo "磁盘占用       : $(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
  echo "内存           : $(free -m | awk '/Mem:/{print $3"MB / "$2"MB"}')"

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
  [ ] DNS 走远程          客户端设 8.8.8.8 / 1.1.1.1, 别用运营商 DNS
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
      [ -z "$(find_user_line "$name")" ] || die "已存在同名凭据: ${name}"
      local nu; nu=$(cat /proc/sys/kernel/random/uuid)
      printf '%s|%s|%s\n' "$nu" "$name" "$(date '+%Y-%m-%d')" >> "$USERS_FILE"
      write_xray_config "$DEST"
      systemctl restart xray >/dev/null 2>&1
      sleep 2
      systemctl is-active --quiet xray || die "xray 重启失败, 凭据文件保留在 ${USERS_FILE}"
      ok "已添加凭据: ${name}"
      echo
      echo -e "${G}$(user_vless_link "$nu" "$name")${N}"
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
      write_xray_config "$DEST"
      systemctl restart xray >/dev/null 2>&1
      sleep 2
      systemctl is-active --quiet xray || warn "xray 重启异常, 请检查: proxy logs"
      ok "已吊销: $(echo "$line" | cut -d'|' -f2)  (该设备的旧链接立即失效)"
      ;;
    link)
      local key="${2:-}" line
      [ -n "$key" ] || die "用法: proxy user link <名字或UUID前缀>"
      line=$(find_user_line "$key")
      [ -n "$line" ] || die "未找到凭据: ${key}"
      user_vless_link "$(echo "$line" | cut -d'|' -f1)" "$(echo "$line" | cut -d'|' -f2)"
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
  mkdir -p "$tmp/etc-proxy-node" "$tmp/etc-hysteria"

  [ -d "$STATE_DIR" ] && cp -a "$STATE_DIR/." "$tmp/etc-proxy-node/" 2>/dev/null
  [ -f /etc/hysteria/cert.pem ] && cp -a /etc/hysteria/cert.pem /etc/hysteria/key.pem "$tmp/etc-hysteria/" 2>/dev/null
  [ -f /root/proxy-info.txt ] && cp -a /root/proxy-info.txt "$tmp/" 2>/dev/null

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

  # 防路径穿越: 含绝对路径或 .. 的备份包直接拒绝
  if tar -tzf "$f" 2>/dev/null | grep -qE '^/|(^|/)\.\.(/|$)'; then
    die "备份包内含非法路径, 已中止"
  fi

  ask_yes "恢复会覆盖当前配置与凭据, 确认?" || { info "已取消"; return 0; }

  tmp=$(mktemp -d)
  tar -xzf "$f" -C "$tmp" || { rm -rf "$tmp"; die "解压失败"; }

  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  [ -d "$tmp/etc-proxy-node" ] && cp -a "$tmp/etc-proxy-node/." "$STATE_DIR/" 2>/dev/null
  if [ -d "$tmp/etc-hysteria" ]; then
    mkdir -p /etc/hysteria
    cp -a "$tmp/etc-hysteria/." /etc/hysteria/ 2>/dev/null
    chmod 600 /etc/hysteria/key.pem 2>/dev/null || true
  fi
  rm -rf "$tmp"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
  [ -f "$USERS_FILE" ] && chmod 600 "$USERS_FILE"

  load_state || die "恢复后的状态文件无法读取"

  # 换 VPS 时公网 IP 会变, 重新探测, 否则链接里还是旧地址
  SERVER_IP=$(get_server_ip)
  info "服务器 IP: ${SERVER_IP:-未知}"

  ensure_xray
  ensure_xray_service
  write_xray_config "$DEST"
  systemctl restart xray >/dev/null 2>&1
  sleep 2
  systemctl is-active --quiet xray || die "xray 启动失败, 查看: journalctl -u xray -n 30"
  ensure_hy2
  setup_firewall
  install_healthcheck
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
  rm -f "$USERS_FILE"
  save_state
  info "重新生成凭据..."
  ensure_creds
  backup_config
  pick_dest || die "目标站选择失败"
  write_xray_config "$DEST"
  systemctl restart xray >/dev/null 2>&1; sleep 2
  ensure_hy2
  save_state
  gen_links; gen_sub_files; maybe_sub_http; save_state
  print_links
  ok "凭据已重置, 请重新导入所有客户端"
}

cmd_upgrade(){
  need_root
  local target="${1:-latest}" asset tmp
  case "$(uname -m)" in
    x86_64|amd64)  asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
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

  local url
  if [ "$target" = "latest" ]; then
    url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"
  else
    url="https://github.com/XTLS/Xray-core/releases/download/v${target}/${asset}"
  fi

  ask_yes "安装 Xray ${target}?  当前: $($XRAY_BIN version 2>/dev/null | head -1)" || { info "已取消"; return 0; }

  tmp=$(mktemp -d)
  download_with_mirror "$url" "$tmp/x.zip" || { rm -rf "$tmp"; die "下载失败(版本号是否存在?)"; }
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
    warn "新版本启动失败, 自动回滚"
    cp -f "${XRAY_BIN}.prev" "$XRAY_BIN" 2>/dev/null
    systemctl start xray >/dev/null 2>&1
    die "已回滚到上一版本, 查看: journalctl -u xray -n 30"
  fi
  ok "已安装: $($XRAY_BIN version 2>/dev/null | head -1)"
  echo -e "${D}回滚: proxy upgrade --rollback${N}"
}

# ---------------- 清理 ----------------
# 只删本脚本创建的东西; remove_script=1 时连管理命令与脚本一起删
do_clean(){
  local remove_script="${1:-0}" hop="" hp="" p o

  # 状态目录随后就被删, 先把端口跳跃信息读出来
  if load_state 2>/dev/null; then
    hop="${HY2_HOP:-}"
    hp="${HY2_PORT:-}"
  fi

  systemctl disable --now xray hysteria-server hy2-hop proxy-sub proxy-healthcheck.timer >/dev/null 2>&1 || true

  rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria-server.service \
        /etc/systemd/system/hy2-hop.service /etc/systemd/system/proxy-sub.service \
        /etc/systemd/system/proxy-healthcheck.service /etc/systemd/system/proxy-healthcheck.timer
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true

  # 只杀本脚本自己的二进制, 不碰系统里其它程序
  pkill -f '^/usr/local/bin/xray' >/dev/null 2>&1 || true
  pkill -f '^/usr/local/bin/hysteria' >/dev/null 2>&1 || true
  sleep 1

  # 端口跳跃的 NAT 规则(可能残留多条)
  if [ -n "$hop" ] && [ -n "$hp" ]; then
    while iptables -t nat -C PREROUTING -p udp --dport "$hop" -j REDIRECT --to-ports "$hp" 2>/dev/null; do
      iptables -t nat -D PREROUTING -p udp --dport "$hop" -j REDIRECT --to-ports "$hp" 2>/dev/null || break
    done
  fi

  rm -rf /usr/local/etc/xray /usr/local/share/xray /etc/hysteria "$SUB_DIR" "$STATE_DIR"
  rm -f "$XRAY_BIN" "${XRAY_BIN}.prev" "$HY2_BIN" /root/proxy-info.txt \
        /usr/local/bin/proxy-healthcheck.sh \
        /etc/sysctl.d/99-proxy-optimize.conf \
        /etc/systemd/journald.conf.d/99-proxy-size.conf
  sysctl --system >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  rm -f /run/proxy-healthcheck.fail /run/proxy-healthcheck.tick

  if [ "$remove_script" = "1" ]; then
    rm -f "/usr/local/bin/${APP_NAME}" /root/setup-proxy.sh
  fi

  # 复查端口是否真的空了
  for p in "${VLESS_PORT:-443}" "${HY2_PORT:-443}"; do
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

# ---------------- 菜单 ----------------
menu(){
  while true; do
    echo
    echo -e "${M}============================================${N}"
    echo -e "${M}   Proxy Node 管理菜单${N}"
    echo -e "${M}============================================${N}"
    if load_state 2>/dev/null; then
      echo -e "  节点 ${G}${NODE_NAME}${N}   IP ${SERVER_IP:-?}   VLESS ${VLESS_PORT}   HY2 ${HY2_PORT}"
      echo -e "  SNI  ${DEST:-?}"
    else
      echo -e "  ${Y}尚未安装${N}"
    fi
    echo
    echo "  1) 安装 / 重新部署 (幂等, 不换凭据)"
    echo "  2) 查看节点信息与链接"
    echo "  3) 重新生成订阅文件"
    echo "  4) 服务状态"
    echo "  5) 重启服务"
    echo "  6) 实时日志 (xray)"
    echo "  7) 实时日志 (hysteria2)"
    echo "  8) 线路体检 (出口 IP / PTR / 时间 / 客户端清单)"
    echo "  a) 设备凭据 (多设备 UUID / 单独吊销)"
    echo "  9) 重置凭据 (换 UUID/密钥, 需重新导入)"
    echo "  b) 备份配置 (迁移到新 VPS 用)"
    echo "  c) 清除所有配置 (端口被占用时用这个)"
    echo "  u) 卸载 (等同清除)"
    echo "  0) 退出"
    echo
    local c=""
    read -rp "请选择: " c </dev/tty 2>/dev/null || c="0"
    case "$c" in
      1) cmd_install ;;
      2) cmd_info ;;
      3) cmd_sub ;;
      4) cmd_status ;;
      5) cmd_restart ;;
      6) cmd_logs xray ;;
      7) cmd_logs hy2 ;;
      8) cmd_audit ;;
      a|A) cmd_user list ;;
      9) cmd_reset ;;
      b|B) cmd_backup ;;
      c|C) cmd_clean ;;
      u|U) cmd_clean ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

usage(){
  cat <<'USAGE'
Proxy Node Installer v3

用法:
  bash setup-proxy.sh [命令]

命令:
  (无参数)         首次=自动安装, 已安装=打开管理菜单
  install          安装/重新部署(幂等, 保留凭据)
  info             查看节点信息、链接、二维码
  sub              重新生成订阅文件
  status           服务状态与监听端口
  restart          重启 xray 与 hysteria2
  logs [xray|hy2]  实时日志
  audit [--dnsbl]  线路体检(出口 IP / PTR / 时间 / 客户端清单)
  user [子命令]    多设备凭据: list(默认) / add <名字> / link <名字> / rm <名字>
  reset            重置凭据(会作废现有客户端)
  backup [文件]    打包状态/凭据/证书, 用于迁移
  restore <文件>   从备份恢复(换 VPS 时用, 会自动重新探测 IP)
  clean [--all]    清除所有配置与服务(端口被占用时用这个)
  uninstall        等同 clean
  upgrade [版本]   升级 Xray 内核; upgrade --rollback 回滚上一版

首次安装可用的环境变量:
  VLESS_PORT=443  HY2_PORT=443
  REALITY_DEST=www.bing.com      指定伪装站(留空=自动挑选)
  ENABLE_OBFS=1                  开启 hy2 salamander 混淆
  HY2_HOP=20000-30000            hy2 UDP 端口跳跃
  HY2_INSECURE=1                 关闭证书固定, 退回 insecure(不推荐)
  SUB_HTTP=1                     起订阅 HTTP 服务
  SUB_BIND=0.0.0.0               订阅服务监听地址(默认 127.0.0.1)
  CLEAN=1                        安装前先彻底清理旧实例
  ASSUME_YES=1                   全程不询问

示例:
  bash setup-proxy.sh
  CLEAN=1 bash setup-proxy.sh install          端口被占用时一条命令重来
  bash setup-proxy.sh clean --all             连管理命令一起删干净
  VLESS_PORT=8443 HY2_PORT=8443 bash setup-proxy.sh install
  ENABLE_OBFS=1 HY2_HOP=20000-30000 bash setup-proxy.sh install
USAGE
}

# ---------------- 入口 ----------------
main(){
  case "${1:-}" in
    install)        cmd_install ;;
    info)           cmd_info ;;
    sub)            cmd_sub ;;
    status)         cmd_status ;;
    restart)        cmd_restart ;;
    logs)           cmd_logs "${2:-xray}" ;;
    audit)          cmd_audit "${2:-}" ;;
    user)           cmd_user "${2:-list}" "${3:-}" ;;
    reset)          cmd_reset ;;
    backup)         cmd_backup "${2:-}" ;;
    restore)        cmd_restore "${2:-}" ;;
    clean|uninstall|purge) cmd_clean "${2:-}" "${3:-}" ;;
    upgrade)        cmd_upgrade "${2:-}" ;;
    help|-h|--help) usage ;;
    "")
      if load_state 2>/dev/null; then menu; else cmd_install; fi
      ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
