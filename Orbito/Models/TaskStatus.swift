import Foundation

/// launchd domain a job is bootstrapped into.
enum LaunchDomain: Hashable, Sendable {
    case gui(uid: UInt32)
    case user(uid: UInt32)
    case system

    var target: String {
        switch self {
        case .gui(let uid): "gui/\(uid)"
        case .user(let uid): "user/\(uid)"
        case .system: "system"
        }
    }

    func serviceTarget(_ label: String) -> String { "\(target)/\(label)" }

    static var currentGUI: LaunchDomain { .gui(uid: getuid()) }
}

/// Tri-state value: unknown must never be silently shown as success.
enum Tristate: Hashable, Sendable {
    case yes, no, unknown

    init(_ value: Bool?) {
        switch value {
        case .some(true): self = .yes
        case .some(false): self = .no
        case .none: self = .unknown
        }
    }
}

/// Outcome of the last run as launchd reports it.
enum LastExit: Hashable, Sendable {
    /// launchd reported no exit (never exited, or status column is "-").
    case none
    case exitCode(Int)
    /// Process was terminated by a signal (negative status in `launchctl list`).
    case signal(Int)
    case unknown

    init(listStatus: Int) {
        self = listStatus < 0 ? .signal(-listStatus) : .exitCode(listStatus)
    }

    var isFailure: Bool {
        switch self {
        case .exitCode(let code): code != 0
        case .signal: true
        default: false
        }
    }

    var description: String {
        switch self {
        case .none: "Нет данных о завершении"
        case .exitCode(0): "Код 0"
        case .exitCode(let code): "Код \(code)"
        case .signal(let signal): "Сигнал \(signal) (\(Self.signalName(signal)))"
        case .unknown: "Неизвестно"
        }
    }

    static func signalName(_ signal: Int) -> String {
        switch signal {
        case 1: "SIGHUP"
        case 2: "SIGINT"
        case 6: "SIGABRT"
        case 9: "SIGKILL"
        case 11: "SIGSEGV"
        case 13: "SIGPIPE"
        case 15: "SIGTERM"
        default: "сигнал"
        }
    }
}

/// Runtime facts gathered from launchd. Each field is independent:
/// "file exists", "loaded", "running", "disabled", "last exit" are never merged.
struct RuntimeState: Hashable, Sendable {
    var domain: LaunchDomain
    var loaded: Tristate = .unknown
    var pid: Int?
    var lastExit: LastExit = .unknown
    /// Value from launchd's override database (`launchctl print-disabled`), if any.
    var disabledOverride: Bool?
    /// Whether the override database could be read at all.
    var overridesKnown: Bool = false

    var isRunning: Tristate {
        switch loaded {
        case .yes: pid != nil ? .yes : .no
        case .no: .no
        case .unknown: .unknown
        }
    }
}

/// Detailed service info from `launchctl print <service>`.
struct ServiceDetails: Hashable, Sendable {
    var state: String?
    var pid: Int?
    var runs: Int?
    var lastExitCode: String?
    var lastExitReason: String?
    var program: String?
    var domain: String?
    var path: String?
    var raw: String
}

enum IssueSeverity: Int, Comparable, Sendable {
    case info = 0, warning = 1, error = 2

    static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct JobIssue: Hashable, Sendable, Identifiable {
    var severity: IssueSeverity
    var message: String
    var id: String { "\(severity.rawValue)-\(message)" }
}
