# 风控闸门与审计日志

这一层的存在理由只有一个：**agent 会自己拼命令。**

提示词里写"单笔别超过 100 美元"是劝告 —— 模型换个说法、少带一个参数、
或者干脆绕开这个脚本直接调 `coinbase orders create`，劝告就失效了。
所以限额必须落在**代码里**，并且在**下单之前**执行，而不是在提示词里。

## 借鉴了谁

| 来源 | 做法 | 这里怎么用 |
|---|---|---|
| [Hummingbot kill switch](https://hummingbot.org/client/global-configs/kill-switch/) | 阈值是持久配置（`kill_switch_mode` / `kill_switch_rate`），运行中可改，触发即停策略 | kill switch 做成一个**文件**（`touch` 就算开），任何脚本、任何人都能在紧急时立刻关闸，不需要改 JSON、不需要重启 |
| [TradingAgents](https://arxiv.org/html/2412.20138) 的 Risk Management Team | 交易员出主意之后，还有一层独立的风险辩论，最后才由基金经理拍板 | 检查与执行分成两段代码：算限额的分支不下单，下单的分支不自己判断额度 |
| [tigerpaw](https://www.npmjs.com/package/@greatlyrecommended/tigerpaw) | `maxSingleTradeUsd` 这类上限是硬闸门 | `max_single_trade_usd`，被拒就是退出码 4，没有"再确认一次就放行"的路径 |

刻意**没有**照搬的：Hummingbot 那套按浮动盈亏率自动停策略。原因很实在 ——
这个账户还没有真实成交，算不出 P&L。等有了成交记录再说，凭空实现一个
没有数据喂它的熔断器只是装饰。

## 规则

| 配置键 | 含义 | 没设置时 |
|---|---|---|
| `max_single_trade_usd` | 单笔名义金额上限 | 不限 |
| `max_daily_usd` | 当日累计上限（按本地日期） | 不限 |
| `max_orders_per_hour` | 最近 60 分钟提交笔数上限 | 不限 |
| `allowed_products` | 逗号分隔的产品白名单，如 `BTC-USD,ETH-USD` | 不限 |
| `kill_switch` | `true` 时禁止一切下单（也可用 `KILL` 文件） | 关 |

```bash
cb-risk.sh set max_single_trade_usd 100
cb-risk.sh set allowed_products BTC-USD,ETH-USD
cb-risk.sh show                # 当前限额 + 今日已用 + kill switch 状态
cb-risk.sh check BTC-USD BUY 50 # 只判断，不动账本
cb-risk.sh kill                # 立刻禁止下单
cb-risk.sh resume
cb-risk.sh journal 10          # 最近 10 条记录
```

## 什么算额度

只有**真正提交给服务端并成功**的单子（`event=exec`、`result=ok`）占额度。
这条规则是为了让"先看看"这件事免费：

**金额和笔数的口径不一样，这是故意的：**

| 动作 | 记账 | 占金额额度 | 占每小时笔数 |
|---|---|---|---|
| `cb-trade.sh BTC-USD BUY 20`（dry-run） | `preview` | 否 | 否 |
| `cb-trade.sh … --paper` | `paper` | 否 | 否 |
| `cb-trade.sh … --commit` 成功 | `exec` / `ok` | **是** | **是** |
| `cb-trade.sh … --commit` 失败 | `exec` / `error` | 否（没成交） | **是** |
| 被限额拦下 | `block` / `deny` | 否 | 否 |

金额只算成交的，因为它衡量"花了多少钱"；笔数算**所有提交尝试**，因为它衡量
"打了多少次账户和 API"。失败的尝试同样在打服务端 —— 只在成功时才限流，等于没限流。
余额为 0 时每一笔都会失败，那正是最需要限流的时候。

反过来说：dry-run 跑一万次也不会把额度跑没，但也不会产生"已用额度"的假象。

## 账本

`${XDG_CONFIG_HOME:-$HOME/.config}/coinbase-agent/journal.jsonl`，一行一个 JSON 对象，
权限 600，只追加（`os.open(..., O_APPEND, 0o600)`）。它同时是**审计日志**和
**限额计数器** —— 没有第二个真相来源，所以不会出现"日志说下了三单、限额说下了两单"。

```json
{"ts":"2026-10-31T07:42:30Z","epoch":1793526150,"day":"2026-10-31","event":"exec",
 "product":"BTC-USD","side":"BUY","type":"market","notional":20.0,"result":"ok",
 "reason":"create 返回 0"}
```

`cb-risk.sh reset` 不删记录，而是把文件改名成 `journal.jsonl.<时间戳>.archived`：
限额从 0 开始，但"昨天到底下了什么"仍然查得到。

## 顺序为什么是这样

```
产品识别 → 算名义金额 → 风控闸门 → 服务端预览 → 确认 → 下单 → 记账
```

闸门放在预览**之前**，不是因为预览花钱（它不花钱），而是因为
"让 agent 反复试一下"本身就是个坏习惯：试十次、错九次、第十次对了，
日志里只剩一片噪音。先拦掉明显越界的，再让服务端去看细节。

## 已知限制

- 名义金额是**估算**：市价 SELL 用查询到的价格乘数量，滑点不算在内。
  限额因此是"大概没超标"，不是会计意义上的精确。
- 只约束**本仓库的脚本**。绕过 `cb-trade.sh` 直接调 `coinbase orders create`
  不受这里约束 —— 真要在服务端层面兜底，得靠 Coinbase 侧的 key 权限
  （例如只给某一个组合的权限，让越界操作在服务端就 403）。
- 没有实现 P&L 熔断（见上）。
