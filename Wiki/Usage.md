# 使用指南

本指南详细介绍 ClamshellKit 公开 API 的适用场景、生命周期和错误处理方式。

> [!IMPORTANT]
> 屏幕开合角度不是 macOS 公开、稳定的系统能力。
> 如果 `status` 返回 `.available` 状态，后续读取仍可能因设备状态变化而失败，因此所有读取操作都需要处理错误。

> [!NOTE]
> `angularVelocity` 和 `angularAcceleration` 根据连续角度样本估算，并非传感器直接提供的原始测量值。

## 目录

- [系统要求](#系统要求)
- [安装](#安装)
- [选择合适的 API](#选择合适的-api)
- [创建监视器](#创建监视器)
- [检查可用状态](#检查可用状态)
- [读取当前角度](#读取当前角度)
- [读取完整运动数据](#读取完整运动数据)
- [持续观察](#持续观察)
- [控制发送频率](#控制发送频率)
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

屏幕开合角度不是 macOS 公开、稳定的系统能力，兼容性可能随机型、系统版本和运行环境变化。
集成后应在目标设备上验证 `status` 和实际读取结果。

## 安装

### Xcode

1. 选择 **File > Add Package Dependencies…**
2. 输入仓库地址

   ```text
   https://github.com/bob-zebedy/ClamshellKit.git
   ```

3. 将 `Dependency Rule` 设置为 `Branch` 并填写 `main`
4. 将 `ClamshellKit` 添加到 macOS App 的 `target`

### `Package.swift`

将 ClamshellKit 添加到包的依赖中：

```swift
dependencies: [
    .package(
        url: "https://github.com/bob-zebedy/ClamshellKit.git",
        branch: "main"
    )
]
```

然后在对应的 `target` 中引用：

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

建议在同一功能生命周期内复用一个 `ClamshellMonitor` 实例。该类型实现 `Sendable` 协议，可以安全地跨并发任务传递。使用时不需要手动打开或关闭传感器连接。

## 创建监视器

```swift
import ClamshellKit

let monitor = ClamshellMonitor()
```

`ClamshellMonitor` 没有可配置的初始化参数。调用读取或观察 API 时，它会按需连接传感器；空闲时会自动释放连接。

## 检查可用状态

```swift
let status = await monitor.status

if status.isAvailable {
    print("ClamshellKit is available")
}
```

`status` 是异步属性。每次访问都会实际探测当前设备，而不是返回启动时缓存的结果。
它适合控制功能入口或展示诊断信息，但不应作为错误处理的替代品：状态检查和后续读取之间，设备状态仍可能变化。

需要区分不可用原因时，可以匹配所有状态：

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

`degrees` 表示屏幕与机身之间的夹角，返回值以 `°` 为单位。

只关心当前角度时应优先调用 `angle()` 方法。与 `reading()` 方法相比，它不需要为估算运动数据收集连续样本，因此返回更快、开销更低。

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

`reading()` 返回 `ClamshellReading` 类型的完整读数，内容如下：

| 成员 | 单位 | 含义 |
| --- | --- | --- |
| `angle.degrees` | `°` | 当前屏幕开合角度 |
| `angularVelocity` | `°/s` | 估算角速度，正值表示打开，负值表示合上 |
| `angularAcceleration` | `°/s²` | 估算角加速度 |

该方法需要收集一小段连续角度样本，因此通常不会像 `angle()` 方法一样立即返回。静止时，角速度和角加速度均使用 `0` 表示。判断屏幕是否正在加速或减速时，需要结合角速度与角加速度的符号，而不能只看角加速度。

### 当前运动估算参数

当前实现使用偏向响应速度、同时保留整度量化抗噪能力的平衡配置：

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
这些数值属于当前估算实现，不是稳定的公开 API 契约，后续版本可能根据更多设备数据继续调整。

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

`observe(options:)` 返回 `AsyncThrowingStream<ClamshellReading, any Error>` 异步流。方法本身不会抛出错误，连接、读取和参数错误会在遍历流时抛出。

观察流具有以下行为：

- 建立观察后会先收集足够的样本，再发送第一条完整读数
- 只发送发生变化的读数，不重复发送完全相同的值
- 慢消费者最多保留一条最新待读取值，中间值可能被合并
- 遇到临时断线时会自动尝试重新连接，无法恢复时以错误结束
- 取消消费任务或释放流后，订阅会自动移除，最后一个订阅结束时连接会关闭

使用 `observe(options:)` 可以展示最新状态，但不能保证交付每一个底层采样值。如果业务要求无损记录所有原始样本，当前 API 不提供该语义。

## 控制发送频率

```swift
let options = ClamshellObservationOptions(maximumFrequency: 10)

for try await reading in monitor.observe(options: options) {
    print(reading.angle.degrees)
}
```

`maximumFrequency` 控制每个观察者每秒最多收到多少条读数：

| 值 | 行为 |
| --- | --- |
| 省略或 `30` | 默认最多 `30 Hz` |
| 大于 `0` 的有限值 | 使用指定的最大发送频率 |
| `nil` | 不额外限制发送频率 |
| 值为 `0` 或负数，或者为 `NaN` 及无穷大 | 遍历流时抛出 `.invalidOptions` |

该选项限制的是对调用方的发送频率，不会提高传感器的采样能力。
实际频率不会超过底层传感器支持的上限，而且相同读数不会为了满足频率而重复发送。
多个观察者可以使用不同的 `maximumFrequency` 同时共享一个设备连接。

## 数据类型

### `ClamshellAngle`

```swift
public struct ClamshellAngle: Sendable, Equatable {
    public let degrees: Double

    public init(degrees: Double)
}
```

该类型表示屏幕与机身之间的夹角。使用 `Equatable` 可以检测角度是否变化，使用 `Sendable` 可以让值安全地跨并发边界传递。

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

表示某一时刻的角度和估算运动状态。公开初始化器便于保存快照、构造测试数据或在应用内部传递统一模型。

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
| `.disconnected` | 已建立的设备连接失效 | 一次读取可重试；观察流会先尝试自动恢复 |
| `.invalidData` | 设备返回无效数据 | 停止使用本次结果并记录诊断信息 |
| `.invalidOptions` | `ClamshellObservationOptions` 无效 | 修正 `maximumFrequency` |
| `.systemError(code:)` | IOKit 返回系统错误 | 记录错误码并按暂时不可用处理 |

所有错误都实现 `LocalizedError` 协议，可以使用 `localizedDescription` 属性获取可读描述。
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
- 无需调用 `close()` 方法，取消任务或结束流消费即可释放订阅资源

在 App 中持续观察时，建议把返回的 `Task` 保存在与页面或功能相同的生命周期内，并在退出该生命周期时调用 `cancel()` 方法。更新 UI 时再交给 `MainActor` 执行，不要在主线程上进行同步等待。

## 完整示例

以下示例先展示不可用原因，再以 `10 Hz` 的最大发送频率持续输出读数：

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

仓库中的 [ClamshellLive](../Examples/ClamshellLive) 提供了可直接运行的终端示例。

## 完整 API 参考

所有 API 均可在 `import ClamshellKit` 后使用。

### API 声明

```swift
public final class ClamshellMonitor: Sendable {
    public init()

    public var status: ClamshellStatus { get async }

    public func angle() async throws -> ClamshellAngle
    public func reading() async throws -> ClamshellReading

    public func observe(
        options: ClamshellObservationOptions = .default
    ) -> AsyncThrowingStream<ClamshellReading, any Error>
}

public struct ClamshellObservationOptions: Sendable, Equatable {
    public static let `default`: ClamshellObservationOptions
    public var maximumFrequency: Double?

    public init(maximumFrequency: Double? = 30)
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

负责探测、读取和观察屏幕开合传感器。建议在同一功能生命周期内复用实例。

#### `init()`

```swift
public init()
```

创建监视器。初始化不会访问硬件，也不会提前建立连接；首次访问 `status` 属性、调用 `angle()` 方法或 `reading()` 方法，或创建观察流时，才会访问传感器。

#### `status`

```swift
public var status: ClamshellStatus { get async }
```

实时探测当前设备的可用状态。

- 返回值类型为 `ClamshellStatus`
- 每次读取都会执行一次设备探测，不返回缓存状态
- 属性本身不抛出错误，而是将探测错误转换为对应状态
- 出现 `.invalidData` 错误时会映射为 `.unsupported` 状态，无法进一步分类的读取故障会映射为 `.unavailable`

`status` 只能用于预检。后续读取仍可能失败，调用方必须继续处理读取错误。

#### `angle()`

```swift
public func angle() async throws -> ClamshellAngle
```

执行一次传感器读取并返回当前屏幕开合角度。

- 返回值：包含度数的 `ClamshellAngle`
- 抛出：设备访问或数据读取失败时抛出 `ClamshellError`
- 该方法不收集运动样本，不计算角速度和角加速度
- 没有活动观察者时，本次读取使用的连接会在完成后自动释放

#### `reading()`

```swift
public func reading() async throws -> ClamshellReading
```

返回当前角度以及估算的角速度和角加速度。

- 返回值类型为 `ClamshellReading`
- 设备访问失败时抛出 `ClamshellError` 错误，任务取消时可能抛出 `CancellationError`
- 为了估算运动数据，该方法会收集一小段连续样本，通常比 `angle()` 返回更慢
- 如果已有活动观察流和可用读数，监视器会复用现有连接和数据管线

#### `observe(options:)`

```swift
public func observe(
    options: ClamshellObservationOptions = .default
) -> AsyncThrowingStream<ClamshellReading, any Error>
```

创建持续发送完整运动读数的异步流。

- 参数 `options` 控制当前观察者的最大发送频率，默认使用 `.default`
- 返回值类型为 `AsyncThrowingStream<ClamshellReading, any Error>`
- 创建流时会开始注册观察者，但方法调用本身不执行异步等待，也不抛出错误；注册和读取错误会在消费流时出现
- 无效选项会使流以 `ClamshellError.invalidOptions` 结束
- 缓冲策略为只保留最新的一个待读取值，慢消费者可能跳过中间读数
- 多个观察流共享设备连接，但各自拥有独立的限频配置
- 取消消费任务或释放流会自动移除对应观察者

### `ClamshellObservationOptions`

配置单个 `observe(options:)` 调用的发送行为。

#### `default`

```swift
public static let `default`: ClamshellObservationOptions
```

默认配置中的 `maximumFrequency` 值为 `30` 并且每秒最多发送 `30 Hz`

#### `maximumFrequency`

```swift
public var maximumFrequency: Double?
```

每秒向当前观察者发送读数的最大次数。

- 值为 `nil` 时不额外限制发送频率
- 大于 `0` 的有限值：使用指定上限
- 值为 `0` 或负数，或者为 `NaN` 及无穷大时无效，消费观察流时产生 `.invalidOptions`
- 该值只限制发送频率，不会改变底层传感器的实际采样上限

配置是值类型。传入 `observe(options:)` 后再修改原变量，不会改变已经创建的观察流。

#### `init(maximumFrequency:)`

```swift
public init(maximumFrequency: Double? = 30)
```

创建观察配置。

- 参数 `maximumFrequency` 表示每秒最多发送的读数数量，默认值为 `30`
- 初始化器不会验证参数；参数在传给 `observe(options:)` 时验证

### `ClamshellAngle`

表示 Mac 笔记本屏幕与机身之间的夹角。

#### `degrees`

```swift
public let degrees: Double
```

角度值以 `°` 为单位。

#### `init(degrees:)`

```swift
public init(degrees: Double)
```

使用指定度数创建角度值。该初始化器不会校验有限性或传感器支持的角度范围；手动构造值时，调用方需要保证数据符合自身业务约束。

### `ClamshellReading`

表示一个包含角度与估算运动状态的读数快照。

#### `angle`

```swift
public let angle: ClamshellAngle
```

当前屏幕开合角度。

#### `angularVelocity`

```swift
public let angularVelocity: Double
```

估算角速度使用 `°/s` 作为单位。正值表示屏幕正在打开，负值表示屏幕正在合上，返回 `0` 时表示当前估算为静止。

#### `angularAcceleration`

```swift
public let angularAcceleration: Double
```

估算角加速度使用 `°/s²` 作为单位。需要结合 `angularVelocity` 的方向判断屏幕正在加速还是减速。

#### `init(angle:angularVelocity:angularAcceleration:)`

```swift
public init(
    angle: ClamshellAngle,
    angularVelocity: Double,
    angularAcceleration: Double
)
```

使用给定数据创建读数快照。该初始化器不会重新估算或校验运动数据，主要用于应用模型转换和测试数据构造。

### `ClamshellStatus`

表示当前设备对屏幕角度读取功能的可用状态。

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

该属性返回布尔值。状态为 `.available` 时以 `true` 表示，其他状态以 `false` 表示。

### `ClamshellError`

表示读取或观察屏幕开合传感器时产生的错误。该类型实现 `LocalizedError` 协议，可通过 `errorDescription` 属性或 `localizedDescription` 属性获取错误描述。

#### 错误值

| 错误 | 说明 |
| --- | --- |
| `.unavailable` | 屏幕角度当前不可用 |
| `.notFound` | 未找到兼容的屏幕角度设备 |
| `.unsupported` | 检测到的设备不受支持 |
| `.accessDenied` | macOS 拒绝访问设备 |
| `.disconnected` | 已连接设备断开 |
| `.invalidData` | 设备返回无效数据 |
| `.invalidOptions` | 观察配置无效 |
| `.systemError(code:)` | IOKit 系统错误，字段 `code` 提供原始 `Int32` 错误码 |

#### `errorDescription`

```swift
public var errorDescription: String? { get }
```

返回当前错误的英文说明。针对 `.systemError(code:)` 错误，说明会将错误码格式化为十六进制，便于与 IOKit 诊断信息对应。

### 协议遵循

| 类型 | 遵循的协议 |
| --- | --- |
| `ClamshellMonitor` | `Sendable` |
| `ClamshellObservationOptions` | `Sendable` 与 `Equatable` |
| `ClamshellAngle` | `Sendable` 与 `Equatable` |
| `ClamshellReading` | `Sendable` 与 `Equatable` |
| `ClamshellStatus` | `Sendable` 与 `Equatable` |
| `ClamshellError` | `Error` 和 `LocalizedError` 以及 `Sendable` 与 `Equatable` |
