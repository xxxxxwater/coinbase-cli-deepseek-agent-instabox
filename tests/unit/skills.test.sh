#!/usr/bin/env bash
# cb-skills.sh 的行为测试：三个状态（齐全 / 缺失 / CLI 谎报没捆绑）都要能分辨。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
C="$ROOT/scripts/cb-skills.sh"
export NO_COLOR=1

mk() { mkdir -p "$1/$2" && printf '# %s\n' "$2" > "$1/$2/SKILL.md"; }

# 1. 两侧都齐 → verify 退出码 0
D1="$TESTDIR/a"; D2="$TESTDIR/b"
mk "$D1" coinbase; mk "$D1" coinbase-trading
mk "$D2" coinbase; mk "$D2" coinbase-trading
out=$(bash "$C" verify --dir "$D1" 2>&1); rc=$?
assert_exit "$rc" 0 "齐全时退出码 0"
assert_contains "$out" "✓ coinbase-trading" "逐个列出 skill"
assert_contains "$out" "2/2 齐全" "报出齐全的分数"

# 2. 缺一个 → verify 退出码 1，并给出修法
D3="$TESTDIR/c"; mk "$D3" coinbase
out=$(bash "$C" verify --dir "$D3" 2>&1); rc=$?
assert_exit "$rc" 1 "缺 skill 时退出码 1"
assert_contains "$out" "✗ coinbase-trading" "指出缺的是哪个"
assert_contains "$out" "缺 1 个" "报出缺失数量"
assert_contains "$out" "sync" "给出修复命令"

# 3. sync 之后补齐 （桩会把两个 skill 都建出来）
out=$(bash "$C" sync --dir "$D3" 2>&1); rc=$?
assert_exit "$rc" 0 "sync 之后退出码 0"
assert_file "$D3/coinbase-trading/SKILL.md" "sync 真的落盘了缺的那个"

# 4. CLI 谎报"没有捆绑 skills" → 退出码 3，且解释这不是"没装"
export STUB_SKILLS="No bundled skills found."
out=$(bash "$C" verify --dir "$D1" 2>&1); rc=$?
assert_exit "$rc" 3 "CLI 找不到捆绑 skills 时退出码 3"
assert_contains "$out" "不是'没装'" "把谎报和真缺失区分开"
assert_contains "$out" "import.meta.url" "解释根因"
assert_contains "$out" "dist/index.js" "给出绕过方法"

# 5. 参数校验
unset STUB_SKILLS
out=$(bash "$C" --bogus 2>&1); rc=$?
assert_exit "$rc" 2 "未知参数退出码 2"
out=$(bash "$C" --dir 2>&1); rc=$?
assert_exit "$rc" 2 "--dir 缺参数退出码 2"
out=$(bash "$C" --help 2>&1); rc=$?
assert_exit "$rc" 0 "--help 退出码 0"

# 6. 含空格目标始终是一个目录，不允许 sync 在错误目录自检成功
D4="$TESTDIR/agent skills"
mk "$D4" coinbase; mk "$D4" coinbase-trading
out=$(bash "$C" verify --dir "$D4" 2>&1); rc=$?
assert_exit "$rc" 0 "含空格完整路径 verify 成功"

mkdir -p "$TESTDIR/work"
D5="$TESTDIR/new skills"
: > "$STUB_LOG"
out=$(cd "$TESTDIR/work" && bash "$C" sync --dir "$D5" 2>&1); rc=$?
assert_exit "$rc" 0 "含空格完整路径 sync 成功"
assert_file "$D5/coinbase-trading/SKILL.md" "sync 写入完整目标"
adds=$(grep -c '^skills add ' "$STUB_LOG")
assert_eq "$adds" 1 "自定义目标只安装一次"
if [ ! -e "$TESTDIR/new" ] && [ ! -e "$TESTDIR/work/skills" ]; then
  ok "不产生分裂目录"
else
  bad "不应产生分裂目录"
fi

# 7. HOME 含空格时保留默认双目录以及仅已存在一侧的行为
H="$TESTDIR/home space"
out=$(cd "$TESTDIR/work" && HOME="$H" bash "$C" sync 2>&1); rc=$?
assert_exit "$rc" 0 "含空格 HOME 默认同步成功"
assert_file "$H/.claude/skills/coinbase/SKILL.md" "默认 Claude 路径完整"
assert_file "$H/.codex/skills/coinbase/SKILL.md" "默认 Codex 路径完整"
H2="$TESTDIR/single home"
mkdir -p "$H2/.codex"
: > "$STUB_LOG"
out=$(cd "$TESTDIR/work" && HOME="$H2" bash "$C" sync 2>&1); rc=$?
assert_exit "$rc" 0 "仅存在 Codex 时同步成功"
assert_file "$H2/.codex/skills/coinbase/SKILL.md" "保留已存在一侧"
adds=$(grep -c '^skills add ' "$STUB_LOG")
assert_eq "$adds" 1 "仅安装已存在一侧"

finish

