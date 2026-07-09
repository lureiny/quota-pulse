#!/usr/bin/env bash
#
# quota-pulse → Claude Code 状态栏(降级版)
#
# 直连 sub2api 后台 API,拉取「一个实例的一个账号」的滚动窗口用量(默认 5h + 7d),
# 格式化成一行喂给 Claude Code 的 statusLine。只读、不改上游。
#
# 依赖:bash、curl、jq。
# 配置:见同目录 statusline.env.example —— 复制成 ~/.config/quota-pulse/statusline.env 并填写。
# 用法:在 ~/.claude/settings.json 里把本脚本设为 statusLine.command(见 install.md)。
#
# 手动自测(不需要真实凭据也能验证格式,喂假数据即可):
#   QP_BASE_URL=x QP_API_KEY=x QP_ACCOUNT_ID=1 \
#   QP_FIXTURE='{"five_hour":{"utilization":42},"seven_day":{"utilization":88}}' ./statusline.sh
#
set -uo pipefail

# ---------------------------------------------------------------------------
# 1. 读配置:环境变量优先,其次配置文件。
# ---------------------------------------------------------------------------
CONF="${QP_STATUSLINE_CONF:-$HOME/.config/quota-pulse/statusline.env}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

BASE="${QP_BASE_URL:-}"
KEY="${QP_API_KEY:-}"
ACCOUNT="${QP_ACCOUNT_ID:-}"
WINDOWS="${QP_WINDOWS:-five_hour,seven_day}"  # 逗号分隔的窗口 id,按此顺序展示
TTL="${QP_TTL:-30}"                            # 缓存秒数:TTL 内直接复用上次结果,不打接口
SOURCE="${QP_SOURCE:-passive}"                 # passive(便宜,默认)| active(强制回源)
PREFIX="${QP_PREFIX:-}"                         # 可选前缀,如账号昵称
SEP="${QP_SEP:- · }"

die() { echo "$1"; exit 0; }   # 状态栏永不该报错退出;有问题就打一行提示

command -v jq   >/dev/null 2>&1 || die "qp: 缺少 jq"
command -v curl >/dev/null 2>&1 || die "qp: 缺少 curl"

# ---------------------------------------------------------------------------
# 2. 取数据:优先 QP_FIXTURE(自测)→ 缓存(TTL 内)→ 联网拉取。
# ---------------------------------------------------------------------------
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

fetch_data() {
  # 返回信封里的 .data(usageInfo);失败返回非 0。
  local resp code
  resp=$(curl -fsS --max-time 6 -H "x-api-key: $KEY" -H "Accept: application/json" \
    "${BASE%/}/api/v1/admin/accounts/${ACCOUNT}/usage?source=${SOURCE}" 2>/dev/null) || return 1
  code=$(printf '%s' "$resp" | jq -r '.code // 0' 2>/dev/null) || return 1
  [ "$code" = "0" ] || return 1
  printf '%s' "$resp" | jq -c '.data' 2>/dev/null
}

DATA=""
if [ -n "${QP_FIXTURE:-}" ]; then
  DATA="$QP_FIXTURE"
else
  [ -n "$BASE" ] && [ -n "$KEY" ] && [ -n "$ACCOUNT" ] || die "qp: 未配置(见 $CONF)"

  CACHE_DIR="${TMPDIR:-/tmp}/quota-pulse"
  mkdir -p "$CACHE_DIR" 2>/dev/null
  CACHE_FILE="$CACHE_DIR/usage-${ACCOUNT}.json"

  fresh=0
  if [ -f "$CACHE_FILE" ]; then
    now=$(date +%s); mt=$(file_mtime "$CACHE_FILE" 2>/dev/null || echo 0)
    [ $((now - mt)) -lt "$TTL" ] && fresh=1
  fi

  if [ "$fresh" -eq 0 ]; then
    if d=$(fetch_data) && [ -n "$d" ] && [ "$d" != "null" ]; then
      printf '%s' "$d" > "$CACHE_FILE"
    fi
  fi
  [ -f "$CACHE_FILE" ] && DATA=$(cat "$CACHE_FILE")
fi

[ -n "$DATA" ] && [ "$DATA" != "null" ] || die "qp: --"

# ---------------------------------------------------------------------------
# 3. 账号级异常优先(比空窗口更该让人看到)。
# ---------------------------------------------------------------------------
flag=$(printf '%s' "$DATA" | jq -r '
  if (.error // "") != "" then "err"
  elif .is_banned  then "banned"
  elif .needs_reauth then "reauth"
  elif .is_forbidden then "forbidden"
  else "" end' 2>/dev/null)
case "$flag" in
  banned)    die "qp: ⛔ banned" ;;
  reauth)    die "qp: 🔑 reauth" ;;
  forbidden) die "qp: 🚫 forbidden" ;;
  err)       die "qp: ⚠ error" ;;
esac

# ---------------------------------------------------------------------------
# 4. 逐窗口提取 utilization,格式化 + 阈值上色。
# ---------------------------------------------------------------------------
label_for() {
  case "$1" in
    five_hour)          echo "5h" ;;
    seven_day)          echo "7d" ;;
    seven_day_sonnet)   echo "7d·S" ;;
    seven_day_fable)    echo "7d·F" ;;
    gemini_shared_daily)  echo "GmShared/日" ;;
    gemini_pro_daily)     echo "GmPro/日" ;;
    gemini_flash_daily)   echo "GmFlash/日" ;;
    gemini_pro_minute)    echo "GmPro/分" ;;
    gemini_flash_minute)  echo "GmFlash/分" ;;
    *) echo "$1" ;;
  esac
}

use_color=1
[ -n "${NO_COLOR:-}" ] && use_color=0
[ "${QP_COLOR:-1}" = "0" ] && use_color=0

colorize() { # $1=pct $2=text
  [ "$use_color" -eq 1 ] || { printf '%s' "$2"; return; }
  local c=32                       # <70 绿
  [ "$1" -ge 70 ] && c=33          # 70–89 黄
  [ "$1" -ge 90 ] && c=31          # ≥90 红
  printf '\033[%sm%s\033[0m' "$c" "$2"
}

out=""
# jq 输出 "<id> <utilization>" 行,只保留 utilization 非空的窗口。
while read -r id util; do
  [ -n "$id" ] || continue
  pct=$(printf '%.0f' "$util" 2>/dev/null) || continue
  seg=$(colorize "$pct" "$(label_for "$id") ${pct}%")
  if [ -z "$out" ]; then out="$seg"; else out="${out}${SEP}${seg}"; fi
done <<EOF
$(printf '%s' "$DATA" | jq -r --arg ws "$WINDOWS" '
  . as $d
  | ($ws | split(","))[]
  | . as $id
  | ($d[$id] // empty) as $w
  | select(($w.utilization // null) != null)
  | "\($id) \($w.utilization)"' 2>/dev/null)
EOF

[ -n "$out" ] || die "qp: 无窗口"
printf '%s%s\n' "$PREFIX" "$out"
