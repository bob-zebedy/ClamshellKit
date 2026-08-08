# ClamshellKit

ClamshellKit 是一个面向 macOS 的 Swift SDK，用于读取和持续监听受支持 Mac
笔记本的屏幕开合角度。

底层通过 IOKit 访问内置 HID 传感器，对外提供简洁的 Swift Concurrency API。

> [!IMPORTANT]
> 屏幕开合角度不是 macOS 公开、稳定的系统能力。设备存在、报告格式和访问权限
> 都可能因机型、系统版本及宿主运行环境而异。请始终通过 `status` 进行运行时探测，
> 并处理读取和监听过程中产生的错误。

## 特性

- 单次读取屏幕开合角度
- 基于 `AsyncThrowingStream` 的持续监听
- 首次发送当前值，随后仅发送变化值
- 可配置最大更新频率，默认 `30 Hz`
- 多个订阅者共享同一 HID 连接
- 慢速消费者仅保留最新待处理值
- 订阅取消后自动释放底层资源
- 设备断开后自动尝试重新连接
- 完整支持 Swift 6 并发检查
- 不依赖第三方库

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS 12 或更高版本 |
| Swift | Swift 6.0 或更高版本 |
| 硬件 | 具有兼容屏幕角度传感器的 Mac 笔记本 |

## 安装

ClamshellKit 以 Swift Package 的形式提供。

1. 在 Xcode 中选择 **File > Add Package Dependencies…**。
2. 输入 ClamshellKit 仓库地址。
3. 将 `ClamshellKit` 产品添加到 macOS App target。
4. 在需要使用的源码中导入模块：

```swift
import ClamshellKit
```

## 快速开始

### 检查状态并读取一次

```swift
import Foundation
import ClamshellKit

let monitor = ClamshellMonitor()

Task {
    switch await monitor.status {
    case .available:
        do {
            let angle = try await monitor.read()
            print("Display angle: \(angle.degrees)°")
        } catch {
            print("Failed to read angle: \(error.localizedDescription)")
        }

    case .unavailable:
        print("The sensor is currently unavailable.")
    case .notFound:
        print("No compatible sensor was found.")
    case .unsupported:
        print("The detected sensor is not supported.")
    case .accessDenied:
        print("Access to the sensor was denied.")
    }
}
```

### 持续监听角度变化

```swift
let observationTask = Task {
    do {
        for try await angle in monitor.observe() {
            print("Display angle: \(angle.degrees)°")
        }
    } catch is CancellationError {
        // 正常取消，无需处理。
    } catch {
        print("Observation stopped: \(error.localizedDescription)")
    }
}

// 不再需要监听时取消任务。
observationTask.cancel()
```

### 设置最大更新频率

```swift
let stream = monitor.observe(
    options: ClamshellObservationOptions(maximumFrequency: 10)
)
```

`maximumFrequency` 必须是大于 `0` 的有限值：

- 默认值为 `30`，表示最多每秒发送 30 个值。
- 传入 `nil` 表示不额外限制发送频率。
- 当前内置 profile 的轮询上限为 `60 Hz`；传入更高值也不会突破该上限。
- 实际频率还取决于传感器响应和系统调度，可能低于设置值。

## API

### `ClamshellMonitor`

```swift
public final class ClamshellMonitor: Sendable {
    public init()

    public var status: ClamshellStatus { get async }

    public func read() async throws -> ClamshellAngle

    public func observe(
        options: ClamshellObservationOptions = .default
    ) -> AsyncThrowingStream<ClamshellAngle, any Error>
}
```

| API | 作用 |
| --- | --- |
| `init()` | 创建监控器；此时不会立即打开 HID 设备 |
| `status` | 执行一次真实设备探测并返回当前可用状态 |
| `read()` | 读取一次当前屏幕开合角度 |
| `observe(options:)` | 返回初始角度及后续变化值组成的异步序列 |

`ClamshellMonitor` 遵循 `Sendable`，可以安全地跨并发上下文使用。

### `ClamshellAngle`

```swift
public struct ClamshellAngle: Sendable, Equatable {
    public let degrees: Double

    public init(degrees: Double)
}
```

`degrees` 表示屏幕与机身之间的夹角，单位为度。

### `ClamshellObservationOptions`

```swift
public struct ClamshellObservationOptions: Sendable, Equatable {
    public static let `default`: ClamshellObservationOptions
    public var maximumFrequency: Double?

    public init(maximumFrequency: Double? = 30)
}
```

用于控制单个订阅者接收角度变化的最大频率。

### `ClamshellStatus`

| 状态 | 含义 |
| --- | --- |
| `.available` | 找到兼容设备并成功读取有效数据 |
| `.unavailable` | 设备当前无法使用 |
| `.notFound` | 没有找到候选角度传感器 |
| `.unsupported` | 找到候选设备，但报告格式不受支持 |
| `.accessDenied` | macOS 拒绝访问 HID 设备 |

可以使用 `status.isAvailable` 快速判断设备当前是否可用。

### `ClamshellError`

| 错误 | 含义 |
| --- | --- |
| `.unavailable` | 设备当前不可用 |
| `.notFound` | 没有找到候选设备 |
| `.unsupported` | 设备或报告格式不受支持 |
| `.accessDenied` | 系统拒绝访问设备 |
| `.disconnected` | 设备已断开或连接失效 |
| `.invalidData` | 设备返回了无效报告 |
| `.invalidOptions` | 监听参数无效 |
| `.systemError(code:)` | 未单独映射的 IOKit 错误 |

所有错误都遵循 `LocalizedError`，可以通过 `localizedDescription` 获取可读描述。

## 监听行为

`observe(options:)` 具有以下确定语义：

1. 订阅建立后首先发送当前角度。
2. 后续只发送与上一次已发送值不同的角度。
3. 每个订阅者独立应用自己的最大更新频率。
4. 多个订阅者共享同一个设备连接和轮询任务。
5. 消费者处理速度不足时，仅保留最新的一个待处理值。
6. 最后一个订阅结束后自动停止轮询并关闭设备。
7. 临时断线时自动重试；重试失败后以 `ClamshellError` 结束序列。

调用 `read()` 不需要手动管理连接。没有活跃订阅时，SDK 会在读取完成后立即关闭
设备；存在活跃订阅时，则复用当前连接。

## 硬件兼容性

ClamshellKit 当前支持以下 HID 设备：

| 属性 | 值 |
| --- | --- |
| Vendor ID | `0x05AC` |
| Product ID | `0x8104` |
| Primary Usage Page | `0x20` |
| Primary Usage | `0x8A` |

兼容性以实际读取结果为准，而不是仅根据 Mac 型号或是否能够枚举到 HID 节点进行
判断。应用应在运行时检查 `status`，并为不可用状态提供降级处理。

## App Sandbox

ClamshellKit 直接访问内置 Apple SPU HID 设备。宿主 App 开启 App Sandbox 时，
IOKit 访问可能被系统拒绝，此时 `status` 返回 `.accessDenied`，读取和监听操作抛出
`ClamshellError.accessDenied`。

SDK 无法修改宿主 target 的签名或 entitlement。需要使用该能力的 target 应根据
实际分发方式配置 App Sandbox；Hardened Runtime 可以保持启用。
