import Foundation

public struct ProcessResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

public protocol ProcessRunning {
    func run(executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval) -> ProcessResult
}

public extension ProcessRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval = 600) -> ProcessResult {
        run(executable: executable, arguments: arguments, currentDirectory: nil, timeout: timeout)
    }
}

public struct RealProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], currentDirectory: String? = nil, timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let box = OutputBox()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                box.append(data, error: false)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                box.append(data, error: true)
            }
        }

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "Failed to launch \(executable): \(error.localizedDescription)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return ProcessResult(exitCode: -1,
                                 stdout: box.text(error: false),
                                 stderr: box.text(error: true) + "\n[AutoRenew] process timed out after \(Int(timeout))s")
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        box.append(outPipe.fileHandleForReading.readDataToEndOfFile(), error: false)
        box.append(errPipe.fileHandleForReading.readDataToEndOfFile(), error: true)

        return ProcessResult(exitCode: process.terminationStatus,
                             stdout: box.text(error: false),
                             stderr: box.text(error: true))
    }
}

final class OutputBox {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, error: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if error { err.append(data) } else { out.append(data) }
        lock.unlock()
    }

    func text(error: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        let data = error ? err : out
        return String(data: data, encoding: .utf8) ?? ""
    }
}
