#!/usr/bin/env bash
# cb-brief.sh — 一屏态势：风控状态 + 市场状态 + 余额 + 走势 + 事件
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
#   cb-brief.sh [产品] [--news N] [--candles N] [--since 24h] [--no-market]
#     产品       默认 BTC-USD
#     --no-market 不显示市场状态（情绪/总量/流动性/杠杆/链上）
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
MARKET=1
NEWS_N=6
CANDLES_N=12
SINCE="24h"
while [ $# -gt 0 ]; do
  case "$1" in
    --news)    [ $# -ge 2 ] || { printf '错误: --news 需要值\n' >&2; exit 2; }; NEWS_N=$2; shift 2 ;;
    --candles) [ $# -ge 2 ] || { printf '错误: --candles 需要值\n' >&2; exit 2; }; CANDLES_N=$2; shift 2 ;;
    --since)   [ $# -ge 2 ] || { printf '错误: --since 需要值\n' >&2; exit 2; }; SINCE=$2; shift 2 ;;
    --no-market) MARKET=0; shift ;;
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

# 2. 市场：情绪 / 总量 / 流动性 / 杠杆 / 链上拥堵
section "市场"
if [ "$MARKET" -eq 0 ]; then
  printf '（跳过）\n'
elif [ -x "$HERE/cb-market.sh" ]; then
  out=$(cb_timeout 60 bash "$HERE/cb-market.sh" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    # 简报头部已有时间，去掉它自己的标题行，保留五行信号
    printf '%s\n' "$out" | sed '1{/^市场状态/d;}'
  elif [ "$rc" -eq 6 ]; then
    unavailable "所有市场数据源都失败了"
  else
    unavailable "cb-market.sh 退出码 ${rc:-?}"
  fi
else
  unavailable "找不到 cb-market.sh"
fi

# 3. 余额
section "余额"
if command -v coinbase >/dev/null 2>&1; then
  PFX=$(cb_portfolio_id 2>/dev/null) || PFX=""
  if [ -n "$PFX" ]; then
    out=$(cb_timeout 45 coinbase balance "portfolio_id==$PFX" show_zero==true 2>/dev/null)
  else
    out=$(cb_timeout 45 coinbase balance 2>/dev/null)
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    unavailable "coinbase balance 退出码 $rc"
  elif balance=$(python3 -c '
import json, sys

try:
    d=json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(d, dict) or "errorType" in d or not isinstance(d.get("accounts"), list):
    sys.exit(1)

rows = []
for acc in d["accounts"]:
    hold = acc.get("available_balance") if isinstance(acc, dict) else None
    if not isinstance(hold, dict) or hold.get("value") in (None, ""):
        sys.exit(1)
    v = hold["value"]
    cur = hold.get("currency") or acc.get("currency") or "?"
    if v in ("0", "0.00", "0.00000000"):
        continue
    rows.append("%s %s" % (v, cur))
print(" · ".join(rows) if rows else "余额均为 0")
' <<< "$out"); then
    printf '%s\n' "$balance"
  else
    unavailable "coinbase balance 返回无效账户数据"
  fi
else
  unavailable "找不到 coinbase 或 cb-doctor.sh"
fi

# 4. 走势
section "走势"
if [ "$CANDLES_N" -eq 0 ]; then
  printf '（跳过）\n'
elif [ -x "$HERE/cb-candles.sh" ]; then
  out=$(cb_timeout 45 bash "$HERE/cb-candles.sh" "$PRODUCT" --limit "$CANDLES_N" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
  else
    unavailable "cb-candles.sh 退出码 ${rc:-?}"
  fi
else
  unavailable "找不到 cb-candles.sh"
fi

# 5. 事件：条数由 cb-news.sh 限制
section "事件"
if [ "$NEWS_N" -eq 0 ]; then
  printf '（跳过）\n'
elif [ -x "$HERE/cb-news.sh" ]; then
  out=$(CB_NEWS_FIXTURE_DIR="${CB_NEWS_FIXTURE_DIR:-}" cb_timeout 90 bash "$HERE/cb-news.sh" \
        --since "$SINCE" --limit "$NEWS_N" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    # 简报已有自己的通用提示，保留事件及来源诊断。
    printf '%s\n' "$out" | awk '
      /^-+$/ { next }
      /^提示：/ { next }
      { print }
    '
  elif [ "$rc" -eq 6 ]; then
    unavailable "所有新闻源都失败了"
  else
    unavailable "cb-news.sh 退出码 ${rc:-?}"
  fi
else
  unavailable "找不到 cb-news.sh"
fi

printf '\n'
if [ "$FAILED" -eq 1 ]; then
  printf '注意：上面有板块不可用，别把缺失当成正常。\n'
  exit 1
fi
printf '提示：风控允许 ≠ 该下单。事件里的 P0 意味着"先读完再决定"。\n'
