## [Unreleased]

### Added

- `scripts/cb-candles.sh`：K 线。给 OHLCV 的同时画一条 sparkline —— agent 拿一屏
  JSON 看不出形状，一行块字符能。`--granularity` / `--limit` / `--json`。
  两处刻意区分：股票（EQUITY）没有 K 线接口 ≠ 该区间无成交；服务端错误负载也是
  JSON，不能当"成功但没数据"渲染（否则失败被伪装成空结果）。22 条断言。

- `scripts/cb-skills.sh`：管 agent skills。`verify` 逐个检查 claude 与 codex 两侧是否
  在位，`sync` 重新从 CLI 包安装。**能分辨"真缺失"与"CLI 谎报没捆绑"**（后者退出码 3
  并解释根因），因为这两种情况修法完全不同。16 条断言。

### Fixed

- 守卫把真程序复制成 `/usr/local/bin/coinbase-real.js` 之后，`coinbase skills list`
  开始谎报 `No bundled skills found`、`skills add` 装 0 个：这个 CLI 用
  `import.meta.url` 找自己捆绑的 `skills/`，入口挪了位置就找不到。守卫现在**优先**
  用包里的原始入口（`$(npm root -g)/@coinbase/coinbase-cli/dist/index.js`），
  复制品只作兜底；`install.sh --guard` 与开机自检会把 npm root 写进
  `/usr/local/bin/coinbase-pkg-root` 供守卫读取。

- `scripts/cb-capability.sh`：能力面矩阵。只读探测十个产品面（鉴权/现货行情/余额/
  下单路径/股票可见性/股票下单/Convert/x402/期货/组合），标 `✓ / ✗ / ·` 并写清依据。
  股票刻意不试 `orders create`（真下单会成交，探测不该有副作用）。`--strict` 可接自检。
  18 条断言 + `docs/CAPABILITIES.md`（含两种 403 形态对照表）。
- `cb_timeout`（`scripts/lib/config.sh`）：有 `timeout` 用它、有 `gtimeout` 用它、
  都没有就直跑 —— macOS 上两者都没有，缺一个工具不该让脚本报 command not found。

- `scripts/cb-x402.sh`：x402 付费数据目录与取回。`resources` 把 6 位原子单位
  换算成 USDC 并支持 `--search`/`--limit`；`fetch` 默认只打印将要执行的命令，
  `--commit` 才真付，且必须过 `cb-risk.sh` 闸门（kill switch / 单笔上限）——
  x402 也是花钱，不该绕开同一套限额。28 条断言。
- `guard/mcp-proxy.mjs`：`coinbase mcp` 也过风控闸门。此前二进制守卫只拦得住
  shell 里的 `orders create`，而 agent 实际是通过 MCP server 下单的 —— 那条路
  完全绕过限额。现在 `tools/call` 里会动钱的工具（下单/改单/撤单/平仓/兑换/转账/
  x402 支付/组合增删改）都要先过 `cb-risk.sh check`，两条路径共用一份账本。
- `cb-risk.sh check` 支持可选的第 4 个参数（订单类型），只为让账本记得更准。
- `scripts/cb-orders.sh`：看订单。空结果不再是个谜（说明 recurring buy 不在表里、
  可能还在 PENDING），字段名取自 `coinbase orders list --help` 的 Response 段，
  不是猜的。`--json` 原样输出，`--all` 自动翻页。
- `uninstall.sh`：装得进去也要撤得出来（脚本 / 守卫 / systemd / 配置，`--purge`
  会先归档账本再删）。
- `cb-doctor.sh` 增加 `risk.limits` / `guard.*` 五项：查的是"你以为有闸门，其实没有"。
- `tests/unit/mcpproxy.test.sh`：17 条断言，覆盖透传、闸门、金额算不出来时拒绝、
  参数顺序、风控库缺失时 fail closed。

- `cb-risk.sh report` 把"同一句理由但来自不同层"的原因归并：守卫会在理由末尾
  标 `（coinbase-guard）`，真机上于是出现了"kill switch 开着"和
  "kill switch 开着（coinbase-guard）"两组。现在按拦截层拆开统计，理由本身归一。

### Fixed
- 守卫接管 `mcp` 时漏了 `child.stdout.pipe(process.stdout)`，客户端只会看到请求
  发出去、永远等不到响应（`claude mcp list` 报 30 秒超时，看起来像网络问题）。
- 代理退出时硬 `process.exit()` 会截断管道里还没冲出去的响应，改成记 `exitCode`
  让事件循环自己排空。
- 代理调 `cb-risk.sh check` 时参数错位（把类型当成了金额），导致账本写入 python
  抛 `ValueError` 而**静默丢记录**。现在参数顺序正确，且账本写入失败会大声警告。
- 开机自检除了恢复守卫，也确认 `coinbase-mcp-proxy.mjs` 在位——缺了它
  `coinbase mcp` 会 exit 78。

# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.3.0] — 2026-10-31

加一层"绕不过去"的防线。方向参考了现有 agent 交易项目（Hummingbot 的 kill switch、
TradingAgents 的独立风险复核、tigerpaw 的单笔上限），具体取舍见 `docs/RISK.md`。

### 新增

- `scripts/lib/risk.sh`：风控判定 + 审计账本。账本是
  `~/.config/coinbase-agent/journal.jsonl`（600、只追加），同时充当限额计数器 ——
  日志和计数没有第二个真相来源。
- `scripts/cb-risk.sh`：`show` / `set` / `check` / `kill` / `resume` / `reset` / `journal` / `path`。
  限额键：`max_single_trade_usd`、`max_daily_usd`、`max_orders_per_hour`、`allowed_products`。
- `cb-trade.sh --paper`：模拟盘。记 `paper` 事件、打印真正会执行的命令、不调用 create，
  给 agent 反复演练用。
- `docs/RISK.md`：规则表、什么算额度、"闸门为什么在预览之前"、以及已知限制。
- `tests/unit/risk.test.sh`（36 条）：限额、白名单、kill switch、模拟盘、
  当日累计、每小时笔数、`reset` 归档、以及"被拒只记一条 block"这类记账精度。

### 变更

- `cb-trade.sh` 每笔先过风控闸门（在服务端预览**之前**），并打印名义金额。
  `--commit` 成功记 `exec/ok`、失败记 `exec/error`，失败不占额度。
- kill switch 用**文件**表示（`touch` 即生效），不需要改 JSON、不需要重启 ——
  紧急时谁都能立刻关闸。

### 修复

- `$VAR` 紧跟中文标点导致的 `unbound variable` 又出现两处（`scripts/cb-config.sh`、
  `scripts/lib/risk.sh`），已统一 `${VAR}` 并由 `tests/unit/multibyte.test.sh` 守着。

## [1.2.0] — 2026-10-31

补齐"看得见"和"防得住"这两件事。

### 新增

- `scripts/cb-config.sh`：看当前生效的配置值与来源（环境变量 / 文件），
  `set` / `unset` / `get` / `path` / `--json`。`set portfolio_id` 会先校验 UUID 形状 ——
  拼错的 UUID 不会立刻报错，而是之后每次调用都 403。
- `scripts/cb-products.sh`：查交易对。详情 / `--search` / `--quote` / `--ticker` / `--json`。
  顺带确认 `AAPL-USD` 的 `product_type` 是 `EQUITY` 但行情字段全空 ——
  股票在 Agent API 上只有"能不能交易"，没有"现在多少钱"。
- `scripts/lib/config.sh` 增加 `cb_cfg_set` / `cb_cfg_unset`：原子写（临时文件 +
  `os.replace`），文件 600、目录 700。
- `tests/unit/install.test.sh`（32 条）、`cbconfig.test.sh`（34 条）、`multibyte.test.sh`（5 条）。
  现在 9 个测试文件、200+ 条断言，仍然纯离线。
- 多字节守卫：禁止 `$VAR` 后面直接跟中文标点（bash 3.2 会把它吃进变量名）。

### 修复

- `cb-products.sh` 把服务端的 HTTP 400 `not supported for trading` 当成接口故障，
  用户把产品名打错时会看到"接口调用失败"，方向完全错。现在归到"查不到"（退出码 3）。
- `$VAR` 紧跟中文标点导致 `unbound variable`（本版本内又出现两次，已加守卫）。

### 变更

- `Makefile` 的 `shellcheck` 目标与 CI 现在也检查 `tests/` 下的脚本 ——
  测试脚本里写错不会让 CI 红，只会让测试骗人。

## [1.1.0] — 2026-10-31

从"一堆能跑的脚本"变成"有测试、有 CI、能自诊断的项目"。

### 新增

- `install.sh` 一键安装：环境检查 → 装 CLI → 装脚本 → 写配置 → 可选装
  systemd → 跑自检。不写私钥、不改 agent 配置、不动已有单元。
- `scripts/cb-doctor.sh` 一键诊断（15~16 项），`--json` / `--quiet`，
  退出码 0/1/2 可直接给监控或 CI 用。
- `scripts/cb-portfolio.sh` 逐个探测哪个组合可用，`--save` 记住唯一可用的那个。
  一把 key 只能操作建 key 时选定的组合，光看 403 分不清"没权限"和"不存在"。
- `scripts/lib/config.sh` 共享配置库：环境变量优先于配置文件，统一 NODE_OPTIONS
  检查、颜色输出、JSON 判断。
- `telegram/lib/text.mjs`：按**转义后**长度切块，避开 HTML 实体和 emoji 代理对边界。
- `telegram/lib/agent.mjs`：参数拼装与 stream-json 事件折叠抽成纯函数。
- `telegram/bot.mjs --selftest`：跑一次真实 agent 调用，不碰 Telegram、不写会话状态。
- `tests/`：158 条断言，纯离线，11 秒跑完。`make test` / `make check`。
- `.github/workflows/ci.yml`：shellcheck + 语法检查 + 测试 + 密钥扫描。
- `docs/ARCHITECTURE.md`、`docs/TROUBLESHOOTING.md`。

### 修复

- **`cb-doctor.sh` 的出网探测没有超时**，在没有出口的机器上会永久挂住 ——
  一个用来排查"没反应"的工具自己制造"没反应"。现在请求 3 秒超时 + 5 秒硬看门狗。
- **测试夹具把完整 PEM 标记写进了仓库**，触发自己写的密钥扫描；改为拼接生成。
- **`.test-tmp/` 被提交进公开仓库**（早期手工验证的残留），已清除并加入 `.gitignore`。
- **系统提示里的组合 UUID 是占位符**，生产环境上 agent 会拿它去拼命令然后 403。
  改成运行时从共享配置读，读不到就教它用 `cb-portfolio.sh --show` 查。
- **15 处 shellcheck 报错**：`A && B || C` 当 if-else（10）、`ls | wc -l`（2）、
  `sudo` 重定向（1）、两个死变量（2）。
- **中继器切块按原文长度切而按转义后长度发送**，`<`/`&` 转义放大 4~5 倍后会超过
  Telegram 上限，导致整段回退成纯文本、丢格式和页脚。

### 变更

- CI 从自托管 runner 改回 GitHub 托管 —— 自托管那台机器会被 stop，
  机器一停所有 push 永远停在 queued，等于没有 CI。
- `cb-doctor.sh` 新增 `skip` 状态（`CB_DOCTOR_SKIP_NET=1`）：既不算通过也不算失败，
  JSON 里单独计数。假装通过会骗人，算失败又会误报。
- 契约：**stdout 只放数据，提示与告警一律走 stderr**。

### 踩过的坑（都写进 TROUBLESHOOTING.md）

- IPv6 出网绕过 IPv4 白名单 → 全部 401，而 CLI 把任何 401 都渲染成
  "你需要 ECDSA key"（这句是客户端硬编码的，不是服务端判断）。
- `codex exec` 挂住不动：stdin 没关，它在等 EOF。
- `status=127` 不是脚本丢了，是 `/data` 还没挂上。
- bash 参数展开里的花括号会被数掉；`$(cmd)` 吞掉退出码；
  macOS bash 3.2 遇到中文全角括号会污染变量名。

## [1.0.0] — 2026-10-31

首次发布：把 Coinbase for Agents CLI + DeepSeek V4.1 Flash + Telegram 中继器
在一台 instabox 云主机上配成一套可用、可自愈、开机自动恢复的环境。

- Coinbase CLI 0.0.11，ECDSA (P-256) key，`--allow-plaintext-secrets` + 600。
- 9 个 `coinbase-*` agent skills，MCP 注册（claude / codex 双端）。
- `ds-model.sh`：把两个 agent CLI 的底层模型指向 DeepSeek，key 验证不过则零写入。
- Telegram 中继器：流式编辑同一条消息、会话续接、10 条中文命令、收文件。
- `coinbase-stack.service`：开机 8 项自检 + 自愈，两次真重启验证通过。
