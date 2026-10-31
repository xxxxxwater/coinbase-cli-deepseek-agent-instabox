#!/usr/bin/env bash
# cb-orders.sh — 看订单：列表、成交、空态
#
# 为什么要单独一个命令：`coinbase orders list` 的参数是 `==` 语法、分页要自己跟
# cursor、空结果和"出错"都是空数组之外的东西，agent 记不住这些。
#
# 字段名不是猜的 —— `coinbase orders list --help` 的 Response 段就是这份契约：
#   order_id product_id side status order_configuration reduce_only
#   trigger_reference triggered_order_id attached_order_id
#   attached_order_configuration created_time last_fill_time
#   completion_percentage filled_size average_filled_price total_fees
#   total_value_after_fees number_of_fills
#
# 用法:
#   cb-orders.sh                     # 最近 10 条
#   cb-orders.sh --open              # 只看还挂着的（能撤/能改的）
#   cb-orders.sh --status FILLED     # PENDING/OPEN/FILLED/CANCELLED/EXPIRED/FAILED/QUEUED…
#   cb-orders.sh --product BTC-USD   # 只看某个产品
#   cb-orders.sh --limit 25 --all    # 每页 25 条并自动翻页
#   cb-orders.sh --json              # 原样输出接口 JSON（给别的程序用）
#
# 退出码: 0 成功 / 2 用法错 / 4 接口失败 / 5 返回内容不是 JSON

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"; }

LIMIT=10
STATUS=""
PRODUCT=""
AS_JSON=0
ALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --open)     STATUS=OPEN; shift ;;
    --status)   STATUS=${2:?--status 需要值}; shift 2 ;;
    --product)  PRODUCT=${2:?--product 需要值}; shift 2 ;;
    --limit)    LIMIT=${2:?--limit 需要值}; shift 2 ;;
    --all)      ALL=1; shift ;;
    --json)     AS_JSON=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) printf '错误: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
  esac
done

case "$LIMIT" in
  ''|*[!0-9]*) printf '错误: --limit 要是正整数，拿到的是 %s\n' "$LIMIT" >&2; exit 2 ;;
esac

cb_need coinbase
cb_ensure_node_options

# 组合作用域：不传 portfolio_id 时接口会跨"调用者能访问的所有组合"，
# 而我们的 key 往往只对一个组合有权限 —— 所以配置里有就带上。
args=(orders list)
if PFX=$(cb_portfolio_id); then
  args+=("portfolio_id==${PFX}")
fi
[ -n "$STATUS" ] && args+=("status=${STATUS}")
[ -n "$PRODUCT" ] && args+=("product_ids=${PRODUCT}")
args+=("limit=${LIMIT}")
[ "$ALL" -eq 1 ] && args+=(--paginate)

out=$(coinbase "${args[@]}" 2>&1) || cb_die "查询订单失败：${out}"

if [ "$AS_JSON" -eq 1 ]; then
  printf '%s\n' "$out"
  exit 0
fi

# 注意：不能 "python3 - <<'PY'" 同时把数据从 stdin 喂进去 —— heredoc 占了 stdin，
# python 读到的会是空的（这个坑我踩了：数据显示为空，但接口明明返回了 JSON）。
RENDER=$(cat <<'PYORDERS'
import json, sys

status_filter = sys.argv[1] if len(sys.argv) > 1 else ""
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print("返回内容不是 JSON，原样贴在下面：")
    print(raw[:2000])
    sys.exit(5)
if not isinstance(data, dict) or "orders" not in data:
    print("返回里没有 orders 字段，原样贴在下面：")
    print(raw[:2000])
    sys.exit(5)

orders = data.get("orders") or []
if not orders:
    what = "还挂着的订单" if status_filter == "OPEN" else "订单"
    print("没有%s。" % what)
    print("说明：")
    print("  · 这个结果只代表 orders 列表为空，不代表账户里没有任何东西 ——")
    print("    recurring buy（定期买入）的计划不在这张表里。")
    print("  · 如果刚提交过订单，可能还在 PENDING，用 --status PENDING 再看一次。")
    sys.exit(0)


def short(v, n=18):
    s = str(v)
    return s if len(s) <= n else s[: n - 1] + "…"


print("%-19s %-11s %-4s %-9s %12s %14s %10s  %s" % (
    "创建时间", "产品", "方向", "状态", "已成交", "均价", "手续费", "订单号"))
for o in orders:
    created = (o.get("created_time") or "").replace("T", " ")[:19]
    print("%-19s %-11s %-4s %-9s %12s %14s %10s  %s" % (
        created,
        short(o.get("product_id"), 11),
        o.get("side") or "-",
        o.get("status") or "-",
        short(o.get("filled_size") or "0", 12),
        short(o.get("average_filled_price") or "-", 14),
        short(o.get("total_fees") or "-", 10),
        short(o.get("order_id"), 18),
    ))

if data.get("has_next"):
    print()
    print("还有下一页：加 --all 自动翻页，或自己跟 cursor（这个页的 cursor 在上面 JSON 里）。")
PYORDERS
)
printf '%s' "$out" | python3 -c "$RENDER" "${STATUS}"
