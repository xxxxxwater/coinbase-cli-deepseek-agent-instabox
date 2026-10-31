#!/usr/bin/env bash
# cb-market.sh 的行为测试：五段信号、数值换算、方向判断、缺数据不装没事。
# 全程不联网：用 CB_MARKET_FIXTURE_DIR 从夹具目录读 <key>.json。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
M="$ROOT/scripts/cb-market.sh"
export NO_COLOR=1
export XDG_CACHE_HOME="$TESTDIR/cache"

FIX="$TESTDIR/fix"
mkdir -p "$FIX"
write_good() {
  cat > "$FIX/fng.json" <<'J'
{"name":"Fear and Greed Index","data":[{"value":"30","value_classification":"Fear","timestamp":"1793443200"},{"value":"34","value_classification":"Fear","timestamp":"1793356800"}]}
J
  cat > "$FIX/global.json" <<'J'
{"data":{"active_cryptocurrencies":22643,"total_market_cap":{"usd":2410000000000},"market_cap_change_percentage_24h_usd":-1.234,"market_cap_percentage":{"btc":58.31}}}
J
  cat > "$FIX/stablecoins.json" <<'J'
{"peggedAssets":[{"id":"1","circulating":{"peggedUSD":120000000000}},{"id":"2","circulating":{"peggedUSD":62000000000}},{"id":"3","circulating":{}}]}
J
  cat > "$FIX/okx_funding.json" <<'J'
{"code":"0","data":[{"instId":"BTC-USDT-SWAP","fundingRate":"0.0001000000000000","nextFundingTime":"1793481600000"}]}
J
  cat > "$FIX/mempool.json" <<'J'
{"fastestFee":1,"halfHourFee":1,"hourFee":1}
J
}
write_good

echo "== 五段全在 =="
out=$(CB_MARKET_FIXTURE_DIR="$FIX" bash "$M" 2>/dev/null); rc=$?
assert_exit "$rc" 0 "五段正常时退出码 0"
assert_contains "$out" "市场状态" "有标题"
assert_contains "$out" "30（Fear）" "情绪值带分类"
assert_contains "$out" "↓ 昨日 34" "情绪比昨天低要显示方向"
assert_contains "$out" '$2.41T' "总市值换算成 T"
assert_contains "$out" "-1.23%" "24h 涨跌保留两位"
assert_contains "$out" "BTC 占比 58.3%" "BTC 占比"
assert_contains "$out" '稳定币总量 $182.0B' "稳定币合计 120+62=182，缺 circulating 的条目跳过"
assert_contains "$out" "+0.0100%/8h" "资金费率换算成百分比"
assert_contains "$out" "多头付费" "正费率是多方付钱"
assert_contains "$out" "1 sat/vB" "链上费率"
assert_contains "$out" "不拥堵" "1 sat/vB 判不拥堵"
assert_not_contains "$out" "不可用" "全都拿到时不该出现不可用"

echo "== 空恐慌贪婪 =="
cat > "$FIX/fng.json" <<'J'
{"name":"Fear and Greed Index","data":[]}
J
out=$(CB_MARKET_FIXTURE_DIR="$FIX" bash "$M" --only fng 2>/dev/null)
assert_contains "$out" "不可用" "没有数据点要说不可用，不能崩"
write_good

echo "== 负费率与拥堵 =="
cat > "$FIX/okx_funding.json" <<'J'
{"code":"0","data":[{"fundingRate":"-0.00025","nextFundingTime":"1793481600000"}]}
J
cat > "$FIX/mempool.json" <<'J'
{"fastestFee":55}
J
out=$(CB_MARKET_FIXTURE_DIR="$FIX" bash "$M" --only funding,fees 2>/dev/null)
assert_contains "$out" "-0.0250%/8h" "负费率换算正确"
assert_contains "$out" "空头付费" "负费率是空方付钱"
assert_contains "$out" "拥堵" "55 sat/vB 判拥堵"
write_good

echo "== --only =="
out=$(CB_MARKET_FIXTURE_DIR="$FIX" bash "$M" --only fng 2>/dev/null)
assert_contains "$out" "情绪" "只保留情绪段"
assert_not_contains "$out" "链上" "不该出现未请求的段"

echo "== --json =="
out=$(CB_MARKET_FIXTURE_DIR="$FIX" bash "$M" --json 2>/dev/null)
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["ok"] and len(d["rows"])==5 else 1)' 2>/dev/null; then
  ok "--json 是合法 JSON，ok=true，5 行"
else
  bad "--json 结构不对" "$out"
fi

echo "== 缺数据 =="
PART="$TESTDIR/part"; mkdir -p "$PART"; cp "$FIX/fng.json" "$PART/"
out=$(CB_MARKET_FIXTURE_DIR="$PART" bash "$M" 2>/dev/null); rc=$?
assert_exit "$rc" 0 "部分缺失仍退出 0（部分数据也是数据）"
assert_contains "$out" "4 段拿不到" "要说清缺了几段"
assert_contains "$out" "别把「没信号」当成「没问题」" "缺数据要给出警示"
out=$(CB_MARKET_FIXTURE_DIR="$PART" bash "$M" --strict 2>/dev/null); rc=$?
assert_exit "$rc" 1 "--strict 下有缺失退出 1"
out=$(CB_MARKET_FIXTURE_DIR="$PART" bash "$M" --json 2>/dev/null)
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if (not d["ok"]) and len(d["missing"])==4 else 1)' 2>/dev/null; then
  ok "部分缺失时 JSON 标 ok=false 并列出 missing"
else
  bad "部分缺失时 JSON 结构不对" "$out"
fi

echo "== 全部拿不到 =="
EMPTY="$TESTDIR/empty"; mkdir -p "$EMPTY"
out=$(CB_MARKET_FIXTURE_DIR="$EMPTY" bash "$M" 2>&1); rc=$?
assert_exit "$rc" 6 "全拿不到退出 6"
assert_contains "$out" "所有数据源都拿不到" "要说清是全部失败"

echo "== 坏 JSON =="
BAD="$TESTDIR/bad"; mkdir -p "$BAD"; cp "$FIX"/*.json "$BAD/"
printf 'not json at all' > "$BAD/global.json"
out=$(CB_MARKET_FIXTURE_DIR="$BAD" bash "$M" --only cap 2>/dev/null); rc=$?
assert_exit "$rc" 0 "坏 JSON 不拖垮整条命令"
assert_contains "$out" "解析失败" "要说解析失败，而不是假装没数据"
assert_not_contains "$out" "（不可用：HTTP 200）" "别把解析失败直接报成 HTTP 200"

echo "== 参数校验 =="
bash "$M" --only >/dev/null 2>&1; assert_exit $? 2 "--only 缺值退出 2"
bash "$M" --nope >/dev/null 2>&1; assert_exit $? 2 "未知参数退出 2"
bash "$M" --help >/dev/null 2>&1; assert_exit $? 0 "--help 退出 0"
out=$(bash "$M" --help 2>&1)
assert_contains "$out" "--strict" "帮助里说明 --strict"
assert_contains "$out" "地区封锁" "帮助里写明哪些源被封锁，省得后人乱试"

echo "== 缓存 =="
CS="$TESTDIR/cachetest"; mkdir -p "$CS"
CB_MARKET_FIXTURE_DIR="" XDG_CACHE_HOME="$CS" bash -c 'true' 2>/dev/null
mkdir -p "$CS/coinbase-agent/market"
cp "$FIX/mempool.json" "$CS/coinbase-agent/market/mempool.json"
out=$(CB_MARKET_TTL=999999 XDG_CACHE_HOME="$CS" bash "$M" --only fees 2>/dev/null)
assert_contains "$out" "1 sat/vB" "缓存命中时不必联网也能出结果"

finish
