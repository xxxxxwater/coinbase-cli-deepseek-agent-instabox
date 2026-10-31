# 对话手册：怎么跟这个 agent 说话

这份文档给两类人看：

- **想直接用的人**：照抄下面的提示词，发到 Telegram 或任何接了 `coinbase mcp` 的 agent 里。
- **想改的人**：每个官方示例后面都标了它落到本仓库的哪个脚本、以及为什么某些示例在这台机器上做不到。

状态标记：✅ 现在就能用 ／ ⚠️ 部分可用 ／ ✗ 当前做不到（附原因）

---

## 一、第一次对话

官方引导语，两句，照抄即可。

**第 1 句 —— 让它自我介绍**

```
您的代理介绍它能使用 Coinbase 做什么。
```

**第 2 句 —— 验证真的连上了**

```
现在 Coinbase 已关联成功，请显示我的投资组合价值和我持仓最多的三种资产，然后告诉我我还能问什么问题。
```

真实运行结果（2026-10-31，目标机，账户余额为 0）：

```
## 📊 投资组合概览

**当前授权访问的投资组合：Agent MPC**

| 项目 | 金额 |
|---|---|
| 总价值 | $0.00 |
| 加密货币 | $0.00 |
| 法币（USD） | $0.00 |

**持仓最多（Top 3）**：暂无持仓

账户中 ETH、SOL、BTC、USDC、USD 五个账户的余额均为 0。

⚠️ 说明：API 密钥只能访问 Agent MPC 这个投资组合；
Default 和 HFT 两个投资组合返回 403 无权限。
```

这一句之所以值得先发，是因为它一次性验证了三件事：key 能签名、组合权限正确、余额能读出来。**如果它答不出余额，后面所有示例都不用试了。**

---

## 二、六个官方示例：在这套环境里能不能用

### 1. 投资组合再平衡 ⚠️

```
将我的投资组合再平衡至 80% 比特币 / 20% S&P 500，并在偏差超过 5% 时通知我。
```

- **现货部分能做**：`cb-brief.sh` 看当前配置 → `cb-trade.sh` 买 BTC-USD（默认只预览，`--commit` 才真下单）。
- **S&P 500 做不到**：股票通道对这个 key 返回短格式 403（组合层面拒绝，不是权限勾错）。
- **"偏差超过 5% 通知我"做不到**：本仓库只管单次执行，不负责调度。要自动通知得加 systemd timer 跑 `cb-brief.sh` 再把结果推到 Telegram。

### 2. 市场感知型平均成本法 ✗

```
每周三购买 50 美元的 TSLA。如果 RSI 高于 70，表明情绪过热，则改为购买 25 美元。
```

三处都卡住：

- **TSLA 是 EQUITY**，`orders create` 打 Agent MPC 组合返回 `{"errorType":"permission_denied","errorMessage":"User does not have access to portfolio"}`（与现货同组合不同结果，是股票通道拒绝）。
- **我们没有算 RSI**。`cb-candles.sh` 给的是收盘价与一行 sparkline，不是指标。
- **"每周三"是调度**，同问题 1。

可行的替代：把标的换成现货（如 BTC-USD），RSI 用 `cb-candles.sh --json` 自己算，再用 timer 触发。

### 3. 已披露的交易活动提醒 ⚠️

```
追踪公司高管和国会议员近期披露的股票交易情况。
```

- 已接：`cb-news.sh` 里的 `sec_press`（SEC 官方新闻稿，A 级源）与 `fed_monetary`/`fed_all`。
- 缺的是：**结构化披露**。高管增减持是 SEC Form 4，需要单独接 EDGAR 的 Form 4 feed —— 新闻稿里只会零星提到，不构成"追踪"。

### 4. 投资组合透视 ⚠️

```
请提供我在加密货币和股票方面持仓的完整明细。针对每一项，请显示其 7 天趋势、近期新闻，以及相对于我其余投资组合的表现。
```

拆开看每一块都有对应工具，但拼不到"完整明细"：

| 要的东西 | 现在能给 | 命令 |
|---|---|---|
| 加密持仓 | 只读 Agent MPC 组合 | `coinbase balance portfolio_id==<uuid> show_zero==true` |
| 股票持仓 | ✗ 无（组合在股票通道被拒） | — |
| 7 天趋势 | ✅ 现货 | `cb-candles.sh BTC-USD --granularity 1d --limit 7` |
| 近期新闻 | ✅ | `cb-news.sh --since 48h` |
| 相对表现 | ⚠️ 只能单标的，多标的要自己比 | `cb-brief.sh` 分次跑 |

一条命令拿到以上四段的方式：`cb-brief.sh BTC-USD`（见示例 5）。

### 5. 周一早间简报 ✅

```
每周一，给我一份 60 秒的投资组合摘要：上周有什么变化、哪些行情有变动，以及本周我应关注哪些内容。如果资产配置出现偏离，建议再平衡交易。
```

**这个已经做好了**，就是 `cb-brief.sh`（Telegram 里发 `/brief`）。五段固定顺序：

```
=== 风控 ===   kill switch 状态、各类限额、今日已用
=== 市场 ===   情绪 / 总量 / 流动性 / 杠杆 / 链上
=== 余额 ===   Agent MPC 组合的非零余额
=== 走势 ===   产品 K 线 + 一行 sparkline + 区间涨跌
=== 事件 ===   P0/P1 事件与主题概览
```

"每周一自动发"仍要 timer；手动触发是一句话的事。

### 6. 高级数据深度剖析 ⚠️

```
从 x402 数据源获取我前 5 大持仓的高级市场数据，费用不超过 1 美元。比较它们的动量指标，标记任何异常情况，并总结出这些数据所传达的信息。
```

- **目录与价格能看**（真实 127 条资源）：`cb-x402.sh resources --search btc`
- **花钱有上限**：`cb-x402.sh fetch <url> --max-amount 0.05 --commit`，默认不花钱只打印命令，且**必须过风控闸门**（kill switch / 单笔上限）。
- **"前 5 大持仓"目前是空的**：账户余额为 0，没有持仓可比。

---

## 三、Telegram 里怎么用

14 个命令（`getMyCommands` 真实回读）：

```
/start /help /new /status /stop /model /backend /skills /mcp /cap /risk /news /brief /id
```

| 命令 | 做什么 | 例子 |
|---|---|---|
| `/brief` | 一屏态势（风控/市场/余额/走势/事件） | `/brief` |
| `/news` | 事件流，默认 8 条 | `/news 15` |
| `/cap` | 这把 key 到底能做什么（只读探测） | `/cap` |
| `/risk` | 当前限额与今日已用 | `/risk` |
| `/skills` | 9 个 Coinbase skill 是否在位 | `/skills` |
| `/mcp` | MCP server 注册状态 | `/mcp` |
| `/model` | 切模型（`deepseek-flash` / `deepseek-v4-pro`） | `/model flash` |
| `/new` | 清空会话上下文，重新开始 | `/new` |
| `/stop` | 中断正在跑的那一轮 | `/stop` |
| `/id` | 回显你的 chat id（排白名单用） | `/id` |

除命令外，**直接说话就行** —— 中继器会把消息交给 agent，agent 自己决定调哪个 MCP 工具或脚本。流式输出（边生成边编辑同一条消息），会话可续接。

### 三段真实对话

**① 查态势**

```
你：/brief
Bot：态势简报 · BTC-USD · 2026-10-31 11:00 UTC
     === 风控 ===  ✓ kill switch: 关着  max_single_trade_usd 100 / 每小时 6 笔
     === 市场 ===  情绪 30（Fear）→ 昨日 30 ／ 总量 $2.60T -2.85% ／
                   稳定币 $299.7B ／ 资金费率 +0.0100%/8h ／ 链上 1 sat/vB
     === 余额 ===  余额均为 0
     === 走势 ===  BTC-USD 1h 6 根 ▅▅▂▂▃▅▄▄▆▆ 最新 77364.9 ↑0.16%
     === 事件 ===  4 条，P0 两条（Binance 被盗后续）
```

**② 问一件具体事（走 agent + MCP）**

```
你：用 coinbase 的 MCP 工具查一下 BTC-USD 的价格，顺便看下最优买卖价
Bot：77282.5 美元（最优买价 77282.5，卖价 77282.51）
```

**③ 想买之前先看要花多少钱（默认不成交）**

```
你：帮我看看买 25 美元的 BTC 大概什么情况
Bot：（调 cb-trade.sh）名义额 25.00 USD → orders preview →
     order preview failed: preview insufficient fund
     （余额为 0，预览就挡住了；真下单命令已打印，加 --commit 才执行）
```

---

## 四、x402 付费数据：先看价格再决定

`cb-x402.sh resources --search btc` 的真实输出（**这一步不花钱**）：

```
价格            资源
0.0500 USDC     https://x402.glassnode.com/v1/metrics/institutions/us_spot_etf_balances_all
                US Spot ETF Balances — The most recent holdings of the lead…
1.0000 USDC     https://api.apify.com/v2/acts/gochujang~crypto-etf-flow-tracker/run-sync-get-dataset-items
```

真要取数时，默认仍然不花钱：

```
$ cb-x402.sh fetch https://x402.glassnode.com/v1/metadata/assets --max-amount 0.05
将要执行（还没花钱）
  资源    https://x402.glassnode.com/v1/metadata/assets
  上限    0.05 USDC
  命令    coinbase x402 fetch resource=… max_amount=50000
确认要付就加 --commit；这笔会过风控闸门（kill switch / 单笔上限）。
```

---

## 五、能力边界（先说清楚，省得反复试）

| 想做的事 | 现在 | 原因 |
|---|---|---|
| 现货买卖 BTC/ETH 等 | ✅ | key 绑的就是 Agent MPC 组合，权限 `can_view/can_trade/can_transfer` 全 true |
| 看余额、看行情、看 K 线 | ✅ | 只读接口不挑组合 |
| 股票（AAPL/TSLA） | ✗ | 产品可见、`product_type=EQUITY`，但下单被组合层面拒绝（短格式 403） |
| Convert 换币 | ✗ | `Convert can only be performed on default portfolio`，而这把 key 只能碰 Agent MPC |
| 期货 CFM | ✗ | `derivatives` 返回 `invalid request`（官方标注"已集成但暂不可用"） |
| 其它组合（Default/HFT） | ✗ | 403，key 创建时只勾了 Agent MPC |
| 定时任务（每周三、每周一） | ⚠️ | 本仓库不调度，要 systemd timer 跑脚本 |
| 真成交 | ⚠️ | 余额 0，任何 create 都会被 `insufficient fund` 挡住 |

---

## 六、给 agent 的系统提示（可直接粘）

如果你要把自己的一套 agent 接进来，这段能省掉大部分踩坑：

```
你是 Coinbase 交易助手，运行在 Linux 服务器上。
1. 查余额必须带 portfolio_id（否则 403）：coinbase balance portfolio_id==<uuid> show_zero==true
2. 下单前先跑 cb-brief.sh 看风控与市场；被风控拒绝（退出码 4）时不要换参数重试，如实回报原因。
3. 想下真单必须显式加 --commit；默认只预览，不要把预览当成成交。
4. 本机 IPv6 出口不在门户白名单，命令前需要 NODE_OPTIONS=--dns-result-order=ipv4first（已写进 /etc/environment）。
5. 股票、Convert、期货、其它组合会返回 403 —— 那是能力缺失，不是网络问题，不要反复重试。
```

---

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 分层与数据流
- [TELEGRAM-RELAY.md](TELEGRAM-RELAY.md) — 中继器怎么工作
- [RISK.md](RISK.md) — 限额、账本、kill switch、事件收紧
- [NEWS.md](NEWS.md) — 事件流与 P0 判定
- [MARKET.md](MARKET.md) — 市场状态五段信号
- [CAPABILITIES.md](CAPABILITIES.md) — 这把 key 能做什么（含实测输出）
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — 按报错查
