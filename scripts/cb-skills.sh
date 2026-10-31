#!/usr/bin/env bash
# cb-skills.sh — 管 Coinbase 的 agent skills（claude 与 codex 两侧）
#
# 为什么要单独一个脚本：skills 是 `coinbase skills add --dir <dir>` 从 CLI 包里
# 拷过去的，`npm i -g` 升级、换 node、甚至把入口文件挪个位置都可能让它们悄悄消失。
# 而"没有 skill"的表现是 agent 不知道有这些能力 —— 不报错，只是变笨。
#
# 用法:
#   cb-skills.sh            # 列出侧栏目录里的 skills 与安装状态（默认 verify）
#   cb-skills.sh list       # 同上
#   cb-skills.sh verify     # 只检查，缺一个就退出码 1（可接自检/CI）
#   cb-skills.sh sync       # 重新从 CLI 包安装到 claude 与 codex 两个目录
#   cb-skills.sh --dir <路径>  # 指定目标目录（默认 ~/.claude/skills 与 ~/.codex/skills）
#
# 退出码: 0 正常 / 1 verify 失败（有缺失） / 2 用法错 / 3 CLI 不可用

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^#/ { exit }' "$0"; }

CMD="verify"
EXTRA_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    list|verify|sync) CMD=$1; shift ;;
    --dir) [ $# -ge 2 ] || { printf '错误: --dir 需要一个路径\n' >&2; exit 2; }; EXTRA_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '错误: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
  esac
done

cb_need coinbase

# 默认两侧都看：claude 用 ~/.claude/skills，codex 用 ~/.codex/skills
DIRS=""
if [ -n "$EXTRA_DIR" ]; then
  DIRS="$EXTRA_DIR"
else
  [ -d "${HOME}/.claude/skills" ] || [ -d "${HOME}/.claude" ] && DIRS="${DIRS} ${HOME}/.claude/skills"
  [ -d "${HOME}/.codex/skills" ] || [ -d "${HOME}/.codex" ] && DIRS="${DIRS} ${HOME}/.codex/skills"
  [ -z "${DIRS// /}" ] && DIRS="${HOME}/.claude/skills ${HOME}/.codex/skills"
fi

# 包里的权威列表：`coinbase skills list` 会打印名字、是否已安装、描述。
# 注意：这个命令**依赖入口脚本的位置**（CLI 用 import.meta.url 找捆绑的 skills/）。
# 如果入口被复制到别处，它会打印 "No bundled skills found." —— 那是谎报，不是没装。
bundled_raw=$(cb_timeout 60 coinbase skills list 2>&1)
if printf '%s' "$bundled_raw" | grep -qi 'No bundled skills found'; then
  cb_bad "CLI 说找不到捆绑的 skills —— 这不是'没装'，而是入口脚本不在包里了"
  cb_dim "  原因：CLI 按 import.meta.url 解析 skills/ 目录；把 dist/index.js 复制到" >&2
  cb_dim "        /usr/local/bin 之后它会去找 /usr/local/bin/skills。" >&2
  cb_dim "  解法：让 /usr/local/bin/coinbase 的守卫指向包里的原始入口（见 docs/GUARD.md），" >&2
  cb_dim "        或直接跑 node \$(npm root -g)/@coinbase/coinbase-cli/dist/index.js skills list" >&2
  exit 3
fi

NAMES=$(printf '%s' "$bundled_raw" | awk 'NR>2 && $1 ~ /^coinbase/ { print $1 }')
if [ -z "$NAMES" ]; then
  cb_bad "没能从 \`coinbase skills list\` 解析出任何 skill 名"
  printf '%s\n' "$bundled_raw" | head -5 >&2
  exit 3
fi
WANT=$(printf '%s\n' "$NAMES" | wc -l | tr -d ' ')

if [ "$CMD" = "sync" ]; then
  for d in $DIRS; do
    mkdir -p "$d"
    out=$(cb_timeout 120 coinbase skills add --dir "$d" 2>&1)
    printf '%s\n' "$out" | tail -2
    cb_ok "已同步到 ${d}"
  done
  CMD="verify"
fi

missing_total=0
cb_hr
printf '包内共 %s 个 skill\n' "$WANT"
cb_hr
for d in $DIRS; do
  printf '%s:\n' "$d"
  miss=0
  for n in $NAMES; do
    if [ -f "${d}/${n}/SKILL.md" ]; then
      printf '  ✓ %s\n' "$n"
    else
      printf '  ✗ %s\n' "$n"
      miss=$((miss + 1))
    fi
  done
  if [ "$miss" -eq 0 ]; then
    cb_ok "  ${WANT}/${WANT} 齐全"
  else
    cb_bad "  缺 ${miss} 个 —— 修：$0 sync"
  fi
  missing_total=$((missing_total + miss))
done
cb_hr

if [ "$CMD" = "verify" ] && [ "$missing_total" -gt 0 ]; then
  exit 1
fi
exit 0
