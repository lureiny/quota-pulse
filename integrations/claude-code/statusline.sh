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
BAR_WIDTH="${QP_BAR_WIDTH:-10}"                 # 进度条格数
BAR_FILL="${QP_BAR_FILL:-▰}"                    # 已用格字符(默认中高实心块)
BAR_EMPTY="${QP_BAR_EMPTY:-▱}"                  # 剩余格字符
BAR_LEFT="${QP_BAR_LEFT:-[}"                    # 进度条左括号
BAR_RIGHT="${QP_BAR_RIGHT:-]}"                  # 进度条右括号
SHOW_RESET="${QP_SHOW_RESET:-1}"                # 1=显示重置倒计时(3h20m),0=隐藏

# 配置文件由用户编辑:对参与算术/URL 语义的值做收口,避免笔误让状态栏脚本报语法错。
case "$TTL" in ''|*[!0-9]*) TTL=30 ;; esac
case "$BAR_WIDTH" in ''|*[!0-9]*) BAR_WIDTH=10 ;; esac
[ "$BAR_WIDTH" -gt 50 ] && BAR_WIDTH=50
case "$SOURCE" in passive|active) ;; *) SOURCE=passive ;; esac
case "$SHOW_RESET" in 0|1) ;; *) SHOW_RESET=1 ;; esac

die() { echo "$1"; exit 0; }   # 状态栏永不该报错退出;有问题就打一行提示

command -v jq   >/dev/null 2>&1 || die "qp: 缺少 jq"
command -v curl >/dev/null 2>&1 || die "qp: 缺少 curl"

# ---------------------------------------------------------------------------
# 2. 取数据:优先 QP_FIXTURE(自测)→ 缓存(TTL 内)→ 联网拉取。
# ---------------------------------------------------------------------------
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

fetch_data() {
  # 返回信封里的 .data(usageInfo);失败返回非 0。
  local resp code query
  query="source=${SOURCE}"
  [ "$SOURCE" = "active" ] && query="${query}&force=true"
  # header 从 stdin 交给 curl,admin key 不出现在进程 argv/ps 列表里。
  resp=$(printf 'x-api-key: %s\nAccept: application/json\n' "$KEY" | \
    curl -fsS --max-time 6 -H @- \
      "${BASE%/}/api/v1/admin/accounts/${ACCOUNT}/usage?${query}" 2>/dev/null) || return 1
  code=$(printf '%s' "$resp" | jq -r '.code // 0' 2>/dev/null) || return 1
  [ "$code" = "0" ] || return 1
  printf '%s' "$resp" | jq -c '.data' 2>/dev/null
}

DATA=""
if [ -n "${QP_FIXTURE:-}" ]; then
  DATA="$QP_FIXTURE"
else
  [ -n "$BASE" ] && [ -n "$KEY" ] && [ -n "$ACCOUNT" ] || die "qp: 未配置(见 $CONF)"
  case "$ACCOUNT" in *[!0-9]*) die "qp: account id 必须是数字" ;; esac
  case "$KEY" in *$'\r'*|*$'\n'*) die "qp: api key 格式无效" ;; esac

  # 放用户私有 cache 目录,不用共享 /tmp;实例/account/source 共同参与匿名指纹,
  # 避免两个后台恰有相同 account id 时串用彼此缓存。
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/quota-pulse/statusline"
  umask 077
  mkdir -p "$CACHE_DIR" 2>/dev/null || die "qp: 无法创建缓存目录"
  chmod 700 "$CACHE_DIR" 2>/dev/null || true
  CACHE_KEY=$(printf '%s\0%s\0%s' "$BASE" "$ACCOUNT" "$SOURCE" | cksum | awk '{print $1}')
  CACHE_FILE="$CACHE_DIR/usage-${CACHE_KEY}.json"

  fresh=0
  if [ -f "$CACHE_FILE" ]; then
    now=$(date +%s); mt=$(file_mtime "$CACHE_FILE" 2>/dev/null || echo 0)
    [ $((now - mt)) -lt "$TTL" ] && fresh=1
  fi

  if [ "$fresh" -eq 0 ]; then
    if d=$(fetch_data) && [ -n "$d" ] && [ "$d" != "null" ]; then
      DATA="$d" # 即便缓存落盘失败,本次新数据仍可正常渲染。
      tmp=$(mktemp "$CACHE_DIR/.usage.XXXXXX" 2>/dev/null || true)
      if [ -n "$tmp" ]; then
        if printf '%s' "$d" > "$tmp"; then
          chmod 600 "$tmp" 2>/dev/null || true
          mv -f "$tmp" "$CACHE_FILE"
        else
          rm -f "$tmp"
        fi
      fi
    fi
  fi
  [ -z "$DATA" ] && [ -f "$CACHE_FILE" ] && DATA=$(cat "$CACHE_FILE")
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

color_for() {                      # $1=pct -> 阈值色码
  local c=32                       # <70 绿
  [ "$1" -ge 70 ] && c=33          # 70–89 黄
  [ "$1" -ge 90 ] && c=31          # ≥90 红
  echo "$c"
}

bar_for() {                        # $1=pct $2=色码 -> 字符进度条(填充上色、剩余置暗)
  local pct=$1 c=$2 w=$BAR_WIDTH n=0 i=0 fill="" empty=""
  n=$(( (pct * w + 50) / 100 ))    # 四舍五入到格
  [ "$n" -lt 0 ] && n=0
  [ "$n" -gt "$w" ] && n=$w        # >100% 封顶为满格
  while [ "$i" -lt "$n" ]; do fill="$fill$BAR_FILL";   i=$((i+1)); done
  while [ "$i" -lt "$w" ]; do empty="$empty$BAR_EMPTY"; i=$((i+1)); done
  if [ "$use_color" -eq 1 ]; then
    printf '\033[%sm%s\033[0m\033[2m%s\033[0m' "$c" "$fill" "$empty"
  else
    printf '%s%s' "$fill" "$empty"
  fi
}

fmt_remaining() {                  # $1=秒 -> 紧凑时长(2d5h / 3h20m / 45m / <1m);<=0 输出空
  local s=$1
  [ "$s" -gt 0 ] 2>/dev/null || { printf ''; return; }
  local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60))
  if   [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '<1m'; fi
}

out=""
# jq 输出 "<id> <utilization> <remaining_seconds>" 行,只保留 utilization 非空的窗口。
while read -r id util rem; do
  [ -n "$id" ] || continue
  pct=$(printf '%.0f' "$util" 2>/dev/null) || continue
  c=$(color_for "$pct")
  bar=$(bar_for "$pct" "$c")
  lbl=$(label_for "$id")
  rtxt=""
  if [ "$SHOW_RESET" = "1" ]; then
    r=$(fmt_remaining "$rem"); [ -n "$r" ] && rtxt=" $r"
  fi
  if [ "$use_color" -eq 1 ]; then
    seg=$(printf '%s %s%s%s \033[%sm%d%%\033[0m\033[2m%s\033[0m' \
      "$lbl" "$BAR_LEFT" "$bar" "$BAR_RIGHT" "$c" "$pct" "$rtxt")
  else
    seg=$(printf '%s %s%s%s %d%%%s' "$lbl" "$BAR_LEFT" "$bar" "$BAR_RIGHT" "$pct" "$rtxt")
  fi
  if [ -z "$out" ]; then out="$seg"; else out="${out}${SEP}${seg}"; fi
done <<EOF
$(printf '%s' "$DATA" | jq -r --arg ws "$WINDOWS" '
  . as $d
  | ($ws | split(","))[]
  | . as $id
  | ($d[$id] // empty) as $w
  | select(($w.utilization // null) != null)
  | "\($id) \($w.utilization) \($w.remaining_seconds // 0)"' 2>/dev/null)
EOF

[ -n "$out" ] || die "qp: 无窗口"
printf '%s%s\n' "$PREFIX" "$out"
