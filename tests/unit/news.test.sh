#!/usr/bin/env bash
# cb-news.sh 的行为测试：分级信任、保守去重、时效窗口、缓存、离线夹具。
# 全程不联网：用 CB_NEWS_FIXTURE_DIR 从夹具目录读 <id>.xml。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
N="$ROOT/scripts/cb-news.sh"
export NO_COLOR=1
export XDG_CACHE_HOME="$TESTDIR/cache"

FIX="$TESTDIR/feeds"
mkdir -p "$FIX"
# 夹具里的时间要相对"现在"生成，否则过几天就全落在 48h 窗口外了
python3 - "$FIX" <<'PY'
import sys, time, os
d = sys.argv[1]
now = time.time()
def rfc(off):
    return time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(now - off))
# A 级官方源：一条 P1 货币政策 + 一条 30 天前的旧闻
open(os.path.join(d, "fed_monetary.xml"), "w").write(f"""<?xml version="1.0"?><rss version="2.0"><channel>
<title>Federal Reserve</title>
<item><title>Federal Reserve issues FOMC statement on interest rate decision</title>
<link>https://www.federalreserve.gov/newsevents/pressreleases/x1.htm</link>
<guid>x1</guid><pubDate>{rfc(3600)}</pubDate><description>&lt;p&gt;The Committee decided to cut rates.&lt;/p&gt;</description></item>
<item><title>Federal Reserve Board announces appointment of new general counsel</title>
<link>https://www.federalreserve.gov/newsevents/pressreleases/old.htm</link>
<guid>old</guid><pubDate>{rfc(86400*30)}</pubDate><description>very old</description></item>
</channel></rss>""")
# A 级监管源：一条 P0（安全事件 + 起诉）
open(os.path.join(d, "sec_press.xml"), "w").write(f"""<?xml version="1.0"?><rss version="2.0"><channel>
<title>SEC</title>
<item><title>SEC charges crypto exchange after hack drained customer funds</title>
<link>https://www.sec.gov/news/press-release/2026-1</link>
<guid>sec1</guid><pubDate>{rfc(7200)}</pubDate><description>charges</description></item>
</channel></rss>""")
# C 级聚合源：标题就是上面那条 SEC 新闻的另一种写法 —— 既要去重，也要被压到 P2
open(os.path.join(d, "google_btc.xml"), "w").write(f"""<?xml version="1.0"?><rss version="2.0"><channel>
<title>Google News</title>
<item><title>SEC charges crypto exchange after hack drained customer funds</title>
<link>https://news.google.com/rss/articles/abc?utm_source=x&amp;utm_medium=y</link>
<guid>g1</guid><pubDate>{rfc(7000)}</pubDate><description>same event</description></item>
</channel></rss>""")
# 主流媒体源：一条事故 + 同一件事的另一种报道（应聚合成一组）+ 一条解读类（应降级并标"解析"）
open(os.path.join(d, "decrypt.xml"), "w").write(f"""<?xml version="1.0"?><rss version="2.0"><channel>
<title>Decrypt</title>
<item><title>Binance hack: exchange sets aside 6.4 billion to cover customer losses</title>
<link>https://decrypt.co/1</link><guid>d1</guid><pubDate>{rfc(5400)}</pubDate></item>
<item><title>Binance hackers deploy never-before-seen laundering tactics after the hack</title>
<link>https://decrypt.co/2</link><guid>d2</guid><pubDate>{rfc(5000)}</pubDate></item>
<item><title>Why bitcoin did not crash like it did in 2018</title>
<link>https://decrypt.co/3</link><guid>d3</guid><pubDate>{rfc(4000)}</pubDate></item>
</channel></rss>""")
# Atom 格式 + 只有 base_size 无关，这里测 Atom 解析与下架类 P0
open(os.path.join(d, "theblock.xml"), "w").write(f"""<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>The Block</title>
<entry><title>Exchange to delist three tokens following regulatory review</title>
<link rel="alternate" href="https://www.theblock.co/post/1"/>
<id>tb1</id><updated>{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now-1800))}</updated>
<summary>delisting</summary></entry>
</feed>""")
PY

run() { CB_NEWS_FIXTURE_DIR="$FIX" bash "$N" "$@" 2>&1; }

# ---------- 基本输出 ----------
out=$(run); rc=$?
assert_exit "$rc" 0 "默认运行退出码 0"
assert_contains "$out" "市场事件" "默认运行：有标题行"
assert_contains "$out" "FOMC" "默认运行：抓到美联储那条"
assert_contains "$out" "macro.policy_decision" "分类：FOMC 声明 → macro.policy_decision（比笼统的 macro.monetary 更具体）"
assert_contains "$out" "P0" "等级：出现 P0"
assert_contains "$out" "crypto.security" "分类：SEC 被攻击 → crypto.security"
assert_not_contains "$out" "appointment of new" "时效窗口：30 天前的旧闻默认不显示"

# ---------- 分级信任：C 级永不 P0/P1 ----------
# ---------- 保守去重 ----------
out=$(run --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
hits = [i for i in d["items"] if "SEC charges crypto exchange" in i["title"]]
n = len(hits)
also = len(hits[0].get("also", [])) if hits else -1
print("hits=%d also=%d" % (n, also))')
assert_contains "$out" "hits=1" "去重：同一事件只留一条"
assert_contains "$out" "also=1" "去重：合并掉的来源记在 also 里（+1源）"
out=$(run)
assert_contains "$out" "+1源" "去重：表格里显示 +1源"
out=$(run)
assert_contains "$out" "(解析)" "解读类标题标注 (解析)"
assert_contains "$out" "本批集中在" "主题概览：告诉你这批新闻集中在什么事上"
out=$(run --json | python3 -c '
import json,sys
d=json.load(sys.stdin)
a=[i for i in d["items"] if i.get("analysis")]
print("an=%d pri=%s" % (len(a), a[0]["priority"]) if a else "an=0")')
assert_contains "$out" "an=1" "解读类：确实被识别出来"
assert_contains "$out" "pri=P3" "解读类：等级被降一级（crypto.market P2 → P3）"

# ---------- 时效窗口可放宽 ----------
out=$(run --since 1000h)
assert_contains "$out" "appointment of new" "--since 1000h：旧闻被放出来"

# ---------- 过滤 ----------
out=$(run --source fed_monetary)
assert_not_contains "$out" "delist" "--source：只出这一个源"
out=$(run --tag crypto.security)
assert_contains "$out" "SEC charges" "--tag：命中 crypto.security"
assert_not_contains "$out" "FOMC" "--tag：不相关分类被过滤"
out=$(run --tag macro)
assert_contains "$out" "FOMC" "--tag 前缀匹配：macro 命中 macro.monetary"
out=$(run --limit 1 --json | python3 -c 'import json,sys;print("n=%d"%json.load(sys.stdin)["count"])')
assert_contains "$out" "n=1" "--limit：条数受控"

# ---------- 源清单与参数校验 ----------
out=$(bash "$N" --sources 2>&1)
assert_contains "$out" "fed_monetary" "--sources：列出 id"
assert_contains "$out" "永不 P0/P1" "--sources：标明 C 级不能触发紧急判断"
out=$(bash "$N" --limit 3 --sources 2>&1); rc=$?
assert_exit "$rc" 0 "--sources 不需要网络"

bash "$N" --limit abc >/dev/null 2>&1; assert_exit "$?" 2 "--limit 非数字 → 2"
bash "$N" --since 48 >/dev/null 2>&1; assert_exit "$?" 2 "--since 缺单位 → 2"
bash "$N" --source nope >/dev/null 2>&1; assert_exit "$?" 2 "未知源 → 2"
bash "$N" --bogus >/dev/null 2>&1; assert_exit "$?" 2 "未知参数 → 2"

# ---------- 全部源失败 ----------
EMPTY="$TESTDIR/nofeeds"; mkdir -p "$EMPTY"
out=$(CB_NEWS_FIXTURE_DIR="$EMPTY" bash "$N" --source fed_monetary 2>&1); rc=$?
assert_exit "$rc" 6 "源全失败 → 6"
assert_contains "$out" "所有源都失败了" "源全失败：说清楚"

# ---------- 空窗口 ----------
out=$(CB_NEWS_FIXTURE_DIR="$FIX" bash "$N" --since 1m 2>&1); rc=$?
assert_exit "$rc" 0 "窗口内没有新闻：退出码仍是 0"
assert_contains "$out" "没有匹配的新闻" "窗口内没有新闻：说清楚不是错误"

# ---------- 时间解析不出来 ----------
BAD="$TESTDIR/baddates"; mkdir -p "$BAD"
cat > "$BAD/fed_monetary.xml" <<'EOF'
<?xml version="1.0"?><rss version="2.0"><channel><title>F</title>
<item><title>Federal Reserve issues statement with unparseable date</title><link>https://a/bad</link><guid>bad</guid><pubDate>not a date</pubDate></item>
</channel></rss>
EOF
out=$(CB_NEWS_FIXTURE_DIR="$BAD" bash "$N" --source fed_monetary 2>&1); rc=$?
assert_exit "$rc" 0 "时间解析不出来：不算失败"
assert_not_contains "$out" "unparseable date" "时间解析不出来：默认不显示（不能当刚发生）"
assert_contains "$out" "时间解析不出来" "时间解析不出来：说明略过了几条"
out=$(CB_NEWS_FIXTURE_DIR="$BAD" bash "$N" --source fed_monetary --include-undated 2>&1)
assert_contains "$out" "unparseable date" "--include-undated：显式要求才显示"

# ---------- 缓存 ----------
CB_NEWS_FIXTURE_DIR="$FIX" bash "$N" >/dev/null 2>&1
assert_file "$XDG_CACHE_HOME/coinbase-agent/news.json" "缓存文件已写"
perms=$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode)[-3:])' "$XDG_CACHE_HOME/coinbase-agent/news.json")
assert_eq "$perms" "600" "缓存文件权限 600（只自己可读）"
out=$(CB_NEWS_FIXTURE_DIR="$FIX" bash "$N" --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print("srcs=%d"%len(d["items"]))')
assert_contains "$out" "srcs=" "重复运行不炸（缓存可复用）"

echo "== P0 标记文件（给风控读，不让风控联网）=="
MK="$TESTDIR/p0.json"
CB_NEWS_FIXTURE_DIR="$FIX" CB_NEWS_P0_FILE="$MK" bash "$N" >/dev/null 2>&1
assert_file "$MK" "跑完会写 P0 标记"
if python3 -c "import json,sys;d=json.load(open('$MK'));sys.exit(0 if d['count']>=1 and d['latest']>0 else 1)" 2>/dev/null; then
  ok "标记里有 P0 计数与最新时间"
else
  bad "标记内容不对" "$(cat "$MK" 2>/dev/null)"
fi
perms=$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode)[-3:])' "$MK" 2>/dev/null)
assert_eq "$perms" "600" "标记文件权限 600"

teardown
finish
