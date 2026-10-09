import Foundation

struct CommandResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var combinedOutput: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Runs an executable with an explicit argument vector. No shell is involved,
/// so arguments are never re-interpreted (no globbing, no interpolation).
protocol CommandRunning: Sendable {
    func run(_ executable: URL, arguments: [String]) async throws -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    var timeout: TimeInterval = 30

    func run(_ executable: URL, arguments: [String]) async throws -> CommandResult {
        guard executable.path.hasPrefix("/") else {
            throw OrbitoError.invalidPath(executable.path)
        }
        let execution = ProcessExecution(executable: executable, arguments: arguments, timeout: timeout)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try execution.runBlocking() })
            }
        }
    }
}

/// Owns one `Process` for its whole lifetime; all access is serialised by
/// the blocking call or by the pipe-draining group, hence `@unchecked`.
private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let timeout: TimeInterval
    private var outData = Data()
    private var timedOut = false
    private var errData = Data()

    init(executable: URL, arguments: [String], timeout: TimeInterval) {
        self.timeout = timeout
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // Minimal, predictable environment for system tools.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    func runBlocking() throws -> CommandResult {
        do {
            try process.run()
        } catch {
            throw OrbitoError.processFailed("Не удалось запустить \(process.executableURL?.path ?? "?"): \(error.localizedDescription)")
        }

        let watchdog = DispatchWorkItem { [self] in
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain both pipes concurrently so a full buffer can't deadlock the child.
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { [self] in
            outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        DispatchQueue.global().async(group: group) { [self] in
            errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        group.wait()
        process.waitUntilExit()
        watchdog.cancel()
        if timedOut {
            let command = ([process.executableURL?.path ?? "?"] + (process.arguments ?? [])).joined(separator: " ")
            throw OrbitoError.timedOut(command: command)
        }

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
