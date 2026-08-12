# 使用指南

本指南详细介绍 ClamshellKit 公开 API 的适用场景、生命周期和错误处理方式

> [!IMPORTANT]
> 屏幕开合角度不是 macOS 公开、稳定的系统能力。
> 如果 `status` 返回 `.available` 状态，后续读取仍可能因设备状态变化而失败，因此所有读取操作都需要处理错误

> [!NOTE]
> `angularVelocity` 和 `angularAcceleration` 根据连续角度样本估算，并非传感器直接提供的原始测量值

## 目录

- [系统要求](#系统要求)
- [使用](#使用)
- [选择合适的 API](#选择合适的-api)
- [创建监视器](#创建监视器)
- [检查可用状态](#检查可用状态)
- [读取当前角度](#读取当前角度)
- [读取完整运动数据](#读取完整运动数据)
- [持续观察](#持续观察)
- [控制发送频率](#控制发送频率)
- [调试诊断](#调试诊断)
- [数据类型](#数据类型)
- [状态与错误](#状态与错误)
- [并发、连接与生命周期](#并发连接与生命周期)
- [完整示例](#完整示例)
- [完整 API 参考](#完整-api-参考)

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS `12` 或更高版本 |
| Swift | Swift `6.0` 或更高版本 |
| 硬件 | 具有兼容屏幕角度传感器的 Mac 笔记本 |

屏幕开合角度不是 macOS 公开、稳定的系统能力，兼容性可能随机型、系统版本和运行环境变化，应在目标设备上验证 `status` 和实际读取结果

## 使用

### Xcode

1. 选择 **File > Add Package Dependencies…**
2. 输入地址

   ```text
   https://github.com/bob-zebedy/ClamshellKit.git
   ```

3. 将 `Dependency Rule` 设置为 **Exact Version** 填写对应的 Tag 版本
4. 将 `ClamshellKit` 添加到 macOS App 的 `target`

### `Package.swift`

将 ClamshellKit 添加到包的依赖中

```swift
dependencies: [
    .package(
        url: "https://github.com/bob-zebedy/ClamshellKit.git",
        exact: "x.x.x"
    )
]
```

然后在对应的 `target` 中引用

```swift
dependencies: [
    .product(name: "ClamshellKit", package: "ClamshellKit")
]
```

## 选择合适的 API

| 需求 | API | 特点 |
| --- | --- | --- |
| 检查功能是否可用 | `status` | 执行一次实时探测 |
| 只需要当前角度 | `angle()` | 一次传感器读取，开销最低 |
| 一次获取角度和运动数据 | `reading()` | 收集短序列后返回估算结果 |
| 连续更新界面或记录数据 | `observe(options:)` | 返回异步流，支持限频和取消 |
| 主动释放传感器连接 | `disconnect()` | 等待资源关闭，监视器之后仍可复用 |
| 排查设备识别、协议解析或运动估算 | `observeDiagnostics(options:)` | 在原有输出之外返回结构化诊断事件 |

建议在同一功能生命周期内复用一个 `ClamshellMonitor` 实例。该类型实现 `Sendable` 协议，可以安全地跨并发任务传递

连接通常会自动管理，需要在明确的生命周期边界立即释放资源时，可以调用 `disconnect()`

## 创建监视器

```swift
import ClamshellKit

let monitor = ClamshellMonitor()
```

`ClamshellMonitor` 没有可配置的初始化参数。调用读取或观察 API 时，它会按需连接传感器；空闲时会自动释放连接

## 检查可用状态

```swift
let status = await monitor.status

if status.isAvailable {
    print("ClamshellKit is available")
}
```

`status` 是异步属性。每次访问都会实际探测当前设备，而不是返回启动时缓存的结果

适合控制功能入口或展示诊断信息，但不应作为错误处理的替代品：状态检查和后续读取之间，设备状态仍可能变化

需要区分不可用原因时，可以匹配所有状态

```swift
switch await monitor.status {
case .available:
    print("可用")
case .unavailable:
    print("当前暂不可用")
case .notFound:
    print("未找到兼容传感器")
case .unsupported:
    print("设备或报告格式不受支持")
case .accessDenied:
    print("macOS 拒绝访问传感器")
}
```

频繁轮询 `status` 会产生实际设备读取。如果需要持续获取数据，应使用 `observe(options:)`

## 读取当前角度

```swift
do {
    let angle = try await monitor.angle()
    print("角度: \(angle.degrees)°")
} catch {
    print("读取失败: \(error.localizedDescription)")
}
```

`angle()` 执行一次传感器读取并返回 `ClamshellAngle`

`degrees` 表示屏幕与机身之间的夹角，返回值以 `°` 为单位

只关心当前角度时应优先调用 `angle()` 方法，与 `reading()` 方法相比，它不需要为估算运动数据收集连续样本，因此返回更快、开销更低

## 读取完整运动数据

```swift
do {
    let reading = try await monitor.reading()

    print("角度: \(reading.angle.degrees)°")
    print("角速度: \(reading.angularVelocity)°/s")
    print("角加速度: \(reading.angularAcceleration)°/s²")
} catch {
    print("读取失败: \(error.localizedDescription)")
}
```

`reading()` 返回 `ClamshellReading` 类型的完整读数，内容如下

| 成员 | 单位 | 含义 |
| --- | --- | --- |
| `angle.degrees` | `°` | 当前屏幕开合角度 |
| `angularVelocity` | `°/s` | 估算角速度，正值表示打开，负值表示合上 |
| `angularAcceleration` | `°/s²` | 估算角加速度 |

该方法需要收集一小段连续角度样本，因此通常不会像 `angle()` 方法一样立即返回

静止时，角速度和角加速度均使用 `0` 表示。判断屏幕是否正在加速或减速时，需要结合角速度与角加速度的符号，而不能只看角加速度

### 当前运动估算参数

当前实现使用偏向响应速度、同时保留整度量化抗噪能力的平衡配置

| 项目 | 当前值 | 作用 |
| --- | --- | --- |
| 角速度窗口 | `350 ms` | 对最近的角度样本执行加权线性回归 |
| 角速度最小样本跨度 | `200 ms` | 样本不足时暂不生成角速度 |
| 角加速度窗口 | `400 ms` | 对最近的角速度样本执行加权线性回归 |
| 角加速度最小样本跨度 | `300 ms` | 样本不足时暂不生成完整读数 |
| 最新样本权重 | 最旧样本的 `1.5` 倍 | 让估算结果更快跟随当前动作 |
| 角速度死区 | `0.75°/s` | 过滤低于可靠范围的速度抖动 |
| 角加速度死区 | `3.5°/s²` | 抵消缩短窗口后增加的量化噪声 |

运动开始还需要窗口内至少出现 `2°` 的角度变化，避免传感器在相邻整度之间抖动时误判。

这些数值属于当前估算实现，不是稳定的公开 API 契约，后续版本可能根据更多设备数据继续调整

## 持续观察

```swift
let observationTask = Task {
    do {
        for try await reading in monitor.observe() {
            print(
                reading.angle.degrees,
                reading.angularVelocity,
                reading.angularAcceleration
            )
        }
    } catch is CancellationError {
        // 主动取消属于正常结束, 不需要提示错误
    } catch {
        print("观察失败: \(error.localizedDescription)")
    }
}

// 不再需要数据时取消任务
observationTask.cancel()
```

`observe(options:)` 返回 `AsyncThrowingStream<ClamshellReading, any Error>` 异步流。方法本身不会抛出错误，连接、读取和参数错误会在遍历流时抛出

观察流具有以下行为

- 建立观察后会先收集足够的样本，再发送第一条完整读数
- 只发送发生变化的读数，不重复发送完全相同的值
- 慢消费者最多保留一条最新待读取值，中间值可能被合并
- 遇到临时断线时会自动尝试重新连接，无法恢复时以错误结束
- 调用 `disconnect()` 时，当前观察流会以 `.disconnected` 结束
- 取消消费任务或释放流后，订阅会自动移除，最后一个订阅结束时连接会关闭

使用 `observe(options:)` 可以展示最新状态，但不能保证交付每一个底层采样值

## 控制发送频率

```swift
let options = ClamshellObservationOptions(maximumFrequency: 10)

for try await reading in monitor.observe(options: options) {
    print(reading.angle.degrees)
}
```

`maximumFrequency` 控制每个观察者每秒最多收到多少条读数

| 值 | 行为 |
| --- | --- |
| 省略或 `30` | 默认最多 `30 Hz` |
| 大于 `0` 的有限值 | 使用指定的最大发送频率 |
| `nil` | 不额外限制发送频率 |
| 值为 `0` 或负数，或者为 `NaN` 及无穷大 | 遍历流时抛出 `.invalidOptions` |

该选项限制的是对调用方的发送频率，不会提高传感器的采样能力。
实际频率不会超过底层传感器支持的上限，而且相同读数不会为了满足频率而重复发送。
多个观察者可以使用不同的 `maximumFrequency` 同时共享一个设备连接。

## 调试诊断

ClamshellKit 默认不产生诊断输出

`observeDiagnostics(options:)` 返回一个独立的 `AsyncStream` 创建并持有该流即为当前 `ClamshellMonitor` 开启对应级别的诊断，取消消费任务或释放流即为关闭

诊断事件是原有 `status`、`angle()`、`reading()` 和 `observe(options:)` 结果之外的旁路数据，不会修改这些 API 的返回值、错误或发送频率

应先建立诊断订阅，再执行需要排查的操作，否则无法收到订阅建立之前发生的设备发现和 Profile 选择事件

```swift
import ClamshellKit

func diagnoseCurrentAngle() async {
    let monitor = ClamshellMonitor()
    let diagnostics = monitor.observeDiagnostics(
        options: .init(level: .verbose)
    )
    let diagnosticsTask = Task {
        for await event in diagnostics {
            print(event.description)
        }
    }
    defer { diagnosticsTask.cancel() }

    do {
        let angle = try await monitor.angle()
        print("角度: \(angle.degrees)°")
    } catch {
        print("读取失败: \(error.localizedDescription)")
    }
}
```

### 诊断级别

各级别按包含关系递增，高级别会同时收到所有低级别事件

| 级别 | 诊断内容 | 建议用途 |
| --- | --- | --- |
| `.off` | 不注册订阅, 返回的流立即结束 | 由应用配置明确关闭诊断 |
| `.basic` | 数据源打开和关闭、候选设备数量、选中的 Profile、重连过程及错误 | 生产环境问题定位和兼容性概览 |
| `.verbose` | 增加候选设备属性、HID Element、每个 Profile 的匹配结果或拒绝原因、报告元数据、解码结果、轮询配置和数据交付统计 | 排查新机型识别、报告布局或数据流问题 |
| `.trace` | 增加原始 HID 报告字节、每个角度样本、速度和加速度回归值、运动状态变化及估算器重置原因 | 开发新的 Profile 或深入分析运动估算，仅短时间开启 |

不传参数时使用 `.basic`

```swift
for await event in monitor.observeDiagnostics() {
    print(event)
}
```

### 结构化事件

每个 `ClamshellDiagnosticEvent` 包含以下成员

| 成员 | 含义 |
| --- | --- |
| `level` | 接收该事件所需的最低诊断级别 |
| `uptimeNanoseconds` | 基于系统单调时钟的纳秒时间戳, 适合排序和计算同一次启动内的间隔, 非挂钟时间 |
| `kind` | 事件类别, 例如 `.profileEvaluated`、`.angleDecoded` 或 `.failure` |
| `fields` | 使用字符串键和 `ClamshellDiagnosticValue` 值表达的事件上下文 |
| `description` | 适合直接写入日志的单行文本, 字段按键名排序 |

如果需要程序化处理，应读取 `kind` 和需要的字段，而不是解析 `description`

```swift
for await event in monitor.observeDiagnostics(
    options: .init(level: .verbose)
) {
    switch event.kind {
    case .profileEvaluated:
        if case let .string(profile)? = event.fields["profile"],
           case let .string(outcome)? = event.fields["outcome"] {
            print("\(profile): \(outcome)")
        }
    case .failure:
        print("诊断错误: \(event.fields)")
    @unknown default:
        break
    }
}
```

事件字段会随事件类别而不同，并可能在兼容版本中增加。调用方应只读取所需字段并忽略额外字段

对 `Kind` 做穷举 `switch` 时，跨模块调用方应保留 `@unknown default` 以便兼容未来新增事件类别

当前事件分为以下几组

| 类别 | `Kind` |
| --- | --- |
| 连接生命周期 | `.sourceOpening`、`.sourceOpened`、`.sourceClosed` |
| 设备与 Profile | `.deviceDiscovery`、`.deviceCandidate`、`.hidElement`、`.profileEvaluated`、`.profileSelected` |
| 报告与解析 | `.reportRead`、`.rawReport`、`.angleDecoded` |
| 轮询与交付 | `.pollingConfigured`、`.delivery` |
| 自动恢复 | `.reconnectAttempt`、`.reconnectSucceeded`、`.reconnectFailed` |
| 运动估算 | `.estimatorSample`、`.estimatorVelocity`、`.estimatorAcceleration`、`.estimatorReset`、`.motionStateChanged` |
| 错误 | `.failure` |

### 事件字段

以下是各事件提供的字段。带 “可选” 标记的字段只会在底层设备或错误包含对应信息时出现

| `Kind` | 级别 | `fields` |
| --- | --- | --- |
| `.sourceOpening` | `.basic` | `profileCount` |
| `.sourceOpened` | `.basic` | `profile` |
| `.sourceClosed` | `.basic` | 无 |
| `.deviceDiscovery` | `.basic` | `candidateCount` |
| `.profileSelected` | `.basic` | `deviceIndex`、`profile`、`match` |
| `.reconnectAttempt` | `.basic` | `attempt`、`delayNanoseconds` |
| `.reconnectSucceeded` | `.basic` | `attempt` |
| `.reconnectFailed` | `.basic` | `attempt`、`error`、`recoverable` |
| `.failure` | `.basic` | `operation`、`error`，以及可选的 `ioReturn`、`systemCode` 或选择失败详情 |
| `.deviceCandidate` | `.verbose` | `deviceIndex`、`elementCount`，以及可选的 `vendorID`、`productID`、`primaryUsagePage`、`primaryUsage`、`transport`、`isBuiltIn` |
| `.hidElement` | `.verbose` | `deviceIndex`、`elementIndex`、`reportKind`、`usagePage`、`usage`、`reportID`、`reportSize`、`reportCount`、逻辑和物理范围、Unit 信息、`isRelative`、`isArray` |
| `.profileEvaluated` | `.verbose` | `deviceIndex`、`profile`、`outcome`，匹配时增加 `match`，拒绝时增加 `reason` |
| `.reportRead` | `.verbose` | `reportType`、`reportID`、`maximumLength`、`actualLength` |
| `.angleDecoded` | `.verbose` | `profile`、`rawValue`、`degrees` |
| `.pollingConfigured` | `.verbose` | `frequency`、`intervalNanoseconds`、`observerCount` |
| `.delivery` | `.verbose` | `angle`、`observerCount`、`deliveredCount`、`droppedCount`、`terminatedCount`、`throttledCount`、`unchangedCount` |
| `.rawReport` | `.trace` | `reportType`、`reportID`、`length`、`bytes` |
| `.estimatorSample` | `.trace` | `angle`、`timestamp`、`angleSampleCount`、`angleSpanNanoseconds` |
| `.estimatorVelocity` | `.trace` | `rawVelocity`、`filteredVelocity`、`isMoving`、`regressionTimestamp`、角度样本数量和跨度 |
| `.estimatorAcceleration` | `.trace` | `rawAcceleration`、`filteredAcceleration`、`isMoving`、速度样本数量和跨度 |
| `.estimatorReset` | `.trace` | `reason`、`wasMoving`、角度和速度样本数量 |
| `.motionStateChanged` | `.trace` | `estimatedVelocity`、`isMoving` |

`.profileEvaluated` 的 `match` 当前可能为 `knownDevice` 或 `compatibleLayout`

`profile` 是不依赖 Swift 类型名的稳定标识符。当前内置 Profile 的标识符为 `apple-hid-orientation-v1`

`.profileEvaluated` 的 `reason` 可能为

| `reason` | 含义 |
| --- | --- |
| `candidateMismatch` | 候选设备不属于该 Profile 搜索的 HID 传感器族 |
| `externalDevice` | 设备明确标记为外置设备 |
| `incompatibleLayout` | HID Element 布局与该 Profile 预期协议不一致 |
| `missingInternalEvidence` | VID/PID 未知, 同时缺少内置设备或内部传输方式的正向证据 |

### Profile 选择与歧义

ClamshellKit 会评估所有已注册 Profile，匹配强度按 `knownDevice` 高于 `compatibleLayout` 排序。只有最强匹配唯一时才会选择，不使用 Profile 注册顺序或设备枚举顺序打破平局

- 同一设备有多个同强度最强 Profile 时拒绝选择
- 多个设备具有同等最强匹配时拒绝选择
- 较弱匹配之间的重叠不会阻止一个唯一的更强匹配被选择

这两类歧义均保持公开错误为 `.unsupported`，并产生 `operation=profile.selection` 的 `.failure` 事件。此时 `reason` 为 `ambiguous`，`ambiguityScope` 为 `profile` 或 `device`，`candidateCount` 是对应范围内的并列候选数，`match` 是并列匹配强度。没有任何 Profile 匹配时，`reason` 为 `unsupported`

这些信息用于判断新机型是 "标识变化但协议兼容" 还是 "报告布局已经变化，需要新增 Profile" 不能只根据 VID/PID 或一份原始报告放宽现有 Profile

新增兼容规则前仍应验证设备来源、完整 HID 布局、读取策略、字节序、数值范围和多次实际读数

新增 Profile 时应提供唯一且发布后保持不变的 `identifier`，实现自己的候选发现、完整布局校验、读取策略和解码逻辑，再将其加入 `HIDProfileRegistry.defaultProfiles`。如果新旧 Profile 会以相同强度匹配同一设备，应先通过更精确的身份或布局条件消除重叠；注册顺序不会被当作协议优先级

### 性能、缓冲与隐私

- 没有活动诊断订阅时，不会创建或缓存 `ClamshellDiagnosticEvent`，也不会格式化日志文本；常规高频事件的字段按需构造
- 每个诊断流独立保留最新 `256` 条事件；消费者跟不上时会丢弃较旧的诊断事件，传感器轮询和原有读数流不会因此阻塞
- `description` 只在调用时格式化 `.trace` 中的原始字节也不会在未订阅对应级别时复制到事件中
- 诊断订阅本身不会打开传感器，也不会让已经空闲的传感器连接保持打开
- 同一个监视器可以存在多个不同级别的诊断订阅，它们拥有独立缓冲和生命周期
- 设备诊断不包含序列号、唯一设备 ID 或用户信息；但 `.trace` 包含原始传感器报告，分享日志前仍应按技术诊断数据审查和裁剪

诊断流用于问题定位，不提供无损审计日志语义。如果必须保留完整事件，应确保消费者足够快，并及时将事件转存到自己的日志系统

## 数据类型

### `ClamshellAngle`

```swift
public struct ClamshellAngle: Sendable, Equatable {
    public let degrees: Double

    public init(degrees: Double)
}
```

该类型表示屏幕与机身之间的夹角。使用 `Equatable` 可以检测角度是否变化，使用 `Sendable` 可以让值安全地跨并发边界传递

### `ClamshellReading`

```swift
public struct ClamshellReading: Sendable, Equatable {
    public let angle: ClamshellAngle
    public let angularVelocity: Double
    public let angularAcceleration: Double

    public init(
        angle: ClamshellAngle,
        angularVelocity: Double,
        angularAcceleration: Double
    )
}
```

表示某一时刻的角度和估算运动状态。公开初始化器便于保存快照、构造测试数据或在应用内部传递统一模型

### `ClamshellObservationOptions`

```swift
public struct ClamshellObservationOptions: Sendable, Equatable {
    public static let `default`: ClamshellObservationOptions
    public var maximumFrequency: Double?

    public init(maximumFrequency: Double? = 30)
}
```

该类型配置单个观察流的发送行为，其中 `ClamshellObservationOptions(maximumFrequency: 30)` 等价于 `.default`

## 状态与错误

### `ClamshellStatus`

| 状态 | 含义 |
| --- | --- |
| `.available` | 找到兼容设备并成功读取有效数据 |
| `.unavailable` | 设备可能存在，但当前无法使用 |
| `.notFound` | 未找到候选角度传感器 |
| `.unsupported` | 找到候选设备，但报告格式不受支持 |
| `.accessDenied` | macOS 拒绝访问设备 |

`isAvailable` 仅在状态为 `.available` 时返回 `true`

### `ClamshellError`

| 错误 | 含义 | 建议处理 |
| --- | --- | --- |
| `.unavailable` | 设备当前不可用 | 稍后重试或禁用相关功能 |
| `.notFound` | 未找到兼容设备 | 提示当前环境未找到兼容传感器 |
| `.unsupported` | 设备或报告格式不受支持 | 更新 SDK 或禁用相关功能 |
| `.accessDenied` | 系统拒绝访问设备 | 提示用户检查运行环境或系统限制 |
| `.disconnected` | 已建立的设备连接失效或被主动关闭 | 意外断开时可以重试；主动断开后按需创建新的数据操作 |
| `.invalidData` | 设备返回无效数据 | 停止使用本次结果并记录诊断信息 |
| `.invalidOptions` | `ClamshellObservationOptions` 无效 | 修正 `maximumFrequency` |
| `.systemError(code:)` | IOKit 返回系统错误 | 记录错误码并按暂时不可用处理 |

所有错误都实现 `LocalizedError` 协议，可以使用 `localizedDescription` 属性获取可读描述

需要针对不同原因采取措施时，应转换为 `ClamshellError`

```swift
do {
    let angle = try await monitor.angle()
    print(angle.degrees)
} catch let error as ClamshellError {
    switch error {
    case .unavailable, .disconnected:
        print("传感器暂时不可用")
    case .notFound, .unsupported:
        print("当前设备不支持屏幕角度读取")
    case .accessDenied:
        print("macOS 拒绝访问传感器")
    case .invalidData:
        print("传感器返回了无效数据")
    case .invalidOptions:
        print("观察参数无效")
    case let .systemError(code):
        print("IOKit 错误: \(code)")
    }
} catch is CancellationError {
    // 正常取消
} catch {
    print(error.localizedDescription)
}
```

## 并发、连接与生命周期

- 类型 `ClamshellMonitor` 与所有公开值类型、状态类型和错误类型均为 `Sendable`
- 同一个监视器上的多个观察流共享一个底层设备连接
- `status` 和一次性读取在没有活动观察者时会按需打开并释放连接
- 观察期间调用一次性读取会复用当前连接
- 每个观察流拥有独立的发送频率和最新值缓冲
- 诊断流不参与设备连接引用计数，单独存在时不会访问或保持硬件
- 每个诊断流拥有独立的级别和 `256` 条最新事件缓冲
- 没有活动观察者时，连接会在一次读取结束或最后一个观察流退出后自动关闭
- 调用 `disconnect()` 会结束当前观察与等待中的 `reading()` 并等待底层连接完整关闭
- 主动断开会清空当前运动估算状态，后续数据操作会按需重新建立连接并收集新样本
- 通常只需取消任务或结束流消费；`disconnect()` 用于需要确定性释放全部当前连接资源的场景

在 App 中持续观察时，建议把返回的 `Task` 保存在与页面或功能相同的生命周期内，并在退出该生命周期时调用 `cancel()` 方法。更新 UI 时再交给 `MainActor` 执行，不要在主线程上进行同步等待

## 完整示例

以下示例先展示不可用原因，再以 `10 Hz` 的最大发送频率持续输出读数

```swift
import ClamshellKit
import Foundation

func observeClamshell() async {
    let monitor = ClamshellMonitor()
    let status = await monitor.status

    guard status.isAvailable else {
        print("屏幕角度传感器不可用: \(status)")
        return
    }

    let options = ClamshellObservationOptions(maximumFrequency: 10)

    do {
        for try await reading in monitor.observe(options: options) {
            print(
                "角度=\(reading.angle.degrees)°, "
                    + "角速度=\(reading.angularVelocity)°/s, "
                    + "角加速度=\(reading.angularAcceleration)°/s²"
            )
        }
    } catch is CancellationError {
        // 调用方结束了观察
    } catch {
        print("观察失败: \(error.localizedDescription)")
    }
}
```

仓库中的 [ClamshellLive](../Examples/ClamshellLive) 提供了可直接运行的终端示例

## 完整 API 参考

所有 API 均可在 `import ClamshellKit` 后使用。

### API 声明

```swift
public final class ClamshellMonitor: Sendable {
    public init()

    public var status: ClamshellStatus { get async }

    public func angle() async throws -> ClamshellAngle
    public func reading() async throws -> ClamshellReading
    public func disconnect() async

    public func observe(
        options: ClamshellObservationOptions = .default
    ) -> AsyncThrowingStream<ClamshellReading, any Error>

    public func observeDiagnostics(
        options: ClamshellDiagnosticsOptions = .default
    ) -> AsyncStream<ClamshellDiagnosticEvent>
}

public struct ClamshellObservationOptions: Sendable, Equatable {
    public static let `default`: ClamshellObservationOptions
    public var maximumFrequency: Double?

    public init(maximumFrequency: Double? = 30)
}

public enum ClamshellDiagnosticsLevel:
    Int, Sendable, Equatable, Comparable
{
    case off = 0
    case basic = 1
    case verbose = 2
    case trace = 3
}

public struct ClamshellDiagnosticsOptions: Sendable, Equatable {
    public static let `default`: ClamshellDiagnosticsOptions
    public var level: ClamshellDiagnosticsLevel

    public init(level: ClamshellDiagnosticsLevel = .basic)
}

public enum ClamshellDiagnosticValue:
    Sendable, Equatable, CustomStringConvertible
{
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case floatingPoint(Double)
    case boolean(Bool)
    case bytes([UInt8])

    public var description: String { get }
}

public struct ClamshellDiagnosticEvent:
    Sendable, Equatable, CustomStringConvertible
{
    public enum Kind: String, Sendable, Equatable {
        case sourceOpening = "source.opening"
        case sourceOpened = "source.opened"
        case sourceClosed = "source.closed"
        case deviceDiscovery = "device.discovery"
        case deviceCandidate = "device.candidate"
        case hidElement = "hid.element"
        case profileEvaluated = "profile.evaluated"
        case profileSelected = "profile.selected"
        case reportRead = "report.read"
        case rawReport = "report.raw"
        case angleDecoded = "angle.decoded"
        case pollingConfigured = "polling.configured"
        case delivery = "reading.delivery"
        case reconnectAttempt = "reconnect.attempt"
        case reconnectSucceeded = "reconnect.succeeded"
        case reconnectFailed = "reconnect.failed"
        case estimatorSample = "estimator.sample"
        case estimatorVelocity = "estimator.velocity"
        case estimatorAcceleration = "estimator.acceleration"
        case estimatorReset = "estimator.reset"
        case motionStateChanged = "estimator.motion-state-changed"
        case failure
    }

    public let level: ClamshellDiagnosticsLevel
    public let uptimeNanoseconds: UInt64
    public let kind: Kind
    public let fields: [String: ClamshellDiagnosticValue]

    public init(
        level: ClamshellDiagnosticsLevel,
        uptimeNanoseconds: UInt64,
        kind: Kind,
        fields: [String: ClamshellDiagnosticValue] = [:]
    )

    public var description: String { get }
}

public struct ClamshellAngle: Sendable, Equatable {
    public let degrees: Double

    public init(degrees: Double)
}

public struct ClamshellReading: Sendable, Equatable {
    public let angle: ClamshellAngle
    public let angularVelocity: Double
    public let angularAcceleration: Double

    public init(
        angle: ClamshellAngle,
        angularVelocity: Double,
        angularAcceleration: Double
    )
}

public enum ClamshellStatus: Sendable, Equatable {
    case available
    case unavailable
    case notFound
    case unsupported
    case accessDenied

    public var isAvailable: Bool { get }
}

public enum ClamshellError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case notFound
    case unsupported
    case accessDenied
    case disconnected
    case invalidData
    case invalidOptions
    case systemError(code: Int32)

    public var errorDescription: String? { get }
}
```

### `ClamshellMonitor`

负责探测、读取和观察屏幕开合传感器。建议在同一功能生命周期内复用实例

#### `init()`

```swift
public init()
```

创建监视器。初始化不会访问硬件，也不会提前建立连接；首次访问 `status` 属性、调用 `angle()` 方法或 `reading()` 方法，或创建普通读数观察流时，才会访问传感器。创建诊断流不会访问硬件

#### `status`

```swift
public var status: ClamshellStatus { get async }
```

实时探测当前设备的可用状态

- 返回值类型为 `ClamshellStatus`
- 每次读取都会执行一次设备探测，不返回缓存状态
- 属性本身不抛出错误，而是将探测错误转换为对应状态
- 出现 `.invalidData` 错误时会映射为 `.unsupported` 状态，无法进一步分类的读取故障会映射为 `.unavailable`

`status` 只能用于预检。后续读取仍可能失败，调用方必须继续处理读取错误

#### `angle()`

```swift
public func angle() async throws -> ClamshellAngle
```

执行一次传感器读取并返回当前屏幕开合角度

- 返回: 包含度数的 `ClamshellAngle`
- 失败: 设备访问或数据读取失败时抛出 `ClamshellError`
- 该方法不收集运动样本，不计算角速度和角加速度
- 没有活动观察者时，本次读取使用的连接会在完成后自动释放

#### `reading()`

```swift
public func reading() async throws -> ClamshellReading
```

返回当前角度以及估算的角速度和角加速度

- 返回值类型为 `ClamshellReading`
- 设备访问失败时抛出 `ClamshellError` 错误，任务取消时可能抛出 `CancellationError`
- 为了估算运动数据，该方法会收集一小段连续样本，通常比 `angle()` 返回更慢
- 如果已有活动观察流和可用读数，监视器会复用现有连接和数据管线

#### `disconnect()`

```swift
public func disconnect() async
```

关闭当前传感器连接并等待相关资源完整释放

- 方法可以重复调用，当前没有连接时直接返回
- 当前观察流和等待中的 `reading()` 会以 `.disconnected` 结束
- 停止当前轮询和重连，并清除角度、角速度及角加速度的估算状态
- `ClamshellMonitor` 实例仍可复用，后续数据操作会按需重新建立连接
- 诊断订阅不会结束，也不会阻止连接关闭
- 与主动断开并发启动的数据操作不保证继续执行；需要重新连接时，应在 `disconnect()` 返回后创建新的操作

#### `observe(options:)`

```swift
public func observe(
    options: ClamshellObservationOptions = .default
) -> AsyncThrowingStream<ClamshellReading, any Error>
```

创建持续发送完整运动读数的异步流

- 参数 `options` 控制当前观察者的最大发送频率，默认使用 `.default`
- 返回值类型为 `AsyncThrowingStream<ClamshellReading, any Error>`
- 创建流时会开始注册观察者，但方法调用本身不执行异步等待，也不抛出错误；注册和读取错误会在消费流时出现
- 无效选项会使流以 `ClamshellError.invalidOptions` 结束
- 缓冲策略为只保留最新的一个待读取值，慢消费者可能跳过中间读数
- 多个观察流共享设备连接，但各自拥有独立的限频配置
- 取消消费任务或释放流会自动移除对应观察者

#### `observeDiagnostics(options:)`

```swift
public func observeDiagnostics(
    options: ClamshellDiagnosticsOptions = .default
) -> AsyncStream<ClamshellDiagnosticEvent>
```

创建独立的结构化诊断事件流

- 参数 `options` 决定当前订阅接收的最高详细级别，默认 `.basic`
- 返回值类型为不会抛出错误的 `AsyncStream<ClamshellDiagnosticEvent>` 错误通过 `.failure` 事件表达
- 创建流时即注册当前诊断订阅；应持续消费返回的流，并在不再需要时取消任务或释放流
- 诊断订阅应在待排查操作之前建立，不能补发此前发生的事件
- 缓冲策略为保留最新 `256` 条事件，慢消费者可能跳过中间诊断事件
- 创建该流不会打开或保持传感器连接，也不会启动普通读数观察
- 使用 `.off` 时返回的流立即结束
- 多个诊断流彼此独立，可同时使用不同级别

### `ClamshellDiagnosticsOptions`

配置单个 `observeDiagnostics(options:)` 调用的详细级别

#### `default`

```swift
public static let `default`: ClamshellDiagnosticsOptions
```

默认配置的 `level` 为 `.basic`

#### `level`

```swift
public var level: ClamshellDiagnosticsLevel
```

当前流接收的最高详细级别。级别具有包含关系，例如 `.verbose` 同时包含 `.basic` 事件

#### `init(level:)`

```swift
public init(level: ClamshellDiagnosticsLevel = .basic)
```

使用指定级别创建诊断配置

### `ClamshellDiagnosticsLevel`

控制诊断事件的详细程度。该类型实现 `Comparable` 顺序为 `.off < .basic < .verbose < .trace`

| 值 | 说明 |
| --- | --- |
| `.off` | 关闭当前诊断订阅 |
| `.basic` | 生命周期、发现结果、Profile 选择、重连和错误 |
| `.verbose` | 增加设备与 HID 布局、Profile 评估、报告解析、轮询及交付 |
| `.trace` | 增加原始报告和逐样本运动估算内部值 |

### `ClamshellDiagnosticEvent`

表示一条结构化诊断事件

#### 事件成员

| 成员 | 类型 | 说明 |
| --- | --- | --- |
| `level` | `ClamshellDiagnosticsLevel` | 接收事件所需的最低级别 |
| `uptimeNanoseconds` | `UInt64` | 单调时钟时间戳，仅用于当前系统启动周期内排序或计算间隔 |
| `kind` | `ClamshellDiagnosticEvent.Kind` | 事件类别 |
| `fields` | `[String: ClamshellDiagnosticValue]` | 与类别相关的结构化上下文 |
| `description` | `String` | 按键名排序后生成的单行日志文本 |

公开初始化器主要用于日志管线适配和测试数据构造。`uptimeNanoseconds` 不是 Unix 时间戳，不能直接转换为日期。

### `ClamshellDiagnosticValue`

表示诊断字段支持的值类型，包括 `.string`、`.integer`、`.unsignedInteger`、`.floatingPoint`、`.boolean` 和 `.bytes`

匹配对应枚举值即可无损读取结构化字段；`description` 适合日志展示，其中字节数组会格式化为空格分隔的大写十六进制

### `ClamshellObservationOptions`

配置单个 `observe(options:)` 调用的发送行为

#### `default`

```swift
public static let `default`: ClamshellObservationOptions
```

默认配置中的 `maximumFrequency` 值为 `30` 并且每秒最多发送 `30 Hz`

#### `maximumFrequency`

```swift
public var maximumFrequency: Double?
```

每秒向当前观察者发送读数的最大次数

- 值为 `nil` 时不额外限制发送频率
- 大于 `0` 的有限值: 使用指定上限
- 值为 `0` 或负数，或者为 `NaN` 及无穷大时无效，消费观察流时产生 `.invalidOptions`
- 该值只限制发送频率，不会改变底层传感器的实际采样上限

配置是值类型。传入 `observe(options:)` 后再修改原变量，不会改变已经创建的观察流。

#### `init(maximumFrequency:)`

```swift
public init(maximumFrequency: Double? = 30)
```

创建观察配置

- 参数 `maximumFrequency` 表示每秒最多发送的读数数量，默认值为 `30`
- 初始化器不会验证参数；参数在传给 `observe(options:)` 时验证

### `ClamshellAngle`

表示 Mac 笔记本屏幕与机身之间的夹角

#### `degrees`

```swift
public let degrees: Double
```

角度值以 `°` 为单位

#### `init(degrees:)`

```swift
public init(degrees: Double)
```

使用指定度数创建角度值。该初始化器不会校验有限性或传感器支持的角度范围

### `ClamshellReading`

表示一个包含角度与估算运动状态的读数快照

#### `angle`

```swift
public let angle: ClamshellAngle
```

当前屏幕开合角度

#### `angularVelocity`

```swift
public let angularVelocity: Double
```

估算角速度使用 `°/s` 作为单位。正值表示屏幕正在打开，负值表示屏幕正在合上，返回 `0` 时表示当前估算为静止

#### `angularAcceleration`

```swift
public let angularAcceleration: Double
```

估算角加速度使用 `°/s²` 作为单位。需要结合 `angularVelocity` 的方向判断屏幕正在加速还是减速

#### `init(angle:angularVelocity:angularAcceleration:)`

```swift
public init(
    angle: ClamshellAngle,
    angularVelocity: Double,
    angularAcceleration: Double
)
```

使用给定数据创建读数快照。该初始化器不会重新估算或校验运动数据，主要用于应用模型转换和测试数据构造

### `ClamshellStatus`

表示当前设备对屏幕角度读取功能的可用状态

#### 状态值

| 状态 | 说明 |
| --- | --- |
| `.available` | 找到兼容设备，并成功读取有效数据 |
| `.unavailable` | 设备可能存在，但当前无法使用 |
| `.notFound` | 未找到候选角度设备 |
| `.unsupported` | 找到候选设备，但其报告格式不受支持 |
| `.accessDenied` | macOS 拒绝访问设备 |

#### `isAvailable`

```swift
public var isAvailable: Bool { get }
```

该属性返回布尔值。状态为 `.available` 时以 `true` 表示，其他状态以 `false` 表示

### `ClamshellError`

表示读取或观察屏幕开合传感器时产生的错误。该类型实现 `LocalizedError` 协议，可通过 `errorDescription` 属性或 `localizedDescription` 属性获取错误描述

#### 错误值

| 错误 | 说明 |
| --- | --- |
| `.unavailable` | 屏幕角度当前不可用 |
| `.notFound` | 未找到兼容的屏幕角度设备 |
| `.unsupported` | 检测到的设备不受支持 |
| `.accessDenied` | macOS 拒绝访问设备 |
| `.disconnected` | 已连接设备断开或连接被主动关闭 |
| `.invalidData` | 设备返回无效数据 |
| `.invalidOptions` | 观察配置无效 |
| `.systemError(code:)` | IOKit 系统错误，字段 `code` 提供原始 `Int32` 错误码 |

#### `errorDescription`

```swift
public var errorDescription: String? { get }
```

返回当前错误的英文说明。针对 `.systemError(code:)` 错误，说明会将错误码格式化为十六进制，便于与 IOKit 诊断信息对应

### 协议遵循

| 类型 | 遵循的协议 |
| --- | --- |
| `ClamshellMonitor` | `Sendable` |
| `ClamshellObservationOptions` | `Sendable` 与 `Equatable` |
| `ClamshellDiagnosticsLevel` | `Sendable`、`Equatable` 与 `Comparable` |
| `ClamshellDiagnosticsOptions` | `Sendable` 与 `Equatable` |
| `ClamshellDiagnosticEvent` | `Sendable`、`Equatable` 与 `CustomStringConvertible` |
| `ClamshellDiagnosticEvent.Kind` | `Sendable` 与 `Equatable` |
| `ClamshellDiagnosticValue` | `Sendable`、`Equatable` 与 `CustomStringConvertible` |
| `ClamshellAngle` | `Sendable` 与 `Equatable` |
| `ClamshellReading` | `Sendable` 与 `Equatable` |
| `ClamshellStatus` | `Sendable` 与 `Equatable` |
| `ClamshellError` | `Error` 和 `LocalizedError` 以及 `Sendable` 与 `Equatable` |
