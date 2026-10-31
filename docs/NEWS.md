# 新闻与事件流：`cb-news.sh`

价格告诉你"发生了什么"，新闻告诉你"为什么"。下单前的判断里，"某交易所刚被
盗 6.4 亿美元"比"24 小时跌了 1.3%"重要得多。

这个脚本只做一件事：**把多个公开 RSS/Atom 源压成一屏能读的、按紧急程度排好的
事件列表**，并且明确标出哪些是官方一手消息、哪些只是聚合搜索。

```bash
./scripts/cb-news.sh                     # 最近 48 小时，按 P 等级排
./scripts/cb-news.sh --tag crypto.security --limit 5
./scripts/cb-news.sh --since 6h --json    # 给程序用
./scripts/cb-news.sh --sources            # 看内置源与信任级别
```

退出码：`0` 成功（包括"窗口内没有新闻"）、`2` 用法错、`6` 所有源都失败。

## 分级信任：为什么给源分级

| 级别 | 含义 | 例子 |
|---|---|---|
| **A** | 一手官方 | 美联储新闻稿、欧洲央行、SEC 新闻稿 |
| **B** | 主流媒体 | The Block、Decrypt、Blockworks、Bitcoin Magazine、CryptoSlate、CNBC、Kraken 博客 |
| **C** | 聚合搜索 | Google 新闻「bitcoin」「coinbase」 |

**C 级永远不会被评为 P0/P1。** 聚合结果里一条未经确认的转述，不该和 SEC 的
正式起诉书享有同等的紧急度。这条规则写在 `classify()` 里，有测试守着。

## 等级：什么值得打断你

| 等级 | 判据（节选） | 例子 |
|---|---|---|
| **P0** | 安全事故 / 下架停牌 / 利率决议 | `crypto.security`、`exchange.delisting`、`macro.policy_decision` |
| **P1** | 货币政策、宏观数据、监管动作、上线、财报、ETF 流向 | `macro.monetary`、`macro.data`、`regulation`、`etf.flows` |
| **P2/P3** | 背景 |

**解读类标题会降一级并标 `(解析)`。** `What is EIP-7702?`、`Why bitcoin didn't
crash in 2018` 不是新事件 —— 它值得读，但不该像事故一样打断你。

## 去重：为什么宁可留两条

同一件事被五家媒体转载时只留一条。判重看归一化标题的 token 相似度
（Jaccard ≥ **0.88**），并且**数字 token 必须一致**、最少 5 个 token。

宁可留两条，也不可把"美联储降息 25bp"和"降息 50bp"合成一条 —— 那是两个不同的
世界，合成一条比不去重危害大得多。

`canonical_url()` 会剥掉 `utm_*`/`fbclid`/`gclid`/`ref`/`igshid`，避免同一条
新闻因为追踪参数被当成不同的。

> **试过但放弃了"按主体聚合"**：英文标题是 Title Case，每个实词都大写，
> 专有名词检测退化成噪音（`Hack`/`Shows`/`Offshore` 都会被当成实体）。
> 实测同一批 200 条里，它要么把 44 条并成一条、要么把同一件事拆成十条。
> 现在的做法是在表格上方给一行**主题概览**（`本批集中在：binance（72 条）…`）：
> 描述分布，但不动任何一条的判定。

## 时效：时间解析不出来的一律略过

默认只看 `--since 48h` 内的条目。**时间解析不出来的条目默认不显示**，只在末尾
提示略过了几条；`--include-undated` 才会显示。

理由：无法确认它是何时发生的，就不能当"刚发生"给你看。这条规则来自一个真实的
坑 —— 早期版本把无法解析的 `pubDate` 记成 `epoch=0`，而 `epoch=0` 在窗口过滤里
被当成"在窗口内"，于是缓存里的旧闻永远显示成最新。现在缓存带 `version`，
解析逻辑一改就整体作废（见下）。

## 缓存：带版本号

`<XDG_CACHE_HOME>/coinbase-agent/news.json`（权限 600），每个源保留最近 120 条，
并记 `etag` / `last-modified`。下次请求带上条件头，服务端回 **304** 就直接复用
缓存，不重复解析。

缓存里存解析结果（含 `epoch`），所以解析逻辑一改就必须整体作废 —— 否则算错的
时间会被永久复用。`CACHE_VERSION` 就是干这个的。

## 为什么源要在这个仓库里硬编码

源清单是**配置**，但它决定了"什么算紧急"。把它做成外部可改的清单，等于让
任何能写文件的人在 A 级里塞一个 C 级源。需要临时加源时改脚本、跑测试、提交 ——
这个摩擦是故意的。

未启用的源（实测失败，多为 DNS/403，见提交记录）：`cointelegraph`（DNS）、
`coinbase_blog`（403）、`binance_ann`（空响应）、`reuters_biz`（DNS）、
`yahoo_finance`（404）、`glassnode`（403）、`cryptoquant`（403）、
`deribit_insights`（DNS）、`sec_litigation`（404）、`fred_blog`（超时）、
`barchart_news`（404）。

## 它不能告诉你什么

- **不做情感判断**。"hack" 出现在标题里不等于利空，`crypto.security` 的 P0 也不
  等于该做空 —— 这是给人（或 agent）的判断，不是脚本的。
- **不覆盖中文源**。内置全是英文源；中文快讯（尤其交易所公告的中文版）可能更早。
- **C 级聚合源的标题是别人写的**，可能带立场或夸大，`trust=C` 就是提醒你这个。
- **不做去重以外的因果推断**。它不会说"因为 A 所以价格跌"，只列事实条目。
- 源站改版会静默失效（返回 0 条而不是报错）；`cb-doctor` 里没有新闻项，
  需要时用 `--json` 的 `fetched`/`errors` 字段自查。

## 与其他脚本的关系

| 脚本 | 分工 |
|---|---|
| `cb-news.sh` | 发生了什么（事件） |
| `cb-brief.sh` | 四段拼成一屏（风控 + 余额 + 走势 + 事件），省得在脑子里拼四条命令 |
| `cb-candles.sh` | 价格怎么走的（形状） |
| `cb-products.sh` | 这个交易对的具体参数 |
| `cb-capability.sh` | 这把 key 能做什么 |
| `cb-risk.sh` | 现在允许下多少 |

Telegram 里可以直接 `/news`（默认 8 条，`/news 15` 指定条数）或 `/brief`。

它们都是**只读**的：`cb-news.sh` 不联网下单、不碰账户、不花钱。
