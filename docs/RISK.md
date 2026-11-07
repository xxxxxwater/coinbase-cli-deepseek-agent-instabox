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

MCP 写操作和 `cb-trade.sh --commit` 在真正执行前，先写入一条唯一的
`reserve/pending` 记录。**检查额度与预留是同一个加锁事务**，预留落盘并完成
`fsync` 后才允许转发。多个代理进程与脚本共用配置目录、账本和锁。

| 动作 | 记账 | 占金额额度 | 占每小时笔数 |
|---|---|---|---|
| dry-run | `preview` | 否 | 否 |
| `--paper` | `paper` | 否 | 否 |
| MCP 写操作 / `--commit` 获准转发 | `reserve/pending` | **是** | **是** |
| CLI 成功或失败返回 | 带预留 ID 的 `exec` 审计 | 不重复扣减，也不释放 | 不重复计数 |
| 被限额拦下 | `block/deny` | 否 | 否 |

预留衡量的是**可能已提交的名义金额**，不是实际成交金额。超时、断线、CLI 非零退出、
MCP 错误响应都不能证明服务端没有执行，因此不会自动退还额度。本版也不根据成功
响应自动结束预留，避免把未核实的 API 返回格式当成成交事实。

**未核对预留跨重启、跨日保留，直到明确对账。** 每小时笔数按预留发生时间计算，
已经释放金额的尝试仍占该小时笔数。撤单和组合元数据操作金额为零，但同样产生待核对
预留并占笔数；达到小时上限仍可能拦住它们。

### 对账后处理预留

先查看 Coinbase 的订单/转账记录，确认具体请求的结果，不要仅凭报错文字操作：

```bash
cb-risk.sh journal 20  # 显示 reservation_id
# 已在交易所确认提交：保留提交日和本次核对日的金额统计
cb-risk.sh reconcile <reservation_id> accepted
# 已确认没有提交、没有执行：释放金额；本小时尝试次数不退还
cb-risk.sh reconcile <reservation_id> not-submitted
```

这些命令只改本地账本，不调用交易所，也不会代替对账。不要让无人值守代理仅凭
成功、失败、超时或缺少响应就调用 `reconcile`。无法确认时保持 pending。

历史上没有预留 ID 的 `exec` 仍按旧口径计算：成功提交占当天金额，全部尝试占小时
笔数。旧 MCP 请求没有完整记账，本补丁不能追溯重建它们，升级前必须核对历史敞口。

## 账本与升级

`${XDG_CONFIG_HOME:-$HOME/.config}/coinbase-agent/journal.jsonl` 是共享账本，
`journal.jsonl.lock` 是稳定的进程锁。所有新版追加、读取额度和 reset 操作共用该锁。
使用 Python 标准库 `fcntl`，支持 Linux/macOS；不支持此锁的环境会拒绝预留。
新记录的名义金额以十进制字符串保存，额度累加不截断到八位小数。

账本读取/写入/fsync 失败、损坏 JSON、哈希链不符、非法金额或限额，都按拒绝处理。
旧的无哈希记录仍可读取，但不能当作可验证的审计链。哈希链不阻止具有文件写权限
的人重写整份账本，不是防 root 或恶意本地操作者的安全边界。

`cb-risk.sh reset` 在没有未核对预留时才允许归档。存在 pending 时拒绝，不能用
清零来恢复未知请求占用的额度。不要删除锁文件、手工截断账本或对运行中实例执行
卸载/purge 来绕开这一限制。

升级时先停止所有旧代理和交易脚本，核对交易所历史，再一起更新代理、`cb-risk.sh`、
`cb-trade.sh` 和 `lib/`。混用旧版本仍可能不加锁或漏记账。仅复制代理文件不够，
旧风控脚本不能返回持久预留凭据，新代理会拒绝转发。

## 执行顺序

```
产品识别 → 估算名义金额 → 预检 → 预览/确认 → 加锁复查并持久预留 → 下单 → 审计 → 对账
```

本改动不安装到实盘、不修改密钥或服务配置，也不代表部署后的交易链路已验收。

## 事件收紧：出了大事自动把上限压下来

TradingAgents 那套流程里，风险辩论之后才由基金经理拍板 —— 借鉴到这里的形态是：
**刚出过 P0 事件的时候，就算限额是 100，也只让你下 25。**

规则：

| 键 | 默认 | 含义 |
|---|---|---|
| `tighten_on_p0` | `true` | 是否启用事件收紧 |
| `tighten_hours` | `6` | P0 之后多少小时内算"刚发生" |
| `tighten_factor` | `0.25` | 上限乘数（100 → 25） |

数据从哪来：`cb-news.sh` 每次运行会往
`${XDG_CACHE_HOME:-~/.cache}/coinbase-agent/p0.json` 写一个小标记
（`{"count": N, "latest": <epoch>, ...}`，600）。风控**只读这个文件**，
不联网 —— 否则每次 `cb_risk_check` 都要拉一遍 RSS，慢且会因网络抖动误判。

所以有两个必然的后果，都是刻意的：

- **没有跑过 `cb-news.sh` 就不会收紧**（标记不存在 = 没见过 P0）。想让它工作就定时跑一次，`cb-brief.sh` 里也调了它。
- **标记是事实，不是判断**：文件里只有"几条、最新一条什么时候"，缩放多少由风控自己算，改 `tighten_hours` 立刻生效，不用重跑新闻。

`cb-risk.sh show` 会直接告诉你状态：

```
⚠ 事件收紧: 生效 —— 3 条 P0 在 10 分钟前，单笔上限 ×0.25（cb-risk.sh set tighten_on_p0 false 可关）
```

被拦时账本里的理由会写明来源，便于事后区分"普通超限"和"事件收紧"：

```
block BTC-USD BUY market 50.0 deny 超过单笔上限 25.00000000（事件收紧：3 条 P0 在 10 分钟前，上限 ×0.25）
```

只作用于**单笔上限**。当日上限、每小时笔数、白名单、kill switch 各自独立，不参与缩放 ——
把四个维度同时打折会让限额变得没人算得清。

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

## 第二条路：`coinbase mcp` 也要过闸门

二进制守卫拦的是 shell 里的 `coinbase orders create`。但 agent 通常不敲 shell ——
它连的是 `coinbase mcp` 这个 MCP server（37 个工具，其中有
`coinbase_orders_create` / `orders_cancel` / `orders_edit` / `orders_close_position` /
`convert_execute` / `transfer` / `x402_pay` / `portfolios_*`）。
那个 server 在自己的进程里直接调 API，**二进制守卫对它完全无效**。

所以守卫接管了 `mcp` 这个子命令：`coinbase mcp` 实际启动的是
`guard/mcp-proxy.mjs`，它把真 server 拉起来做子进程，逐行透传 JSON-RPC，
只在中途审视 `tools/call`：

| 情况 | 结果 |
|---|---|
| 只读工具（`coinbase_balance` / `products_*` / `orders_list` …） | 原样透传 |
| 会动钱的工具 | 先跑 `cb-risk.sh reserve <产品> <side> <金额> <类型> mcp`，取得持久预留凭据才转发 |
| 风控拒绝 | 回一个同 id 的 JSON-RPC `error`，真 server 根本收不到这条请求 |
| 金额算不出来（既没 `quote_size` 也没 `base_size`） | **拒绝**。算不出来不等于 0 |
| 只有数量没有价格（市价卖出） | 用 `cb-products.sh --ticker` 查一次现价再算 |
| 风控库不存在 | 拒绝（fail closed） |
| 代理文件不存在 | `coinbase mcp` 直接 exit 78，不启动没有闸门的 mcp |

两条路共用同一份账本（`journal.jsonl`），所以"shell 路径被拒"和"MCP 路径被拒"
在审计里是一个口径。

调试：`CB_MCP_PROXY_DEBUG=1 coinbase mcp` 会把每次判定打到 stderr。

## 已知限制

- 名义金额是**估算**：市价 SELL 用查询到的价格乘数量，滑点不算在内。
  限额因此是"大概没超标"，不是会计意义上的精确。
- 累计金额预留覆盖新版 MCP 已识别写操作和 `cb-trade.sh --commit`，不覆盖
  直接执行真实 CLI 的所有路径。原始 shell `coinbase orders create` 仍只有守卫的
  kill switch/白名单；未识别的新 MCP 工具名也不构成自动安全保障。
- MCP 批量 JSON-RPC 被拒绝。Convert、x402 支付、close-position 没有可靠金额
  估算时被拒绝；订单和转账仅接受 USD/USDC 计价。USDC 估值仍按 1 USD 假设。
- 这不是账户级硬额度，也不是已验证的实盘部署。还需要交易所权限约束、完整工具
  清单与真实 API 契约验收；不要仅凭本地测试放开无人值守交易。
- 没有实现 P&L 熔断（见上）。
