# 守卫：在二进制层兜住"直连下单"

## 为什么需要它

`cb-trade.sh` 会过风控，但 agent 不一定用脚本。它可以直接敲：

```bash
coinbase orders create product_id=BTC-USD side=BUY type=market quote_size=5000
```

这一条会绕过脚本里的所有限额。提示词里写"别超过 100 美元"是劝告，不是闸门。

## 怎么装

```bash
./install.sh --guard
```

它做三件事：

1. 把真的 `/usr/local/bin/coinbase` 改名成 `coinbase-real.js`
2. 把 `guard/coinbase` 装到 `/usr/local/bin/coinbase`（占住这个名字）
3. 把 `guard/mcp-proxy.mjs` 装到同一目录，并在 `$HOME/bin` 留一份自愈副本

撤销：`./uninstall.sh --guard`。

## 真程序为什么必须叫 `.js`

这个 CLI 是 Node ESM 脚本（`#!/usr/bin/env node`）。改名成 `coinbase.real`
之后，node 直接抛：

```
TypeError [ERR_UNKNOWN_FILE_EXTENSION]: Unknown file extension ".real" for /usr/local/bin/coinbase.real
```

所以是 `coinbase-real.js`。守卫的解析顺序：
`CB_REAL_COINBASE` → 同目录 `coinbase-real.js` → 同目录 `coinbase.real`（旧名兼容）
→ 沿 `PATH` 找（跳过自己）。都找不到就 `exit 127`，**绝不自己 exec 自己**。

## 为什么不能只靠 PATH

试过在 `/etc/environment` 的 PATH 里把守卫目录排前面，真机上不生效：

- `ssh host 'cmd'` 是**非登录 shell**，不读 `.bashrc`
- PAM 的 `environment` 不作用于所有 exec 场景
- 结果 `bash -c "command -v coinbase"` 还是 `/usr/local/bin/coinbase`

所以只能占住二进制本身。

## 它拦什么

| 命令 | 行为 |
|---|---|
| `orders create` / `orders cancel` | 过闸门（kill switch + 白名单） |
| `mcp` | 交给 MCP 代理，由代理审 `tools/call` |
| `--version` / `balance` / `products` / `orders preview` / 其它 | 透明转发 |

判不出产品时（白名单开着却解析不 `product_id`）→ `exit 78`。
缺风控库 → `exit 78`。缺 MCP 代理 → `exit 78`。

**"判断不了"不能等于"放行"** —— 这是这个守卫最重要的约定。

## 参数写法坑

两条命令的参数语法不一样：

```bash
coinbase balance  portfolio_id==<uuid>        # 双等号
coinbase orders create product_id=BTC-USD ... # 单等号
```

守卫早期只匹配 `product_id==`，于是白名单形同虚设（真机实测 SOL-USD 直连成功）。
现在四种写法都认：`product_id=`、`product_id==`、`--product_id=`、`--product_id==`。

## 被 npm 覆盖怎么办

`npm i -g @coinbase/coinbase-cli` 会把 `/usr/local/bin/coinbase` 换回真二进制，
**守卫就这么没了** —— 而"守卫悄悄消失"比"从没装过"更危险：两者看起来都是能下单。

`scripts/coinbase-stack-check.sh` 每次开机检测：当前 `coinbase` 里有没有
`# CB_GUARD_V1` 标记；没有就把当前文件 `mv` 成 `coinbase-real.js`、把守卫装回去，
状态记 `guard(restored)`。它同时确认 `coinbase-mcp-proxy.mjs` 在位。

`cb-doctor.sh` 会在运行时检查同一组事实（`guard.on` / `guard.proxy` /
`guard.selfheal` / `guard.off`），其中"守卫在但代理没了"直接判失败 ——
那种状态下 `coinbase mcp` 会 `exit 78`，agent 会说自己"什么都查不到"。

## 它挡不住什么

- 有 sudo 的人可以直接把真二进制换回去。守卫防的是 agent 手滑与被诱导，
  不是防有 root 的攻击者。
- 金额上限目前只在 `cb-trade.sh` 和 MCP 代理里；shell 直连的
  `quote_size=99999` 只受 kill switch 与白名单约束。
  详见 [SECURITY.md](SECURITY.md) 第三节。

## 为什么守卫优先用「包里的原始入口」

第一版守卫把真程序**复制**成 `/usr/local/bin/coinbase-real.js` 再 exec 它。
能用，但有个静默副作用：

```console
$ coinbase skills list
No bundled skills found.
$ coinbase skills add --dir ~/.claude/skills
Installed 0 skills to /home/user/.claude/skills.
```

这个 CLI 用 `import.meta.url` 定位自己捆绑的 `skills/` 目录。入口被复制到
`/usr/local/bin` 之后，它去 `/usr/local/bin/skills` 找 —— 那里当然没有。
**它不报错，只是说"没有捆绑的 skills"**，而 agent 那边表现为"突然不知道有这些能力"。

所以现在的解析顺序是：

1. `CB_REAL_COINBASE`（显式指定）
2. **`$(cat /usr/local/bin/coinbase-pkg-root)/@coinbase/coinbase-cli/dist/index.js`**
3. 常见 npm 全局前缀下的同一个文件
4. 同目录的 `coinbase-real.js` / `coinbase.real`（兜底，会丢 skills 解析）
5. 沿 PATH 找，跳过自己所在目录

`install.sh --guard` 和开机自检都会写 `coinbase-pkg-root`（内容是 `npm root -g`），
所以正常情况下走的都是第 2 条，`skills` 相关命令完好。

诊断：`cb-skills.sh verify` —— 它会把"CLI 谎报没捆绑"（退出码 3）和"真的缺 skill"
（退出码 1）分开报，因为这两种情况的修法完全不同。
