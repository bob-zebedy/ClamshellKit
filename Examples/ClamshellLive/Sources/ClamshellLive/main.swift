import ClamshellKit
import Darwin
import Dispatch
import Foundation

@main
struct ClamshellLive {
    private static let diagnosticsEnvironmentVariable = "CLAMSHELLKIT_TRACE"
    private static let diagnosticsFileName = "clamshellkit.log"

    static func main() async {
        _ = Darwin.signal(SIGINT, SIG_IGN)

        let exampleTask = Task {
            let diagnosticsSession = await runConfiguredExample()
            await diagnosticsSession?.finish()
        }

        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: .main
        )
        interruptSource.setEventHandler {
            exampleTask.cancel()
        }
        interruptSource.resume()

        await exampleTask.value
        interruptSource.cancel()
        _ = Darwin.signal(SIGINT, SIG_DFL)
    }

    private static func runConfiguredExample() async -> DiagnosticsSession? {
        let monitor = ClamshellMonitor()
        let diagnosticsSession: DiagnosticsSession?

        do {
            diagnosticsSession = try makeDiagnosticsSession(for: monitor)
        } catch {
            writeError(
                "无法开启诊断日志: \(error.localizedDescription)\n"
            )
            diagnosticsSession = nil
        }

        if let diagnosticsSession {
            writeOutput("诊断日志: \(diagnosticsSession.fileURL.path)\n")
        }

        await run(monitor: monitor)
        return diagnosticsSession
    }

    private static func run(monitor: ClamshellMonitor) async {
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
            // Cancellation is the expected way to stop observing
        } catch {
            writeError("\n读取停止: \(error.localizedDescription)\n")
            return
        }

        writeOutput("\n")
    }

    private static func makeDiagnosticsSession(
        for monitor: ClamshellMonitor
    ) throws -> DiagnosticsSession? {
        guard let value = ProcessInfo.processInfo.environment[diagnosticsEnvironmentVariable],
              let level = try diagnosticsLevel(from: value) else {
            return nil
        }

        let directoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let fileURL = directoryURL.appendingPathComponent(diagnosticsFileName)

        return try DiagnosticsSession(
            monitor: monitor,
            level: level,
            fileURL: fileURL
        )
    }

    private static func diagnosticsLevel(
        from value: String
    ) throws -> ClamshellDiagnosticsLevel? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "0", "false", "no", "off":
            nil
        case "basic":
            .basic
        case "1", "true", "yes", "on", "verbose":
            .verbose
        case "trace":
            .trace
        default:
            throw ExampleError.invalidDiagnosticsLevel(value)
        }
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

    private final class DiagnosticsSession {
        private static let shutdownGraceNanoseconds: UInt64 = 100000000

        let fileURL: URL

        private let fileHandle: FileHandle
        private let task: Task<Void, Never>

        init(
            monitor: ClamshellMonitor,
            level: ClamshellDiagnosticsLevel,
            fileURL: URL
        ) throws {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil
                ) else {
                    throw ExampleError.cannotCreateDiagnosticsFile(fileURL.path)
                }
            }

            let fileHandle = try FileHandle(forWritingTo: fileURL)
            do {
                try fileHandle.truncate(atOffset: 0)
                let startedAt = ISO8601DateFormatter().string(from: Date())
                let header = "# ClamshellLive diagnostics level=\(level) startedAt=\(startedAt)\n"
                try fileHandle.write(contentsOf: Data(header.utf8))
            } catch {
                try? fileHandle.close()
                throw error
            }

            let stream = monitor.observeDiagnostics(
                options: .init(level: level)
            )

            self.fileURL = fileURL
            self.fileHandle = fileHandle
            task = Task {
                for await event in stream {
                    let line = "uptimeNanoseconds=\(event.uptimeNanoseconds) level=\(event.level) \(event)\n"

                    do {
                        try fileHandle.write(contentsOf: Data(line.utf8))
                    } catch {
                        ClamshellLive.writeError(
                            "诊断日志写入失败: \(error.localizedDescription)\n"
                        )
                        return
                    }
                }
            }
        }

        func finish() async {
            let gracePeriodNanoseconds = Self.shutdownGraceNanoseconds
            let forcedCancellationTask = Task.detached { [task] in
                do {
                    try await Task.sleep(
                        nanoseconds: gracePeriodNanoseconds
                    )
                } catch {
                    return
                }

                task.cancel()
            }

            await task.value
            forcedCancellationTask.cancel()

            do {
                try fileHandle.synchronize()
            } catch {
                ClamshellLive.writeError(
                    "诊断日志同步失败: \(error.localizedDescription)\n"
                )
            }

            do {
                try fileHandle.close()
            } catch {
                ClamshellLive.writeError(
                    "诊断日志关闭失败: \(error.localizedDescription)\n"
                )
            }
        }
    }

    private enum ExampleError: LocalizedError {
        case invalidDiagnosticsLevel(String)
        case cannotCreateDiagnosticsFile(String)

        var errorDescription: String? {
            switch self {
            case let .invalidDiagnosticsLevel(value):
                "\(diagnosticsEnvironmentVariable)=\(value) 无效, 请使用 basic verbose trace 1 或 off"
            case let .cannotCreateDiagnosticsFile(path):
                "无法创建 \(path)"
            }
        }
    }
}
