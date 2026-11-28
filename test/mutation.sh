#!/usr/bin/env bash
# 变异测试: 验证回归套件是否真的能抓到 bug, 而不是一堆假绿的静态断言。
#
# 原理: 把整个项目复制到临时目录, 在副本的 setup.sh 上注入一个已知缺陷,
#       跑完整回归。回归必须判 FAIL —— 如果注入了 bug 还是全绿, 说明那一带
#       的断言是纸糊的, 这才是真正要补测试的地方。
#
# 这个脚本只读原项目, 所有修改都在临时副本里进行, 交付脚本一根手指都不碰。
# 每个变异在独立目录并行跑, 结果写文件后统一汇总。
#
# 注意: 6 个变异并行跑完整回归约需 20 分钟, 不适合放进每次 PR 的 CI 闸门。
# 定位是定期专项体检(比如发版前手动跑一次), 验证回归套件没有退化成假绿。
#
# 用法:
#   bash test/mutation.sh              # 跑全部变异
#   bash test/mutation.sh <关键词>     # 只跑名字含该关键词的变异
#   bash test/mutation.sh --list       # 列出所有变异
set -uo pipefail

if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
FILTER="${1:-}"

# 变异清单用 python 字符串定义, 避免 bash 用 | 分隔时被原文里的管道符切断。
# 每条: (名字, 原文, 注入后的文本)。原文必须逐字节匹配且只匹配一次 ——
# 匹配不到会报 MATCH-FAIL, 不能让"没注入成功"伪装成"测试抓到了"。
read -r -d '' MUTDEF <<'PYEOF' || true
[
 ("delete-install-check",
  '  if ! install -m 755 "$bin" "$SB_BIN"; then',
  '  if install -m 755 "$bin" "$SB_BIN"; then'),
 ("blind-rollback",
  '    if [ -x "${SB_BIN}.prev" ]; then',
  '    if [ -x "${SB_BIN}.prev" ] || [ -f /dev/null ]; then'),
 ("loose-timezone",
  '  if [[ ! "$tz" =~ ^(UTC|[A-Za-z_]+(/[A-Za-z0-9_+-]+)*)$ ]]; then',
  '  if [ -z "$tz" ]; then'),
 ("no-cred-die",
  '            die "state.env 里的 REALITY 凭据 ${k} 含非法字符',
  '            warn "state.env 里的 REALITY 凭据 ${k} 含非法字符'),
 ("unlocked-sub",
  '    sub|name|user|egress)',
  '    name|user|egress)'),
 ("no-clean-dest",
  '"${STATE_DIR}.before-dest" "${STATE_DIR}.before-dest.svc"',
  '"${STATE_DIR}.never-existed"'),
]
PYEOF

if [ "$FILTER" = "--list" ]; then
  printf '%s\n' "$MUTDEF" | grep -oP '\(\s*"\K[^"]+' || true
  exit 0
fi

RESULT_DIR=$(mktemp -d "$TMPDIR/mutres.XXXXXXXX") || exit 1
trap 'rm -rf "$RESULT_DIR"' EXIT

run_one(){
  local name="$1" work
  work=$(mktemp -d "$TMPDIR/mut.XXXXXXXX") || { printf 'FAIL %s 无法建临时目录\n' "$name" > "$RESULT_DIR/$name"; return; }
  mkdir -p "$work/proj/test"
  cp "$ROOT/setup.sh" "$ROOT/setup-proxy.sh" "$ROOT/README.md" "$ROOT/CHANGELOG.md" \
     "$ROOT/cn-direct.txt" "$work/proj/" 2>/dev/null
  cp -r "$ROOT/test/." "$work/proj/test/" 2>/dev/null
  cp -r "$ROOT/docs" "$work/proj/" 2>/dev/null
  cp "$ROOT/setup.sh" "$work/setup-proxy.sh"

  python3 - "$work/proj/setup.sh" "$MUTDEF" "$name" <<'PY' 2>/dev/null
import sys, ast
p, raw, want = sys.argv[1], sys.argv[2], sys.argv[3]
items = ast.literal_eval(raw)
hit = [x for x in items if x[0] == want]
if len(hit) != 1:
    sys.exit(f"找不到变异 {want}")
f, t = hit[0][1], hit[0][2]
s = open(p, encoding='utf-8').read()
n = s.count(f)
if n != 1:
    sys.exit(f"期望 1 处匹配, 实际 {n} 处")
open(p, 'w', encoding='utf-8').write(s.replace(f, t, 1))
PY
  if [ $? -ne 0 ]; then
    printf 'FAIL %s 变异注入失败(原文对不上)\n' "$name" > "$RESULT_DIR/$name"
    rm -rf "$work"; return
  fi
  cp -f "$work/proj/setup.sh" "$work/proj/setup-proxy.sh"

  local out rc p fl
  out=$(cd "$work/proj/test" && CI=true bash run.sh 2>&1); rc=$?
  p=$(printf '%s\n' "$out" | grep -c '^PASS ' || true)
  fl=$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)
  if [ "$rc" -ne 0 ]; then
    printf 'KILLED %s 回归抓到了(FAIL=%s)\n' "$name" "$fl" > "$RESULT_DIR/$name"
  else
    printf 'SURVIVED %s 注入 bug 后回归仍全绿(PASS=%s) <<< 测试盲区\n' "$name" "$p" > "$RESULT_DIR/$name"
  fi
  rm -rf "$work"
}

mapfile -t NAMES < <(printf '%s\n' "$MUTDEF" | grep -oP '\(\s*"\K[^"]+' || true)
TOTAL=0
for name in "${NAMES[@]}"; do
  case "$name" in *"$FILTER"*) ;; *) continue ;; esac
  TOTAL=$((TOTAL + 1))
  run_one "$name" &
done
wait

KILLED=0; SURVIVED=0
for name in "${NAMES[@]}"; do
  case "$name" in *"$FILTER"*) ;; *) continue ;; esac
  [ -f "$RESULT_DIR/$name" ] || { echo "FAIL $name 没有结果文件"; SURVIVED=$((SURVIVED+1)); continue; }
  cat "$RESULT_DIR/$name"
  if grep -q '^KILLED' "$RESULT_DIR/$name"; then KILLED=$((KILLED+1)); else SURVIVED=$((SURVIVED+1)); fi
done

echo "------------------------------------------------------------"
echo "变异总数 ${TOTAL}  抓到 ${KILLED}  漏掉 ${SURVIVED}"
[ "$TOTAL" -gt 0 ] || { echo "没有跑任何变异"; exit 1; }
[ "$SURVIVED" -eq 0 ] || exit 1
echo "OK: 回归套件抓到了全部注入缺陷"
exit 0
