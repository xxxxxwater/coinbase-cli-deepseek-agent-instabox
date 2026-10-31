#!/usr/bin/env bash
# MCP 代理：只审 tools/call 里会动钱的工具，其余一律原样透传。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
# shellcheck source=/dev/null
. tests/helper.sh
setup

PROXY="$ROOT/guard/mcp-proxy.mjs"
export FAKE_LOG="$TESTDIR/child.log"
: > "$FAKE_LOG"

# 假真程序：收到的每一行都记下来，并给带 id 的行回一个 result
cat > "$TESTDIR/fake-cli.mjs" <<'EOF'
import fs from "node:fs";
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => {
  buf += c;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    fs.appendFileSync(process.env.FAKE_LOG, line + "\n");
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.id !== undefined) {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { ok: true } }) + "\n");
    }
  }
});
EOF

# 假风控。调用形式是 `risk.sh check <产品> <side> <金额> [类型]`，
# 所以脚本视角：$1=check $2=产品 $3=side $4=金额 $5=类型。
# 把金额和类型记到 risk.args，用来断言参数没有错位（错位过一次，账本静默丢记录）。
cat > "$TESTDIR/risk.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${4:-}" "${5:-}" >> "$(dirname "$0")/risk.args"
case "${4:-}" in
  ''|*[!0-9.]*) echo "✗ 风控：金额无法识别，拒绝" >&2; exit 4 ;;
esac
if awk -v n="$4" 'BEGIN{exit !(n>100)}'; then
  echo "✗ 风控：单笔 $4 USD 超过上限 100" >&2
  exit 4
fi
exit 0
EOF
chmod +x "$TESTDIR/risk.sh"
: > "$TESTDIR/risk.args"

# 假行情：现价 100
printf '#!/usr/bin/env bash\necho 100\n' > "$TESTDIR/products.sh"
chmod +x "$TESTDIR/products.sh"

run_proxy() {
  CB_REAL_COINBASE="$TESTDIR/fake-cli.mjs" \
  CB_RISK_BIN="$TESTDIR/risk.sh" \
  CB_PRODUCTS_BIN="$TESTDIR/products.sh" \
  node "$PROXY"
}

input=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"coinbase_balance","arguments":{}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"coinbase_orders_create","arguments":{"product_id":"BTC-USD","side":"BUY","type":"market","quote_size":5}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"coinbase_orders_create","arguments":{"product_id":"BTC-USD","side":"BUY","type":"market","quote_size":500}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"coinbase_orders_create","arguments":{"product_id":"BTC-USD","side":"BUY","type":"market"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"coinbase_orders_create","arguments":{"product_id":"BTC-USD","side":"SELL","type":"market","base_size":0.5}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"coinbase_orders_cancel","arguments":{"order_ids":["x"]}}}
not json at all
EOF
)
out=$(printf '%s\n' "$input" | run_proxy)
child=$(cat "$FAKE_LOG")

# ---- 透传 ----
assert_contains "$child" '"id":1' "tools/list 透传"
assert_contains "$out" '"id":1' "真 server 的响应被接回给客户端"
assert_contains "$child" '"id":2' "只读工具 coinbase_balance 透传"
assert_contains "$out" '"ok":true' "响应内容原样透传"
assert_contains "$child" "not json at all" "解析不了的行原样透传"

# ---- 闸门 ----
assert_contains "$child" '"id":3' "限额内的下单放行"
assert_not_contains "$child" '"id":4' "超限的下单没被转发给真程序"
assert_contains "$out" '"id":4' "超限时给客户端回了带同一个 id 的响应"
assert_contains "$out" "超过上限 100" "拒绝原因说明白"
assert_not_contains "$child" '"id":5' "算不出金额的下单也被拒（不转发）"
assert_contains "$out" "算不出金额" "算不出金额时说清原因"
assert_contains "$child" '"id":6' "市价卖出：查现价后 50 USD 在限额内，放行"
assert_contains "$child" '"id":7' "撤单不涉及金额，kill switch 之外不拦"

# ---- 参数顺序 ----
assert_contains "$(cat "$TESTDIR/risk.args")" "5 market" "代理传参顺序正确（金额第4、类型第5）"

# ---- 风控库拒绝时回 JSON-RPC error ----
out2=$(printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"coinbase_transfer","arguments":{"amount":5000}}}' | run_proxy)
assert_contains "$out2" '"id":9' "转账超限：回了响应"
assert_contains "$out2" '"error"' "转账超限：是 error 而不是 result"

# ---- 风控库缺失时 fail closed ----
out3=$(printf '%s\n' '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"coinbase_orders_create","arguments":{"product_id":"BTC-USD","side":"BUY","type":"market","quote_size":5}}}' \
  | CB_REAL_COINBASE="$TESTDIR/fake-cli.mjs" CB_RISK_BIN="$TESTDIR/nonexistent.sh" CB_PRODUCTS_BIN="$TESTDIR/products.sh" node "$PROXY")
assert_contains "$out3" '"error"' "风控库不存在：拒绝而不是放行（fail closed）"

finish
