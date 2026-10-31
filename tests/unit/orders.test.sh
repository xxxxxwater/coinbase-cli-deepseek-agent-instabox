#!/usr/bin/env bash
# cb-orders.sh 的行为测试：空态、真实字段渲染、过滤参数、--json、错误分类。
# 全部离线：coinbase 由桩模拟。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
O="$ROOT/scripts/cb-orders.sh"
export COINBASE_PORTFOLIO_ID="11111111-1111-1111-1111-111111111111"
export NO_COLOR=1

# ---------- 空态 ----------
out=$(bash "$O" 2>&1); rc=$?
assert_exit "$rc" 0 "空列表：退出码 0（空不是错误）"
assert_contains "$out" "没有订单" "空列表：明确说没有订单"
assert_contains "$out" "recurring buy" "空列表：提醒定期买入不在这张表里"
assert_contains "$out" "PENDING" "空列表：提示可能是 PENDING"

# ---------- 有订单：按真实字段渲染 ----------
STUB_ORDERS='{"orders":[
 {"order_id":"aaa-1111-bbbb-2222-cccc","product_id":"BTC-USD","side":"BUY","status":"FILLED",
  "created_time":"2026-10-31T07:00:00Z","filled_size":"0.001","average_filled_price":"77250.5",
  "total_fees":"0.69","completion_percentage":"100","number_of_fills":1},
 {"order_id":"ddd-3333","product_id":"ETH-USD","side":"SELL","status":"OPEN",
  "created_time":"2026-10-31T08:00:00Z","filled_size":"0","average_filled_price":"0",
  "total_fees":"0"}],"has_next":false,"cursor":""}'
out=$(STUB_ORDERS="$STUB_ORDERS" bash "$O" 2>&1); rc=$?
assert_exit "$rc" 0 "有订单：退出码 0"
assert_contains "$out" "BTC-USD" "有订单：产品出现"
assert_contains "$out" "FILLED" "有订单：状态出现"
assert_contains "$out" "77250.5" "有订单：成交均价出现"
assert_contains "$out" "已成交" "有订单：表头是中文"
assert_contains "$out" "ETH-USD" "有订单：第二条也在"

# ---------- 分页提示 ----------
STUB_ORDERS='{"orders":[{"order_id":"x","product_id":"BTC-USD","side":"BUY","status":"OPEN"}],"has_next":true,"cursor":"abc"}'
out=$(STUB_ORDERS="$STUB_ORDERS" bash "$O" 2>&1)
assert_contains "$out" "还有下一页" "has_next：提示 --all"

# ---------- 过滤参数真的传下去了 ----------
: > "$STUB_LOG"
bash "$O" --open --product BTC-USD --limit 5 >/dev/null 2>&1
assert_contains "$(cat "$STUB_LOG")" "status=OPEN" "--open：传成 status=OPEN"
assert_contains "$(cat "$STUB_LOG")" "product_ids=BTC-USD" "--product：传成 product_ids"
assert_contains "$(cat "$STUB_LOG")" "limit=5" "--limit：传下去了"
: > "$STUB_LOG"
bash "$O" --all >/dev/null 2>&1
assert_contains "$(cat "$STUB_LOG")" "--paginate" "--all：带上 --paginate"
: > "$STUB_LOG"
bash "$O" >/dev/null 2>&1
assert_contains "$(cat "$STUB_LOG")" "portfolio_id==11111111-1111-1111-1111-111111111111" "默认带上配置里的组合"

# ---------- --json 原样 ----------
STUB_ORDERS='{"orders":[{"order_id":"x"}],"has_next":false,"cursor":""}'
out=$(STUB_ORDERS="$STUB_ORDERS" bash "$O" --json 2>&1)
assert_contains "$out" '"order_id":"x"' "--json：原样输出接口内容"

# ---------- 参数与错误分类 ----------
out=$(bash "$O" --bogus 2>&1); rc=$?
assert_exit "$rc" 2 "未知参数：退出码 2"
out=$(bash "$O" --limit abc 2>&1); rc=$?
assert_exit "$rc" 2 "--limit 非数字：退出码 2"
STUB_ORDERS='not json at all'
out=$(STUB_ORDERS="$STUB_ORDERS" bash "$O" 2>&1); rc=$?
assert_exit "$rc" 5 "返回不是 JSON：退出码 5（不是当成空列表）"
assert_contains "$out" "不是 JSON" "返回不是 JSON：说清楚"

finish
