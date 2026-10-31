#!/usr/bin/env bash
# coinbase-stack-check.sh — Coinbase for Agents 栈的开机自检 / 自愈
#
# Coinbase CLI 是命令，不是常驻进程，所以它本身没有"启动"这回事。
# 真正需要随开机恢复的是"能让它工作的一切"：
#   1) NODE_OPTIONS（IPv4 优先，否则 IPv6 出网绕过 IP 白名单 → 一律 401）
#   2) coinbase 二进制（全局 npm 包，缺失则重装）
#   3) 配置里的 env 指向 live 且 key 已装载
#   4) key 文件存在且权限 600
#   5) 9 个 agent skills 目录
#   6) MCP 注册（claude / codex）
#   7) 端到端连通性：api-key permissions 必须 200
#
# 全部成功退出 0；关键项失败退出非 0，systemd 里显示为 failed。

set -uo pipefail

HOME_DIR=/data/home
KEY=$HOME_DIR/cdp_api_key_ecdsa.json
LOG=$HOME_DIR/.coinbase-stack.log
STATUS=$HOME_DIR/.coinbase-stack-status.json
# portfolio_id 的来源，按优先级：
#   1) 环境变量 COINBASE_PORTFOLIO_ID（显式指定）
#   2) 配置文件（cb-portfolio.sh --save / cb-config.sh set 写的那份）
# 只认环境变量会让开机自检永远"跳过 balance"——明明配置里有，却假装没配，
# 那样这条自检就成了摆设。
PFX=${COINBASE_PORTFOLIO_ID:-}
if [ -z "$PFX" ] && [ -f "$HOME_DIR/lib/config.sh" ]; then
  # 显式指定配置文件：此刻 HOME 还没被改成 HOME_DIR，靠默认路径会读错地方
  [ -n "${CB_CONFIG:-}" ] || export CB_CONFIG="$HOME_DIR/.config/coinbase-agent/config.json"
  # shellcheck disable=SC1091
  . "$HOME_DIR/lib/config.sh" 2>/dev/null && PFX=$(cb_portfolio_id 2>/dev/null || true)
fi
[ -n "$PFX" ] || PFX="YOUR_PORTFOLIO_UUID"
PFX_OK=1; [ "$PFX" = "YOUR_PORTFOLIO_UUID" ] && PFX_OK=0
NODE_OPT='--dns-result-order=ipv4first'

export HOME=$HOME_DIR
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export NODE_OPTIONS=$NODE_OPT

mkdir -p "$HOME_DIR"
say() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
fail=0
res=()

check() { # name ok_detail
  if [ "$1" = 0 ]; then res+=("$2:OK"); else res+=("$2:FAIL"); fail=1; fi
}

say "===== boot self-check start ====="

# ---------- 1. NODE_OPTIONS 幂等固化 ----------
if ! grep -q 'dns-result-order=ipv4first' /etc/environment 2>/dev/null; then
  sudo -n sh -c "printf 'NODE_OPTIONS=\"$NODE_OPT\"\n' >> /etc/environment" >/dev/null 2>&1 \
    && say "已补写 /etc/environment 的 NODE_OPTIONS"
fi
sudo -n sh -c "test -f /etc/profile.d/99-node-ipv4.sh || printf 'export NODE_OPTIONS=\"%s\"\n' '$NODE_OPT' > /etc/profile.d/99-node-ipv4.sh" >/dev/null 2>&1
nopt=$(grep -c 'dns-result-order=ipv4first' /etc/environment 2>/dev/null || echo 0)
if [ "$nopt" -ge 1 ]; then check 0 node_options; else check 1 node_options; fi

# ---------- 2. coinbase 二进制 ----------
if [ ! -e /usr/local/bin/coinbase ] && [ ! -e /usr/local/bin/coinbase-real.js ]; then
  say "coinbase 缺失，重装 npm 包"
  # 日志文件是当前用户所有，重定向故意留在这层；
  # shellcheck disable=SC2024
  sudo -n npm install -g @coinbase/coinbase-cli >>"$LOG" 2>&1
fi
ver=$(timeout 60 coinbase --version 2>&1 | tr -d '\n')
if [ -n "$ver" ]; then check 0 "cli($ver)"; else check 1 cli; fi

# ---------- 2.5 风控守卫是否还在原位 ----------
# npm 升级会把 /usr/local/bin/coinbase 换回真二进制，守卫就没了 ——
# 而"守卫悄悄消失"比"守卫从没装过"更危险：两者看起来都是能下单。
# 所以每次开机都确认一遍，发现被覆盖就重新装回去。
GUARD_SRC="$HOME_DIR/bin/coinbase-guard"
if [ -f "$GUARD_SRC" ]; then
  if grep -q 'CB_GUARD_V1' /usr/local/bin/coinbase 2>/dev/null \
     && [ -f /usr/local/bin/coinbase-mcp-proxy.mjs ]; then
    check 0 guard
  else
    say "风控守卫被覆盖了，正在恢复"
    # 真程序必须叫 .js：这个 CLI 是 Node ESM 脚本，别的扩展名 node 会直接拒绝
    # （ERR_UNKNOWN_FILE_EXTENSION），改名时踩过这个坑。
    if [ -x /usr/local/bin/coinbase ]; then
      sudo -n mv -f /usr/local/bin/coinbase /usr/local/bin/coinbase-real.js >/dev/null 2>&1
    fi
    PROXY_SRC="$HOME_DIR/bin/coinbase-mcp-proxy.mjs"
    [ -f "$PROXY_SRC" ] && sudo -n install -m 644 "$PROXY_SRC" /usr/local/bin/coinbase-mcp-proxy.mjs >/dev/null 2>&1
    if sudo -n install -m 755 "$GUARD_SRC" /usr/local/bin/coinbase >/dev/null 2>&1 \
       && grep -q 'CB_GUARD_V1' /usr/local/bin/coinbase 2>/dev/null; then
      check 0 "guard(restored)"
    else
      check 1 guard
    fi
  fi
fi

# ---------- 3. key 文件 ----------
if [ -f "$KEY" ]; then
  chmod 600 "$KEY" 2>/dev/null
  mode=$(stat -c %a "$KEY")
  if [ "$mode" = 600 ]; then check 0 keyfile; else check 1 keyfile; fi
else
  say "缺少 key 文件 $KEY"
  check 1 keyfile
fi

# ---------- 4. env = live ----------
envname=$(timeout 60 coinbase env 2>/dev/null | awk '/^\*/{print $2}' | head -1)
if [ "$envname" != live ]; then
  say "当前 env='$envname'，切回 live"
  timeout 90 coinbase env live --key-file "$KEY" --allow-plaintext-secrets >>"$LOG" 2>&1
  envname=$(timeout 60 coinbase env 2>/dev/null | awk '/^\*/{print $2}' | head -1)
fi
if [ "$envname" = live ]; then check 0 env_live; else check 1 env_live; fi

# ---------- 5. skills ----------
# 用 find 而不是 ls|wc：技能目录名带空格或特殊字符时 ls 会数错
sk_c=$(find "$HOME_DIR/.claude/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
sk_x=$(find "$HOME_DIR/.codex/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
if [ "$sk_c" -ge 9 ] && [ "$sk_x" -ge 9 ]; then
  check 0 "skills($sk_c/$sk_x)"
else
  check 1 "skills($sk_c/$sk_x)"
fi

# ---------- 6. MCP 注册 ----------
m_c=$(grep -c '"coinbase"' "$HOME_DIR/.claude.json" 2>/dev/null || echo 0)
m_x=$(grep -c '^\[mcp_servers.coinbase\]' "$HOME_DIR/.codex/config.toml" 2>/dev/null || echo 0)
if [ "$m_c" -ge 1 ] && [ "$m_x" -ge 1 ]; then
  check 0 mcp
else
  check 1 "mcp(claude=$m_c codex=$m_x)"
fi

# ---------- 7. 端到端连通性（开机时网络可能刚起来，最多重试 3 次）----------
perm=""
for attempt in 1 2 3; do
  perm=$(timeout 90 coinbase api-key permissions 2>&1 | tr -d '\n' | head -c 300)
  case "$perm" in
    *'"can_trade":true'*|*'"can_view":true'*) break ;;
  esac
  say "api-key 第 $attempt 次未通过: $perm"
  [ "$attempt" -lt 3 ] && sleep 5
done
case "$perm" in
  *'"can_trade":true'*|*'"can_view":true'*) check 0 api_key ;;
  *) say "api-key permissions 异常: $perm"; check 1 api_key ;;
esac

bal_rc=1
ran_bal=0
if [ "$fail" -eq 0 ] && [ "$PFX_OK" -eq 0 ]; then
  say "跳过 balance：环境变量与配置里都没有 portfolio_id（其余项不受影响）"
elif [ "$fail" -eq 0 ]; then
  ran_bal=1
  bel=""
  for attempt in 1 2 3; do
    bel=$(timeout 90 coinbase balance portfolio_id=="$PFX" show_zero==true 2>&1 | tr -d '\n' | head -c 200)
    case "$bel" in *'"accounts"'*) bal_rc=0; break ;; esac
    say "balance 第 $attempt 次未通过: $bel"
    [ "$attempt" -lt 3 ] && sleep 5
  done
fi
[ $ran_bal -eq 1 ] && check $bal_rc balance

# ---------- 状态文件 ----------
{
  printf '{"at":"%s","version":"%s","env":"%s","checks":[' "$(date -Is)" "$ver" "$envname"
  first=1
  for r in "${res[@]}"; do
    [ $first -eq 1 ] || printf ','
    printf '"%s"' "$r"; first=0
  done
  printf '],"ok":%s}\n' "$([ $fail -eq 0 ] && echo true || echo false)"
} > "$STATUS"

say "结果: ${res[*]}"
say "===== boot self-check end (ok=$([ $fail -eq 0 ] && echo yes || echo no)) ====="
exit $fail
