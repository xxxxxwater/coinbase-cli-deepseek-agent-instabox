#!/usr/bin/env bash
# cb-brief.sh — 一屏态势：风控状态 + 余额 + 走势 + 事件
#
# 为什么需要：真正要下单的时候，判断依据分散在四个脚本里（风控允不允许、
# 有多少钱、价格什么形状、刚出了什么事）。人要把四条命令的输出在脑子里拼起来，
# agent 更糟 —— 它常常只看得到最后一条。
#
# 这个脚本只做**编排**：调已有的脚本，按固定顺序拼成一屏。它自己不做判断，
# 也不重复实现任何逻辑。某个板块失败时明确写"不可用 + 原因"，不静默省略 ——
# 少了风控那一段的态势图和"一切正常"看起来一模一样。
#
# 用法:
#   cb-brief.sh [产品] [--news N] [--candles N] [--since 24h]
#     产品       默认 BTC-USD
#     --news N   事件条数，默认 6（0 = 不显示事件）
#     --candles N K 线根数，默认 12
#     --since D  事件窗口，默认 24h
#
# 退出码: 0 正常 / 1 有板块失败 / 2 用法错
#
# 环境变量:
#   COINBASE_PORTFOLIO_ID  余额板块用的组合 UUID

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"; }

PRODUCT="BTC-USD"
NEWS_N=6
CANDLES_N=12
SINCE="24h"
while [ $# -gt 0 ]; do
  case "$1" in
    --news)    [ $# -ge 2 ] || { printf '错误: --news 需要值\n' >&2; exit 2; }; NEWS_N=$2; shift 2 ;;
    --candles) [ $# -ge 2 ] || { printf '错误: --candles 需要值\n' >&2; exit 2; }; CANDLES_N=$2; shift 2 ;;
    --since)   [ $# -ge 2 ] || { printf '错误: --since 需要值\n' >&2; exit 2; }; SINCE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf '错误: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
    *) PRODUCT=$1; shift ;;
  esac
done
case "$NEWS_N" in ''|*[!0-9]*) printf '错误: --news 必须是非负整数\n' >&2; exit 2 ;; esac
case "$CANDLES_N" in ''|*[!0-9]*) printf '错误: --candles 必须是非负整数\n' >&2; exit 2 ;; esac

cb_ensure_node_options

FAILED=0
section() { printf '\n=== %s ===\n' "$1"; }
unavailable() { printf '（不可用：%s）\n' "$1"; FAILED=1; }

printf '态势简报 · %s · %s\n' "$PRODUCT" "$(date -u '+%Y-%m-%d %H:%M UTC')"

# 1. 风控：先看允不允许，再谈别的
section "风控"
if [ -x "$HERE/cb-risk.sh" ]; then
  out=$(cb_timeout 30 bash "$HERE/cb-risk.sh" show 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
  else
    unavailable "cb-risk.sh 退出码 ${rc:-?}"
  fi
else
  unavailable "找不到 cb-risk.sh"
fi

# 2. 余额
section "余额"
if command -v coinbase >/dev/null 2>&1; then
  PFX=$(cb_portfolio_id 2>/dev/null) || PFX=""
  if [ -n "$PFX" ]; then
    out=$(cb_timeout 45 coinbase balance "portfolio_id==$PFX" show_zero==true 2>&1)
  else
    out=$(cb_timeout 45 coinbase balance 2>&1)
  fi
  rc=$?
  if [ "$rc" -eq 0 ]; then
    python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
rows=[]
for acc in d.get("accounts",[]):
    hold=acc.get("available_balance") or {}
    v=hold.get("value")
    cur=hold.get("currency") or acc.get("currency") or "?"
    if v in (None,"","0","0.00","0.00000000"): continue
    rows.append("%s %s" % (v, cur))
print(" · ".join(rows) if rows else "余额均为 0")
' <<< "$out" || printf '%s\n' "$out"
  else
    unavailable "coinbase balance 退出码 ${rc:-?}"
  fi
else
  unavailable "找不到 coinbase 或 cb-doctor.sh"
fi

# 3. 走势
section "走势"
if [ -x "$HERE/cb-candles.sh" ] && [ "$CANDLES_N" -gt 0 ]; then
  out=$(cb_timeout 45 bash "$HERE/cb-candles.sh" "$PRODUCT" --limit "$CANDLES_N" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
  else
    unavailable "cb-candles.sh 退出码 ${rc:-?}"
  fi
else
  printf '（跳过）\n'
fi

# 4. 事件：只留 P0/P1，P2/P3 交给完整的 cb-news.sh
section "事件"
if [ -x "$HERE/cb-news.sh" ] && [ "$NEWS_N" -gt 0 ]; then
  out=$(CB_NEWS_FIXTURE_DIR="${CB_NEWS_FIXTURE_DIR:-}" cb_timeout 90 bash "$HERE/cb-news.sh" \
        --since "$SINCE" --limit "$NEWS_N" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    # 只留"标题 + 主题概览 + 前 N 条"；分隔线与通用提示在这个版面里是噪音
    printf '%s\n' "$out" | awk '
      /^-+$/ { next }
      /^提示：/ { next }
      { print }
    ' | head -n $((NEWS_N + 3))
  elif [ "$rc" -eq 6 ]; then
    unavailable "所有新闻源都失败了"
  else
    unavailable "cb-news.sh 退出码 ${rc:-?}"
  fi
else
  printf '（跳过）\n'
fi

printf '\n'
if [ "$FAILED" -eq 1 ]; then
  printf '注意：上面有板块不可用，别把缺失当成正常。\n'
  exit 1
fi
printf '提示：风控允许 ≠ 该下单。事件里的 P0 意味着"先读完再决定"。\n'
