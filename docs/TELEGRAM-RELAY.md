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
