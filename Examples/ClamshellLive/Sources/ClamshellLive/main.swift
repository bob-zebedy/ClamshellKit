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

        writeOutput(
            "正在读取屏幕开合传感器...\n"
                + "S 断开传感器连接\n"
                + "C 重新连接传感器\n"
                + "Control-C 退出\n\n"
        )

        let controller = LiveController(monitor: monitor)
        let (commands, commandContinuation) = AsyncStream<LiveCommand>.makeStream()
        let keyboardHandler = KeyboardHandler { key in
            if let command = command(for: key) {
                commandContinuation.yield(command)
            }
        }

        await controller.connect()

        await withTaskCancellationHandler {
            for await command in commands {
                switch command {
                case .disconnect:
                    await controller.disconnect()
                case .connect:
                    await controller.connect()
                }
            }
        } onCancel: {
            commandContinuation.finish()
        }

        commandContinuation.finish()
        await controller.shutdown()
        withExtendedLifetime(keyboardHandler) {}
        writeOutput("\n")
    }

    private static func command(for key: UInt8) -> LiveCommand? {
        if key == Character("s").asciiValue
            || key == Character("S").asciiValue {
            return .disconnect
        }
        if key == Character("c").asciiValue
            || key == Character("C").asciiValue {
            return .connect
        }

        return nil
    }

    private static func observe(monitor: ClamshellMonitor) async -> ObservationResult {
        do {
            var hasRendered = false

            writeOutput("传感器已连接\n")

            for try await reading in monitor.observe() {
                render(reading, replacingPreviousFrame: hasRendered)
                hasRendered = true
            }

            return .finished
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
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

    private enum LiveCommand: Sendable {
        case disconnect
        case connect
    }

    private enum ObservationResult: Sendable {
        case finished
        case cancelled
        case failed(String)
    }

    private actor LiveController {
        private let monitor: ClamshellMonitor
        private var observationTask: Task<Void, Never>?
        private var observationGeneration: UInt64 = 0

        init(monitor: ClamshellMonitor) {
            self.monitor = monitor
        }

        func connect() {
            guard observationTask == nil else {
                return
            }

            observationGeneration &+= 1
            let generation = observationGeneration
            let monitor = monitor

            ClamshellLive.writeOutput("正在连接传感器...\n")
            observationTask = Task { [weak self] in
                let result = await ClamshellLive.observe(monitor: monitor)
                await self?.observationDidFinish(
                    generation: generation,
                    result: result
                )
            }
        }

        func disconnect() async {
            await stop()
            ClamshellLive.writeOutput(
                "\n传感器已断开, 按 C 重新连接\n"
            )
        }

        func shutdown() async {
            await stop()
        }

        private func stop() async {
            observationGeneration &+= 1

            let observationTask = observationTask
            self.observationTask = nil

            observationTask?.cancel()
            await monitor.disconnect()
            await observationTask?.value
        }

        private func observationDidFinish(
            generation: UInt64,
            result: ObservationResult
        ) {
            guard generation == observationGeneration else {
                return
            }

            observationTask = nil

            switch result {
            case .finished:
                ClamshellLive.writeOutput(
                    "\n读取结束, 按 C 重新连接\n"
                )
            case .cancelled:
                break
            case let .failed(message):
                ClamshellLive.writeError(
                    "\n读取停止: \(message)\n按 C 重新连接\n"
                )
            }
        }
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

private final class KeyboardHandler: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let originalAttributes: termios?

    init(handler: @escaping @Sendable (UInt8) -> Void) {
        var original = termios()
        var savedAttributes: termios?

        if tcgetattr(STDIN_FILENO, &original) == 0 {
            var attributes = original
            attributes.c_lflag &= ~tcflag_t(ICANON | ECHO)

            if tcsetattr(STDIN_FILENO, TCSANOW, &attributes) == 0 {
                savedAttributes = original
            }
        }

        originalAttributes = savedAttributes
        source = DispatchSource.makeReadSource(
            fileDescriptor: STDIN_FILENO,
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler {
            var key: UInt8 = 0

            if Darwin.read(STDIN_FILENO, &key, 1) == 1 {
                handler(key)
            }
        }
        source.resume()
    }

    deinit {
        source.cancel()

        if var originalAttributes {
            tcsetattr(STDIN_FILENO, TCSANOW, &originalAttributes)
        }
    }
}
