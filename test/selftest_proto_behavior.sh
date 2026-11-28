#!/usr/bin/env bash
# 验证协议自检选对了客户端: hy2 必须用自带的 hysteria 客户端, 不能依赖 sing-box。
#
# 为什么单独测: 默认组合 reality+hy2 不装 sing-box, 旧代码把 hy2 绑在 sing-box
# 客户端上, 于是 hy2 永远"跳过(缺 sing-box 客户端)", 自检看着从没测完。
# 这里抽取 selftest_protocols, 桩掉两个客户端探测函数, 断言:
#   - hy2 走 verify_hy2, 不碰 selftest_sb_proto
#   - 缺 hysteria 客户端时 hy2 才跳过
#   - ss2022/anytls/tuic 仍走 sing-box 路径
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

awk '$0 ~ "^selftest_protocols\\(\\)\\{" {p=1} p{print} p&&$0=="}"{exit}' "$SRC" > "$FNS"
grep -q '^selftest_protocols(){' "$FNS" || { echo "FAIL selftest_protocols 没抽到"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取出的函数语法错误"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

# 桩: 用临时文件记录谁被调用, 因为函数在命令替换子 shell 里跑。
run_case(){
  local protos="$1" hy2_bin="$2" hy2_rc="$3" real_rc="${4:-0}" cnt="$TD/cnt"; : > "$cnt"
  # 这些变量由下面 source 的函数间接读取, shellcheck 静态看不到。
  # shellcheck disable=SC2034
  PROTOCOLS="$protos"; HY2_BIN="$hy2_bin"; HY2_PIN="abc123"; XRAY_BIN=/bin/true
  # shellcheck disable=SC2034
  G=''; N=''; R=''
  : "$PROTOCOLS" "$HY2_BIN" "$HY2_PIN" "$XRAY_BIN" "$G" "$N" "$R"
  proto_on(){ case ",${PROTOCOLS}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
  verify_reality(){ printf 'real\n' >> "$cnt"; return "$real_rc"; }
  verify_hy2(){ printf 'hy2:%s\n' "$1" >> "$cnt"; return "$hy2_rc"; }
  selftest_sb_proto(){ printf 'sb:%s\n' "$1" >> "$cnt"; return 0; }
  # 函数库路径运行时生成, shellcheck 追不到; 这里是故意 source。
  # shellcheck disable=SC1090
  source "$FNS"
  OUT=$(selftest_protocols 2>&1)
}

# 1) 默认 reality+hy2, hy2 客户端在, 应走 verify_hy2 且不碰 sing-box
run_case 'reality,hy2' /bin/true 0
t "hy2 走自带客户端 verify_hy2" "$(grep -c 'hy2:abc123' "$TD/cnt")" "1"
t "hy2 不调用 sing-box 客户端" "$(grep -c '^sb:' "$TD/cnt" || true)" "0"
t "reality 仍走 verify_reality" "$(grep -c '^real$' "$TD/cnt")" "1"
t "hy2 客户端在时不跳过" "$(printf '%s\n' "$OUT" | grep -c '跳过')" "0"
# 不能直接 grep -c '通': "不通" 里也含这个字, reality 挂了也能假绿成 2。
# 先把"不通"整词去掉, 再数剩下的"通"。
t "hy2 判定为通" "$(printf '%s\n' "$OUT" | sed 's/不通//g' | grep -o '通' | wc -l | tr -d ' ')" "2"

# 2) 缺 hysteria 客户端 -> 只 hy2 跳过, 且提示写清楚缺的是谁
run_case 'hy2' '' 0
t "缺 hysteria 时 hy2 跳过" "$(printf '%s\n' "$OUT" | grep -c '跳过(缺 hysteria 客户端)')" "1"
t "缺客户端提示不再误写 sing-box" "$(printf '%s\n' "$OUT" | grep -c '缺 sing-box')" "0"
t "缺 hysteria 时不调用 verify_hy2" "$(grep -c '^hy2:' "$TD/cnt" || true)" "0"

# 3) hy2 不通 -> 算失败, 不算跳过
run_case 'hy2' /bin/true 1
t "hy2 不通判为不通(不是跳过)" "$(printf '%s\n' "$OUT" | grep -c '不通')" "1"
t "hy2 失败时调用了 verify_hy2" "$(grep -c '^hy2:' "$TD/cnt")" "1"

# 4) sing-box 协议仍走原路径
run_case 'ss2022,anytls,tuic' /bin/true 0
t "ss2022/anytls/tuic 走 sing-box" "$(grep -c '^sb:' "$TD/cnt")" "3"
t "未启用 hy2 时不调用 verify_hy2" "$(grep -c '^hy2:' "$TD/cnt" || true)" "0"

# 5) reality 不通必须如实报"不通", 且不能混进"通"的计数里
run_case 'reality,hy2' /bin/true 0 1
t "reality 不通时输出含不通" "$(printf '%s\n' "$OUT" | grep -c '不通')" "1"
t "reality 不通不算作通" "$(printf '%s\n' "$OUT" | sed 's/不通//g' | grep -o '通' | wc -l | tr -d ' ')" "1"

echo "  PASS $P  FAIL $F"
[ "$F" -eq 0 ]
