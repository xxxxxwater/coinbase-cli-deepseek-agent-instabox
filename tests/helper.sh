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
assert_file() { # assert_file <路径> <描述>
  if [ -f "$1" ]; then ok "$2"; else bad "$2（文件不存在）"; fi
}
assert_file_exec() { # assert_file_exec <路径> <描述>
  if [ -x "$1" ]; then ok "$2"; else bad "$2（不存在或没有执行位）"; fi
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
  products)
    case "$2" in
      get)
        # 服务端对不存在的交易对给的是 HTTP 400 + invalid_argument，不是 404
        case " ${STUB_PRODUCT_MISSING:-} " in
          *" $3 "*) echo '{"errorType":"invalid_argument","errorMessage":"the requested product or currency is not supported for trading on this domain"}'
                    echo 'error: the requested product or currency is not supported for trading on this domain (HTTP 400)' >&2
                    exit 1 ;;
        esac
        if [ -n "${STUB_PRODUCT:-}" ]; then printf '%s\n' "$STUB_PRODUCT"; exit 0; fi
        case "$3" in
          AAPL-USD|TSLA-USD) echo '{"product_id":"'"$3"'","product_type":"EQUITY"}' ;;
          *) echo '{"product_id":"'"$3"'","product_type":"SPOT"}' ;;
        esac ;;
      list)
        if [ -n "${STUB_PRODUCTS:-}" ]; then printf '%s\n' "$STUB_PRODUCTS"
        else echo '{"products":[],"num_products":0}'; fi ;;
      *) echo '{}' ;;
    esac ;;
  balance)
    uuid=${2#portfolio_id==}
    case " ${STUB_DENY:-} " in *" $uuid "*) printf '%s\n' "$DENIED" ;; *) printf '%s\n' "$TODAY" ;; esac ;;
  x402)
    case "${2:-}" in
      resources)
        if [ -n "${STUB_X402:-}" ]; then printf '%s\n' "$STUB_X402"
        else printf '%s\n' '{"resources":[]}'; fi ;;
      fetch) printf '%s\n' "${STUB_X402_FETCH:-{\"ok\":true\}}"; exit "${STUB_X402_FETCH_RC:-0}" ;;
      *) echo '{}' ;;
    esac ;;
  convert)
    # Convert 只允许 default portfolio —— 真机对非默认组合固定返回这个 403
    if [ "${STUB_CONVERT_OK:-0}" = "1" ]; then printf '%s\n' "${STUB_CONVERT:-{\"quote_id\":\"q1\"}}"
    else printf '%s\n' '{"errorType":"permission_denied","errorMessage":"Convert can only be performed on default portfolio"}'
         echo 'error: Convert can only be performed on default portfolio (HTTP 403)' >&2; exit 1; fi ;;
  derivatives)
    printf '%s\n' '{"errorType":"invalid_argument","errorMessage":"invalid request"}'; exit 1 ;;
  orders)
    case "${2:-}" in
      preview)
        # 股票没有独立预览路径 —— 真机固定返回这句
        case "$*" in
          *AAPL-USD*|*TSLA-USD*)
            printf '%s\n' '{"errorType":"invalid_argument","errorMessage":"standalone order preview is not available for equities; orders_create performs an internal brokerage preview and cannot bypass preview failures"}' ;;
          *) printf '%s\n' "$STUB_PREVIEW" ;;
        esac ;;
      list)
        if [ -n "${STUB_ORDERS:-}" ]; then printf '%s\n' "$STUB_ORDERS"
        else printf '%s\n' '{"orders":[],"has_next":false,"cursor":""}'; fi ;;
      *) printf '%s\n' "$STUB_CREATE" ;;
    esac ;;
  *) echo '{}' ;;
esac
STUB
  chmod +x "$STUB_DIR/coinbase"
  export PATH="$STUB_DIR:$PATH"
  export STUB_LOG STUB_DIR
  export NO_COLOR=1
  export CB_CONFIG="$TESTDIR/config.json"
  unset COINBASE_PORTFOLIO_ID COINBASE_KEY_FILE 2>/dev/null || true
  # ROOT 给各测试文件拼路径用 —— shellcheck 单文件看会以为没用，所以 export
  export ROOT
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
