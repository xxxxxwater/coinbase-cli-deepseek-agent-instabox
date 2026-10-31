#!/usr/bin/env bash
# cb-brief.sh 的行为测试：四段都在、顺序固定、缺一段必须说出来而不是静默省略。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
B="$ROOT/scripts/cb-brief.sh"
export NO_COLOR=1
export XDG_CACHE_HOME="$TESTDIR/cache"
export COINBASE_PORTFOLIO_ID="11111111-1111-1111-1111-111111111111"

FIX="$TESTDIR/feeds"; mkdir -p "$FIX"
python3 - "$FIX" <<'PY'
import os, sys, time
d = sys.argv[1]; now = time.time()
def rfc(o): return time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(now - o))
an = "".join(
    f'<item><title>Exchange number {i} reports customer funds after hack probe</title>'
    f'<link>https://x/{i}</link><guid>{i}</guid><pubDate>{rfc(600 + i * 60)}</pubDate></item>'
    for i in range(5))
open(os.path.join(d, "sec_press.xml"), "w").write(
    f'<?xml version="1.0"?><rss version="2.0"><channel><title>S</title>{an}</channel></rss>')
PY

run() { CB_NEWS_FIXTURE_DIR="$FIX" bash "$B" "$@" 2>&1; }

# ---------- 四段齐全 + 顺序 ----------
out=$(run --news 2 --candles 3); rc=$?
assert_exit "$rc" 0 "正常运行时退出码 0"
assert_contains "$out" "态势简报" "有标题"
assert_contains "$out" "=== 风控 ===" "有风控段"
assert_contains "$out" "=== 余额 ===" "有余额段"
assert_contains "$out" "=== 走势 ===" "有走势段"
assert_contains "$out" "=== 事件 ===" "有事件段"
first=$(printf '%s\n' "$out" | grep -n '=== ' | head -1 | cut -d: -f1)
second=$(printf '%s\n' "$out" | grep -n '=== 余额' | cut -d: -f1)
assert_eq "$([ "$first" -lt "$second" ] && echo ordered)" "ordered" "风控排在余额之前（先看允不允许，再谈别的）"

# ---------- 风控真的会拦 ----------
bash "$ROOT/scripts/cb-risk.sh" kill >/dev/null 2>&1
out=$(run --news 2 --candles 3)
assert_contains "$out" "kill switch: 开着" "风控段：kill switch 打开后如实显示"
bash "$ROOT/scripts/cb-risk.sh" resume >/dev/null 2>&1
out=$(run --news 2 --candles 3)
assert_contains "$out" "kill switch: 关着" "风控段：恢复后如实显示"

# ---------- 走势段 ----------
out=$(run --candles 3 --news 0)
assert_contains "$out" "BTC-USD" "走势段：默认产品"
out=$(run ETH-USD --candles 3 --news 0)
assert_contains "$out" "ETH-USD" "走势段：接受位置参数换产品"

# ---------- 事件段 ----------
out=$(run --news 2)
assert_contains "$out" "市场事件" "事件段：有事件标题"
assert_contains "$out" "crypto.security" "事件段：带分类"
ev=$(printf '%s\n' "$out" | sed -n '/=== 事件 ===/,$p')
n=$(printf '%s\n' "$ev" | awk '/^[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]/' | wc -l | tr -d ' ')
assert_eq "$n" "2" "事件段：--news 2 只显示 2 行"

out=$(run --news 0)
assert_contains "$out" "（跳过）" "--news 0：事件段跳过"
assert_not_contains "$out" "市场事件" "--news 0：不去抓新闻"

out=$(run --candles 0 --news 2)
assert_contains "$out" "（跳过）" "--candles 0：走势段跳过"

# ---------- 板块失败必须说出来 ----------
BAD="$TESTDIR/bad"; mkdir -p "$BAD"
printf 'not xml at all <<<' > "$BAD/sec_press.xml"
out=$(CB_NEWS_FIXTURE_DIR="$BAD" bash "$B" --news 2 --candles 0 2>&1); rc=$?
assert_exit "$rc" 1 "新闻全失败：整份简报退出码 1（缺失不能当正常）"
assert_contains "$out" "=== 事件 ===" "新闻解析失败：事件段仍然存在"
assert_contains "$out" "所有新闻源都失败了" "新闻解析失败：说清是源全失败"

# 让 coinbase 完全不可用 → 余额与走势都失败 → 退出码 1
PATH_BAK="$PATH"
NOBIN="$TESTDIR/nobin"; mkdir -p "$NOBIN"
out=$(CB_NEWS_FIXTURE_DIR="$FIX" PATH="$NOBIN:/usr/bin:/bin" /bin/bash "$B" --news 0 --candles 3 2>&1); rc=$?
assert_exit "$rc" 1 "有板块不可用：退出码 1"
assert_contains "$out" "不可用" "有板块不可用：明确写出来"
assert_contains "$out" "别把缺失当成正常" "有板块不可用：给出警告"
export PATH="$PATH_BAK"

# ---------- 参数校验 ----------
bash "$B" --bogus >/dev/null 2>&1; assert_exit "$?" 2 "未知参数 → 2"
bash "$B" --news abc >/dev/null 2>&1; assert_exit "$?" 2 "--news 非数字 → 2"
bash "$B" --candles -1 >/dev/null 2>&1; assert_exit "$?" 2 "--candles 负数 → 2"
out=$(bash "$B" --help 2>&1)
assert_contains "$out" "cb-brief.sh" "--help：打印用法"

teardown
finish
