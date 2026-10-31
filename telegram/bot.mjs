#!/usr/bin/env node
/**
 * Telegram ⇄ Agent CLI 中继器
 * 后端: claude (Claude Code) 或 codex，模型走 DeepSeek 兼容端点
 * 特性: 流式增量渲染 / 中文命令 / MCP / skills / 会话续接
 */

import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { esc, splitChunks, splitHtml } from "./lib/text.mjs";
import {
  buildClaudeArgs as libClaudeArgs,
  buildCodexArgs as libCodexArgs,
  buildAgentEnv,
  portfolioHint,
  initAcc,
  applyEvent,
  parseLine,
} from "./lib/agent.mjs";

const DIR = "/data/home/tg-agent";
const CONFIG_PATH = join(DIR, "config.json");
const STATE_PATH = join(DIR, "state.json");
const CFG = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));

const TOKEN = CFG.token;
const ALLOWED = new Set((CFG.allowed_chat_ids || []).map(String));
const API = `https://api.telegram.org/bot${TOKEN}`;

const DEFAULT_BACKEND = CFG.backend || "claude";
const DEFAULT_MODEL = CFG.model || "deepseek-flash";
const MODELS = CFG.models || ["deepseek-flash", "deepseek-v4-pro"];
const WORKDIR = CFG.workdir || "/data/home";
const EDIT_MS = CFG.edit_interval_ms || 1200;
const MAX_TG = 3900;

// 组合 UUID 从共享配置读（仓库是公开的，不能把真实 UUID 写进源码）
function readPortfolioId() {
  try {
    const p = process.env.CB_CONFIG
      || join(process.env.HOME || "/data/home", ".config/coinbase-agent/config.json");
    return JSON.parse(readFileSync(p, "utf8")).portfolio_id || "";
  } catch {
    return "";
  }
}

const SYSTEM_PROMPT = [
  "你是一个通过 Telegram 与用户对话的智能助手，运行在这台 Linux 服务器上。",
  "始终使用简体中文回答。代码、命令、文件路径、专有名词保持原文。",
  "回答要简洁、适合手机屏幕阅读：多用短段落，避免大表格和超长行。",
  "你可以使用已配置的 MCP 工具和 skills 完成任务；需要时直接调用，不要问用户要不要调。",
  "如果任务需要较多步骤，先说一句你要做什么，然后直接做。",
  portfolioHint(readPortfolioId()),
  "本机有 IPv6 出口，而 Coinbase 门户白名单只放行了 IPv4 203.0.113.10；所有 Node 进程需带 NODE_OPTIONS=--dns-result-order=ipv4first。该变量已写入系统环境，若某处仍报 401，先确认它在生效。",
].join("\n");

// ---------- 状态 ----------
mkdirSync(DIR, { recursive: true });
let state = { sessions: {}, chats: {} };
if (existsSync(STATE_PATH)) {
  try { state = JSON.parse(readFileSync(STATE_PATH, "utf8")); } catch { /* 忽略损坏状态 */ }
}
let saveTimer = null;
function saveState() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try { writeFileSync(STATE_PATH, JSON.stringify(state, null, 2)); } catch (e) { log(`状态写入失败: ${e.message}`); }
  }, 400);
}

function chatState(chatId) {
  const id = String(chatId);
  if (!state.chats[id]) state.chats[id] = { backend: DEFAULT_BACKEND, model: DEFAULT_MODEL };
  const c = state.chats[id];
  if (!c.backend) c.backend = DEFAULT_BACKEND;
  if (!c.model) c.model = DEFAULT_MODEL;
  return c;
}
function sessionKey(chatId) {
  const c = chatState(chatId);
  return `${chatId}:${c.backend}:${c.model}`;
}
function getSession(chatId) { return state.sessions[sessionKey(chatId)] || null; }
function setSession(chatId, sid) {
  if (sid) state.sessions[sessionKey(chatId)] = sid;
  else delete state.sessions[sessionKey(chatId)];
  saveState();
}

// ---------- 工具 ----------
function log(msg) { console.log(`[${new Date().toISOString()}] ${msg}`); }

async function tg(method, payload, { silent = false } = {}) {
  const r = await fetch(`${API}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  const j = await r.json().catch(() => ({ ok: false, description: "响应不是 JSON" }));
  if (!j.ok) {
    const d = String(j.description || "");
    if (d.includes("message is not modified")) return null;
    if (!silent) throw new Error(`${method} 失败: ${j.error_code} ${d}`);
    return null;
  }
  return j.result;
}

// 切块与转义已抽到 lib/text.mjs（可按转义后长度切，且不切断实体/emoji）

// ---------- 命令定义（中文） ----------
const COMMANDS = [
  { command: "start", description: "开始使用 / 查看介绍" },
  { command: "help", description: "显示全部命令说明" },
  { command: "new", description: "开启新会话（清空上下文）" },
  { command: "status", description: "查看当前后端、模型、会话状态" },
  { command: "stop", description: "中断正在生成的回答" },
  { command: "model", description: "查看或切换模型（如 /model deepseek-v4-pro）" },
  { command: "backend", description: "切换后端 claude / codex" },
  { command: "skills", description: "列出已安装的 skills" },
  { command: "mcp", description: "查看 MCP 服务器连接状态" },
  { command: "id", description: "显示当前 chat id" },
];

const HELP_TEXT = () => [
  "<b>🤖 服务器 Agent 中继器</b>",
  "",
  "直接发消息就是跟 agent 对话，回答会流式逐字出现在同一条消息里。",
  "",
  "<b>命令</b>",
  ...COMMANDS.map((c) => `/${c.command} — ${c.description}`),
  "",
  "<b>当前状态</b>",
  `后端 <code>${chatState(currentChatId).backend}</code> · 模型 <code>${chatState(currentChatId).model}</code>`,
  "",
  "支持 MCP 工具与 skills，可以读写文件、跑命令、查资料。",
].join("\n");

// ---------- Agent 调用 ----------
const running = new Map(); // chatId -> { child, startedAt }

function killRun(chatId) {
  const r = running.get(String(chatId));
  if (!r) return false;
  try { r.child.kill("SIGKILL"); } catch { /* 已退出 */ }
  running.delete(String(chatId));
  return true;
}

// 参数拼装与事件折叠在 lib/agent.mjs 里（纯逻辑，可单测）。
// 这里只负责把会话状态喂进去。
function buildClaudeArgs(chatId, prompt) {
  const c = chatState(chatId);
  return libClaudeArgs({
    model: c.model,
    systemPrompt: SYSTEM_PROMPT,
    sessionId: getSession(chatId),
    prompt,
  });
}

function buildCodexArgs(chatId, prompt) {
  const c = chatState(chatId);
  return libCodexArgs({ model: c.model, prompt });
}

function spawnAgent(chatId, prompt, onDelta, onThinking) {
  const c = chatState(chatId);
  const spec = c.backend === "codex" ? buildCodexArgs(chatId, prompt) : buildClaudeArgs(chatId, prompt);

  const env = buildAgentEnv({
    model: c.model,
    deepseekKey: CFG.deepseek_key,
    baseEnv: process.env,
    home: "/data/home",
  });

  return new Promise((resolve) => {
    const child = spawn(spec.cmd, spec.args, { cwd: WORKDIR, env, stdio: ["pipe", "pipe", "pipe"] });
    running.set(String(chatId), { child, startedAt: Date.now() });
    const maxMs = CFG.max_run_ms || 900000;
    const hardTimer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch { /* 已退出 */ }
      errOut += `\n超过最大运行时长 ${Math.round(maxMs / 1000)}s，已强制结束。`;
    }, maxMs);
    child.on("close", () => clearTimeout(hardTimer));

    let acc = initAcc();
    let errOut = "";
    let buf = "";
    let killed = false;

    child.on("error", (e) => {
      errOut += `spawn 错误: ${e.message}\n`;
    });

    child.stdout.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let idx;
      while ((idx = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        const ev = parseLine(line);
        if (!ev) continue;
        const { state, changed } = applyEvent(acc, ev);
        const beforeThink = acc.thinkChars;
        acc = state;
        if (changed) onDelta(acc.text);
        if (acc.thinkChars !== beforeThink && onThinking) onThinking(acc.thinkChars);
      }
    });

    child.stderr.on("data", (c) => { errOut += c.toString("utf8"); });

    const finish = (code, signal) => {
      running.delete(String(chatId));
      if (acc.sessionId) setSession(chatId, acc.sessionId);
      const text = (acc.finalResult || acc.text || "").trim();
      resolve({
        ok: !killed && !acc.resultError,
        text,
        code,
        signal,
        killed,
        errOut: errOut.trim(),
        sessionId: acc.sessionId,
        usage: acc.usage,
        resultError: acc.resultError,
      });
    };

    child.on("close", (code, signal) => finish(code, signal));

    const origKill = killRun;
    // 让 /stop 能标记 killed
    const tracker = running.get(String(chatId));
    if (tracker) {
      tracker.markKilled = () => { killed = true; };
      tracker.resolveIfNeeded = () => {};
    }

    if (spec.stdin !== null && spec.stdin !== undefined) child.stdin.write(spec.stdin);
    child.stdin.end();  // 必须关闭：否则 codex 会一直等 stdin EOF
  });
}

// 让 /stop 同时标记 killed 标志
const _origKillRun = killRun;
function stopRun(chatId) {
  const r = running.get(String(chatId));
  if (!r) return false;
  if (typeof r.markKilled === "function") r.markKilled();
  try { r.child.kill("SIGKILL"); } catch { /* 已退出 */ }
  return true;
}

// ---------- 单次对话处理 ----------
let currentChatId = null;
const queue = [];
let busy = false;

async function handlePrompt(chatId, prompt, messageId) {
  const c = chatState(chatId);
  // 占位消息
  let streamingMsg = null;
  try {
    streamingMsg = await tg("sendMessage", {
      chat_id: chatId,
      text: "▌",
      disable_notification: true,
    });
  } catch (e) {
    log(`占位消息失败: ${e.message}`);
  }

  let lastEdit = 0;
  let deltaCount = 0;
  let thinkCount = 0;
  let editCount = 0;
  let lastSent = "";
  let editTimer = null;
  let pendingText = null;
  let inflight = null;

  const renderStreaming = (acc) => {
    let t = acc;
    if (t.length > MAX_TG) t = "…" + t.slice(-MAX_TG + 20);
    return `<pre>${esc(t)}</pre>▌`;
  };

  const renderThinking = (n) => `💭 思考中…（${n} 字）`;

  const dbg = (m) => { if (process.env.TG_DEBUG === "1") log(`dbg ${m}`); };

  const doEdit = async () => {
    if (!streamingMsg) { dbg("早期返回: streamingMsg 为空"); return; }
    const text = pendingText;
    if (text === null) { dbg("早期返回: pendingText 为 null"); return; }
    if (text === lastSent) { dbg("早期返回: 文本未变化"); return; }
    lastSent = text;
    lastEdit = Date.now();
    try {
      inflight = tg("editMessageText", { chat_id: chatId, message_id: streamingMsg.message_id, text, parse_mode: "HTML" }, { silent: true });
      await inflight;
      editCount++;
    } catch (e) { dbg(`编辑抛错: ${e.message}`); } finally { inflight = null; }
  };

  const scheduleEdit = () => {
    const now = Date.now();
    if (now - lastEdit >= EDIT_MS) {
      doEdit();
    } else if (!editTimer) {
      editTimer = setTimeout(() => { editTimer = null; doEdit(); }, EDIT_MS - (now - lastEdit));
    }
  };

  const onDelta = (acc) => {
    deltaCount++;
    pendingText = renderStreaming(acc);
    scheduleEdit();
  };

  const onThinking = (n) => {
    thinkCount = n;
    if (!deltaCount) { pendingText = renderThinking(n); scheduleEdit(); }
  };

  const started = Date.now();
  const typingTimer = setInterval(() => {
    tg("sendChatAction", { chat_id: chatId, action: "typing" }, { silent: true }).catch(() => {});
  }, 4500);
  const res = await spawnAgent(chatId, prompt, onDelta, onThinking);
  clearInterval(typingTimer);
  if (editTimer) { clearTimeout(editTimer); editTimer = null; }
  if (inflight) { try { await inflight; } catch { /* 忽略 */ } }

  const elapsed = ((Date.now() - started) / 1000).toFixed(1);
  log(`完成 chat=${chatId} 用时=${elapsed}s 增量=${deltaCount}次 编辑=${editCount}次 字数=${(res.text || "").length}`);

  // 收尾：删占位消息，发最终内容
  if (streamingMsg) {
    try { await tg("deleteMessage", { chat_id: chatId, message_id: streamingMsg.message_id }, { silent: true }); } catch { /* 忽略 */ }
  }

  if (res.killed) {
    await sendText(chatId, "⏹ 已中断（/stop）");
    return;
  }
  if (!res.text) {
    const why = res.resultError || res.errOut || "没有返回内容";
    await sendText(chatId, `⚠️ 生成失败：\n<pre>${esc(why.slice(0, 1200))}</pre>`);
    return;
  }

  const footer = [];
  if (res.usage) {
    const i = res.usage.input_tokens ?? res.usage.prompt_tokens;
    const o = res.usage.output_tokens ?? res.usage.completion_tokens;
    if (i != null || o != null) footer.push(`↑${i ?? "?"} ↓${o ?? "?"}`);
  }
  footer.push(`${elapsed}s`);

  const htmlChunks = splitHtml(res.text);
  const rawChunks = splitChunks(res.text);
  for (let i = 0; i < htmlChunks.length; i++) {
    const isLast = i === htmlChunks.length - 1;
    const body = `<pre>${htmlChunks[i]}</pre>` + (isLast ? `\n<i>${footer.join(" · ")}</i>` : "");
    const sent = await trySendHtml(chatId, body);
    if (!sent) {
      // HTML 被拒（极少见）就退回纯文本，内容不能丢
      const text = rawChunks[i] ?? "";
      if (text) await sendText(chatId, text);
    }
  }
}

async function trySendHtml(chatId, html) {
  try {
    const r = await fetch(`${API}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text: html, parse_mode: "HTML" }),
    });
    const j = await r.json();
    if (j.ok) return true;
    return false;
  } catch {
    return false;
  }
}

async function sendText(chatId, text, parseMode) {
  const chunks = splitChunks(text);
  for (const c of chunks) {
    const payload = { chat_id: chatId, text: c };
    if (parseMode) payload.parse_mode = parseMode;
    await tg("sendMessage", payload, { silent: true });
  }
}

// ---------- 命令实现 ----------
async function cmdStart(chatId) {
  currentChatId = chatId;
  await sendText(chatId, HELP_TEXT(), "HTML");
}

async function cmdStatus(chatId) {
  const c = chatState(chatId);
  const sid = getSession(chatId);
  const r = running.get(String(chatId));
  const lines = [
    "<b>📊 当前状态</b>",
    `后端：<code>${c.backend}</code>`,
    `模型：<code>${c.model}</code>`,
    `工作目录：<code>${WORKDIR}</code>`,
    `会话：${sid ? `<code>${sid.slice(0, 8)}…</code>（续接中）` : "新会话"}`,
    `运行中：${r ? `是（${((Date.now() - r.startedAt) / 1000).toFixed(0)}s）` : "否"}`,
    "",
    "改动用 /new 清空上下文，用 /model 或 /backend 切换。",
  ];
  await sendText(chatId, lines.join("\n"), "HTML");
}

async function cmdModel(chatId, arg) {
  const c = chatState(chatId);
  if (!arg) {
    await sendText(chatId, [
      "<b>🧠 模型</b>",
      ...MODELS.map((m) => `${m === c.model ? "●" : "○"} <code>${m}</code>`),
      "",
      "切换：<code>/model deepseek-v4-pro</code>",
    ].join("\n"), "HTML");
    return;
  }
  if (!MODELS.includes(arg)) {
    await sendText(chatId, `不支持 <code>${esc(arg)}</code>。可选：${MODELS.map((m) => `<code>${m}</code>`).join("、")}`, "HTML");
    return;
  }
  c.model = arg;
  saveState();
  await sendText(chatId, `✅ 模型已切到 <code>${arg}</code>（新会话上下文，因为不同模型的会话不通用）`, "HTML");
}

async function cmdBackend(chatId, arg) {
  const c = chatState(chatId);
  if (!arg) {
    await sendText(chatId, `<b>⚙️ 后端</b>\n${["claude", "codex"].map((b) => `${b === c.backend ? "●" : "○"} <code>${b}</code>`).join("\n")}\n\n切换：<code>/backend codex</code>`, "HTML");
    return;
  }
  if (!["claude", "codex"].includes(arg)) {
    await sendText(chatId, "只能选 <code>claude</code> 或 <code>codex</code>", "HTML");
    return;
  }
  c.backend = arg;
  saveState();
  await sendText(chatId, `✅ 后端已切到 <code>${arg}</code>`, "HTML");
}

async function cmdSkills(chatId) {
  const dirs = ["/data/home/.claude/skills", "/data/home/.codex/skills"];
  const found = {};
  for (const d of dirs) {
    if (!existsSync(d)) continue;
    for (const name of readdirSync(d, { withFileTypes: true })) {
      if (name.isDirectory()) found[name.name] = true;
    }
  }
  const list = Object.keys(found).sort();
  if (!list.length) { await sendText(chatId, "没有找到已安装的 skills"); return; }
  await sendText(chatId, [
    `<b>🧩 已安装 skills（${list.length}）</b>`,
    ...list.map((s) => `• <code>${esc(s)}</code>`),
    "",
    "直接说要做什么，agent 会自己选对应的 skill。",
  ].join("\n"), "HTML");
}

async function cmdMcp(chatId) {
  await sendText(chatId, "⏳ 正在检查 MCP …");
  const out = await new Promise((resolve) => {
    const p = spawn("claude", ["mcp", "list"], { cwd: WORKDIR, env: { ...process.env, HOME: "/data/home" } });
    let s = "";
    p.stdout.on("data", (d) => { s += d; });
    p.stderr.on("data", (d) => { s += d; });
    p.on("close", () => resolve(s.trim()));
    setTimeout(() => { try { p.kill("SIGKILL"); } catch { /* */ } resolve(s.trim() || "检查超时"); }, 20000);
  });
  await sendText(chatId, `<b>🔌 MCP 服务器</b>\n<pre>${esc(out.slice(0, 3000))}</pre>`, "HTML");
}

// ---------- 文件接收 ----------
async function handleUpload(chatId, msg) {
  let fileId = null, name = null, size = 0;
  if (msg.document) {
    fileId = msg.document.file_id;
    name = msg.document.file_name || "file";
    size = msg.document.file_size || 0;
  } else if (msg.photo) {
    const p = msg.photo[msg.photo.length - 1];
    fileId = p.file_id; name = "photo.jpg"; size = p.file_size || 0;
  } else {
    const o = msg.audio || msg.voice || msg.video;
    fileId = o.file_id; name = o.file_name || "media"; size = o.file_size || 0;
  }
  if (size > 20 * 1024 * 1024) {
    return sendText(chatId, "\u26d4 文件超过 20 MB，Telegram 机器人下载上限。");
  }
  await sendText(chatId, "\ud83d\udce5 正在接收文件\u2026");
  try {
    const r = await tg("getFile", { file_id: fileId });
    const fp = r.result && r.result.file_path;
    if (!fp) throw new Error("getFile 未返回 file_path");
    const resp = await fetch("https://api.telegram.org/file/bot" + TOKEN + "/" + fp);
    if (!resp.ok) throw new Error("下载失败 HTTP " + resp.status);
    const buf = Buffer.from(await resp.arrayBuffer());
    const dir = join(DIR, "uploads");
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
    const safe = String(name).replace(/[^A-Za-z0-9._-]+/g, "_").slice(-80) || "file";
    const dest = join(dir, Date.now() + "-" + safe);
    writeFileSync(dest, buf, { mode: 0o600 });
    log("已接收文件 " + dest + " (" + buf.length + " 字节)");
    await sendText(chatId, "\u2705 已存到盒子\n<code>" + esc(dest) + "</code>\n" + buf.length + " 字节\n\n现在可以直接说：用这个文件配置 Coinbase。", "HTML");
  } catch (e) {
    log("接收文件失败: " + e.message);
    await sendText(chatId, "\u274c 接收失败：" + esc(e.message), "HTML");
  }
}

// ---------- 更新处理 ----------
async function handleUpdate(u) {
  const msg = u.message;
  if (!msg || !msg.chat) return;
  const chatId = msg.chat.id;
  const fromId = msg.from && msg.from.id;
  currentChatId = chatId;

  if (!ALLOWED.size || !(ALLOWED.has(String(chatId)) || ALLOWED.has(String(fromId)))) {
    log(`拒绝未授权 chat_id=${chatId} from=${fromId}`);
    await sendText(chatId, `⛔ 未授权的对话。\n\n你的 chat id：<code>${chatId}</code>\n把它加进白名单后才能使用。`, "HTML");
    return;
  }

  const text = (msg.text || msg.caption || "").trim();

  if (msg.document || msg.photo || msg.audio || msg.voice || msg.video) {
    return handleUpload(chatId, msg);
  }
  if (!text) return;

  if (text.startsWith("/")) {
    const [rawCmd, ...rest] = text.split(/\s+/);
    const cmd = rawCmd.slice(1).split("@")[0];
    const arg = rest.join(" ").trim();
    switch (cmd) {
      case "start": return cmdStart(chatId);
      case "help": return cmdStart(chatId);
      case "new": {
        setSession(chatId, null);
        return sendText(chatId, "🆕 已开启新会话，之前的上下文不再带入。");
      }
      case "status": return cmdStatus(chatId);
      case "stop": {
        const ok = stopRun(chatId);
        return sendText(chatId, ok ? "⏹ 已发送中断信号" : "当前没有正在生成的任务");
      }
      case "model": return cmdModel(chatId, arg);
      case "backend": return cmdBackend(chatId, arg);
      case "skills": return cmdSkills(chatId);
      case "mcp": return cmdMcp(chatId);
      case "id": return sendText(chatId, `chat id：<code>${chatId}</code>`, "HTML");
      default:
        return sendText(chatId, `未知命令 <code>/${esc(cmd)}</code>，发 /help 看全部命令。`, "HTML");
    }
  }

  queue.push({ chatId, prompt: text, messageId: msg.message_id });
  pump();
}

async function pump() {
  if (busy) return;
  busy = true;
  try {
    while (queue.length) {
      const job = queue.shift();
      try {
        await tg("sendChatAction", { chat_id: job.chatId, action: "typing" }, { silent: true });
        await handlePrompt(job.chatId, job.prompt, job.messageId);
      } catch (e) {
        log(`处理失败: ${e.stack || e.message}`);
        await sendText(job.chatId, `⚠️ 出错：${esc(e.message)}`, "HTML");
      }
    }
  } finally {
    busy = false;
  }
}

// ---------- 主循环 ----------
let offset = 0;
let stopping = false;

async function main() {
  log("启动中…");
  try {
    await tg("deleteWebhook", { drop_pending_updates: false }, { silent: true });
    await tg("setMyCommands", { commands: COMMANDS }, { silent: true });
    const me = await tg("getMe");
    log(`已连接 bot @${me.username} (${me.first_name})`);
  } catch (e) {
    log(`初始化失败: ${e.message}`);
  }

  process.on("SIGTERM", () => { stopping = true; log("收到 SIGTERM，退出"); process.exit(0); });
  process.on("SIGINT", () => { stopping = true; process.exit(0); });

  while (!stopping) {
    let updates = [];
    try {
      updates = await tg("getUpdates", { offset, timeout: 50, allowed_updates: ["message"] }, { silent: true }) || [];
    } catch (e) {
      log(`轮询异常: ${e.message}，3 秒后重试`);
      await new Promise((r) => setTimeout(r, 3000));
      continue;
    }
    for (const u of updates) {
      offset = u.update_id + 1;
      handleUpdate(u).catch((e) => log(`更新处理异常: ${e.message}`));
    }
  }
}

// 自检模式：跑一次真实的 agent 调用，不碰 Telegram、不写会话状态。
// 用途：改完代码部署后确认"agent 这条路还是通的"，不用真发一条消息给用户。
if (process.argv.includes("--selftest")) {
  const i = process.argv.indexOf("--selftest");
  const prompt = process.argv[i + 1] || "用一句话说明你能做什么。";
  let last = "";
  spawnAgent("selftest", prompt, (t) => { last = t; }, () => {})
    .then((r) => {
      log(`自检: ok=${r.ok} code=${r.code} 增量长度=${last.length} 会话=${r.sessionId || "无"}`);
      if (r.resultError) log(`自检: 错误 ${r.resultError}`);
      console.log("--- 回复 ---");
      console.log(r.text || "(空)");
      process.exit(r.ok ? 0 : 1);
    })
    .catch((e) => { log(`自检异常: ${e.message}`); process.exit(1); });
} else if (process.env.TG_BOT_NO_POLL !== "1") {
  main();
}

// 导出给自检/测试用
export { handleUpdate, handlePrompt, COMMANDS, spawnAgent };
