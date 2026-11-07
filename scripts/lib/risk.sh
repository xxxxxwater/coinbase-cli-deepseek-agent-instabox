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
export CB_RISK_VERSION=2

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
cb_risk_ledger() {
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/risk-ledger.py" "$1" "$(cb_risk_journal)" "${@:2}"
}

cb_risk_journal_add() {
  cb_risk_ledger append "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}" "${8:-}"
}

# Atomic admission and durable reservation. Only reconciliation can release it.
cb_risk_reserve() {
  cb_risk_ledger reserve "$1" "$2" "$3" "${4:--}" "${5:-script}"
}

# cb_risk_usage：打印 "<今日已用金额> <本小时已提交笔数>"
# 金额包含未核对预留；笔数包含预留尝试，终态审计不重复计数。
# cb_risk_verify: 校验哈希链。返回 0 全部可验证；1 发现断链/被改；2 有旧格式行（不可验证）
cb_risk_verify() {
  python3 - "$(cb_risk_journal)" <<'PYVERIFY'
import hashlib, json, sys

path = sys.argv[1]

def canon(r):
    body = {k: v for k, v in r.items() if k not in ("prev", "h")}
    return json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

try:
    with open(path, "r", encoding="utf-8") as f:
        lines = [ln for ln in f.read().splitlines() if ln.strip()]
except FileNotFoundError:
    print("账本还不存在（0 条记录）")
    raise SystemExit(0)

prev = ""
legacy = 0
for i, ln in enumerate(lines, 1):
    try:
        rec = json.loads(ln)
    except Exception:
        print("第 %d 行不是 JSON —— 账本被手工改过？" % i)
        raise SystemExit(1)
    if "h" not in rec:
        legacy += 1
        prev = ""      # 链从这里断开，后面只能看"自洽"
        continue
    if rec.get("prev", "") != prev and prev != "":
        print("第 %d 行 prev 对不上：期望 %s…，实际 %s…" % (i, prev[:12], str(rec.get("prev", ""))[:12]))
        raise SystemExit(1)
    want = hashlib.sha256((str(rec.get("prev", "")) + canon(rec)).encode("utf-8")).hexdigest()
    if want != rec["h"]:
        print("第 %d 行内容与哈希不符 —— 这一行被改过" % i)
        raise SystemExit(1)
    prev = rec["h"]

if legacy:
    print("共 %d 行，其中 %d 行是旧格式（没有哈希链），这些行无法验证" % (len(lines), legacy))
    raise SystemExit(2)
print("共 %d 行，哈希链完整（每行都与前一行相连且内容未改）" % len(lines))
PYVERIFY
}

cb_risk_usage() { cb_risk_ledger usage; }


# cb_risk_p0_file：cb-news.sh 写的 P0 标记文件（同一路径，风控不联网）
cb_risk_p0_file() {
  printf '%s' "${CB_NEWS_P0_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/coinbase-agent/p0.json}"
}

# cb_risk_p0_info：回显 "计数 最新epoch"；读不到就是 "0 0"
cb_risk_p0_info() {
  local f
  f=$(cb_risk_p0_file)
  if [ ! -f "$f" ]; then printf '0 0'; return 0; fi
  python3 - "$f" <<'PY2' 2>/dev/null || printf '0 0'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    print(int(d.get("count") or 0), int(d.get("latest") or 0))
except Exception:
    print(0, 0)
PY2
}

# cb_risk_tighten_state：回显 "<on|off> <factor> <count> <age秒>"
# 生效条件：开关打开 + 标记里有 P0 + 最新 P0 落在 tighten_hours 之内
cb_risk_tighten_state() {
  local on hours factor count latest now age
  on=$(cb_risk_cfg tighten_on_p0 true)
  case "$on" in
    true|1|yes) ;;
    *) printf 'off 1 0 0'; return 0 ;;
  esac
  hours=$(cb_risk_cfg tighten_hours 6)
  hours=$(python3 -c 'from decimal import Decimal; import sys; n=Decimal(sys.argv[1]); assert n.is_finite() and 0 <= n <= 87600 and n == n.to_integral_value(); print(int(n))' "$hours") || return 4
  factor=$(cb_risk_cfg tighten_factor 0.25)
  read -r count latest <<EOF
$(cb_risk_p0_info)
EOF
  case "${count:-0}" in ''|*[!0-9]*) count=0 ;; esac
  case "${latest:-0}" in ''|*[!0-9]*) latest=0 ;; esac
  now=$(date +%s)
  age=$(( now - latest ))
  if [ "$count" -gt 0 ] && [ "$latest" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt $(( hours * 3600 )) ]; then
    printf 'on %s %s %s' "$factor" "$count" "$age"
  else
    printf 'off %s %s %s' "$factor" "$count" "$age"
  fi
}

# cb_risk_check <产品> <BUY|SELL> <类型> <名义金额>
# 通过返回 0；被拒打印原因并返回 4。规则全部来自配置，没有硬编码的魔法数。
cb_risk_check() {
  local product=$1 side=$2 otype=$3 notional=$4
  local max_single max_daily max_hour allow spent count usage tighten_factor tighten_hours
  max_single=$(cb_risk_cfg max_single_trade_usd "")
  max_daily=$(cb_risk_cfg max_daily_usd "")
  max_hour=$(cb_risk_cfg max_orders_per_hour "")
  tighten_factor=$(cb_risk_cfg tighten_factor 0.25)
  tighten_hours=$(cb_risk_cfg tighten_hours 6)
  if ! cb_risk_ledger validate "$notional" "$max_single" "$max_daily" "$max_hour" "$tighten_factor" "$tighten_hours" "$(cb_config_path)"; then
    return 4
  fi

  if cb_risk_killed; then
    cb_risk_journal_add block "$product" "$side" "$otype" "$notional" deny "kill switch 开着"
    cb_bad "风控：kill switch 开着，所有下单被禁止。恢复：cb-risk.sh resume"
    return 4
  fi

  local t_on t_factor t_count t_age note
  read -r t_on t_factor t_count t_age <<EOF
$(cb_risk_tighten_state)
EOF
  note=""
  max_single=$(cb_risk_cfg max_single_trade_usd "")
  if [ "$t_on" = "on" ] && [ -n "$max_single" ]; then
    max_single=$(python3 -c 'from decimal import Decimal, getcontext; import sys; getcontext().prec=1000; print(Decimal(sys.argv[1]) * Decimal(sys.argv[2]))' "$max_single" "$t_factor") || return 4
    note="（事件收紧：${t_count} 条 P0 在 $(( t_age / 60 )) 分钟前，上限 ×${t_factor}）"
  fi
  if [ -n "$max_single" ] && python3 -c 'from decimal import Decimal, getcontext; import sys; getcontext().prec=1000; sys.exit(0 if Decimal(sys.argv[1]) > Decimal(sys.argv[2]) else 1)' "$notional" "$max_single" 2>/dev/null; then
    cb_risk_journal_add block "$product" "$side" "$otype" "$notional" deny "超过单笔上限 $max_single${note}"
    cb_bad "风控：本笔名义金额 ${notional} 超过单笔上限 ${max_single}${note} —— cb-risk.sh show 看当前限额"
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

  usage=$(cb_risk_usage) || return 4
  read -r spent count <<< "$usage"

  max_daily=$(cb_risk_cfg max_daily_usd "")
  if [ -n "$max_daily" ] && python3 -c 'from decimal import Decimal, getcontext; import sys; getcontext().prec=1000; sys.exit(0 if Decimal(sys.argv[1]) + Decimal(sys.argv[2]) > Decimal(sys.argv[3]) else 1)' "$spent" "$notional" "$max_daily" 2>/dev/null; then
    cb_risk_journal_add block "$product" "$side" "$otype" "$notional" deny "超过当日上限 ${max_daily}（已用 ${spent}）"
    cb_bad "风控：今日已用 ${spent}，再加本笔 ${notional} 会超过当日上限 ${max_daily} —— 请先核对账本与交易所记录"
    return 4
  fi

  max_hour=$(cb_risk_cfg max_orders_per_hour "")
  if [ -n "$max_hour" ] && python3 -c 'from decimal import Decimal; import sys; sys.exit(0 if Decimal(sys.argv[1]) >= Decimal(sys.argv[2]) else 1)' "$count" "$max_hour"; then
    cb_risk_journal_add block "$product" "$side" "$otype" "$notional" deny "超过每小时上限 $max_hour"
    cb_bad "风控：达到每小时上限 ${max_hour} —— 最近一小时已提交 ${count} 笔（失败的也算）"
    return 4
  fi

  return 0
}

# cb_risk_report [--days N] [--json]
# 把账本汇总成人能看的样子。审计的用处不是"有日志"，而是"能回答这一周发生了什么"。
cb_risk_report() {
  python3 - "$(cb_risk_journal)" "$@" <<'PYREPORT'
import json, re, sys, time
from collections import Counter, defaultdict

path = sys.argv[1]
args = sys.argv[2:]
days = None
as_json = False
i = 0
while i < len(args):
    a = args[i]
    if a == "--json":
        as_json = True
        i += 1
    elif a == "--days" and i + 1 < len(args):
        days = int(args[i + 1])
        i += 2
    else:
        print("错误: report 不认识的参数 %s" % a, file=sys.stderr)
        sys.exit(2)

rows = []
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                continue
except FileNotFoundError:
    rows = []

if days:
    cutoff = time.strftime("%Y-%m-%d", time.localtime(time.time() - days * 86400))
    rows = [r for r in rows if (r.get("day") or "") >= cutoff]

by_result = defaultdict(lambda: [0, 0.0])   # key -> [笔数, 金额]
reasons = Counter()
by_product = Counter()
by_layer = Counter()

# 同一句理由，脚本层和守卫层会各写一遍（守卫会在末尾标注来源）。
# 真机上 14 条 block 被拆成"kill switch 开着"和"kill switch 开着（coinbase-guard）"
# 两组 —— 汇总的意义是"为什么被拒"，不该被来源拆散。
LAYER_RE = re.compile(r"[（(](coinbase-guard)[)）]\s*$")


def split_layer(reason):
    m = LAYER_RE.search(reason)
    if m:
        return LAYER_RE.sub("", reason).strip(), m.group(1)
    return reason, "script"
day_min = day_max = None
for r in rows:
    key = "%s/%s" % (r.get("event") or "?", r.get("result") or "?")
    by_result[key][0] += 1
    try:
        by_result[key][1] += float(r.get("notional") or 0)
    except Exception:
        pass
    if (r.get("event") or "") == "block":
        why, layer = split_layer(r.get("reason") or "（未写原因）")
        reasons[why] += 1
        by_layer[layer] += 1
        by_product[r.get("product") or "?"] += 1
    d = r.get("day") or ""
    if d:
        day_min = d if day_min is None or d < day_min else day_min
        day_max = d if day_max is None or d > day_max else day_max

if as_json:
    out = {
        "total": len(rows),
        "range": {"from": day_min, "to": day_max},
        "by_result": {k: {"count": v[0], "notional": round(v[1], 8)} for k, v in sorted(by_result.items())},
        "blocked_reasons": dict(reasons.most_common()),
        "blocked_by_layer": dict(by_layer.most_common()),
        "blocked_by_product": dict(by_product.most_common()),
    }
    print(json.dumps(out, ensure_ascii=False, indent=2, sort_keys=False))
    sys.exit(0)

print("记录: %d 条%s" % (len(rows), "" if not day_min else "（%s ~ %s）" % (day_min, day_max)))
if not rows:
    print("账本还是空的：还没有任何预览/提交/模拟盘记录。")
    sys.exit(0)

print()
# 顺手报一句链状态 —— 一份被改过的账本，"统计"越漂亮越危险
_chain = "未知"
try:
    import hashlib as _h
    _prev = ""
    _ok = True
    for _ln in open(sys.argv[1], encoding="utf-8"):
        _ln = _ln.strip()
        if not _ln:
            continue
        _r = json.loads(_ln)
        if "h" not in _r:
            _chain = "含旧格式行（无法验证）"
            _ok = False
            break
        _body = {k: v for k, v in _r.items() if k not in ("prev", "h")}
        _canon = json.dumps(_body, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        if _h.sha256((str(_r.get("prev", "")) + _canon).encode()).hexdigest() != _r["h"]:
            _chain = "第 %d 行被改过" % (_ln and 0 or 0)
            _ok = False
            break
        _prev = _r["h"]
    else:
        _chain = "完整" if _ok else "异常"
except Exception:
    _chain = "无法检查"
print("账本链: %s" % _chain)
print()
print("按结果:")
for k in sorted(by_result):
    c, amt = by_result[k]
    print("  %-18s %4d 笔  %12.2f USD" % (k, c, amt))

if reasons:
    print()
    print("被拒原因:")
    for why, c in reasons.most_common():
        print("  %3d × %s" % (c, why))
    if by_layer:
        print()
        print("按拦截层:")
        for layer, c in by_layer.most_common():
            name = "守卫（二进制/mcp）" if layer != "script" else "脚本层"
            print("  %-16s %d 笔" % (name, c))
    print()
    print("被拒最多的产品:")
    for prod, c in by_product.most_common(5):
        print("  %-12s %d 笔" % (prod, c))
PYREPORT
}
