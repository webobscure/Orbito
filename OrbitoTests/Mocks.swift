import Foundation
@testable import Orbito

/// Records launchctl calls without touching the real launchd.
actor MockLaunchctl: LaunchctlControlling {
    enum Call: Equatable {
        case bootstrap(String, String)
        case bootout(String, String)
        case kickstart(String, Bool)
        case enable(String)
        case disable(String)
        case kill(String, String)
    }

    private(set) var calls: [Call] = []
    var loaded: [String: LoadedService] = [:]
    var overrides: [String: Bool] = [:]
    /// Number of upcoming bootstrap calls that fail, and the exit code they fail with.
    var bootstrapFailures = 0
    var bootstrapFailureCode: Int32 = 5
    var bootoutFailureCode: Int32?
    var listFails = false
    /// Path launchd reports for a loaded label (`launchctl print` → `path`).
    var loadedPaths: [String: String] = [:]

    func setLoaded(_ services: [String: LoadedService]) { loaded = services }
    func setOverrides(_ value: [String: Bool]) { overrides = value }
    func failBootstrap(times: Int, code: Int32 = 5) {
        bootstrapFailures = times
        bootstrapFailureCode = code
    }
    func failBootout(code: Int32?) { bootoutFailureCode = code }
    func setListFails(_ value: Bool) { listFails = value }
    func setLoadedPath(_ label: String, _ path: String) { loadedPaths[label] = path }

    func loadedServices(in domain: LaunchDomain) async throws -> [String: LoadedService] {
        if listFails { throw failure(["list"], 1, "boom") }
        return loaded
    }

    func disabledOverrides(in domain: LaunchDomain) async throws -> [String: Bool] { overrides }

    func serviceDetails(_ label: String, in domain: LaunchDomain) async throws -> ServiceDetails? {
        guard let path = loadedPaths[label] else { return nil }
        var details = ServiceDetails(raw: "")
        details.path = path
        return details
    }

    func bootstrap(plist: URL, in domain: LaunchDomain) async throws {
        calls.append(.bootstrap(domain.target, plist.path))
        if bootstrapFailures > 0 {
            bootstrapFailures -= 1
            throw failure(["bootstrap", domain.target, plist.path], bootstrapFailureCode, "Bootstrap failed: \(bootstrapFailureCode): Input/output error")
        }
    }

    func bootout(_ label: String, in domain: LaunchDomain) async throws {
        calls.append(.bootout(domain.target, label))
        if let code = bootoutFailureCode { throw failure(["bootout", domain.serviceTarget(label)], code, "Boot-out failed") }
    }

    func kickstart(_ label: String, in domain: LaunchDomain, killRunning: Bool) async throws {
        calls.append(.kickstart(domain.serviceTarget(label), killRunning))
    }

    func enable(_ label: String, in domain: LaunchDomain) async throws { calls.append(.enable(domain.serviceTarget(label))) }
    func disable(_ label: String, in domain: LaunchDomain) async throws { calls.append(.disable(domain.serviceTarget(label))) }
    func kill(_ signal: String, _ label: String, in domain: LaunchDomain) async throws { calls.append(.kill(signal, domain.serviceTarget(label))) }

    private func failure(_ args: [String], _ code: Int32, _ output: String) -> OrbitoError {
        .launchctl(LaunchctlFailure(arguments: args, exitCode: code, output: output))
    }
}

/// Command runner returning canned results and recording invocations.
final class MockRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [[String]] = []
    var handler: @Sendable (URL, [String]) -> CommandResult

    init(handler: @escaping @Sendable (URL, [String]) -> CommandResult = { _, _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }) {
        self.handler = handler
    }

    var invocations: [[String]] { lock.withLock { _invocations } }

    func run(_ executable: URL, arguments: [String]) async throws -> CommandResult {
        lock.withLock { _invocations.append([executable.path] + arguments) }
        return handler(executable, arguments)
    }
}

/// Temporary directory removed on deinit.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "OrbitoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ name: String, _ contents: String) throws -> URL {
        let file = url.appending(path: name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

enum Fixtures {
    static let daily = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.onkron.market-prices</string>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/bin/caffeinate</string>
            <string>-i</string>
            <string>/Users/user/Scripts/nightly-prices.sh</string>
        </array>
        <key>StandardOutPath</key>
        <string>/tmp/out.log</string>
        <key>StartCalendarInterval</key>
        <dict>
            <key>Hour</key>
            <integer>12</integer>
            <key>Minute</key>
            <integer>0</integer>
        </dict>
        <key>X-Custom-Key</key>
        <dict>
            <key>Nested</key>
            <array><integer>1</integer><true/><real>2.5</real></array>
        </dict>
        <key>Nice</key>
        <integer>5</integer>
    </dict>
    </plist>
    """

    static let array = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.example.weekdays</string>
        <key>Program</key>
        <string>/bin/echo</string>
        <key>StartCalendarInterval</key>
        <array>
            <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
            <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
            <dict><key>Weekday</key><integer>5</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
        </array>
    </dict>
    </plist>
    """

    static let interval = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.example.interval</string>
        <key>ProgramArguments</key>
        <array><string>/bin/zsh</string><string>/tmp/x.sh</string></array>
        <key>StartInterval</key>
        <integer>1800</integer>
        <key>RunAtLoad</key>
        <true/>
    </dict>
    </plist>
    """
}

extension LaunchJob {
    static func make(from dict: [String: PlistValue], at url: URL, loaded: Tristate = .yes, scope: JobScope = .userAgent, format: PlistFormat = .xml) -> LaunchJob {
        var runtime = RuntimeState(domain: .gui(uid: 501))
        runtime.loaded = loaded
        runtime.overridesKnown = true
        let definition = PlistService.definition(from: dict)
        return LaunchJob(
            label: definition.label ?? "x", plistURL: url, scope: scope, format: format, raw: dict,
            definition: definition, runtime: runtime
        )
    }
}
