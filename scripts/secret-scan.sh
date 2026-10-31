#!/usr/bin/env bash
# secret-scan.sh — 确认仓库里（以及**全部历史**里）没有密钥
#
# 为什么连历史一起扫：工作区干净不代表没泄漏过。密钥一旦进过某个 commit，
# 就算下一条提交把它删掉，它仍然躺在 GitHub 上，`git log -p` 一翻就有。
#
# 用法:
#   bash scripts/secret-scan.sh          # 扫工作区 + 全部提交
#   bash scripts/secret-scan.sh --tree   # 只扫工作区（快）
#   bash scripts/secret-scan.sh --json   # 机器可读
#
# 退出码: 0 干净 / 1 命中

set -uo pipefail

# 只匹配"长得像真密钥"的东西，避免误报文档和测试夹具：
#   - sk- 开头的 API key
#   - Telegram bot token（<数字>:AA...）
#   - PEM 私钥：头后面必须紧跟 >=60 字符的 base64 体（只出现头不算 —— 测试夹具会拼这种字符串）
PAT='sk-[A-Za-z0-9]{20,}|[0-9]{9,10}:AA[A-Za-z0-9_-]{30,}|BEGIN [A-Z ]*PRIVATE KEY-----[A-Za-z0-9+/=]{60,}'

MODE="all"; JSON=0
for a in "$@"; do
  case "$a" in
    --tree) MODE="tree" ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '错误: 未知参数 %s\n' "$a" >&2; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { printf '错误: 不在 git 仓库里\n' >&2; exit 2; }

hits_tree=0; hits_hist=0; tree_out=""; hist_out=""

tree_out=$(git grep -nE "$PAT" -- . 2>/dev/null | head -20) || true
[ -n "$tree_out" ] && hits_tree=$(printf '%s\n' "$tree_out" | grep -c . )

if [ "$MODE" = "all" ]; then
  # 遍历所有分支的所有提交内容；排除 .git 自身
  hist_out=$(git log -p --all --no-color -- . 2>/dev/null \
             | grep -nE "$PAT" \
             | grep -vE '^\s*[0-9]+:[-+]{3} ' \
             | head -20) || true
  [ -n "$hist_out" ] && hits_hist=$(printf '%s\n' "$hist_out" | grep -c . )
fi

if [ "$JSON" -eq 1 ]; then
  printf '{"tree_hits":%s,"history_hits":%s}\n' "${hits_tree:-0}" "${hits_hist:-0}"
else
  if [ "${hits_tree:-0}" -eq 0 ]; then
    printf '✓ 工作区干净\n'
  else
    printf '✗ 工作区命中 %s 处：\n%s\n' "$hits_tree" "$tree_out"
  fi
  if [ "$MODE" = "all" ]; then
    if [ "${hits_hist:-0}" -eq 0 ]; then
      printf '✓ 全部历史干净（%s 个提交）\n' "$(git rev-list --all --count)"
    else
      printf '✗ 历史里命中 %s 处（工作区干净也没用，历史能翻出来）：\n%s\n' "$hits_hist" "$hist_out"
      printf '  处理：把这个密钥作废并重新签发，然后用 git filter-repo 重写历史\n'
    fi
  fi
fi

[ "${hits_tree:-0}" -eq 0 ] && [ "${hits_hist:-0}" -eq 0 ] && exit 0
exit 1
