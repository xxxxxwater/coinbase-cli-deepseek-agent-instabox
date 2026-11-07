// Offline integration regression: fake CLI processes, fake Telegram, isolated state.
import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "tg-session-"));
const savedEnv = { ...process.env };
const originalSpawn = childProcess.spawn;
const originalFetch = globalThis.fetch;
const children = [];
process.env.HOME = dir;
process.env.TG_AGENT_DIR = dir;
process.env.TG_BOT_NO_POLL = "1";
process.env.CB_CONFIG = join(dir, "missing-config.json");
writeFileSync(join(dir, "config.json"), JSON.stringify({
  token: "offline", allowed_chat_ids: [1, 2, 3, 4, 5, 6],
  workdir: dir, max_run_ms: 5000,
}));
childProcess.spawn = (cmd, args) => {
  assert.ok(["claude", "codex"].includes(cmd));
  const child = new EventEmitter();
  Object.assign(child, { stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(), cmd, args });
  child.kill = () => child.emit("close", null, "SIGKILL");
  children.push(child);
  return child;
};
syncBuiltinESMExports();
globalThis.fetch = async () => ({ json: async () => ({ ok: true, result: { message_id: 1 } }) });

let failures = 0;
try {
  const { spawnAgent, handleUpdate } = await import("../../telegram/bot.mjs");
  const command = (id, text) => handleUpdate({ message: { chat: { id }, from: { id }, text } });
  function start(id, sid) {
    const promise = spawnAgent(id, "offline prompt", () => {});
    const child = children.at(-1);
    child.stdout.write(JSON.stringify({ type: "system", subtype: "init", session_id: sid }) + "\n");
    return { child, promise };
  }
  async function finish(run, sid) {
    if (sid) run.child.stdout.write(JSON.stringify({ type: "result", subtype: "success", session_id: sid, result: "done" }) + "\n");
    run.child.emit("close", 0, null);
    await run.promise;
  }
  function resume(run) {
    const i = run.child.args.indexOf("--resume");
    return i < 0 ? null : run.child.args[i + 1];
  }
  async function check(name, fn) {
    try { await fn(); console.log("ok " + name); }
    catch (err) { failures++; console.error("FAIL " + name + ": " + err.message); }
  }

  await check("normal completion resumes its session", async () => {
    await finish(start(1, "normal-session"));
    const next = start(1, "normal-next");
    const actual = resume(next);
    await finish(next);
    assert.equal(actual, "normal-session");
  });
  await check("/new on an initially empty slot invalidates an in-flight init/result", async () => {
    const old = start(2, "old-session");
    await command(2, "/new");
    await finish(old, "old-session");
    const next = start(2, "new-session");
    const actual = resume(next);
    await finish(next);
    assert.equal(actual, null);
  });
  await check("repeated /new clears a previously persisted session without resurrection", async () => {
    await finish(start(3, "persisted-session"));
    const old = start(3, "persisted-session");
    await command(3, "/new");
    await command(3, "/new");
    await finish(old, "persisted-session");
    const next = start(3, "fresh-session");
    const actual = resume(next);
    await finish(next);
    assert.equal(actual, null);
  });
  await check("model switch cannot redirect the old result into the new model", async () => {
    const old = start(4, "old-model-session");
    await command(4, "/model deepseek-v4-pro");
    await finish(old);
    const next = start(4, "pro-session");
    const actual = resume(next);
    await finish(next);
    await command(4, "/model deepseek-flash");
    const back = start(4, "back-session");
    const previous = resume(back);
    await finish(back);
    assert.equal(actual, null);
    assert.equal(previous, "old-model-session");
  });
  await check("backend switch saves to the captured backend only", async () => {
    const old = start(5, "claude-session");
    await command(5, "/backend codex");
    await finish(old);
    await command(5, "/backend claude");
    const back = start(5, "back-session");
    const actual = resume(back);
    await finish(back);
    assert.equal(actual, "claude-session");
  });
  await check("switch away/back and reset still invalidates the original run", async () => {
    const old = start(6, "stale-session");
    await command(6, "/backend codex");
    await command(6, "/backend claude");
    await command(6, "/new");
    await finish(old, "stale-session");
    const next = start(6, "fresh-session");
    const actual = resume(next);
    await finish(next);
    assert.equal(actual, null);
  });
  await new Promise(resolve => setTimeout(resolve, 450));
  const saved = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
  assert.equal(saved.sessions["5:codex:deepseek-flash"], undefined);
} finally {
  await new Promise(resolve => setTimeout(resolve, 450));
  childProcess.spawn = originalSpawn;
  syncBuiltinESMExports();
  globalThis.fetch = originalFetch;
  for (const key of Object.keys(process.env)) if (!(key in savedEnv)) delete process.env[key];
  Object.assign(process.env, savedEnv);
  rmSync(dir, { recursive: true, force: true });
}
if (failures) process.exitCode = 1;
