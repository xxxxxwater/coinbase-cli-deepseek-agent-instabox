import { esc, splitChunks, splitHtml, splitPairs, SAFE_BUDGET } from "../../telegram/lib/text.mjs";
let pass=0, fail=0;
const ok=(m)=>{pass++;console.log("  ok   "+m);};
const bad=(m,d)=>{fail++;console.log("  FAIL "+m+(d?"\n       "+d:""));};
const t=(c,m,d)=>{ c?ok(m):bad(m,d); };

// 1 转义
t(esc("a<b&c>d")==="a&lt;b&amp;c&gt;d","esc 转义三个字符",esc("a<b&c>d"));
t(esc(null)==="","esc 容忍 null");

// 2 普通切块
t(splitChunks("").length===0,"空字符串不产生块");
t(splitChunks("abc").length===1,"短文本一块");
const longNoLine="x".repeat(9000);
const c2=splitChunks(longNoLine, 3800);
t(c2.every(c=>c.length<=3800),"无换行长文每块都 ≤ 上限",c2.map(c=>c.length).join(","));
t(c2.join("")===longNoLine,"拼回去不丢字符");

// 3 优先在换行处切
const lines=Array.from({length:400},(_,i)=>`第 ${i} 行内容`).join("\n");
const c3=splitChunks(lines, 500);
t(c3.every(c=>c.length<=500),"多行文本每块 ≤ 上限");
t(c3.join("")===lines,"多行文本拼回完全一致");

// 4 emoji 不被切半
const emoji="🍓".repeat(1500);
const c4=splitChunks(emoji, 500);
const lone=c4.filter(c=>/[\uD800-\uDBFF]$/.test(c)||/^[\uDC00-\uDFFF]/.test(c));
t(lone.length===0,"没有孤立代理对",lone.length+" 块被切坏");
t(c4.join("")===emoji,"emoji 拼回一致");

// 5 HTML 实体不被切断：全是 < 和 &
const heavy="<".repeat(3000)+"&".repeat(3000);
const c5=splitHtml(heavy, 800);
t(c5.every(c=>c.length<=800),"转义后每块 ≤ 上限",c5.map(c=>c.length).join(","));
const brokenChunk=c5.filter(c=>/&[a-zA-Z#0-9]*$/.test(c));
t(brokenChunk.length===0,"没有以半个实体结尾的块",JSON.stringify(brokenChunk.slice(0,2)));
t(c5.join("")===esc(heavy),"转义+切块后拼回等于整体转义");

// 6 边界：正好等于上限
const exact="y".repeat(800);
t(splitHtml(exact,800).length===1,"正好等于上限时只有一块");

// 7 换行在很靠前的位置（低于 50%）应改用硬切，避免产生大量超小块
const early="\n"+"z".repeat(1000);
const c7=splitChunks(early,400);
t(c7.length<=4,"靠前的换行不会导致碎块",c7.map(c=>c.length).join(","));


// 8 splitPairs：切点是精确的（转义长度刚好不超限，且不浪费）

{
  const raw = "<a>".repeat(2000);
  const ps = splitPairs(raw, 1000);
  t(ps.every(p=>p.html.length<=1000), "splitPairs 每段 HTML ≤ 上限", ps.map(p=>p.html.length).join(","));
  t(ps.map(p=>p.raw).join("")===raw, "splitPairs 原文拼回一致");
  t(ps.map(p=>p.html).join("")===esc(raw), "splitPairs HTML 拼回等于整体转义");
  t(ps.slice(0,-1).every(p=>p.html.length>900), "除最后一段外没有碎块", ps.map(p=>p.html.length).join(","));
}

// 9 混合：中文 + emoji + 代码块标记 + 实体
{
  const raw = ("\n```js\nconst a = 1 < 2 && 3 > 2;\n```\n").repeat(300) + "🍓".repeat(300);
  const ps = splitPairs(raw, 1200);
  t(ps.every(p=>p.html.length<=1200), "混合内容每段 ≤ 上限");
  t(ps.map(p=>p.raw).join("")===raw, "混合内容拼回一致");
  const bad = ps.filter(p=>/&[a-zA-Z#0-9]*$/.test(p.html));
  t(bad.length===0, "混合内容没有半个实体结尾");
}

console.log(`  -- ${pass} 通过, ${fail} 失败`);
process.exit(fail?1:0);
