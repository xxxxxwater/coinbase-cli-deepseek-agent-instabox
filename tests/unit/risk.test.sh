#!/usr/bin/env bash
# 风控闸门的行为测试：限额、白名单、kill switch、模拟盘、审计日志。
# 全部离线：coinbase 由桩模拟，账本写在临时目录。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
R="$ROOT/scripts/cb-risk.sh"
T="$ROOT/scripts/cb-trade.sh"
UUID="11111111-1111-1111-1111-111111111111"
export COINBASE_PORTFOLIO_ID="$UUID"
export NO_COLOR=1
JR="$(dirname "$CB_CONFIG")/journal.jsonl"   # helper 的 CB_CONFIG 在临时目录里

# ---------- 初始状态 ----------
out=$(bash "$R" show 2>&1); rc=$?
assert_exit "$rc" 0 "show：退出码 0"
assert_contains "$out" "kill switch: 关着" "show：默认允许下单"
assert_contains "$out" "未设置" "show：没设限额时明确说不限"

out=$(bash "$R" path 2>&1)
assert_eq "$out" "$JR" "path：账本就在配置文件旁边"

# ---------- 设限额 ----------
bash "$R" set max_single_trade_usd 100 >/dev/null 2>&1
bash "$R" set max_daily_usd 250 >/dev/null 2>&1
bash "$R" set max_orders_per_hour 2 >/dev/null 2>&1
bash "$R" set allowed_products "BTC-USD,ETH-USD" >/dev/null 2>&1
out=$(bash "$R" show 2>&1)
assert_contains "$out" "max_single_trade_usd   100" "show：单笔上限生效"
assert_contains "$out" "BTC-USD,ETH-USD" "show：白名单生效"

# ---------- check：单笔 / 白名单 ----------
out=$(bash "$R" check BTC-USD BUY 50 2>&1); rc=$?
assert_exit "$rc" 0 "check 50：通过"
out=$(bash "$R" check BTC-USD BUY 150 2>&1); rc=$?
assert_exit "$rc" 4 "check 150：被拒（超过单笔上限）"
assert_contains "$out" "单笔上限" "check 150：说清是哪条限额"
out=$(bash "$R" check SOL-USD BUY 10 2>&1); rc=$?
assert_exit "$rc" 4 "check SOL：被拒（不在白名单）"
assert_contains "$out" "白名单" "check SOL：说清白名单"

# ---------- kill switch ----------
bash "$R" kill >/dev/null 2>&1
out=$(bash "$R" check BTC-USD BUY 10 2>&1); rc=$?
assert_exit "$rc" 4 "kill 之后：任何单子都被拒"
assert_contains "$out" "kill switch" "kill 之后：说明是 kill switch"
bash "$R" resume >/dev/null 2>&1
out=$(bash "$R" check BTC-USD BUY 10 2>&1); rc=$?
assert_exit "$rc" 0 "resume 之后：恢复"

# ---------- 参数校验 ----------
out=$(bash "$R" set max_single_trade_usd abc 2>&1); rc=$?
assert_exit "$rc" 2 "限额写字母：退出码 2"
out=$(bash "$R" set unknown_key 1 2>&1); rc=$?
assert_exit "$rc" 2 "未知键：退出码 2"

# ---------- 与 cb-trade.sh 的联动 ----------
BTC='{"product_id":"BTC-USD","price":"60000","product_type":"SPOT","quote_currency_id":"USD","base_currency_id":"BTC"}'
# 超限：必须被拦在预览之前，且不产生 preview 记录
: > "$JR"
out=$(STUB_PRODUCT="$BTC" bash "$T" BTC-USD BUY 500 2>&1); rc=$?
assert_exit "$rc" 4 "下单超过单笔上限：被拦（退出码 4）"
assert_not_contains "$out" "[预览]" "下单超限：预览压根没跑"
n_block=$(grep -c '"event": "block"' "$JR" 2>/dev/null || echo 0)
assert_eq "$n_block" "1" "记账：被拒只记一条 block（不是两条）"

# 正常：dry-run 记 preview，不占额度
out=$(STUB_PRODUCT="$BTC" bash "$T" BTC-USD BUY 50 2>&1); rc=$?
assert_exit "$rc" 0 "下单 50：通过"
assert_contains "$out" "名义额" "输出：打出了名义金额"
assert_contains "$out" "dry-run" "下单 50：没有真下单"
out=$(bash "$R" show 2>&1)
assert_contains "$out" "今日已用  0.00000000" "额度：dry-run 不占当日额度"

# ---------- 模拟盘 ----------
: > "$JR"
out=$(STUB_PRODUCT="$BTC" bash "$T" BTC-USD BUY 50 --paper 2>&1); rc=$?
assert_exit "$rc" 0 "--paper：退出码 0"
assert_contains "$out" "[paper]" "--paper：说明这是模拟盘"
assert_contains "$out" "coinbase orders create" "--paper：给出真下单的命令"
n_paper=$(grep -c '"event": "paper"' "$JR" 2>/dev/null || echo 0)
assert_eq "$n_paper" "1" "--paper：账本里有 paper 记录"
assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "orders create" "--paper：桩没收到 create"

# ---------- 当日额度：连续两笔真单会超 ----------
bash "$R" set max_single_trade_usd 1000 >/dev/null 2>&1
: > "$JR"
python3 - "$JR" <<'PYJ'
import json, sys, time
# 造两笔已成功的 exec（合计 200），当日上限是 250
for n in (100, 100):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "epoch": int(time.time()),
           "day": time.strftime("%Y-%m-%d"), "event": "exec", "product": "BTC-USD",
           "side": "BUY", "type": "market", "notional": n, "result": "ok"}
    open(sys.argv[1], "a").write(json.dumps(rec) + "\n")
PYJ
out=$(STUB_PRODUCT="$BTC" bash "$T" BTC-USD BUY 60 2>&1); rc=$?
assert_exit "$rc" 4 "当日额度：200+60 超过 250 被拒"
assert_contains "$out" "当日上限" "当日额度：说清是哪条限额"

# ---------- 每小时笔数 ----------
bash "$R" set max_daily_usd 100000 >/dev/null 2>&1
: > "$JR"
python3 - "$JR" <<'PYJ'
import json, sys, time
for _ in range(2):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "epoch": int(time.time()),
           "day": time.strftime("%Y-%m-%d"), "event": "exec", "product": "BTC-USD",
           "side": "BUY", "type": "market", "notional": 1, "result": "ok"}
    open(sys.argv[1], "a").write(json.dumps(rec) + "\n")
PYJ
out=$(STUB_PRODUCT="$BTC" bash "$T" BTC-USD BUY 1 2>&1); rc=$?
assert_exit "$rc" 4 "每小时笔数：已有 2 笔达到上限被拒"
assert_contains "$out" "每小时" "每小时笔数：说清是哪条限额"

# ---------- reset：归档账本 ----------
out=$(bash "$R" reset 2>&1); rc=$?
assert_exit "$rc" 0 "reset：退出码 0"
assert_contains "$out" "归档" "reset：说明是归档不是删除"
if [ -f "$JR" ]; then
  bad "reset：账本应该被移走"
else
  ok "reset：账本已移走（限额从 0 开始）"
fi
n_arch=$(find "$(dirname "$JR")" -name 'journal.jsonl.*.archived' | wc -l | tr -d ' ')
assert_eq "$n_arch" "1" "reset：归档文件留着（审计不丢）"

finish
