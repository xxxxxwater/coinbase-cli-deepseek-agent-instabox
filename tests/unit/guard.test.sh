#!/usr/bin/env bash
# PATH 守卫（guard/coinbase）的行为测试：只拦 orders create/cancel，其它透明转发。
# 用假 coinbase 冒充真程序，全部离线。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
export NO_COLOR=1

# 布置一个"装好"的样子：$TESTDIR/bin/coinbase 是守卫，$STUB_DIR/bin/coinbase 是真的
# 注意：helper 的 $STUB_DIR 就是 $TESTDIR/bin，守卫不能放同一个目录 ——
# 否则守卫会把自己跳过，然后认定"PATH 里没有真的 coinbase"。
export CB_CONFIG="$CB_CONFIG"
GB="$TESTDIR/guardbin"; mkdir -p "$GB" "$TESTDIR/scripts/lib"
cp "$ROOT/guard/coinbase" "$GB/coinbase"
chmod +x "$GB/coinbase"
cp "$ROOT/scripts/lib/config.sh" "$ROOT/scripts/lib/risk.sh" "$TESTDIR/scripts/lib/"

# 桩（$STUB_DIR/bin/coinbase）就是"真程序"：捕获参数即算被调用。
# 守卫放在它前面，所以 PATH 顺序是：守卫目录 → 桩目录。
export FAKE_LOG="$STUB_LOG"
export PATH="$GB:$STUB_DIR:$PATH"
GUARD="$GB/coinbase"

# ---------- 透明转发 ----------
out=$(bash "$GUARD" --version 2>&1); rc=$?
assert_exit "$rc" 0 "--version：退出码 0"
assert_contains "$out" "0.0.11" "--version：真的交给了 coinbase（桩的版本号）"
assert_contains "$(cat "$FAKE_LOG")" "--version" "--version：真程序收到了这个参数"

out=$(bash "$GUARD" balance 2>&1); rc=$?
assert_exit "$rc" 0 "balance：放行（只读命令不拦）"

out=$(bash "$GUARD" orders preview product_id==BTC-USD side==BUY 2>&1); rc=$?
assert_exit "$rc" 0 "orders preview：放行（预览不下来拦）"
assert_contains "$(cat "$FAKE_LOG")" "orders preview" "orders preview：真程序收到了"

# ---------- kill switch ----------
: > "$FAKE_LOG"
bash "$ROOT/scripts/cb-risk.sh" kill >/dev/null 2>&1
out=$(bash "$GUARD" orders create product_id==BTC-USD side==BUY quote_size==5 2>&1); rc=$?
assert_exit "$rc" 4 "kill switch：orders create 被拒绝"
assert_contains "$out" "kill switch" "kill switch：说清原因"
assert_eq "$(wc -l < "$FAKE_LOG" | tr -d ' ')" "0" "kill switch：真程序一次都没被调用"
J="$(dirname "$CB_CONFIG")/journal.jsonl"
assert_contains "$(cat "$J")" '"event": "block"' "kill switch：账本里有 block 记录"
bash "$ROOT/scripts/cb-risk.sh" resume >/dev/null 2>&1

# ---------- 白名单 ----------
bash "$ROOT/scripts/cb-risk.sh" set allowed_products "ETH-USD" >/dev/null 2>&1
: > "$FAKE_LOG"
out=$(bash "$GUARD" orders create product_id==BTC-USD side==BUY quote_size==5 2>&1); rc=$?
assert_exit "$rc" 4 "白名单：BTC-USD 不在白名单被拒"
assert_eq "$(wc -l < "$FAKE_LOG" | tr -d ' ')" "0" "白名单：真程序没被调用"
out=$(bash "$GUARD" orders create product_id==ETH-USD side==BUY quote_size==5 2>&1); rc=$?
assert_exit "$rc" 0 "白名单：ETH-USD 在白名单放行"
assert_contains "$(cat "$FAKE_LOG")" "product_id==ETH-USD" "白名单：允许的确实交给了真程序"

# ---------- orders cancel 也算改状态 ----------
: > "$FAKE_LOG"
bash "$ROOT/scripts/cb-risk.sh" kill >/dev/null 2>&1
out=$(bash "$GUARD" orders cancel order_id==abc 2>&1); rc=$?
assert_exit "$rc" 4 "orders cancel：kill switch 下也被拒"
assert_eq "$(wc -l < "$FAKE_LOG" | tr -d ' ')" "0" "orders cancel：真程序没被调用"
bash "$ROOT/scripts/cb-risk.sh" resume >/dev/null 2>&1

# ---------- 找不到风控库：拒绝而不是放行 ----------
mv "$TESTDIR/scripts/lib" "$TESTDIR/scripts/lib.off"
out=$(bash "$GUARD" orders create product_id==BTC-USD 2>&1); rc=$?
assert_exit "$rc" 78 "缺少风控库：fail closed（退出码 78）"
assert_contains "$out" "找不到风控库" "缺少风控库：说清原因"
mv "$TESTDIR/scripts/lib.off" "$TESTDIR/scripts/lib"

# ---------- 找不到真 coinbase ----------
out=$(PATH="$GB:/usr/bin:/bin" bash "$GUARD" --version 2>&1); rc=$?
assert_exit "$rc" 127 "找不到真程序：退出码 127（不会自己 exec 自己）"
assert_contains "$out" "找不到真正的 coinbase" "找不到真程序：说清原因"

finish
