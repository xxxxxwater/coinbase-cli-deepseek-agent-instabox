# coinbase-cli-deepseek-agent-instabox

把 **Coinbase for Agents CLI**、**DeepSeek V4.1 Flash** 和 **Telegram 中继器** 三件事，在一台 instabox 云主机上配成一套可用、可自愈、开机自动恢复的 agent 环境。

目标很具体：**在手机上用中文跟自己的交易服务器对话**，让它查余额、看行情、下单。

---

## 它能做什么

- 通过 Telegram 对话驱动 agent CLI（Claude Code / Codex），流式输出中文回答
- 底层模型走 DeepSeek，不依赖 Anthropic / OpenAI 订阅
- 直接调用 Coinbase：查余额、查组合、查权限、查费率、查行情、现货下单
- 开机自愈：CLI 丢了自动装、key 权限错了自动修、环境变量缺了自动补

## 架构

```
Telegram  ──长轮询──▶  tg-agent.service   (/data/home/tg-agent/bot.mjs, Node 22, 零依赖)
                          │ spawn
                          ├─▶ claude -p --output-format stream-json ──▶ DeepSeek /anthropic
                          └─▶ codex exec ────────────────────────────▶ DeepSeek /v1/responses
                          │
                          └─▶ MCP: coinbase (coinbase mcp) ──────────▶ api.coinbase.com
                                                                      agents.coinbase.com

coinbase-stack.service  (oneshot, 开机执行)
   └─▶ coinbase-stack-check.sh   ── 8 项自检 + 自愈 + 写状态文件
```

两条独立的线：
- **常驻**：`tg-agent.service`——对话入口，`Restart=always`
- **一次性**：`coinbase-stack.service`——每次开机跑一遍自检，`RemainAfterExit=yes`

## 目录

| 路径 | 作用 |
|---|---|
| `scripts/ds-model.sh` | 把 `claude` / `codex` 指向 DeepSeek；key 验证不过则**一个字节都不写** |
| `scripts/cb-activate-key.sh` | 装载 CDP key：先判算法类型，Ed25519 直接拒绝 |
| `scripts/cb-trade.sh` | 下单助手：产品识别 → 余额 → 预览 → 执行；默认只预览，`--commit` 才真下单 |
| `scripts/coinbase-stack-check.sh` | 开机自检 8 项，可自愈的自动修 |
| `telegram/bot.mjs` | Telegram 中继器主体（长轮询 + 流式编辑 + 会话续接 + 收文件） |
| `telegram/config.example.json` | 配置模板，复制成 `config.json` 后填值 |
| `systemd/*.service` | 两个单元文件 |
| `docs/COINBASE-SETUP.md` | Coinbase 侧完整排查记录与报错对照表 |
| `docs/TELEGRAM-RELAY.md` | 中继器运维手册 |

## 快速开始

**前置条件**：Linux + systemd、Node ≥ 22、一把 **ECDSA (ES256)** 的 CDP API key、一个 Telegram bot。

```bash
# 1. 安装 Coinbase CLI
sudo npm install -g @coinbase/coinbase-cli
coinbase --version                     # 0.0.11

# 2. 装 key 文件（必须 600）
install -m 600 cdp_api_key.json ~/cdp_api_key_ecdsa.json

# 3. ⚠️ 关键：强制 Node 走 IPv4（见下面第 1 个坑）
echo 'NODE_OPTIONS=--dns-result-order=ipv4first' | sudo tee -a /etc/environment
export NODE_OPTIONS=--dns-result-order=ipv4first

# 4. 装载 key
coinbase env live --key-file ~/cdp_api_key_ecdsa.json --allow-plaintext-secrets
coinbase env                            # 必须显示 * live

# 5. 验证（必须 200）
coinbase api-key permissions
coinbase balance portfolio_id==$COINBASE_PORTFOLIO_ID show_zero==true

# 6. 切模型到 DeepSeek
./scripts/ds-model.sh --key-file ~/.deepseek-key
# 写完后开新 shell 验证
claude -p '只回一个字：好'
codex exec '只回一个字：好'

# 7. Telegram 中继器
mkdir -p ~/tg-agent && cp telegram/bot.mjs ~/tg-agent/
cp telegram/config.example.json ~/tg-agent/config.json && chmod 600 ~/tg-agent/config.json
# 编辑 config.json 填 token / chat_id / deepseek_key
sudo cp systemd/tg-agent.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now tg-agent
```

开机自启（可选）：

```bash
cp scripts/coinbase-stack-check.sh ~/ && chmod +x ~/coinbase-stack-check.sh
sudo cp systemd/coinbase-stack.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable coinbase-stack
sudo systemctl start coinbase-stack && journalctl -u coinbase-stack -n 30
```

## 五个坑（都真踩过，按踩到的顺序排）

### 1. IPv6 出网 → 所有请求 401 ⭐ 最坑

云主机同时有 IPv4 和 IPv6。CDP 门户的 IP 白名单只加了 IPv4（`x.x.x.x/32`），
但 Node 22 的 Happy Eyeballs 默认**优先连 IPv6**，于是每个请求都从不在白名单里的地址出去，
服务端一律返回 401。

```bash
# 判断方法：看 Coinbase 边缘看到的你到底是谁
curl -s https://api.coinbase.com/cdn-cgi/trace | grep ^ip=
#   ip=2600:1f14:...   ← IPv6，不在白名单，这就是 401 的原因
curl -s https://api.ipify.org                  # 你的 IPv4
```

修法：`NODE_OPTIONS=--dns-result-order=ipv4first`。要写进 4 个地方才不会丢
（`/etc/environment`、`/etc/profile.d/`、`~/.bashrc`、systemd 单元的 `Environment=`）。

### 2. Ed25519 key 不被支持

CDP 门户可以建两种 key，但 **Advanced Trade 只认 ECDSA (ES256)**。
用 Ed25519 建出来的 key，文件长这样（`id` + 88 字符 base64）：

```json
{"id":"...","privateKey":"<64字节 base64>"}
```

这种 key 永远 401，且报错文案极具误导性。正确的 ECDSA key 是 PEM 形态：

```json
{"name":"organizations/.../apiKeys/...","privateKey":"-----BEGIN EC PRIVATE KEY-----\n..."}
```

`cb-activate-key.sh` 会先判类型，Ed25519 直接拒绝装载。

### 3. CLI 的 401 文案会骗人

任何 401 都会被渲染成：

> `Authentication failed for the current API key. Coinbase Advanced Trade requires an ECDSA key; if this environment uses Ed25519, create an ECDSA key and update the environment credentials.`

**这句是客户端硬编码的**，不是服务端判断。我照它去换了两把 key，白忙两小时，
真实原因其实是第 1 条。不要相信这句话，先去看 `cdn-cgi/trace`。

### 4. codex 0.160 只认 `wire_api = "responses"`

```
Error loading config.toml: `wire_api = "chat"` is no longer supported.
How to fix: set `wire_api = "responses"`
```

新版 codex 移除了 chat completions 支持。DeepSeek 确实提供 `POST /v1/responses`，
所以这不是将就，而是正解。

### 5. `/data` 挂载晚于 systemd 单元 → `status=127`

自定义 unit 抢在 `instabox-data-init.service` 前面跑，脚本文件还看不见：

```
/bin/bash: /data/home/coinbase-stack-check.sh: No such file or directory
Main process exited, code=exited, status=127
```

单元里这三行**别删**：

```ini
RequiresMountsFor=/data/home
After=network-online.target instabox-data-init.service data.mount
Wants=network-online.target instabox-data-init.service
```

## 环境变量

| 变量 | 说明 |
|---|---|
| `NODE_OPTIONS` | 必须是 `--dns-result-order=ipv4first`，否则 401 |
| `COINBASE_PORTFOLIO_ID` | 组合 UUID。不设的话 `cb-trade.sh` 和自检里的 balance 会跳过 |
| `DEEPSEEK_API_KEY` | `ds-model.sh` 写进 `~/.config/deepseek/env`，供 codex 使用 |

## 验证清单

```bash
coinbase env                     # * live + key id
coinbase api-key permissions     # can_view/can_trade/can_transfer 全 true
coinbase portfolios list         # 能看到组合，记下 uuid
coinbase balance portfolio_id==<uuid> show_zero==true
coinbase fees                    # Intro 档：taker 0.9% / maker 0.5%
coinbase products get BTC-USD    # product_type: SPOT
systemctl status coinbase-stack  # 8/8 OK
systemctl status tg-agent        # active (running)
```

## 安全说明

- **本仓库不含任何密钥**。`config.json`、`state.json`、`cdp_api_key*.json` 全部在 `.gitignore` 里。
- key 文件权限必须 600；无头服务器没有 keyring 时用 `--allow-plaintext-secrets`（等价于 600 文件保护），
  不要在多人机器上这么用。
- ⚠️ 中继器用 `--dangerously-skip-permissions` 启动 agent：**谁能跟这个 bot 对话，谁就能操作这台服务器**。
  兜底只有单 chat_id 白名单 + 600 配置文件。公网部署请自行加鉴权或改成只读工具集。

## 已知限制

- **股票下单 403**：股票产品可见、下单路径存在，但该组合在股票通道无交易能力
  （`capabilities: []`），疑似需在 Coinbase 账户侧开通并绑定组合，API key 无法自行获得。
- **不带 portfolio_id 的 balance 会 403**：默认组合不在这把 key 的授权范围里，属正常。
- **期货未开通**：`derivatives` 接口返回 400。
- **Telegram 真实入站消息**：自动化测试只能覆盖解析/白名单/分发路径，首次使用请先发 `/start`。

## 许可

MIT
