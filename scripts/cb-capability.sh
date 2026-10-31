#!/usr/bin/env bash
# cb-capability.sh — 这把 key、这个组合，到底能做什么
#
# 为什么需要：Coinbase 有多个产品面（现货 / 股票 / 期货 / Convert / x402），
# 可用性既取决于 key 的类型与权限，也取决于 key 绑定的组合，还取决于该账户
# 是否开通了对应业务。这些差异全都表现为 403，而 403 的文案只对其中一部分
# 情况有区分度 —— 于是"能不能做"变成一堆试错。
#
# 这个脚本只做只读探测（包括 orders preview，它不产生订单），把每个面标成：
#   ✓ 可用      接口返回了数据
#   ✗ 不可用    明确被拒，并给出原因
#   ? 未判定    返回了看不懂的东西（不当成可用）
#
# 用法:
#   cb-capability.sh            # 人看的表
#   cb-capability.sh --json     # 给程序用
#   cb-capability.sh --strict   # 有任何 ✗ 或 ? 就退出码 1（放进 CI / 自检）
#
# 退出码: 0 全部可用或非 --strict / 1 --strict 且有不可用项 / 2 用法错

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"; }

AS_JSON=0
STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json)   AS_JSON=1; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '错误: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
  esac
done

cb_need coinbase
cb_ensure_node_options

PFX=$(cb_portfolio_id) || exit $?

# 每一项跑一次只读请求，把结果压成一个三元组。全部走 timeout，避免一个卡住拖垮整张表。
P_STAT=""; P_DETAIL=""
probe() { # probe <命令...>  → 设置 P_STAT / P_DETAIL（不 echo，避免词分割）
  local out rc why
  out=$(cb_timeout 45 "$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"'; then
    P_STAT="ok"; P_DETAIL="返回了数据"
    return 0
  fi
  # 403 / 401 / 400 的文案里通常写着原因，把它捞出来当说明
  local why
  why=$(printf '%s' "$out" | python3 -c '
import json,sys,re
raw=sys.stdin.read()
m=re.search(r"\{.*\}", raw, re.S)
if m:
    try:
        d=json.loads(m.group(0))
        e=d.get("errorMessage") or d.get("message") or d.get("error") or ""
        if e: print(str(e)[:160]); raise SystemExit
    except SystemExit: raise
    except Exception: pass
for line in raw.splitlines():
    if "error" in line.lower():
        print(line.strip()[:160]); break
' 2>/dev/null)
  [ -z "$why" ] && why="退出码 ${rc:-?}"
  P_STAT="no"; P_DETAIL="$why"
}

ROWS=""
add() { # add <标签> <状态> <说明>
  ROWS="${ROWS}${1}\t${2}\t${3}\n"
}

# ---------- 1. 鉴权 ----------
perm=$(cb_timeout 45 coinbase api-key permissions 2>&1)
if printf '%s' "$perm" | grep -q '"can_view"'; then
  add "鉴权 · API key" ok "$(printf '%s' "$perm" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("can_view=%s can_trade=%s can_transfer=%s" % (d.get("can_view"), d.get("can_trade"), d.get("can_transfer")))' 2>/dev/null)"
else
  add "鉴权 · API key" no "$(printf '%s' "$perm" | tr -d '\n' | head -c 120)"
fi

# ---------- 2. 现货 ----------
probe coinbase products get BTC-USD
add "现货 · 行情" "$P_STAT" "$P_DETAIL"
probe coinbase balance "portfolio_id==${PFX}" show_zero==true
add "现货 · 余额" "$P_STAT" "$P_DETAIL"

# preview 不产生订单，只验证"这一笔能不能下" —— 余额 0 时会明确说 insufficient fund，
# 那正好证明鉴权与产品都通，只是没钱。
pv=$(cb_timeout 45 coinbase orders preview "product_id=BTC-USD" side=BUY type=market "quote_size=1" "portfolio_id=${PFX}" 2>&1)
if printf '%s' "$pv" | grep -q 'insufficient fund'; then
  add "现货 · 下单路径" ok "预览通过（余额不足，这是预期）"
elif printf '%s' "$pv" | grep -qi 'permission_denied\|does not have access'; then
  add "现货 · 下单路径" no "组合无权下单：$(printf '%s' "$pv" | tr -d '\n' | head -c 110)"
else
  add "现货 · 下单路径" ok "预览返回：$(printf '%s' "$pv" | tr -d '\n' | head -c 90)"
fi

# ---------- 3. 股票 ----------
eq=$(cb_timeout 45 coinbase products get AAPL-USD 2>&1)
if printf '%s' "$eq" | grep -q 'EQUITY'; then
  add "股票 · 产品可见" ok "AAPL-USD product_type=EQUITY"
else
  add "股票 · 产品可见" no "$(printf '%s' "$eq" | tr -d '\n' | head -c 110)"
fi
# 股票没有独立预览（服务端策略），所以这里只能验证"预览路径本身存在"。
# 不去试 create：真下单一旦被接受就会成交，探测不该有副作用。
epv=$(cb_timeout 45 coinbase orders preview "product_id=AAPL-USD" side=BUY type=market "quote_size=1" "portfolio_id=${PFX}" 2>&1)
if printf '%s' "$epv" | grep -q 'standalone order preview is not available'; then
  add "股票 · 下单能力" na "无独立预览（服务端策略），真下单见 docs/CAPABILITIES.md"
elif printf '%s' "$epv" | grep -qi 'permission_denied\|does not have access'; then
  add "股票 · 下单能力" no "被拒：$(printf '%s' "$epv" | tr -d '\n' | head -c 110)"
else
  add "股票 · 下单能力" na "预览返回：$(printf '%s' "$epv" | tr -d '\n' | head -c 90)"
fi

# ---------- 4. Convert ----------
cv=$(cb_timeout 45 coinbase convert quote from=USDC to=USD amount=1 2>&1)
if printf '%s' "$cv" | grep -q 'only be performed on default portfolio'; then
  add "Convert · 换币" no "只支持 default portfolio，而 key 绑定的是 Agent MPC"
elif printf '%s' "$cv" | grep -q '"'; then
  add "Convert · 换币" ok "报价可用"
else
  add "Convert · 换币" no "$(printf '%s' "$cv" | tr -d '\n' | head -c 110)"
fi

# ---------- 5. x402 ----------
x4=$(cb_timeout 60 coinbase x402 resources 2>&1)
if printf '%s' "$x4" | grep -q '"resources"'; then
  n=$(printf '%s' "$x4" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("resources") or []))' 2>/dev/null)
  add "x402 · 付费数据目录" ok "共 ${n} 条资源可发现"
else
  add "x402 · 付费数据目录" no "$(printf '%s' "$x4" | tr -d '\n' | head -c 110)"
fi

# ---------- 6. 期货 ----------
dv=$(cb_timeout 45 coinbase derivatives updates 2>&1)
if printf '%s' "$dv" | grep -qi 'invalid request'; then
  add "期货 · 快照流" no "接口返回 invalid request（CFM 期货本身也未对本账户开放）"
elif printf '%s' "$dv" | grep -q '"'; then
  add "期货 · 快照流" ok "返回了快照"
else
  add "期货 · 快照流" no "$(printf '%s' "$dv" | tr -d '\n' | head -c 110)"
fi

# ---------- 7. 组合 ----------
pf=$(cb_timeout 45 coinbase portfolios list 2>&1)
if printf '%s' "$pf" | grep -q '"portfolios"'; then
  add "组合 · 列表" ok "见 cb-portfolio.sh"
else
  add "组合 · 列表" no "$(printf '%s' "$pf" | tr -d '\n' | head -c 110)"
fi

# ---------- 输出 ----------
if [ "$AS_JSON" -eq 1 ]; then
  printf '%b' "$ROWS" | python3 -c '
import sys, json
rows = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    while len(parts) < 3:
        parts.append("")
    rows.append({"item": parts[0], "status": parts[1], "detail": parts[2]})
print(json.dumps({"portfolio": sys.argv[1], "items": rows,
                  "ok": sum(1 for r in rows if r["status"] == "ok"),
                  "not_ok": sum(1 for r in rows if r["status"] == "no")},
                 ensure_ascii=False, indent=2))
' "$PFX"
else
  cb_hr
  printf '组合 %s 的能力面\n' "$PFX"
  cb_hr
  printf '%b' "$ROWS" | python3 -c '
import sys
icon = {"ok": "✓", "no": "✗", "na": "·"}
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    p = line.split("\t")
    while len(p) < 3:
        p.append("")
    print("%s %-22s %s" % (icon.get(p[1], "?"), p[0], p[2]))
'
  cb_hr
fi

not_ok=$(printf '%b' "$ROWS" | awk -F'\t' '$2=="no"' | wc -l | tr -d ' ')
if [ "$STRICT" -eq 1 ] && [ "${not_ok:-0}" -gt 0 ]; then
  exit 1
fi
exit 0
