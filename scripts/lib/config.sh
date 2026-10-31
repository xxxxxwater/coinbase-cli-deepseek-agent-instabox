#!/usr/bin/env bash
# shellcheck shell=bash
# config.sh — 所有脚本共享的配置解析与输出助手。
#
# 取值优先级：命令行参数 > 环境变量 > 配置文件 > 报错
# 配置文件：${CB_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/coinbase-agent/config.json}
#
# 被 source，不单独执行。source 之后不要 exit（会带走调用者）。

CB_LIB_VERSION=1
CB_CONFIG_DEFAULT="${XDG_CONFIG_HOME:-$HOME/.config}/coinbase-agent/config.json"
# Node 22 默认 Happy Eyeballs 优先连 IPv6；CDP 门户白名单通常只放行 IPv4。
# 少了这个变量，所有请求会从白名单外的地址出去，服务端一律 401。
CB_NODE_OPT='--dns-result-order=ipv4first'

# ---------- 输出 ----------

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  CB_C_RED=$'\033[31m'; CB_C_YEL=$'\033[33m'; CB_C_GRN=$'\033[32m'
  CB_C_DIM=$'\033[2m';  CB_C_OFF=$'\033[0m'
else
  CB_C_RED=''; CB_C_YEL=''; CB_C_GRN=''; CB_C_DIM=''; CB_C_OFF=''
fi

cb_info() { printf '%s\n' "$*"; }
cb_dim()  { printf '%s%s%s\n' "$CB_C_DIM" "$*" "$CB_C_OFF"; }
cb_warn() { printf '%s警告:%s %s\n' "$CB_C_YEL" "$CB_C_OFF" "$*" >&2; }
cb_ok()   { printf '%s✓%s %s\n' "$CB_C_GRN" "$CB_C_OFF" "$*"; }
cb_bad()  { printf '%s✗%s %s\n' "$CB_C_RED" "$CB_C_OFF" "$*" >&2; }
cb_die()  { printf '%s错误:%s %s\n' "$CB_C_RED" "$CB_C_OFF" "${1:-未知错误}" >&2; exit "${2:-2}"; }
cb_hr()   { printf '%s\n' "------------------------------------------------------------"; }

# cb_need <命令> [安装提示]
cb_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  cb_die "缺少命令 $1。${2:-}"
}

# ---------- 配置文件 ----------

cb_config_path() { printf '%s' "${CB_CONFIG:-$CB_CONFIG_DEFAULT}"; }

# cb_cfg_raw <点分键>：只读配置文件，不看环境变量；缺失返回 1
cb_cfg_raw() {
  local f; f=$(cb_config_path)
  [ -f "$f" ] || return 1
  python3 - "$f" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    v = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for part in sys.argv[2].split('.'):
    if not isinstance(v, dict) or part not in v:
        sys.exit(1)
    v = v[part]
print(json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v)
PY
}

# cb_get <环境变量名> <配置键> [默认值]
# 环境变量优先，其次配置文件，最后默认值。
cb_get() {
  local env_name=$1 cfg_key=$2 def=${3:-} v
  v=$(eval "printf '%s' \"\${$env_name:-}\"")
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  if v=$(cb_cfg_raw "$cfg_key"); then printf '%s' "$v"; return 0; fi
  printf '%s' "$def"
}

# ---------- 具体字段 ----------

# cb_portfolio_id：组合 UUID。找不到就报错并给出下一步命令。
cb_portfolio_id() {
  local v
  v=$(cb_get COINBASE_PORTFOLIO_ID portfolio_id)
  case "$v" in
    ''|YOUR_PORTFOLIO_UUID|'"'*)
      cb_die "没有可用的组合 UUID。
        三种给法，任选其一：
          export COINBASE_PORTFOLIO_ID=<uuid>
          （本脚本）--portfolio <uuid>
          bash scripts/cb-portfolio.sh --save      # 自动挑出有权限的那个并记住
        查组合：coinbase portfolios list --jq '.portfolios[] | {uuid,name}'" 3 ;;
  esac
  printf '%s' "$v"
}

# cb_key_file：CDP key 路径
cb_key_file() {
  local v; v=$(cb_get COINBASE_KEY_FILE key_file "${HOME}/cdp_api_key.json")
  printf '%s' "$v"
}

# ---------- 环境 ----------

# cb_ensure_node_options：确保 Node 走 IPv4 优先。
# 已经是正确值时静默；补上了就提示一句（写 stderr，不污染 stdout 的 JSON）。
cb_ensure_node_options() {
  case " ${NODE_OPTIONS:-} " in
    *" $CB_NODE_OPT "*) return 0 ;;
  esac
  export NODE_OPTIONS="${NODE_OPTIONS:-} $CB_NODE_OPT"
  NODE_OPTIONS="${NODE_OPTIONS# }"
  export NODE_OPTIONS
  cb_dim "已为本次执行补上 NODE_OPTIONS=${CB_NODE_OPT}（避免 IPv6 出网 401）" >&2
}

# ---------- JSON ----------

# cb_json_get <字段>：从 stdin 读 JSON 取一个顶层字段，失败返回 1
cb_json_get() {
  python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    sys.exit(1)
if v is None:
    sys.exit(1)
print(json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v)
' "$1" 2>/dev/null
}

# cb_is_json：stdin 是不是合法 JSON
# cb_is_json [字符串] —— 合法 JSON 返回 0，否则返回 1。
# 不传参数时读标准输入：printf '%s' "$x" | cb_is_json
cb_is_json() {
  if [ $# -gt 0 ]; then
    printf '%s' "$1"
  else
    cat
  fi | python3 -c 'import json,sys
try:
    json.load(sys.stdin)
except Exception:
    sys.exit(1)' 2>/dev/null
}
