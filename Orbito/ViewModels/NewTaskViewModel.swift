import Foundation

enum WizardStep: Int, CaseIterable, Identifiable {
    case info, command, schedule, logging, review
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .info: "Основное"
        case .command: "Команда"
        case .schedule: "Расписание"
        case .logging: "Логи"
        case .review: "Проверка"
        }
    }

    var symbol: String {
        switch self {
        case .info: "textformat"
        case .command: "terminal"
        case .schedule: "clock"
        case .logging: "doc.text"
        case .review: "checkmark.seal"
        }
    }
}

@MainActor
@Observable
final class NewTaskViewModel {
    var step: WizardStep = .info
    var form = JobForm()
    var draft = ScheduleDraft()
    var loadAfterCreate = true
    var labelEditedManually = false
    var isCreating = false
    var errorMessage: String?
    let existingLabels: Set<String>

    /// Set from Settings → Tasks when the wizard opens.
    var logDirectory = NewTaskViewModel.defaultLogDirectory
    static let defaultLogDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Orbito", directoryHint: .isDirectory).path

    init(existingLabels: Set<String>) {
        self.existingLabels = existingLabels
        draft.mode = .daily
    }

    // MARK: Step 1

    func nameChanged() {
        guard !labelEditedManually else { return }
        form.label = LabelValidator.suggestedLabel(from: form.displayName)
        updateDefaultLogPaths()
    }

    var labelError: String? {
        let label = form.trimmedLabel
        if label.isEmpty { return "Укажите Label." }
        do {
            try LabelValidator.validateNew(label, existingLabels: existingLabels, directory: JobScope.userAgent.directory)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Step 2

    func useFile(_ url: URL) {
        let command = ScriptInterpreter.command(for: url)
        form.executable = command.executable
        form.arguments = command.arguments.map { ArgumentItem(value: $0) }
        if form.workingDirectory.isEmpty {
            form.workingDirectory = url.deletingLastPathComponent().path
        }
        if form.displayName.isEmpty {
            form.displayName = url.deletingPathExtension().lastPathComponent
            nameChanged()
        }
    }

    // MARK: Step 4

    func updateDefaultLogPaths() {
        let label = form.trimmedLabel.isEmpty ? "task" : form.trimmedLabel
        let dir = logDirectory
        let outIsDefault = form.standardOutPath.isEmpty || form.standardOutPath.hasPrefix(dir)
        let errIsDefault = form.standardErrorPath.isEmpty || form.standardErrorPath.hasPrefix(dir)
        if outIsDefault { form.standardOutPath = "\(dir)/\(label).out.log" }
        if errIsDefault { form.standardErrorPath = "\(dir)/\(label).err.log" }
    }

    func setLogDirectory(_ url: URL) {
        let label = form.trimmedLabel.isEmpty ? "task" : form.trimmedLabel
        form.standardOutPath = url.appending(path: "\(label).out.log").path
        form.standardErrorPath = url.appending(path: "\(label).err.log").path
    }

    // MARK: Navigation

    func errors(for step: WizardStep) -> [String] {
        switch step {
        case .info: labelError.map { [$0] } ?? []
        case .command: form.validateCommand().errors
        case .schedule: draft.validationErrors
        case .logging: form.validateLogs().errors
        case .review: WizardStep.allCases.dropLast().flatMap { errors(for: $0) }
        }
    }

    var canAdvance: Bool { errors(for: step).isEmpty }

    func next() {
        guard canAdvance, let next = WizardStep(rawValue: step.rawValue + 1) else { return }
        if next == .logging { updateDefaultLogPaths() }
        step = next
    }

    func back() {
        if let previous = WizardStep(rawValue: step.rawValue - 1) { step = previous }
    }

    // MARK: Result

    var plistDictionary: [String: PlistValue] {
        var dict = form.applying(to: [:])
        if let schedule = try? draft.build() {
            dict = PlistService.applying(schedule, to: dict)
        }
        return dict
    }

    var plistPreview: String { PlistService.xmlString(plistDictionary) }

    var scheduleSummary: String {
        guard let schedule = try? draft.build() else { return "—" }
        var def = JobDefinition()
        def.schedule = schedule
        def.runAtLoad = form.runAtLoad
        return ScheduleFormatter.describe(def)
    }

    func create(using appState: AppState) async -> Bool {
        let errors = errors(for: .review)
        guard errors.isEmpty else {
            errorMessage = errors.joined(separator: "\n")
            return false
        }
        isCreating = true
        defer { isCreating = false }
        do {
            let metadata = JobMetadata(
                displayName: form.displayName.isEmpty ? nil : form.displayName,
                notes: form.notes.isEmpty ? nil : form.notes
            )
            _ = try await appState.create(dict: plistDictionary, metadata: metadata, load: loadAfterCreate)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
