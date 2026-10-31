#!/usr/bin/env bash
# cb-trade.sh — Coinbase 下单助手：产品识别 → 余额检查 → 预览/内部预览 → 执行
#
# 安全默认：不加 --commit 绝不下单。
# 现货/期货：用 `orders preview`（服务端独立预览，不下单，返回手续费/成交估算）。
# 股票：Coinbase 不提供独立预览，只有 `orders create` 内部的 brokerage preview。
#       因此股票在未加 --commit 时脚本只做检查并打印将要执行的命令，不会触发下单。
#
# 用法:
#   cb-trade.sh <产品> <BUY|SELL> <金额> [--type market|limit] [--limit <价>]
#               [--session NORMAL|MULTI_SESSION] [--portfolio <uuid>]
#               [--commit] [--yes] [--paper]
#
# 金额含义: market BUY = 花多少计价币(quote_size)；SELL 或 limit = 数量(base_size)
#
# 每一笔都会先过 cb-risk.sh 的闸门（限额/白名单/kill switch），再过服务端预览。
# --paper: 只记账不下单（模拟盘）。与 --commit 互斥，便于 agent 反复演练。

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"
# shellcheck source=lib/risk.sh
. "$HERE/lib/risk.sh"

PRODUCT=""; SIDE=""; AMOUNT=""
OTYPE="market"; LIMIT=""; SESSION="NORMAL"; COMMIT=0; ASSUME_YES=0; PFX=""; PAPER=0

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --type)      OTYPE=${2:?}; shift 2 ;;
    --limit)     LIMIT=${2:?}; shift 2 ;;
    --session)   SESSION=${2:?}; shift 2 ;;
    --portfolio) PFX=${2:?}; shift 2 ;;
    --commit)    COMMIT=1; shift ;;
    --paper)     PAPER=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          cb_die "未知选项 $1" ;;
    *)
      if   [ -z "$PRODUCT" ]; then PRODUCT=$1
      elif [ -z "$SIDE" ];    then SIDE=$1
      elif [ -z "$AMOUNT" ];  then AMOUNT=$1
      else cb_die "多余参数: $1"; fi
      shift ;;
  esac
done

if [ -z "$PRODUCT" ] || [ -z "$SIDE" ] || [ -z "$AMOUNT" ]; then
  usage
  exit 2
fi

SIDE=$(printf '%s' "$SIDE" | tr '[:lower:]' '[:upper:]')
case "$SIDE" in BUY|SELL) ;; *) cb_die "side 必须是 BUY 或 SELL（收到 ${SIDE}）" ;; esac
case "$OTYPE" in market|limit) ;; *) cb_die "type 只支持 market 或 limit（收到 ${OTYPE}）" ;; esac
[ "$OTYPE" = limit ] && [ -z "$LIMIT" ] && cb_die "limit 单必须给 --limit"

# 金额与价格必须是真的数字：这里直接进订单参数，写错就是真金白银。
cb_is_amount() { printf '%s' "$1" | grep -Eq '^[0-9]+([.][0-9]+)?$'; }
cb_is_amount "$AMOUNT" || cb_die "金额必须是正数（收到 '$AMOUNT'）"
cb_is_amount "$LIMIT"  || [ -z "$LIMIT" ] || cb_die "限价必须是正数（收到 '$LIMIT'）"

cb_need coinbase "安装：sudo npm i -g @coinbase/coinbase-cli"
cb_ensure_node_options

# 组合：命令行 > 环境变量 > 配置文件 > 报错（并给出三种补法）
if [ -z "$PFX" ]; then
  PFX=$(cb_portfolio_id) || exit $?
fi

# ---------- 1. 产品类型 ----------
PROD_JSON=$(coinbase products get "$PRODUCT" 2>&1)
PTYPE=$(printf '%s' "$PROD_JSON" | cb_json_get product_type)
[ -n "$PTYPE" ] || cb_die "查询不到产品 ${PRODUCT}：$(printf '%s' "$PROD_JSON" | head -c 200)"

# ---------- 1.5 名义金额 ----------
# 名义金额 = 这笔单子大概动用多少钱。目的只是给限额用，不需要精确到分。
PRICE=$(printf '%s' "$PROD_JSON" | cb_json_get price)
NOTIONAL=$(python3 - "$AMOUNT" "$OTYPE" "$LIMIT" "$SIDE" "${PRICE:-0}" <<'PYN'
import sys
amount, otype, limit, side, price = sys.argv[1:6]
try:
    a = float(amount); p = float(price or 0); lim = float(limit or 0)
except Exception:
    print("0"); raise SystemExit
if otype == "limit":
    n = a * (lim or p)
elif side.upper() == "SELL":
    n = a * p
else:
    n = a          # market BUY 的 quote_size 本身就是计价币金额
print("%.8f" % n)
PYN
)

echo "产品   : ${PRODUCT}  (${PTYPE})"
echo "方向   : ${SIDE}   类型: ${OTYPE}$([ "$OTYPE" = limit ] && echo " @ ${LIMIT}")"
echo "组合   : ${PFX}"
echo "名义额 : ${NOTIONAL} USD（风控按这个数算限额）"

# ---------- 1.9 风控闸门 ----------
# 闸门放在余额查询和预览之前：被拦下的单子连读都不必读，
# 也免得 agent 反复"试一下"把日志写满噪音。
# cb_risk_check 被拒时自己会记一条 block，这里不要再记一遍（否则一笔被拒算两次）
if ! cb_risk_check "$PRODUCT" "$SIDE" "$OTYPE" "$NOTIONAL"; then
  exit 4
fi

# ---------- 2. 余额 ----------
BAL_JSON=$(coinbase balance portfolio_id=="$PFX" show_zero==true 2>&1)
printf '%s' "$BAL_JSON" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception:
    print("余额   : 读取失败（返回的不是 JSON）"); raise SystemExit
if "errorMessage" in d:
    print("余额   : 读取失败 -> %s" % d["errorMessage"][:90]); raise SystemExit
have={}
for a in d.get("accounts",[]):
    try: v=float(a["available_balance"]["value"])
    except Exception: continue
    if v: have[a.get("currency","?")]=v
if have: print("余额   : " + "  ".join("%s=%g" % (k,v) for k,v in sorted(have.items())))
else:    print("余额   : 全为 0（USD/USDC 都没有可用资金）")
' 2>/dev/null || echo "余额   : 解析失败"

# ---------- 3. 组装订单参数 ----------
ORDER_ARGS=(product_id="$PRODUCT" side="$SIDE" type="$OTYPE" portfolio_id="$PFX")
if [ "$OTYPE" = limit ]; then
  ORDER_ARGS+=(limit_price="$LIMIT" base_size="$AMOUNT")
elif [ "$SIDE" = SELL ]; then
  ORDER_ARGS+=(base_size="$AMOUNT")
else
  ORDER_ARGS+=(quote_size="$AMOUNT")
fi
[ "$PTYPE" = EQUITY ] && ORDER_ARGS+=(equity_trading_session="$SESSION")

cb_hr
case "$PTYPE" in
  SPOT|FUTURE*)
    echo "[预览] orders preview（服务端独立预览，不产生订单）"
    if coinbase orders preview "${ORDER_ARGS[@]}"; then
      cb_hr
    else
      echo "（预览未通过，见上方原因）" >&2
      cb_hr
    fi
    ;;
  EQUITY)
    echo "[股票] Coinbase 不提供独立预览。"
    echo "       唯一可用的估价路径是 orders create 内部的 brokerage preview，"
    echo "       它只在 create 时运行，无法单独调用。因此："
    echo "       - 未加 --commit：本脚本只检查并给出命令，不下单。"
    echo "       - 加 --commit：直接调用 create，服务端会先跑内部预览；预览不通过会原样返回原因。"
    echo
    echo "       股票只在 Agents API 上存在（Advanced Trade 面 404 not supported）。"
    echo "       若 create 返回 403 \"User does not have access to portfolio\"，"
    echo "       说明该组合没有股票交易能力（capabilities 为空），需在 Coinbase"
    echo "       账户侧开通并绑定组合；API key 自己无法获得该能力。"
    echo
    echo "       注意美股交易时段：当前美东时间 $(TZ=America/New_York date '+%Y-%m-%d %H:%M:%S %Z %A')"
    echo "       会话参数 equity_trading_session=${SESSION}（默认 NORMAL=只做常规时段）"
    cb_hr
    ;;
  *)
    cb_die "未知 product_type: ${PTYPE}" 3
    ;;
esac

# ---------- 4. 执行 ----------
if [ "$PAPER" -eq 1 ]; then
  # 模拟盘：记录意图与参数，不调用 create。给 agent 反复演练用。
  cb_risk_journal_add paper "$PRODUCT" "$SIDE" "$OTYPE" "$NOTIONAL" ok "paper"
  echo "[paper] 模拟盘：没有下单。真实执行用 --commit"
  printf '  coinbase orders create'
  printf ' %q' "${ORDER_ARGS[@]}"
  printf '\n'
  exit 0
fi

if [ "$COMMIT" -eq 1 ]; then
  # 真下单前在 tty 上再确认一次；脚本化调用请显式 --yes。
  if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    printf '确认提交这笔真实订单？输入 yes 继续：' >&2
    read -r ans || ans=""
    [ "$ans" = "yes" ] || { echo "已取消，未下单。" >&2; exit 130; }
  fi
  # 预览到确认之间可能有人按下 kill switch —— 这正是 kill switch 存在的场景：
  # 不是"以后别再下"，而是"这一笔现在别下"。所以下单前再判一次。
  if ! cb_risk_check "$PRODUCT" "$SIDE" "$OTYPE" "$NOTIONAL"; then
    echo "已在下单前被风控拦下，本笔没有提交。" >&2
    exit 4
  fi
  echo "[执行] coinbase orders create"
  coinbase orders create "${ORDER_ARGS[@]}"
  RC=$?
  if [ "$RC" -eq 0 ]; then
    cb_risk_journal_add exec "$PRODUCT" "$SIDE" "$OTYPE" "$NOTIONAL" ok "create 返回 0"
  else
    # 失败的单子也记，但 result 不是 ok —— 它不占当日限额（没成交也没提交成功）
    cb_risk_journal_add exec "$PRODUCT" "$SIDE" "$OTYPE" "$NOTIONAL" error "create 退出码 ${RC}"
  fi
  cb_hr
  echo "退出码: ${RC}"
  exit $RC
fi

cb_risk_journal_add preview "$PRODUCT" "$SIDE" "$OTYPE" "$NOTIONAL" ok "dry-run"
echo "[dry-run] 未加 --commit，没有下单。真正执行用："
printf '  coinbase orders create'
printf ' %q' "${ORDER_ARGS[@]}"
printf '\n'
exit 0
