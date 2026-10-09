import Foundation

struct ScanResult: Sendable {
    var jobs: [LaunchJob]
    /// Non-fatal problems (unreadable directory, launchctl unavailable…).
    var warnings: [String]
}

/// Discovers plists on disk and joins them with launchd runtime state.
/// Never executes anything from the plist: only `launchctl list/print` is run.
struct LaunchAgentScanner: Sendable {
    var launchctl: any LaunchctlControlling
    var directories: [JobScope: URL] = Dictionary(uniqueKeysWithValues: JobScope.allCases.map { ($0, $0.directory) })
    var uid: UInt32 = getuid()

    func scan(includeSystem: Bool, metadata: [String: JobMetadata] = [:]) async -> ScanResult {
        var warnings: [String] = []
        let scopes: [JobScope] = includeSystem ? JobScope.allCases : [.userAgent]

        var jobs: [LaunchJob] = []
        for scope in scopes {
            guard let directory = directories[scope] else { continue }
            let files: [URL]
            do {
                files = try plistFiles(in: directory)
            } catch {
                if scope == .userAgent, (error as NSError).code == NSFileReadNoSuchFileError { continue }
                warnings.append("Не удалось прочитать \(directory.path): \(error.localizedDescription)")
                continue
            }
            jobs += files.map { loadJob(at: $0, scope: scope) }
        }

        // Query each domain once.
        let domains = Set(jobs.map(\.runtime.domain))
        var loaded: [LaunchDomain: [String: LoadedService]] = [:]
        var overrides: [LaunchDomain: [String: Bool]] = [:]
        for domain in domains {
            do {
                loaded[domain] = try await launchctl.loadedServices(in: domain)
            } catch {
                warnings.append("Состояние домена \(domain.target) недоступно: \(error.localizedDescription)")
            }
            do {
                overrides[domain] = try await launchctl.disabledOverrides(in: domain)
            } catch {
                warnings.append("Список отключённых служб \(domain.target) недоступен: \(error.localizedDescription)")
            }
        }

        let labelCounts = Dictionary(jobs.map { ($0.label, 1) }, uniquingKeysWith: +)
        for index in jobs.indices {
            let domain = jobs[index].runtime.domain
            let label = jobs[index].label
            if let services = loaded[domain] {
                if let service = services[label] {
                    jobs[index].runtime.loaded = .yes
                    jobs[index].runtime.pid = service.pid
                    jobs[index].runtime.lastExit = service.lastExit
                } else {
                    jobs[index].runtime.loaded = .no
                    jobs[index].runtime.lastExit = .none
                }
            }
            if let domainOverrides = overrides[domain] {
                jobs[index].runtime.overridesKnown = true
                jobs[index].runtime.disabledOverride = domainOverrides[label]
            }
            jobs[index].metadata = metadata[label] ?? JobMetadata()
            jobs[index].issues = JobAnalyzer.issues(for: jobs[index])
            if (labelCounts[label] ?? 0) > 1 {
                jobs[index].issues.insert(.init(severity: .warning, message: "Этот Label используется несколькими plist-файлами. Состояние в launchd может относиться к другому файлу; Orbito проверяет путь перед перезагрузкой."), at: 0)
            }
        }

        return ScanResult(jobs: jobs, warnings: warnings)
    }

    func plistFiles(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { $0.pathExtension == "plist" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func loadJob(at url: URL, scope: JobScope) -> LaunchJob {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let fallbackLabel = url.deletingPathExtension().lastPathComponent
        do {
            let (dict, format) = try PlistService.read(url)
            let definition = PlistService.definition(from: dict)
            let label = definition.label ?? fallbackLabel
            return LaunchJob(
                label: label, plistURL: url, scope: scope, format: format, raw: dict,
                definition: definition,
                runtime: RuntimeState(domain: Self.domain(for: scope, definition: definition, uid: uid)),
                fileModified: modified
            )
        } catch {
            return LaunchJob(
                label: fallbackLabel, plistURL: url, scope: scope, format: .xml, raw: [:],
                definition: JobDefinition(),
                runtime: RuntimeState(domain: Self.domain(for: scope, definition: JobDefinition(), uid: uid)),
                loadError: error.localizedDescription,
                fileModified: modified
            )
        }
    }

    /// Agents go to the GUI (Aqua) domain unless restricted to Background sessions.
    static func domain(for scope: JobScope, definition: JobDefinition, uid: UInt32) -> LaunchDomain {
        switch scope {
        case .globalDaemon:
            return .system
        case .userAgent, .globalAgent:
            let sessions = definition.limitLoadToSessionType
            if !sessions.isEmpty, !sessions.contains("Aqua"), sessions.contains("Background") {
                return .user(uid: uid)
            }
            return .gui(uid: uid)
        }
    }
}

/// Static checks that never execute anything.
enum JobAnalyzer {
    static func issues(for job: LaunchJob, fileManager: FileManager = .default) -> [JobIssue] {
        if let error = job.loadError { return [JobIssue(severity: .error, message: error)] }
        var issues: [JobIssue] = []
        let def = job.definition

        if def.label == nil {
            issues.append(.init(severity: .error, message: "В plist нет ключа Label — launchd не загрузит задание."))
        } else if job.label != job.plistURL.deletingPathExtension().lastPathComponent {
            issues.append(.init(severity: .info, message: "Имя файла не совпадает с Label."))
        }

        if let exe = def.executablePath {
            if !exe.hasPrefix("/") {
                issues.append(.init(severity: .warning, message: "Исполняемый файл «\(exe)» указан без абсолютного пути — launchd ищет его только в /usr/bin:/bin:/usr/sbin:/sbin."))
            } else if !fileManager.fileExists(atPath: exe) {
                issues.append(.init(severity: .error, message: "Исполняемый файл не найден: \(exe)"))
            } else if !fileManager.isExecutableFile(atPath: exe) {
                issues.append(.init(severity: .error, message: "Файл не является исполняемым: \(exe)"))
            }
        } else {
            issues.append(.init(severity: .error, message: "Не указаны Program или ProgramArguments."))
        }

        if let script = def.scriptPath, !fileManager.fileExists(atPath: script) {
            issues.append(.init(severity: .error, message: "Скрипт не найден: \(script)"))
        }

        if let wd = def.workingDirectory {
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: wd, isDirectory: &isDir) || !isDir.boolValue {
                issues.append(.init(severity: .error, message: "Рабочая директория не найдена: \(wd)"))
            }
        }

        for path in [def.standardOutPath, def.standardErrorPath].compactMap({ $0 }) {
            let dir = (path as NSString).deletingLastPathComponent
            if !path.hasPrefix("/") {
                issues.append(.init(severity: .warning, message: "Путь лога «\(path)» не абсолютный."))
            } else if !fileManager.fileExists(atPath: dir) {
                issues.append(.init(severity: .warning, message: "Каталог для лога не существует: \(dir) — launchd не сможет создать файл."))
            }
        }

        switch job.runtime.lastExit {
        case .exitCode(let code) where code != 0:
            issues.append(.init(severity: .warning, message: "Последний запуск завершился с кодом \(code). Это не обязательно означает, что задание сломано — проверьте логи."))
        case .signal(let signal):
            issues.append(.init(severity: .warning, message: "Последний запуск завершён сигналом \(signal) (\(LastExit.signalName(signal)))."))
        default: break
        }

        for warning in ScheduleService().warnings(for: def.schedule) {
            issues.append(.init(severity: .warning, message: warning))
        }
        return issues.sorted { $0.severity > $1.severity }
    }
}
