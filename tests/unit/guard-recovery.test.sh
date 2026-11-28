#!/usr/bin/env bash
# 只执行开机自检的守卫恢复段。把系统路径重定向到夹具，sudo/npm 全部用桩。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
bin="$TESTDIR/global-bin"
copies="$TESTDIR/user/bin"
mkdir -p "$bin" "$copies"
cp "$ROOT/guard/coinbase" "$copies/coinbase-guard"
cp "$ROOT/guard/mcp-proxy.mjs" "$copies/coinbase-mcp-proxy.mjs"
printf '#!/bin/sh\necho real-cli\n' > "$bin/coinbase-real.js"
chmod 755 "$bin/coinbase-real.js"
cp "$copies/coinbase-guard" "$bin/coinbase"

cat > "$STUB_DIR/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-n" ] || exit 1
shift
if [ "$1" = mv ] && [ "${FAIL_BACKUP:-}" = 1 ]; then exit 1; fi
"$@"
STUB
printf '#!/bin/sh\nexit 1\n' > "$STUB_DIR/npm"
chmod +x "$STUB_DIR/sudo" "$STUB_DIR/npm"
awk '/^# ---------- 2.5 /{copy=1} /^# ---------- 3\./{copy=0} copy' \
  "$ROOT/scripts/coinbase-stack-check.sh" | sed "s|/usr/local/bin|$bin|g" > "$TESTDIR/repair.sh"

# HOME_DIR、say 和 check 都由下面加载的实际恢复段使用。
# shellcheck disable=SC2034,SC2329
run_repair() (
  HOME_DIR="$TESTDIR/user"
  say() { :; }
  check() { printf '%s %s\n' "$1" "$2"; }
  . "$TESTDIR/repair.sh"
)

result=$(run_repair)
assert_eq "$result" "0 guard(restored)" "仅缺代理：恢复成功"
assert_file "$bin/coinbase-mcp-proxy.mjs" "仅缺代理：代理已安装"
assert_contains "$(cat "$bin/coinbase-real.js")" "echo real-cli" "仅缺代理：保留真 CLI 备份"
assert_eq "$(run_repair)" "0 guard" "重复自检：状态正常"

rm "$bin/coinbase-mcp-proxy.mjs" "$copies/coinbase-mcp-proxy.mjs"
result=$(run_repair)
assert_eq "$result" "1 guard" "缺少代理恢复副本：报告失败"
assert_contains "$(cat "$bin/coinbase-real.js")" "echo real-cli" "缺少恢复副本：保留备份"

cp "$ROOT/guard/mcp-proxy.mjs" "$copies/coinbase-mcp-proxy.mjs"
printf '#!/bin/sh\necho upgraded-cli\n' > "$bin/coinbase"
chmod 755 "$bin/coinbase"
result=$(FAIL_BACKUP=1 run_repair)
assert_eq "$result" "1 guard" "真 CLI 备份失败：报告失败"
assert_eq "$("$bin/coinbase")" "upgraded-cli" "备份失败：不覆盖真 CLI"
result=$(run_repair)
assert_eq "$result" "0 guard(restored)" "npm 升级覆盖守卫：恢复成功"
assert_contains "$(cat "$bin/coinbase")" "CB_GUARD_V1" "升级后守卫重新到位"
assert_eq "$("$bin/coinbase-real.js")" "upgraded-cli" "升级后的真 CLI 成为可执行备份"

finish
