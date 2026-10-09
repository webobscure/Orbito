import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Основные", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Внешний вид", systemImage: "paintbrush") }
            TaskSettings()
                .tabItem { Label("Задания", systemImage: "list.bullet.rectangle") }
            DeveloperSettings()
                .tabItem { Label("Developer", systemImage: "terminal") }
            ConnectionSettings()
                .tabItem { Label("Подключения", systemImage: "network") }
        }
        .frame(minHeight: 460)
        .navigationTitle("Настройки")
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var appState
    @State private var loginItemEnabled = LoginItemService.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Запуск") {
                Toggle("Запускать Orbito при входе в систему", isOn: $loginItemEnabled)
                    .onChange(of: loginItemEnabled) { _, enabled in
                        do {
                            try LoginItemService.setEnabled(enabled)
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                            loginItemEnabled = LoginItemService.isEnabled
                        }
                    }
                Text(LoginItemService.statusDescription).font(.caption).foregroundStyle(.secondary)
                if let loginItemError { MessageRow(text: loginItemError, severity: .error) }
            }
            Section("Обновление") {
                Toggle("Автоматически обновлять список", isOn: $settings.autoRefresh)
                Picker("Интервал", selection: $settings.refreshInterval) {
                    ForEach([5, 10, 15, 30, 60, 300], id: \.self) { value in
                        Text(value < 60 ? "\(value) с" : "\(value / 60) мин").tag(value)
                    }
                }
                .disabled(!settings.autoRefresh)
                Text("Обновление работает, пока Orbito открыт. Фонового мониторинга после выхода из приложения нет.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Уведомления") {
                Toggle("Уведомлять о замеченных ошибках", isOn: $settings.notifyFailures)
                    .onChange(of: settings.notifyFailures) { _, enabled in
                        if enabled { Task { _ = await NotificationService.requestAuthorization() } }
                    }
                Text("Только об ошибках, которые Orbito увидел сам во время работы.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Тема") {
                Picker("Оформление", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Эффекты") {
                Toggle("Уменьшить анимацию", isOn: $settings.reduceMotion)
                Toggle("Уменьшить прозрачность", isOn: $settings.reduceTransparency)
                Text("Прозрачность Liquid Glass также следует системной настройке «Универсальный доступ → Дисплей → Уменьшить прозрачность».")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TaskSettings: View {
    @Environment(AppState.self) private var appState
    @State private var pickingBackupDir = false
    @State private var pickingLogDir = false

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Задания") {
                Toggle("Показывать системные задания", isOn: $settings.showSystemJobs)
                    .onChange(of: settings.showSystemJobs) { Task { await appState.refresh() } }
                Text("/Library/LaunchAgents и /Library/LaunchDaemons — только для чтения.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Каталог логов по умолчанию") {
                pathRow(settings.defaultLogDirectory)
                HStack {
                    Button("Изменить…") { pickingLogDir = true }
                    Button("По умолчанию") { settings.defaultLogDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Orbito").path }
                }
                .fileImporter(isPresented: $pickingLogDir, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { settings.defaultLogDirectory = url.path }
                }
            }
            Section("Резервные копии") {
                pathRow(settings.backupPath)
                HStack {
                    Button("Изменить…") { pickingBackupDir = true }
                    Button("По умолчанию") { settings.backupPath = BackupService.defaultRoot.path }
                    Spacer()
                    Button("Открыть в Finder") {
                        try? FileManager.default.createDirectory(at: settings.backupURL, withIntermediateDirectories: true)
                        Workspace.open(settings.backupURL)
                    }
                }
                .fileImporter(isPresented: $pickingBackupDir, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { settings.backupPath = url.path }
                }
            }
            Section("Подтверждения") {
                Toggle("Подтверждать «Запустить сейчас»", isOn: $settings.confirmRunNow)
                Text("Выгрузка, отключение, удаление и перезапуск работающего процесса всегда требуют подтверждения.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Просмотр логов") {
                Picker("Строк по умолчанию", selection: $settings.logLineCount) {
                    ForEach([100, 500, 1000, 5000, 20000], id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section("Данные") {
                Button("Импортировать plist…") { FilePanels.importPlist(appState) }
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(_ path: String) -> some View {
        Text(path)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

private struct DeveloperSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section {
                Toggle(isOn: $settings.developerMode.animation()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Developer Mode").font(.headline)
                        Text("CLI-подсказки, предпросмотр команд, сырой plist, diff, история команд и CLI Inspector.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: settings.developerMode) { appState.developerSettingsChanged() }
            }
            Section("Инструменты") {
                Toggle("CLI-подсказки при наведении", isOn: $settings.cliTooltips)
                Picker("Платформа по умолчанию", selection: $settings.defaultCLIPlatform) {
                    ForEach(CLIPlatform.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Предпросмотр команд перед изменениями", isOn: $settings.previewBeforeChanges)
                Toggle("Dry Run — ничего не выполнять, только показывать", isOn: $settings.dryRun)
                Toggle("Расширенные логи (диагностика launchd, экспорт)", isOn: $settings.advancedLogs)
                Toggle("Записывать историю команд", isOn: $settings.commandHistory)
                    .onChange(of: settings.commandHistory) { appState.developerSettingsChanged() }
            }
            .disabled(!settings.developerMode)
            Section {
                Label("Вкладка Linux в подсказках — справочник (Reference Only). Orbito не выполняет Linux-команды и не управляет Linux-системами.", systemImage: "book.closed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.isDryRun {
                    MessageRow(text: "Dry Run включён: изменения не будут применяться, пока вы его не выключите.", severity: .warning)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionSettings: View {
    var body: some View {
        Form {
            Section("Локальное подключение") {
                LabeledContent("Этот Mac", value: Host.current().localizedName ?? "—")
                LabeledContent("Домен launchd", value: LaunchDomain.currentGUI.target)
            }
            Section("SSH") {
                LabeledContent("Удалённые подключения", value: "Coming Later")
                Text("Управление удалёнными машинами не реализовано. Архитектурные заметки: docs/architecture/remote-connections.md.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
