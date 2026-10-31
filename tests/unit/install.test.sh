#!/usr/bin/env bash
# install.sh 的行为测试：装到临时目录，不碰真实 HOME、不装 npm 包。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
I="$ROOT/install.sh"

# 隔离到临时目录，避免污染真实的 ~/.config 与 ~/.local
export HOME="$TESTDIR/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$TESTDIR/xdg"
export CB_DOCTOR_SKIP_NET=1
PREFIX="$TESTDIR/prefix"
BIN="$PREFIX/bin"
CFG="$XDG_CONFIG_HOME/coinbase-agent/config.json"

# ---------- --help ----------
out=$(bash "$I" --help 2>&1); rc=$?
assert_exit "$rc" 0 "--help 退出码 0"
assert_contains "$out" "--skip-cli" "--help 列出参数"
assert_contains "$out" "退出码" "--help 说明退出码"

# ---------- 未知参数 ----------
out=$(bash "$I" --nope 2>&1); rc=$?
assert_exit "$rc" 2 "未知参数退出码 2"
assert_contains "$out" "未知参数" "未知参数有提示"

# ---------- key 文件不存在 ----------
out=$(bash "$I" --prefix "$PREFIX" --skip-cli --yes --key-file "$TESTDIR/nope.json" 2>&1); rc=$?
assert_exit "$rc" 1 "key 文件不存在：退出码 1"
assert_contains "$out" "找不到 key 文件" "key 文件不存在：说清原因"

# ---------- 正常安装 ----------
out=$(bash "$I" --prefix "$PREFIX" --skip-cli --yes 2>&1); rc=$?
assert_exit "$rc" 0 "安装：退出码 0"
for s in cb-doctor.sh cb-portfolio.sh cb-trade.sh cb-products.sh cb-activate-key.sh ds-model.sh coinbase-stack-check.sh; do
  assert_file_exec "$BIN/$s" "安装：$s 可执行"
done
assert_file "$BIN/lib/config.sh" "安装：共享库 lib/config.sh 一起装了"
assert_eq "$(stat -c '%a' "$BIN/lib/config.sh" 2>/dev/null || stat -f '%Lp' "$BIN/lib/config.sh")" "644" "安装：lib 是 644（不是可执行）"
assert_contains "$out" "不在 PATH 里" "安装：提示 BIN_DIR 不在 PATH"
assert_contains "$out" "下一步" "安装：结尾给了下一步指引"

# 装完的脚本能跑（用桩，不需要网络）
out=$(PATH="$BIN:$PATH" CB_CONFIG="$TESTDIR/c.json" STUB_PRODUCT='{"product_id":"BTC-USD","price":"1","product_type":"SPOT"}' bash "$BIN/cb-products.sh" --ticker BTC-USD 2>&1); rc=$?
assert_exit "$rc" 0 "装好的 cb-products.sh 能直接跑"
assert_eq "$out" "1" "装好的 cb-products.sh 找得到 lib/config.sh"

# ---------- 写配置：key-file ----------
KEYF="$TESTDIR/cdp.json"; printf '{"id":"x","privateKey":"y"}\n' > "$KEYF"
out=$(bash "$I" --prefix "$PREFIX" --skip-cli --yes --key-file "$KEYF" --portfolio "11111111-2222-3333-4444-555555555555" 2>&1); rc=$?
assert_exit "$rc" 0 "带 key-file/portfolio 再装一遍：退出码 0"
assert_contains "$out" "已记录 key 文件" "写配置：确认 key 文件"
assert_contains "$out" "已记录组合" "写配置：确认组合"
if [ -f "$CFG" ]; then
  ok "写配置：config.json 生成了"
  k=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["key_file"])' "$CFG" 2>/dev/null)
  p=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["portfolio_id"])' "$CFG" 2>/dev/null)
  assert_eq "$k" "$KEYF" "写配置：key_file 值正确"
  assert_eq "$p" "11111111-2222-3333-4444-555555555555" "写配置：portfolio_id 值正确"
  assert_eq "$(stat -c '%a' "$CFG" 2>/dev/null || stat -f '%Lp' "$CFG")" "600" "写配置：config.json 是 600"
  assert_eq "$(stat -c '%a' "$(dirname "$CFG")" 2>/dev/null || stat -f '%Lp' "$(dirname "$CFG")")" "700" "写配置：配置目录是 700"
else
  bad "写配置：config.json 没生成"
fi

# 再装一次不能把已有配置冲掉（幂等）
out=$(bash "$I" --prefix "$PREFIX" --skip-cli --yes 2>&1)
k=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["key_file"])' "$CFG" 2>/dev/null)
assert_eq "$k" "$KEYF" "幂等：不带参数重装不覆盖已有 key_file"

# ---------- Node 版本守卫 ----------
FAKE="$TESTDIR/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/node" <<'FAKE_NODE'
#!/usr/bin/env bash
case "$1" in
  -p) echo 20 ;;
  -v) echo v20.11.0 ;;
  *)  echo v20.11.0 ;;
esac
FAKE_NODE
chmod +x "$FAKE/node"
out=$(PATH="$FAKE:$PATH" bash "$I" --prefix "$TESTDIR/p2" --skip-cli --yes 2>&1); rc=$?
assert_exit "$rc" 1 "Node 版本太低：退出码 1"
assert_contains "$out" "需要 Node.js" "Node 版本太低：说清要求"

# ---------- --guard：替换真二进制（用临时目录 + 桩 coinbase 测真路径） ----------
GD="$TESTDIR/guardbin"; mkdir -p "$GD"
cat > "$GD/coinbase" <<'STUB'
#!/usr/bin/env bash
echo "real coinbase $*"
STUB
chmod 755 "$GD/coinbase"

# PATH 里必须解析到同一个 coinbase，否则守卫装了也没人走到它
out=$(PATH="$GD:$PATH" CB_GUARD_DIR="$GD" bash "$ROOT/install.sh" --prefix "$TESTDIR/g1" --skip-cli --yes --guard 2>&1); rc=$?
assert_exit "$rc" 0 "--guard：退出码 0（目录可写时不需要 sudo）"
assert_file_exec "$GD/coinbase" "--guard：coinbase 现在可执行"
if grep -q 'CB_GUARD_V1' "$GD/coinbase"; then ok "--guard：装上去的是守卫"; else bad "--guard：装上去的不是守卫"; fi
assert_file_exec "$GD/coinbase-real.js" "--guard：真程序改名成 .js 留着（Node ESM 的硬要求）"
assert_file "$GD/coinbase-mcp-proxy.mjs" "--guard：MCP 代理也装到同一目录"
assert_file_exec "$TESTDIR/home/bin/coinbase-guard" "--guard：自愈副本落在 HOME/bin"

out=$("$GD/coinbase" --version 2>&1); rc=$?
assert_exit "$rc" 0 "--guard：守卫能转发 --version"
assert_contains "$out" "real coinbase" "--guard：转发到的是真程序"

# 幂等：再跑一次不该把守卫又"替换"一遍
out=$(PATH="$GD:$PATH" CB_GUARD_DIR="$GD" bash "$ROOT/install.sh" --prefix "$TESTDIR/g2" --skip-cli --yes --guard 2>&1)
assert_contains "$out" "守卫已经在了" "--guard：重复安装时认出现有守卫"

# coinbase 不在指定目录 → 明确拒绝，不要装一个拦不住的守卫
out=$(CB_GUARD_DIR="$TESTDIR/nowhere" bash "$ROOT/install.sh" --prefix "$TESTDIR/g3" --skip-cli --yes --guard 2>&1); rc=$?
assert_exit "$rc" 1 "--guard：位置不对时退出码 1"
assert_contains "$out" "没找到可执行的 coinbase" "--guard：说清是位置不对"

# PATH 解析到别的 coinbase 时必须拒绝：装了守卫却没人走它，比没装更危险
OTHER="$TESTDIR/otherbin"; mkdir -p "$OTHER"
cp "$GD/coinbase-real.js" "$OTHER/coinbase" 2>/dev/null || true
[[ -f "$OTHER/coinbase" ]] || { printf '#!/bin/sh\n' > "$OTHER/coinbase"; chmod 755 "$OTHER/coinbase"; }
out=$(PATH="$OTHER:$PATH" CB_GUARD_DIR="$GD" bash "$ROOT/install.sh" --prefix "$TESTDIR/g4" --skip-cli --yes --guard 2>&1); rc=$?
assert_exit "$rc" 1 "--guard：PATH 指向别处时拒绝安装"
assert_contains "$out" "不是" "--guard：说清 PATH 里的不是那个文件"

finish
