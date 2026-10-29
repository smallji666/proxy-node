#!/usr/bin/env bash
# ============================================================
#  Proxy Node Installer  v2
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
#     bash setup-proxy.sh uninstall    卸载
#     bash setup-proxy.sh upgrade      升级内核(危险, 见警告)
#  环境变量(首次安装生效):
#     VLESS_PORT=443  HY2_PORT=443  REALITY_DEST=www.bing.com
#     ENABLE_OBFS=1   开启 hy2 salamander 混淆
#     HY2_HOP=20000-30000   hy2 UDP 端口跳跃
#     SUB_HTTP=1      起一个订阅 HTTP 服务(默认关)
#     ASSUME_YES=1    全程不询问
# ============================================================
set -uo pipefail

APP_NAME="proxy"
STATE_DIR="/etc/proxy-node"
STATE_FILE="${STATE_DIR}/state.env"
BACKUP_DIR="${STATE_DIR}/backup"
SUB_DIR="/var/www/proxy-sub"
LOG_FILE="/var/log/proxy-deploy.log"
# 发布到 GitHub 后, 把这里改成你自己的仓库地址(README 里的 sed 会一并替换)
REPO_URL="https://github.com/smallji666/proxy-node"

# ---------------- 记录用户显式传入的环境变量 ----------------
# 未传时置为哨兵值, 以便 load_state 之后判断是否需要覆盖
_RAW_VLESS_PORT="${VLESS_PORT-__unset__}"
_RAW_HY2_PORT="${HY2_PORT-__unset__}"
_RAW_XRAY_VERSION="${XRAY_VERSION-__unset__}"
_RAW_REALITY_DEST="${REALITY_DEST-__unset__}"
_RAW_ENABLE_OBFS="${ENABLE_OBFS-__unset__}"
_RAW_HY2_HOP="${HY2_HOP-__unset__}"
_RAW_SUB_HTTP="${SUB_HTTP-__unset__}"
_RAW_SUB_PORT="${SUB_PORT-__unset__}"
_RAW_NODE_NAME="${NODE_NAME-__unset__}"

# ---------------- 默认参数 ----------------
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-443}"
XRAY_VERSION="${XRAY_VERSION:-26.3.27}"
REALITY_DEST="${REALITY_DEST:-}"
ENABLE_OBFS="${ENABLE_OBFS:-0}"
HY2_HOP="${HY2_HOP:-}"
SUB_HTTP="${SUB_HTTP:-0}"
SUB_PORT="${SUB_PORT:-}"
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
    echo "SUB_TOKEN='${SUB_TOKEN:-}'"
    echo "SUB_PORT='${SUB_PORT:-}'"
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
  [ "$_RAW_SUB_HTTP"     != "__unset__" ] && SUB_HTTP="$_RAW_SUB_HTTP"
  [ "$_RAW_SUB_PORT"     != "__unset__" ] && SUB_PORT="$_RAW_SUB_PORT"
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
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"
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
  [ -n "$PRIV" ] && [ -n "$PUB" ] || die "x25519 密钥生成失败: $keys"
  ok "新凭据已生成"
}

# ---------------- Xray 配置 ----------------
write_xray_config(){
  local dest="$1"
  cat > "$XRAY_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ],
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
      "users": [ { "id": "${UUID}", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
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
  return 1
}

ensure_xray_service(){
  if [ ! -f /etc/systemd/system/xray.service ]; then
    cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
NoNewPrivileges=true
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

  if [ ! -f /etc/systemd/system/hysteria-server.service ]; then
    cat > /etc/systemd/system/hysteria-server.service <<'UNIT'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
User=root
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
}

verify_hy2(){
  local code
  {
    echo "server: 127.0.0.1:${HY2_PORT}"
    echo "auth: ${HY2_PASS}"
    echo "tls:"
    echo "  sni: ${DEST}"
    echo "  insecure: true"
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
  code=$(curl -s --socks5-hostname 127.0.0.1:10898 -o /dev/null -w '%{http_code}' --max-time 20 https://www.youtube.com 2>/dev/null)
  kill $pid >/dev/null 2>&1; wait $pid 2>/dev/null
  rm -f /tmp/_hc.yaml /tmp/_hc.log
  case "$code" in 200|301|302) return 0 ;; *) return 1 ;; esac
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
SYSCTL
  sysctl -p /etc/sysctl.d/99-proxy-optimize.conf >/dev/null 2>&1
  ok "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

  if [ "$(free -m | awk '/Swap:/{print $2}')" = "0" ] && [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null
    chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "已添加 1GB swap"
  else
    ok "swap 已就绪"
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
  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${NODE_NAME}-VLESS"
  HY2_LINK="hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=${DEST}&insecure=1"
  if [ -n "${HY2_HOP:-}" ]; then
    HY2_LINK="${HY2_LINK}&mport=${HY2_HOP}"
  fi
  if [ "$ENABLE_OBFS" = "1" ]; then
    HY2_LINK="${HY2_LINK}&obfs=salamander&obfs-password=${OBFS_PASS}"
  fi
  HY2_LINK="${HY2_LINK}#${NODE_NAME}-HY2"
}

# ---------------- 订阅文件 ----------------
gen_sub_files(){
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
    echo "    uuid: ${UUID}"
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
    echo "    skip-cert-verify: true"
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
      "uuid": "${UUID}", "flow": "xtls-rprx-vision",
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
      "tls": { "enabled": true, "server_name": "${DEST}", "insecure": true }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "vless-out" }
}
EOF

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
ExecStart=$(command -v python3) -m http.server ${SUB_PORT} --bind 0.0.0.0 --directory ${SUB_DIR}
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
    ok "订阅 HTTP 服务已启动 (端口 ${SUB_PORT})"
    warn "订阅地址含节点密钥, 请勿外传; 停用: systemctl disable --now proxy-sub"
  else
    warn "订阅 HTTP 服务启动失败, 已跳过"
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
  echo "跳过证书验证: 开启 (insecure=1)"
  [ -n "${HY2_HOP:-}" ] && echo "端口跳跃  : ${HY2_HOP}"
  [ "$ENABLE_OBFS" = "1" ] && echo "混淆      : salamander / ${OBFS_PASS}"
  echo
  echo -e "${G}${HY2_LINK}${N}"
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
  if [ "$SUB_HTTP" = "1" ] && [ -n "${SUB_PORT:-}" ] && [ -n "${SUB_TOKEN:-}" ]; then
    echo
    echo "HTTP 订阅(需安全组放行 TCP ${SUB_PORT}):"
    echo "  Clash   : http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}/clash.yaml"
    echo "  通用    : http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}/base64.txt"
    echo "  singbox : http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}/singbox.json"
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
  if verify_hy2; then ok "Hysteria2 链路: 通过"; else warn "Hysteria2 链路: 未验证通过(本机 UDP 回环可能受限, 以客户端实测为准)"; fi
}

# ---------------- 安装主流程 ----------------
cmd_install(){
  need_root
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  echo
  echo -e "${M}============================================================${N}"
  echo -e "${M}   Proxy Node Installer v2${N}"
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

  if [ "$fresh" = "1" ] && port_in_use "$VLESS_PORT"; then
    warn "TCP ${VLESS_PORT} 已被占用:"
    ss -tlnp 2>/dev/null | awk -v p=":${VLESS_PORT}" 'index($4,p)>0'
    die "请释放端口, 或用 VLESS_PORT=8443 bash setup-proxy.sh 重新运行"
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
    echo "insecure : 1"
    [ -n "${HY2_HOP:-}" ] && echo "端口跳跃 : ${HY2_HOP}"
    [ "$ENABLE_OBFS" = "1" ] && echo "混淆     : salamander / ${OBFS_PASS}"
    echo "链接     : ${HY2_LINK}"
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

cmd_reset(){
  need_root
  load_state || die "尚未安装"
  warn "重置会生成新的 UUID / 密钥 / hy2 密码, 所有客户端必须重新导入!"
  ask_yes "确认重置凭据?" || { info "已取消"; return 0; }
  UUID=""; PRIV=""; PUB=""; SID=""; HY2_PASS=""; OBFS_PASS=""; DEST=""
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
  echo
  err "危险操作: Xray >= 26.9.8 会强制要求客户端携带 X25519MLKEM768"
  echo "  小火箭没有该开关, 升级后会「开关变绿但网页打不开」。"
  echo "  mihomo 系需在配置里加 reality-opts.support-x25519mlkem768: true"
  echo
  ask_yes "仍然继续升级到最新版?" || { info "已取消"; return 0; }
  local tmp asset
  case "$(uname -m)" in
    x86_64|amd64)  asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的架构" ;;
  esac
  tmp=$(mktemp -d)
  download_with_mirror "https://github.com/XTLS/Xray-core/releases/latest/download/${asset}" "$tmp/x.zip" || die "下载失败"
  unzip -o -q "$tmp/x.zip" -d "$tmp/pkg" || die "解压失败"
  systemctl stop xray >/dev/null 2>&1
  install -m 755 "$tmp/pkg/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  systemctl start xray >/dev/null 2>&1; sleep 2
  ok "已升级: $($XRAY_BIN version 2>/dev/null | head -1)"
  warn "回滚: XRAY_VERSION=26.3.27 bash $(readlink -f "$0" 2>/dev/null) install"
}

cmd_uninstall(){
  need_root
  warn "将停止并删除 xray / hysteria2 服务、配置与订阅文件"
  ask_yes "确认卸载?" || { info "已取消"; return 0; }
  systemctl disable --now xray hysteria-server hy2-hop proxy-sub >/dev/null 2>&1
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria-server.service \
        /etc/systemd/system/hy2-hop.service /etc/systemd/system/proxy-sub.service
  systemctl daemon-reload
  rm -rf /usr/local/etc/xray /usr/local/share/xray /etc/hysteria "$SUB_DIR" "$STATE_DIR"
  rm -f "$XRAY_BIN" "$HY2_BIN" "/usr/local/bin/${APP_NAME}" /root/proxy-info.txt
  if [ -n "${HY2_HOP:-}" ]; then
    local s="${HY2_HOP%%-*}" e="${HY2_HOP##*-}"
    iptables -t nat -D PREROUTING -p udp --dport "${s}:${e}" -j REDIRECT --to-ports "${HY2_PORT}" 2>/dev/null || true
  fi
  ok "已卸载"
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
    echo "  8) 重置凭据 (换 UUID/密钥, 需重新导入)"
    echo "  9) 卸载"
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
      8) cmd_reset ;;
      9) cmd_uninstall ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

usage(){
  cat <<'USAGE'
Proxy Node Installer v2

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
  reset            重置凭据(会作废现有客户端)
  uninstall        卸载
  upgrade          升级 Xray 内核(危险, 默认不建议)

首次安装可用的环境变量:
  VLESS_PORT=443  HY2_PORT=443
  REALITY_DEST=www.bing.com      指定伪装站(留空=自动挑选)
  ENABLE_OBFS=1                  开启 hy2 salamander 混淆
  HY2_HOP=20000-30000            hy2 UDP 端口跳跃
  SUB_HTTP=1                     起订阅 HTTP 服务
  ASSUME_YES=1                   全程不询问

示例:
  bash setup-proxy.sh
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
    reset)          cmd_reset ;;
    uninstall)      cmd_uninstall ;;
    upgrade)        cmd_upgrade ;;
    help|-h|--help) usage ;;
    "")
      if load_state 2>/dev/null; then menu; else cmd_install; fi
      ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
