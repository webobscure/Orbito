import SwiftUI

@main
struct OrbitoApp: App {
    @State private var appState = AppState()

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        Window("Orbito", id: "main") {
            RootView()
                .environment(appState)
                .frame(minWidth: 1040, minHeight: 640)
                .task {
                    guard !isRunningTests else { return }
                    appState.start()
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        // The menu-bar extra keeps the app alive without windows; always show the main window on launch.
        .defaultLaunchBehavior(.presented)
        .commands { OrbitoCommands(appState: appState) }

        WindowGroup("Логи", id: "logs", for: String.self) { $jobID in
            LogWindowRoot(jobID: jobID)
                .environment(appState)
        }
        .defaultSize(width: 860, height: 600)

        Settings {
            SettingsView()
                .environment(appState)
                .frame(width: 620)
        }

        MenuBarExtra("Orbito", systemImage: "clock.arrow.2.circlepath") {
            MenuBarContent()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

struct OrbitoCommands: Commands {
    var appState: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Новое задание…") { appState.isPresentingNewTask = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("Импортировать plist…") { FilePanels.importPlist(appState) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Задание") {
            Button("Обновить список") { Task { await appState.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Запустить сейчас") { if let job = appState.selectedJob { appState.runNow(job) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(appState.selectedJob == nil)
            Button("Изменить расписание…") { appState.scheduleEditorJob = appState.selectedJob }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(appState.selectedJob?.isEditable != true)
            Button("Перезагрузить") { if let job = appState.selectedJob { appState.reload(job) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(appState.selectedJob?.isEditable != true || appState.selectedJob?.runtime.loaded != .yes)
            Button("Показать в Finder") { if let job = appState.selectedJob { Workspace.reveal(job.plistURL) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(appState.selectedJob == nil)
            Button("Открыть plist…") { appState.rawEditorJob = appState.selectedJob }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(appState.selectedJob?.loadError != nil || appState.selectedJob == nil)
        }
        CommandMenu("Developer") {
            Toggle("Developer Mode", isOn: Binding(
                get: { appState.settings.developerMode },
                set: { appState.settings.developerMode = $0; appState.developerSettingsChanged() }
            ))
            .keyboardShortcut("d", modifiers: [.command, .option])
            Toggle("Dry Run", isOn: Binding(get: { appState.settings.dryRun }, set: { appState.settings.dryRun = $0 }))
                .disabled(!appState.settings.developerMode)
            Divider()
            Button("Терминальные команды…") { if let job = appState.selectedJob { appState.showCommands(.inspect, for: job) } }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!appState.settings.developerMode || appState.selectedJob == nil)
            Button("История команд") { appState.section = .commandHistory }
                .disabled(!appState.settings.developerMode)
            Button("CLI Inspector") { appState.section = .cliInspector }
                .disabled(!appState.settings.developerMode)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(SidebarSection.allCases.filter { !$0.isDeveloperOnly }.prefix(9).enumerated()), id: \.element) { index, section in
                Button(section.title) { appState.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}

/// Resolves the job for a log window by its id (plist path).
struct LogWindowRoot: View {
    var jobID: String?
    @Environment(AppState.self) private var appState

    var body: some View {
        if let jobID, let job = appState.job(withID: jobID) {
            LogViewerView(job: job)
                .navigationTitle("Логи — \(job.displayName)")
        } else {
            EmptyStateView(title: "Задание не найдено", message: "Возможно, оно было удалено.", symbol: "doc.questionmark")
                .task { if !appState.hasLoadedOnce { await appState.refresh() } }
        }
    }
}
