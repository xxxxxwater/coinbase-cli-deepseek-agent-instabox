#!/usr/bin/env bash
# cb-trade.sh：参数校验、安全默认、真下单路径
. "$(dirname "$0")/../helper.sh"
setup
TRADE="$ROOT/scripts/cb-trade.sh"
export COINBASE_PORTFOLIO_ID="11111111-1111-1111-1111-111111111111"

echo "参数校验"
out=$(bash "$TRADE" BTC-USD HOLD 10 2>&1); rc=$?
assert_exit "$rc" "2" "非法 side 退出码 2"
assert_contains "$out" "BUY 或 SELL" "给出正确取值"

out=$(bash "$TRADE" BTC-USD BUY 10 --type stop 2>&1); rc=$?
assert_exit "$rc" "2" "非法 type 退出码 2"

out=$(bash "$TRADE" BTC-USD BUY 10x 2>&1); rc=$?
assert_exit "$rc" "2" "非法金额退出码 2"
assert_contains "$out" "必须是正数" "提示金额格式"

out=$(bash "$TRADE" BTC-USD BUY 0.1 --type limit 2>&1); rc=$?
assert_exit "$rc" "2" "limit 单缺 --limit 退出码 2"

echo "安全默认：不加 --commit 绝不下单"
: > "$STUB_LOG"
out=$(bash "$TRADE" BTC-USD BUY 25 2>&1); rc=$?
assert_exit "$rc" "0" "dry-run 退出码 0"
called "orders preview" ; assert_exit "$?" "0" "调了 preview"
if called "orders create"; then bad "dry-run 不该下单" "日志里出现了 orders create"; else ok "没有 orders create"; fi
assert_contains "$out" "dry-run" "明确告知是 dry-run"
assert_contains "$out" "quote_size=25" "market BUY 用 quote_size"

echo "SELL 用 base_size"
: > "$STUB_LOG"
bash "$TRADE" BTC-USD SELL 0.001 >/dev/null 2>&1
if grep -q "base_size=0.001" "$STUB_LOG"; then ok "SELL 传 base_size"; else bad "SELL 应传 base_size" "$(cat "$STUB_LOG")"; fi

echo "limit 单带 limit_price"
: > "$STUB_LOG"
bash "$TRADE" BTC-USD BUY 0.001 --type limit --limit 50000 >/dev/null 2>&1
grep -q "limit_price=50000" "$STUB_LOG" && ok "带 limit_price" || bad "缺 limit_price"
grep -q "portfolio_id=11111111-1111-1111-1111-111111111111" "$STUB_LOG" \
  && ok "组合 UUID 进到订单参数" || bad "组合 UUID 丢了"

echo "股票：走 EQUITY 分支，带上交易时段参数"
: > "$STUB_LOG"
out=$(bash "$TRADE" AAPL-USD BUY 10 2>&1)
assert_contains "$out" "不提供独立预览" "说明股票没有独立预览"
assert_contains "$out" "equity_trading_session=NORMAL" "带上会话参数"
if called "orders create"; then bad "股票 dry-run 不该下单"; else ok "股票 dry-run 没有下单"; fi

echo "--commit 才真下单（脚本化用 --yes 跳过确认）"
: > "$STUB_LOG"
out=$(bash "$TRADE" BTC-USD BUY 25 --commit --yes 2>&1); rc=$?
assert_exit "$rc" "0" "--commit 退出码 0"
called "orders create" && ok "调了 orders create" || bad "没调用 create"

: > "$STUB_LOG"
echo "缺组合时不下单"
out=$(env -u COINBASE_PORTFOLIO_ID CB_CONFIG=/tmp/none-$$.json bash "$TRADE" BTC-USD BUY 1 2>&1); rc=$?
assert_exit "$rc" "3" "缺组合退出码 3"
if called "orders"; then bad "缺组合仍下了单" "$(cat "$STUB_LOG")"; else ok "缺组合没有下单"; fi

finish
