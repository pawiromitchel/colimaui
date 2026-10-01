import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
    public var succeeded: Bool { exitCode == 0 }
}

public struct CommandError: Error, LocalizedError, Equatable {
    public var command: String
    public var exitCode: Int32
    public var message: String
    public var errorDescription: String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(command) exited with code \(exitCode)" : trimmed
    }
}

/// Abstraction over running external tools so the clients can be tested without a real Colima.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String], environment: [String: String]) async throws -> CommandResult
    /// Streams merged stdout/stderr line by line until the process exits or the stream is cancelled.
    func stream(_ executable: String, arguments: [String], environment: [String: String]) -> AsyncThrowingStream<String, Error>
}

extension CommandRunning {
    public func run(_ executable: String, arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments: arguments, environment: [:])
    }

    /// Runs and throws a `CommandError` on non-zero exit.
    public func runChecked(_ executable: String, arguments: [String], environment: [String: String] = [:]) async throws -> String {
        let result = try await run(executable, arguments: arguments, environment: environment)
        guard result.succeeded else {
            throw CommandError(command: ([executable] + arguments).joined(separator: " "),
                               exitCode: result.exitCode,
                               message: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout
    }
}

/// Locates CLI tools. GUI apps launch with a minimal PATH, so Homebrew paths are searched explicitly.
public enum ToolLocator {
    public static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin"]

    public static func find(_ name: String, extraPaths: [String] = []) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in extraPaths + searchPaths {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public static var environmentPath: String {
        (searchPaths + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []))
            .joined(separator: ":")
    }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    private func makeProcess(_ executable: String, _ arguments: [String], _ environment: [String: String]) throws -> Process {
        guard let path = ToolLocator.find(executable) else {
            throw CommandError(command: executable, exitCode: 127, message: "\(executable) not found. Install it with Homebrew.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ToolLocator.environmentPath
        for (k, v) in environment { env[k] = v }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        return process
    }

    public func run(_ executable: String, arguments: [String], environment: [String: String]) async throws -> CommandResult {
        let process = try makeProcess(executable, arguments, environment)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { collector.appendOut($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { collector.appendErr($0.availableData) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                    let (o, e) = collector.snapshot()
                    cont.resume(returning: CommandResult(exitCode: proc.terminationStatus, stdout: o, stderr: e))
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    public func stream(_ executable: String, arguments: [String], environment: [String: String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process: Process
            do { process = try makeProcess(executable, arguments, environment) } catch {
                continuation.finish(throwing: error)
                return
            }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let splitter = LineSplitter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                for line in splitter.feed(data) { continuation.yield(line) }
            }
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                for line in splitter.feed(rest) { continuation.yield(line) }
                if let tail = splitter.flush() { continuation.yield(tail) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do { try process.run() } catch { continuation.finish(throwing: error) }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func snapshot() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

/// Splits a byte stream into lines, carrying partial lines between chunks.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<idx]
            lines.append(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
