# 故障排查

按"你看到的报错"查，不要按理论顺序查。每条都写清三件事：**为什么**会这样、
**怎么确认**、**怎么修**。

先跑一次 `cb-doctor.sh`，它能覆盖下面一半的情况：

```bash
cb-doctor.sh          # 人看
cb-doctor.sh --json   # 机器看
cb-doctor.sh --quiet  # 只看有问题的
```

---

## 一、鉴权类

### `coinbase balance` 返回 `"unauthorized"`，HTTP 401

**最常见的原因不是 key 错，是出口 IP 不对。**

CDP 门户给 API key 配的 IP 白名单通常只写 IPv4。但这台机器如果同时有 IPv6，
Node 22 的 Happy Eyeballs 会优先连 IPv6，于是请求从白名单之外的地址发出，
服务端一律 401 —— 而 CLI 会把任何 401 都渲染成"你需要 ECDSA key"，
把人引向完全错误的方向。

确认：

```bash
# Node 真实出口（这才是 CLI 用的）
node -e 'require("https").get("https://api.coinbase.com/cdn-cgi/trace",r=>{let b="";r.on("data",d=>b+=d);r.on("end",()=>console.log(b.match(/^ip=(.*)$/m)[1]))})'
# 对比：curl 的出口可能不同，因为 curl 不读 NODE_OPTIONS
curl -s https://api.coinbase.com/cdn-cgi/trace | grep '^ip='
```

修：

```bash
export NODE_OPTIONS="--dns-result-order=ipv4first"
coinbase balance portfolio_id==<uuid>
```

要永久生效，写进 `/etc/environment`（ssh 非登录会话也读）或
`/etc/profile.d/99-node-ipv4.sh`。`cb-doctor.sh` 会检查这一项。

### 报错说 "Coinbase Advanced Trade requires an ECDSA key"，但我的 key 就是 ECDSA

**这句话是 CLI 客户端写死的文案，不是服务端判断。**

它出现在 `@coinbase/coinbase-cli/dist/index.js` 里，条件是 `status === 401`：

```js
r = t === 401 ? "Authentication failed for the current API key. Coinbase
Advanced Trade requires an ECDSA key; if this environment uses Ed25519…" : …
```

所以只要 401 就会看到它。真正的 401 原因要照上一条查（出口 IP、白名单、key 作用域）。

### key 是 Ed25519，怎么都不通

Coinbase App / Advanced Trade 的 API key **不支持 Ed25519**，只支持 ES256
（ECDSA P-256）。官方文档原文：*"Ed25519 (EdDSA) keys are NOT supported."*

判断手里的 key 是哪一种：

```bash
python3 - <<'PY'
import json
d = json.load(open("/path/to/cdp_api_key.json"))
pk = d.get("privateKey") or d.get("secret") or ""
if pk.startswith("-----BEGIN"):
    print("ECDSA（PEM）—— 对")
else:
    import base64
    n = len(base64.b64decode(pk))
    print("Ed25519（%d 字节）—— 不对，去门户重建成 ECDSA" % n if n == 64 else "ECDSA（%d 字节）" % n)
PY
```

重建时门户里要选：**Create API key → Advanced Settings → Signature algorithm = ECDSA**。

### `does not have access to portfolio` 有两种形态，成因不同

| 形态 | 样子 | 含义 |
|---|---|---|
| 长格式 | `rpc error: code = PermissionDenied desc = User does not have access to portfolio; pass a portfolio_id from coinbase_portfolios_list` | 请求打到了 key **作用域之外**的组合（比如默认组合） |
| 短格式 | `{"errorType":"permission_denied","errorMessage":"User does not have access to portfolio"}` | 组合在作用域内，但该**产品线**不接受这个组合（实测：股票单打到现货组合） |

一把 key 只能操作**创建它时选定的那个组合**。查哪个能用：

```bash
cb-portfolio.sh          # 逐个探测
cb-portfolio.sh --save   # 把唯一可用的记进配置
```

### `no environment configured`

`~/.config/coinbase/config.json` 里的 `"env"` 被清空了（通常是清理脚本干的）。
重装一次即可：

```bash
coinbase env live --key-file <key.json> --allow-plaintext-secrets
```

### `secret-tool` 报 `org.freedesktop.secrets was not provided by any .service files`

无头机器没有 Secret Service。装 `libsecret-tools` 只是装了客户端，
**没有 keyring 守护进程**，`secret-tool store` 会失败或直接挂死。

在单用户沙箱里，空口令 keyring 的安全等级和 600 权限的明文文件基本相同，
却多出一个"重启后失效"的故障模式。所以这里的选择是：

```bash
coinbase env live --key-file <key.json> --allow-plaintext-secrets
chmod 600 ~/.config/coinbase/config.json
```

---

## 二、下单类

### 股票报 `standalone order preview is not available for equities`

这不是权限问题，是产品行为：股票的预览必须在 `orders create` 内部完成，
CLI 没有独立的 dry-run 开关。`cb-trade.sh` 遇到 EQUITY 会说明这一点，
并打印将要执行的 create 命令，只有加 `--commit` 才真的下单。

### 股票下单返回短格式 403

见上面"两种 403 形态"。股票通道不接受那把只限现货组合的 key。
余额为 0 时任何单都不会成交，可以先不管。

### `preview insufficient fund`

内部预演已经跑通、鉴权也通过 —— 只是余额不够。这是**好消息**。

---

## 三、模型与 agent 类

### codex 启动就报 `wire_api = "chat"` is no longer supported

codex 0.160 起只认 `wire_api = "responses"`。DeepSeek 提供
`POST /v1/responses`，所以这是正解而不是变通：

```toml
[model_providers.deepseek]
wire_api = "responses"
```

### `codex exec` 挂住不动，几分钟没有任何输出

子进程的标准输入被留成了打开状态的管道，`codex exec` 在等 EOF。
**必须 `child.stdin.end()`**，哪怕不发任何内容。

### Claude Code 说 `"<model>" isn't described by this version's model catalog`

自定义模型名不在 Claude Code 的内置目录里，它会按 200k 上下文估算窗口。
这是保守估计，不影响使用。真要改可以设 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`，
但要先确认模型的真实窗口，否则压缩会算错。

---

## 四、Telegram 中继器类

### 消息发出去没反应

```bash
systemctl status tg-agent
journalctl -u tg-agent -n 50
```

三种常见原因：

1. 进程在跑但长轮询报 `fetch failed` —— 网络抖动，`systemctl restart tg-agent`。
2. 有第二个实例在轮询同一个 bot，Telegram 会给其中一个返回 409 Conflict。
   `pgrep -af bot.mjs` 看看是不是起了两份。
3. chat id 不在 `allowed_chat_ids` 里 —— 直接给 bot 发一句话，它会回显你的 id。

### 长回答被吞了一半，或者只发出第一条

老版本的切块按**原文长度**切，但发出去的是 `<pre>${esc(chunk)}</pre>`。
`<` `&` `>` 转义后会放大 4~5 倍，于是"切的时候 3900 够短、转义完就 15000"，
Telegram 直接 400。现在改成按**转义后长度**二分切，并避开 HTML 实体与
emoji 代理对边界（见 `telegram/lib/text.mjs`）。

### 回答里出现乱码方块

切点切断了 emoji 的代理对。同上，`splitPairs` 已经处理。

---

## 五、开机与系统类

### `coinbase-stack.service` 启动失败，`status=127`

```
/bin/bash: /data/home/coinbase-stack-check.sh: No such file or directory
```

不是脚本不存在，是**挂载还没就绪**。`/data` 由 `instabox-data-init.service`
准备，比普通 unit 启动晚。所以 unit 里必须有：

```ini
After=network-online.target instabox-data-init.service data.mount
RequiresMountsFor=/data/home
```

改完 `systemctl daemon-reload` 再重启，别只 `restart`。

### SSH 被拒绝：`machine ... is stopped`

机器被 `stop` 了。**`stop` 不会被 SSH 唤醒**（官方原文：*"A manual pause or
stop does not wake from a URL"*），必须去 dashboard 点 start。只有 `pause` /
`suspend` 才会被访问自动唤醒。

### 服务明明 enabled，重启后却没跑

`systemctl is-enabled` 只说明"开机时会被启动"，不代表启动成功了。
看 `systemctl status` 的 `status=` 和 `journalctl -u <unit> -b`。
开机自检脚本会把结果写进状态文件，一并检查：

```bash
cat ~/.coinbase-stack-status.json
```

---

## 六、排查方法本身的两条教训

1. **诊断工具报错报错了方向，比没有工具更糟。** 早期版本用 `curl` 判断出网，
   在目标机上一直报 IPv6 失败，可 CLI 明明工作正常 —— 因为 curl 不读
   `NODE_OPTIONS`。诊断必须复现**真实调用路径**，不是"看起来等价"的路径。

2. **不要用 `pkill -f <字符串>` 杀自己正在跑的脚本。** 如果那个字符串也出现在
   当前 ssh 会话的命令行里，会把自己一起杀掉（exit 255）。用 pidfile + `kill`。
