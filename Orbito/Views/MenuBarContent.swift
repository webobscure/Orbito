import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let favorites = appState.favorites
        let upcoming = DashboardViewModel.upcoming(appState.jobs, service: appState.scheduleService, limit: 4)
        let errors = appState.jobs.filter(\.hasErrors).count

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Orbito").font(.headline)
                Spacer()
                if errors > 0 {
                    Label("\(errors)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption.weight(.semibold))
                }
            }

            if !upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ближайшие запуски").font(.caption).foregroundStyle(.secondary)
                    ForEach(upcoming) { run in
                        HStack {
                            Circle().fill(CalendarViewModel.color(for: run.label)).frame(width: 6, height: 6)
                            Text(run.name).lineLimit(1)
                            Spacer()
                            Text(ScheduleFormatter.relativeDay(run.date)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Избранное").font(.caption).foregroundStyle(.secondary)
                if favorites.isEmpty {
                    Text("Отметьте задания звёздочкой для быстрого запуска.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(favorites) { job in
                    HStack {
                        StatusDot(health: JobHealth(job: job))
                        Text(job.displayName).lineLimit(1)
                        Spacer()
                        Button {
                            // Previews / confirmations need the main window to appear.
                            if appState.settings.developerMode || appState.settings.confirmRunNow || job.runtime.pid != nil {
                                openWindow(id: "main")
                                NSApp.activate()
                            }
                            appState.runNow(job)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(appState.isBusy(job))
                    }
                }
            }

            Divider()
            HStack {
                Button("Открыть Orbito") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button {
                    Task { await appState.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .buttonStyle(.glass)
        }
        .padding(14)
        .frame(width: 320)
        .task { if !appState.hasLoadedOnce { appState.start() } }
    }
}

/// AppKit open/save panels for import and export.
@MainActor
enum FilePanels {
    static func importPlist(_ appState: AppState) {
        let panel = NSOpenPanel()
        panel.title = "Импорт задания launchd"
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.requestImport(from: url)
    }

    static func exportText(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Экспорт"
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(text.utf8).write(to: destination, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func exportPlist(_ job: LaunchJob) {
        let panel = NSSavePanel()
        panel.title = "Экспорт plist"
        panel.nameFieldStringValue = job.plistURL.lastPathComponent
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: job.plistURL)
            try data.write(to: destination, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
