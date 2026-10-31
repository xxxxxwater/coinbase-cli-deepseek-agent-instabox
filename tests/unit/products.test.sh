#!/usr/bin/env bash
# cb-products.sh 的行为测试。全部离线，coinbase 由桩模拟。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
S="$ROOT/scripts/cb-products.sh"

BTC='{"product_id":"BTC-USD","price":"77254.49","price_percentage_change_24h":-1.3911,"volume_24h":9084.4,"product_type":"SPOT","quote_currency_id":"USD","base_currency_id":"BTC","base_increment":"0.00000001","quote_increment":"0.01","base_min_size":"0.00000001","base_max_size":3400,"quote_min_size":1,"quote_max_size":150000000,"status":"online"}'
LIST='{"products":[
{"product_id":"BTC-USD","quote_currency_id":"USD"},
{"product_id":"ETH-USD","quote_currency_id":"USD"},
{"product_id":"SOL-USD","quote_currency_id":"USD"},
{"product_id":"ETH-BTC","quote_currency_id":"BTC"},
{"product_id":"CBETH-ETH","quote_currency_id":"ETH"}
],"num_products":5}'

# ---------- 详情 ----------
out=$(STUB_PRODUCT="$BTC" bash "$S" BTC-USD 2>&1); rc=$?
assert_exit "$rc" 0 "详情：退出码 0"
assert_contains "$out" "BTC-USD" "详情：有产品名"
assert_contains "$out" "SPOT" "详情：有产品类型"
assert_contains "$out" "77,254.49" "详情：价格有千分位"
assert_contains "$out" "-1.39%" "详情：带符号的 24h 涨跌"
assert_contains "$out" "最小下单" "详情：有最小下单量"

# 涨跌为零/缺失时不能崩
out=$(STUB_PRODUCT='{"product_id":"X-USD","price":"1","product_type":"SPOT"}' bash "$S" X-USD 2>&1); rc=$?
assert_exit "$rc" 0 "详情：字段缺失不影响退出码"
assert_contains "$out" "X-USD" "详情：字段缺失时仍打印产品名"

# ---------- --ticker ----------
out=$(STUB_PRODUCT="$BTC" bash "$S" --ticker BTC-USD 2>&1)
assert_eq "$out" "77254.49" "--ticker：只输出价格，没有别的字"

# ---------- --search ----------
out=$(STUB_PRODUCTS="$LIST" bash "$S" --search eth 2>&1)
assert_contains "$out" "ETH-USD" "--search：命中 ETH-USD"
assert_contains "$out" "CBETH-ETH" "--search：命中 CBETH-ETH"
assert_not_contains "$out" "BTC-USD" "--search：不出现不匹配的 BTC-USD"
assert_contains "$out" "3 个" "--search：统计到 3 个"

# ---------- --quote ----------
out=$(STUB_PRODUCTS="$LIST" bash "$S" --quote USD 2>&1)
assert_contains "$out" "BTC-USD" "--quote USD：含 BTC-USD"
assert_not_contains "$out" "ETH-BTC" "--quote USD：不含以 BTC 计价的"
assert_contains "$out" "3 个" "--quote USD：统计到 3 个"

# ---------- -n 限制 ----------
out=$(STUB_PRODUCTS="$LIST" bash "$S" --quote USD -n 2 2>&1)
assert_contains "$out" "只显示前" "-n：提示这是截断后的结果"
assert_contains "$out" "3 个" "-n：总数仍然是全量"
# 截断后只应出现 2 个产品名
cnt=$(printf '%s' "$out" | grep -oE '[A-Z]+-USD' | sort -u | wc -l | tr -d ' ')
assert_eq "$cnt" "2" "-n 2：实际只列了 2 个"

# ---------- --json ----------
out=$(STUB_PRODUCT="$BTC" bash "$S" --json BTC-USD 2>&1)
assert_eq "$out" "$BTC" "--json：原样输出 API 返回"

# ---------- 查不到的产品 ----------
out=$(STUB_PRODUCT_MISSING="FOO-BAR" bash "$S" FOO-BAR 2>&1); rc=$?
assert_exit "$rc" 3 "不存在的产品：退出码 3"
assert_contains "$out" "查不到产品" "不存在的产品：说清是查不到而不是接口故障"
assert_contains "$out" "not supported for trading" "不存在的产品：带上服务端原话"

out=$(STUB_PRODUCT_MISSING="FOO-BAR" bash "$S" --ticker FOO-BAR 2>&1); rc=$?
assert_exit "$rc" 3 "--ticker 查不到：退出码 3"

# ---------- 参数校验 ----------
out=$(bash "$S" --nope 2>&1); rc=$?
assert_exit "$rc" 2 "未知参数：退出码 2"
assert_contains "$out" "未知参数" "未知参数：给出提示"

finish
