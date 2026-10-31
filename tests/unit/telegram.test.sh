#!/usr/bin/env bash
# Telegram 中继器的纯函数：切块、转义
. "$(dirname "$0")/../helper.sh"
setup

echo "text.mjs 纯函数"
if node "$ROOT/tests/unit/text.node.mjs"; then
  ok "text.node.mjs 全部通过"
else
  bad "text.node.mjs 有失败"
fi

echo "语法检查"
for f in "$ROOT"/telegram/*.mjs "$ROOT"/telegram/lib/*.mjs; do
  [ -f "$f" ] || continue
  if node --check "$f" 2>/dev/null; then ok "$(basename "$f") 语法正确"; else bad "$(basename "$f") 语法错误"; fi
done

echo "切块上限必须低于 Telegram 的 4096"
node -e '
import("file://'"$ROOT"'/telegram/lib/text.mjs").then(m=>{
  const okMax = m.SAFE_BUDGET < m.MAX_TG && m.SAFE_BUDGET > 3000;
  console.log(okMax ? "OK" : "BAD " + m.SAFE_BUDGET);
})' > "$TESTDIR/max.txt"
assert_eq "$(cat "$TESTDIR/max.txt")" "OK" "SAFE_BUDGET 留有余量"

finish
