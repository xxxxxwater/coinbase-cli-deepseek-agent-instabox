#!/usr/bin/env bash
# cb-x402.sh — x402 付费数据服务：先看目录，再决定花多少
#
# 为什么要包一层：`coinbase x402 resources` 返回 127 条资源，每条带一段
# 英文描述和 6 位原子单位的价格（10000 = 0.01 USDC）。直接看是一屏 JSON，
# 而真正要决定的是"这条多少钱、值不值"。
#
# 用法:
#   cb-x402.sh                             # 等于 resources
#   cb-x402.sh resources [--search 词]     # 按 URL/描述过滤
#   cb-x402.sh resources --limit 20        # 只看前 20 条（默认 20）
#   cb-x402.sh resources --json            # 原样输出接口 JSON
#   cb-x402.sh fetch <url> [--max-amount 0.05]        # 只打印将要做什么（不花钱）
#   cb-x402.sh fetch <url> --max-amount 0.05 --commit # 真的付并取回
#
# 关于钱：x402 是从 Base USDC 余额里按次扣费，`--max-amount` 是单次上限。
# 默认不付 —— fetch 不加 --commit 时只打印命令。加 --commit 也仍然要过
# cb-risk.sh 的闸门（kill switch / 单笔上限 / 每日上限），因为这也是花钱。
#
# 退出码: 0 成功 / 2 用法错 / 4 被风控拒绝 / 5 返回不是 JSON / 6 接口失败

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"; }

MODE="resources"
[ $# -gt 0 ] && case "$1" in resources|fetch) MODE=$1; shift ;; esac

SEARCH=""
LIMIT=20
AS_JSON=0
URL=""
MAX_AMOUNT=""
COMMIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --search)     SEARCH=${2:?--search 需要值}; shift 2 ;;
    --limit)      LIMIT=${2:?--limit 需要值}; shift 2 ;;
    --json)       AS_JSON=1; shift ;;
    --max-amount) MAX_AMOUNT=${2:?--max-amount 需要值}; shift 2 ;;
    --commit)     COMMIT=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           printf '错误: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
    *)            if [ -z "$URL" ]; then URL=$1; else
                    printf '错误: 多余的参数 %s\n' "$1" >&2; exit 2
                  fi; shift ;;
  esac
done

case "$LIMIT" in ''|*[!0-9]*) printf '错误: --limit 要是正整数\n' >&2; exit 2 ;; esac

cb_need coinbase
cb_ensure_node_options

if [ "$MODE" = "resources" ]; then
  out=$(coinbase x402 resources 2>&1) || cb_die "查询 x402 目录失败：${out}" 6
  if [ "$AS_JSON" -eq 1 ]; then
    printf '%s\n' "$out"
    exit 0
  fi
  RENDER=$(cat <<'PYX'
import json, sys
search, limit = sys.argv[1], int(sys.argv[2])
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print("返回内容不是 JSON，原样贴在下面：")
    print(raw[:2000])
    sys.exit(5)
res = data.get("resources") or []
if search:
    q = search.lower()
    res = [r for r in res if q in (r.get("resource") or "").lower() or q in (r.get("description") or "").lower()]
if not res:
    print("没有匹配的资源%s。" % ("（关键词：%s）" % search if search else ""))
    sys.exit(0)


def price_usdc(r):
    acc = r.get("accepts") or []
    if not acc:
        return "-"
    amt = acc[0].get("amount")
    try:
        return "%.4f USDC" % (int(amt) / 1_000_000)
    except Exception:
        return str(amt)


print("%-16s %s" % ("价格", "资源"))
print("-" * 78)
for r in res[:limit]:
    url = r.get("resource") or "?"
    desc = (r.get("description") or "").strip().replace("\n", " ")
    if len(desc) > 60:
        desc = desc[:59] + "…"
    print("%-16s %s" % (price_usdc(r), url))
    if desc:
        print("%-16s %s" % ("", desc))
if len(res) > limit:
    print()
    print("（还有 %d 条，用 --limit 或 --search 缩小）" % (len(res) - limit))
PYX
)
  printf '%s' "$out" | python3 -c "$RENDER" "$SEARCH" "$LIMIT"
  exit $?
fi

# ---------- fetch ----------
[ -n "$URL" ] || cb_die "fetch 需要一个资源 URL（先跑 cb-x402.sh resources 看目录）"
case "$URL" in
  http://*|https://*) ;;
  *) cb_die "资源 URL 必须带 http(s)://" ;;
esac

# 没给上限就按 0.01 USDC 兜底：这个数是"最小可能花费"，不是授权额度。
EFFECTIVE_MAX=${MAX_AMOUNT:-0.01}
case "$EFFECTIVE_MAX" in
  ''|*[!0-9.]*) cb_die "--max-amount 要是数字（单位 USDC，例如 0.05）" ;;
esac

HOST=$(printf '%s' "$URL" | sed -e 's#^https\{0,1\}://##' -e 's#/.*##')
CMD=(coinbase x402 fetch "resource=${URL}" "max_amount=$(printf '%s' "$EFFECTIVE_MAX" | python3 -c 'import sys; print(int(round(float(sys.stdin.read().strip())*1000000)))')")

if [ "$COMMIT" -eq 0 ]; then
  printf '%s将要执行（还没花钱）%s\n' "$CB_C_DIM" "$CB_C_OFF"
  printf '  资源    %s\n' "$URL"
  printf '  上限    %s USDC\n' "$EFFECTIVE_MAX"
  printf '  命令    %s\n' "${CMD[*]}"
  printf '确认要付就加 --commit；这笔会过风控闸门（kill switch / 单笔上限）。\n'
  exit 0
fi

# 花钱就是花钱：走和下单同一套闸门。
if [ -x "$HERE/cb-risk.sh" ] || [ -f "$HERE/cb-risk.sh" ]; then
  if ! bash "$HERE/cb-risk.sh" check "X402:${HOST}" BUY "$EFFECTIVE_MAX" x402; then
    cb_die "被风控拒绝，未发起支付" 4
  fi
fi
cb_risk_journal_add exec "X402:${HOST}" BUY x402 "$EFFECTIVE_MAX" submitted "x402 fetch" 2>/dev/null || true

out=$("${CMD[@]}" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  cb_risk_journal_add exec "X402:${HOST}" BUY x402 "$EFFECTIVE_MAX" error "退出码 ${rc}" 2>/dev/null || true
  cb_die "x402 支付/取回失败（退出码 ${rc}）：${out}" 6
fi
cb_risk_journal_add exec "X402:${HOST}" BUY x402 "$EFFECTIVE_MAX" ok "x402 fetch" 2>/dev/null || true
printf '%s\n' "$out"
