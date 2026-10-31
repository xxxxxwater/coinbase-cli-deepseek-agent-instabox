#!/usr/bin/env bash
# run.sh — 跑全部单元测试。make test / CI 都走这里。
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

failed=0; files=0
for t in tests/unit/*.test.sh; do
  [ -f "$t" ] || continue
  files=$((files+1))
  printf '\n▶ %s\n' "${t#tests/unit/}"
  if bash "$t"; then :; else
    printf '  ✗ 本文件有失败项\n'
    failed=$((failed+1))
  fi
done

printf '\n============================================\n'
if [ "$failed" -eq 0 ]; then
  printf '全部通过（%d 个测试文件）\n' "$files"
  exit 0
fi
printf '%d 个测试文件有失败\n' "$failed"
exit 1
