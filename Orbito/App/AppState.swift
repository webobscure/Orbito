import Foundation
import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case dashboard, all, calendar, activity
    case active, disabled, errors
    case commandHistory, cliInspector
    case localMachine
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Обзор"
        case .all: "Все задачи"
        case .calendar: "Календарь"
        case .activity: "Активность"
        case .active: "Активные"
        case .disabled: "Отключённые"
        case .errors: "Проблемы"
        case .commandHistory: "История команд"
        case .cliInspector: "CLI Inspector"
        case .localMachine: "Этот Mac"
        case .settings: "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .all: "list.bullet.rectangle"
        case .calendar: "calendar"
        case .activity: "clock.arrow.circlepath"
        case .active: "bolt.circle"
        case .disabled: "pause.circle"
        case .errors: "exclamationmark.triangle"
        case .commandHistory: "terminal"
        case .cliInspector: "stethoscope"
        case .localMachine: "laptopcomputer"
        case .settings: "gearshape"
        }
    }

    var isTaskList: Bool { [.all, .active, .disabled, .errors].contains(self) }
    var isDeveloperOnly: Bool { [.commandHistory, .cliInspector].contains(self) }
}

struct Banner: Identifiable, Equatable {
    enum Style { case success, warning, error, info }
    var id = UUID()
    var style: Style
    var title: String
    var details: [String] = []
}

/// Pending action that needs explicit confirmation.
struct PendingConfirmation: Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var confirmTitle: String
    var isDestructive: Bool
    var action: @MainActor () async -> Void
}

/// A Command Preview shown as a sheet: just viewing, confirming an action, or the result of a Dry Run.
struct PreviewPresentation: Identifiable {
    enum Mode {
        case view
        case confirm(@MainActor () async -> Void)
        case dryRun
    }

    var id = UUID()
    var preview: CommandPreview
    var mode: Mode
    var job: LaunchJob?
}

/// Single source of truth for discovered jobs and global UI state.
@MainActor
@Observable
final class AppState {
    // Data
    private(set) var jobs: [LaunchJob] = []
    private(set) var scanWarnings: [String] = []
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var lastRefresh: Date?
    private(set) var busyJobIDs: Set<String> = []

    // Navigation / presentation
    var section: SidebarSection = .dashboard
    var selectedJobID: String?
    var banner: Banner?
    var confirmation: PendingConfirmation?
    var previewPresentation: PreviewPresentation?
    var isPresentingNewTask = false
    var scheduleEditorJob: LaunchJob?
    var definitionEditorJob: LaunchJob?
    var rawEditorJob: LaunchJob?
    var duplicateJob: LaunchJob?

    // Collaborators
    let settings: AppSettings
    let history: HistoryStore
    let commandHistory: CommandHistoryStore
    let metadata: MetadataStore
    let taskList = TaskListViewModel()
    let scheduleService = ScheduleService()
    let logService = LogService()
    private let launchctl: any LaunchctlControlling
    private let plistService: PlistService

    private var refreshTask: Task<Void, Never>?
    private var previousExits: [String: LastExit] = [:]

    init(
        settings: AppSettings = AppSettings(),
        history: HistoryStore = HistoryStore(),
        commandHistory: CommandHistoryStore = CommandHistoryStore(),
        metadata: MetadataStore = MetadataStore(),
        launchctl: (any LaunchctlControlling)? = nil,
        plistService: PlistService? = nil
    ) {
        self.settings = settings
        self.history = history
        self.commandHistory = commandHistory
        self.metadata = metadata
        // Every process goes through the recording runner; only commands run inside a
        // CommandContext (user actions, inspector) are stored, periodic scans are not.
        let runner = RecordingCommandRunner(base: ProcessCommandRunner(), recorder: commandHistory)
        self.launchctl = launchctl ?? LaunchctlService(runner: runner)
        self.plistService = plistService ?? PlistService(runner: runner)
        commandHistory.isEnabled = settings.recordsCommandHistory
    }

    var operations: JobOperations {
        var ops = JobOperations(launchctl: launchctl, plist: plistService, backups: BackupService(root: settings.backupURL))
        ops.journal = OperationJournal(recorder: commandHistory)
        return ops
    }

    var previews: CommandPreviewService { CommandPreviewService(backupDirectory: settings.backupURL.path) }

    var scanner: LaunchAgentScanner { LaunchAgentScanner(launchctl: launchctl) }

    var selectedJob: LaunchJob? {
        guard let selectedJobID else { return nil }
        return jobs.first { $0.id == selectedJobID }
    }

    var allLabels: Set<String> { Set(jobs.map(\.label)) }

    func job(withID id: String) -> LaunchJob? { jobs.first { $0.id == id } }

    func isBusy(_ job: LaunchJob) -> Bool { busyJobIDs.contains(job.id) }

    func developerSettingsChanged() {
        commandHistory.isEnabled = settings.recordsCommandHistory
        if !settings.developerMode, section.isDeveloperOnly { section = .dashboard }
    }

    // MARK: Lifecycle

    func start() {
        settings.applyTheme()
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            self?.applyDebugLaunchArguments()
            while !Task.isCancelled {
                let interval = max(5, self?.settings.refreshInterval ?? 15)
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                if self.settings.autoRefresh { await self.refresh(silent: true) }
            }
        }
    }

    /// Debug-only: `-OrbitoSection calendar -OrbitoSelect <label> -OrbitoSheet schedule|edit|raw|new|preview`.
    private func applyDebugLaunchArguments() {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "OrbitoSection"), let value = SidebarSection(rawValue: raw) { section = value }
        if let label = defaults.string(forKey: "OrbitoSelect"), let job = jobs.first(where: { $0.label == label }) {
            selectedJobID = job.id
            switch defaults.string(forKey: "OrbitoSheet") {
            case "schedule": scheduleEditorJob = job
            case "edit": definitionEditorJob = job
            case "raw": rawEditorJob = job
            case "preview": showCommands(.runNow, for: job)
            case "schedulepreview":
                // View-only preview of moving the first calendar entry one hour later.
                var schedule = job.definition.schedule
                if !schedule.calendar.isEmpty { schedule.calendar[0].hour = ((schedule.calendar[0].hour ?? 0) + 1) % 24 }
                let newDict = PlistService.applying(schedule, to: job.raw)
                previewPresentation = PreviewPresentation(preview: previews.previewChange(.editSchedule, job: job, newDict: newDict), mode: .view, job: job)
            default: break
            }
        }
        if defaults.string(forKey: "OrbitoSheet") == "new" { isPresentingNewTask = true }
        #endif
    }

    func refresh(silent: Bool = false) async {
        if isLoading { return }
        if !silent { isLoading = true }
        let result = await scanner.scan(includeSystem: settings.showSystemJobs, metadata: metadata.items)
        detectObservedFailures(in: result.jobs)
        withAnimation(settings.animation) {
            jobs = result.jobs
            scanWarnings = result.warnings
        }
        lastRefresh = .now
        isLoading = false
        hasLoadedOnce = true
        if let selectedJobID, job(withID: selectedJobID) == nil { self.selectedJobID = nil }
    }

    /// Records failures that appear between two refreshes while the app runs.
    private func detectObservedFailures(in newJobs: [LaunchJob]) {
        defer { previousExits = Dictionary(newJobs.map { ($0.id, $0.runtime.lastExit) }, uniquingKeysWith: { a, _ in a }) }
        guard hasLoadedOnce else { return }
        for job in newJobs where job.scope.isEditable {
            let old = previousExits[job.id]
            let new = job.runtime.lastExit
            guard let old, old != new else { continue }
            if new.isFailure {
                history.record(job.label, .observedFailure, .observed, new.description)
                if settings.notifyFailures {
                    NotificationService.notifyFailure(label: job.label, name: job.displayName, detail: "Последний запуск: \(new.description)")
                }
            } else if old.isFailure, case .exitCode(0) = new {
                history.record(job.label, .observedRecovery, .observed, "Последний запуск завершился с кодом 0")
            }
        }
    }

    // MARK: Navigation

    func open(_ job: LaunchJob) {
        if !section.isTaskList { section = .all }
        selectedJobID = job.id
    }

    func showBanner(_ style: Banner.Style, _ title: String, _ details: [String] = []) {
        withAnimation(settings.reduceMotion ? nil : .spring(duration: 0.35)) {
            banner = Banner(style: style, title: title, details: details)
        }
    }

    // MARK: Preview / Dry Run gate

    /// Shows the exact Terminal commands for an action without running anything.
    func showCommands(_ action: CLIAction, for job: LaunchJob) {
        previewPresentation = PreviewPresentation(preview: previews.preview(action, for: job), mode: .view, job: job)
    }

    /// Routes every state-changing action through Dry Run, Command Preview or a confirmation.
    func gate(_ preview: CommandPreview, job: LaunchJob?, confirmation: PendingConfirmation?, execute: @escaping @MainActor () async -> Void) {
        let execute = dryRunGuarded(preview, execute)
        if settings.isDryRun {
            recordDryRun(preview)
            previewPresentation = PreviewPresentation(preview: preview, mode: .dryRun, job: job)
        } else if settings.showsPreviewBeforeChanges || (confirmation == nil && preview.requiresConfirmation) {
            previewPresentation = PreviewPresentation(preview: preview, mode: .confirm(execute), job: job)
        } else if var confirmation {
            confirmation.action = execute
            self.confirmation = confirmation
        } else {
            Task { await execute() }
        }
    }

    /// Same gate for editor sheets: the preview is shown on top of the editor via `present`.
    func gateEditor(_ preview: CommandPreview, job: LaunchJob?, present: (PreviewPresentation) -> Void, dryRunDone: () -> Void, execute: @escaping @MainActor () async -> Void) {
        let execute = dryRunGuarded(preview, execute)
        if settings.isDryRun {
            recordDryRun(preview)
            dryRunDone()
        } else if settings.showsPreviewBeforeChanges || preview.requiresConfirmation {
            // Saving a job whose process is running restarts it: always confirm.
            present(PreviewPresentation(preview: preview, mode: .confirm(execute), job: job))
        } else {
            Task { await execute() }
        }
    }

    /// Dry Run: store the CLI equivalent in Command History, change nothing.
    func recordDryRun(_ preview: CommandPreview) {
        commandHistory.append(CommandRecord(kind: .cliEquivalent, label: preview.label, action: "Dry Run: " + preview.title, command: preview.script, exitCode: nil))
        history.record(preview.label ?? "—", .dryRun, .observed, "Dry Run: \(preview.title). Ничего не изменено.")
        showBanner(.info, "Dry Run: ничего не изменено", [commandHistory.isEnabled
            ? "CLI-эквивалент «\(preview.title)» записан в Историю команд."
            : "Запись истории команд выключена — эквивалент не сохранён."])
    }

    /// Wraps an action so that it re-checks Dry Run at the moment it would run
    /// (a confirmation may stay open while Dry Run is switched on elsewhere).
    private func dryRunGuarded(_ preview: CommandPreview, _ execute: @escaping @MainActor () async -> Void) -> @MainActor () async -> Void {
        { [weak self] in
            guard let self else { return }
            if self.settings.isDryRun {
                self.recordDryRun(preview)
                return
            }
            await execute()
        }
    }

    /// Last line of defence: no state-changing operation runs in Dry Run, whatever the entry point.
    private func refuseInDryRun() -> Bool {
        guard settings.isDryRun else { return false }
        showBanner(.info, "Dry Run включён", ["Операция не выполнена. Выключите Dry Run в настройках Developer."])
        return true
    }

    // MARK: Actions

    /// Runs `body` for a job with busy state, command context, banner, history and refresh.
    func perform(
        _ job: LaunchJob,
        kind: HistoryEvent.Kind,
        success: String,
        _ body: @escaping () async throws -> OperationReport?
    ) async {
        if refuseInDryRun() { return }
        // One operation per job at a time; concurrent writes could interleave.
        guard !busyJobIDs.contains(job.id) else {
            showBanner(.info, "Операция уже выполняется", ["Дождитесь завершения предыдущего действия с «\(job.displayName)»."])
            return
        }
        busyJobIDs.insert(job.id)
        defer { busyJobIDs.remove(job.id) }
        do {
            let report = try await CommandContext.$current.withValue(.init(label: job.label, action: kind.title)) {
                try await body()
            }
            let partial = report?.status == .partial
            history.record(job.label, kind, partial ? .failure : .success, report?.details.joined(separator: "\n") ?? success)
            showBanner(partial ? .warning : .success, report?.title ?? success, report?.details ?? [])
        } catch {
            history.record(job.label, kind, .failure, error.localizedDescription)
            showBanner(.error, "Операция не выполнена", [error.localizedDescription])
        }
        await refresh(silent: true)
    }

    func runNow(_ job: LaunchJob) {
        guard job.scope.isEditable else {
            showBanner(.error, "Системное задание", ["Orbito не запускает системные службы. Используйте launchctl с правами администратора, если это действительно нужно."])
            return
        }
        guard job.runtime.loaded != .no else {
            confirmation = PendingConfirmation(
                title: "Задание не загружено",
                message: "«\(job.displayName)» не загружено в launchd, поэтому его нельзя запустить через kickstart. Загрузить задание сейчас? Если у него RunAtLoad = true, оно запустится сразу.",
                confirmTitle: "Загрузить", isDestructive: false
            ) { [weak self] in self?.load(job) }
            return
        }
        let kill = job.runtime.pid != nil
        let preview = previews.preview(.runNow, for: job, killRunning: kill)
        let confirmation: PendingConfirmation? = kill
            ? PendingConfirmation(title: "Задание уже выполняется", message: "Процесс PID \(job.runtime.pid!) ещё работает. Перезапустить его (kickstart -k)?", confirmTitle: "Перезапустить", isDestructive: true) {}
            : (settings.confirmRunNow ? PendingConfirmation(title: "Запустить «\(job.displayName)»?", message: Workspace.shellCommand(job.definition.argv), confirmTitle: "Запустить", isDestructive: false) {} : nil)
        gate(preview, job: job, confirmation: confirmation) { [weak self] in
            guard let self else { return }
            await self.perform(job, kind: .runNow, success: "Задание запущено") {
                try await self.operations.runNow(job, killRunning: kill)
                return OperationReport(title: "«\(job.displayName)» запущено", details: preview.steps.map(\.command))
            }
        }
    }

    func stop(_ job: LaunchJob) {
        let preview = previews.preview(.stop, for: job)
        gate(preview, job: job, confirmation: PendingConfirmation(
            title: "Остановить «\(job.displayName)»?",
            message: "Процессу PID \(job.runtime.pid ?? 0) будет отправлен SIGTERM." + (job.definition.keepAlive.isActive ? " Из-за KeepAlive launchd запустит его снова." : ""),
            confirmTitle: "Остановить", isDestructive: true) {}) { [weak self] in
            guard let self else { return }
            await self.perform(job, kind: .stop, success: "Сигнал остановки отправлен") {
                try await self.operations.stop(job)
                return nil
            }
        }
    }

    func load(_ job: LaunchJob) {
        gate(previews.preview(.load, for: job), job: job, confirmation: nil) { [weak self] in
            guard let self else { return }
            await self.perform(job, kind: .load, success: "Задание загружено") {
                try await self.operations.load(job)
                return nil
            }
        }
    }

    func unload(_ job: LaunchJob) {
        gate(previews.preview(.unload, for: job), job: job, confirmation: PendingConfirmation(
            title: "Выгрузить «\(job.displayName)»?",
            message: "Задание будет удалено из launchd до следующей загрузки или входа в систему. Работающий процесс будет остановлен.",
            confirmTitle: "Выгрузить", isDestructive: true) {}) { [weak self] in
            guard let self else { return }
            await self.perform(job, kind: .unload, success: "Задание выгружено") {
                try await self.operations.unload(job)
                return nil
            }
        }
    }

    func reload(_ job: LaunchJob) {
        let confirmation: PendingConfirmation? = job.runtime.pid != nil
            ? PendingConfirmation(title: "Перезагрузить «\(job.displayName)»?", message: "Процесс сейчас выполняется (PID \(job.runtime.pid!)). Перезагрузка (bootout + bootstrap) остановит его.", confirmTitle: "Перезагрузить", isDestructive: true) {}
            : nil
        gate(previews.preview(.reload, for: job), job: job, confirmation: confirmation) { [weak self] in
            guard let self else { return }
            await self.perform(job, kind: .reload, success: "Задание перезагружено") {
                try await self.operations.reload(job)
                return nil
            }
        }
    }

    func setDisabled(_ job: LaunchJob, disabled: Bool) {
        if disabled {
            gate(previews.preview(.disable, for: job), job: job, confirmation: PendingConfirmation(
                title: "Отключить «\(job.displayName)»?",
                message: "Задание будет помечено как disabled в базе launchd (сохраняется после перезагрузки Mac) и выгружено. Файл plist не изменяется.",
                confirmTitle: "Отключить", isDestructive: true) {}) { [weak self] in
                guard let self else { return }
                await self.perform(job, kind: .disable, success: "Задание отключено") {
                    try await self.operations.disable(job, unloadNow: true)
                    return nil
                }
            }
        } else {
            gate(previews.preview(.enable, for: job), job: job, confirmation: nil) { [weak self] in
                guard let self else { return }
                await self.perform(job, kind: .enable, success: "Задание включено и загружено") {
                    try await self.operations.enable(job, loadAfter: true)
                    return nil
                }
            }
        }
    }

    func delete(_ job: LaunchJob) {
        gate(previews.preview(.delete, for: job), job: job, confirmation: PendingConfirmation(
            title: "Удалить «\(job.displayName)»?",
            message: "Задание будет выгружено из launchd, а файл \(job.plistURL.lastPathComponent) перемещён в Корзину. Резервная копия сохранится в каталоге бэкапов.",
            confirmTitle: "Удалить", isDestructive: true) {}) { [weak self] in
            guard let self else { return }
            await self.perform(job, kind: .deleted, success: "Задание удалено") {
                try await self.operations.delete(job)
            }
            if self.selectedJobID == job.id { self.selectedJobID = nil }
        }
    }

    func saveSchedule(_ schedule: JobSchedule, for job: LaunchJob) async -> Bool {
        var succeeded = false
        await perform(job, kind: .scheduleChanged, success: "Расписание сохранено") {
            let report = try await self.operations.saveSchedule(schedule, for: job)
            succeeded = true
            return report
        }
        return succeeded
    }

    func saveDefinition(_ dict: [String: PlistValue], for job: LaunchJob, metadata newMetadata: JobMetadata?, kind: HistoryEvent.Kind = .edited) async -> Bool {
        var succeeded = false
        if let newMetadata {
            metadata.update(job.label) { $0.displayName = newMetadata.displayName; $0.notes = newMetadata.notes }
        }
        await perform(job, kind: kind, success: "Задание сохранено") {
            let report = try await self.operations.saveDefinition(dict, for: job)
            succeeded = true
            return report
        }
        return succeeded
    }

    func create(dict: [String: PlistValue], metadata newMetadata: JobMetadata, load: Bool) async throws -> OperationReport {
        guard !settings.isDryRun else { throw OrbitoError.processFailed("Dry Run включён — задание не создано.") }
        let label = dict["Label"]?.stringValue ?? ""
        do {
            let report = try await CommandContext.$current.withValue(.init(label: label, action: "Создание")) {
                try await operations.create(dict: dict, existingLabels: allLabels, load: load)
            }
            metadata.update(label) { $0.displayName = newMetadata.displayName; $0.notes = newMetadata.notes }
            let partial = report.status == .partial
            history.record(label, .created, partial ? .failure : .success, report.details.joined(separator: "\n"))
            showBanner(partial ? .warning : .success, report.title, report.details)
            await refresh(silent: true)
            if let job = jobs.first(where: { $0.label == label && $0.scope == .userAgent }) { open(job) }
            return report
        } catch {
            history.record(label, .created, .failure, error.localizedDescription)
            throw error
        }
    }

    func duplicate(_ job: LaunchJob, as newLabel: String) async throws {
        guard !settings.isDryRun else { throw OrbitoError.processFailed("Dry Run включён — копия не создана.") }
        let report = try await CommandContext.$current.withValue(.init(label: newLabel, action: "Дублирование")) {
            try await operations.duplicate(job, newLabel: newLabel, existingLabels: allLabels)
        }
        metadata.update(newLabel) { $0.displayName = job.displayName + " (копия)"; $0.notes = job.metadata.notes }
        history.record(newLabel, .duplicated, .success, "Копия \(job.label)")
        showBanner(.success, report.title, report.details + ["Копия не загружена в launchd, чтобы задание не выполнялось дважды."])
        await refresh(silent: true)
    }

    /// Import goes through the same gate as other changes (Dry Run / preview).
    func requestImport(from url: URL) {
        do {
            let (dict, _) = try PlistService.read(url)
            guard let label = dict["Label"]?.stringValue else {
                throw OrbitoError.invalidPlist(path: url.path, reason: "нет ключа Label")
            }
            var preview = previews.previewCreate(dict: dict, label: label, load: false)
            preview.title = "Импорт plist"
            gate(preview, job: nil, confirmation: nil) { [weak self] in await self?.importPlist(from: url) }
        } catch {
            showBanner(.error, "Импорт не выполнен", [error.localizedDescription])
        }
    }

    func importPlist(from url: URL) async {
        if refuseInDryRun() { return }
        do {
            let report = try await CommandContext.$current.withValue(.init(label: nil, action: "Импорт")) {
                try await operations.importPlist(from: url, existingLabels: allLabels, load: false)
            }
            history.record(url.deletingPathExtension().lastPathComponent, .imported, .success, report.details.joined(separator: "\n"))
            showBanner(.success, report.title, report.details + ["Импортированное задание не загружено. Проверьте его и загрузите вручную."])
        } catch {
            showBanner(.error, "Импорт не выполнен", [error.localizedDescription])
        }
        await refresh(silent: true)
    }

    func toggleFavorite(_ job: LaunchJob) {
        metadata.update(job.label) { $0.isFavorite.toggle() }
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].metadata = metadata.metadata(for: job.label)
        }
    }

    func serviceDetails(for job: LaunchJob) async -> ServiceDetails? {
        try? await launchctl.serviceDetails(job.label, in: job.runtime.domain)
    }

    /// Read-only launchctl calls for the CLI Inspector (recorded in Command History).
    func inspect(_ arguments: [String]) async -> CommandResult {
        let runner = RecordingCommandRunner(base: ProcessCommandRunner(), recorder: commandHistory)
        do {
            return try await CommandContext.$current.withValue(.init(label: nil, action: "CLI Inspector")) {
                try await runner.run(LaunchctlService.executable, arguments: arguments)
            }
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
    }

    // MARK: Derived data

    func nextRun(for job: LaunchJob, after date: Date = .now) -> Date? {
        guard job.isDisabled != .yes, job.loadError == nil else { return nil }
        return scheduleService.nextRun(of: job.definition.schedule, after: date)
    }

    var favorites: [LaunchJob] { jobs.filter(\.metadata.isFavorite) }
}
