#!/usr/bin/env bash
# 验证自签证书的两种指纹算法: 整证书 SHA-256(hex) 与 SPKI(base64)。
#
# 为什么单独测: 这两个值直接决定客户端能不能连上。
#   - hysteria2 的 pinSHA256 / mihomo 的 fingerprint 要的是**整证书 DER 的 hex**;
#   - sing-box 的 certificate_public_key_sha256 要的是**公钥 SPKI 的 base64**。
# 两者算错一个, 客户端就报"证书指纹不匹配", 而服务端日志一切正常。
# 曾经这里只剩 SPKI 一项、CERT_HEX 全脚本没人赋值 —— 结果 compute_cert_pins
# 恒返回失败, ensure_hy2 每次都 die, 默认组合 reality,hy2 根本装不完。
# 本测试用真 openssl 生成一张真证书, 再用独立算法复算一遍做交叉比对。
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

{
  for fn in compute_cert_pins; do
    awk -v n="$fn" '$0 ~ "^" n "\\(\\)\\{" {p=1} p{print} p && $0=="}"{exit}' "$SRC"
  done
} > "$FNS"
grep -q '^compute_cert_pins(){' "$FNS" || { echo "FAIL compute_cert_pins 没抽到"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取出的函数语法错误"; exit 1; }
source "$FNS" || { echo "FAIL 函数库无法加载"; exit 1; }
command -v compute_cert_pins >/dev/null 2>&1 || { echo "FAIL compute_cert_pins 不可调用"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP 没有 openssl, 跳过证书指纹测试"
  echo "  PASS 0   FAIL 0"
  exit 0
fi

CERT="$TD/cert.pem"; KEY="$TD/key.pem"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$KEY" -out "$CERT" -days 30 -subj "/CN=www.bing.com" >/dev/null 2>&1 \
  || { echo "FAIL 无法生成测试证书"; exit 1; }

# --- 正常路径 ---
CERT_SPKI_B64=""; CERT_HEX=""
if compute_cert_pins "$CERT"; then rc=0; else rc=1; fi
t "真证书算得出指纹" "$rc" 0
t "CERT_HEX 是 64 位" "$(printf '%s' "$CERT_HEX" | wc -c | tr -d ' ')" 64
t "CERT_HEX 全小写十六进制" \
  "$(printf '%s' "$CERT_HEX" | grep -cE '^[0-9a-f]{64}$')" 1
t "CERT_SPKI_B64 非空" "$([ -n "$CERT_SPKI_B64" ] && echo yes || echo no)" yes

# 独立复算: 不走被测代码, 直接问 openssl。两边必须逐字相同。
want_hex=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null \
  | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')
t "CERT_HEX 与 openssl 复算一致" "$CERT_HEX" "$want_hex"

want_spki=$(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null \
  | openssl pkey -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A 2>/dev/null)
t "CERT_SPKI_B64 与 openssl 复算一致" "$CERT_SPKI_B64" "$want_spki"

# 两个指纹覆盖的范围不同(整证书 vs 公钥), 值必须不同 —— 相等说明有一处算错
t "HEX 与 SPKI 不是同一个值" \
  "$([ "$CERT_HEX" != "$CERT_SPKI_B64" ] && echo yes || echo no)" yes

# --- 失败路径必须返回非 0, 不能留下半套值让调用方以为成功 ---
CERT_SPKI_B64=""; CERT_HEX=""
if compute_cert_pins "$TD/nonexistent.pem"; then rc=0; else rc=1; fi
t "证书不存在返回失败" "$rc" 1
t "失败时不清空上一次的值" "$([ -z "$CERT_HEX" ] && echo yes || echo no)" yes

: > "$TD/empty.pem"
if compute_cert_pins "$TD/empty.pem"; then rc=0; else rc=1; fi
t "空证书返回失败" "$rc" 1

printf 'not a certificate\n' > "$TD/junk.pem"
if compute_cert_pins "$TD/junk.pem"; then rc=0; else rc=1; fi
t "非证书文件返回失败" "$rc" 1

# 换一张证书, 指纹必须跟着变(否则说明缓存/写死了旧值)
CERT2="$TD/cert2.pem"; KEY2="$TD/key2.pem"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$KEY2" -out "$CERT2" -days 30 -subj "/CN=www.bing.com" >/dev/null 2>&1
first_hex="$CERT_HEX"
CERT_SPKI_B64=""; CERT_HEX=""
compute_cert_pins "$CERT2" >/dev/null 2>&1
t "换证书后指纹变化" "$([ "$CERT_HEX" != "$first_hex" ] && echo yes || echo no)" yes

# 默认参数必须还是 /etc/hysteria/cert.pem: 少了它调用方(ensure_hy2 不带参)
# 会拿空路径, 永远失败。
t "默认路径仍是 hysteria 证书" \
  "$(grep -c 'local cert="${1:-/etc/hysteria/cert.pem}"' "$SRC")" 1

echo "----------------------------------------"
echo "  PASS $P   FAIL $F"
[ "$F" -eq 0 ] || exit 1
