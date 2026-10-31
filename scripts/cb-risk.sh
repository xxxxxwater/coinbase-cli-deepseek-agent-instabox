#!/usr/bin/env bash
# cb-risk.sh — 下单风控闸门：限额、白名单、kill switch、审计日志
#
# 为什么要在 CLI 外面再加一层：agent 会自己拼命令。提示词里写"别超过 100 美元"
# 是劝告，模型换个说法就绕过去了；写在这里是闸门，绕不过去。
#
# 用法:
#   cb-risk.sh                     # 等于 show
#   cb-risk.sh show                # 当前限额 + 今日已用 + 最近几条记录
#   cb-risk.sh set <键> <值>       # max_single_trade_usd / max_daily_usd /
#                                  # max_orders_per_hour / allowed_products
#   cb-risk.sh check <产品> <BUY|SELL> <名义金额> [类型]   # 只检查不记录，给脚本预检用
#   cb-risk.sh kill                # 立刻禁止所有下单（不删限额配置）
#   cb-risk.sh resume              # 解除 kill switch
#   cb-risk.sh reset               # 归档当日账本（限额计数从 0 开始，记录不丢）
#   cb-risk.sh journal [N]         # 看最近 N 条（默认 20）
#   cb-risk.sh path                # 打印账本路径
#
# 退出码: 0 通过 / 2 用法错 / 4 被风控拒绝

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"
# shellcheck source=lib/risk.sh
. "$HERE/lib/risk.sh" 2>/dev/null || . "$HERE/../scripts/lib/risk.sh"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"; }

MODE="show"; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    show|set|check|kill|resume|reset|journal|path|report) MODE=$1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) case "$1" in
          --json) ARGS+=("$1"); shift ;;
          --days) ARGS+=("$1" "${2:-}"); shift 2 ;;
          *) printf '错误: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
        esac ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

case "$MODE" in
  path) cb_risk_journal; printf '\n' ;;

  set)
    [ ${#ARGS[@]} -ge 2 ] || { printf '错误: set 需要 <键> <值>\n' >&2; exit 2; }
    k=${ARGS[0]}; v=${ARGS[1]}
    case "$k" in
      max_single_trade_usd|max_daily_usd|max_orders_per_hour)
        printf '%s' "$v" | grep -Eq '^[0-9]+([.][0-9]+)?$' || {
          printf '错误: %s 要是非负数字（收到 %s）\n' "$k" "$v" >&2; exit 2; } ;;
      allowed_products) ;;
      *) printf '错误: 未知键 %s\n' "$k" >&2; exit 2 ;;
    esac
    cb_cfg_set "$k" "$v" || { printf '错误: 写配置失败\n' >&2; exit 3; }
    cb_info "已设置 $k = $v"
    ;;

  kill)
    : > "$(cb_risk_killfile)"
    cb_ok "已开启 kill switch：所有下单被禁止（cb-risk.sh resume 解除）"
    ;;

  resume)
    rm -f "$(cb_risk_killfile)"
    cb_cfg_set kill_switch false >/dev/null 2>&1 || true
    cb_ok "kill switch 已解除"
    ;;

  reset)
    j=$(cb_risk_journal)
    if [ -f "$j" ] && [ -s "$j" ]; then
      mv "$j" "${j}.$(date +%Y%m%d-%H%M%S).archived"
      cb_ok "当日账本已归档，限额计数从 0 开始（记录没删，文件名带时间戳）"
    else
      cb_info "账本还是空的，不需要清零"
    fi
    ;;

  check)
    [ ${#ARGS[@]} -ge 3 ] || { printf '错误: check 需要 <产品> <BUY|SELL> <名义金额> [类型]\n' >&2; exit 2; }
    # 第 4 个参数可选：订单类型（market/limit…），只影响账本里记什么，不影响判断。
    # 不加这个参数时记 "-"，历史行为不变。
    _otype=${ARGS[3]:--}
    if cb_risk_check "${ARGS[0]}" "$(printf '%s' "${ARGS[1]}" | tr '[:lower:]' '[:upper:]')" "$_otype" "${ARGS[2]}"; then
      cb_ok "通过：${ARGS[0]} ${ARGS[1]} ${ARGS[2]}"
    else
      exit 4
    fi
    ;;

  journal)
    n=${ARGS[0]:-20}
    j=$(cb_risk_journal)
    [ -f "$j" ] || { cb_info "还没有任何记录（${j}）"; exit 0; }
    tail -n "$n" "$j" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: r = json.loads(line)
    except Exception: print(line); continue
    print("%s  %-8s %-10s %-4s %-6s %10s  %-8s %s" % (
        r.get("ts","")[11:19], r.get("event",""), r.get("product",""), r.get("side",""),
        r.get("type",""), r.get("notional",0), r.get("result",""), r.get("reason","")))
'
    ;;

  report)
    cb_risk_report "${ARGS[@]+"${ARGS[@]}"}"
    ;;

  show)
    j=$(cb_risk_journal)
    echo "账本: $j"
    [ -f "$j" ] && printf '记录: %s 条\n' "$(wc -l < "$j" | tr -d ' ')" || echo "记录: 0 条"
    if cb_risk_killed; then cb_bad "kill switch: 开着（下单被禁止）"; else cb_ok "kill switch: 关着（可下单）"; fi
    cb_hr
    for k in max_single_trade_usd max_daily_usd max_orders_per_hour allowed_products; do
      v=$(cb_risk_cfg "$k" "")
      if [ -n "$v" ]; then
        printf '%-22s %s\n' "$k" "$v"
      else
        printf '%-22s %s\n' "$k" "${CB_C_DIM}未设置，不限${CB_C_OFF}"
      fi
    done
    read -r spent count <<EOF
$(cb_risk_usage)
EOF
    cb_hr
    printf '今日已用  %s\n最近一小时 %s 笔\n' "$spent" "$count"
    ;;
esac
exit 0
