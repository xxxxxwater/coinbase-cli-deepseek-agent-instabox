# 能力面：这把 key、这个组合，到底能做什么

Coinbase 的 agent 接口覆盖好几个产品面，可用性由四件事共同决定：

1. **key 的签名算法**（Ed25519 不被支持，必须 ECDSA/P-256）
2. **key 上勾选的权限**（View / Trade / Transfer）
3. **key 绑定的组合**（scope 之外的组合一律 403）
4. **该账户是否开通了对应业务**（股票、期货需要单独资格）

前三条是配置问题，第四条不是你能在 API 侧解决的。**这四类失败全都返回 403**，
而 403 的文案只对其中一部分情况有区分度 —— 所以"能不能做"不该靠试错，
应该有一张表。

`cb-capability.sh` 就是那张表。它**只做只读探测**（包括 `orders preview`，
它不产生订单），每项给出 `✓ 可用 / ✗ 不可用 / · 未判定`，并在说明里写清依据。

```bash
./scripts/cb-capability.sh            # 人看的表
./scripts/cb-capability.sh --json     # 给程序用
./scripts/cb-capability.sh --strict   # 有 ✗ 就退出码 1（放进自检/CI）
```

## 一项真实的输出

```
组合 3e4df874-98c4-4fe7-8988-0bc3170b0b85 的能力面
------------------------------------------------------------
✓ 鉴权 · API key      can_view=True can_trade=True can_transfer=True
✓ 现货 · 行情          返回了数据
✓ 现货 · 余额          返回了数据
✓ 现货 · 下单路径        预览通过（余额不足，这是预期）
✓ 股票 · 产品可见        AAPL-USD product_type=EQUITY
· 股票 · 下单能力        无独立预览（服务端策略），真下单见下文
✗ Convert · 换币      只支持 default portfolio，而 key 绑定的是 Agent MPC
✓ x402 · 付费数据目录   共 127 条资源可发现
✗ 期货 · 快照流         接口返回 invalid request（CFM 期货本身也未对本账户开放）
✓ 组合 · 列表          见 cb-portfolio.sh
------------------------------------------------------------
```

## 每一项在证明什么

| 项 | 探测方式 | 判定 |
| --- | --- | --- |
| 鉴权 | `coinbase api-key permissions` | 返回 `can_view/can_trade/can_transfer` 即通过 |
| 现货 · 行情 | `products get BTC-USD` | 返回 `product_type=SPOT` |
| 现货 · 余额 | `balance portfolio_id==<uuid> show_zero==true` | 返回 `accounts` |
| 现货 · 下单路径 | `orders preview quote_size=1` | `insufficient fund` 也算**通**（鉴权与产品都对，只是没钱） |
| 股票 · 产品可见 | `products get AAPL-USD` | `product_type=EQUITY` |
| 股票 · 下单能力 | `orders preview`（股票） | 服务端固定回"无独立预览"，故只能标未判定 |
| Convert | `convert quote from=USDC to=USD` | 非默认组合固定 403 |
| x402 | `x402 resources` | 数出资源条数 |
| 期货 | `derivatives updates` | 400 `invalid request` |
| 组合 | `portfolios list` | 返回 `portfolios` |

**为什么不试 `orders create`**：真下单一旦被接受就会成交。探测不该有副作用，
所以股票那一项只验证"预览路径存在但不给独立预览"，不拿真钱去确认。

## 常见的能力缺失与含义

### Convert 只支持 default portfolio

```json
{"errorType":"permission_denied","errorMessage":"Convert can only be performed on default portfolio"}
```

这把 key 绑在 `Agent MPC` 组合上，`Agent MPC` 不是 default，所以换币用不了。
两种解法：把 key 绑定到 default 组合重建一把；或者干脆用现货交易代替换币。
**不要**在这条路上反复重试 —— 它不是限流、不是临时故障，重试一万次还是 403。

### 股票产品看得到，下单却被拒

```json
{"errorType":"permission_denied","errorMessage":"User does not have access to portfolio"}
```

注意这条是**短格式**，和"组合不在 key 作用域"的**长格式**不是一回事：

| 形态 | 原文 | 含义 |
| --- | --- | --- |
| 长 | `rpc error: code = PermissionDenied desc = User does not have access to portfolio; pass a portfolio_id from coinbase_portfolios_list` | 组合不在 key 的 scope 里 |
| 短 | `{"errorType":"permission_denied","errorMessage":"User does not have access to portfolio"}` | 组合在 scope 里，但**这个产品通道**拒绝它 |

股票属于后者，配合 `GET /api/v3/brokerage/portfolios/<uuid>` 返回
`"capabilities": []`（空数组）可以确认：这个组合在股票通道上没有交易能力。
要解决得在 Coinbase 账户侧开通股票并绑定组合，API key 无法自行获得。

### 期货

`coinbase derivatives updates` 固定返回 `invalid request`。CFM 日期期货这条通道
在 CLI 里已集成，但账户侧未开放；`derivatives` 子命令目前只有 `updates` 一个。

## 与其他脚本的关系

- `cb-doctor.sh` 查**环境**（Node/IPv4/CLI/key/守卫/限额）——"这套装置装好了吗"
- `cb-capability.sh` 查**能力**（每个产品面能不能做）——"装好了，然后能干什么"
- `cb-portfolio.sh` 查**组合**（哪几个组合这把 key 真能访问）

三个都在只读范围内，都可以随便跑。
