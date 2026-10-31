#!/usr/bin/env bash
# cb-doctor.sh — 一条命令把 Coinbase 环境从头到脚查一遍
#
# 这个脚本是把"踩过的坑"变成检查项：每一条都对应一次真实故障。
# 只读：不修改任何配置、不下单、不写密钥。
#
# 用法:
#   cb-doctor.sh              # 人类可读报告
#   cb-doctor.sh --json       # 机器可读（给监控/CI 用）
#   cb-doctor.sh --quiet      # 只输出失败的项
#
# 退出码: 0 全部通过 / 1 有警告 / 2 有失败

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"

JSON=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --json)  JSON=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) cb_die "未知参数 $a" ;;
  esac
done

ROWS=()          # "状态<TAB>编号<TAB>说明<TAB>建议"
FAILED=0; WARNED=0

# record <ok|warn|fail> <编号> <说明> [建议]
record() {
  local st=$1 id=$2 msg=$3 hint=${4:-}
  ROWS+=("${st}"$'\t'"${id}"$'\t'"${msg}"$'\t'"${hint}")
  case "$st" in
    fail) FAILED=$((FAILED+1)) ;;
    warn) WARNED=$((WARNED+1)) ;;
  esac
  [ "$JSON" -eq 1 ] && return 0
  if [ "$QUIET" -eq 1 ]; then
    case "$st" in ok) return 0 ;; esac
  fi
  case "$st" in
    ok)   printf '%s✓%s %-22s %s\n' "$CB_C_GRN" "$CB_C_OFF" "$id" "$msg" ;;
    warn) printf '%s!%s %-22s %s\n' "$CB_C_YEL" "$CB_C_OFF" "$id" "$msg" ;;
    fail) printf '%s✗%s %-22s %s\n' "$CB_C_RED" "$CB_C_OFF" "$id" "$msg" ;;
  esac
  [ -n "$hint" ] && printf '   %s→ %s%s\n' "$CB_C_DIM" "$hint" "$CB_C_OFF"
  return 0
}

# 一行结论 + 自动判级：0=ok 其它=fail
# A && B || C 不是 if-else：B 失败时 C 也会跑，这里必须写清楚
verdict() {
  if [ "$1" -eq 0 ]; then
    record ok "$2" "$3"
  else
    record fail "$2" "$3" "${4:-}"
  fi
}

command -v python3 >/dev/null || { echo "缺少 python3" >&2; exit 2; }

# ---------- 1. 运行环境 ----------
verdict 0 env.host "$(uname -s) $(uname -m) / $(id -un) / $(hostname 2>/dev/null || echo '?')"

nodev=$(node --version 2>/dev/null | sed 's/^v//')
if [ -z "$nodev" ]; then
  record fail env.node "没装 node"
elif [ "${nodev%%.*}" -ge 22 ] 2>/dev/null; then
  record ok env.node "node ${nodev}（≥22 ✓）"
else
  record fail env.node "node ${nodev} 低于 22" "Coinbase CLI 要求 Node.js 22 或更高"
fi

# ---------- 2. CLI ----------
if command -v coinbase >/dev/null; then
  record ok cli.coinbase "$(coinbase --version 2>/dev/null | tr -d '\n' | sed 's/^coinbase \+//')"
else
  record fail cli.coinbase "没装 coinbase" "sudo npm i -g @coinbase/coinbase-cli"
fi

# ---------- 3. NODE_OPTIONS：本项目最贵的坑 ----------
case " ${NODE_OPTIONS:-} " in
  *" $CB_NODE_OPT "*)
    record ok node.ipv4 "NODE_OPTIONS 已含 ${CB_NODE_OPT}" ;;
  *)
    record fail node.ipv4 "NODE_OPTIONS 缺少 ${CB_NODE_OPT}" \
      "缺了它会走 IPv6 出网，源 IP 不在门户白名单里，所有请求一律 401
          修法：export NODE_OPTIONS=${CB_NODE_OPT}（并写进 /etc/environment 与 systemd 单元）" ;;
esac

# ---------- 4. 出网：以 Node 看到的为准 ----------
# 关键点：coinbase CLI 是 Node 程序，cdp 门户白名单看的是"Node 从哪个地址出去"。
# curl 和 node 的出口可能不同（curl 不受 NODE_OPTIONS 影响），
# 所以必须用 node 复现 CLI 的真实出口，否则会误报。

# node_trace <开关>：打印 Coinbase 边缘看到的源 IP
node_trace() {
  NODE_EXTRA_OFF=$1 node -e '
const https = require("https");
https.get("https://api.coinbase.com/cdn-cgi/trace", r => {
  let b = ""; r.on("data", d => b += d); r.on("end", () => {
    const m = b.match(/^ip=(.*)$/m); process.stdout.write(m ? m[1].trim() : "");
  });
}).on("error", () => process.stdout.write(""));
' 2>/dev/null
}

edge_node=$(node_trace "")
if [ -z "$edge_node" ]; then
  record warn net.edge "node 取不到 api.coinbase.com/cdn-cgi/trace" "网络或 DNS 异常，其它检查结果可能不可信"
elif printf '%s' "$edge_node" | grep -q ':'; then
  record fail net.edge "Node 出网是 IPv6：${edge_node}" \
    "CLI 会从白名单外的地址发出请求，一律 401。先修 NODE_OPTIONS=${CB_NODE_OPT}"
else
  record ok net.edge "Node 出网是 IPv4：${edge_node}" \
    "确认这个地址在 CDP 门户该 API key 的 IP Allowlist 里"
fi

# curl 的出口单独看一眼：它和 node 不一致是正常的（curl 不读 NODE_OPTIONS），
# 但如果 curl 也是 IPv6，说明这台机器默认路由偏好 IPv6，IPv4 白名单迟早出问题。
edge_curl=$(curl -s --max-time 8 https://api.coinbase.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')
if [ -n "$edge_curl" ] && printf '%s' "$edge_curl" | grep -q ':'; then
  record warn net.curl "curl 走的是 IPv6：${edge_curl}" \
    "curl 不读 NODE_OPTIONS，所以它和 CLI 的出口不同是正常的；
          这里只作提示：只要有程序不强制 IPv4，就会撞上同一个白名单问题"
elif [ -n "$edge_curl" ]; then
  record ok net.curl "curl 出网也是 IPv4：${edge_curl}"
fi

# ---------- 5. key 文件：类型、权限 ----------
KEY=$(cb_key_file)
if [ ! -f "$KEY" ]; then
  record fail key.file "找不到 key 文件：${KEY}" \
    "从 CDP 门户下载 JSON，或设 COINBASE_KEY_FILE / 配置文件 key_file"
else
  mode=$(stat -c %a "$KEY" 2>/dev/null || stat -f %Lp "$KEY" 2>/dev/null)
  if [ "$mode" = "600" ]; then
    record ok key.perm "key 文件权限 600"
  else
    record warn key.perm "key 文件权限是 ${mode}，应为 600" "chmod 600 ${KEY}"
  fi
  keyinfo=$(python3 - "$KEY" <<'PY' 2>/dev/null
import json, sys, base64
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("bad|不是合法 JSON"); raise SystemExit
pk = d.get("privateKey") or d.get("secret") or ""
kid = (d.get("name") or d.get("id") or "?").rstrip("/").split("/")[-1]
if "BEGIN EC PRIVATE KEY" in pk:
    print("ok|ECDSA (PEM, P-256) — Advanced Trade 支持；key …%s" % kid[-8:])
elif "BEGIN PRIVATE KEY" in pk:
    print("warn|PKCS#8 PEM — 类型未判定，先试 coinbase env 看是否 401")
else:
    try:
        raw = base64.b64decode(pk + "=" * (-len(pk) % 4))
    except Exception:
        raw = b""
    if len(raw) in (32, 64):
        print("fail|Ed25519（base64 %d 字节）— Advanced Trade 不支持，必须换 ECDSA" % len(raw))
    else:
        print("warn|无法识别的 key 形态（解出 %d 字节）" % len(raw))
PY
)
  case "$keyinfo" in
    ok\|*)   record ok   key.type "${keyinfo#ok|}" ;;
    warn\|*) record warn key.type "${keyinfo#warn|}" ;;
    fail\|*) record fail key.type "${keyinfo#fail|}" \
               "CDP 门户 Create API key → Advanced Settings → Signature algorithm 选 ECDSA" ;;
    *)       record warn key.type "无法解析 key 文件" ;;
  esac
fi

# ---------- 6. CLI 环境是否指向 live ----------
envout=$(coinbase env 2>&1)
if printf '%s' "$envout" | grep -q '^\* live\|live'; then
  record ok cli.env "环境：live"
else
  record fail cli.env "没有配置成 live" "coinbase env live --key-file ${KEY} --allow-plaintext-secrets"
fi
if printf '%s' "$envout" | grep -qi 'key.*\.\.\.\|Key '; then
  record ok cli.keyid "已装载 key"
fi

# ---------- 7. 连通性：权限接口 ----------
perm=$(coinbase api-key permissions 2>&1)
case "$perm" in
  *'"can_view"'*)
    record ok api.permissions "$(printf '%s' "$perm" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("返回不是 JSON"); raise SystemExit
print("can_view=%(can_view)s can_trade=%(can_trade)s can_transfer=%(can_transfer)s portfolio_type=%(portfolio_type)s" % {
    "can_view": d.get("can_view"), "can_trade": d.get("can_trade"),
    "can_transfer": d.get("can_transfer"), "portfolio_type": d.get("portfolio_type")})' 2>/dev/null)" ;;
  *unauthorized*|*401*|*AUTHENTICATION_FAILED*)
    record fail api.permissions "权限接口 401/鉴权失败" \
      "按顺序查：NODE_OPTIONS → 出网是否 IPv6 → key 是否 ECDSA → 门户 IP 白名单" ;;
  *)
    record fail api.permissions "权限接口异常：$(printf '%s' "$perm" | head -c 120)" ;;
esac

# ---------- 8. 组合：能否读到余额 ----------
pfx=""
if pfx=$(cb_portfolio_id 2>/dev/null); then
  bal=$(coinbase balance portfolio_id=="$pfx" show_zero==true 2>&1)
  case "$bal" in
    *'"accounts"'*)
      record ok portfolio.balance "组合 ${pfx:0:8}… 可读，余额接口 200" ;;
    *does\ not\ have\ access*|*PermissionDenied*)
      record fail portfolio.balance "组合 ${pfx:0:8}… 无权限" \
        "这组 key 的作用域只覆盖创建时选的那个组合，换组合或换 key" ;;
    *)
      record fail portfolio.balance "余额接口异常：$(printf '%s' "$bal" | head -c 120)" ;;
  esac
else
  record warn portfolio.id "还没有可用的组合 UUID" "bash scripts/cb-portfolio.sh --save 自动挑一个存起来"
fi

# ---------- 9. 可选：DeepSeek 模型接通 ----------
if command -v claude >/dev/null && [ -f "$HOME/.claude/settings.json" ]; then
  base=$(python3 -c '
import json, os
try: e = json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("env", {})
except Exception: e = {}
print(e.get("ANTHROPIC_BASE_URL", ""))' 2>/dev/null)
  if printf '%s' "$base" | grep -q deepseek; then
    record ok model.deepseek "claude 指向自定义端点：${base}"
  else
    record warn model.deepseek "claude 未指向 DeepSeek" "bash scripts/ds-model.sh --key-file <deepseek-key>"
  fi
fi

# ---------- 10. 可选：Telegram 中继器 ----------
if command -v systemctl >/dev/null; then
  if st=$(systemctl is-active tg-agent 2>/dev/null); then
    if [ "$st" = "active" ]; then
      record ok relay.tg "tg-agent active"
    else
      record warn relay.tg "tg-agent ${st}"
    fi
  fi
  if st=$(systemctl is-active coinbase-stack 2>/dev/null); then
    if [ "$st" = "active" ]; then
      record ok relay.stack "coinbase-stack active（开机自检已通过）"
    else
      record warn relay.stack "coinbase-stack ${st}" "journalctl -u coinbase-stack -n 50"
    fi
  fi
fi

# ---------- 输出 ----------
if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "${ROWS[@]}" | python3 -c '
import sys, json
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line: continue
    st, cid, msg, hint = (line.split("\t") + ["", "", ""])[:4]
    rows.append({"check": cid, "status": st, "message": msg, "hint": hint})
print(json.dumps({"ok": not any(r["status"] == "fail" for r in rows),
                  "failed": sum(r["status"] == "fail" for r in rows),
                  "warned": sum(r["status"] == "warn" for r in rows),
                  "checks": rows}, ensure_ascii=False, indent=2))'
else
  cb_hr
  if [ "$FAILED" -eq 0 ] && [ "$WARNED" -eq 0 ]; then
    printf '%s全部 %d 项检查通过。%s\n' "$CB_C_GRN" "${#ROWS[@]}" "$CB_C_OFF"
  elif [ "$FAILED" -eq 0 ]; then
    printf '%s%d 项通过，%d 项警告，没有失败项。%s\n' "$CB_C_YEL" "${#ROWS[@]}" "$WARNED" "$CB_C_OFF"
  else
    printf '%s%d 项失败，%d 项警告。按上面的 → 提示逐条处理。%s\n' \
      "$CB_C_RED" "$FAILED" "$WARNED" "$CB_C_OFF"
  fi
fi

[ "$FAILED" -gt 0 ] && exit 2
[ "$WARNED" -gt 0 ] && exit 1
exit 0
