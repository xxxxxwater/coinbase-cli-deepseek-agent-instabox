#!/usr/bin/env bash
# cb-candles.sh：K 线渲染与参数校验
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
C="$ROOT/scripts/cb-candles.sh"
export NO_COLOR=1

# 1. 默认渲染：产品名、根数、sparkline、涨跌、最新价都在
out=$(bash "$C" 2>/dev/null)
assert_contains "$out" "BTC-USD  1h  3 根" "标题带产品/周期/根数"
assert_contains "$out" "最新 118" "给出最新收盘价"
assert_contains "$out" "↑" "上升区间用上箭头"
assert_contains "$out" "区间 ↑" "区间涨跌用百分比"
assert_contains "$out" "最高 120" "给出区间最高"
assert_contains "$out" "最低 100" "给出区间最低"
assert_contains "$out" "成交量合计 6" "成交量合计正确（1+2+3）"

# 2. sparkline 是单行块字符，不是 JSON
assert_contains "$out" "▃" "画出块字符（3 根上升，最低那根落在第三档）"
assert_not_contains "$out" '"candles"' "人看的视图里没有原始 JSON"

# 3. 股票没有 K 线接口 —— 必须说清是"不覆盖股票"而不是"没有成交"
out=$(bash "$C" AAPL-USD 2>/dev/null)
assert_contains "$out" "EQUITY" "点明这是股票"
assert_contains "$out" "不覆盖股票" "说清是接口不覆盖"
assert_not_contains "$out" "没有成交" "不把接口缺失说成没成交"

# 4. --json 原样输出
out=$(bash "$C" --json 2>/dev/null)
assert_contains "$out" '"candles"' "--json 原样给出响应"

# 5. 参数校验
out=$(bash "$C" --granularity 7h 2>&1); rc=$?
assert_exit "$rc" 2 "非法周期退出码 2"
assert_contains "$out" "granularity 只能是" "指出合法取值"
out=$(bash "$C" --limit abc 2>&1); rc=$?
assert_exit "$rc" 2 "非数字 limit 退出码 2"
out=$(bash "$C" --limit 1 2>&1); rc=$?
assert_exit "$rc" 2 "只给 1 根 K 线退出码 2"
assert_contains "$out" "看不出走势" "解释为什么至少 2 根"
out=$(bash "$C" --bogus 2>&1); rc=$?
assert_exit "$rc" 2 "未知参数退出码 2"
out=$(bash "$C" --help 2>&1); rc=$?
assert_exit "$rc" 0 "--help 退出码 0"

# 6. 服务端报错 → 退出码 6，且不假装成功
out=$(STUB_CANDLES='{"errorType":"invalid_argument","errorMessage":"nope"}' bash "$C" 2>&1); rc=$?
assert_exit "$rc" 6 "接口失败退出码 6"

# 7. 空 K 线（现货无成交）的说法与股票不同
out=$(STUB_CANDLES='{"candles":[]}' bash "$C" SOL-USD 2>/dev/null)
assert_contains "$out" "没有 K 线" "现货空数据说没成交"

finish
