#!/usr/bin/env bash
# cb-config.sh 的行为测试。全部离线，只操作临时配置文件。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
C="$ROOT/scripts/cb-config.sh"
CFG="$TESTDIR/config.json"
export CB_CONFIG="$CFG"
UUID="3e4df874-98c4-4fe7-8988-0bc3170b0b85"

# ---------- path ----------
out=$(bash "$C" path 2>&1); rc=$?
assert_exit "$rc" 0 "path：退出码 0"
assert_eq "$out" "$CFG" "path：打印的正是 CB_CONFIG"

# ---------- show（还没有配置文件）----------
out=$(bash "$C" show 2>&1); rc=$?
assert_exit "$rc" 0 "show：没有配置文件也退出 0"
assert_contains "$out" "还不存在" "show：说明文件还没创建"
assert_contains "$out" "优先级" "show：提示取值优先级"

# ---------- set ----------
out=$(bash "$C" set portfolio_id "$UUID" 2>&1); rc=$?
assert_exit "$rc" 0 "set：退出码 0"
assert_contains "$out" "已写入" "set：确认写入"
assert_file "$CFG" "set：配置文件创建了"
assert_eq "$(stat -c '%a' "$CFG" 2>/dev/null || stat -f '%Lp' "$CFG")" "600" "set：文件权限 600"

# ---------- get ----------
out=$(bash "$C" get portfolio_id 2>&1); rc=$?
assert_exit "$rc" 0 "get：退出码 0"
assert_eq "$out" "$UUID" "get：取回原值"

# ---------- 环境变量优先 ----------
out=$(COINBASE_PORTFOLIO_ID="from-env" bash "$C" get portfolio_id 2>&1)
assert_eq "$out" "from-env" "get：环境变量优先于文件"
out=$(COINBASE_PORTFOLIO_ID="from-env" bash "$C" show 2>&1)
assert_contains "$out" "env COINBASE_PORTFOLIO_ID" "show：标出值来自环境变量"

# ---------- --json ----------
out=$(bash "$C" --json 2>&1)
assert_eq "$out" "{\"portfolio_id\":\"$UUID\"}" "--json：只有当前生效的键"
assert_eq "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["portfolio_id"])')" "$UUID" "--json：是合法 JSON 且值正确"

# ---------- 坏 UUID 拦住 ----------
out=$(bash "$C" set portfolio_id notauuid 2>&1); rc=$?
assert_exit "$rc" 2 "set 坏 UUID：退出码 2"
assert_contains "$out" "不像 UUID" "set 坏 UUID：说清哪里不对"
assert_eq "$(bash "$C" get portfolio_id)" "$UUID" "set 坏 UUID：原值没被覆盖"

# ---------- 未知键 ----------
out=$(bash "$C" set nope 1 2>&1); rc=$?
assert_exit "$rc" 2 "未知键：退出码 2"
assert_contains "$out" "未知键" "未知键：列出可用键"

# ---------- 缺参数 ----------
out=$(bash "$C" get 2>&1); rc=$?
assert_exit "$rc" 2 "get 缺键名：退出码 2"
out=$(bash "$C" set onlykey 2>&1); rc=$?
assert_exit "$rc" 2 "set 缺值：退出码 2"

# ---------- key_file ----------
out=$(bash "$C" set key_file "$TESTDIR/k.json" 2>&1); rc=$?
assert_exit "$rc" 0 "set key_file：文件不存在也允许先记下来"
assert_contains "$out" "已写入" "set key_file：确认写入"
out=$(bash "$C" show 2>&1)
assert_contains "$out" "key_file" "show：列出 key_file"

# ---------- unset ----------
out=$(bash "$C" unset portfolio_id 2>&1); rc=$?
assert_exit "$rc" 0 "unset：退出码 0"
assert_contains "$out" "已删除" "unset：确认删除"
out=$(bash "$C" get portfolio_id 2>&1); rc=$?
assert_exit "$rc" 3 "unset 后 get：退出码 3"
out=$(bash "$C" unset portfolio_id 2>&1); rc=$?
assert_exit "$rc" 3 "重复 unset：退出码 3（键已经不在了）"
# unset 不该把别的键一起删掉
assert_eq "$(bash "$C" get key_file)" "$TESTDIR/k.json" "unset：其他键还在"

# ---------- 权限告警 ----------
chmod 644 "$CFG"
out=$(bash "$C" show 2>&1)
assert_contains "$out" "建议 chmod 600" "权限太宽时给告警"

# ---------- 帮助 ----------
out=$(bash "$C" --help 2>&1); rc=$?
assert_exit "$rc" 0 "--help：退出码 0"
assert_contains "$out" "cb-config.sh" "--help：打印用法"
out=$(bash "$C" --bogus 2>&1); rc=$?
assert_exit "$rc" 2 "未知参数：退出码 2"

finish
