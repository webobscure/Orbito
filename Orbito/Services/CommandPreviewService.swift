import Foundation

/// Actions that have a CLI explanation (tooltips, previews, reference).
enum CLIAction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case runNow, stop, load, unload, reload, enable, disable
    case editSchedule, editConfiguration, create, duplicate, delete
    case viewLogs, inspect, listTasks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runNow: "Запустить сейчас"
        case .stop: "Остановить процесс"
        case .load: "Загрузить"
        case .unload: "Выгрузить"
        case .reload: "Перезагрузить"
        case .enable: "Включить"
        case .disable: "Отключить"
        case .editSchedule: "Изменить расписание"
        case .editConfiguration: "Изменить конфигурацию"
        case .create: "Создать задание"
        case .duplicate: "Дублировать"
        case .delete: "Удалить"
        case .viewLogs: "Открыть логи"
        case .inspect: "Состояние в планировщике"
        case .listTasks: "Список заданий"
        }
    }

    var summary: String {
        switch self {
        case .runNow: "Немедленно запускает задание вне расписания."
        case .stop: "Отправляет сигнал завершения работающему процессу."
        case .load: "Регистрирует задание в планировщике, после чего оно начинает работать по расписанию."
        case .unload: "Убирает задание из планировщика до следующей загрузки. Файл остаётся."
        case .reload: "Выгружает и снова загружает задание, чтобы применить изменённую конфигурацию."
        case .enable: "Снимает запрет на загрузку задания и загружает его."
        case .disable: "Запрещает загрузку задания (сохраняется после перезагрузки) и выгружает его."
        case .editSchedule: "Меняет только параметры расписания и применяет их."
        case .editConfiguration: "Меняет конфигурацию задания и применяет её."
        case .create: "Создаёт файл конфигурации и регистрирует задание."
        case .duplicate: "Создаёт копию задания с новым идентификатором."
        case .delete: "Выгружает задание и удаляет его конфигурацию."
        case .viewLogs: "Показывает последние строки вывода задания."
        case .inspect: "Показывает, что о задании знает планировщик."
        case .listTasks: "Показывает задания текущего пользователя."
        }
    }
}

struct CommandStep: Identifiable, Hashable, Sendable {
    var id = UUID()
    var command: String
    var purpose: String
    var isDestructive = false
    /// e.g. "если задание загружено".
    var condition: String?
}

struct FilePreview: Identifiable, Hashable, Sendable {
    var path: String
    var before: String?
    var after: String?
    var structured: [StructuredChange]
    /// Terminal equivalent of the file edit (plutil). Shown, never executed.
    var manualCommands: [String]
    var id: String { path }
}

/// Everything Orbito will do for an action, generated from the real job model.
struct CommandPreview: Identifiable, Hashable, Sendable {
    var id = UUID()
    var action: CLIAction
    var title: String
    var label: String?
    var connection = "Этот Mac (локально)"
    var platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)"
    var backend = "launchd"
    var files: [FilePreview] = []
    var steps: [CommandStep] = []
    var warnings: [String] = []
    /// A running process would be stopped: confirm even when previews are off.
    var requiresConfirmation = false

    /// All commands as a copy-pasteable script, in execution order.
    /// File edits are already part of `steps`; `manualCommands` are only for display.
    var script: String {
        var lines = ["# Orbito — \(title)" + (label.map { " (\($0))" } ?? "")]
        for step in steps {
            lines.append("# \(step.purpose)" + (step.condition.map { " — \($0)" } ?? ""))
            lines.append(step.command)
        }
        return lines.joined(separator: "\n")
    }
}

/// Builds exact launchctl/plutil sequences for the selected LaunchAgent. Never executes anything.
struct CommandPreviewService: Sendable {
    var uid: UInt32 = getuid()
    var backupDirectory: String = BackupService.defaultRoot.path

    private func q(_ s: String) -> String { Workspace.shellCommand([s]) }

    /// Mirrors `BackupService.backup`: `<root>/<safe>/<safe>-yyyyMMdd-HHmmss.plist`.
    private func backupStep(_ job: LaunchJob, purpose: String) -> CommandStep {
        let safe = BackupService.safeName(job.label)
        let dir = "\(backupDirectory)/\(safe)"
        return CommandStep(
            command: "mkdir -p \(q(dir)) && cp \(q(job.plistURL.path)) \(q(dir))/\(q(safe))-$(date +%Y%m%d-%H%M%S).plist",
            purpose: purpose
        )
    }

    func target(_ job: LaunchJob) -> String { job.runtime.domain.serviceTarget(job.label) }
    func domain(_ job: LaunchJob) -> String { job.runtime.domain.target }

    // MARK: Runtime actions

    func preview(_ action: CLIAction, for job: LaunchJob, killRunning: Bool = false) -> CommandPreview {
        var preview = CommandPreview(action: action, title: action.title, label: job.label)
        let t = q(target(job)), d = q(domain(job)), path = q(job.plistURL.path)
        let loaded = job.runtime.loaded == .yes

        switch action {
        case .runNow:
            preview.steps = [CommandStep(command: "launchctl kickstart \(killRunning ? "-k " : "")\(t)", purpose: killRunning ? "Перезапустить работающий процесс" : "Запустить задание сейчас", isDestructive: killRunning)]
            if killRunning {
                preview.requiresConfirmation = true
                preview.warnings.append("Работающий процесс\(job.runtime.pid.map { " (PID \($0))" } ?? "") будет завершён и запущен заново.")
            }
            switch job.runtime.loaded {
            case .no: preview.warnings.append("Задание не загружено: kickstart вернёт ошибку «Could not find service». Сначала загрузите его.")
            case .unknown: preview.warnings.append("Состояние в launchd неизвестно: если задание не загружено, kickstart вернёт ошибку.")
            case .yes: break
            }
        case .stop:
            preview.steps = [CommandStep(command: "launchctl kill SIGTERM \(t)", purpose: "Попросить процесс завершиться", isDestructive: true)]
            if job.runtime.loaded != .yes { preview.warnings.append("Задание не загружено (или состояние неизвестно) — Orbito не будет отправлять сигнал.") }
            if job.definition.keepAlive.isActive { preview.warnings.append("У задания включён KeepAlive — launchd сразу запустит процесс снова.") }
        case .load:
            preview.steps = [CommandStep(command: "launchctl bootstrap \(d) \(path)", purpose: "Загрузить задание в launchd")]
        case .unload:
            preview.steps = [CommandStep(command: "launchctl bootout \(t)", purpose: "Выгрузить задание", isDestructive: true)]
            if job.runtime.pid != nil { preview.warnings.append("Работающий процесс будет остановлен.") }
        case .reload:
            if job.isDisabled != .no {
                preview.warnings.append(job.isDisabled == .yes
                    ? "Задание отключено: после выгрузки launchd не загрузит его снова. Orbito не будет перезагружать его — сначала включите задание."
                    : "Не удалось определить, отключено ли задание. Orbito не будет перезагружать его.")
            } else {
                preview.steps = reloadSteps(job, condition: nil)
                if job.runtime.pid != nil {
                    preview.requiresConfirmation = true
                    preview.warnings.append("Работающий процесс будет остановлен.")
                }
            }
        case .enable:
            preview.steps = [CommandStep(command: "launchctl enable \(t)", purpose: "Снять запрет (disabled) в базе launchd")]
            if !loaded { preview.steps.append(CommandStep(command: "launchctl bootstrap \(d) \(path)", purpose: "Загрузить задание")) }
        case .disable:
            preview.steps = [CommandStep(command: "launchctl disable \(t)", purpose: "Запретить загрузку (сохраняется после перезагрузки)")]
            if loaded { preview.steps.append(CommandStep(command: "launchctl bootout \(t)", purpose: "Выгрузить сейчас", isDestructive: true)) }
            preview.warnings.append("Файл plist не изменяется: запрет хранится в базе переопределений launchd.")
        case .delete:
            preview.steps = [backupStep(job, purpose: "Резервная копия")]
            if job.runtime.loaded != .no { preview.steps.append(CommandStep(command: "launchctl bootout \(t)", purpose: "Выгрузить задание", isDestructive: true, condition: loaded ? nil : "если загружено")) }
            preview.steps.append(CommandStep(command: "mv \(path) ~/.Trash/", purpose: "Переместить файл в Корзину", isDestructive: true))
        case .viewLogs:
            for (name, logPath) in [("stdout", job.definition.standardOutPath), ("stderr", job.definition.standardErrorPath)] {
                if let logPath { preview.steps.append(CommandStep(command: "tail -n 100 \(q(logPath))", purpose: "Последние 100 строк \(name)")) }
            }
            if preview.steps.isEmpty { preview.warnings.append("В plist не заданы StandardOutPath/StandardErrorPath — вывод задания нигде не сохраняется.") }
            preview.steps.append(CommandStep(command: "log show --last 1h --predicate 'subsystem == \"com.apple.xpc.launchd\" AND eventMessage CONTAINS \"\(job.label)\"'", purpose: "Сообщения launchd о задании за час"))
        case .inspect:
            preview.steps = [
                CommandStep(command: "launchctl print \(t)", purpose: "Полное состояние службы"),
                CommandStep(command: "launchctl print-disabled \(d)", purpose: "Список запретов (disabled) домена"),
                CommandStep(command: "plutil -p \(path)", purpose: "Содержимое plist"),
            ]
        case .listTasks:
            preview.steps = [
                CommandStep(command: "launchctl list", purpose: "Загруженные задания пользователя (PID, код, Label)"),
                CommandStep(command: "ls ~/Library/LaunchAgents", purpose: "Файлы пользовательских агентов"),
            ]
        case .editSchedule, .editConfiguration, .create, .duplicate:
            preview.warnings.append("Для этого действия используйте предпросмотр изменений.")
        }
        return preview
    }

    private func reloadSteps(_ job: LaunchJob, condition: String?) -> [CommandStep] {
        [
            CommandStep(command: "launchctl bootout \(q(target(job)))", purpose: "Выгрузить старую версию", isDestructive: true, condition: condition),
            CommandStep(command: "launchctl bootstrap \(q(domain(job))) \(q(job.plistURL.path))", purpose: "Загрузить новую версию", condition: condition),
        ]
    }

    // MARK: Configuration changes

    /// Preview for replacing the plist of an existing job (schedule or definition edits).
    func previewChange(_ action: CLIAction, job: LaunchJob, newDict: [String: PlistValue]) -> CommandPreview {
        var preview = CommandPreview(action: action, title: action.title, label: job.label)
        let path = job.plistURL.path
        let manual = plutilCommands(old: job.raw, new: newDict, path: path)
        preview.files = [FilePreview(
            path: path,
            before: PlistService.xmlString(job.raw),
            after: PlistService.xmlString(newDict),
            structured: ConfigurationDiffService.structured(old: job.raw, new: newDict),
            manualCommands: manual
        )]
        preview.steps = [backupStep(job, purpose: "Резервная копия перед изменением")]
        preview.steps += manual.map { CommandStep(command: $0, purpose: "Изменить ключ plist") }
        preview.steps.append(CommandStep(command: "plutil -lint \(q(path))", purpose: "Проверить корректность plist"))

        switch job.runtime.loaded {
        case .yes where job.isDisabled == .no:
            preview.steps += reloadSteps(job, condition: nil)
            if job.runtime.pid != nil {
                preview.requiresConfirmation = true
                preview.warnings.append("Процесс сейчас выполняется (PID \(job.runtime.pid!)) — перезагрузка его остановит.")
            }
        case .yes:
            preview.warnings.append("Задание отключено — оно не будет перезагружено; изменения вступят в силу после включения.")
        case .no:
            preview.warnings.append("Задание не загружено — изменится только файл.")
        case .unknown:
            preview.warnings.append("Состояние в launchd неизвестно — Orbito не будет перезагружать задание.")
        }
        if newDict == job.raw { preview.warnings.insert("Изменений нет.", at: 0) }
        if manual.isEmpty && newDict != job.raw { preview.warnings.append("Изменение не выражается через plutil — Orbito запишет файл целиком.") }
        preview.warnings.append("Если применение не удастся, Orbito восстановит исходный файл из резервной копии.")
        return preview
    }

    func previewCreate(dict: [String: PlistValue], label: String, load: Bool, duplicateOf: String? = nil) -> CommandPreview {
        var preview = CommandPreview(action: duplicateOf == nil ? .create : .duplicate, title: duplicateOf == nil ? CLIAction.create.title : CLIAction.duplicate.title, label: label)
        let path = JobScope.userAgent.directory.appending(path: "\(label).plist").path
        let xml = PlistService.xmlString(dict)
        let dirs = Set([dict["StandardOutPath"]?.stringValue, dict["StandardErrorPath"]?.stringValue].compactMap { $0 }.map { ($0 as NSString).deletingLastPathComponent })
        // `test ! -e` guards the write: the file is created only if it does not exist yet.
        let write = "test ! -e \(q(path)) && cat > \(q(path)) <<'PLIST'\n\(xml)PLIST"
        preview.files = [FilePreview(path: path, before: nil, after: xml, structured: ConfigurationDiffService.structured(old: [:], new: dict), manualCommands: [write])]
        preview.steps = dirs.sorted().map { CommandStep(command: "mkdir -p \(q($0))", purpose: "Каталог для логов (launchd сам его не создаёт)") }
        preview.steps.append(CommandStep(command: write, purpose: "Создать файл, только если его ещё нет (Orbito никогда не перезаписывает)"))
        preview.steps.append(CommandStep(command: "plutil -lint \(q(path))", purpose: "Проверить корректность plist"))
        if load {
            preview.steps.append(CommandStep(command: "launchctl bootstrap gui/\(uid) \(q(path))", purpose: "Загрузить задание в launchd"))
        } else if duplicateOf != nil {
            preview.warnings.append("Копия не загружается в launchd, чтобы задание не выполнялось дважды.")
        }
        return preview
    }

    // MARK: plutil equivalents

    /// Top-level key edits as `plutil -replace/-remove` commands.
    func plutilCommands(old: [String: PlistValue], new: [String: PlistValue], path: String) -> [String] {
        var commands: [String] = []
        for key in Set(old.keys).union(new.keys).sorted() where old[key] != new[key] {
            let keyPath = q(key.replacingOccurrences(of: ".", with: "\\."))
            if let value = new[key] {
                commands.append("plutil -replace \(keyPath) \(plutilValue(value)) \(q(path))")
            } else {
                commands.append("plutil -remove \(keyPath) \(q(path))")
            }
        }
        return commands
    }

    private func plutilValue(_ value: PlistValue) -> String {
        switch value {
        case .string(let s): return "-string \(q(s))"
        case .integer(let i): return "-integer \(i)"
        case .real(let d): return "-float \(d)"
        case .bool(let b): return "-bool \(b ? "YES" : "NO")"
        case .array, .dictionary:
            if let json = jsonString(value) { return "-json \(q(json))" }
            fallthrough
        case .date, .data:
            let fragment = PlistService.xmlString(["v": value])
                .components(separatedBy: "\n").dropFirst(5).dropLast(3).joined()
                .trimmingCharacters(in: .whitespaces)
            return "-xml \(q(fragment))"
        }
    }

    private func jsonString(_ value: PlistValue) -> String? {
        func convert(_ v: PlistValue) -> Any? {
            switch v {
            case .string(let s): return s
            case .integer(let i): return i
            // JSON can't keep 1.0 as a real (plutil would store an integer): use -xml instead.
            case .real: return nil
            case .bool(let b): return b
            case .array(let a):
                let items = a.compactMap(convert)
                return items.count == a.count ? items : nil
            case .dictionary(let d):
                var out: [String: Any] = [:]
                for (k, item) in d { guard let c = convert(item) else { return nil }; out[k] = c }
                return out
            case .date, .data: return nil
            }
        }
        guard let object = convert(value),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
