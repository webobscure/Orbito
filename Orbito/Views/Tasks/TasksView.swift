import SwiftUI

struct TasksView: View {
    var section: SidebarSection
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var list = appState.taskList
        let jobs = list.visibleJobs(appState.jobs, section: section) { appState.nextRun(for: $0) }

        HSplitView {
            TaskListView(jobs: jobs, section: section)
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)

            Group {
                if let job = appState.selectedJob {
                    TaskDetailView(job: job)
                        .id(job.id)
                        .transition(.opacity)
                } else {
                    EmptyStateView(
                        title: "Выберите задание",
                        message: "Слева — задания из ~/Library/LaunchAgents. Выберите одно, чтобы увидеть расписание, состояние и логи.",
                        symbol: "sidebar.left"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AmbientBackground())
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(section.title)
        .navigationSubtitle("\(jobs.count) из \(appState.jobs.count)")
        .searchable(text: $list.searchText, placement: .toolbar, prompt: "Label, название, путь, аргументы")
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var list = appState.taskList
        ToolbarItemGroup(placement: .automatic) {
            Menu {
                Picker("Фильтр", selection: $list.filter) {
                    ForEach(TaskFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                if appState.settings.showSystemJobs {
                    Picker("Каталог", selection: $list.scopeFilter) {
                        Text("Все каталоги").tag(JobScope?.none)
                        ForEach(JobScope.allCases, id: \.self) { Text($0.title).tag(JobScope?.some($0)) }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label("Фильтр", systemImage: list.filter == .all && list.scopeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Фильтр")

            Menu {
                Picker("Сортировка", selection: $list.sort) {
                    ForEach(TaskSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Сортировка", systemImage: "arrow.up.arrow.down")
            }
            .help("Сортировка")

            Button {
                Task { await appState.refresh() }
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .help("Обновить (⌘R)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                appState.isPresentingNewTask = true
            } label: {
                Label("Новое задание", systemImage: "plus")
            }
            .help("Новое задание (⌘N)")
        }
    }
}

struct TaskListView: View {
    var jobs: [LaunchJob]
    var section: SidebarSection
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var appState = appState

        Group {
            if !appState.hasLoadedOnce {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Сканирование LaunchAgents…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if jobs.isEmpty {
                emptyState
            } else {
                List(selection: $appState.selectedJobID) {
                    ForEach(jobs) { job in
                        TaskRow(job: job, nextRun: appState.nextRun(for: job), isBusy: appState.isBusy(job))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("task.\(job.label)")
                            .tag(job.id)
                            .contextMenu { TaskContextMenu(job: job, openWindow: openWindow) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .animation(.smooth, value: jobs.map(\.id))
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var emptyState: some View {
        if appState.taskList.isFiltering {
            EmptyStateView(title: "Ничего не найдено", message: "Измените запрос или сбросьте фильтры.", symbol: "magnifyingglass", actionTitle: "Сбросить фильтры") {
                appState.taskList.reset()
            }
        } else if section == .errors {
            EmptyStateView(title: "Ошибок нет", message: "Orbito не обнаружил проблем в ваших заданиях.", symbol: "checkmark.seal")
        } else if section == .disabled {
            EmptyStateView(title: "Нет отключённых заданий", message: "Отключённые через launchctl задания появятся здесь.", symbol: "pause.circle")
        } else {
            EmptyStateView(title: "Заданий пока нет", message: "В ~/Library/LaunchAgents нет plist-файлов. Создайте первое задание.", symbol: "tray", actionTitle: "Новое задание") {
                appState.isPresentingNewTask = true
            }
        }
    }
}

struct TaskRow: View {
    var job: LaunchJob
    var nextRun: Date?
    var isBusy: Bool

    var body: some View {
        let health = JobHealth(job: job)
        HStack(spacing: 12) {
            JobIcon(job: job)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if job.metadata.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if !job.scope.isEditable {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .help("Только чтение")
                    }
                }
                Text(job.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.caption2)
                    Text(ScheduleFormatter.describe(job.definition))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    StatusBadge(health: health, compact: false)
                }
                if let nextRun {
                    Text(ScheduleFormatter.relativeDay(nextRun))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Right-click menu shared by the list and the detail view.
struct TaskContextMenu: View {
    var job: LaunchJob
    var openWindow: OpenWindowAction
    @Environment(AppState.self) private var appState

    var body: some View {
        Button("Запустить сейчас", systemImage: "play.fill") { appState.runNow(job) }
            .disabled(!job.scope.isEditable)
        if job.isEditable {
            Button("Изменить расписание…", systemImage: "clock") { appState.scheduleEditorJob = job }
            Button("Редактировать…", systemImage: "pencil") { appState.definitionEditorJob = job }
            Divider()
            if job.runtime.loaded == .yes {
                Button("Перезагрузить", systemImage: "arrow.clockwise") { appState.reload(job) }
                Button("Выгрузить", systemImage: "eject") { appState.unload(job) }
            } else {
                Button("Загрузить", systemImage: "arrow.down.circle") { appState.load(job) }
            }
            if job.isDisabled == .yes {
                Button("Включить", systemImage: "power") { appState.setDisabled(job, disabled: false) }
            } else {
                Button("Отключить", systemImage: "pause") { appState.setDisabled(job, disabled: true) }
            }
        }
        Divider()
        Button(job.metadata.isFavorite ? "Убрать из избранного" : "В избранное", systemImage: job.metadata.isFavorite ? "star.slash" : "star") {
            appState.toggleFavorite(job)
        }
        if job.runtime.pid != nil, job.scope.isEditable {
            Button("Остановить процесс", systemImage: "stop.fill") { appState.stop(job) }
        }
        Button("Открыть логи", systemImage: "doc.text.magnifyingglass") { openWindow(id: "logs", value: job.id) }
        Button("Открыть plist…", systemImage: "chevron.left.forwardslash.chevron.right") { appState.rawEditorJob = job }
            .disabled(job.loadError != nil)
        if appState.settings.developerMode {
            Button("Терминальные команды…", systemImage: "terminal") { appState.showCommands(.inspect, for: job) }
        }
        Button("Копировать команду", systemImage: "doc.on.doc") { Workspace.copy(Workspace.shellCommand(job.definition.argv)) }
        Button("Копировать Label", systemImage: "tag") { Workspace.copy(job.label) }
        Button("Показать в Finder", systemImage: "folder") { Workspace.reveal(job.plistURL) }
        Button("Экспортировать plist…", systemImage: "square.and.arrow.up") { FilePanels.exportPlist(job) }
        if job.loadError == nil {
            Button("Дублировать…", systemImage: "plus.square.on.square") { appState.duplicateJob = job }
        }
        if job.scope.isEditable {
            Divider()
            Button("Удалить…", systemImage: "trash", role: .destructive) { appState.delete(job) }
        }
    }
}
