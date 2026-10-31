#!/usr/bin/env bash
# config.sh 的行为：优先级、默认值、报错、NODE_OPTIONS 补齐
. "$(dirname "$0")/../helper.sh"
setup
. "$ROOT/scripts/lib/config.sh"

echo "配置文件优先于默认值"
printf '{"portfolio_id":"11111111-1111-1111-1111-111111111111","key_file":"/tmp/k.json"}\n' > "$CB_CONFIG"
assert_eq "$(cb_portfolio_id)" "11111111-1111-1111-1111-111111111111" "cb_portfolio_id 读配置"
assert_eq "$(cb_key_file)" "/tmp/k.json" "cb_key_file 读配置"

echo "环境变量覆盖配置文件"
assert_eq "$(COINBASE_PORTFOLIO_ID=env-wins cb_portfolio_id)" "env-wins" "COINBASE_PORTFOLIO_ID 优先"
assert_eq "$(COINBASE_KEY_FILE=/tmp/other.json cb_key_file)" "/tmp/other.json" "COINBASE_KEY_FILE 优先"

echo "缺失时用默认值，不报错"
assert_eq "$(cb_get NOT_SET_ANYWHERE nothing fallback)" "fallback" "cb_get 默认值"

echo "组合缺失时报错并给出三种补法"
out=$(CB_CONFIG=/tmp/does-not-exist-$$.json cb_portfolio_id 2>&1); rc=$?
assert_exit "$rc" "3" "缺组合退出码 3"
assert_contains "$out" "COINBASE_PORTFOLIO_ID" "提示里给出环境变量写法"
assert_contains "$out" "cb-portfolio.sh --save" "提示里给出自动探测命令"

echo "占位符也算缺失"
printf '{"portfolio_id":"YOUR_PORTFOLIO_UUID"}\n' > "$CB_CONFIG"
out=$(cb_portfolio_id 2>&1); rc=$?
assert_exit "$rc" "3" "占位符被判为缺失"

echo "NODE_OPTIONS 补齐是幂等的"
unset NODE_OPTIONS
cb_ensure_node_options 2>/dev/null
assert_eq "$NODE_OPTIONS" "--dns-result-order=ipv4first" "首次补上"
cb_ensure_node_options 2>/dev/null
assert_eq "$NODE_OPTIONS" "--dns-result-order=ipv4first" "重复调用不重复追加"
NODE_OPTIONS="--max-old-space-size=512"
cb_ensure_node_options 2>/dev/null
assert_contains "$NODE_OPTIONS" "--max-old-space-size=512" "保留已有选项"
assert_contains "$NODE_OPTIONS" "--dns-result-order=ipv4first" "并追加 IPv4 选项"

echo "JSON 助手"
assert_eq "$(printf '{"a":"b"}' | cb_json_get a)" "b" "cb_json_get 取字段"
printf 'not json' | cb_json_get a >/dev/null 2>&1
assert_exit "$?" "1" "非 JSON 返回 1"
printf '{"a":1}' | cb_is_json && ok "cb_is_json 认合法 JSON" || bad "cb_is_json 认合法 JSON"
cb_is_json '{"b":[1,2]}' && ok "cb_is_json 接受参数形式" || bad "cb_is_json 接受参数形式"
cb_is_json 'not json' && bad "cb_is_json 拒绝坏 JSON" || ok "cb_is_json 拒绝坏 JSON"

finish
