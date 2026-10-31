# 市场状态（cb-market.sh）

一屏看五件事：**情绪、总量、流动性、杠杆、链上拥堵**。

价格涨没涨是结果，不是原因。这个脚本回答的是"现在是什么环境"：市场在恐惧还是贪婪、总市值在不在缩、稳定币在不在流出、杠杆钱是多是空、BTC 链上堵不堵。

```bash
cb-market.sh                 # 全部
cb-market.sh --only fng,funding
cb-market.sh --json          # 给程序看
cb-market.sh --strict        # 任一段缺失即退出码 1
```

## 五个信号与它们的来源

| 段 | 数据 | 来源 | 为什么看它 |
|---|---|---|---|
| 情绪 | Fear & Greed 指数（今日 + 昨日） | `api.alternative.me/fng/` | 极端恐惧常出现在恐慌抛售尾部；极端贪婪常出现在追高段 |
| 总量 | 总市值、24h 涨跌、BTC 占比 | `api.coingecko.com/api/v3/global` | BTC 占比上升 = 资金往"最保守的币"躲 |
| 流动性 | 稳定币总发行量 | `stablecoins.llama.fi` | 稳定币在缩，说明钱在离场，弹不起来 |
| 杠杆 | BTC 永续资金费率（8h + 年化） | `okx.com/api/v5/public/funding-rate` | 正费率 = 多头付钱（多头拥挤）；负费率 = 空头付钱 |
| 链上 | BTC 建议费率 sat/vB | `mempool.space/api/v1/fees/recommended` | 拥堵时转账成本高，也是链上活动温度 |

## 只有这五个，因为其余拿不到

实测（2026-10-31，从目标机出口 IP 逐个 `curl`）：

- **可用**：`alternative.me`、`coingecko.com`、`llama.fi`、`mempool.space`、`okx.com`、`futures.kraken.com`、`api.hyperliquid.xyz`（POST）、`api.blockchain.info`、`api.exchange.coinbase.com`
- **不可用（地区封锁，不是代码问题）**：
  - `fapi.binance.com` → **HTTP 451** `Service unavailable from a restricted location`
  - `api.bybit.com` → **HTTP 403** `The Amazon CloudFront distribution is configured to block access from…`
  - `www.deribit.com` → 连不上（同一地区策略）
  - `api.hyperliquid.xyz/info` 用 GET → **405**（必须 POST）

所以这个脚本**不提供**币安/Bybit/Deribit 的持仓量、爆仓数据、期权隐含波动率。要这些得换出口 IP 或买数据，不是改代码能解决的。

## 设计上的几处取舍

1. **缺数据不装没事**：某段拿不到就写 `（不可用：原因）`，末尾加一句"缺数据的时候，别把「没信号」当成「没问题」"。`--strict` 才让缺失变成失败。
2. **区分"HTTP 失败"和"解析失败"**：接口 200 但结构变了（对方改了字段名）和接口连不上，是完全不同的故障，混在一起就没法排查。
3. **缓存 120 秒**（`CB_MARKET_TTL` 可改）：这些都是免费接口，agent 连续调用会把额度打爆。缓存目录 `<XDG_CACHE_HOME>/coinbase-agent/market/`，文件 600。
4. **稳定币总量用 555KB 的响应**：接口没给汇总端点，只能自己加总 `peggedAssets[].circulating.peggedUSD`；缺 `circulating` 的条目跳过而不是当 0。
5. **资金费率换算成人话**：`+0.0100%/8h`、年化 `+10.9%`、并写明"多头付费"——原始值 `0.0001` 看不出方向也看不出量级。

## 它不能告诉你什么

- **不是价格预测**。五个指标同时极端也不构成买卖信号，只是"环境描述"。
- **不含持仓/爆仓/期权数据**（见上：地区封锁）。
- **资金费率只取 OKX 一个交易所**。单所费率可能偏离全市场，看趋势比看绝对值有意义。
- **稳定币总量没有变化率**。接口每次都返回全量快照；要看"在缩还是在涨"，需要自己隔天记录对比。
- **不能替代 `cb-news.sh`**。这里是慢变量（数小时到数天），突发事件看新闻。

## 在态势简报里

`cb-brief.sh` 把市场状态放在**风控之后、余额之前**：

```
=== 风控 ===   ✓ kill switch: 关着   max_single_trade_usd 100 / 每小时 6 笔
=== 市场 ===   情绪 30（Fear） ↓ 昨日 34 / 总量 $2.41T -1.23% / 杠杆 +0.0100% 年化 +10.9%
=== 余额 ===   余额均为 0
=== 走势 ===   BTC-USD 1h 12 根  ▅▅▂▂▃▅▄▄▆▆  最新 77364.9  区间 ↑0.16%
=== 事件 ===   4 条，P0 两条
```

顺序的理由：先看**允不允许**（风控），再看**该不该**（市场），然后才是**有多少钱**和**具体什么形状**。
