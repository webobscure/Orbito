import Foundation

enum LogStream: String, CaseIterable, Identifiable {
    case stdout, stderr
    /// Advanced logs: launchd's own diagnostics (unified log + launchctl print).
    case launchd
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stdout: "stdout"
        case .stderr: "stderr"
        case .launchd: "launchd"
        }
    }
}

@MainActor
@Observable
final class LogViewerViewModel {
    let job: LaunchJob
    var stream: LogStream
    var searchText = ""
    var autoRefresh = true
    var autoScroll = true
    var lineCount: Int
    private(set) var snapshot = LogSnapshot(state: .notConfigured, lines: [], fileSize: 0, truncated: false)
    private(set) var isLoading = false
    private let service: LogService
    private var pollTask: Task<Void, Never>?

    init(job: LaunchJob, lineCount: Int, service: LogService = LogService()) {
        self.job = job
        self.lineCount = lineCount
        self.service = service
        let hasStdout = !(job.definition.standardOutPath ?? "").isEmpty
        let hasStderr = !(job.definition.standardErrorPath ?? "").isEmpty
        stream = (!hasStdout && hasStderr) ? .stderr : .stdout
    }

    var path: String? {
        if stream == .launchd { return nil }
        return stream == .stdout ? job.definition.standardOutPath : job.definition.standardErrorPath
    }

    var sameFileForBoth: Bool {
        job.definition.standardOutPath != nil && job.definition.standardOutPath == job.definition.standardErrorPath
    }

    var visibleLines: [(index: Int, text: String)] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let enumerated = snapshot.lines.enumerated().map { (index: $0.offset, text: $0.element) }
        guard !query.isEmpty else { return enumerated }
        return enumerated.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    func reload() async {
        if stream == .launchd {
            await loadDiagnostics()
            return
        }
        isLoading = true
        let path = path
        let count = lineCount
        let service = service
        let result = await Task.detached(priority: .userInitiated) {
            service.tail(path: path, lines: count)
        }.value
        snapshot = result
        isLoading = false
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                // Diagnostics run `log show`: refreshed manually, never polled.
                guard self.autoRefresh, self.stream != .launchd else { continue }
                let path = self.path
                let attributes = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
                let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = attributes?[.modificationDate] as? Date
                if size != self.snapshot.fileSize || modified != self.snapshot.modified {
                    await self.reload()
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Diagnostics origin shown in the status bar.
    private(set) var diagnosticsOrigin = ""

    /// Reads what launchd reported about this job: `launchctl print` and the unified log (last hour).
    /// Read-only; no history of runs is invented — only what the system logged.
    private func loadDiagnostics() async {
        isLoading = true
        let runner = ProcessCommandRunner(timeout: 20)
        let target = job.runtime.domain.serviceTarget(job.label)
        let predicate = "subsystem == \"com.apple.xpc.launchd\" AND eventMessage CONTAINS \"\(job.label)\""
        var lines: [String] = []
        if let print = try? await runner.run(LaunchctlService.executable, arguments: ["print", target]) {
            lines.append("── launchctl print \(target) (код \(print.exitCode))")
            lines += (print.exitCode == 0 ? print.stdout : print.combinedOutput).components(separatedBy: "\n").filter { line in
                ["state =", "pid =", "runs =", "last exit", "path =", "program ="].contains { line.contains($0) }
            }
        }
        if let log = try? await runner.run(URL(filePath: "/usr/bin/log"), arguments: ["show", "--last", "1h", "--style", "compact", "--predicate", predicate]) {
            lines.append("── log show --last 1h (launchd о задании)")
            let entries = log.stdout.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("Timestamp") }
            lines += entries.isEmpty ? ["(записей нет)"] : Array(entries.suffix(lineCount))
        }
        diagnosticsOrigin = "launchctl print + log show"
        snapshot = LogSnapshot(state: lines.isEmpty ? .unreadable("Диагностика недоступна.") : .ok, lines: lines, fileSize: 0, modified: .now, truncated: false)
        isLoading = false
    }

    var allText: String { visibleLines.map(\.text).joined(separator: "\n") }
}
