import Foundation

struct ArgumentItem: Identifiable, Hashable {
    var id = UUID()
    var value: String
}

struct EnvironmentItem: Identifiable, Hashable {
    var id = UUID()
    var key: String
    var value: String
}

/// Editable fields of a job (command, paths, flags). Shared by the editor and the wizard.
struct JobForm: Hashable {
    var displayName = ""
    var label = ""
    var notes = ""
    var executable = ""
    var arguments: [ArgumentItem] = []
    var workingDirectory = ""
    var environment: [EnvironmentItem] = []
    var standardOutPath = ""
    var standardErrorPath = ""
    var runAtLoad = false
    var keepAlive = false
    var keepAliveIsConditional = false

    init() {}

    init(job: LaunchJob) {
        let def = job.definition
        displayName = job.metadata.displayName ?? ""
        label = job.label
        notes = job.metadata.notes ?? ""
        executable = def.executablePath ?? ""
        // With `Program`, ProgramArguments[0] is argv[0]; without it, it is the binary.
        arguments = Array(def.programArguments.dropFirst()).map { ArgumentItem(value: $0) }
        workingDirectory = def.workingDirectory ?? ""
        environment = def.environment.sorted { $0.key < $1.key }.map { EnvironmentItem(key: $0.key, value: $0.value) }
        standardOutPath = def.standardOutPath ?? ""
        standardErrorPath = def.standardErrorPath ?? ""
        runAtLoad = def.runAtLoad
        if case .always(let value) = def.keepAlive { keepAlive = value }
        keepAliveIsConditional = def.keepAlive == .conditional
    }

    var argv: [String] { [executable] + arguments.map(\.value) }

    var trimmedLabel: String { label.trimmingCharacters(in: .whitespaces) }

    /// Applies form values onto `base`, leaving every unrelated key intact.
    func applying(to base: [String: PlistValue]) -> [String: PlistValue] {
        var dict = base
        dict["Label"] = .string(trimmedLabel)

        let args = arguments.map(\.value)
        if base["Program"] != nil {
            dict["Program"] = .string(executable)
            let argv0 = base["ProgramArguments"]?.arrayValue?.first ?? .string(executable)
            dict["ProgramArguments"] = .array([argv0] + args.map(PlistValue.string))
        } else {
            dict["ProgramArguments"] = .array(([executable] + args).map(PlistValue.string))
        }

        Self.set(&dict, "WorkingDirectory", workingDirectory)
        Self.set(&dict, "StandardOutPath", standardOutPath)
        Self.set(&dict, "StandardErrorPath", standardErrorPath)

        let env = environment.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        if env.isEmpty {
            dict.removeValue(forKey: "EnvironmentVariables")
        } else {
            dict["EnvironmentVariables"] = .dictionary(Dictionary(env.map { ($0.key.trimmingCharacters(in: .whitespaces), PlistValue.string($0.value)) }, uniquingKeysWith: { _, last in last }))
        }

        Self.setBool(&dict, "RunAtLoad", runAtLoad, base: base)
        if !keepAliveIsConditional { Self.setBool(&dict, "KeepAlive", keepAlive, base: base) }
        return dict
    }

    private static func set(_ dict: inout [String: PlistValue], _ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { dict.removeValue(forKey: key) } else { dict[key] = .string(trimmed) }
    }

    /// Writes `false` only if the key already existed, to avoid noise in new files.
    private static func setBool(_ dict: inout [String: PlistValue], _ key: String, _ value: Bool, base: [String: PlistValue]) {
        if value || base[key] != nil { dict[key] = .bool(value) } else { dict.removeValue(forKey: key) }
    }

    // MARK: Validation

    struct Validation {
        var errors: [String] = []
        var warnings: [String] = []
    }

    func validateCommand(fileManager: FileManager = .default) -> Validation {
        var result = Validation()
        let exe = executable.trimmingCharacters(in: .whitespaces)
        if exe.isEmpty {
            result.errors.append("Укажите исполняемый файл.")
        } else if !exe.hasPrefix("/") {
            result.errors.append("Путь к исполняемому файлу должен быть абсолютным (launchd не использует ваш PATH).")
        } else if !fileManager.fileExists(atPath: exe) {
            result.errors.append("Файл не найден: \(exe)")
        } else if !fileManager.isExecutableFile(atPath: exe) {
            result.errors.append("Файл не исполняемый: \(exe). Выберите интерпретатор (например /bin/zsh) и передайте скрипт аргументом.")
        }
        if let script = arguments.first?.value, script.hasPrefix("/"), !fileManager.fileExists(atPath: script) {
            result.warnings.append("Первый аргумент выглядит как путь, но файл не найден: \(script)")
        }
        if arguments.contains(where: { $0.value.contains(" && ") || $0.value.contains(" | ") || $0.value.contains(";") }) {
            result.warnings.append("Аргументы передаются напрямую, без shell: операторы &&, |, ; не сработают. Поместите команды в скрипт.")
        }
        let wd = workingDirectory.trimmingCharacters(in: .whitespaces)
        if !wd.isEmpty {
            var isDir: ObjCBool = false
            if !wd.hasPrefix("/") { result.errors.append("Рабочая директория должна быть абсолютным путём.") }
            else if !fileManager.fileExists(atPath: wd, isDirectory: &isDir) || !isDir.boolValue {
                result.errors.append("Рабочая директория не найдена: \(wd)")
            }
        }
        for item in environment where !item.key.isEmpty {
            if item.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
                result.errors.append("Недопустимое имя переменной окружения: \(item.key)")
            }
        }
        return result
    }

    func validateLogs() -> Validation {
        var result = Validation()
        for (name, path) in [("stdout", standardOutPath), ("stderr", standardErrorPath)] {
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if !trimmed.hasPrefix("/") { result.errors.append("Путь \(name) должен быть абсолютным.") }
            else if trimmed.hasSuffix("/") { result.errors.append("Путь \(name) должен указывать на файл, а не каталог.") }
        }
        return result
    }
}

/// Picks an explicit interpreter for scripts so the plist never relies on a shell.
enum ScriptInterpreter {
    static func candidates(for ext: String) -> [String] {
        switch ext.lowercased() {
        case "sh", "bash": ["/bin/bash"]
        case "zsh": ["/bin/zsh"]
        case "py": ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        case "php": ["/opt/homebrew/bin/php", "/usr/local/bin/php", "/usr/bin/php"]
        case "js", "mjs", "cjs": ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        case "rb": ["/opt/homebrew/bin/ruby", "/usr/bin/ruby"]
        case "pl": ["/usr/bin/perl"]
        default: []
        }
    }

    static let known: [(name: String, path: String)] = [
        ("Zsh", "/bin/zsh"), ("Bash", "/bin/bash"), ("sh", "/bin/sh"),
        ("Python 3", firstExisting(candidates(for: "py")) ?? "/usr/bin/python3"),
        ("PHP", firstExisting(candidates(for: "php")) ?? "/opt/homebrew/bin/php"),
        ("Node.js", firstExisting(candidates(for: "js")) ?? "/opt/homebrew/bin/node"),
    ]

    static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns (executable, arguments) for a dropped or chosen file.
    static func command(for file: URL) -> (executable: String, arguments: [String]) {
        let path = file.path
        if let interpreter = firstExisting(candidates(for: file.pathExtension)) {
            return (interpreter, [path])
        }
        if let shebang = shebangInterpreter(file), FileManager.default.isExecutableFile(atPath: shebang.0) {
            return (shebang.0, shebang.1 + [path])
        }
        return (path, [])
    }

    /// Reads only the first line of the file; never executes it.
    static func shebangInterpreter(_ file: URL) -> (String, [String])? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256), data.starts(with: Array("#!".utf8)) else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        let parts = line.dropFirst(2).split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        if first == "/usr/bin/env", parts.count >= 2 {
            let name = parts[1]
            let resolved = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map { "\($0)/\(name)" }
            return firstExisting(resolved).map { ($0, Array(parts.dropFirst(2))) }
        }
        return (first, Array(parts.dropFirst()))
    }
}

/// State of the "edit job" sheet.
@MainActor
@Observable
final class TaskEditorViewModel {
    let job: LaunchJob
    var form: JobForm
    var isSaving = false
    var errorMessage: String?

    init(job: LaunchJob) {
        self.job = job
        self.form = JobForm(job: job)
    }

    var validation: JobForm.Validation {
        let command = form.validateCommand()
        let logs = form.validateLogs()
        return .init(errors: command.errors + logs.errors, warnings: command.warnings + logs.warnings)
    }

    var updatedPlist: [String: PlistValue] { form.applying(to: job.raw) }

    var hasChanges: Bool {
        updatedPlist != job.raw || form.displayName != (job.metadata.displayName ?? "") || form.notes != (job.metadata.notes ?? "")
    }

    func save(using appState: AppState) async -> Bool {
        guard validation.errors.isEmpty else { return false }
        isSaving = true
        defer { isSaving = false }
        let metadata = JobMetadata(displayName: form.displayName.isEmpty ? nil : form.displayName, notes: form.notes.isEmpty ? nil : form.notes)
        return await appState.saveDefinition(updatedPlist, for: job, metadata: metadata)
    }
}

/// State of the schedule editor sheet.
@MainActor
@Observable
final class ScheduleEditorViewModel {
    let job: LaunchJob
    var draft: ScheduleDraft
    var isSaving = false

    init(job: LaunchJob) {
        self.job = job
        self.draft = ScheduleDraft(schedule: job.definition.schedule)
    }

    var built: JobSchedule? { try? draft.build() }

    var preview: [Date] {
        guard let built else { return [] }
        return ScheduleService().nextRuns(of: built, after: .now, count: 5)
    }

    var summary: String {
        guard let built else { return "—" }
        var def = job.definition
        def.schedule = built
        return ScheduleFormatter.describe(def)
    }

    var plistFragment: String {
        guard let built else { return "" }
        let dict = PlistService.applying(built, to: [:])
        return PlistService.xmlString(dict)
            .components(separatedBy: "\n")
            .drop { !$0.hasPrefix("<dict>") }
            .dropFirst()
            .filter { $0 != "</dict>" && $0 != "</plist>" && !$0.isEmpty }
            .joined(separator: "\n")
    }

    var updatedPlist: [String: PlistValue]? {
        built.map { PlistService.applying($0, to: job.raw) }
    }

    var hasChanges: Bool {
        guard let updatedPlist else { return false }
        return updatedPlist != job.raw
    }

    func save(using appState: AppState) async -> Bool {
        guard let built else { return false }
        isSaving = true
        defer { isSaving = false }
        return await appState.saveSchedule(built, for: job)
    }
}
