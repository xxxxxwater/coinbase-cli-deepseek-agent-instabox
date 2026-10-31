# 架构

这套东西解决一个问题：**让一个 AI agent 能安全地看和动 Coinbase 账户，并且能远程对话**。
它不是个应用，是三层拼起来的一台机器的配置 —— 所以架构文档的重点是
"哪一层负责什么、坏了先看哪层"。

```
                    ┌──────────────────────────────────────────┐
   你在 Telegram ──▶│  tg-agent.service  (Node 22, 无依赖)      │
                    │  长轮询 → 白名单 → 流式编辑同一条消息      │
                    └───────────────┬──────────────────────────┘
                                    │ spawn
                                    ▼
                    ┌──────────────────────────────────────────┐
                    │  claude / codex  (agent CLI)             │
                    │  + 9 个 coinbase-* skills                │
                    │  + MCP: coinbase / instabox / computer   │
                    │  底层模型 = DeepSeek V4.1 Flash          │
                    └───────────────┬──────────────────────────┘
                                    │ 调用
                                    ▼
                    ┌──────────────────────────────────────────┐
                    │  coinbase CLI 0.0.11                     │
                    │  JWT (ES256, 每次请求现签)                │
                    └───────────────┬──────────────────────────┘
                                    │ HTTPS，出口必须是白名单里的 IPv4
                                    ▼
                         api.coinbase.com / agents.coinbase.com
```

## 一、分层职责

| 层 | 组件 | 只负责 | 坏了的表现 |
|---|---|---|---|
| 鉴权 | CDP API key（ECDSA P-256）+ `~/.config/coinbase/config.json`(600) | 证明"这是谁" | 全部 401 |
| 传输 | `NODE_OPTIONS=--dns-result-order=ipv4first` | 从白名单 IP 出网 | 全部 401（和上一层同样的表现，最容易误判） |
| 客户端 | `coinbase` CLI | 拼请求、签 JWT、渲染 JSON | 单条命令报错 |
| 能力 | 9 个 `coinbase-*` skills | 教 agent"怎么用 CLI" | agent 瞎猜命令 |
| 会话 | `claude` / `codex` + DeepSeek 重定向 | 跑 agent 循环 | 模型报错或超时 |
| 入口 | `tg-agent.service` | 把对话搬进 Telegram | Telegram 没反应 |
| 自愈 | `coinbase-stack.service`（oneshot） | 开机把上面全查一遍，缺什么补什么 | 重启后"看起来没装" |

**关键点：鉴权层和传输层的故障表现完全一样（都是 401）**，而 CLI 的报错文案
又会把人指向"算法不对"。所以诊断顺序永远是：

```
1. 出口 IP 对不对   →  cb-doctor.sh 的 net.edge 这一项
2. key 是不是 ECDSA  →  cb-doctor.sh 的 key.type
3. key 有没有这个组合 → cb-portfolio.sh
4. 前面都对 → 才去怀疑 CLI 和网络
```

## 二、为什么这么设计

### 明文存 key，而不是 keyring

无头机器没有 Secret Service 守护进程，`secret-tool store` 会失败甚至挂死。
在单用户沙箱里，空口令 keyring 与实际防护等级等于一个 600 权限的文件，
却多一个"重启后失效"的故障模式。所以选择 `--allow-plaintext-secrets` + 600，
并且把"这个文件就是凭证"写进文档，而不是让人误以为有加密。

### 把 IPv4 钉死在系统级，而不是每次跑命令加参数

因为忘一次就是 401，而 401 的报错会把人带到错误方向。钉在
`/etc/environment`（PAM，ssh 非登录会话也读）+ `/etc/profile.d/` +
systemd unit 的 `Environment=`，覆盖交互 shell、非交互 ssh、服务三种场景。

### Telegram 中继器是 spawn agent CLI，不是自己调模型 API

直接调 API 的话，skills、MCP、工具调用、会话续接全都要重新实现一遍。
spawn `claude -p --output-format stream-json` 相当于复用了整套 agent 能力，
中继器只需要做三件事：把流式增量渲染成消息编辑、维护 session id、做白名单。

代价是每轮对话要起一个进程（冷启动约 1 秒），这个代价换掉的是几千行重复实现。

### stdout 只放数据，提示全部走 stderr

起因是一个真实的 bug：测试用 `2>&1` 抓 `--json` 的输出，结果"已补 NODE_OPTIONS"
这句提示被并进了 JSON 里，解析直接崩。从那以后定成契约：
**管道里只有数据，人能读的话一律 stderr。**

### 所有脚本共用一个 `scripts/lib/config.sh`

配置路径、环境变量优先级、组合 UUID、NODE_OPTIONS 检查这些逻辑如果在四个脚本里
各写一遍，就会出现"cb-doctor 说没配好、cb-trade 却能用"这种自相矛盾。
共享库让"配置怎么读"只有一个答案。

## 三、文件布局

```
├── install.sh                 一键安装（环境检查 → CLI → 脚本 → 配置 → unit → 自检）
├── scripts/
│   ├── lib/config.sh          共享：配置读写、颜色、NODE_OPTIONS、组合 UUID
│   ├── cb-activate-key.sh     校验 key 类型并装载
│   ├── cb-portfolio.sh        探测哪个组合能用，--save 记住
│   ├── cb-trade.sh            下单（默认只预览，--commit 才真发）
│   ├── cb-doctor.sh           一键诊断（15~16 项，0/1/2 退出码）
│   ├── coinbase-stack-check.sh 开机自检的实体（8 项 + 自动修复）
│   └── ds-model.sh            把 claude/codex 的底层模型指向 DeepSeek
├── systemd/
│   ├── coinbase-stack.service oneshot + RemainAfterExit
│   └── tg-agent.service       常驻中继器
├── telegram/
│   ├── bot.mjs                长轮询 + 流式编辑
│   └── lib/text.mjs           按转义后长度切块（HTML 安全）
├── tests/                     helper.sh + run.sh + unit/*.test.sh
└── docs/
    ├── COINBASE-SETUP.md      真机上跑通的完整配置记录
    ├── TELEGRAM-RELAY.md      中继器运维
    ├── ARCHITECTURE.md        本文件
    └── TROUBLESHOOTING.md     按报错查
```

## 四、一次 `coinbase balance` 的完整路径

```
cb-trade.sh balance
   └─ cb_portfolio_id     读配置 → 环境变量 COINBASE_PORTFOLIO_ID 优先
      └─ coinbase balance portfolio_id==<uuid>
         └─ CLI 读 config.json 拿 key → 签 JWT(ES256)
            header {alg,typ,kid,nonce}  payload {sub,iss,nbf,iat,exp,uris}
            └─ Node 解析 DNS（ipv4first）→ HTTPS
               └─ 服务端校验：签名 ✓ / kid 存在 ✓ / 源 IP ∈ 白名单 ✓ / 组合 ∈ key 作用域 ✓
                  └─ 200 JSON → cb-trade.sh 用 python3 取字段 → stdout
```

四个校验里任何一环失败，客户端看到的都是 401 或 403 —— 这是最容易让人
在错误方向上花掉半天的原因，也是 `cb-doctor.sh` 存在的理由。

## 五、开机时发生什么

```
开机
 └─ instabox-data-init.service   准备 /data 挂载点
     └─ data.mount               挂上持久盘（/data/home 在这里面）
         └─ coinbase-stack.service  RequiresMountsFor=/data/home 才敢启动
             ├─ 检查/补 NODE_OPTIONS（/etc/environment + profile.d）
             ├─ 检查/补 coinbase CLI
             ├─ 检查 key 文件权限 600
             ├─ 检查 env 是否 live（不是就重装 key）
             ├─ 检查 9 个 skills / MCP 注册
             ├─ 检查 api-key permissions（3 次重试）
             └─ 检查 balance（3 次重试）
                 └─ 结果写 ~/.coinbase-stack-status.json
```

**顺序依赖是硬要求**：少了 `RequiresMountsFor` 就会在挂载完成前执行，
报 `/bin/bash: ...: No such file or directory` + `status=127`。
这不是"脚本不存在"，是"盘还没挂上"。这个坑真机上踩过一次，见 TROUBLESHOOTING。

## 六、边界：这套东西不做什么

- 不做自动交易策略。`cb-trade.sh` 是执行器，不是决策器。
- 不绕过 CDP 的权限模型。key 能操作哪个组合是门户决定的，脚本只是尊重它。
- 不在网页里点。所有操作走官方 CLI / API，没有浏览器自动化。
- 不隐藏风险。`tg-agent` 用 `--dangerously-skip-permissions` 跑 agent，
  等于"能对话就能操作这台机器"，靠单 chat 白名单兜底 —— 这个取舍写在 README 里，
  不写成"安全隔离"。
