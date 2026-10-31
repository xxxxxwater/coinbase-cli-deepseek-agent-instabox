// text.mjs — Telegram 文本切块与转义。纯函数，无 I/O，便于单测。
//
// 为什么不用简单的 slice：把长回答切成多条消息时有两个坑
//   1. Telegram 单条上限 4096 UTF-16 码元，切大了直接 400；
//   2. 走 parse_mode=HTML 时 < & > 会被转义成 4~5 个字符，
//      于是"切的时候够短、转义完就超了"，而且从中间切断一个
//      &amp; 会让整条消息解析失败。
// 这里按"转义后的长度"切，同时避开代理对与 HTML 实体边界。

export const MAX_TG = 4096; // Telegram 单条消息上限（UTF-16 码元）
export const SAFE_BUDGET = 3800; // 留出 <pre></pre> 与页脚的空间

export function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// 不要把一个代理对（emoji）切成两半，否则 Telegram 收到孤立的半个码元
function avoidSurrogate(s, cut) {
  if (cut <= 0 || cut >= s.length) return cut;
  const c = s.charCodeAt(cut - 1);
  if (c >= 0xd800 && c <= 0xdbff) return cut - 1;
  return cut;
}

// 不要切断 HTML 实体：&amp; 切成 &am + p; 会让 parse_mode=HTML 直接 400
function avoidEntity(s, cut) {
  const amp = s.lastIndexOf("&", cut - 1);
  if (amp === -1) return cut;
  const semi = s.indexOf(";", amp);
  if (semi === -1 || semi >= cut) return amp;
  return cut;
}

// 把原文切成若干段，每段同时给出原文与转义后的 HTML。
// 切点是"转义后长度不超过 max"的最右位置，并优先落在换行之后。
export function splitPairs(rawText, max = SAFE_BUDGET) {
  const s = String(rawText ?? "");
  const out = [];
  let i = 0;
  while (i < s.length) {
    // 二分：最大的 j 使 esc(s[i..j]) 不超过 max
    let lo = i;
    let hi = s.length - 1;
    let best = i;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (esc(s.slice(i, mid + 1)).length <= max) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    let cut = best + 1;
    if (cut <= i) cut = i + 1; // 极端情况：单个字符就超限，硬切一个字，避免死循环

    // 优先在换行之后切（不超过回退 1200 字符，否则这个换行不划算）
    const nl = s.lastIndexOf("\n", cut - 1);
    if (nl > i && cut - nl <= 1200) cut = nl + 1;

    cut = avoidSurrogate(s, cut);
    cut = avoidEntity(s, cut);
    if (cut <= i) cut = i + 1;

    const piece = s.slice(i, cut);
    out.push({ raw: piece, html: esc(piece) });
    i = cut;
  }
  return out;
}

// 纯文本切块（不带 parse_mode 时用，也是 HTML 发送失败时的回退）
export function splitChunks(text, size = SAFE_BUDGET) {
  return splitPairs(text, size).map((p) => p.raw);
}

// 给 <pre> 用的切块：数字对的是转义后的长度
export function splitHtml(rawText, max = SAFE_BUDGET) {
  return splitPairs(rawText, max).map((p) => p.html);
}
