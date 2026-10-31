// telegram/lib/agent.mjs — agent 调用的纯逻辑部分
//
// 这里只放"给定输入算出输出"的东西：参数怎么拼、环境变量怎么给、
// 一行 stream-json 事件怎么折叠进累加器。
// 真正 spawn 进程、写文件、发消息都留在 bot.mjs，方便单独测这些逻辑。

/** 拼 claude 的参数。有 sessionId 就续接会话。 */
export function buildClaudeArgs({ model, systemPrompt, sessionId, prompt }) {
  const args = [
    "-p",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--dangerously-skip-permissions",
    "--append-system-prompt", systemPrompt,
    "--model", model,
  ];
  if (sessionId) args.push("--resume", sessionId);
  return { cmd: "claude", args, stdin: prompt };
}

/** 拼 codex 的参数。prompt 走位置参数，stdin 必须留空（见下方注释）。 */
export function buildCodexArgs({ model, prompt }) {
  const args = ["exec", "--json", "--skip-git-repo-check", "--model", model, prompt];
  return { cmd: "codex", args, stdin: null };
}

/**
 * 子进程的环境变量。
 *
 * 两个必须项：
 * - ANTHROPIC_BASE_URL 指向 DeepSeek 的 anthropic 兼容端点，否则 claude 会去
 *   连 api.anthropic.com 然后因为没有真 key 而 401。
 * - DISABLE_AUTOUPDATER=1：中继器是长驻进程，别让 CLI 自己升级自己。
 */
export function buildAgentEnv({ model, deepseekKey, baseEnv = {}, home }) {
  const key = deepseekKey || baseEnv.DEEPSEEK_API_KEY || "";
  return {
    ...baseEnv,
    ...(home ? { HOME: home } : {}),
    ANTHROPIC_BASE_URL: "https://api.deepseek.com/anthropic",
    ANTHROPIC_AUTH_TOKEN: key,
    ANTHROPIC_MODEL: model,
    ANTHROPIC_SMALL_FAST_MODEL: model,
    DEEPSEEK_API_KEY: key,
    DISABLE_AUTOUPDATER: "1",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
  };
}

/** 累加器的初始状态。 */
export function initAcc() {
  return {
    text: "",
    thinkChars: 0,
    sessionId: null,
    finalResult: null,
    usage: null,
    resultError: null,
  };
}

/** 把一行 stdout 解析成事件对象；解析不了就返回 null。 */
export function parseLine(line) {
  const s = String(line).trim();
  if (!s || s[0] !== "{") return null;
  try {
    const ev = JSON.parse(s);
    // 只接受普通对象：数组、null、标量都不是事件
    return ev && typeof ev === "object" && !Array.isArray(ev) ? ev : null;
  } catch {
    return null;
  }
}

/**
 * 把一个事件折叠进累加器，返回 { state, changed }。
 * changed 表示"正文有变化"，调用方据此决定要不要刷 Telegram 消息 ——
 * thinking 增量不刷新正文，只更新字数提示。
 *
 * 这个函数是纯的：同样的 state + 同样的 ev 一定得到同样的结果。
 */
export function applyEvent(state, ev) {
  const st = { ...state };
  let changed = false;

  // claude 的会话初始化：拿到 session_id 才能续接下一轮
  if (ev.type === "system" && ev.subtype === "init" && ev.session_id) {
    st.sessionId = ev.session_id;
  }

  // claude 的流式增量
  if (ev.type === "stream_event" && ev.event) {
    const e2 = ev.event;
    if (e2.type === "content_block_delta" && e2.delta) {
      if (e2.delta.type === "text_delta") {
        st.text += e2.delta.text || "";
        changed = true;
      } else if (e2.delta.type === "thinking_delta") {
        st.thinkChars += (e2.delta.thinking || "").length;
      }
    }
  }

  // codex 的增量：它给的是整段快照而不是 delta，所以只在变长时替换，
  // 否则会把已经显示的内容缩短。
  if (ev.type === "item.completed" || ev.type === "item.updated") {
    const it = ev.item || {};
    if (it.type === "agent_message" || it.type === "assistant_message") {
      const t = it.text || it.content || "";
      if (t && t.length >= st.text.length) {
        st.text = t;
        changed = true;
      }
    }
  }

  // claude 的收尾：result 里的文本是权威版本
  if (ev.type === "result") {
    if (ev.session_id) st.sessionId = ev.session_id;
    if (typeof ev.result === "string" && ev.result.length) st.finalResult = ev.result;
    if (ev.usage) st.usage = ev.usage;
    if (ev.subtype && ev.subtype !== "success") {
      st.resultError = ev.subtype + (ev.error ? `: ${ev.error}` : "");
    }
  }

  // codex 的收尾
  if (ev.type === "turn.completed" && ev.usage) {
    st.usage = ev.usage;
  }

  return { state: st, changed };
}

/**
 * 系统提示里"查余额要带哪个组合"的那句话。
 *
 * 真实 UUID 不能写进源码（仓库是公开的），但也不能让提示里留个占位符 ——
 * agent 会照着占位符去拼命令，然后 403。所以运行时从共享配置读，
 * 读不到才退回"教它怎么自己查"。
 */
export function portfolioHint(pfx) {
  const id = String(pfx || "").trim();
  if (id) {
    return `Coinbase CLI 已配好（live 环境），这把 API key 只能访问 Agent MPC 组合。`
      + `查余额必须带 portfolio_id：coinbase balance portfolio_id==${id} show_zero==true（不传会 403）。`;
  }
  return "Coinbase CLI 已配好（live 环境），但这把 API key 只能访问某一个组合，"
    + "查余额必须带 portfolio_id。先用 cb-portfolio.sh --show 查出组合 UUID，"
    + "再用 coinbase balance portfolio_id==<那串 UUID>（不传会 403）。";
}
