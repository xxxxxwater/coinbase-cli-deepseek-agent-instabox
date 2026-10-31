#!/usr/bin/env bash
# cb-news.sh — 市场事件流（RSS/Atom）：官方公告、监管、主流媒体
#
# 为什么需要：价格告诉你"发生了什么"，新闻告诉你"为什么"。下单前的判断里，
# "SEC 刚对某交易所提起诉讼"比"24h 跌了 1.4%"重要得多。
#
# 设计上刻意保守，因为错报比漏报更糟：
#   · 分级信任：A=官方一手（美联储/欧央行/SEC），B=主流媒体，C=聚合搜索。
#     C 级**永远不会**被评为 P0/P1 —— 未经确认的消息不该触发任何"紧急"判断。
#   · 保守去重：同一件事被五家媒体转载时只留一条。判重看归一化标题的
#     token 相似度（≥0.88）且数字 token 必须一致 —— 宁可留两条，不可把
#     "美联储降息 25bp" 和 "降息 50bp" 合成一条。
#   · 时效封顶：默认只看 48 小时内。**时间解析不出来的条目默认略过**：
#     无法确认它是什么时候发生的，就不能当"刚发生"给你看。
#   · 条件请求：缓存 ETag / Last-Modified，304 就复用缓存，不重复解析。
#
# 用法:
#   cb-news.sh [--limit N] [--since 12h] [--source ID] [--tag 分类] [--json]
#               [--sources] [--no-cache]
#     --limit N     最多显示 N 条（默认 15）
#     --since D     时效窗口，如 6h / 48h / 7d（默认 48h）
#     --source ID   只看某个源（--sources 列出 id）
#     --tag TAG     只看某个分类，如 crypto.security / macro.monetary / regulation
#     --json        机器可读
#     --sources     列出内置源
#     --no-cache    跳过缓存（强制重新抓）但**仍然**不打印旧闻
#     --include-undated  连"时间解析不出来"的条目也显示（默认略过，见下）
#
# 退出码: 0 成功 / 2 用法错 / 6 所有源都失败
#
# 环境变量:
#   CB_NEWS_FIXTURE_DIR  从目录读 <id>.xml 而不是联网（测试用）

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"; }

LIMIT=15
SINCE="48h"
SRC=""
TAG=""
AS_JSON=0
LIST_SRC=0
NO_CACHE=0
UNDATED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --limit)   [ $# -ge 2 ] || { printf '错误: --limit 需要值\n' >&2; exit 2; }; LIMIT=$2; shift 2 ;;
    --since)   [ $# -ge 2 ] || { printf '错误: --since 需要值\n' >&2; exit 2; }; SINCE=$2; shift 2 ;;
    --source)  [ $# -ge 2 ] || { printf '错误: --source 需要值\n' >&2; exit 2; }; SRC=$2; shift 2 ;;
    --tag)     [ $# -ge 2 ] || { printf '错误: --tag 需要值\n' >&2; exit 2; }; TAG=$2; shift 2 ;;
    --json)    AS_JSON=1; shift ;;
    --sources) LIST_SRC=1; shift ;;
    --no-cache) NO_CACHE=1; shift ;;
    --include-undated) UNDATED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '错误: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
  esac
done

case "$LIMIT" in ''|*[!0-9]*) printf '错误: --limit 必须是正整数\n' >&2; exit 2 ;; esac
case "$SINCE" in
  *h|*d|*m) ;;
  *) printf '错误: --since 要写成 6h / 48h / 7d 这种形式\n' >&2; exit 2 ;;
esac

cb_need python3

if [ "$LIST_SRC" -eq 1 ]; then
  cat <<'EOF'
id               信任  说明
fed_monetary     A     美联储货币政策公告（P1 起）
fed_all          A     美联储全部新闻稿
ecb_press        A     欧洲央行新闻
sec_press        A     SEC 新闻稿（监管）
theblock         B     The Block
decrypt          B     Decrypt
blockworks       B     Blockworks
bitcoinmagazine  B     Bitcoin Magazine
cryptoslate      B     CryptoSlate
cnbc_markets     B     CNBC 市场
kraken_blog      B     Kraken 博客（交易所一手）
google_btc       C     Google 新闻「bitcoin」（聚合，永不 P0/P1）
google_coinbase  C     Google 新闻「coinbase」（聚合，永不 P0/P1）
EOF
  exit 0
fi

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/coinbase-agent"
mkdir -p "$CACHE_DIR" 2>/dev/null || true
CACHE="$CACHE_DIR/news.json"

LIMIT="$LIMIT" SINCE="$SINCE" SRC="$SRC" TAG="$TAG" AS_JSON="$AS_JSON" \
NO_CACHE="$NO_CACHE" UNDATED="$UNDATED" CACHE="$CACHE" FIXTURE="${CB_NEWS_FIXTURE_DIR:-}" \
python3 - <<'PY'
import hashlib, json, os, re, sys, time, unicodedata
import urllib.request, urllib.error
import xml.etree.ElementTree as ET

LIMIT = int(os.environ["LIMIT"])
SINCE = os.environ["SINCE"]
SRC = os.environ["SRC"]
TAG = os.environ["TAG"]
AS_JSON = os.environ["AS_JSON"] == "1"
NO_CACHE = os.environ["NO_CACHE"] == "1"
UNDATED = os.environ.get("UNDATED") == "1"
CACHE = os.environ["CACHE"]
FIXTURE = os.environ["FIXTURE"]

# ---- 源清单：信任级别决定它能被评多高 ----
FEEDS = [
    ("fed_monetary",    "美联储·货币政策", "A", "https://www.federalreserve.gov/feeds/press_monetary.xml"),
    ("fed_all",         "美联储·全部",     "A", "https://www.federalreserve.gov/feeds/press_all.xml"),
    ("ecb_press",       "欧洲央行",        "A", "https://www.ecb.europa.eu/rss/press.html"),
    ("sec_press",       "SEC 新闻",        "A", "https://www.sec.gov/news/pressreleases.rss"),
    ("theblock",        "The Block",       "B", "https://www.theblock.co/rss.xml"),
    ("decrypt",         "Decrypt",         "B", "https://decrypt.co/feed"),
    ("blockworks",      "Blockworks",      "B", "https://blockworks.co/feed"),
    ("bitcoinmagazine", "Bitcoin Magazine","B", "https://bitcoinmagazine.com/.rss/full/"),
    ("cryptoslate",     "CryptoSlate",     "B", "https://cryptoslate.com/feed/"),
    ("cnbc_markets",    "CNBC 市场",       "B", "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=20910258"),
    ("kraken_blog",     "Kraken",          "B", "https://blog.kraken.com/feed"),
    ("google_btc",      "Google·bitcoin",  "C", "https://news.google.com/rss/search?q=bitcoin&hl=en-US&gl=US&ceid=US:en"),
    ("google_coinbase", "Google·coinbase", "C", "https://news.google.com/rss/search?q=coinbase&hl=en-US&gl=US&ceid=US:en"),
]
BY_ID = {f[0]: f for f in FEEDS}

if SRC and SRC not in BY_ID:
    print(f"错误: 没有这个源 {SRC}（--sources 看列表）", file=sys.stderr)
    raise SystemExit(2)

STOP = set("the a an of to in on for and or is are was were be been at by with from as it its this that "
           "after before over under new says say said will would could can may".split())

def since_seconds(spec):
    unit = spec[-1]
    n = float(spec[:-1] or 0)
    return n * {"m": 60, "h": 3600, "d": 86400}[unit]

WINDOW = since_seconds(SINCE)
NOW = int(time.time())

def strip_markup(s):
    s = re.sub(r"<[^>]+>", " ", s or "")
    return re.sub(r"\s+", " ", s).strip()

def norm_title(t):
    s = unicodedata.normalize("NFKC", strip_markup(t)).lower()
    s = re.sub(r"https?://\S+", " ", s)
    s = re.sub(r"[^\w\u4e00-\u9fff]+", " ", s)
    return " ".join(s.split())[:300]

def tokens(t):
    return {w for w in norm_title(t).split() if w not in STOP}

def canon_url(u):
    if not u:
        return ""
    try:
        from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit
        p = urlsplit(u)
        if p.scheme not in ("http", "https"):
            return ""
        q = [(k, v) for k, v in parse_qsl(p.query, keep_blank_values=True)
             if not (k.lower().startswith("utm_") or k.lower() in {"fbclid", "gclid", "ref", "igshid"})]
        netloc = p.netloc.lower().removesuffix(":443").removesuffix(":80")
        path = p.path.rstrip("/") or "/"
        return urlunsplit((p.scheme.lower(), netloc, path, urlencode(sorted(q)), ""))
    except ValueError:
        return ""

def same_event(a, b):
    """保守判重：宁可留两条，不可把不同的事合成一条。"""
    na, nb = norm_title(a), norm_title(b)
    if na and na == nb and len(na) >= 16:
        return True
    ta, tb = tokens(a), tokens(b)
    if min(len(ta), len(tb)) < 5:
        return False
    # 数字不同 = 不是同一件事（降息 25bp vs 50bp）
    if {x for x in ta if x.isdecimal()} != {x for x in tb if x.isdecimal()}:
        return False
    return len(ta & tb) / max(len(ta | tb), 1) >= 0.88

CATS = [
    ("crypto.security", "P0", r"(hack|hacked|exploit|breach|drained|stolen|outage|insolven|bankrupt)|遭攻击|盗币|破产|被盗"),
    ("exchange.delisting", "P0", r"(delist|suspend trading|halts? trading|trading halt)|下架|暂停交易|停止交易"),
    ("macro.policy_decision", "P0", r"(fomc statement|rate decision|cuts? rates|hikes? rates|raises? rates)|利率决议"),
    ("macro.monetary", "P1", r"(fomc|federal reserve|fed |interest rate|powell)|美联储|降息|加息"),
    ("macro.data", "P1", r"(cpi|inflation|nonfarm|payrolls|pce|unemployment|gdp)|通胀|非农|失业"),
    ("regulation", "P1", r"(sec |cftc|regulat|lawsuit|charges|settlement|subpoena)|监管|起诉|和解"),
    ("exchange.listing", "P1", r"(new listing|list(?:s|ed)? on|launch(?:es)? (?:spot )?trading)|上线|新增交易对"),
    ("equities.earnings", "P1", r"(earnings|revenue|guidance)|财报|营收"),
    ("etf.flows", "P1", r"(spot etf|etf (?:inflow|outflow|flow))|ETF 流入|ETF 流出"),
    ("crypto.market", "P2", r"(bitcoin|btc|ethereum|eth|crypto|stablecoin|defi)|比特币|以太坊|加密"),
]
RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}

ANALYSIS_RE = re.compile(
    r"^(what|why|how)\b|\bwhat to know\b|\bexplainer\b|\banalysis\b|\bopinion\b|\bop-ed\b|"
    r"\bdeep ?dive\b|\brecap\b|\broundup\b|\bhere'?s what\b|\bexplained\b")

def classify(title, trust, default_priority="P2"):
    t = norm_title(title)
    cat, pri = "general", default_priority
    for name, level, pat in CATS:
        if re.search(pat, t):
            if cat == "general" or RANK[level] < RANK[pri]:
                cat, pri = name, level
    # 解读类标题（"What is EIP-7702?"、"Why bitcoin didn't crash"）不是新事件，
    # 降一级：它值得读，但不该像事故一样打断你。
    analysis = bool(ANALYSIS_RE.search(t))
    if analysis and pri != "P3":
        pri = {"P0": "P1", "P1": "P2", "P2": "P3"}[pri]
    # 聚合搜索（C 级）永远不会被判成 P0/P1：未经确认的消息不该触发紧急判断
    if trust == "C" and RANK[pri] < RANK["P2"]:
        pri = "P2"
    return cat, pri, analysis

def parse_feed(raw):
    root = ET.fromstring(raw)
    out = []
    for item in root.findall(".//item"):
        title = (item.findtext("title") or "").strip()
        link = (item.findtext("link") or "").strip()
        guid = (item.findtext("guid") or "").strip()
        pub = (item.findtext("pubDate") or "").strip()
        desc = strip_markup(item.findtext("description") or "")[:400]
        if title:
            out.append({"title": title, "link": link, "guid": guid, "published": pub, "summary": desc})
    if not out:  # Atom
        A = "{http://www.w3.org/2005/Atom}"
        for e in root.findall(f".//{A}entry"):
            title = (e.findtext(f"{A}title") or "").strip()
            link = ""
            for ln in e.findall(f"{A}link"):
                if ln.get("rel") in (None, "alternate"):
                    link = ln.get("href") or ""
                    break
            guid = (e.findtext(f"{A}id") or "").strip()
            pub = (e.findtext(f"{A}updated") or e.findtext(f"{A}published") or "").strip()
            summ = strip_markup(e.findtext(f"{A}summary") or e.findtext(f"{A}content") or "")[:400]
            if title:
                out.append({"title": title, "link": link, "guid": guid, "published": pub, "summary": summ})
    return out

def parse_when(s):
    """RFC 822（RSS pubDate，含 GMT/PST 等）与 ISO 8601（Atom）都要能吃。
    解不出来返回 0 —— 调用方把它当"时间未知"，不当成"刚刚发生"。"""
    if not s:
        return 0
    s = s.strip()
    # RFC 822: Thu, 30 Oct 2026 12:00:00 GMT / ... +0800
    try:
        from email.utils import parsedate_to_datetime
        dt = parsedate_to_datetime(s)
        if dt is not None:
            return int(dt.timestamp())
    except Exception:
        pass
    # ISO 8601: 2026-10-30T12:00:00Z / +08:00 / 无时区
    try:
        from datetime import datetime, timezone
        t = s.replace("Z", "+00:00")
        dt = datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except Exception:
        pass
    return 0

# ---- 缓存：per-source etag / last-modified / items ----
# 缓存带版本号：日期解析逻辑一旦改动，旧缓存里存的 epoch 就是错的，
# 继续复用会让"三天前的新闻"永远显示成最新的（踩过：缓存里全是 epoch=0）。
CACHE_VERSION = 2
cache = {"version": CACHE_VERSION, "sources": {}}
if not NO_CACHE and os.path.exists(CACHE):
    try:
        with open(CACHE, encoding="utf-8") as f:
            loaded = json.load(f)
        if loaded.get("version") == CACHE_VERSION:
            cache = loaded
    except Exception:
        pass
cache.setdefault("sources", {})

targets = [BY_ID[SRC]] if SRC else FEEDS
errors, fetched, not_modified = [], 0, 0
all_items = []

for sid, name, trust, url in targets:
    entry = cache["sources"].get(sid, {})
    if os.environ.get("FIXTURE"):
        p = os.path.join(FIXTURE, sid + ".xml")
        try:
            raw = open(p, "rb").read()
        except FileNotFoundError:
            # 夹具目录代表"完整的世界"：默认跑时没给夹具的源就是没启用，不算错误。
            # 但用户点名要某个源却没有它 —— 那是配置错了，必须报出来，不能静默成功。
            if SRC:
                errors.append(f"{sid}: 夹具里没有 {sid}.xml")
            continue
        try:
            parsed = parse_feed(raw)
            fetched += 1
        except Exception as e:
            # 坏 XML 不能把整个脚本带崩：记下这个源坏了，其它源照旧
            errors.append(f"{sid}: 解析失败 {type(e).__name__}")
            parsed = entry.get("items", [])
    else:
        headers = {"User-Agent": "cb-news/0.1 (+https://github.com/xxxxxwater/coinbase-cli-deepseek-agent-instabox)"}
        if not NO_CACHE:
            if entry.get("etag"):
                headers["If-None-Match"] = entry["etag"]
            if entry.get("modified"):
                headers["If-Modified-Since"] = entry["modified"]
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as r:
                raw = r.read(2_000_000)
                entry["etag"] = r.headers.get("ETag") or ""
                entry["modified"] = r.headers.get("Last-Modified") or ""
            parsed = parse_feed(raw)
            fetched += 1
        except urllib.error.HTTPError as e:
            if e.code == 304 and entry.get("items"):
                parsed = entry["items"]
                not_modified += 1
            else:
                errors.append(f"{sid}: HTTP {e.code}")
                parsed = entry.get("items", [])
        except Exception as e:
            errors.append(f"{sid}: {type(e).__name__} {str(e)[:50]}")
            parsed = entry.get("items", [])

    items = []
    for it in parsed:
        ts = parse_when(it.get("published", ""))
        cat, pri, analysis = classify(it["title"], trust)
        items.append({
            "source": sid, "source_name": name, "trust": trust,
            "title": strip_markup(it["title"]), "link": it["link"],
            "epoch": ts, "category": cat, "priority": pri, "analysis": analysis,
        })
    # 每源只留最近的 120 条，避免缓存无限长
    items_sorted = sorted(items, key=lambda x: x["epoch"], reverse=True)[:120]
    cache["sources"][sid] = {"etag": entry.get("etag", ""), "modified": entry.get("modified", ""),
                             "items": items_sorted, "checked": NOW}
    all_items.extend(items_sorted)

if not NO_CACHE:
    try:
        tmp = CACHE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CACHE)
    except Exception as e:
        print(f"警告: 缓存写入失败（{e}）", file=sys.stderr)

# ---- 过滤：时效窗口 + 分类 ----
undated = [i for i in all_items if not i["epoch"]]

def in_window(it):
    if not it["epoch"]:
        return UNDATED
    return (NOW - it["epoch"]) <= WINDOW

items = [i for i in all_items if in_window(i)]
if TAG:
    items = [i for i in items if i["category"] == TAG or i["category"].startswith(TAG)]

# ---- 去重 ----
# 只用保守规则：链接相同，或标题几乎相同（Jaccard ≥0.88 且数字token一致）。
# 试过"按主体聚合"，放弃了 —— 英文标题是 Title Case，每个词都大写，
# 专有名词检测退化成噪音（Hack / Shows / Offshore 都会被当成实体），
# 结果要么散开、要么把不同的事并成一条。宁可多几行，不可张冠李戴。
items.sort(key=lambda x: (RANK[x["priority"]], -x["epoch"]))
kept = []
for it in items:
    dup = None
    for k in kept:
        same_link = canon_url(it["link"]) and canon_url(it["link"]) == canon_url(k["link"])
        if same_link or same_event(it["title"], k["title"]):
            dup = k
            break
    if dup is None:
        it.setdefault("also", [])
        kept.append(it)
    else:
        if it["source"] not in [dup["source"]] + dup["also"]:
            dup["also"].append(it["source"])

# ---- 主题概览 ----
# 不去合并，但告诉读者"这批新闻集中在什么事上"：按文档频率取前几个实词。
# 这只描述分布，不改变任何一条的判定。
DF = {}
for it in items:
    for w in tokens(it["title"]):
        if len(w) >= 4 and not w.isdecimal():
            DF[w] = DF.get(w, 0) + 1
TOPICS = [{"token": w, "count": n} for w, n in sorted(DF.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
          if n >= 3]

kept = kept[:LIMIT]

if AS_JSON:
    print(json.dumps({
        "generated": NOW, "window": SINCE, "count": len(kept),
        "fetched": fetched, "not_modified": not_modified,
        "errors": errors, "topics": TOPICS, "items": kept,
    }, ensure_ascii=False, indent=2))
    raise SystemExit(0 if (kept or not errors) else 6)

if not kept:
    if errors and fetched == 0:
        print("✗ 所有源都失败了：", file=sys.stderr)
        for e in errors:
            print("  " + e, file=sys.stderr)
        raise SystemExit(6)
    print(f"最近 {SINCE} 内没有匹配的新闻。")
    if undated and not UNDATED:
        print(f"（另有 {len(undated)} 条时间解析不出来，已略过；--include-undated 可看）")
    for e in errors[:3]:
        print(f"  （{e}）", file=sys.stderr)
    raise SystemExit(0)

ICON = {"P0": "!!!", "P1": "!! ", "P2": "!  ", "P3": "   "}
print(f"市场事件（最近 {SINCE}，{len(kept)} 条；抓取 {fetched} 源，304 复用 {not_modified}）")
if TOPICS:
    print("本批集中在：" + "、".join(f"{t['token']}（{t['count']} 条）" for t in TOPICS))
print("-" * 96)
for it in kept:
    when = time.strftime("%m-%d %H:%M", time.localtime(it["epoch"])) if it["epoch"] else "  ?  "
    src = f"{it['source_name']}/{it['trust']}"
    also = f"  +{len(it['also'])}源" if it.get("also") else ""
    ana = " (解析)" if it.get("analysis") else ""
    print(f"{when}  {ICON[it['priority']]} {it['category']:<22} {src:<22} {it['title'][:58]}{ana}{also}")
print("-" * 96)
print("提示：P0/P1 值得打断手上的事；P2/P3 是背景信息。详情用 --json 取 link。")
if undated and not UNDATED:
    print(f"（另有 {len(undated)} 条时间解析不出来，已略过；--include-undated 可看）")
if errors:
    print(f"（{len(errors)} 个源有问题：{'; '.join(errors[:3])}）", file=sys.stderr)
PY
