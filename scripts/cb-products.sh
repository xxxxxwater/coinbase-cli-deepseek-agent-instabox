#!/usr/bin/env bash
# cb-products.sh — 查交易对：详情、搜索、按计价币列清单
#
# 用法:
#   cb-products.sh BTC-USD              # 一个交易对的详情（价格、24h 涨跌、最小下单量…）
#   cb-products.sh --search btc         # 在产品名里搜（不分大小写）
#   cb-products.sh --quote USD          # 列某个计价币下的所有交易对（默认 USD）
#   cb-products.sh --quote USD -n 20    # 只列前 20 个
#   cb-products.sh --ticker BTC-USD     # 只要价格（适合写进脚本）
#   cb-products.sh --json BTC-USD       # 原样输出 API 返回
#
# 为什么单独一个脚本：`coinbase products list --jq` 返回的是一整个对象，
# 想数个数得写 `.products | length`，想筛一笔得再拼 jq —— 每次都现查 help。
#
# 退出码: 0 成功 / 2 用法错误 / 3 这个产品查不到 / 4 接口调用失败

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh" 2>/dev/null || . "$(dirname "$0")/lib/config.sh"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

MODE="auto"
JSON=0
QUOTE="USD"
LIMIT=0
PRODUCT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --search) MODE="search";  SEARCH=${2:?}; shift 2 ;;
    --quote)  MODE="quote";   QUOTE=${2:?};  shift 2 ;;
    --ticker) MODE="ticker";  PRODUCT=${2:?}; shift 2 ;;
    --json)   JSON=1; shift ;;
    -n|--limit) LIMIT=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) cb_die "未知参数: $1（用 --help 看用法）" ;;
    *) PRODUCT=$1; shift ;;
  esac
done

cb_ensure_node_options 2>/dev/null || true
command -v coinbase >/dev/null || cb_die "找不到 coinbase 命令"

# 价格加千分位：77254.49 → 77,254.49
fmt_num() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1]
try:
    f = float(s)
except Exception:
    print(s); raise SystemExit
if f == 0:
    print("0")
elif abs(f) >= 1000:
    print(f"{f:,.2f}".rstrip("0").rstrip("."))
elif abs(f) >= 1:
    print(f"{f:,.4f}".rstrip("0").rstrip("."))
else:
    print(f"{f:.10f}".rstrip("0").rstrip("."))
PY
}

# ---------- 单个产品详情 ----------
show_detail() {
  local id=$1 raw
  raw=$(coinbase products get "$id" 2>&1) || {
    local _why=""
    _why=$(printf '%s' "$raw" | grep -o '"errorMessage":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//') || true
    case "$raw" in
      # 不存在的交易对，服务端给的是 HTTP 400 + invalid_argument，
      # 而不是 404 —— 按"查不到"处理，别把用户的产品名拼错报成接口故障。
      *"could not be found"*|*"not found"*|*"NotFound"*|*"not supported for trading"*)
        if [ -n "$_why" ]; then cb_bad "查不到产品：$id —— $_why"; else cb_bad "查不到产品：$id"; fi
        return 3 ;;
      *)
        if [ -z "$_why" ]; then _why=$(printf '%s' "$raw" | head -1); fi
        cb_bad "接口调用失败：$_why"
        return 4 ;;
    esac
  }
  cb_is_json "$raw" || { cb_bad "返回的不是 JSON：$(printf '%s' "$raw" | head -2)"; return 4; }
  if [ "$JSON" -eq 1 ]; then printf '%s\n' "$raw"; return 0; fi

  python3 - "$raw" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
def g(k, default="—"):
    v = d.get(k)
    return default if v in (None, "") else v
def fmt(v):
    try:
        f = float(v)
    except Exception:
        return str(v)
    if f == 0: return "0"
    if abs(f) >= 1000: return f"{f:,.2f}".rstrip("0").rstrip(".")
    if abs(f) >= 1: return f"{f:,.4f}".rstrip("0").rstrip(".")
    return f"{f:.10f}".rstrip("0").rstrip(".")

pct = d.get("price_percentage_change_24h")
pct_s = f"{float(pct):+.2f}%" if pct not in (None, "") else "—"
status = g("status")
print(f"  {g('product_id')}   {g('product_type')}   {status}")
print()
print(f"  价格      {fmt(g('price'))} {g('quote_currency_id', '')}")
print(f"  24h       {pct_s}")
print(f"  24h 成交量 {fmt(g('volume_24h'))} {g('base_currency_id', '')}")
print()
print(f"  最小下单   {fmt(g('base_min_size'))} {g('base_currency_id', '')}"
      f"  /  {fmt(g('quote_min_size'))} {g('quote_currency_id', '')}")
print(f"  最大下单   {fmt(g('base_max_size'))} {g('base_currency_id', '')}"
      f"  /  {fmt(g('quote_max_size'))} {g('quote_currency_id', '')}")
print(f"  数量精度   {g('base_increment')}   价格精度 {g('quote_increment')}")
PY
}

# ---------- 只要价格 ----------
show_ticker() {
  local id=$1 raw
  raw=$(coinbase products get "$id" 2>&1) || {
    local _why=""
    _why=$(printf '%s' "$raw" | grep -o '"errorMessage":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//') || true
    if [ -n "$_why" ]; then cb_bad "查不到产品：$id —— $_why"; else cb_bad "查不到产品：$id"; fi
    return 3
  }
  cb_is_json "$raw" || { cb_bad "返回的不是 JSON"; return 4; }
  printf '%s' "$raw" | cb_json_get price || { cb_bad "返回里没有 price 字段"; return 4; }
}

# ---------- 列表 / 搜索 ----------
list_products() {
  local raw
  raw=$(coinbase products list 2>&1) || {
    cb_bad "接口调用失败：$(printf '%s' "$raw" | grep -o '"errorMessage":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
    return 4
  }
  cb_is_json "$raw" || { cb_bad "返回的不是 JSON"; return 4; }
  if [ "$JSON" -eq 1 ]; then printf '%s\n' "$raw"; return 0; fi

  python3 - "$raw" "$MODE" "${SEARCH:-}" "$QUOTE" "$LIMIT" <<'PY'
import json, sys
raw, mode, needle, quote, limit = sys.argv[1], sys.argv[2], sys.argv[3].upper(), sys.argv[4].upper(), int(sys.argv[5])
d = json.loads(raw)
items = d.get("products") or d.get("accounts") or []
if not isinstance(items, list):
    print("返回结构不是预期的 products 列表", file=sys.stderr); raise SystemExit(4)

if mode == "search":
    sel = [p for p in items if needle in str(p.get("product_id", "")).upper()]
    label = f"包含 {needle} 的产品"
else:
    sel = [p for p in items if str(p.get("quote_currency_id", "")).upper() == quote]
    label = f"以 {quote} 计价的产品"

total = len(sel)
if limit and limit < total:
    shown = sel[:limit]
else:
    shown = sel

print(f"  {label}：{total} 个" + (f"（只显示前 {len(shown)} 个）" if len(shown) < total else ""))
print()
# 按字母序，每行 4 个，方便在窄终端里看
names = sorted(str(p.get("product_id")) for p in shown)
for i in range(0, len(names), 4):
    print("  " + "".join(f"{n:<16}" for n in names[i:i + 4]).rstrip())
if total > len(shown):
    print()
    print(f"  用 -n {total} 看全部，或 --search <关键词> 缩小范围")
PY
}

case "$MODE" in
  ticker) show_ticker "$PRODUCT" ;;
  search|quote) list_products ;;
  auto)
    if [ -n "$PRODUCT" ]; then show_detail "$PRODUCT"; else MODE="quote"; list_products; fi ;;
esac
