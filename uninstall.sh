#!/usr/bin/env bash
# uninstall.sh — 把 install.sh 装的东西撤掉
#
# 原则：**只撤它自己装的东西**，且先说要做什么再动手。
# 不删：CDP 私钥文件、风控账本（那是审计记录）、系统里别的 coinbase 安装。
#
# 用法:
#   ./uninstall.sh                 # 撤脚本（保留配置、账本、守卫）
#   ./uninstall.sh --guard         # 另外把 coinbase 恢复成真程序
#   ./uninstall.sh --systemd       # 另外停用并删除 coinbase-stack.service
#   ./uninstall.sh --purge         # 连配置和账本一起删（会先归档账本）
#   ./uninstall.sh --prefix /usr/local --yes
#
# 退出码: 0 成功 / 1 环境不满足 / 2 用户取消

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

PREFIX="${HOME}/.local"
BIN_DIR=""
WITH_GUARD=0
WITH_SYSTEMD=0
PURGE=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)  PREFIX=${2:?}; shift 2 ;;
    --guard)   WITH_GUARD=1; shift ;;
    --systemd) WITH_SYSTEMD=1; shift ;;
    --purge)   PURGE=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1（用 --help 看用法）" >&2; exit 2 ;;
  esac
done
BIN_DIR="${PREFIX}/bin"
# 防手滑：PREFIX 为 / 时 BIN_DIR 是 /bin，下面的 rm -rf 会动系统目录。
case "$BIN_DIR" in
  "/bin"|"/usr/bin"|"/usr/local") die "PREFIX 看起来是系统目录（${BIN_DIR}），拒绝执行" ;;
esac
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/coinbase-agent"
GUARD_DIR="${CB_GUARD_DIR:-/usr/local/bin}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n▶ %s\n' "$*"; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# ---------- 先算清要做什么 ----------
PLAN=()
for f in "$HERE"/scripts/*.sh; do
  [ -f "$f" ] || continue
  [ -f "$BIN_DIR/$(basename "$f")" ] && PLAN+=("$BIN_DIR/$(basename "$f")")
done
[ -d "$BIN_DIR/lib" ] && PLAN+=("$BIN_DIR/lib")
if [ "$WITH_GUARD" -eq 1 ]; then
  PLAN+=("${GUARD_DIR}/coinbase（换成真程序）" "${GUARD_DIR}/coinbase-mcp-proxy.mjs" "$HOME/bin/coinbase-guard")
fi
if [ "$WITH_SYSTEMD" -eq 1 ]; then
  PLAN+=("/etc/systemd/system/coinbase-stack.service")
fi
[ "$PURGE" -eq 1 ] && PLAN+=("${CONF_DIR}（配置 + 账本）")

step "将要撤销"
if [ ${#PLAN[@]} -eq 0 ]; then
  say "  没找到可撤的东西（${BIN_DIR} 下没有本仓库的脚本）"
else
  for x in "${PLAN[@]}"; do say "  - $x"; done
fi
say "  保留：CDP 私钥文件（如果装了）、系统里别处的 coinbase"

if [ "$ASSUME_YES" -eq 0 ] && [ ${#PLAN[@]} -gt 0 ]; then
  printf '\n继续？[y/N] '
  read -r ans </dev/tty
  case "$ans" in y|Y|yes) ;; *) say "已取消"; exit 2 ;; esac
fi

# ---------- 撤脚本 ----------
step "撤销脚本"
# bash 3.2 + set -u 下空数组展开会报错，必须用 ${PLAN[@]+...} 兜住
for x in ${PLAN[@]+"${PLAN[@]}"}; do
  case "$x" in
    "${BIN_DIR}/"*.sh) rm -f "$x"; say "  已删 $(basename "$x")" ;;
  esac
done
if [ -d "$BIN_DIR/lib" ]; then
  rm -rf "${BIN_DIR:?}/lib"
  say "  已删 lib/"
fi

# ---------- 恢复真 coinbase ----------
if [ "$WITH_GUARD" -eq 1 ]; then
  step "恢复 coinbase 真程序"
  REAL="${GUARD_DIR}/coinbase"
  REALJS="${GUARD_DIR}/coinbase-real.js"
  if [ -f "$REAL" ] && grep -q 'CB_GUARD_V1' "$REAL" 2>/dev/null; then
    if [ -f "$REALJS" ]; then
      as_root() { if [ -w "$GUARD_DIR" ]; then "$@"; else sudo "$@"; fi; }
      as_root mv -f "$REALJS" "$REAL"
      as_root rm -f "${GUARD_DIR}/coinbase-mcp-proxy.mjs"
      chmod 755 "$REAL" 2>/dev/null || true
      say "  已恢复 ${REAL}（来自 coinbase-real.js）"
    else
      say "  ⚠ 守卫在，但找不到 coinbase-real.js —— 没动它，请手工重装 CLI：npm i -g @coinbase/coinbase-cli"
    fi
  else
    say "  当前 coinbase 不是守卫，跳过"
  fi
  rm -f "$HOME/bin/coinbase-guard" "$HOME/bin/coinbase-mcp-proxy.mjs"
  say "  已删 \$HOME/bin 下的自愈副本"
fi

# ---------- 停用 systemd ----------
if [ "$WITH_SYSTEMD" -eq 1 ]; then
  step "停用开机自检"
  command -v systemctl >/dev/null || die "这台机器没有 systemd"
  if [ -f /etc/systemd/system/coinbase-stack.service ]; then
    sudo systemctl disable --now coinbase-stack.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/coinbase-stack.service
    sudo systemctl daemon-reload
    say "  已停用并删除 coinbase-stack.service"
  else
    say "  没有这个单元，跳过"
  fi
fi

# ---------- 配置与账本 ----------
if [ "$PURGE" -eq 1 ]; then
  step "删除配置与账本"
  if [ -d "$CONF_DIR" ]; then
    if [ -f "$CONF_DIR/journal.jsonl" ]; then
      arch="$CONF_DIR/journal.jsonl.$(date +%Y%m%d-%H%M%S).archived"
      mv "$CONF_DIR/journal.jsonl" "$arch"
      say "  账本已归档到 ${arch}（审计记录不直接删）"
    fi
    rm -f "$CONF_DIR/config.json" "$CONF_DIR/KILL"
    say "  已删配置"
  else
    say "  没有配置目录，跳过"
  fi
fi

step "完成"
say "  剩下的自己决定："
say "    - ${CONF_DIR}（配置/账本，用 --purge 才会删）"
say "    - CDP 私钥文件（仓库从不碰它）"
exit 0
