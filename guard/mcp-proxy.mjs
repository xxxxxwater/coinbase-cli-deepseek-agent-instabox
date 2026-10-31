#!/usr/bin/env node
/**
 * coinbase-mcp-proxy — 把风控闸门架在 MCP 这条路上。
 *
 * 为什么需要它：`guard/coinbase` 拦得住 shell 里的 `coinbase orders create`，
 * 但 agent 通常不敲 shell —— 它通过 `coinbase mcp` 这个 MCP server 下单，
 * 而那个 server 是在自己的进程里直接调 API 的。二进制层的守卫对它完全无效。
 * 所以 `coinbase mcp` 也要过闸门：做一个透传代理，只审 JSON-RPC 里的 tools/call。
 *
 * 原则：
 *   - 只拦「改状态」的工具，其余一律原样透传（协议不能被我改坏）。
 *   - 判断不了就拒绝（fail closed），不猜。
 *   - 拒绝也记进风控账本，和 shell 路径共用一份 journal。
 */
import { spawn } from "node:child_process";
import { execFile, execFileSync } from "node:child_process";

const REAL = process.env.CB_REAL_COINBASE || "/usr/local/bin/coinbase-real.js";
const RISK = process.env.CB_RISK_BIN || "/data/home/cb-risk.sh";
const PRODUCTS = process.env.CB_PRODUCTS_BIN || "/data/home/cb-products.sh";

// 会动钱/动仓位的工具。只拦这些：把读操作也拦了，agent 就什么也做不了。
const MUTATING = new Set([
  "coinbase_orders_create",
  "coinbase_orders_edit",
  "coinbase_orders_cancel",
  "coinbase_orders_close_position",
  "coinbase_convert_execute",
  "coinbase_transfer",
  "coinbase_x402_pay",
  "coinbase_portfolios_create",
  "coinbase_portfolios_edit",
  "coinbase_portfolios_delete",
]);

function log(...a) {
  if (process.env.CB_MCP_PROXY_DEBUG) console.error("[mcp-proxy]", ...a);
}

/** 查现价（只读，用仓库里的 cb-products.sh，不自己调 API）。失败返回 null。 */
function lastPrice(product) {
  if (!product) return null;
  try {
    const out = execFileSync("bash", [PRODUCTS, "--ticker", product], {
      encoding: "utf8", timeout: 20000, stdio: ["ignore", "pipe", "ignore"],
    });
    const px = Number(String(out).trim());
    return Number.isFinite(px) && px > 0 ? px : null;
  } catch {
    return null;
  }
}

/**
 * 从 tools/call 的参数里算出这笔要花多少钱。
 * 返回 { notional, why }：算不出时 notional=null，why 说明原因。
 */
function notionalOf(name, args) {
  const num = (v) => (v === undefined || v === null || v === "" ? null : Number(v));
  if (name === "coinbase_orders_create" || name === "coinbase_orders_edit") {
    const quote = num(args.quote_size ?? args.total_quote_size);
    if (quote !== null && Number.isFinite(quote)) {
      return { notional: quote, why: "quote_size" };                 // 市价买入：quote_size 就是花费
    }
    const base = num(args.base_size ?? args.size);
    const px = num(args.limit_price ?? args.stop_price ?? args.price);
    if (base !== null && px !== null && Number.isFinite(base * px)) {
      return { notional: base * px, why: "base_size×限价" };
    }
    if (base !== null && Number.isFinite(base)) {
      // 市价卖出这类只有数量没有价格的：查一次现价再算，别凭猜。
      const p = lastPrice(args.product_id);
      if (p !== null) return { notional: base * p, why: `base_size×现价(${p})` };
      return { notional: null, why: "拿不到现价" };
    }
    return { notional: null, why: "参数里没有 quote_size 也没有 base_size" };
  }
  if (name === "coinbase_transfer") {
    const amt = num(args.amount ?? args.quote_size);
    return amt !== null && Number.isFinite(amt)
      ? { notional: amt, why: "amount" }
      : { notional: null, why: "转账金额未知" };
  }
  // cancel / close_position / portfolios_*：不改仓位规模，只判 kill switch
  return { notional: 0, why: "不计金额" };
}

function check(product, side, type, notional, cb) {
  // cb-risk.sh check 的签名是 <产品> <side> <金额> [类型] —— 金额在第 3 位，
  // 类型是可选第 4 位。参数错位会让账本里的 notional 变成 "market" 之类，
  // python 抛 ValueError、账本静默丢失（真机上就是这么丢了 4 条 block 记录）。
  const args = [RISK, "check", product || "unknown", side || "BUY",
    notional === null ? "0" : String(notional), type || "market"];
  execFile("bash", args, { timeout: 15000 }, (err, stdout, stderr) => {
    const code = err && typeof err.code === "number" ? err.code : err ? 1 : 0;
    cb(code, (stdout || "") + (stderr || ""));
  });
}

function denyReply(msg, text) {
  // JSON-RPC 层面回一个错误结果，而不是直接掐断连接：让 agent 看懂为什么被拒。
  return {
    jsonrpc: "2.0",
    id: msg.id,
    error: { code: -32001, message: text },
  };
}

const child = spawn(process.execPath, [REAL, "mcp"], {
  stdio: ["pipe", "pipe", "inherit"],
  env: process.env,
});
// 真 server 的 stdout 必须原样接回给客户端 —— 少了这一句，客户端只会看到
// 自己的请求发出去、然后永远等不到任何响应（claude 的报错是
// "MCP server connection timed out after 30000ms"，看起来像网络问题）。
child.stdout.pipe(process.stdout);
// 不要在这里 process.exit()：管道里可能还有没冲出去的响应，
// 硬退会把最后几条截断（表现为客户端收不到最后一条结果）。
// 只记退出码，让事件循环自己排空后退出。
child.on("exit", (c) => { process.exitCode = c ?? 0; });
// 客户端关掉输入后，子进程的输出可能还在路上；等它自己结束再走。
process.stdout.on("error", () => {});

let pending = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  pending += chunk;
  let i;
  while ((i = pending.indexOf("\n")) >= 0) {
    const line = pending.slice(0, i);
    pending = pending.slice(i + 1);
    handleLine(line);
  }
});
process.stdin.on("end", () => {
  if (pending) handleLine(pending);
  // 必须等队列跑完再关子进程的 stdin：不然代理先退出、子进程跟着退，
  // 排队中的请求全丢（真机上表现为"客户端发了几条、服务端只看到前两条"）。
  queue.then(() => child.stdin.end());
});

let queue = Promise.resolve();
function handleLine(line) {
  queue = queue.then(() => new Promise((resolve) => {
    const raw = line.endsWith("\r") ? line.slice(0, -1) : line;
    if (!raw.trim()) { child.stdin.write(line + "\n"); return resolve(); }
    let msg;
    try { msg = JSON.parse(raw); } catch { child.stdin.write(line + "\n"); return resolve(); }
    const isCall = msg && msg.method === "tools/call" && msg.params && msg.params.name;
    if (!isCall || !MUTATING.has(msg.params.name)) { child.stdin.write(line + "\n"); return resolve(); }

    const name = msg.params.name;
    const args = msg.params.arguments || {};
    const product = args.product_id || args.currency || args.base_currency || "";
    const side = args.side || "";
    const type = args.type || args.order_type || "";
    const { notional, why } = notionalOf(name, args);
    log(name, { product, side, type, notional, why });

    // 金额算不出来时不能当 0 —— 那等于给"未知金额"开了免限额通道。
    // 只有当它确实不涉及金额（cancel 等）才放过，否则拒绝。
    const amountMatters = name === "coinbase_orders_create" || name === "coinbase_orders_edit" ||
      name === "coinbase_transfer";
    if (amountMatters && notional === null) {
      const whyMsg = `✗ 风控：这笔 ${name} 算不出金额（${why}），无法确认是否在限额内，已拒绝。` +
        `补齐 quote_size（买入）或 limit_price（卖出）后重试。`;
      process.stdout.write(JSON.stringify(denyReply(msg, whyMsg)) + "\n");
      log("denied-no-notional", why);
      return resolve();
    }

    check(product, side, type, notional, (code, out) => {
      if (code === 0) {
        child.stdin.write(line + "\n");
        return resolve();
      }
      // 4 = 风控拒绝；4 以外的非零（比如 78 找不到风控库）同样按拒绝处理。
      const why = out.trim().split("\n").filter(Boolean).pop() ||
        "风控闸门拒绝了这笔操作";
      process.stdout.write(JSON.stringify(denyReply(msg, why)) + "\n");
      log("denied", code, why);
      resolve();
    });
  }));
}
