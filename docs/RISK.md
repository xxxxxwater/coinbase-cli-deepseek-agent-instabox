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

## 兜底：占住 `coinbase` 这个名字的守卫

`cb-trade.sh` 过闸门，但 agent 也能直接敲 `coinbase orders create …`，
那就绕过了限额。`guard/coinbase` 是个透明的 wrapper，拦 `orders create` /
`orders cancel`，其余原样转发。

**它不靠 PATH 顺序工作**，这是被真机否掉一版之后才定下来的：`ssh host 'cmd'`
是非登录 shell、不读 `.bashrc`；`/etc/environment` 里的 PATH 也不作用于这种
exec 场景。把守卫目录排在 PATH 前面，在 `bash -c`、cron、别的进程里全都可能失效。
所以正确装法是**把真程序改名，让守卫占住 `coinbase` 这个名字**：

```bash
sudo mv /usr/local/bin/coinbase /usr/local/bin/coinbase-real.js   # 必须留 .js
sudo install -m 755 guard/coinbase /usr/local/bin/coinbase
```

真程序**必须保留 `.js` 扩展名**：这个 CLI 是 Node ESM 脚本，改成 `coinbase.real`
之类 node 会直接抛 `ERR_UNKNOWN_FILE_EXTENSION` 拒绝执行。守卫按
`CB_REAL_COINBASE` → 同目录 `coinbase-real.js` → 沿 PATH 找（跳过自己所在目录）
的顺序定位真程序。

`scripts/coinbase-stack-check.sh` 每次开机都会检查 `CB_GUARD_V1` 标记还在不在：
`npm i -g` 升级会把 `/usr/local/bin/coinbase` 换回真二进制，守卫就悄悄没了 ——
而"守卫悄悄消失"和"守卫从没装过"在用户看来都是"能下单"。

行为：

| 调用 | 结果 |
|---|---|
| `coinbase --version` / `balance` / `products …` / `mcp` | 原样转发 |
| `coinbase orders preview …` | 原样转发（只读） |
| `coinbase orders create …` / `orders cancel …` | 先判 kill switch 与产品白名单，通过才转发 |
| 找不到风控库 | **拒绝**（退出码 78），不是放行 |
| 白名单开着、但认不出 `product_id` | **拒绝**（退出码 78）——判断不了不等于放行 |
| 找不到真的 coinbase | 退出码 127，绝不自己 exec 自己 |

`product_id` 的写法要认全：`orders create` 用的是**单等号**
（`product_id=BTC-USD side=BUY type=market`），而 `balance` 用双等号
（`portfolio_id==<uuid>`）。守卫原来只匹配双等号，白名单在真机上等于没开 ——
现在 `product_id=` / `product_id==` / `--product_id=` / `--product_id==` 都认。

刻意**不**在 wrapper 里算金额限额：市价单的名义金额要查行情才知道，
每拦一次就多打一次 API 是本末倒置。金额归 `cb-trade.sh`，它本来就查过价格。

## 已知限制

- 名义金额是**估算**：市价 SELL 用查询到的价格乘数量，滑点不算在内。
  限额因此是"大概没超标"，不是会计意义上的精确。
- 装上守卫后，`coinbase orders create` 也拦得住（kill switch + 白名单）；
  但**金额限额仍然只管 `cb-trade.sh`**。真要在服务端层面兜底，还得靠
  Coinbase 侧的 key 权限（只给某一个组合，让越界操作在服务端就 403）。
- 没有实现 P&L 熔断（见上）。
