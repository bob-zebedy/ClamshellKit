# ClamshellKit

ClamshellKit 面向 macOS 平台，以 Swift SDK 形式读取 Mac 笔记本的屏幕开合角度，并通过 Swift Concurrency 获取角速度、角加速度和实时变化。

> [!IMPORTANT]
> 屏幕开合角度不是公开、稳定的系统能力，兼容性可能因机型、系统版本和运行环境而异。
> 角速度和角加速度为连续角度样本的估算值。请在实际设备上检查 `status` 并处理读取错误。

## 安装

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

## 快速使用

在支持 `async throws` 的上下文中读取当前角度

```swift
import ClamshellKit

let monitor = ClamshellMonitor()
let angle = try await monitor.angle()

print("角度: \(angle.degrees)°")
```

## 使用指南

安装、兼容性、完整读数、持续观察及错误处理请参阅 [使用指南](Wiki/Usage.md)
