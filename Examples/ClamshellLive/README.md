# ClamshellLive

ClamshellLive 是一个可直接运行的终端示例，用于实时显示屏幕开合角度、角速度和
角加速度。它作为独立 Swift Package 通过本地依赖调用仓库根目录中的 ClamshellKit，
不会向 ClamshellKit SDK 增加命令行产品。

## 运行

在 ClamshellKit 根目录执行：

```shell
swift run --package-path Examples/ClamshellLive ClamshellLive
```

```text
角度:      123.0°
角速度:    +0.00°/s
角加速度:  +0.00°/s²
```

正角速度表示屏幕正在打开，负角速度表示屏幕正在合上。角加速度的正负表示角速度
沿相应方向变化，是否正在加速需要结合角速度的符号判断。

## 构建后运行

```shell
swift build --package-path Examples/ClamshellLive -c release
Examples/ClamshellLive/.build/release/ClamshellLive
```

该示例需要在具有兼容屏幕角度传感器且允许 IOKit 访问的 Mac 笔记本上运行。
