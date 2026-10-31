import {
  buildClaudeArgs,
  buildCodexArgs,
  buildAgentEnv,
  initAcc,
  applyEvent,
  parseLine,
} from "../../telegram/lib/agent.mjs";

let pass = 0, fail = 0;
const ok = (m) => { pass++; console.log("  ok   " + m); };
const bad = (m, d) => { fail++; console.log("  FAIL " + m + (d ? "\n       " + d : "")); };
const t = (c, m, d) => { c ? ok(m) : bad(m, d); };

// ---------- 1 claude 参数 ----------
{
  const s = buildClaudeArgs({ model: "deepseek-flash", systemPrompt: "SYS", prompt: "你好" });
  t(s.cmd === "claude", "claude 命令名");
  t(s.args.includes("-p"), "带 -p（非交互）");
  t(s.args.includes("stream-json"), "要 stream-json 输出");
  t(s.args.includes("--include-partial-messages"), "要增量消息");
  t(s.args.includes("--dangerously-skip-permissions"), "跳过权限确认");
  t(s.args[s.args.indexOf("--model") + 1] === "deepseek-flash", "模型正确传递");
  t(s.args[s.args.indexOf("--append-system-prompt") + 1] === "SYS", "系统提示正确传递");
  t(!s.args.includes("--resume"), "没有会话时不加 --resume");
  t(s.stdin === "你好", "prompt 走 stdin");

  const s2 = buildClaudeArgs({ model: "m", systemPrompt: "S", prompt: "p", sessionId: "abc-123" });
  t(s2.args.includes("--resume"), "有会话时加 --resume");
  t(s2.args[s2.args.indexOf("--resume") + 1] === "abc-123", "--resume 带的是会话 id");
}

// ---------- 2 codex 参数 ----------
{
  const s = buildCodexArgs({ model: "deepseek-flash", prompt: "你好" });
  t(s.cmd === "codex", "codex 命令名");
  t(s.args[0] === "exec", "用 exec 子命令");
  t(s.args.includes("--json"), "要 json 输出");
  t(s.args.includes("--skip-git-repo-check"), "跳过 git 仓库检查");
  t(s.args[s.args.length - 1] === "你好", "prompt 是最后一个位置参数");
  t(s.stdin === null, "codex 的 stdin 必须为空（否则会等 EOF 挂死）");
}

// ---------- 3 环境变量 ----------
{
  const e = buildAgentEnv({ model: "deepseek-flash", deepseekKey: "sk-x", baseEnv: {}, home: "/data/home" });
  t(e.ANTHROPIC_BASE_URL === "https://api.deepseek.com/anthropic", "base url 指向 DeepSeek 兼容端点");
  t(e.ANTHROPIC_AUTH_TOKEN === "sk-x", "token 来自参数");
  t(e.ANTHROPIC_MODEL === "deepseek-flash" && e.ANTHROPIC_SMALL_FAST_MODEL === "deepseek-flash", "两个模型变量都设了");
  t(e.DEEPSEEK_API_KEY === "sk-x", "codex 用的 DEEPSEEK_API_KEY 也设了");
  t(e.DISABLE_AUTOUPDATER === "1", "关掉 CLI 自动升级");
  t(e.HOME === "/data/home", "HOME 可覆盖");

  const e2 = buildAgentEnv({ model: "m", deepseekKey: "", baseEnv: { DEEPSEEK_API_KEY: "sk-from-env", PATH: "/bin" }, home: "" });
  t(e2.ANTHROPIC_AUTH_TOKEN === "sk-from-env", "参数没给时回落到环境变量");
  t(e2.PATH === "/bin", "保留原有环境变量");
  t(!("HOME" in e2), "home 为空时不覆盖 HOME");
}

// ---------- 4 parseLine ----------
{
  t(parseLine('{"type":"result"}').type === "result", "能解析合法 JSON");
  t(parseLine("not json") === null, "非 JSON 返回 null");
  t(parseLine("") === null, "空行返回 null");
  t(parseLine("   ") === null, "纯空白返回 null");
  t(parseLine("[1,2]") === null, "数组不是事件，返回 null");
  t(parseLine('{"broken":') === null, "坏 JSON 返回 null 而不是抛错");
  t(parseLine("null") === null, "JSON null 返回 null");
  t(parseLine('  {"a":1}  ').a === 1, "容忍前后空白");
}

// ---------- 5 事件折叠：claude ----------
{
  let st = initAcc();
  let r = applyEvent(st, { type: "system", subtype: "init", session_id: "sid-1" });
  st = r.state;
  t(st.sessionId === "sid-1", "init 事件里取到 session_id");
  t(r.changed === false, "只有 session_id 不算正文变化");

  r = applyEvent(st, { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "你" } } });
  st = r.state;
  t(st.text === "你" && r.changed === true, "text_delta 累积并标记变化");

  r = applyEvent(st, { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "好" } } });
  st = r.state;
  t(st.text === "你好", "连续 delta 拼起来");

  r = applyEvent(st, { type: "stream_event", event: { type: "content_block_delta", delta: { type: "thinking_delta", thinking: "想" } } });
  st = r.state;
  t(st.thinkChars === 1, "thinking 累计字数");
  t(r.changed === false, "thinking 不触发正文刷新（否则会疯狂刷消息）");

  r = applyEvent(st, { type: "result", result: "最终答案", session_id: "sid-2", usage: { input_tokens: 5 } });
  st = r.state;
  t(st.finalResult === "最终答案", "result 里的文本是权威版本");
  t(st.sessionId === "sid-2", "result 里的 session_id 覆盖旧值");
  t(st.usage.input_tokens === 5, "记下 usage");
  t(st.resultError === null, "subtype 缺失或 success 不算错误");

  r = applyEvent(st, { type: "result", subtype: "error_max_turns" });
  t(r.state.resultError === "error_max_turns", "非 success 的 subtype 记为错误");

  r = applyEvent(st, { type: "result", subtype: "error_during_execution", error: "boom" });
  t(r.state.resultError === "error_during_execution: boom", "错误信息带原因");
}

// ---------- 6 事件折叠：codex ----------
{
  let st = initAcc();
  let r = applyEvent(st, { type: "item.completed", item: { type: "agent_message", text: "第一段" } });
  st = r.state;
  t(st.text === "第一段" && r.changed === true, "codex 的 agent_message 整段替换");

  r = applyEvent(st, { type: "item.updated", item: { type: "agent_message", text: "第一段更长" } });
  st = r.state;
  t(st.text === "第一段更长", "变长时替换");

  r = applyEvent(st, { type: "item.updated", item: { type: "agent_message", text: "短" } });
  st = r.state;
  t(st.text === "第一段更长", "变短时不替换（否则屏幕上的字会倒退）");
  t(r.changed === false, "没变化就不刷新");

  r = applyEvent(st, { type: "item.completed", item: { type: "other" } });
  t(r.state.text === "第一段更长", "其它类型的 item 不动正文");

  r = applyEvent(st, { type: "turn.completed", usage: { total_tokens: 9 } });
  t(r.state.usage.total_tokens === 9, "turn.completed 记下 usage");
}

// ---------- 7 纯函数：不改原状态 ----------
{
  const st = initAcc();
  const snapshot = JSON.stringify(st);
  applyEvent(st, { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "X" } } });
  t(JSON.stringify(st) === snapshot, "applyEvent 不修改传入的 state（纯函数）");
}

// ---------- 8 未知事件必须无害 ----------
{
  let st = initAcc();
  for (const ev of [{}, { type: "unknown" }, { type: "stream_event" }, { type: "stream_event", event: { type: "message_start" } }, null]) {
    const r = applyEvent(st, ev || {});
    t(r.changed === false && r.state.text === "", "未知事件 " + JSON.stringify(ev) + " 不改变状态");
    st = r.state;
  }
}

console.log(`  -- ${pass} 通过, ${fail} 失败`);
process.exit(fail ? 1 : 0);
