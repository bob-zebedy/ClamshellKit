# ClamshellKit

ClamshellKit 是一个面向 macOS 的 Swift SDK，用于读取 Mac 笔记本的屏幕开合角度、
角速度和角加速度。

> [!IMPORTANT]
> 屏幕开合角度不是 macOS 公开、稳定的系统能力，兼容性可能因机型、系统版本和运行环境而异。
> 请通过 `status` 检查当前设备是否可用，并处理相关错误。

> [!NOTE]
> 角速度和角加速度根据连续角度样本估算，并非传感器直接提供的原始测量值。

## 特性

- 读取当前屏幕开合角度
- 获取角度、角速度和角加速度
- 使用 `AsyncThrowingStream` 持续观察
- 可配置最大发送频率，默认 `30 Hz`
- 自动处理订阅取消和临时断线
- 完整支持 Swift 6 并发检查

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS 12 或更高版本 |
| Swift | Swift 6.0 或更高版本 |
| 硬件 | 具有兼容屏幕角度传感器的 Mac 笔记本 |

## 安装

### Xcode

1. 选择 **File > Add Package Dependencies…**。
2. 输入以下地址：

   ```text
   https://github.com/bob-zebedy/ClamshellKit.git
   ```

3. `Dependency Rule` 选择 **Branch**，填写 `main`。
4. 将 `ClamshellKit` 添加到 macOS App target。

### Package.swift

```swift
dependencies: [
    .package(
        url: "https://github.com/bob-zebedy/ClamshellKit.git",
        branch: "main"
    )
]
```

在对应 target 中引用：

```swift
dependencies: [
    .product(name: "ClamshellKit", package: "ClamshellKit")
]
```

## 使用

```swift
import ClamshellKit

let monitor = ClamshellMonitor()
```

### 读取当前角度

```swift
if await monitor.status == .available {
    let angle = try await monitor.angle()
    print("Angle: \(angle.degrees)°")
}
```

### 获取完整读数

```swift
let reading = try await monitor.reading()

print("Angle: \(reading.angle.degrees)°")
print("Angular velocity: \(reading.angularVelocity)°/s")
print("Angular acceleration: \(reading.angularAcceleration)°/s²")
```

正角速度表示屏幕正在打开，负角速度表示屏幕正在合上。

### 持续观察

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
        // 正常取消
    } catch {
        print(error.localizedDescription)
    }
}

// 不再需要观察时取消
observationTask.cancel()
```

### 设置最大发送频率

```swift
let stream = monitor.observe(
    options: ClamshellObservationOptions(maximumFrequency: 10)
)
```

`maximumFrequency` 必须是大于 `0` 的有限值。默认值为 `30`；传入 `nil` 表示不额外
限制发送频率。实际发送频率不会超过传感器支持的上限。

## API

### ClamshellMonitor

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
```

| API | 作用 |
| --- | --- |
| `status` | 获取当前设备可用状态 |
| `angle()` | 读取当前屏幕开合角度 |
| `reading()` | 获取当前完整运动读数 |
| `observe(options:)` | 持续接收完整运动读数 |

### 数据

| 成员 | 单位 | 含义 |
| --- | --- | --- |
| `ClamshellAngle.degrees` | `°` | 屏幕与机身之间的夹角 |
| `ClamshellReading.angle.degrees` | `°` | 当前屏幕开合角度 |
| `ClamshellReading.angularVelocity` | `°/s` | 角速度；正值打开，负值合上 |
| `ClamshellReading.angularAcceleration` | `°/s²` | 角加速度 |

### 状态

| 状态 | 含义 |
| --- | --- |
| `.available` | 当前可用 |
| `.unavailable` | 当前不可用 |
| `.notFound` | 未找到兼容传感器 |
| `.unsupported` | 设备或报告格式不受支持 |
| `.accessDenied` | macOS 拒绝访问设备 |

### 错误

| 错误 | 含义 |
| --- | --- |
| `.unavailable` | 设备当前不可用 |
| `.notFound` | 未找到兼容设备 |
| `.unsupported` | 设备或报告格式不受支持 |
| `.accessDenied` | 系统拒绝访问设备 |
| `.disconnected` | 设备连接已失效 |
| `.invalidData` | 设备返回无效数据 |
| `.invalidOptions` | 观察参数无效 |
| `.systemError(code:)` | IOKit 系统错误 |

## 示例

[ClamshellLive](Examples/ClamshellLive)
