#!/usr/bin/env bash
# cb-x402.sh 的行为测试：目录过滤、价格换算、默认不花钱、花钱要走闸门。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
X="$ROOT/scripts/cb-x402.sh"
R="$ROOT/scripts/cb-risk.sh"
export COINBASE_PORTFOLIO_ID="11111111-1111-1111-1111-111111111111"
export NO_COLOR=1

CATALOG='{"resources":[
 {"resource":"https://x402.glassnode.com/v1/metadata/assets","description":"Assets Metadata — Lists all assets known to Glassnode","accepts":[{"amount":"10000"}]},
 {"resource":"https://x402.other.io/v1/price/BTC","description":"BTC spot price","accepts":[{"amount":"50000"}]},
 {"resource":"https://x402.other.io/v1/nochan","description":"no accepts field"}]}'

# ---------- 目录 ----------
out=$(STUB_X402="$CATALOG" bash "$X" 2>&1); rc=$?
assert_exit "$rc" 0 "resources：退出码 0"
assert_contains "$out" "0.0100 USDC" "resources：10000 原子单位 = 0.01 USDC"
assert_contains "$out" "0.0500 USDC" "resources：50000 原子单位 = 0.05 USDC"
assert_contains "$out" "glassnode" "resources：资源 URL 出现"
assert_contains "$out" "Assets Metadata" "resources：描述出现"
assert_contains "$out" "x402.other.io/v1/nochan" "resources：缺 accepts 的条目也照样列出（不崩）"
assert_not_contains "$out" "还有 0 条" "resources：全显示时不提示剩余"

out=$(STUB_X402="$CATALOG" bash "$X" --search glassnode 2>&1)
assert_contains "$out" "glassnode" "resources --search：命中"
assert_not_contains "$out" "other.io" "resources --search：未命中的被过滤"

out=$(STUB_X402="$CATALOG" bash "$X" --limit 1 2>&1)
assert_contains "$out" "还有 2 条" "resources --limit：提示还有几条"

out=$(STUB_X402="$CATALOG" bash "$X" --search 不存在的词 2>&1)
assert_contains "$out" "没有匹配的资源" "resources --search：空结果说清楚"

out=$(STUB_X402="$CATALOG" bash "$X" --json 2>&1)
assert_contains "$out" '"resource":"https://x402.glassnode.com/v1/metadata/assets"' "--json：原样输出"

STUB_X402='not json'
out=$(STUB_X402="$STUB_X402" bash "$X" 2>&1); rc=$?
assert_exit "$rc" 5 "返回不是 JSON：退出码 5"

# ---------- fetch 默认不花钱 ----------
: > "$STUB_LOG"
out=$(bash "$X" fetch https://x402.glassnode.com/v1/metadata/assets --max-amount 0.05 2>&1); rc=$?
assert_exit "$rc" 0 "fetch 不加 --commit：退出码 0"
assert_contains "$out" "还没花钱" "fetch 不加 --commit：明确说没花钱"
assert_contains "$out" "0.05 USDC" "fetch：打印上限"
assert_contains "$out" "max_amount=50000" "fetch：USDC 换算成 6 位原子单位"
if grep -q "x402 fetch" "$STUB_LOG" 2>/dev/null; then
  bad "fetch 不加 --commit：不应该真的调用接口"
else
  ok "fetch 不加 --commit：没有调用接口"
fi

# ---------- kill switch 下即使 --commit 也不花 ----------
bash "$R" kill >/dev/null 2>&1
out=$(STUB_X402_FETCH='{"ok":true}' bash "$X" fetch https://x402.glassnode.com/v1/assets --max-amount 0.05 --commit 2>&1); rc=$?
assert_exit "$rc" 4 "kill switch 开着 --commit：退出码 4（被风控拒绝）"
assert_contains "$out" "风控" "kill switch 开着 --commit：说是被风控拒绝"
bash "$R" resume >/dev/null 2>&1

# ---------- 单笔上限也管 x402 ----------
bash "$R" set max_single_trade_usd 0.01 >/dev/null 2>&1
out=$(bash "$X" fetch https://x402.glassnode.com/v1/assets --max-amount 1 --commit 2>&1); rc=$?
assert_exit "$rc" 4 "超过单笔上限 --commit：退出码 4"
bash "$R" set max_single_trade_usd 100 >/dev/null 2>&1

# ---------- 放行时真的调用，并记账 ----------
: > "$STUB_LOG"
out=$(STUB_X402_FETCH='{"asset":"BTC"}' bash "$X" fetch https://x402.glassnode.com/v1/assets --max-amount 0.05 --commit 2>&1); rc=$?
assert_exit "$rc" 0 "放行 --commit：退出码 0"
assert_contains "$out" '"asset":"BTC"' "放行 --commit：把取回的内容原样输出"
assert_contains "$(cat "$STUB_LOG")" "x402 fetch" "放行 --commit：确实调用了接口"
out=$(bash "$R" report 2>&1)
assert_contains "$out" "X402:x402.glassnode.com" "放行 --commit：账本里记了这笔（审计）"

# ---------- 参数校验 ----------
out=$(bash "$X" fetch 2>&1); rc=$?
assert_exit "$rc" 2 "fetch 不带 URL：退出码 2"
out=$(bash "$X" fetch ftp://x/y 2>&1); rc=$?
assert_exit "$rc" 2 "非 http(s) URL：退出码 2"
out=$(bash "$X" --bogus 2>&1); rc=$?
assert_exit "$rc" 2 "未知参数：退出码 2"

finish
