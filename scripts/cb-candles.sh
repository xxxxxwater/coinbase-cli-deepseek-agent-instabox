#!/usr/bin/env bash
# cb-candles.sh — 看 K 线（OHLCV），并在终端里直接看见走势
#
# 为什么需要：`products get` 只给当前价，判断"是不是在跌"需要历史。
# agent 拿到一屏 JSON 也看不出形状，所以这里顺手画一条 sparkline ——
# 一行文字就能看出趋势，比读 24 行数字快。
#
# 用法:
#   cb-candles.sh [<产品>] [--granularity 1h] [--limit N] [--json]
#     <产品>              默认 BTC-USD
#     --granularity <g>   1m/5m/15m/30m/1h/2h/4h/6h/1d（默认 1h）
#     --limit <N>         K 线根数，默认 24（最近 24 根）
#     --json              原始 JSON，不渲染
#
# 退出码: 0 成功 / 2 用法错 / 5 返回不是 JSON / 6 接口失败
#
# 说明：股票（EQUITY）没有 K 线接口，服务端会拒；本脚本会明说而不是显示空白。

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"; }

PRODUCT="BTC-USD"
GRAN="1h"
LIMIT="24"
AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --granularity) [ $# -ge 2 ] || { printf '错误: --granularity 需要值\n' >&2; exit 2; }; GRAN=$2; shift 2 ;;
    --limit)       [ $# -ge 2 ] || { printf '错误: --limit 需要值\n' >&2; exit 2; }; LIMIT=$2; shift 2 ;;
    --json)        AS_JSON=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            printf '错误: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
    *)             PRODUCT=$1; shift ;;
  esac
done

case "$GRAN" in
  1m|5m|15m|30m|1h|2h|4h|6h|1d) ;;
  *) printf '错误: granularity 只能是 1m/5m/15m/30m/1h/2h/4h/6h/1d（给的是 %s）\n' "$GRAN" >&2; exit 2 ;;
esac
case "$LIMIT" in
  ''|*[!0-9]*) printf '错误: --limit 必须是正整数（给的是 %s）\n' "$LIMIT" >&2; exit 2 ;;
esac
[ "$LIMIT" -ge 2 ] || { printf '错误: --limit 至少 2（一根 K 线看不出走势）\n' >&2; exit 2; }

cb_need coinbase
cb_ensure_node_options

RAW=$(cb_timeout 60 coinbase products candles "$PRODUCT" "granularity==${GRAN}" "limit==${LIMIT}" 2>&1)
RC=$?

if [ "$AS_JSON" -eq 1 ]; then
  printf '%s\n' "$RAW"
  [ "$RC" -eq 0 ] || exit 6
  exit 0
fi

printf '%s' "$RAW" | cb_is_json && JSON_OK=1 || JSON_OK=0
# 是 JSON 不等于成功：服务端的错误负载也是 JSON（errorType/errorMessage），
# 把它当"成功但没数据"渲染，等于把失败伪装成空结果。
if [ "$JSON_OK" -eq 1 ] && printf '%s' "$RAW" | grep -q '"errorType"'; then
  cb_bad "接口报错：$(printf '%s' "$RAW" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("(无法解析)"); raise SystemExit
print(d.get("errorMessage") or d.get("errorType") or "未知错误")
' 2>/dev/null)"
  exit 6
fi
if [ "$JSON_OK" -eq 0 ]; then
  if printf '%s' "$RAW" | grep -qi 'not available for equities\|not supported'; then
    cb_bad "这个产品没有 K 线接口：${PRODUCT}"
    cb_dim "  股票（EQUITY）不提供 candles；现货与永续才有。" >&2
    exit 6
  fi
  cb_bad "接口调用失败"
  printf '%s\n' "$RAW" | head -6 >&2
  exit 6
fi

printf '%s' "$RAW" | PRODUCT="$PRODUCT" GRAN="$GRAN" python3 -c '
import json, os, sys, datetime

d = json.load(sys.stdin)
candles = d.get("candles") or []
if not candles:
    # 空数组有两种含义，别混为一谈：股票本来就没有 K 线接口，
    # 现货才是"这段区间没成交"。先看产品类型再说话。
    import subprocess
    prod = os.environ["PRODUCT"]
    try:
        info = json.loads(subprocess.run(
            ["coinbase", "products", "get", prod],
            capture_output=True, text=True, timeout=45).stdout or "{}")
    except Exception:
        info = {}
    if str(info.get("product_type", "")).upper() == "EQUITY":
        print("%s 是股票（EQUITY）—— Coinbase 的 K 线接口不覆盖股票；"
              "这与现货\"该区间无成交\"是两回事。" % prod)
    else:
        print("%s 在这段区间内没有 K 线（可能没成交，或市场未开）。" % prod)
    raise SystemExit(0)

# 服务端按时间倒序给，画图要正序
candles = sorted(candles, key=lambda c: int(c["start"]))
closes = [float(c["close"]) for c in candles]
highs = [float(c["high"]) for c in candles]
lows = [float(c["low"]) for c in candles]
vols = [float(c.get("volume") or 0) for c in candles]

first, last = closes[0], closes[-1]
chg = (last - first) / first * 100 if first else 0.0
arrow = "↑" if chg > 0 else ("↓" if chg < 0 else "→")

blocks = "▁▂▃▄▅▆▇█"
lo, hi = min(lows), max(highs)
span = (hi - lo) or 1.0
spark = "".join(blocks[min(len(blocks) - 1, int((c - lo) / span * (len(blocks) - 1) + 0.5))] for c in closes)

def ts(s):
    return datetime.datetime.fromtimestamp(int(s), datetime.timezone.utc).strftime("%m-%d %H:%M")

print("%s  %s  %d 根" % (os.environ["PRODUCT"], os.environ["GRAN"], len(candles)))
print("%s → %s UTC" % (ts(candles[0]["start"]), ts(candles[-1]["start"])))
print()
print("  " + spark)
print()
print("  最新 %.6g   区间 %s%.2f%%   最高 %.6g   最低 %.6g" % (last, arrow, chg, hi, lo))
print("  成交量合计 %.6g" % sum(vols))
' 
