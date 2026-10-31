#!/usr/bin/env bash
# helper.sh — 测试断言与桩工具。被 tests/unit/*.test.sh source。

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "期望 [$2]，实际 [$1]"; fi
}
assert_contains() {
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" "输出里没有 [$2]：$(printf '%.160s' "$1")" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) bad "$3" "不该出现 [$2]：$(printf '%.160s' "$1")" ;; *) ok "$3" ;; esac
}
assert_exit() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "期望退出码 $2，实际 $1"; fi
}

# 每个测试文件开头调用：建临时目录 + 装 coinbase 桩
setup() {
  TESTDIR=$(mktemp -d 2>/dev/null || mktemp -d -t cbtest)
  STUB_DIR="$TESTDIR/bin"; mkdir -p "$STUB_DIR"
  STUB_LOG="$TESTDIR/calls.log"; : > "$STUB_LOG"
  cat > "$STUB_DIR/coinbase" <<'STUB'
#!/usr/bin/env bash
# 测试桩。注意：不要用 ${VAR:-{...}} 这种写法 —— bash 在参数展开里
# 数花括号，默认值里的 } 会被当成展开的结尾，多吐一个 } 出来。
printf '%s\n' "$*" >> "${STUB_LOG:-/dev/null}"
[ -n "${STUB_PORTFOLIOS:-}" ] || STUB_PORTFOLIOS='{"portfolios":[]}'
[ -n "${STUB_PERM:-}" ]       || STUB_PERM='{"can_view":true,"can_trade":true,"can_transfer":true,"portfolio_type":"CONSUMER"}'
[ -n "${STUB_PREVIEW:-}" ]    || STUB_PREVIEW='{"ok":true}'
[ -n "${STUB_CREATE:-}" ]     || STUB_CREATE='{"success":true,"order_id":"stub-1"}'
[ -n "${STUB_ENV_OUT:-}" ]    || STUB_ENV_OUT='* live  Key: abc…xyz'
TODAY='{"accounts":[{"currency":"USD","available_balance":{"value":"0"}}],"ready":true}'
DENIED='{"errorType":"permission_denied","errorMessage":"User does not have access to portfolio"}'
case "$1" in
  --version)  echo "coinbase ${STUB_VERSION:-0.0.11}" ;;
  env)        printf '%s\n' "$STUB_ENV_OUT" ;;
  api-key)    printf '%s\n' "$STUB_PERM" ;;
  portfolios) printf '%s\n' "$STUB_PORTFOLIOS" ;;
  products)   case "$3" in
                AAPL-USD|TSLA-USD) echo '{"product_id":"'"$3"'","product_type":"EQUITY"}' ;;
                *) echo '{"product_id":"'"$3"'","product_type":"SPOT"}' ;;
              esac ;;
  balance)
    uuid=${2#portfolio_id==}
    case " ${STUB_DENY:-} " in *" $uuid "*) printf '%s\n' "$DENIED" ;; *) printf '%s\n' "$TODAY" ;; esac ;;
  orders)
    if [ "$2" = preview ]; then printf '%s\n' "$STUB_PREVIEW"; else printf '%s\n' "$STUB_CREATE"; fi ;;
  *) echo '{}' ;;
esac
STUB
  chmod +x "$STUB_DIR/coinbase"
  export PATH="$STUB_DIR:$PATH"
  export STUB_LOG STUB_DIR
  export NO_COLOR=1
  export CB_CONFIG="$TESTDIR/config.json"
  unset COINBASE_PORTFOLIO_ID COINBASE_KEY_FILE 2>/dev/null || true
  REPO="$TESTDIR/repo"
  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
}

teardown() {
  [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
}

finish() {
  teardown
  printf '  -- %d 通过, %d 失败\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# 调 CLI 日志里有没有某个子命令
called() { grep -q -- "$1" "$STUB_LOG" 2>/dev/null; }
