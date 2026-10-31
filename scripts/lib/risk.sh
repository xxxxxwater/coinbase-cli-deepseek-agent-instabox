#!/usr/bin/env bash
# shellcheck shell=bash
# risk.sh — 下单前的风控闸门与审计日志。
#
# 这一层不调用任何 API，只看本地账本，所以离线可测、也拦得住"还没到服务端"的错误。
#
# 借鉴的三处做法：
#   - 单笔上限 / 产品白名单：agent 交易库普遍把"这笔最多多少钱"做成硬闸门
#     （如 tigerpaw 的 maxSingleTradeUsd），而不是靠提示词劝模型别乱下单。
#   - kill switch：Hummingbot 的 kill_switch_mode 是持久配置 + 运行中可改，
#     触发后直接停策略。这里做成一个文件（touch 就算开），任何脚本、任何人
#     都能在紧急时立刻关闸，不需要改 JSON。
#   - 风险复核后再执行：TradingAgents 的 Risk Management Team 在交易员之后
#     再吵一轮才由基金经理拍板。这里用"检查 → 记录 → 执行"的顺序模拟同样的
#     分离：算限额的分支和真正下单的分支不是同一段代码。
#
# 账本：${XDG_CONFIG_HOME:-$HOME/.config}/coinbase-agent/journal.jsonl，一行一个事件。
# 它同时是审计日志和限额计数器 —— 没有第二个真相来源。

# library 的版本号：调用方可以用来判断接口是否变了
export CB_RISK_VERSION=1

cb_risk_dir() {
  local d
  d=$(dirname "$(cb_config_path)")
  mkdir -p "$d" 2>/dev/null || true
  chmod 700 "$d" 2>/dev/null || true
  printf '%s' "$d"
}

cb_risk_journal() { printf '%s/journal.jsonl' "$(cb_risk_dir)"; }
cb_risk_killfile() { printf '%s/KILL' "$(cb_risk_dir)"; }

# cb_risk_cfg <键> [默认值]：先看环境变量 CB_RISK_<大写键>，再看配置文件
cb_risk_cfg() {
  local k=$1 def=${2:-} up v
  up=$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')
  v=$(eval "printf '%s' \"\${CB_RISK_${up}:-}\"")
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  if v=$(cb_cfg_raw "$k"); then printf '%s' "$v"; return 0; fi
  printf '%s' "$def"
}

# cb_risk_killed：kill switch 是否开着（0 = 开着，即禁止下单）
cb_risk_killed() {
  [ -f "$(cb_risk_killfile)" ] && return 0
  case "$(cb_risk_cfg kill_switch false)" in
    true|True|1|yes) return 0 ;;
  esac
  return 1
}

# cb_risk_journal_add <event> <product> <side> <type> <notional> <result> [reason] [extra_json]
# 账本写不进去必须让人看见：审计缺一行比少拒绝一笔更糟，
# 而且静默失败会让人以为"这笔被拒了但没记"，其实是"既没记也没拦"。
cb_risk_journal_add() {
  local ev=$1 product=$2 side=$3 otype=$4 notional=$5 result=$6 reason=${7:-} extra=${8:-}
  python3 - "$(cb_risk_journal)" "$ev" "$product" "$side" "$otype" "$notional" "$result" "$reason" "$extra" <<'PYRISK'
import json, os, sys, time
path, ev, product, side, otype, notional, result, reason, extra = sys.argv[1:10]
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "epoch": int(time.time()),
    "day": time.strftime("%Y-%m-%d"),
    "event": ev,
    "product": product,
    "side": side,
    "type": otype,
    "notional": float(notional) if notional not in ("", "None") else 0.0,
    "result": result,
}
if reason:
    rec["reason"] = reason
if extra:
    try:
        rec.update(json.loads(extra))
    except Exception:
        rec["extra_raw"] = extra
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
with os.fdopen(fd, "a") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PYRISK
  local _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf '⚠ 风控账本写入失败（%s）：这笔操作可能没有被记录\n' "$(cb_risk_journal)" >&2
  fi
  return 0
}

# cb_risk_usage：打印 "<今日已用金额> <本小时已提交笔数>"
# 金额只算成功的，笔数算所有尝试（含失败）——两者口径不同，故意的。
cb_risk_usage() {
  python3 - "$(cb_risk_journal)" <<'PYRISK'
import json, sys, time
path = sys.argv[1]
now = time.time()
today = time.strftime("%Y-%m-%d")
spent = 0.0
last_hour = 0
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("event") != "exec":
                continue
            # 金额只算成功提交的：失败的单子没成交，不该吃掉当日额度。
            if r.get("result") in ("ok", "accepted", "submitted") and r.get("day") == today:
                spent += float(r.get("notional") or 0)
            # 笔数算所有提交尝试：限额是为了防止把账户和 API 打爆，
            # 而失败的尝试同样在打它们 —— 只在成功时才限流等于没限。
            if now - float(r.get("epoch") or 0) <= 3600:
                last_hour += 1
except FileNotFoundError:
    pass
print("%.8f %d" % (spent, last_hour))
PYRISK
}

# cb_risk_check <产品> <BUY|SELL> <类型> <名义金额>
# 通过返回 0；被拒打印原因并返回 4。规则全部来自配置，没有硬编码的魔法数。
cb_risk_check() {
  local product=$1 side=$2 otype=$3 notional=$4
  local max_single max_daily max_hour allow spent count

  if cb_risk_killed; then
    cb_risk_journal_add block "$product" "$side" "$otype" "$notional" deny "kill switch 开着"
    cb_bad "风控：kill switch 开着，所有下单被禁止。恢复：cb-risk.sh resume"
    return 4
  fi

  max_single=$(cb_risk_cfg max_single_trade_usd "")
  if [ -n "$max_single" ] && python3 -c "import sys; sys.exit(0 if float('$notional') > float('$max_single') else 1)" 2>/dev/null; then
    cb_risk_journal_add block "$product" "$side" "$otype" "$notional" deny "超过单笔上限 $max_single"
    cb_bad "风控：本笔名义金额 ${notional} 超过单笔上限 ${max_single} —— cb-risk.sh show 看当前限额"
    return 4
  fi

  allow=$(cb_risk_cfg allowed_products "")
  if [ -n "$allow" ]; then
    case ",$(printf '%s' "$allow" | tr -d ' ')," in
      *",$product,"*) ;;
      *)
        cb_risk_journal_add block "$product" "$side" "$otype" "$notional" deny "不在白名单"
        cb_bad "风控：$product 不在白名单 —— 当前白名单 ${allow}"
        return 4 ;;
    esac
  fi

  read -r spent count <<EOF
$(cb_risk_usage)
EOF

  max_daily=$(cb_risk_cfg max_daily_usd "")
  if [ -n "$max_daily" ] && python3 -c "
import sys
sys.exit(0 if float('$spent') + float('$notional') > float('$max_daily') else 1)" 2>/dev/null; then
    cb_risk_journal_add block "$product" "$side" "$otype" "$notional" deny "超过当日上限 ${max_daily}（已用 ${spent}）"
    cb_bad "风控：今日已用 ${spent}，再加本笔 ${notional} 会超过当日上限 ${max_daily} —— cb-risk.sh reset 可清零当日账本"
    return 4
  fi

  max_hour=$(cb_risk_cfg max_orders_per_hour "")
  if [ -n "$max_hour" ] && [ "$count" -ge "$max_hour" ] 2>/dev/null; then
    cb_risk_journal_add block "$product" "$side" "$otype" "$notional" deny "超过每小时上限 $max_hour"
    cb_bad "风控：达到每小时上限 ${max_hour} —— 最近一小时已提交 ${count} 笔（失败的也算）"
    return 4
  fi

  return 0
}
