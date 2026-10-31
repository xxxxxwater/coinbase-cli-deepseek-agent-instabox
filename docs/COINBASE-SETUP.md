# Coinbase CLI 在本机的配置与已知坑

## 结论先说
`coinbase` 已可用。之前所有 HTTP 401 **不是 key 的问题**，是本机走 IPv6 出网、而门户 IP 白名单只配了 IPv4。

## 关键事实
- 环境：`live`（唯一环境），key id `organizations/<YOUR_ORG_ID>/apiKeys/<YOUR_API_KEY_ID>`（agentMPC2，ECDSA / P-256）
- key 文件：`/data/home/cdp_api_key_ecdsa.json`（600）
- 组合：`Agent MPC` = `YOUR_PORTFOLIO_UUID`（这把 key 只有这个组合的权限）
  另外两个：`Default` = `08e010df-...`，`HFT` = `7d34d77c-...`（均无权限，403 正常）
- 出网：IPv4 `203.0.113.10`（已加白名单）；IPv6 `2001:db8::1`（**不在白名单**）

## 根因链
1. 本机同时有 IPv4/IPv6，Node 22 默认 Happy Eyeballs 会优先连 IPv6。
2. `curl https://api.coinbase.com/cdn-cgi/trace` 显示 Coinbase 边缘看到的客户端 IP 是 IPv6 地址。
3. 门户白名单 `203.0.113.10/32` 只覆盖 IPv4，于是每个请求都来自未授权 IP，服务端一律 401。
4. CLI 把任何 401 都渲染成 “requires an ECDSA key”，把我误导了很久 —— 那句是**客户端文案**，不是服务端判断。

## 修复
所有 Node 进程强制 IPv4 优先：`NODE_OPTIONS=--dns-result-order=ipv4first`
已写入 4 处，重启/新会话都不会丢：
- `/etc/environment`（PAM，覆盖 ssh 非登录会话）
- `/etc/profile.d/99-node-ipv4.sh`（登录 shell）
- `~/.bashrc`、`~/.profile`
- `/etc/systemd/system/tg-agent.service` 的 `Environment=`

## 验证过的命令（全部 200）
```
coinbase env
coinbase portfolios list
coinbase api-key permissions          # can_view/can_trade/can_transfer = true
coinbase balance portfolio_id==$COINBASE_PORTFOLIO_ID
coinbase fees                          # Intro 档 taker 0.9% maker 0.5%
coinbase products get BTC-USD          # 77019
coinbase products list symbol==USD --jq ".products | length"   # 121
```
注意 `balance` 不带 `portfolio_id` 会 403（默认组合不在授权范围），这是正常的。

## 报错对照
| 现象 | 原因 |
|---|---|
| `"unauthorized"` / HTTP 401 | NODE_OPTIONS 没生效，走了 IPv6 |
| `permission_denied ... pass a portfolio_id` | balance 没带 portfolio_id |
| `User does not have access to portfolio` | 查了 Default / HFT 组合 |
| `derivatives updates` 400 invalid request | 期货接口需要具体合约参数，且该账户暂未开通 |

## 开机自启动

Coinbase CLI 是命令不是常驻进程，所以它没有"启动"这回事；
随开机恢复的是**让它能工作的一切**，由一个 oneshot 单元保证：

```
coinbase-stack.service   (enabled, oneshot, RemainAfterExit=yes)
  ExecStart=/bin/bash /data/home/coinbase-stack-check.sh
```

开机时按顺序自检并自愈：

| 项 | 检查 | 自愈动作 |
|---|---|---|
| node_options | /etc/environment 含 dns-result-order=ipv4first | 追加（缺失时） |
| cli | `coinbase --version` | 缺失则 `npm i -g @coinbase/coinbase-cli` |
| keyfile | `/data/home/cdp_api_key_ecdsa.json` 存在且 600 | chmod 600 |
| env_live | `coinbase env` 显示 `* live` | 自动执行 `coinbase env live --key-file …` |
| skills | claude/codex 各 9 个 skill | 只报告 |
| mcp | claude.json + codex config.toml 各有 coinbase | 只报告 |
| api_key | `coinbase api-key permissions` 返回 can_* | — |
| balance | `coinbase balance portfolio_id==AgentMPC` 返回 accounts | — |

结果写到 `/data/home/.coinbase-stack-status.json`，日志 `/data/home/.coinbase-stack.log`。

常用命令：

```
systemctl status coinbase-stack     # 看上次开机自检结果
sudo systemctl start coinbase-stack # 手动重跑一次自检
journalctl -u coinbase-stack -n 50  # 看日志
```

另有一个真正的常驻服务：`tg-agent.service`（enabled + active），
它是 Telegram 侧的对话入口，也随开机自启。

### 排序依赖（血泪，别删）

第一次装的时候开机是 **failed**，日志：

```
/bin/bash: /data/home/coinbase-stack-check.sh: No such file or directory
Main process exited, code=exited, status=127
```

原因：`/data` 是独立盘（`/dev/vdb`），开机时由 `instabox-data-init.service` 准备，
比 `multi-user.target` 早不了多久。unit 抢在前面跑，脚本文件还看不到。

修复后 unit 必须保留这三行：

```
RequiresMountsFor=/data/home
After=network-online.target instabox-data-init.service data.mount
Wants=network-online.target instabox-data-init.service
```

另外脚本里 api_key / balance 两项各带 3 次重试（间隔 5s），
避免开机瞬间网络还没通就判失败。

### 实测：两次真重启

| 时间(UTC) | 事件 |
|---|---|
| 06:16:55 | 第一次重启 → unit failed（/data 未就绪）|
| 06:19:3x | 修好排序后手动跑 → 8/8 OK |
| 06:23:46 | 第二次重启 |
| 06:23:49 | unit 自动启动 |
| 06:23:52 | `Finished` 8/8 OK，状态文件已刷新 |
