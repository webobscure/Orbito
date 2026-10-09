import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
                .animation(appState.settings.animation, value: appState.section)
        }
        .overlay(alignment: .top) {
            if let banner = appState.banner {
                BannerView(banner: banner) {
                    withAnimation(.snappy) { appState.banner = nil }
                }
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: banner.id) {
                    guard banner.style == .success || banner.style == .info else { return }
                    try? await Task.sleep(for: .seconds(6))
                    withAnimation(.snappy) { if appState.banner?.id == banner.id { appState.banner = nil } }
                }
            }
        }
        .sheet(isPresented: $appState.isPresentingNewTask) {
            NewTaskWizard(existingLabels: appState.allLabels)
        }
        .sheet(item: $appState.scheduleEditorJob) { job in
            ScheduleEditorSheet(job: job)
        }
        .sheet(item: $appState.definitionEditorJob) { job in
            TaskEditorSheet(job: job)
        }
        .sheet(item: $appState.duplicateJob) { job in
            DuplicateSheet(job: job)
        }
        .sheet(item: $appState.rawEditorJob) { job in
            RawPlistEditorSheet(job: job)
        }
        .sheet(item: $appState.previewPresentation) { presentation in
            CommandPreviewSheet(presentation: presentation)
        }
        .alert(
            appState.confirmation?.title ?? "",
            isPresented: Binding(get: { appState.confirmation != nil }, set: { if !$0 { appState.confirmation = nil } }),
            presenting: appState.confirmation
        ) { pending in
            Button(pending.confirmTitle, role: pending.isDestructive ? .destructive : nil) {
                Task { await pending.action() }
            }
            Button("Отмена", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.section {
        case .dashboard:
            DashboardView()
        case .all, .active, .disabled, .errors:
            TasksView(section: appState.section)
        case .calendar:
            CalendarScreen()
        case .activity:
            HistoryView()
        case .commandHistory:
            CommandHistoryView()
        case .cliInspector:
            CLIInspectorView()
        case .localMachine:
            LocalMachineView()
        case .settings:
            SettingsView()
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AmbientBackground())
        }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let jobs = appState.jobs

        List(selection: Binding(get: { appState.section }, set: { if let value = $0 { appState.section = value } })) {
            Section("Workspace") {
                row(.dashboard, count: nil)
                row(.all, count: jobs.count)
                row(.calendar, count: nil)
                row(.activity, count: nil)
            }
            Section("Задачи") {
                row(.active, count: jobs.count { TaskListViewModel.sectionMatches(.active, $0) })
                row(.disabled, count: jobs.count { $0.isDisabled == .yes })
                row(.errors, count: jobs.count(where: \.hasErrors), tint: .orange)
            }
            if appState.settings.developerMode {
                Section("Developer") {
                    row(.commandHistory, count: nil)
                    row(.cliInspector, count: nil)
                }
            }
            Section("Подключения") {
                row(.localMachine, count: nil)
                Label("SSH — Coming Later", systemImage: "network")
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
                    .help("Удалённые подключения пока не поддерживаются")
            }
            if !appState.favorites.isEmpty {
                Section("Избранное") {
                    ForEach(appState.favorites) { job in
                        Button {
                            appState.open(job)
                        } label: {
                            HStack {
                                StatusDot(health: JobHealth(job: job))
                                Text(job.displayName).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Система") {
                row(.settings, count: nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private func row(_ section: SidebarSection, count: Int?, tint: Color? = nil) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(count.map { $0 > 0 ? Text("\($0)").foregroundStyle(tint ?? .secondary) : nil } ?? nil)
            .tag(section)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if appState.isLoading {
                ProgressView().controlSize(.small)
                Text("Сканирование…")
            } else if let date = appState.lastRefresh {
                Image(systemName: "checkmark.circle")
                Text("Обновлено \(date.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Не обновлялось")
            }
            Spacer()
            Button {
                Task { await appState.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Обновить (⌘R)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .padding(10)
    }
}
