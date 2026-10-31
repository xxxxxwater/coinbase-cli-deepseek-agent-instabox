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

echo "agent.mjs 纯逻辑（参数拼装 / 事件折叠）"
if node "$ROOT/tests/unit/agent.node.mjs"; then
  ok "agent.node.mjs 全部通过"
else
  bad "agent.node.mjs 有失败"
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

echo "命令表：每条都要能在 handleUpdate 里分派到"
node -e '
const src = require("fs").readFileSync(process.argv[1], "utf8");
const listed = [...src.matchAll(/\{ command: "([a-z]+)", description:/g)].map(m => m[1]);
const dispatched = new Set([...src.matchAll(/case "([a-z]+)":/g)].map(m => m[1]));
const missing = listed.filter(c => !dispatched.has(c));
if (!listed.length) { console.log("BAD 没解析到任何命令"); process.exit(0); }
if (missing.length) { console.log("BAD 列了但没实现: " + missing.join(",")); process.exit(0); }
console.log("OK " + listed.length);
' "$ROOT/telegram/bot.mjs" > "$TESTDIR/cmds.txt"
IFS=" " read -r _verdict _count < "$TESTDIR/cmds.txt"
assert_eq "$_verdict" "OK" "每个注册的命令都有分派分支（共 $_count 条）"

echo "命令不硬编码 /data/home（换台机器也要能跑）"
assert_not_contains "$(grep -nE 'HOME: "/|cwd: "/' "$ROOT/telegram/bot.mjs" || true)" 'HOME: "/' "HOME 不硬编码（从环境变量取）"

finish
