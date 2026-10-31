#!/usr/bin/env bash
# secret-scan.sh 的行为测试：在临时仓库里造真命中与假命中。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
SC="$ROOT/scripts/secret-scan.sh"
R="$TESTDIR/repo"
mkdir -p "$R"
git -C "$R" init -q
git -C "$R" config user.email t@example.com
git -C "$R" config user.name t

# ---------- 干净的仓库 ----------
printf 'hello\n' > "$R/a.txt"
git -C "$R" add -A && git -C "$R" commit -qm init
out=$(cd "$R" && bash "$SC" 2>&1); rc=$?
assert_exit "$rc" 0 "干净的仓库：退出码 0"
assert_contains "$out" "工作区干净" "干净的仓库：报告工作区干净"
assert_contains "$out" "历史干净" "干净的仓库：报告历史干净"

# ---------- 只有 PEM 头，没有 base64 体：不该报（测试夹具就是这种）----------
printf 'local b="-----BEGIN EC PRIVATE" e="-----END EC PRIVATE"\n' > "$R/fixture.sh"
git -C "$R" add -A && git -C "$R" commit -qm fixture
out=$(cd "$R" && bash "$SC" 2>&1); rc=$?
assert_exit "$rc" 0 "只有 PEM 头：退出码 0（不误报夹具）"

# ---------- 工作区里有真密钥 ----------
{ printf 'api_key = "'; printf 'sk-%s' "abcdefghijklmnopqrstuvwxyz0123"; printf '"\n'; } > "$R/leak.txt"
git -C "$R" add -A && git -C "$R" commit -qm leak
out=$(cd "$R" && bash "$SC" 2>&1); rc=$?
assert_exit "$rc" 1 "工作区泄漏：退出码 1"
assert_contains "$out" "工作区命中" "工作区泄漏：报出命中"

# ---------- 删掉之后历史里仍然能查到（这才是重点）----------
git -C "$R" rm -q leak.txt && git -C "$R" commit -qm "remove leak"
out=$(cd "$R" && bash "$SC" --tree 2>&1); rc=$?
assert_exit "$rc" 0 "--tree：工作区已经干净"
assert_contains "$out" "工作区干净" "--tree：工作区确实干净了"
out=$(cd "$R" && bash "$SC" 2>&1); rc=$?
assert_exit "$rc" 1 "历史扫描：commit 删掉了也照样报"
assert_contains "$out" "历史里命中" "历史扫描：指向历史"
assert_contains "$out" "filter-repo" "历史扫描：给出处理建议"

# ---------- Telegram token 形状 ----------
R2="$TESTDIR/repo2"; mkdir -p "$R2"; git -C "$R2" init -q
git -C "$R2" config user.email t@example.com; git -C "$R2" config user.name t
{ printf 'token='; printf '%s:%s' "1234567890" "AAHfakefakefakefakefakefakefake12345"; printf '\n'; } > "$R2/t.txt"
git -C "$R2" add -A && git -C "$R2" commit -qm t
out=$(cd "$R2" && bash "$SC" 2>&1); rc=$?
assert_exit "$rc" 1 "bot token 形状：退出码 1"

# ---------- --json ----------
out=$(cd "$R2" && bash "$SC" --json 2>&1)
assert_contains "$out" '"tree_hits":1' "--json：报出工作区命中数"

finish
