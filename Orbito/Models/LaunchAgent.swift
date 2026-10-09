import Foundation

/// Where a plist lives. Only the user's own LaunchAgents are writable.
enum JobScope: String, Hashable, Sendable, CaseIterable, Codable {
    case userAgent
    case globalAgent
    case globalDaemon

    var directory: URL {
        switch self {
        case .userAgent:
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        case .globalAgent:
            URL(filePath: "/Library/LaunchAgents", directoryHint: .isDirectory)
        case .globalDaemon:
            URL(filePath: "/Library/LaunchDaemons", directoryHint: .isDirectory)
        }
    }

    var isEditable: Bool { self == .userAgent }

    var title: String {
        switch self {
        case .userAgent: "~/Library/LaunchAgents"
        case .globalAgent: "/Library/LaunchAgents"
        case .globalDaemon: "/Library/LaunchDaemons"
        }
    }

    var shortTitle: String {
        switch self {
        case .userAgent: "Пользовательский агент"
        case .globalAgent: "Системный агент"
        case .globalDaemon: "Демон"
        }
    }
}

enum KeepAliveSetting: Hashable, Sendable {
    case absent
    case always(Bool)
    /// Dictionary form (SuccessfulExit, PathState, …); edited only in raw form.
    case conditional

    var isActive: Bool {
        switch self {
        case .absent: false
        case .always(let value): value
        case .conditional: true
        }
    }
}

/// Parsed, typed view of the keys Orbito understands.
struct JobDefinition: Hashable, Sendable {
    var label: String?
    var program: String?
    var programArguments: [String] = []
    var schedule: JobSchedule = .none
    var runAtLoad: Bool = false
    var keepAlive: KeepAliveSetting = .absent
    var workingDirectory: String?
    var environment: [String: String] = [:]
    var standardOutPath: String?
    var standardErrorPath: String?
    var disabled: Bool?
    var limitLoadToSessionType: [String] = []
    /// Non-time triggers present in the plist (WatchPaths, QueueDirectories, …).
    var otherTriggers: [String] = []

    /// The binary launchd will exec.
    var executablePath: String? { program ?? programArguments.first }

    /// argv as launchd builds it: `ProgramArguments`, or `[Program]` when absent.
    var argv: [String] {
        if !programArguments.isEmpty { return programArguments }
        return program.map { [$0] } ?? []
    }

    /// Script passed to a known interpreter, e.g. `/bin/zsh script.sh`.
    var scriptPath: String? {
        let args = argv
        guard let exe = executablePath, args.count >= 2 else { return nil }
        let name = (exe as NSString).lastPathComponent
        let interpreters = ["bash", "zsh", "sh", "python", "python3", "php", "node", "ruby", "perl", "caffeinate"]
        guard interpreters.contains(where: { name == $0 || name.hasPrefix($0) }) else { return nil }
        return args.dropFirst().first { $0.hasPrefix("/") && !$0.hasPrefix("-") }
    }
}

/// App-side metadata (display name, notes, favourite). Never written into the plist.
struct JobMetadata: Codable, Hashable, Sendable {
    var displayName: String?
    var notes: String?
    var isFavorite: Bool = false
}

/// A launchd job discovered on disk plus its runtime state.
struct LaunchJob: Identifiable, Hashable, Sendable {
    /// Plist path; labels can legitimately repeat across directories.
    var id: String { plistURL.path }

    var label: String
    var plistURL: URL
    var scope: JobScope
    var format: PlistFormat
    var raw: [String: PlistValue]
    var definition: JobDefinition
    var runtime: RuntimeState
    var loadError: String?
    var fileModified: Date?
    var issues: [JobIssue] = []
    var metadata = JobMetadata()

    var isEditable: Bool { scope.isEditable && loadError == nil }

    var displayName: String {
        if let name = metadata.displayName, !name.isEmpty { return name }
        return Self.prettyName(from: label)
    }

    /// Effective disabled state: override database first, then the plist key.
    var isDisabled: Tristate {
        if let override = runtime.disabledOverride { return override ? .yes : .no }
        if runtime.overridesKnown { return (definition.disabled ?? false) ? .yes : .no }
        if definition.disabled == true { return .yes }
        return .unknown
    }

    var hasErrors: Bool { issues.contains { $0.severity == .error } || runtime.lastExit.isFailure }

    var searchableText: String {
        ([label, displayName, plistURL.path] + definition.argv + [definition.program ?? ""]).joined(separator: "\n")
    }

    /// "com.onkron.market-prices" → "Market Prices".
    static func prettyName(from label: String) -> String {
        let last = label.split(separator: ".").last.map(String.init) ?? label
        let words = last
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? label : words.joined(separator: " ")
    }
}

/// Overall status shown as a single badge; derived from independent facts.
enum JobHealth: Hashable, Sendable {
    case running
    case loaded
    case lastRunFailed
    case notLoaded
    case disabled
    case invalid
    case unknown

    init(job: LaunchJob) {
        if job.loadError != nil { self = .invalid; return }
        if job.isDisabled == .yes { self = .disabled; return }
        switch job.runtime.loaded {
        case .unknown: self = .unknown
        case .no: self = .notLoaded
        case .yes:
            if job.runtime.pid != nil { self = .running }
            else if job.runtime.lastExit.isFailure { self = .lastRunFailed }
            else { self = .loaded }
        }
    }

    var title: String {
        switch self {
        case .running: "Выполняется"
        case .loaded: "Загружено"
        case .lastRunFailed: "Ошибка запуска"
        case .notLoaded: "Не загружено"
        case .disabled: "Отключено"
        case .invalid: "Неверный plist"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .running: "play.circle.fill"
        case .loaded: "checkmark.circle.fill"
        case .lastRunFailed: "exclamationmark.triangle.fill"
        case .notLoaded: "circle.dashed"
        case .disabled: "pause.circle.fill"
        case .invalid: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var sortRank: Int {
        switch self {
        case .invalid: 0
        case .lastRunFailed: 1
        case .running: 2
        case .loaded: 3
        case .notLoaded: 4
        case .disabled: 5
        case .unknown: 6
        }
    }
}
