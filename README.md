# ClamshellKit

ClamshellKit 是一个面向 macOS 的 Swift SDK，用于读取 Mac 笔记本的屏幕开合角度，并通过 Swift Concurrency 获取角速度、角加速度和实时变化。

> [!IMPORTANT]
> 屏幕开合角度不是公开、稳定的系统能力，兼容性可能因机型、系统版本和运行环境而异。
> 角速度和角加速度为连续角度样本的估算值。请在实际设备上检查 `status` 并处理读取错误。

## 快速使用

在支持 `async throws` 的上下文中读取当前角度：

```swift
import ClamshellKit

let monitor = ClamshellMonitor()
let angle = try await monitor.angle()

print("Angle: \(angle.degrees)°")
```

安装、兼容性、完整读数、持续观察及错误处理请参阅 [API 使用指南](Wiki/API-Usage.md)
