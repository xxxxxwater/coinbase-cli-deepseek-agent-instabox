#!/usr/bin/env bash
#
# cb-market.sh — 一屏市场状态：情绪 / 总量 / 流动性 / 杠杆 / 链上拥堵
#
# 为什么需要它：下单前该看的不是"价格涨没涨"，而是"现在是贪婪还是恐惧、
# 总市值在不在缩、稳定币在不在流出、杠杆钱是多是空、链上堵不堵"。
# 这些数据散在五个免费接口上，任何一个都能挂，所以这里逐个容错，
# 挂了的段落写清楚原因，不许留白。
#
# 只接实测从这台机器能拿到的源（2026-10-31 逐个 curl 验证）：
#   ✓ alternative.me  Fear & Greed
#   ✓ coingecko.com   global
#   ✓ llama.fi        stablecoins
#   ✓ mempool.space   fees/recommended
#   ✓ okx.com         v5/public/funding-rate
#   ✗ binance / bybit / deribit —— 出口 IP 被地区封锁（451 / 403），不是代码问题
#
# 用法:
#   cb-market.sh                   查看全部
#   cb-market.sh --only fng,funding 只看某几段（fng|cap|stable|funding|fees）
#   cb-market.sh --json            给程序看
#   cb-market.sh --strict          有任何一段拿不到就退出码 1
#   cb-market.sh --no-cache        不用缓存（默认缓存 120 秒，别把免费接口打爆）
#
# 退出码: 0 成功 / 2 用法错 / 6 全部源都失败
#
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
[ -f "$SELF_DIR/lib/config.sh" ] && . "$SELF_DIR/lib/config.sh"

CB_MARKET_TTL=${CB_MARKET_TTL:-120}
UA="cb-market/1.0 (+coinbase-cli-deepseek-agent-instabox)"

say() { printf '%s\n' "$*" >&2; }
die() { printf '错误: %s\n' "$*" >&2; exit 2; }

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 && !/^#/ { exit }' "${BASH_SOURCE[0]}"
}

WANT="fng,cap,stable,funding,fees"
JSON=0
STRICT=0
USE_CACHE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --json) JSON=1 ;;
        --strict) STRICT=1 ;;
        --no-cache) USE_CACHE=0 ;;
        --only) [ $# -ge 2 ] || die "--only 需要一个值"; WANT=$2; shift ;;
        --only=*) WANT=${1#*=} ;;
        -h|--help) usage; exit 0 ;;
        *) die "不认识的参数: $1" ;;
    esac
    shift
done

want() { case ",$WANT," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/coinbase-agent/market"
FIXTURES=${CB_MARKET_FIXTURE_DIR:-}
TMPD=$(mktemp -d) || die "无法创建临时目录"
trap 'rm -rf "$TMPD"' EXIT

# fetch <键> <url> [method] [body] —— 结果落到 $TMPD/<键>.json，回显 http code
fetch() {
    local key=$1 url=$2 method=${3:-GET} body=${4:-}
    local out="$TMPD/$key.json" cache="$CACHE_DIR/$key.json" code

    if [ -n "$FIXTURES" ]; then
        if [ -f "$FIXTURES/$key.json" ]; then
            cp "$FIXTURES/$key.json" "$out"
            printf '200'
            return 0
        fi
        printf '000'
        return 0
    fi

    if [ "$USE_CACHE" = "1" ] && [ -f "$cache" ]; then
        local age
        age=$(( $(date +%s) - $(date -r "$cache" +%s 2>/dev/null || echo 0) ))
        if [ "$age" -ge 0 ] && [ "$age" -lt "$CB_MARKET_TTL" ]; then
            cp "$cache" "$out"
            printf '200'
            return 0
        fi
    fi

    if [ "$method" = "POST" ]; then
        code=$(curl -sS --max-time 12 -A "$UA" -X POST \
                    -H 'Content-Type: application/json' -d "$body" \
                    -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
    else
        code=$(curl -sS --max-time 12 -A "$UA" -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
    fi
    [ -n "$code" ] || code=000

    if [ "$code" = "200" ] && [ -s "$out" ] && [ "$USE_CACHE" = "1" ]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null && chmod 700 "$CACHE_DIR" 2>/dev/null
        cp "$out" "$cache" 2>/dev/null && chmod 600 "$cache" 2>/dev/null
    fi
    printf '%s' "$code"
}

# 渲染：python3 读 $TMPD 下所有响应 + 状态表，输出文本或 JSON
RENDER=$(cat <<'PY'
import json, os, sys, datetime

tmp, want, as_json, strict = sys.argv[1], sys.argv[2].split(","), sys.argv[3] == "1", sys.argv[4] == "1"
want = [w for w in want if w]

def load(key):
    p = os.path.join(tmp, key + ".json")
    if not os.path.exists(p):
        return None
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def status(key):
    p = os.path.join(tmp, key + ".code")
    if not os.path.exists(p):
        return "?"
    return open(p, encoding="utf-8").read().strip()

rows, gaps = [], []

def why(key):
    st = status(key)
    if st == "200":
        return "解析失败（HTTP 200 但结构不对）"
    if st == "000":
        return "连不上（超时或被拒）"
    return "HTTP " + st

def add(key, label, value, note="", ok=True):
    rows.append({"key": key, "label": label, "value": value, "note": note, "ok": ok})
    if not ok:
        gaps.append(key)

# 1. 情绪
if "fng" in want:
    d = load("fng")
    try:
        cur = d["data"][0]
        val = int(cur["value"]); cls = cur["value_classification"]
        prev = int(d["data"][1]["value"]) if len(d["data"]) > 1 else None
        arrow = "" if prev is None else (" ↑ 昨日 %d" % prev if val > prev else (" ↓ 昨日 %d" % prev if val < prev else " → 昨日 %d" % prev))
        add("fng", "情绪", "%d（%s）%s" % (val, cls, arrow))
    except Exception:
        add("fng", "情绪", "（不可用：%s）" % why("fng"), ok=False)

# 2. 总量
if "cap" in want:
    d = load("global")
    try:
        g = d["data"]
        cap = float(g["total_market_cap"]["usd"]) / 1e12
        chg = float(g.get("market_cap_change_percentage_24h_usd") or 0)
        dom = float(g["market_cap_percentage"]["btc"])
        add("cap", "总量", "$%.2fT  24h %s%.2f%%  BTC 占比 %.1f%%" % (cap, "+" if chg >= 0 else "", chg, dom))
    except Exception:
        add("cap", "总量", "（不可用：%s）" % why("global"), ok=False)

# 3. 流动性：稳定币总量（接口 555KB，只取合计）
if "stable" in want:
    d = load("stablecoins")
    try:
        total = 0.0
        for a in d["peggedAssets"]:
            c = a.get("circulating") or {}
            v = c.get("peggedUSD")
            if isinstance(v, (int, float)):
                total += float(v)
        add("stable", "流动性", "稳定币总量 $%.1fB（越缩越该警惕）" % (total / 1e9))
    except Exception:
        add("stable", "流动性", "（不可用：%s）" % why("stablecoins"), ok=False)

# 4. 杠杆：OKX BTC 永续资金费率
if "funding" in want:
    d = load("okx_funding")
    try:
        cur = d["data"][0]
        rate = float(cur["fundingRate"]) * 100
        ann = rate * 3 * 365
        nxt = cur.get("nextFundingTime")
        when = ""
        if nxt:
            t = datetime.datetime.fromtimestamp(int(nxt) / 1000, datetime.timezone.utc)
            when = "  下次结算 %s UTC" % t.strftime("%H:%M")
        side = "多头付费（偏多）" if rate > 0 else ("空头付费（偏空）" if rate < 0 else "持平")
        add("funding", "杠杆", "BTC 资金费率 %+.4f%%/8h  年化 %+.1f%%  %s%s" % (rate, ann, side, when))
    except Exception:
        add("funding", "杠杆", "（不可用：%s）" % why("okx_funding"), ok=False)

# 5. 链上拥堵
if "fees" in want:
    d = load("mempool")
    try:
        f = int(d["fastestFee"])
        verdict = "不拥堵" if f <= 10 else ("中等" if f <= 40 else "拥堵")
        add("fees", "链上", "BTC 建议费率 %d sat/vB（%s）" % (f, verdict))
    except Exception:
        add("fees", "链上", "（不可用：%s）" % why("mempool"), ok=False)

if as_json:
    out = {"rows": rows, "missing": gaps, "ok": not gaps}
    print(json.dumps(out, ensure_ascii=False))
else:
    ts = datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    print("市场状态（%s）" % ts)

    def width(s):
        return sum(2 if ord(c) > 0x2E80 else 1 for c in s)

    for r in rows:
        pad = " " * max(1, 8 - width(r["label"]))
        print("%s%s%s" % (r["label"], pad, r["value"]))
    if gaps:
        print("")
        print("注意：%d 段拿不到（%s）。缺数据的时候，别把「没信号」当成「没问题」。" % (len(gaps), "、".join(gaps)))

sys.exit(0 if (rows and (not gaps or not strict)) else (6 if not rows else 1))
PY
)

FETCHED=0
FAILED=0

take() {
    local key=$1 url=$2 method=${3:-GET} body=${4:-}
    local code
    code=$(fetch "$key" "$url" "$method" "$body")
    printf '%s' "$code" > "$TMPD/$key.code"
    case "$code" in
        200) FETCHED=$((FETCHED + 1)) ;;
        *)   FAILED=$((FAILED + 1)) ;;
    esac
}

want fng     && take fng "https://api.alternative.me/fng/?limit=2"
want cap     && take global "https://api.coingecko.com/api/v3/global"
want stable  && take stablecoins "https://stablecoins.llama.fi/stablecoins?includePrices=false"
want funding && take okx_funding "https://www.okx.com/api/v5/public/funding-rate?instId=BTC-USDT-SWAP"
want fees    && take mempool "https://mempool.space/api/v1/fees/recommended"

if [ "$FETCHED" -eq 0 ] && [ "$FAILED" -gt 0 ]; then
    say "所有数据源都拿不到（网络或接口不可用）"
    exit 6
fi

python3 -c "$RENDER" "$TMPD" "$WANT" "$JSON" "$STRICT"
