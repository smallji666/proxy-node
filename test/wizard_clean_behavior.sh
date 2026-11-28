#!/usr/bin/env bash
# 验证部署向导里按 c(清除配置) 一定有可见反馈。
#
# 为什么单独测: 用户实测「一键命令进去, 在向导里按 c 什么都没变」。
# 根因是旧代码在无残留时只打一行 info 就 continue, 向导界面立刻重绘把它冲掉。
# 这里把 wizard 抽出来, 桩掉所有外部依赖, 用假输入驱动, 断言两种情况下
# 都有明确输出、且暂停等回车(而不是瞬间返回)。
set -u
SRC="../setup.sh"
if [ -d /tmp ] && [ -w /tmp ]; then export TMPDIR=/tmp; fi
unset -f rm 2>/dev/null || true
TD=$(mktemp -d)
FNS="$TD/f.sh"

awk '$0 ~ "^wizard\\(\\)\\{" {p=1} p{print} p&&$0=="}"{exit}' "$SRC" > "$FNS"
grep -q '^wizard(){' "$FNS" || { echo "FAIL wizard 没抽到"; exit 1; }
bash -n "$FNS" || { echo "FAIL 抽取出的 wizard 语法错误"; exit 1; }

P=0; F=0
t(){ if [ "$2" = "$3" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 (got=[$2] want=[$3])"; F=$((F+1)); fi; }

# 用一整套桩把 wizard 包起来跑。$1=有无残留(0/1) $2=输入序列(空格分隔, _=空串)
# 计数用文件: wizard 在命令替换的子 shell 里跑, 普通变量改不动父 shell。
run_wizard(){
  local has_residue="$1" seq="$2"
  local cnt="$TD/cnt"; : > "$cnt"
  # 这些变量由下面 source 进来的 wizard 间接读取, shellcheck 静态看不到。
  # shellcheck disable=SC2034
  M=''; N=''; G=''; Y=''; B=''; R=''; D=''
  # shellcheck disable=SC2034
  SCRIPT_VERSION="1.0"; STATE_FILE="$TD/state.env"; CLEAN=0
  : "$M" "$N" "$G" "$Y" "$B" "$R" "$D" "$SCRIPT_VERSION" "$STATE_FILE" "$CLEAN"

  hr(){ echo '---'; }
  ui_stamp(){ :; }
  state_get(){ echo ''; }
  need_root(){ :; }
  info(){ printf 'INFO %s\n' "$*"; }
  warn(){ printf 'WARN %s\n' "$*"; }
  ok(){ printf 'OK %s\n' "$*"; }
  err(){ printf 'ERR %s\n' "$*"; }
  die(){ :; }
  canon_protocols(){ printf '%s' "$1"; }
  cmd_optimize(){ :; }
  cmd_timezone(){ :; }
  deploy_preset(){ :; }
  cmd_install(){ :; }
  load_state(){ return 1; }
  residue_report(){ [ "$has_residue" = "1" ]; }
  ask_yes(){ printf 'asked\n' >> "$cnt"; return 0; }
  do_clean(){ printf 'clean\n' >> "$cnt"; printf 'DO_CLEAN %s\n' "${1:-}"; }

  local -a ans=()
  local w
  for w in $seq; do [ "$w" = "_" ] && w=''; ans+=("$w"); done
  local idx=0
  read_tty(){
    local prompt="$1" var="$2" def="${3:-}"
    if [ "$idx" -lt "${#ans[@]}" ]; then
      printf -v "$var" '%s' "${ans[$idx]}"; idx=$((idx+1))
    else
      printf -v "$var" '%s' "$def"
    fi
    case "$prompt" in
      *回车*) printf 'paused\n' >> "$cnt" ;;
    esac
    printf '%s\n' "$prompt"
    return 0
  }

  # 函数库路径运行时生成, shellcheck 追不到; 这里是故意 source。
  # shellcheck disable=SC1090
  source "$FNS"
  OUT=$(wizard 2>&1)
  # 把计数回传给调用方(通过全局 OUT 已有输出, 这里回显计数标记)
  printf '%s\n' "$OUT" | grep -v '^DIE ' > "$TD/last.out"
}

cnt_n(){ local n; n=$(grep -c "$1" "$TD/cnt" 2>/dev/null) || n=0; printf '%s' "$n"; }

# --- 情况 1: 没有残留(全新机器, 用户最常见的"按 c 没反应"场景) ---
run_wizard 0 'c _ 0'
OUT=$(cat "$TD/last.out")
t "无残留: 明确说明没有东西可清" \
  "$(printf '%s\n' "$OUT" | grep -c '当前没有本脚本的配置或残留需要清除')" "1"
t "无残留: 画了清除配置标题" \
  "$(printf '%s\n' "$OUT" | grep -c '清除配置')" "1"
t "无残留: 没调用清理(不该删任何东西)" "$(cnt_n '^clean$')" "0"
t "无残留: 暂停等回车(不会被向导重绘冲掉)" "$([ "$(cnt_n '^paused$')" -ge 1 ] && echo yes || echo no)" "yes"

# --- 情况 2: 有残留且用户确认 ---
run_wizard 1 'c y _ 0'
OUT=$(cat "$TD/last.out")
t "有残留: 调用了清理" "$(cnt_n '^clean$')" "1"
t "有残留: 先询问确认" "$([ "$(cnt_n '^asked$')" -ge 1 ] && echo yes || echo no)" "yes"
t "有残留: 提示清理完成" "$(printf '%s\n' "$OUT" | grep -c '已清除, 端口已释放')" "1"
t "有残留: 清理后也暂停等回车" "$([ "$(cnt_n '^paused$')" -ge 1 ] && echo yes || echo no)" "yes"

echo "  PASS $P  FAIL $F"
[ "$F" -eq 0 ]
