import SwiftUI

struct TaskDetailView: View {
    var job: LaunchJob
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var details: ServiceDetails?
    @State private var showRawDetails = false
    @State private var showPlist = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actionBar
                factsRow
                if !job.issues.isEmpty { issuesCard }
                scheduleCard
                commandCard
                logsCard
                fileCard
                runtimeCard
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground(tint: CalendarViewModel.color(for: job.label)))
        .task(id: "\(job.id)-\(job.runtime.pid ?? -1)-\(job.runtime.loaded)") {
            details = job.runtime.loaded == .yes ? await appState.serviceDetails(for: job) : nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            JobIcon(job: job, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(job.displayName)
                        .font(.title.weight(.bold))
                        .lineLimit(1)
                    Button {
                        appState.toggleFavorite(job)
                    } label: {
                        Image(systemName: job.metadata.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(job.metadata.isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(job.metadata.isFavorite ? "Убрать из избранного" : "Добавить в избранное")
                }
                Text(job.label)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let notes = job.metadata.notes, !notes.isEmpty {
                    Text(notes).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusBadge(health: JobHealth(job: job))
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            actionButtons(compact: false)
            actionButtons(compact: true)
        }
        .overlay(alignment: .topTrailing) {
            if appState.isBusy(job) { ProgressView().controlSize(.small).offset(x: 8, y: -8) }
        }
    }

    private func actionButtons(compact: Bool) -> some View {
        let busy = appState.isBusy(job)
        let editable = job.isEditable
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    appState.runNow(job)
                } label: {
                    Label("Запустить", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(busy || !job.scope.isEditable)
                .help("Запустить сейчас (⇧⌘R)")
                .accessibilityIdentifier("detail.run")
                .cliHint(.runNow, job: job)

                if job.runtime.pid != nil, job.scope.isEditable {
                    Button {
                        appState.stop(job)
                    } label: {
                        Label("Остановить", systemImage: "stop.fill")
                    }
                    .buttonStyle(.glass)
                    .disabled(busy)
                    .help("Остановить процесс")
                .accessibilityIdentifier("detail.stop")
                    .cliHint(.stop, job: job)
                }

                Button {
                    appState.scheduleEditorJob = job
                } label: {
                    Label("Расписание", systemImage: "clock")
                }
                .buttonStyle(.glass)
                .disabled(busy || !editable)
                .help("Изменить расписание (⌘E)")
                .accessibilityIdentifier("detail.schedule")
                .cliHint(.editSchedule, job: job)

                if job.runtime.loaded == .yes {
                    Button {
                        appState.reload(job)
                    } label: {
                        Label("Перезагрузить", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .disabled(busy || !editable)
                    .help("Перезагрузить")
                .accessibilityIdentifier("detail.reload")
                    .cliHint(.reload, job: job)
                } else {
                    Button {
                        appState.load(job)
                    } label: {
                        Label("Загрузить", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.glass)
                    .disabled(busy || !editable || job.isDisabled == .yes)
                    .help(job.isDisabled == .yes ? "Сначала включите задание" : "Загрузить в launchd")
                .accessibilityIdentifier("detail.load")
                    .cliHint(.load, job: job)
                }

                Button {
                    appState.setDisabled(job, disabled: job.isDisabled != .yes)
                } label: {
                    Label(job.isDisabled == .yes ? "Включить" : "Отключить", systemImage: job.isDisabled == .yes ? "power" : "pause")
                }
                .buttonStyle(.glass)
                .disabled(busy || !job.scope.isEditable)
                .help(job.isDisabled == .yes ? "Включить" : "Отключить")
                .accessibilityIdentifier("detail.toggleDisabled")
                .cliHint(job.isDisabled == .yes ? .enable : .disable, job: job)

                Button {
                    openWindow(id: "logs", value: job.id)
                } label: {
                    Label("Логи", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.glass)
                .help("Логи")
                .accessibilityIdentifier("detail.logs")
                .cliHint(.viewLogs, job: job)

                Spacer(minLength: 0)

                Menu {
                    TaskContextMenu(job: job, openWindow: openWindow)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
                .accessibilityIdentifier("detail.more")
            }
            .labelStyle(AdaptiveLabelStyle(compact: compact))
            .fixedSize(horizontal: !compact, vertical: false)
        }
    }

    // MARK: Facts

    private var factsRow: some View {
        let fileExists = FileManager.default.fileExists(atPath: job.plistURL.path)
        return GlassEffectContainer(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                FactChip(title: "Файл", value: fileExists ? (job.loadError == nil ? "На диске" : "Повреждён") : "Отсутствует",
                         symbol: "doc", color: fileExists && job.loadError == nil ? .primary : .red)
                FactChip(title: "launchd", value: job.runtime.loaded.text(yes: "Загружено", no: "Не загружено"),
                         symbol: "bolt", color: job.runtime.loaded.color(yes: .green, no: .secondary))
                FactChip(title: "Процесс", value: job.runtime.pid.map { "PID \($0)" } ?? job.runtime.isRunning.text(yes: "Работает", no: "Не запущен"),
                         symbol: "cpu", color: job.runtime.pid != nil ? .blue : .secondary)
                FactChip(title: "Отключение", value: job.isDisabled.text(yes: "Отключено", no: "Включено"),
                         symbol: "power", color: job.isDisabled.color(yes: .gray, no: .primary))
                FactChip(title: "Последний выход", value: job.runtime.loaded == .yes ? job.runtime.lastExit.description : "—",
                         symbol: "flag.checkered", color: job.runtime.lastExit.isFailure ? .orange : .primary)
            }
        }
    }

    private var issuesCard: some View {
        GlassCard(tint: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader("Диагностика", symbol: "stethoscope", tint: .orange)
                ForEach(job.issues) { MessageRow(text: $0.message, severity: $0.severity) }
            }
        }
    }

    // MARK: Schedule

    private var scheduleCard: some View {
        let schedule = job.definition.schedule
        let nextRuns = job.isDisabled == .yes ? [] : appState.scheduleService.nextRuns(of: schedule, after: .now, count: 5)
        return GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("Расписание", symbol: "clock") {
                    if job.isEditable {
                        Button("Изменить расписание") { appState.scheduleEditorJob = job }
                            .buttonStyle(.glass)
                    }
                }
                Text(ScheduleFormatter.describe(job.definition))
                    .font(.title3.weight(.semibold))

                HStack(spacing: 16) {
                    if job.definition.runAtLoad { tag("RunAtLoad", symbol: "power") }
                    if job.definition.keepAlive.isActive { tag(job.definition.keepAlive == .conditional ? "KeepAlive (условия)" : "KeepAlive", symbol: "infinity") }
                    if schedule.calendarIsArray { tag("\(schedule.calendar.count) правил(а)", symbol: "list.bullet") }
                    ForEach(job.definition.otherTriggers, id: \.self) { tag($0, symbol: "bolt.horizontal") }
                }

                if !nextRuns.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Следующие плановые запуски")
                            .font(.subheadline.weight(.semibold))
                        ForEach(nextRuns, id: \.self) { date in
                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundStyle(.secondary)
                                Text(ScheduleFormatter.relativeDay(date))
                                    .monospacedDigit()
                                Spacer()
                                Text(date, style: .relative).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        if job.runtime.loaded != .yes {
                            Text("Задание не загружено в launchd — по расписанию оно не запустится.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Время плановое: launchd не гарантирует запуск в точную секунду; если Mac спал, запуск произойдёт после пробуждения.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let interval = schedule.interval {
                    Text("StartInterval \(interval) с: отсчёт от момента загрузки, точное время следующего запуска неизвестно.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tag(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: Command

    private var commandCard: some View {
        let def = job.definition
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("Команда", symbol: "terminal", tint: .purple) {
                    Button {
                        Workspace.copy(Workspace.shellCommand(def.argv))
                        appState.showBanner(.info, "Команда скопирована")
                    } label: {
                        Label("Копировать", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    if job.isEditable {
                        Button("Редактировать") { appState.definitionEditorJob = job }
                            .buttonStyle(.glass)
                            .cliHint(.editConfiguration, job: job)
                    }
                    if appState.settings.developerMode {
                        Button {
                            appState.showCommands(.inspect, for: job)
                        } label: {
                            Label("Терминальные команды", systemImage: "terminal")
                        }
                        .buttonStyle(.glass)
                    }
                }
                Text(Workspace.shellCommand(def.argv).isEmpty ? "—" : Workspace.shellCommand(def.argv))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let program = def.program { KeyValueRow(key: "Program", value: program, monospaced: true) }
                KeyValueRow(key: "Рабочая директория", value: def.workingDirectory ?? "— (по умолчанию /)", monospaced: true)
                if !def.environment.isEmpty {
                    Text("Переменные окружения").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    ForEach(def.environment.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        KeyValueRow(key: key, value: value, monospaced: true)
                    }
                }
            }
        }
    }

    // MARK: Logs

    private var logsCard: some View {
        let def = job.definition
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("Логи", symbol: "doc.text", tint: .teal) {
                    Button("Открыть просмотр") { openWindow(id: "logs", value: job.id) }
                        .buttonStyle(.glass)
                        .disabled(def.standardOutPath == nil && def.standardErrorPath == nil)
                }
                logPathRow("stdout", def.standardOutPath)
                logPathRow("stderr", def.standardErrorPath)
                if def.standardOutPath == nil && def.standardErrorPath == nil {
                    Text("Пути логов не заданы — вывод задания не сохраняется. Добавьте StandardOutPath/StandardErrorPath в редакторе.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func logPathRow(_ name: String, _ path: String?) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            if let path {
                let exists = FileManager.default.fileExists(atPath: path)
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !exists {
                    Text("нет файла").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    Workspace.reveal(URL(filePath: path))
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .disabled(!exists)
                .help("Показать в Finder")
            } else {
                Text("не задан").foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.callout)
    }

    // MARK: File

    private var fileCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("Файл plist", symbol: "doc.badge.gearshape", tint: .gray) {
                    Button {
                        Workspace.reveal(job.plistURL)
                    } label: {
                        Label("Показать в Finder", systemImage: "folder")
                    }
                    .buttonStyle(.glass)
                    Button(showPlist ? "Скрыть XML" : "Показать XML") {
                        withAnimation(appState.settings.animation) { showPlist.toggle() }
                    }
                    .buttonStyle(.glass)
                    .disabled(job.loadError != nil)
                    if appState.settings.developerMode {
                        Button {
                            appState.rawEditorJob = job
                        } label: {
                            Label("Advanced Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        .buttonStyle(.glass)
                        .disabled(job.loadError != nil)
                        .cliHint(.editConfiguration, job: job)
                    }
                }
                KeyValueRow(key: "Путь", value: job.plistURL.path, monospaced: true, copyable: true)
                KeyValueRow(key: "Каталог", value: job.scope.shortTitle + (job.scope.isEditable ? "" : " · только чтение"))
                KeyValueRow(key: "Домен launchd", value: job.runtime.domain.target, monospaced: true)
                KeyValueRow(key: "Формат", value: job.format.rawValue.uppercased())
                if let modified = job.fileModified {
                    KeyValueRow(key: "Изменён", value: modified.formatted(date: .abbreviated, time: .standard))
                }
                if showPlist {
                    CodeBlock(text: PlistService.xmlString(job.raw), language: .xml, maxHeight: 360)
                }
            }
        }
    }

    // MARK: Runtime

    @ViewBuilder
    private var runtimeCard: some View {
        if let details {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader("Состояние в launchd", symbol: "waveform.path.ecg", tint: .green) {
                        Button(showRawDetails ? "Скрыть вывод" : "launchctl print") {
                            withAnimation(.smooth) { showRawDetails.toggle() }
                        }
                        .buttonStyle(.glass)
                    }
                    if let state = details.state { KeyValueRow(key: "state", value: state, monospaced: true) }
                    if let runs = details.runs { KeyValueRow(key: "Запусков с загрузки", value: "\(runs)") }
                    if let code = details.lastExitCode { KeyValueRow(key: "last exit code", value: code, monospaced: true) }
                    if let reason = details.lastExitReason { KeyValueRow(key: "last exit reason", value: reason, monospaced: true) }
                    Text("launchd хранит только итог последнего запуска с момента загрузки; полной истории запусков он не ведёт.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showRawDetails {
                        ScrollView {
                            Text(details.raw)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(maxHeight: 320)
                        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }
}

/// Title + icon normally; icon only (title moves to tooltip) when space is tight.
struct AdaptiveLabelStyle: LabelStyle {
    var compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            Label(configuration)
        }
    }
}
