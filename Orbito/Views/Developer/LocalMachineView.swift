import SwiftUI

/// Connections → this Mac. Remote connections are documented as future work only.
struct LocalMachineView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let tools = [("launchctl", "/bin/launchctl"), ("plutil", "/usr/bin/plutil")]
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.2)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Host.current().localizedName ?? "Этот Mac").font(.largeTitle.weight(.bold))
                        Text("Локальное подключение · launchd").foregroundStyle(.secondary)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader("Система", symbol: "apple.logo")
                        KeyValueRow(key: "macOS", value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
                        KeyValueRow(key: "Пользователь", value: "\(NSUserName()) (uid \(getuid()))", monospaced: true)
                        KeyValueRow(key: "GUI-домен", value: LaunchDomain.currentGUI.target, monospaced: true)
                        KeyValueRow(key: "Пользовательские агенты", value: JobScope.userAgent.directory.path, monospaced: true)
                        KeyValueRow(key: "Резервные копии", value: appState.settings.backupURL.path, monospaced: true)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader("Инструменты", symbol: "wrench.and.screwdriver", tint: .purple)
                        ForEach(tools, id: \.0) { name, path in
                            HStack {
                                let ok = FileManager.default.isExecutableFile(atPath: path)
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? .green : .red)
                                Text(name).font(.callout.monospaced())
                                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Text("Возможности: просмотр всех агентов и демонов; изменение, запуск и удаление — только для ~/Library/LaunchAgents. Системные задания доступны только для чтения.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader("Удалённые подключения", symbol: "network", tint: .gray)
                        HStack {
                            Button {} label: { Label("Добавить SSH-подключение", systemImage: "plus") }
                                .buttonStyle(.glass)
                                .disabled(true)
                            Text("Coming Later").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        Text("Управление удалёнными машинами не реализовано. Архитектурные заметки — в docs/architecture/remote-connections.md.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .navigationTitle("Этот Mac")
    }
}
