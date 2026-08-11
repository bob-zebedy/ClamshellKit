# ClamshellLive

ClamshellLive 是一个可直接运行的终端示例，用于实时显示屏幕开合角度、角速度和角加速度。

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

正角速度表示屏幕正在打开，负角速度表示屏幕正在合上。角加速度的正负表示角速度沿相应方向变化，是否正在加速需要结合角速度的符号判断。

## 开启诊断日志

通过 `CLAMSHELLKIT_TRACE` 环境变量开启诊断数据

```shell
CLAMSHELLKIT_TRACE=verbose \
swift run --package-path Examples/ClamshellLive ClamshellLive
```

日志会写入运行命令的当前目录

```text
clamshellkit.log
```

每次开启诊断运行时都会覆盖上一次日志。环境变量支持以下值

| 值 | 行为 |
| --- | --- |
| `basic` | 写入连接生命周期、设备发现、Profile 选择、重连和错误 |
| `verbose` | 在 `basic` 基础上增加设备描述、HID Element、协议解析和数据交付信息 |
| `trace` | 在 `verbose` 基础上增加原始 HID 报告和运动估算内部数据 |
| `1`、`true`、`yes`、`on` | 等价于 `verbose` |
| `0`、`false`、`no`、`off` 或未设置 | 不创建诊断日志 |

例如需要收集完整诊断信息时

```shell
CLAMSHELLKIT_TRACE=trace \
swift run --package-path Examples/ClamshellLive ClamshellLive
```

`trace` 包含原始传感器报告，只建议在排查问题时短时间开启。诊断日志不会改变终端中原有角度、角速度和角加速度的输出

## 构建后运行

```shell
swift build --package-path Examples/ClamshellLive -c release
Examples/ClamshellLive/.build/release/ClamshellLive
```

该示例需要在具有兼容屏幕角度传感器且允许 IOKit 访问的 Mac 笔记本上运行。
