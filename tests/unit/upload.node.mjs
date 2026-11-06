#!/usr/bin/env node
// Offline regression: tg() unwraps Telegram's result before handleUpload sees it.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const dir = mkdtempSync(join(tmpdir(), "tg-upload-"));
process.env.TG_AGENT_DIR = dir;
process.env.TG_BOT_NO_POLL = "1";
writeFileSync(join(dir, "config.json"), JSON.stringify({token:"offline-test", allowed_chat_ids:["1"]}));
const originalFetch = globalThis.fetch;
const calls = [];
globalThis.fetch = async (url, options) => {
  calls.push({url, payload: JSON.parse(options?.body || "{}")});
  if (url.includes("/file/bot")) return {ok:true, arrayBuffer:async()=>new TextEncoder().encode("hello").buffer};
  return {ok:true, json:async()=>({ok:true, result:url.endsWith("/getFile") ? {file_path:"documents/test.txt"} : {message_id:1}})};
};
try {
  const {handleUpdate} = await import("../../telegram/bot.mjs");
  await handleUpdate({message:{chat:{id:1},from:{id:1},document:{file_id:"test",file_name:"test.txt",file_size:5}}});
  const files = readdirSync(join(dir,"uploads"));
  assert.equal(files.length,1);
  assert.equal(readFileSync(join(dir,"uploads",files[0]),"utf8"),"hello");
  assert.ok(calls.some(c=>c.url.includes("/file/bot")));
  assert.ok(calls.some(c=>c.payload.text?.includes("已存到盒子")));
  console.log("Telegram upload regression passed (offline).");
} finally {
  globalThis.fetch = originalFetch;
  rmSync(dir,{recursive:true,force:true});
}
