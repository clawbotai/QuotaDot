# DeepSeek API 充值余额接入设计

- **状态：** 已实现，代码复审通过，待发布前手动验收
- **范围：** QuotaDot macOS 原生应用
- **作者：** QuotaDot contributors
- **最后更新：** 2026-04-13

## 1. 摘要

QuotaDot 新增 DeepSeek API provider，展示 DeepSeek 账户的 **CNY 充值余额**。用户可从设置页打开 DeepSeek 官方 API Key 页面，将 Key 粘贴到安全输入框；QuotaDot 先请求官方余额接口验证，成功后才保存到 macOS Keychain。Key 不进入 UserDefaults 或日志，仅作为 `Authorization` header 发送给固定的 DeepSeek 官方余额接口，且禁止重定向。

DeepSeek 的数据语义是货币余额，而不是 Codex/Claude 的时间窗口配额。因此它将复用应用的 provider 容器、悬浮窗、紧凑徽章和菜单项，但使用专门的余额卡片，不使用配额环、最低百分比或活动检测。

## 2. 用户目标与已确认决策

### 2.1 用户目标

在当前 QuotaDot 界面中接入 DeepSeek，并显示：

```text
充值余额：¥ xx.xx
```

### 2.2 已确认决策

| 主题 | 决策 |
|---|---|
| DeepSeek 数据类型 | DeepSeek API 账户余额，而非 Web/Chat 配额或 API 限速 |
| 第一版展示字段 | 仅 CNY 的 `topped_up_balance`（充值余额） |
| 不展示字段 | 累计消费、赠送余额、总余额、RPM/TPM、token 用量、重置时间 |
| 余额不足判断 | 只使用官方 `is_available`；不根据余额金额设置自行阈值 |
| 币种 | 第一版仅支持 CNY；不换汇、不显示 USD |
| Key 来源 | 设置页打开官方 `platform.deepseek.com/api_keys`，用户创建并粘贴 API Key |
| Key 验证 | 先请求官方 `/user/balance`；只有成功响应才允许持久化 |
| Key 存储 | macOS Keychain generic password，`AfterFirstUnlockThisDeviceOnly`；不写入 UserDefaults/日志/文档 |
| 失效处理 | 401/403 立即删除 Keychain 凭据、旧余额和缓存，并提示重新连接 |
| 主动撤销 | 设置页“断开连接”删除 Keychain 凭据和内存余额 |
| 临时故障缓存 | 配置不变时，timeout、离线、429 和 5xx 等临时故障可以保留本次应用进程内的上次成功数据，并明确标为“数据暂存”；该类缓存不受契约异常的 24 小时上限影响 |
| 认证/配置失效 | Keychain 无凭据、401 或 403 时立即移除旧 DeepSeek 数据；401/403 同时删除凭据 |
| 契约/安全边界异常 | redirect 拒绝、响应超限、非预期 HTTP 状态、CNY 缺失或响应无法解码时最多保留缓存 24 小时，并明确显示错误；超过期限后隐藏卡片 |
| 重新连接 | 新 Key 验证期间不持久化；成功后原子替换 Keychain 凭据和余额 |
| 排序 | `Codex → Claude → DeepSeek`；不存在的 provider 不预留位置 |
| 全局百分比 | DeepSeek 不参与最低配额、健康状态、天气背景健康色或双环菜单栏图标 |
| DeepSeek-only 菜单栏 | 没有 Codex/Claude 而有 DeepSeek 数据时，显示 DeepSeek 标识和充值余额 |
| 活动检测 | DeepSeek 不参与本地 JSONL 活动检测，也不显示“正在使用”动画 |

## 3. 目标与非目标

### 3.1 目标

1. 用户能在 QuotaDot 设置页打开官方 API Key 页面，并通过安全输入框粘贴 Key。
2. 应用先验证 Key，成功后才保存到 macOS Keychain；正常刷新从 Keychain 读取。
3. 成功响应中的 CNY 充值余额在悬浮窗、紧凑徽章和菜单栏菜单中正确显示。
4. DeepSeek-only 场景有明确且不显示 `--` 的菜单栏表现。
5. 配置变更、Key 缺失、网络错误、异常响应、余额不可用和数据暂存均有确定、可测试的行为。
6. API Key 只在 SecureField transient draft、验证请求和 macOS Keychain 中出现；不进入 UserDefaults、日志或遥测，只发送给固定的 DeepSeek 官方余额接口。

### 3.2 非目标（第一版明确不做）

- 账户历史累计消费。
- 通过余额下降额推测“消费”。充值、赠送余额、过期、退款和账户调整会使该推断不可靠。
- 显示或折算 USD 等非 CNY 余额。
- 显示 `total_balance`、`granted_balance` 或赠送余额金额。
- 展示 API 调用次数、token 用量、价格估算、限速或重置时间。
- 支持 DeepSeek Chat/Web 的账号额度。
- 网页 OAuth、读取浏览器 localStorage/Cookie 或复用网页登录 Token。
- 将 API Key 保存到 UserDefaults、明文配置、shell、LaunchAgent 或云同步。
- 磁盘持久化余额缓存。

## 4. 事实依据与数据语义

### 4.1 官方接口

DeepSeek 官方文档定义余额接口：

```http
GET https://api.deepseek.com/user/balance
Authorization: Bearer <DeepSeek API Key>
Accept: application/json
```

响应包含：

```json
{
  "is_available": true,
  "balance_infos": [
    {
      "currency": "CNY",
      "total_balance": "12.35",
      "granted_balance": "2.00",
      "topped_up_balance": "10.35"
    }
  ]
}
```

本设计只读取 `balance_infos` 中 `currency == "CNY"` 的唯一条目的 `topped_up_balance`。

### 4.2 为什么不实现“累计消费”

DeepSeek 的价格文档说明费用由 token 消耗、模型单价、缓存命中和时段等决定，且实际费用从赠送余额或充值余额扣除，赠送余额优先。余额接口不包含历史交易或累计消费字段。因此：

```text
当前余额 + 价格表 ≠ 历史累计消费
```

把余额下降命名为“累计消费”会将充值、赠送额度变化、过期、退款或人工调整误报为消费，故第一版不显示该指标。

### 4.3 `is_available` 的解释

`is_available` 表示整个账户余额是否足以调用 API，不表示“充值余额是否大于零”。因此下列状态合法：

```text
充值余额：¥0.00
账户状态：可用
```

这可能代表账户仍有可用的赠送余额。应用不显示赠送金额，但必须尊重官方状态：

| 官方值 | UI 状态 |
|---|---|
| `true` | 可用 |
| `false` | 余额不足 |

`¥0.00` 本身不得触发警告色或“余额不足”。

## 5. 架构设计

### 5.1 现有架构

当前链路为：

```text
本地认证信息
  → Provider Direct Client
  → QuotaStore
  → ProviderUsage / UsageLine
  → 浮窗、紧凑徽章、菜单栏
```

Codex/Claude 的 `UsageLine` 描述时间窗百分比；DeepSeek 余额不能伪装成这类数据。

### 5.2 新增组件

```text
DeepSeekCredentialManager
  ├─ 通过 DeepSeekCredentialStoring 读写/删除 Keychain generic password
  └─ 只公开 hasStoredAPIKey，不把 Key 暴露为可观察属性

SettingsView
  ├─ 在 SecureField 生命周期内管理尚未提交的 transient draft
  └─ 打开官方 API Key 页面并发起连接/重新验证/断开事务

DeepSeekDirectClient
  ├─ 接收调用方提供的临时 API Key，不读取环境或持久化
  ├─ 请求固定的 HTTPS 官方 endpoint
  ├─ 解码并验证余额响应
  └─ 返回 CNY 充值余额快照或无敏感信息的 typed error

QuotaStore
  ├─ 管理 DeepSeek 刷新 task 与 generation
  ├─ 作为 DeepSeek 运行时状态的唯一事实源
  ├─ 处理配置变更导致的清除和重读
  └─ 维持统一 provider 排序

BalanceProviderCard
  ├─ 展示余额而非额度环
  └─ 展示 provider 级更新时间、暂存或错误状态
```

### 5.3 数据模型

建议新增余额值对象：

```swift
struct ProviderBalance: Decodable, Sendable, Equatable {
    let currency: String       // 第一版仅 "CNY"
    let toppedUp: Decimal      // API 的 topped_up_balance
    let isAvailable: Bool      // API 顶层 is_available
}
```

在 `ProviderUsage` 上增加可选字段，并以显式 initializer 保护现有构造点：

```swift
let balance: ProviderBalance?

init(
    providerId: String,
    displayName: String,
    plan: String?,
    lines: [UsageLine],
    fetchedAt: Date?,
    balance: ProviderBalance? = nil
)
```

`ProviderUsage.init(from:)` 必须把旧 JSON 中缺失的 `balance` 解码为 `nil`；不得依赖新增属性后未经验证的自动合成行为。Codex、Claude 现有构造点可以省略默认参数，DeepSeek 显式传入余额。必须加入旧 OpenUsage fixture 不含 `balance` 仍可解码的回归测试。

模型约束：

```text
Codex / Claude：balance == nil，lines 包含配额行
DeepSeek：balance != nil，lines 为空
非法：balance != nil 且 lines 非空
非法：DeepSeek 的 balance == nil
```

显式 initializer 或 factory 必须校验这些 invariant，避免同时拥有 quota 与 balance 的非法状态。

`Decimal` 是必须项：DeepSeek 将金额作为字符串返回，人民币不得用 `Double` 存储或比较。解析先执行完整 ASCII 语法和精度校验，再使用固定 POSIX locale 转成 `Decimal`；显示时才按本设计规定的 CNY 规则格式化。

余额 provider 的类型判定：

```swift
provider.balance != nil  → balance presentation
provider.balance == nil  → quota presentation
```

不要以 `providerId == "deepseek"` 在多个 View 中散落分支；仅 provider 品牌、数据来源和排序可按 ID 映射。

### 5.4 Provider 级刷新状态

现有全局 `lastUpdated` 不能表达某一 provider 已暂存、其他 provider 刚成功更新的情形。DeepSeek 必须有独立、可观察且不包含服务端原文的 typed 状态：

```swift
enum DeepSeekErrorKind: Sendable, Equatable {
    case keyMissing
    case invalidLocalKey       // 空白、控制字符或超过 8 KiB
    case unauthorized          // 401 / 403
    case clientRejected        // 其他 4xx（429 除外）
    case rateLimited           // 429
    case serverUnavailable     // 5xx
    case unexpectedHTTPStatus  // 未归类的非 200，例如未形成 redirect callback 的 1xx/3xx
    case networkFailure
    case redirectRejected
    case responseTooLarge
    case malformedResponse
    case cnyBalanceMissing
}

enum DeepSeekRefreshStatus: Sendable, Equatable {
    case idle
    case checking
    case live(fetchedAt: Date)
    case cached(
        lastSuccessfulFetchAt: Date,
        currentError: DeepSeekErrorKind,
        contractFailure: DeepSeekErrorKind?,
        contractCacheExpiresAt: Date? // 与 contractFailure 必须同时为 nil 或同时非 nil
    )
    case failed(DeepSeekErrorKind)
}
```

`QuotaStore` 是运行时状态的唯一事实源；`DeepSeekCredentialManager` 只封装 Keychain，`SettingsView` 只拥有 SecureField transient draft。SettingsView、余额卡和菜单项都从同一个 Store 读取状态，不复用全局 `errorMessageKey`。

规则：

| 事件 | Provider 数据 | 状态 |
|---|---|---|
| DeepSeek 成功 | 替换余额；记录 `fetchedAt` | `.live(fetchedAt:)` |
| timeout、离线、429、5xx 且曾成功，且不存在已到期的 contract expiry | 保留上次 provider 数据；已有 `contractFailure/expiry` 原样保持 | `.cached(...currentError:errorKind, contractFailure:existing, contractCacheExpiresAt:existing)` |
| timeout、离线、429、5xx，但已有 contract expiry 且 `now >= expiry` | 立即移除 provider，报告被保留的 contract failure | `.failed(contractFailure)` |
| 上述临时错误且从未成功 | 不插入 provider | `.failed(errorKind)` |
| Keychain 无凭据或本地 Key 非法 | 立即移除 provider；不发网络请求 | `.failed(errorKind)` |
| 401 或 403 | 立即移除 provider、pending Key 与 Keychain 凭据 | `.failed(.unauthorized)` |
| `clientRejected` | 立即移除 provider，但保留 Keychain 凭据供后续验证 | `.failed(.clientRejected)` |
| redirect 被拒绝、响应超限、`unexpectedHTTPStatus`、CNY 缺失或 malformed，缓存年龄不超过 24 小时 | 保留上次数据，设置 `contractFailure = errorKind`、`expiry = lastSuccessfulFetchAt + 24h` | `.cached(...currentError:errorKind, contractFailure:errorKind, contractCacheExpiresAt:expiry)` |
| 上述契约/安全边界错误，且无缓存或 `now >= expiry` | 移除 provider | `.failed(errorKind)` |
| task 因配置切换或应用退出而取消 | 不改变新 generation 的数据或状态 | 不产生用户错误 |
| 用户粘贴新 Key 并连接 | 取消旧 task、清除旧 provider；验证成功后才更新 Keychain | `.checking → .live/.failed` |
| 用户断开连接 | 删除 Keychain/pending Key、取消请求并清除 provider | `.idle` |

`lastUpdated` 可以继续用于已有全局 footer，但余额卡必须使用自己的状态和成功时间；不得将其他 provider 的刷新时间显示为 DeepSeek 的更新时间。24 小时上限只适用于 `unexpectedHTTPStatus`、`redirectRejected`、`responseTooLarge`、`malformedResponse` 或 `cnyBalanceMissing` 的契约/安全边界缓存，由独立的 `contractFailure + contractCacheExpiresAt` 保持，直到刷新成功或配置清除。后续纯 timeout、离线、429 或 5xx 只更新 `currentError`，不得清除或延后已有 expiry；每次失败和 60 秒周期都先检查 expiry，一旦 `now >= expiry` 就移除 provider 并转为 `.failed(contractFailure)`。从未发生契约/安全边界错误的临时故障缓存没有该期限。

### 5.5 `QuotaStore` 的接入

应用 composition root 只创建一个 `DeepSeekCredentialManager`：

```text
AppDelegate
  ├─ deepSeekCredentials
  ├─ QuotaStore(deepSeekCredentials: ...)
  └─ SettingsView(store: ..., deepSeekCredentials: ...)
```

新增：

```text
DeepSeekDirectClient 实例（通过 protocol 注入）
DeepSeekCredentialManager 共享实例
pendingDeepSeekAPIKey（仅进程内、网络临时失败重试用）
Task<Void, Never>? deepSeekTask
deepSeekGeneration: UInt64
connectDeepSeek(apiKey:)
disconnectDeepSeek()
launchDeepSeekRefresh()
```

刷新时与现有 provider client 并发执行：

```text
App launch / 每 60 秒 / 立即刷新 → 从 pending Key 或 Keychain 读取；无凭据则不请求
“连接”                          → 新 Key 验证成功后保存 Keychain
“重新验证”                      → 重试 pending Key，否则使用 Keychain
“断开连接”                      → 删除凭据、取消请求并清除数据
```

重新连接必须使用单调递增 generation，不能只比较 Key 值，因为存在 `A → B → A`：

```text
1. generation += 1
2. 立即清除旧 DeepSeek provider 与运行时状态
3. 取消旧 task，并解除旧 task 对 active slot 的所有权
4. 新 task 捕获当前 generation
5. 仅当捕获值仍等于当前 generation 时，才能 apply 结果
6. task 清理也必须校验 generation/task identity，旧 task 不得清除新 task slot
7. 取消、成功和所有错误路径都必须释放其拥有的 slot
```

同一 generation 同一时刻只允许一个 DeepSeek 请求；常规刷新不得重入。`isRefreshing` 必须由实际 active tasks 派生或在 task 完成时复位，不能在只启动子 task 后立即变回 `false`。Store 需要暴露可等待的状态转换或测试 hook，使测试无需 sleep 即可判断请求完成。

排序必须是显式映射，而不是字母序：

```text
codex = 0
claude = 1
deepseek = 2
其他 = 100
```

`lowestRemaining` 只从具有配额 `UsageLine` 的 Codex/Claude provider 得到，余额 provider 必须被忽略。

### 5.6 DeepSeek 请求客户端

`DeepSeekDirectClient` 的职责仅限于：

1. 校验调用方提供的 transient/Keychain API Key（去空白、非空、无控制字符、≤8 KiB）。
2. 向固定 URL `https://api.deepseek.com/user/balance` 发起 GET 请求。
3. 选择并验证 CNY `topped_up_balance`。
4. 返回余额 snapshot 或明确错误；不读取 Keychain/环境，不持久化 Key。

请求安全规则如下：

```text
- HTTPS 固定 endpoint；用户不可配置 host、path 或请求方法
- GET
- Authorization: Bearer <API Key>
- Accept: application/json
- 12 秒超时
- .reloadIgnoringLocalCacheData
- ephemeral URLSession
- 禁用 Cookie storage 和 URL cache
- 禁止所有 HTTP redirect；不得把 Authorization 转发到任何重定向目标
- 最大响应体：1 MiB；Content-Length 超限立即拒绝，chunked 响应累计超过上限立即取消
- 非 200 状态转成 typed error；不得把服务端 body 暴露给 UI 或日志
- 不记录 Authorization、API Key、请求 headers、Key 长度/前后缀或原始响应 body
```

API Key 必须去除首尾空白后检查非空、无控制字符且不超过 8 KiB；失败统一映射为无敏感字段的本地错误，不进入 URLRequest。该检查不记录或展示 Key 的模式、长度或片段。

客户端、Store 与 Keychain 通过 protocol 隔离。Store initializer 注入 DeepSeek client、credential store/manager 和 clock；client 注入可控制 redirect 与流式大小限制的 transport。单元测试使用内存 Keychain fake 与 continuation fake，不读取真实 Keychain、不访问真实网络。

### 5.7 响应验证

1. 顶层 `is_available` 必须存在且可解码。
2. `balance_infos` 中必须恰有一个 `currency` 规范化为 `CNY` 的条目。
3. `topped_up_balance` 先按完整 ASCII 正则 `^[0-9]+(?:\.[0-9]+)?$` 验证，禁止部分解析、分组符号、指数、正负号、NaN、Infinity 和尾随字符。
4. 金额最多 28 位有效数字、最多 2 位小数；超过限制直接判为 malformed，不静默舍入。随后使用 `en_US_POSIX` locale 解析为非负 `Decimal`。
5. 不存在 CNY 条目、重复 CNY 条目、字段缺失或金额非法，都视为本次契约失败。
6. CNY 充值余额为 `0` 是合法成功结果。

第一版金额既然定义为人民币两位小数，就不对服务端超过两位小数的值自行舍入。精确 formatter 和 compact formatter 必须复用同一份已验证 `Decimal`。对于“非 CNY 账户”，第一版不显示 DeepSeek 卡片。Settings 需说明为“未返回 CNY 充值余额”，而不是“余额为零”。

## 6. Keychain 与设置设计

### 6.1 设置页交互

```text
DeepSeek API

状态  ○ 未连接
[安全输入框：粘贴 DeepSeek API Key]

[获取 API Key] [连接] [重新验证] [断开连接]
```

- **获取 API Key**：只用系统默认浏览器打开 `https://platform.deepseek.com/api_keys`，不嵌入网页、不读取浏览器 Cookie/localStorage。
- **连接**：读取 SecureField transient draft，执行本地长度/控制字符校验，再请求 `/user/balance`。成功后才写入 Keychain；失败时不保存。
- **重新验证**：优先使用尚未持久化但因临时网络错误保留在本次进程内的 pending Key，否则读取 Keychain。
- **断开连接**：取消在途请求、递增 generation、删除 Keychain 项并清除 DeepSeek provider/缓存。
- SecureField 在提交或窗口关闭后清空；不得把 draft 写入 UserDefaults、日志或错误文本。

### 6.2 Keychain 契约

使用 macOS Security.framework generic password：

```text
service: com.cmsjcm.QuotaDot.deepseek-api-key
account: default
accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

Keychain 访问封装为 `DeepSeekCredentialStoring`，生产实现使用 Security.framework，测试使用内存 fake，绝不触碰用户真实 Keychain。只暴露 `load/save/delete`，不提供可观察的 Key 字符串；UI 只能读取 `hasStoredAPIKey`。

保存事务：

```text
SecureField draft
→ 本地格式校验
→ 官方余额接口验证
→ Keychain save/update
→ provider live
```

若网络或服务临时失败，candidate 只可保留在当前进程内用于“重新验证”，不得落盘。若 Keychain 写入失败，不展示成功 provider，并显示安全存储失败。若 401/403，立即删除已存凭据和 pending Key。

### 6.3 安全边界

- 不实现网页登录回调，因为 DeepSeek 未公开第三方 OAuth authorization/token/refresh 协议。
- 不读取 `platform.deepseek.com` 的 localStorage `userToken`；网页会话 Token 不是官方 API Key。
- API Key 只发送给固定 `https://api.deepseek.com/user/balance`，禁止所有 redirect。
- 不打印 Key、长度、前后缀、Authorization 或服务端原始错误 body。
- 卸载前可在设置页断开连接；用户也可在 DeepSeek API Key 页面撤销 Key。

## 7. UI/UX 设计

### 7.1 展开悬浮窗

DeepSeek 使用与其他 provider 相同的 Liquid Glass 容器、20pt 水平边距、logo 身份行、provider divider 和天气背景。它是独立余额卡，不套用 `ProviderCard` 的配额环布局：

```text
┌────────────────────────────────┐
│ [DeepSeek]  DeepSeek       可用 │
│             API                 │
│                                │
│          充值余额               │
│          ¥ 12.35                │
│                                │
│                         刚刚更新 │
└────────────────────────────────┘
```

内容规则：

- 标题：`DeepSeek`
- 副标题：`API`
- 金额标签：`充值余额` / `Top-up balance`
- 金额：精确展示 CNY 两位小数，例如 `¥12.35`
- 右上状态：`可用` / `余额不足`
- 底部：实时数据显示相对更新时间；暂存数据显示 `数据暂存 · HH:mm 更新`
- `is_available == false` 时，只给卡片自身的状态文字、图标和强调色设置 warning/critical 表现；不改变全局背景或其他 provider 的状态。
- 不显示 session/weekly 环、活动指示、配额健康状态、重置时间或累计消费占位符。

展开浮窗 Header 同样采用三态，避免 DeepSeek-only 时成功数据旁仍显示 `-- / 正在连接`：

```text
存在 Codex/Claude quota → 保持最低百分比 + quota health
仅存在 DeepSeek          → 隐藏百分比，显示“余额已连接”或“数据暂存”中性状态
无任何 provider          → 显示 -- + 正在连接
```

DeepSeek 的 `is_available == false` 不得改变全局 header health。深色/浅色外观、辅助功能字体和 Reduce Motion 行为必须沿用项目现有 SwiftUI 环境；余额卡不引入不必要的常驻动画。

### 7.2 紧凑悬浮徽章

现有每个 provider 使用 52 × 52pt badge。DeepSeek badge 显示官方图标和压缩金额：

```text
┌────────┐
│  Logo  │
│ ¥12.35 │
└────────┘
```

压缩规则：

| 精确金额 | 徽章文本 |
|---:|---|
| `¥12.35` | `¥12.35` |
| `¥1,234.56` | `¥1.2k` |
| `¥12,345.67` | `¥12.3k` |
| `¥1,234,567.89` | `¥1.2M` |
| `¥1,234,567,890.12` | `¥1.2B` |
| `¥0.00` | `¥0.00` |

要求：

- 紧凑显示只能缩写视觉文本；展开卡始终显示精确两位小数。
- compact formatter 按 `k/M/B` 选择能放入 52pt badge 的单位；超过 `999.9B` 显示 `¥999B+`，避免布局溢出。
- compact formatter 使用 decimal half-up 保留一位小数；这只是视觉缩写，不改变原始金额。
- 小于 `1000` 的金额不做四舍五入到整数而丢失小余额意义。
- `is_available == false` 可在细边框/小状态点表达异常，但不能把金额伪装成百分比或配额环。
- 可访问性标签必须使用精确金额和状态，不使用缩写金额。

### 7.3 菜单栏

菜单栏 label 有三种互斥模式：

| 条件 | 图标与文本 |
|---|---|
| 至少一个配额型 provider（Codex/Claude）存在 | 现有双环 glyph + 最低剩余百分比 |
| 无配额型 provider、DeepSeek 已成功读取 | DeepSeek glyph + 压缩 CNY 充值余额 |
| 没有任何 provider 数据 | 现有双环 glyph + `--` |

如果 DeepSeek 与 Codex/Claude 同时存在，菜单栏仍显示双环和配额最低百分比；DeepSeek 余额不会混入百分比计算。

下拉菜单使用：

```text
Codex · 5h 63% · 周 77%
Claude · 5h 48% · 周 85%
DeepSeek · 充值 ¥12.35
```

DeepSeek 暂存时，菜单行或可访问性说明应能表达“数据暂存”；不应改变主菜单栏文本的金额含义。

### 7.4 图标与品牌映射

新增本地 bundle 资源，例如：

```text
Sources/QuotaDot/Resources/deepseek-official.png
```

图标必须来自可审查的官方或许可兼容来源，随应用打包，不从网络按需下载。`ProviderLogo` 必须改为显式 provider-ID 映射：

```text
claude   → claude-official
codex    → codex-official
deepseek → deepseek-official
unknown  → 安全的通用 fallback（不得错误展示 Codex 图标）
```

## 8. 窗口尺寸与布局契约

当前 `FloatingWindowController` 以 provider 数量乘固定高度估算展开窗口；余额卡、空状态和运行中动态增删 provider 都会破坏这个假设。

新增共享的 presentation/metrics 层，供 SwiftUI 卡片和 `FloatingWindowController` 同时使用：

```text
Header 固定高度
+（无 provider ? empty state 高度 : 所有实际 card 高度 + divider 高度）
+ Footer 固定高度
= 展开窗口高度
```

所有尺寸只在一个共享类型中定义，View 也必须使用同一常量：

```text
quota card（无 reset credits）   174pt
quota card（有 reset credits）   202pt
DeepSeek balance card            132pt
empty state                       170pt
provider divider                    1pt
header                             62pt
footer                             34pt
```

当 provider presentation、Codex reset credits、语言或需要影响布局的状态发生变化时，Controller 必须重新计算展开高度。若窗口当前已展开，应保持右上角不动并实时 resize；若 compact，则继续同步 compact 宽度。旧尺寸更新不能覆盖更新后的 presentation generation。

实现不得继续使用 `96 + providerCount * 174`，也不得让 Controller 和 SwiftUI 各自维护一套数字。自动测试至少覆盖零、一、二、三 provider、Codex credits，以及窗口展开期间 `0 → 1 → 3 → 2` 的动态变化；最终视觉裁切仍列入手动验收。

## 9. 错误、缓存与状态矩阵

| 条件 | UI/数据 | 凭据行为 |
|---|---|---|
| Keychain 无凭据 | 不显示 DeepSeek；Settings 显示未连接 | 不发网络请求 |
| 用户粘贴 Key，验证成功 | 显示实时余额 | 成功后保存/替换 Keychain 项 |
| 粘贴 Key 格式非法 | 清空 SecureField，显示格式错误 | 不请求、不保存 |
| Keychain 保存失败 | 不显示新 provider，显示安全存储失败 | pending Key 只留在进程内供重试 |
| `is_available == false` | 显示金额与余额不足 | 保留有效 Keychain 凭据 |
| 401/403 | 立即移除旧余额，提示重新连接 | 删除 Keychain 和 pending Key |
| 其他 4xx | 移除 provider，显示请求被拒绝 | 暂保 Keychain，允许重新验证 |
| timeout/离线/429/5xx | 按既有临时缓存规则显示数据暂存 | 不改 Keychain；pending Key 可在本进程重试 |
| redirect/响应超限/CNY 缺失/解码失败 | 按 24 小时契约缓存规则处理 | 不改已验证 Keychain 凭据 |
| 用户断开连接 | 清除 DeepSeek provider、缓存和状态 | 删除 Keychain/pending Key并取消任务 |
| 应用退出 | 清除余额、状态与 pending Key | 已验证 Key 仍在 Keychain |

错误日志只记录 provider ID 和可枚举错误分类；不得记录 Key、Authorization、Key 长度/片段、原始 payload 或服务端原始错误 body。

## 10. 本地化文案

最低需要：DeepSeek API、状态、粘贴 API Key、获取 API Key、连接、重新验证、断开连接、未连接、验证中、已连接、连接失效、Keychain 失败、充值余额、余额不足、数据暂存及契约异常。中英文参数数量必须一致。

金额使用固定 CNY 格式，例如 `¥12.35`，不按界面语言换汇。

## 11. 隐私与安全影响

### 11.1 本地数据

- SecureField transient draft：提交或关闭设置页后清空。
- pending Key：只在进程内用于验证/临时故障重试，退出即清除。
- 已验证 Key：保存于 macOS Keychain generic password，`AfterFirstUnlockThisDeviceOnly`。
- UserDefaults、日志和 token-history 索引不得包含 DeepSeek Key。
- 余额与 provider 状态仅在内存中。

### 11.2 网络

- Key 只发送给 `https://api.deepseek.com/user/balance`。
- 禁止 HTTP redirect，避免 Authorization 被转发。
- “获取 API Key”只通过 `NSWorkspace` 打开 `https://platform.deepseek.com/api_keys`；App 不读取浏览器内容或会话。

### 11.3 撤销

- Settings 的“断开连接”删除 Keychain 项。
- 401/403 自动删除 Keychain 项并提示重新连接。
- 用户可在 DeepSeek 官方 API Key 页面撤销 Key。

## 12. 测试策略

测试不得使用真实 API Key、真实网络或用户 Keychain：

- 注入内存 `DeepSeekCredentialStoring`，覆盖 load/save/delete 与 Keychain failure。
- 验证成功前 Key 不得保存；成功后才保存。
- 无凭据时不创建网络请求。
- 401/403 删除已存与 pending Key；断开连接删除凭据和 provider。
- SecureField draft 不写入 UserDefaults/日志，提交或关闭后清空。
- API Key 空白、控制字符、超过 8 KiB 在网络前被拒绝。
- 保留 redirect、Content-Length、chunked 超限、HTTP 分类、严格 Decimal、CNY 缺失测试。
- 保留 generation `A → B → A`、缓存 expiry、防重入、窗口 metrics、菜单栏/header 与旧 JSON 兼容测试。

## 13. 实施顺序

1. 以 `DeepSeekCredentialManager` + `DeepSeekCredentialStoring` 替换环境变量设置。
2. 改造 client 为 `fetch(apiKey:)`，保持 transport 安全边界。
3. 接入验证成功后保存、401/403 删除、断开连接和 pending 重试。
4. 改造 Settings SecureField、官方页面按钮和状态文案。
5. 更新 README、Privacy、Install 与本设计文档。
6. 运行 tests、warnings-as-errors build、localization lint、security audit 和独立代码复审。

## 14. 验收标准

- [ ] Key 只能通过 SecureField transient draft 或 Keychain 进入请求。
- [ ] 官方余额验证成功前不得写入 Keychain。
- [ ] Key 不进入 UserDefaults、日志、文档、命令行或 LaunchAgent。
- [ ] Keychain 使用固定 service/account 与 `AfterFirstUnlockThisDeviceOnly`。
- [ ] 401/403 和主动断开都会删除凭据及旧余额。
- [ ] 不读取浏览器 localStorage/Cookie，不实现未公开 OAuth。
- [ ] 固定 endpoint、redirect 拒绝、1 MiB 上限和 HTTP 状态优先级保持有效。
- [ ] 缓存、generation、Decimal、UI 与向后兼容测试全部通过。
- [ ] README、Privacy、Install 准确描述 Keychain 数据流。

## 15. 已知风险与缓解

| 风险 | 缓解 |
|---|---|
| 用户误贴网页 userToken 或第三方 Key | 官方 `/user/balance` 验证失败，不写 Keychain |
| Keychain 不可用 | 不显示新 provider，提示安全存储失败，允许重试 |
| API Key 被撤销 | 401/403 删除凭据和旧余额，提示重新连接 |
| 浏览器会话凭据泄漏 | App 只打开官方 API Key 页面，不读取网页存储 |
| HTTP redirect 泄漏 Key | transport 禁止全部 redirect，并由真实 URLProtocol 测试覆盖 |
| 临时网络失败发生在首次连接 | candidate 仅在当前进程 pending，永不落盘，支持重新验证 |
| 旧 task 回写 | generation + task identity，覆盖 `A → B → A` 测试 |
| 余额语义与百分比混淆 | 专门余额卡和菜单栏/header 模式，不塞入 `UsageLine` |

## 16. 参考资料

- DeepSeek API Docs, [查询余额](https://api-docs.deepseek.com/zh-cn/api/get-user-balance)
- DeepSeek API Docs, [模型与价格：扣费规则](https://api-docs.deepseek.com/zh-cn/quick_start/pricing#扣费规则)
- DeepSeek official platform favicon, `https://cdn.deepseek.com/platform/favicon.png`（打包资源来源；DeepSeek 商标归其权利人所有）
- 当前项目：`Sources/QuotaDot/Services/CodexDirectClient.swift`
- 当前项目：`Sources/QuotaDot/Services/ClaudeDirectClient.swift`
- 当前项目：`Sources/QuotaDot/Stores/QuotaStore.swift`
- 当前项目：`Sources/QuotaDot/Views/ProviderCard.swift`
- 当前项目：`Sources/QuotaDot/Support/FloatingWindowController.swift`
