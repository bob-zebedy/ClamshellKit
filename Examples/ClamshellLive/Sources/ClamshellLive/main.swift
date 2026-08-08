import ClamshellKit
import Foundation

@main
struct ClamshellLive {
    static func main() async {
        let monitor = ClamshellMonitor()
        let status = await monitor.status

        guard status.isAvailable else {
            writeError("无法读取传感器: \(description(for: status))\n")
            return
        }

        writeOutput("按 Control-C 退出\n")

        do {
            var hasRendered = false

            for try await reading in monitor.observe() {
                render(reading, replacingPreviousFrame: hasRendered)
                hasRendered = true
            }
        } catch is CancellationError {
            // Cancellation is the expected way to stop observing.
        } catch {
            writeError("\n读取停止: \(error.localizedDescription)\n")
            return
        }

        writeOutput("\n")
    }

    private static func render(
        _ reading: ClamshellReading,
        replacingPreviousFrame: Bool
    ) {
        let cursorPosition = replacingPreviousFrame ? "\r\u{001B}[2A" : ""
        let frame = String(
            format: cursorPosition
                + "\u{001B}[2K角度:      %.1f°\n"
                + "\u{001B}[2K角速度:    %+.2f°/s\n"
                + "\u{001B}[2K角加速度:  %+.2f°/s²",
            reading.angle.degrees,
            reading.angularVelocity,
            reading.angularAcceleration
        )
        writeOutput(frame)
    }

    private static func description(for status: ClamshellStatus) -> String {
        switch status {
        case .available:
            "可用"
        case .unavailable:
            "当前不可用"
        case .notFound:
            "未找到兼容设备"
        case .unsupported:
            "设备不支持"
        case .accessDenied:
            "系统拒绝"
        }
    }

    private static func writeOutput(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
