#!/usr/bin/env bash
# cb-capability.sh 的行为测试：每种产品面的可用/不可用都要能分辨。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
C="$ROOT/scripts/cb-capability.sh"
export COINBASE_PORTFOLIO_ID="11111111-1111-1111-1111-111111111111"
export NO_COLOR=1

# 全绿场景
export STUB_PERM='{"can_view":true,"can_trade":true,"can_transfer":true,"portfolio_uuid":"11111111-1111-1111-1111-111111111111","portfolio_type":"CONSUMER"}'
export STUB_PREVIEW='{"errorType":"invalid_argument","errorMessage":"order rejected: preview insufficient fund"}'
export STUB_X402='{"resources":[{"resource":"https://x/a","description":"a","accepts":[{"amount":"10000"}]}]}'
export STUB_PORTFOLIOS='{"portfolios":[{"uuid":"11111111-1111-1111-1111-111111111111","name":"Agent MPC","type":"CONSUMER"}]}'

out=$(bash "$C" 2>&1); rc=$?
assert_exit "$rc" 0 "默认（非 --strict）退出码 0"
assert_contains "$out" "鉴权 · API key" "列出鉴权项"
assert_contains "$out" "can_view=True" "鉴权项说出三个权限"
assert_contains "$out" "现货 · 下单路径" "列出下单路径"
assert_contains "$out" "余额不足，这是预期" "预览 insufficient fund 被当成'路径通'而不是失败"
assert_contains "$out" "股票 · 产品可见" "列出股票产品可见性"
assert_contains "$out" "无独立预览" "股票走安全探测并说明没有独立预览"
assert_contains "$out" "只支持 default portfolio" "Convert 的 403 被翻译成人话"
assert_contains "$out" "共 1 条资源可发现" "x402 报出资源条数"
assert_contains "$out" "invalid request" "期货的 400 如实转述"

# 鉴权失败场景
export STUB_PERM='{"error":"AUTHENTICATION_FAILED","code":401}'
out=$(bash "$C" 2>&1)
assert_contains "$out" "✗ 鉴权" "鉴权失败时标 ✗"

# JSON 视图
export STUB_PERM='{"can_view":true,"can_trade":true,"can_transfer":true}'
out=$(bash "$C" --json 2>/dev/null)
assert_contains "$out" '"items"' "--json：有 items"
assert_contains "$out" '"portfolio": "11111111-1111-1111-1111-111111111111"' "--json：报出组合"
python3 -c '
import json,sys
d=json.loads(sys.argv[1])
assert isinstance(d["items"], list) and d["items"], "items 不能为空"
assert all({"item","status","detail"} <= set(r) for r in d["items"]), "每行三字段"
print("JSON_OK")
' "$out" >/dev/null 2>&1   # 这里只关心成败，不关心输出
# shellcheck disable=SC2181
if [ $? -eq 0 ]; then ok "--json：结构完整"; else bad "--json：结构完整"; fi

# strict：只要有 ✗ 就退出码 1（期货与 Convert 在这套桩下必然 ✗）
out=$(bash "$C" --strict 2>&1); rc=$?
assert_exit "$rc" 1 "--strict：有不可用项时退出码 1"

# 参数校验
out=$(bash "$C" --bogus 2>&1); rc=$?
assert_exit "$rc" 2 "未知参数：退出码 2"
out=$(bash "$C" --help 2>&1); rc=$?
assert_exit "$rc" 0 "--help：退出码 0"
assert_contains "$out" "只做只读探测" "--help：说明无副作用"

finish
