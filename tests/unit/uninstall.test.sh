#!/usr/bin/env bash
# uninstall.sh 的行为测试：撤脚本、恢复真 coinbase、归档账本、不动私钥。
# 全部在临时目录里跑，不碰真实的 ~/.config、不碰 /usr/local/bin。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
U="$ROOT/uninstall.sh"

# ---------- 准备一个"装好了"的环境 ----------
PFX="$TESTDIR/prefix"
out=$(bash "$ROOT/install.sh" --prefix "$PFX" --skip-cli --yes 2>&1); rc=$?
assert_exit "$rc" 0 "前置：install.sh 能装到临时目录"
assert_file_exec "$PFX/bin/cb-trade.sh" "前置：脚本已装"

# 造一份带账本的配置（放在 uninstall.sh 真正会看的位置：$XDG_CONFIG_HOME/coinbase-agent）
export XDG_CONFIG_HOME="$TESTDIR/xdg"
CONF="$XDG_CONFIG_HOME/coinbase-agent"
mkdir -p "$CONF"
printf '{"portfolio_id":"11111111-1111-1111-1111-111111111111"}\n' > "$CONF/config.json"
printf '{"event":"exec","result":"ok","notional":1,"day":"2026-10-31"}\n' > "$CONF/journal.jsonl"

# ---------- 未知参数 ----------
out=$(bash "$U" --bogus 2>&1); rc=$?
assert_exit "$rc" 2 "未知参数：退出码 2"

# ---------- 不带任何开关：只撤脚本 ----------
out=$(bash "$U" --prefix "$PFX" --yes 2>&1); rc=$?
assert_exit "$rc" 0 "默认撤销：退出码 0"
if [ -f "$PFX/bin/cb-trade.sh" ]; then bad "默认撤销：脚本应该被删掉"; else ok "默认撤销：脚本已删"; fi
if [ -d "$PFX/bin/lib" ]; then bad "默认撤销：lib/ 应该被删掉"; else ok "默认撤销：lib/ 已删"; fi
assert_file "$CONF/config.json" "默认撤销：配置保留（不带 --purge 不删）"
assert_contains "$out" "保留" "默认撤销：明确说了保留什么"

# ---------- 幂等：已经撤过了再跑一次 ----------
out=$(bash "$U" --prefix "$PFX" --yes 2>&1); rc=$?
assert_exit "$rc" 0 "重复撤销：退出码 0"
assert_contains "$out" "没找到可撤的东西" "重复撤销：说清没东西可撤"

# ---------- --guard：把真程序换回来 ----------
GD="$TESTDIR/guardbin"; mkdir -p "$GD"
printf '#!/usr/bin/env bash\necho "real coinbase"\n' > "$GD/coinbase"; chmod 755 "$GD/coinbase"
PATH="$GD:$PATH" CB_GUARD_DIR="$GD" bash "$ROOT/install.sh" --prefix "$TESTDIR/prefix2" --skip-cli --yes --guard >/dev/null 2>&1
if grep -q 'CB_GUARD_V1' "$GD/coinbase"; then ok "前置：守卫已就位"; else bad "前置：守卫没装上"; fi

out=$(CB_GUARD_DIR="$GD" bash "$U" --prefix "$TESTDIR/prefix2" --guard --yes 2>&1); rc=$?
assert_exit "$rc" 0 "--guard：退出码 0"
if grep -q 'CB_GUARD_V1' "$GD/coinbase"; then bad "--guard：coinbase 应该换回真程序"; else ok "--guard：守卫已撤"; fi
out=$("$GD/coinbase" 2>&1)
assert_contains "$out" "real coinbase" "--guard：换回来的是真程序（能跑）"
if [ -f "$GD/coinbase-mcp-proxy.mjs" ]; then bad "--guard：MCP 代理应该被删"; else ok "--guard：MCP 代理已删"; fi
if [ -f "$TESTDIR/home/bin/coinbase-guard" ]; then bad "--guard：自愈副本应该被删"; else ok "--guard：自愈副本已删"; fi

# ---------- --purge：归档账本、删配置 ----------
out=$(bash "$U" --prefix "$PFX" --purge --yes 2>&1); rc=$?
assert_exit "$rc" 0 "--purge：退出码 0"
if [ -f "$CONF/config.json" ]; then bad "--purge：配置应该被删"; else ok "--purge：配置已删"; fi
n_arch=$(find "$CONF" -name 'journal.jsonl.*.archived' | wc -l | tr -d ' ')
assert_eq "$n_arch" "1" "--purge：账本归档而不是直接删（审计不丢）"
assert_contains "$out" "私钥" "--purge：明确说了不碰私钥文件"

finish
