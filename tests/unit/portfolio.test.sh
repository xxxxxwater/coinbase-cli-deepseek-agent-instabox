#!/usr/bin/env bash
# cb-portfolio.sh：探测、--save 选唯一、多可用时报错、--show
. "$(dirname "$0")/../helper.sh"
setup
PORT="$ROOT/scripts/cb-portfolio.sh"
A="aaaaaaaa-1111-1111-1111-111111111111"
B="bbbbbbbb-2222-2222-2222-222222222222"
C="cccccccc-3333-3333-3333-333333333333"
export STUB_PORTFOLIOS='{"portfolios":[
 {"uuid":"'$A'","name":"Default","type":"DEFAULT"},
 {"uuid":"'$B'","name":"Agent","type":"CONSUMER"},
 {"uuid":"'$C'","name":"HFT","type":"CONSUMER"}]}'

echo "只有一个可访问时正常列出"
export STUB_DENY="$A $C"
out=$(bash "$PORT" 2>&1); rc=$?
assert_exit "$rc" "0" "至少一个可用时退出码 0"
assert_contains "$out" "可用组合: 1 / 3" "统计正确"
assert_contains "$out" "Agent" "列出可用的那个"

echo "--json 结构"
out=$(bash "$PORT" --json 2>/dev/null)
assert_eq "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["usable_count"])')" "1" "usable_count=1"

echo "--save 挑选唯一可用的并写 600"
bash "$PORT" --save >/dev/null 2>&1
assert_exit "$?" "0" "--save 成功"
assert_eq "$(python3 -c "import json;print(json.load(open('$CB_CONFIG'))['portfolio_id'])")" "$B" "写入正确 UUID"
mode=$(stat -c %a "$CB_CONFIG" 2>/dev/null || stat -f %Lp "$CB_CONFIG")
assert_eq "$mode" "600" "配置文件权限 600"

echo "全部不可访问时退出 2"
export STUB_DENY="$A $B $C"
out=$(bash "$PORT" --save 2>&1); rc=$?
assert_exit "$rc" "2" "无可用组合退出码 2"
assert_contains "$out" "没有任何组合可访问" "说明原因"

echo "多个可用但没指定时拒绝瞎猜"
export STUB_DENY=""
out=$(bash "$PORT" --save 2>&1); rc=$?
assert_exit "$rc" "2" "多可用退出码 2"
assert_contains "$out" "多个组合可访问" "提示用 --uuid 指定"
out=$(bash "$PORT" --save --uuid "$C" 2>&1); rc=$?
assert_exit "$rc" "0" "指定 --uuid 后成功"
assert_eq "$(python3 -c "import json;print(json.load(open('$CB_CONFIG'))['portfolio_id'])")" "$C" "写入指定 UUID"

echo "--show 打印配置路径"
out=$(bash "$PORT" --show 2>&1)
assert_contains "$out" "$CB_CONFIG" "显示配置路径"
assert_contains "$out" "$C" "显示当前组合"

echo "列组合就 401 时给明确指引"
export STUB_PORTFOLIOS=''
out=$(COINBASE_PORTFOLIO_ID= bash "$PORT" 2>&1)
printf '{"x":1}' > "$CB_CONFIG"
export STUB_PORTFOLIOS='{"error":"unauthorized"}'
out=$(bash "$PORT" 2>&1); rc=$?
assert_exit "$rc" "3" "401 退出码 3"

finish
