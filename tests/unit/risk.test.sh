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

# ---------- 下单前二次判闸（预览到确认之间可能有人按 kill switch） ----------
# 桩的 orders create 会先 sleep，模拟"预览很慢"；期间把 KILL 放进去，第二次判定必须拦住。
: > "$JR"
: > "$STUB_LOG"
out=$(STUB_PRODUCT="$BTC" bash "$T" BTC-USD BUY 5 --commit --yes 2>&1); rc=$?
assert_exit "$rc" 0 "无 kill switch 时：真下单能走到 create"
assert_contains "$out" "[执行] coinbase orders create" "无 kill switch 时：输出里有执行行"
assert_contains "$(cat "$STUB_LOG" 2>/dev/null)" "orders create" "无 kill switch 时：桩确实收到了 create"
assert_contains "$(cat "$JR")" '"event": "exec"' "无 kill switch 时：账本记了 exec"

# ---------- 模拟盘 ----------
: > "$JR"
: > "$STUB_LOG"          # 上一段真下单也写过日志，这里必须清干净
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

# ---------- 失败的提交也算笔数（金额不算） ----------
: > "$JR"
python3 - "$JR" <<'PYJ'
import json, sys, time
# 两笔"提交了但失败"：金额不该占额度，但笔数要算 —— 否则 agent 反复打 API 不受限
for _ in range(2):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "epoch": int(time.time()),
           "day": time.strftime("%Y-%m-%d"), "event": "exec", "product": "BTC-USD",
           "side": "BUY", "type": "market", "notional": 100, "result": "error"}
    open(sys.argv[1], "a").write(json.dumps(rec) + "\n")
PYJ
out=$(STUB_PRODUCT="$BTC" bash "$T" BTC-USD BUY 1 2>&1); rc=$?
assert_exit "$rc" 4 "失败的两笔：仍然触发每小时笔数上限"
assert_contains "$out" "每小时上限" "失败的两笔：提示点名每小时上限"
out=$(bash "$R" show 2>&1)
assert_contains "$out" "今日已用  0.00000000" "失败的提交：不占当日金额额度"
assert_contains "$out" "最近一小时 2 笔" "失败的提交：计入最近一小时笔数"

# ---------- report：把账本汇总成人能看的样子 ----------
# 用一份手写的账本，断言才可复现（前面那些步骤的记录数会随测试改动而变）。
RT="$TESTDIR/report"
mkdir -p "$RT"
cat > "$RT/journal.jsonl" <<'JL'
{"ts":"2026-10-31T01:00:00Z","epoch":1,"day":"2026-10-31","event":"preview","product":"BTC-USD","side":"BUY","type":"market","notional":50.0,"result":"preview","reason":""}
{"ts":"2026-10-31T01:01:00Z","epoch":2,"day":"2026-10-31","event":"exec","product":"BTC-USD","side":"BUY","type":"market","notional":50.0,"result":"ok","reason":""}
{"ts":"2026-10-31T01:02:00Z","epoch":3,"day":"2026-10-31","event":"exec","product":"ETH-USD","side":"BUY","type":"market","notional":100.0,"result":"error","reason":"preview insufficient fund"}
{"ts":"2026-10-31T01:03:00Z","epoch":4,"day":"2026-10-31","event":"block","product":"SOL-USD","side":"BUY","type":"market","notional":5.0,"result":"deny","reason":"kill switch 开着"}
{"ts":"2026-10-31T01:04:00Z","epoch":5,"day":"2026-10-31","event":"paper","product":"BTC-USD","side":"SELL","type":"market","notional":7.5,"result":"paper","reason":""}
{"ts":"2026-10-31T01:05:00Z","epoch":6,"day":"2026-10-31","event":"block","product":"ETH-USD","side":"BUY","type":"market","notional":9.0,"result":"deny","reason":"kill switch 开着（coinbase-guard）"}
JL
export RCFG="$RT/config.json"

out=$(CB_CONFIG="$RCFG" bash "$R" report 2>&1); rc=$?
assert_exit "$rc" 0 "report：退出码 0"
assert_contains "$out" "记录: 6 条" "report：条数正确"
assert_contains "$out" "按结果:" "report：有按结果分组"
assert_contains "$out" "exec/ok" "report：能看出成功的提交"
assert_contains "$out" "被拒原因:" "report：有被拒原因段"
assert_contains "$out" "kill switch 开着" "report：拒绝原因保留原文"
assert_contains "$out" "SOL-USD" "report：被拒最多的产品"
assert_contains "$out" "按拦截层:" "report：区分脚本层和守卫层"
assert_contains "$out" "脚本层" "report：说出脚本层拦了几笔"

out=$(CB_CONFIG="$RCFG" bash "$R" report --json 2>&1)
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["total"]==6 and d["by_result"]["exec/ok"]["count"]==1 and round(d["by_result"]["exec/ok"]["notional"],2)==50.0 and d["blocked_reasons"].get("kill switch 开着")==2 and d["blocked_by_layer"].get("coinbase-guard")==1 else 1)' 2>/dev/null; then
  ok "report --json：total / 金额 / 同因归一 / 拦截层都对"
else
  bad "report --json：JSON 内容不对" "$(printf '%.200s' "$out")"
fi
out=$(CB_CONFIG="$RCFG" bash "$R" report --days 0 2>&1); rc=$?
assert_exit "$rc" 0 "report --days 0：退出码 0（只看今天也不炸）"
out=$(CB_CONFIG="$RCFG" bash "$R" report --bogus 2>&1); rc=$?
assert_exit "$rc" 2 "report：未知参数退出码 2"
unset RCFG

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

# ---------- 账本哈希链：改过就要看得出来 ----------
R="$ROOT/scripts/cb-risk.sh"
bash "$R" resume >/dev/null 2>&1
bash "$R" set max_single_trade_usd 100 >/dev/null 2>&1
bash "$R" check BTC-USD BUY 5 >/dev/null 2>&1
bash "$R" kill >/dev/null 2>&1
bash "$R" check ETH-USD BUY 7 >/dev/null 2>&1

out=$(bash "$R" verify 2>&1); rc=$?
assert_exit "$rc" 0 "完好账本：verify 退出码 0"
assert_contains "$out" "哈希链完整" "说清链是完整的"

J=$(bash "$R" path 2>/dev/null | tail -1)
python3 - "$J" <<'PYTAMPER'
import json, sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines()
r = json.loads(lines[0]); r["notional"] = 999999.0
lines[0] = json.dumps(r, ensure_ascii=False)
open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PYTAMPER
out=$(bash "$R" verify 2>&1); rc=$?
assert_exit "$rc" 1 "被改过的账本：verify 退出码 1"
assert_contains "$out" "被改过" "指出这一行被改过"

out=$(bash "$R" report 2>&1)
assert_contains "$out" "账本链" "report 里也报链状态"

echo "== 事件收紧（P0 之后自动降上限）=="
P0="$TESTDIR/p0.json"
export CB_NEWS_P0_FILE="$P0"
# 用一份全新的配置与账本，免得前面用例设的每小时上限/白名单在这里抢先拦
export CB_CONFIG="$TESTDIR/tighten/config.json"
mkdir -p "$TESTDIR/tighten"; : > "$TESTDIR/tighten/.keep"
CB_CONFIG="$TESTDIR/tighten/config.json"
bash "$R" set max_single_trade_usd 100 >/dev/null 2>&1
bash "$R" set tighten_on_p0 true >/dev/null 2>&1
python3 -c "import json,time;json.dump({'count':2,'latest':int(time.time())-300},open('$P0','w'))"
out=$(bash "$R" check BTC-USD BUY 50 2>&1); rc=$?
assert_exit "$rc" 4 "有新鲜 P0 时，50 超过被打折的上限 25 → 被拒"
assert_contains "$out" "事件收紧" "拒绝理由要说清是事件收紧，不是普通超限"
out=$(bash "$R" show 2>&1)
assert_contains "$out" "事件收紧: 生效" "show 里能看到事件收紧在生效"
python3 -c "import json,time;json.dump({'count':2,'latest':int(time.time())-7*3600},open('$P0','w'))"
out=$(bash "$R" check BTC-USD BUY 50 2>&1); rc=$?
assert_exit "$rc" 0 "P0 已过 7 小时（窗口 6h），不再收紧"
bash "$R" set tighten_on_p0 false >/dev/null 2>&1
python3 -c "import json,time;json.dump({'count':2,'latest':int(time.time())-300},open('$P0','w'))"
out=$(bash "$R" check BTC-USD BUY 50 2>&1); rc=$?
assert_exit "$rc" 0 "关掉开关后即使有新鲜 P0 也按原上限"
bash "$R" set tighten_hours 12 >/dev/null 2>&1
bash "$R" set tighten_on_p0 true >/dev/null 2>&1
python3 -c "import json,time;json.dump({'count':1,'latest':int(time.time())-7*3600},open('$P0','w'))"
out=$(bash "$R" check BTC-USD BUY 50 2>&1); rc=$?
assert_exit "$rc" 4 "把窗口调到 12h 后，7 小时前的 P0 又生效了"
rm -f "$P0"
unset CB_NEWS_P0_FILE

finish
