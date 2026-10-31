#!/usr/bin/env bash
# cb-portfolio.sh — 列出组合、探测哪些在当前 key 的作用域内、并把可用的那个记下来
#
# 为什么要这个：这把 CDP key 只能在创建时选定的那个组合里活动。
# 打别的组合，服务端会返回两种不同形态的 403，光看报错分不清是
# “key 没权限” 还是 “组合不存在”，所以这里逐个探一遍。
#
# 用法:
#   cb-portfolio.sh                 # 列表 + 逐个探测（只读）
#   cb-portfolio.sh --json          # 机器可读
#   cb-portfolio.sh --save          # 探测通过且唯一时，写进配置文件
#   cb-portfolio.sh --save --uuid <uuid>   # 指定要记的那个（仍须探测通过）
#   cb-portfolio.sh --show          # 只打印当前生效的配置
#
# 退出码: 0 至少有一个可用组合 / 2 一个都没有 / 3 参数或配置问题

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"

JSON=0; SAVE=0; SHOW=0; WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json)  JSON=1; shift ;;
    --save)  SAVE=1; shift ;;
    --show)  SHOW=1; shift ;;
    --uuid)  WANT=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) cb_die "未知参数 $1" ;;
  esac
done

cb_need coinbase "sudo npm i -g @coinbase/coinbase-cli"
cb_ensure_node_options

CFG=$(cb_config_path)

# ---------- --show ----------
if [ "$SHOW" -eq 1 ]; then
  echo "配置文件: ${CFG}"
  if [ -f "$CFG" ]; then
    python3 - "$CFG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("portfolio_id", "key_file"):
    print("  %-13s %s" % (k, d.get(k, "(未设置)")))
PY
    cur=$(cb_get COINBASE_PORTFOLIO_ID portfolio_id "")
    [ -n "$cur" ] && echo "当前生效: ${cur}"
  else
    echo "  （还不存在，运行 --save 生成）"
  fi
  exit 0
fi

# ---------- 列出组合 ----------
raw=$(coinbase portfolios list 2>&1)
case "$raw" in
  *'"portfolios"'*) ;;
  *unauthorized*|*401*|*AUTHENTICATION_FAILED*)
    cb_die "列组合就 401，先跑 cb-doctor.sh 查鉴权链（多半是 NODE_OPTIONS / IPv6 出口）" 3 ;;
  *)
    cb_die "列组合失败：$(printf '%s' "$raw" | head -c 200)" 3 ;;
esac

# uuid \t name \t type
table=$(printf '%s' "$raw" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for p in d.get("portfolios", []):
    print("%s\t%s\t%s" % (p.get("uuid", ""), p.get("name", ""), p.get("type", "")))
' 2>/dev/null)

[ -n "$table" ] || cb_die "接口返回的组合列表是空的" 3

# ---------- 逐个探测 ----------
# 判据：balance 能读到 accounts 就在作用域内。
probe() {
  local uuid=$1 out
  out=$(coinbase balance portfolio_id=="$uuid" show_zero==true 2>&1)
  case "$out" in
    *'"accounts"'*) echo "ok" ;;
    *)              echo "denied" ;;
  esac
}

results=()
usable=()
while IFS=$'\t' read -r uuid name type; do
  [ -n "$uuid" ] || continue
  st=$(probe "$uuid")
  results+=("${uuid}"$'\t'"${name}"$'\t'"${type}"$'\t'"${st}")
  [ "$st" = ok ] && usable+=("$uuid")
done <<< "$table"

cur=$(cb_get COINBASE_PORTFOLIO_ID portfolio_id "")

# ---------- 输出 ----------
if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "${results[@]}" | python3 -c '
import sys, json
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line: continue
    uuid, name, typ, st = (line.split("\t") + ["", "", ""])[:4]
    rows.append({"uuid": uuid, "name": name, "type": typ,
                 "accessible": st == "ok"})
print(json.dumps({"portfolios": rows,
                  "usable_count": sum(1 for r in rows if r["accessible"])},
                 ensure_ascii=False, indent=2))'
else
  printf '%-38s %-16s %-10s %s\n' "UUID" "名称" "类型" "当前 key"
  cb_hr
  while IFS=$'\t' read -r uuid name type st; do
    [ -n "$uuid" ] || continue
    if [ "$st" = ok ]; then mark="${CB_C_GRN}✓ 可访问${CB_C_OFF}"
    else                    mark="${CB_C_DIM}✗ 403${CB_C_OFF}"; fi
    [ "$uuid" = "$cur" ] && suffix=" ${CB_C_YEL}← 当前配置${CB_C_OFF}" || suffix=""
    printf '%-38s %-16s %-10s %b%s\n' "$uuid" "${name:-?}" "${type:-?}" "$mark" "$suffix"
  done <<< "$(printf '%s\n' "${results[@]}")"
  cb_hr
  printf '可用组合: %d / %d\n' "${#usable[@]}" "${#results[@]}"
fi

# ---------- --save ----------
if [ "$SAVE" -eq 1 ]; then
  target=""
  if [ -n "$WANT" ]; then
    printf '%s\n' "${usable[@]}" | grep -qx "$WANT" \
      || cb_die "指定的组合 ${WANT} 不在可访问列表里（先看上面的探测结果）" 2
    target=$WANT
  else
    case "${#usable[@]}" in
      0) cb_die "没有任何组合可访问：检查 key 作用域 / IP 白名单 / NODE_OPTIONS" 2 ;;
      1) target=${usable[0]} ;;
      *) cb_die "有多个组合可访问，用 --uuid 指定要记哪一个：
         $(printf '%s ' "${usable[@]}")" 2 ;;
    esac
  fi

  mkdir -p "$(dirname "$CFG")"
  chmod 700 "$(dirname "$CFG")" 2>/dev/null || true
  python3 - "$CFG" "$target" <<'PY'
import json, sys, os, tempfile
path, target = sys.argv[1], sys.argv[2]
d = {}
if os.path.exists(path):
    try:
        d = json.load(open(path))
    except Exception:
        d = {}
d["portfolio_id"] = target
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("已写入 %s  portfolio_id=%s" % (path, target))
PY
fi

[ "${#usable[@]}" -gt 0 ] || exit 2
exit 0
