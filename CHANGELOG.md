# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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
