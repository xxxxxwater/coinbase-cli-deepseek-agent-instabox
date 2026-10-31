# Telegram Agent 中继器

把服务器上的 Agent CLI（Claude Code / Codex）接到 Telegram，用手机就能对话。

## 快速状态

```bash
systemctl status tg-agent          # 运行状态
sudo journalctl -u tg-agent -f     # 实时日志
sudo systemctl restart tg-agent    # 重启
```

开机自启：`enabled`。

## 它是怎么工作的

```
Telegram 用户
   │ sendMessage
   ▼
bot.mjs (长轮询 getUpdates)
   │ spawn
   ▼
claude -p --output-format stream-json --include-partial-messages
   │                 │
   │                 └─ stdout 逐行 JSON → 累积文本 → editMessageText 覆盖同一条消息（流式）
   ▼
DeepSeek 兼容端点 (api.deepseek.com/anthropic)
```

关键点：

- **流式**：靠 `--include-partial-messages` 拿到 `content_block_delta`，按 1.2 秒节流编辑同一条 Telegram 消息。
- **思考阶段**：DeepSeek 先思考后吐字，思考期间显示 `💭 思考中…（N 字）`，否则用户会盯着 `▌` 干等。
- **会话续接**：每轮把 `session_id` 存进 `state.json`，下一轮 `--resume <id>`，所以上下文连续。
- **MCP / skills**：直接复用 `~/.claude.json` 和 `~/.claude/skills`，不需要额外配置。

## 代码结构

单文件 600 行的时候，改一处要读三遍才敢动手。现在拆成三块，边界是"能不能单测"：

| 文件 | 职责 | 怎么测 |
|---|---|---|
| `telegram/bot.mjs` | 长轮询、消息分发、Telegram API 调用、spawn 子进程 | `--selftest` 真跑一次 |
| `telegram/lib/agent.mjs` | 参数拼装（claude/codex）、stream-json 事件折叠、组合提示 | 纯函数，64 条断言 |
| `telegram/lib/text.mjs` | 按**转义后**长度切块、HTML 转义 | 纯函数，22 条断言 |

关键约定：`applyEvent(state, ev)` 返回 `{state, changed}`，**不修改传入的 state**；
`changed` 只表示正文变了 —— thinking 增量不算，否则每来一个 thinking 包就刷新一次消息，
Telegram 会限流。

改完代码的验证顺序：

```bash
node --check telegram/bot.mjs
bash tests/run.sh                       # 离线，11 秒
node telegram/bot.mjs --selftest        # 真跑一次 agent，不碰 Telegram、不写会话
```

`--selftest` 是专门为"部署完想确认 agent 那条路还通，又不想给用户发消息"设计的。
输出长这样：

```
[2026-10-31T07:22:49.552Z] 自检: ok=true code=0 增量长度=4 会话=4145fee5-…
--- 回复 ---
自检通过
```

## 文件

| 路径 | 作用 |
|---|---|
| `/data/home/tg-agent/bot.mjs` | 主程序（Node 22，零依赖） |
| `/data/home/tg-agent/config.json` | token、chat 白名单、模型列表、密钥（600） |
| `/data/home/tg-agent/state.json` | 每个 chat 的后端/模型 + 会话 id |
| `/etc/systemd/system/tg-agent.service` | 服务单元 |

## 命令

`/start` `/help` `/new` `/status` `/stop` `/model` `/backend` `/skills` `/mcp` `/id`

## 改配置

改 `config.json` 后重启服务。字段：

- `allowed_chat_ids`：白名单，别人的 chat id 会被拒绝并回显自己的 id，方便你加人
- `backend`：默认后端，`claude` 或 `codex`
- `model` / `models`：默认模型与 `/model` 可切换列表
- `edit_interval_ms`：流式刷新间隔，默认 1200（Telegram 编辑太快会被限流）
- `max_run_ms`：单次运行硬上限，默认 900000（15 分钟）
- `deepseek_key`：DeepSeek 密钥，注入子进程的 `ANTHROPIC_AUTH_TOKEN` / `DEEPSEEK_API_KEY`

## 踩过的坑（改代码前先看）

1. **codex 的 `wire_api`**：codex 0.160 不再支持 `chat`，必须 `responses`。DeepSeek 有 `/v1/responses`，所以能通。
2. **stdin 必须关闭**：不 `child.stdin.end()`，`codex exec` 会一直等 EOF 挂死。
3. **编辑要在收尾前收敛**：占位消息被删之前必须 await 在途的 `editMessageText`，否则会 400。
4. **不要用 `pkill -f` 清理**：会连自己的 SSH 会话一起杀掉。按 PID 杀。
5. **未授权 chat 也要回消息**：回显对方 chat id，否则加白名单时没法知道 id。

## 安全

- 白名单只有一个 chat id；其他来源一律拒绝。
- `claude` 用了 `--dangerously-skip-permissions`：因为要让它能真正读写文件、跑命令、调 MCP。**这等于把服务器 shell 暴露给这个 bot 的对话权**，所以 token 和 `config.json` 必须保密（600，不要提交到 git）。
- token 泄露的处置：BotFather `/revoke`，然后把新 token 写进 `config.json` 并重启。

## 命令一览（12 条）

| 命令 | 作用 |
| --- | --- |
| `/start` `/help` | 介绍与全部命令说明 |
| `/new` | 开新会话（清空上下文） |
| `/status` | 当前后端、模型、会话 |
| `/stop` | 中断正在生成的回答 |
| `/model` | 查看/切换模型 |
| `/backend` | 切换 claude / codex |
| `/skills` | 列出两侧已装 skills |
| `/mcp` | MCP 连接状态 |
| `/cap` | **能力面**：这把 key 现在能做什么（跑 `cb-capability.sh`） |
| `/risk` | **风控**：限额与今日用量（跑 `cb-risk.sh show`） |
| `/news` | **事件**：官方公告 / 监管 / 主流媒体，按 P0–P3 排（跑 `cb-news.sh`，可 `/news 15` 指定条数） |
| `/brief` | **一屏态势**：风控 + 余额 + 走势 + 事件（跑 `cb-brief.sh`） |
| `/id` | 当前 chat id |

`/cap` 与 `/risk` 是把脚本输出**原样**塞进 `<pre>` 发回来的，不经 agent 总结 ——
这两张表的用处就在具体数字和 ✗ 项上，多一层"总结"会把它们吃掉。

`runScript()` 依次在 `$WORKDIR`、`$HOME/bin`、`$HOME/.local/bin` 里找脚本，
找不到就明确说"找不到 X（找过 …）"，而不是假装跑过了。
