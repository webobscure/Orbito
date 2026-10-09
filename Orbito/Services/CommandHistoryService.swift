import Foundation

/// One entry in Command History.
struct CommandRecord: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// A process Orbito actually ran (launchctl, plutil).
        case executed
        /// A file Orbito wrote, backed up or moved to the Trash.
        case fileOperation
        /// In-process API work (PropertyListSerialization validation, …).
        case internalOperation
        /// Terminal equivalent shown in Dry Run — never executed.
        case cliEquivalent

        var title: String {
            switch self {
            case .executed: "Выполнено"
            case .fileOperation: "Файл"
            case .internalOperation: "Внутренняя операция"
            case .cliEquivalent: "CLI-эквивалент (не выполнялось)"
            }
        }

        var symbol: String {
            switch self {
            case .executed: "terminal"
            case .fileOperation: "doc"
            case .internalOperation: "gearshape"
            case .cliEquivalent: "eye"
            }
        }
    }

    var id = UUID()
    var date = Date.now
    var kind: Kind
    var connection = "Этот Mac"
    var backend = "launchd"
    var label: String?
    var action: String
    var command: String
    var exitCode: Int32?
    var output = ""
    var errorOutput = ""
    var duration: TimeInterval = 0

    var succeeded: Bool { exitCode.map { $0 == 0 } ?? true }
}

/// Which task/action caused the commands running in the current Swift task.
/// Commands run outside any context (periodic scans) are not recorded.
enum CommandContext {
    struct Value: Sendable {
        var label: String?
        var action: String
    }

    @TaskLocal static var current: Value?
}

protocol CommandRecording: Sendable {
    func record(_ record: CommandRecord) async
}

/// Masks secrets before anything reaches history or disk.
enum HistorySanitizer {
    private static let secretWords = ["pass", "secret", "token", "key", "auth", "credential", "cookie", "session"]

    static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretWords.contains { lower.contains($0) }
    }

    static func sanitize(_ text: String) -> String {
        var result = text
        let names = "pass|secret|token|key|auth|credential|cookie|session"
        // scheme://user:password@host (password may itself contain '@': mask up to the last one)
        result = result.replacingOccurrences(of: #"(\w+://[^:/\s@]+:)\S*@"#, with: "$1***@", options: .regularExpression)
        // plist XML: <key>SECRET_NAME</key> <string>value</string>
        result = result.replacingOccurrences(
            of: "(?i)(<key>[^<]*(\(names))[^<]*</key>\\s*<string>)[^<]*(</string>)",
            with: "$1***$3", options: .regularExpression
        )
        // JSON: "SECRET_NAME": "value"
        result = result.replacingOccurrences(
            of: "(?i)(\"[^\"]*(\(names))[^\"]*\"\\s*:\\s*)\"[^\"]*\"",
            with: "$1\"***\"", options: .regularExpression
        )
        // "SECRET_NAME" => value (launchctl print environment blocks)
        result = result.replacingOccurrences(
            of: #"(?i)([A-Z0-9_]*(pass|secret|token|key|auth)[A-Z0-9_]*\s*=>\s*)\S+"#,
            with: "$1***", options: .regularExpression
        )
        // KEY=value / --password=value / --token value (skips values already masked)
        result = result.replacingOccurrences(
            of: #"(?i)\b([A-Z0-9_\-]*(pass(word)?|secret|token|api[_-]?key|auth|credential|cookie|session)[A-Z0-9_\-]*)(\s*[=:](?!>)\s*|\s+)(?!=>)(?!\*\*\*)("[^"]*"|'[^']*'|\S+)"#,
            with: "$1$4***", options: .regularExpression
        )
        return result
    }

    static func truncate(_ text: String, limit: Int = 16_000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n… (обрезано)" : text
    }

    static func clean(_ record: CommandRecord) -> CommandRecord {
        var copy = record
        copy.command = sanitize(record.command)
        copy.output = truncate(sanitize(record.output))
        copy.errorOutput = truncate(sanitize(record.errorOutput))
        return copy
    }
}

/// Persistent, bounded Command History.
@MainActor
@Observable
final class CommandHistoryStore: CommandRecording {
    private(set) var records: [CommandRecord] = []
    var isEnabled = true
    private let store: JSONFileStore<[CommandRecord]>
    private let maxRecords = 1000

    init(store: JSONFileStore<[CommandRecord]> = .appSupport("command-history.json")) {
        self.store = store
        records = store.load() ?? []
    }

    nonisolated func record(_ record: CommandRecord) async {
        await append(record)
    }

    func append(_ record: CommandRecord) {
        guard isEnabled else { return }
        records.insert(HistorySanitizer.clean(record), at: 0)
        if records.count > maxRecords { records.removeLast(records.count - maxRecords) }
        scheduleSave()
    }

    func clear() {
        records.removeAll()
        scheduleSave()
    }

    private var saveTask: Task<Void, Never>?

    /// Coalesces bursts of appends; encoding and writing happen off the main actor.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = records
        let store = store
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? store.save(snapshot)
        }
    }

    /// Waits for a pending save (tests, app termination).
    func flush() async {
        await saveTask?.value
    }
}

/// Wraps a runner and records commands that run inside a `CommandContext`.
struct RecordingCommandRunner: CommandRunning {
    var base: any CommandRunning
    var recorder: any CommandRecording

    func run(_ executable: URL, arguments: [String]) async throws -> CommandResult {
        let context = CommandContext.current
        let start = Date()
        let command = Workspace.shellCommand([executable.lastPathComponent] + arguments)
        do {
            let result = try await base.run(executable, arguments: arguments)
            if let context {
                await recorder.record(CommandRecord(
                    kind: .executed, label: context.label, action: context.action, command: command,
                    exitCode: result.exitCode, output: result.stdout, errorOutput: result.stderr,
                    duration: Date().timeIntervalSince(start)
                ))
            }
            return result
        } catch {
            if let context {
                await recorder.record(CommandRecord(
                    kind: .executed, label: context.label, action: context.action, command: command,
                    exitCode: nil, errorOutput: error.localizedDescription, duration: Date().timeIntervalSince(start)
                ))
            }
            throw error
        }
    }
}

/// Records file and internal operations performed by `JobOperations`.
struct OperationJournal: Sendable {
    var recorder: (any CommandRecording)?

    func file(_ description: String, _ path: String) async {
        guard let recorder, let context = CommandContext.current else { return }
        await recorder.record(CommandRecord(kind: .fileOperation, label: context.label, action: context.action, command: "\(description): \(path)", exitCode: 0))
    }

    func `internal`(_ description: String) async {
        guard let recorder, let context = CommandContext.current else { return }
        await recorder.record(CommandRecord(kind: .internalOperation, label: context.label, action: context.action, command: description, exitCode: 0))
    }
}
