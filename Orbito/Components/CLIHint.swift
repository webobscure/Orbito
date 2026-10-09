import SwiftUI

/// Platform selector shared by CLI tooltips and Command Preview: macOS | Linux (systemd | cron).
struct CLIPlatformPicker: View {
    @Binding var platform: CLIPlatform
    @Binding var scheduler: LinuxScheduler

    var body: some View {
        HStack(spacing: 8) {
            Picker("Платформа", selection: $platform) {
                ForEach(CLIPlatform.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            if platform == .linux {
                Picker("Планировщик", selection: $scheduler) {
                    ForEach(LinuxScheduler.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.snappy, value: platform)
    }
}

/// Linux reference block: clearly labelled, never tied to a task on this Mac.
struct ReferenceEntryView: View {
    var entry: ReferenceEntry
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Reference Only", systemImage: "book.closed")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.14), in: Capsule())
                Text("Пример для Linux. Orbito не выполняет эти команды и не управляет Linux.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.title).font(compact ? .callout.weight(.semibold) : .headline)
            Text(entry.summary).font(.callout).foregroundStyle(.secondary)
            if entry.commands.isEmpty {
                Label("Прямого аналога нет", systemImage: "arrow.triangle.branch")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            ForEach(entry.commands) { command in
                VStack(alignment: .leading, spacing: 3) {
                    CodeBlock(text: command.command, language: .shell)
                    if let note = command.note {
                        Text(note).font(.caption).foregroundStyle(command.isDestructive ? .red : .secondary)
                    }
                }
            }
            if let differences = entry.differences {
                Label {
                    Text(differences).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                }
                .font(.callout)
            }
        }
    }
}

/// Hover popover explaining how to perform an action in Terminal (Developer Mode → CLI Tooltips).
struct CLIHintModifier: ViewModifier {
    var action: CLIAction
    var job: LaunchJob?
    @Environment(AppState.self) private var appState
    @State private var isPresented = false
    @State private var overAnchor = false
    @State private var overPopover = false
    @State private var showTask: Task<Void, Never>?
    /// "Подробнее…" opens here, attached to the anchor, so it also works inside editor sheets.
    @State private var details: PreviewPresentation?

    func body(content: Content) -> some View {
        if appState.settings.showsCLITooltips {
            content
                .onHover { hovering in
                    overAnchor = hovering
                    scheduleUpdate()
                }
                .sheet(item: $details) { CommandPreviewSheet(presentation: $0) }
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    CLIHintContent(action: action, job: job) { presentation in
                        isPresented = false
                        if let presentation { details = presentation }
                    }
                    .onHover { hovering in
                        overPopover = hovering
                        scheduleUpdate()
                    }
                }
        } else {
            content
        }
    }

    /// Opens after a short dwell; stays open while the pointer is over the control or the popover.
    private func scheduleUpdate() {
        showTask?.cancel()
        let wantsOpen = overAnchor || overPopover
        guard wantsOpen != isPresented else { return }
        showTask = Task {
            try? await Task.sleep(for: wantsOpen ? .milliseconds(650) : .milliseconds(350))
            guard !Task.isCancelled else { return }
            if (overAnchor || overPopover) == wantsOpen { isPresented = wantsOpen }
        }
    }
}

extension View {
    /// Attaches a CLI tooltip (only visible with Developer Mode → CLI Tooltips).
    func cliHint(_ action: CLIAction, job: LaunchJob?) -> some View {
        modifier(CLIHintModifier(action: action, job: job))
    }
}

struct CLIHintContent: View {
    var action: CLIAction
    var job: LaunchJob?
    /// Closes the popover, optionally opening the full preview.
    var close: (PreviewPresentation?) -> Void
    @Environment(AppState.self) private var appState
    @State private var platform: CLIPlatform = .macOS
    @State private var scheduler: LinuxScheduler = .systemd

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "terminal").foregroundStyle(.tint)
                Text(action.title).font(.headline)
                Spacer()
                CLIPlatformPicker(platform: $platform, scheduler: $scheduler)
                    .controlSize(.small)
            }
            Text(action.summary).font(.callout).foregroundStyle(.secondary)

            if platform == .macOS {
                if let job {
                    let preview = appState.previews.preview(action, for: job)
                    let steps = preview.steps.prefix(3)
                    ForEach(Array(steps)) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            CodeBlock(text: step.command, language: .shell)
                            Text(step.purpose + (step.condition.map { " (\($0))" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(step.isDestructive ? .red : .secondary)
                        }
                    }
                    if preview.steps.count > 3 {
                        Text("и ещё \(preview.steps.count - 3) шаг(а) — откройте полный предпросмотр.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(preview.warnings.prefix(2), id: \.self) { MessageRow(text: $0, severity: .warning) }
                    HStack {
                        Button("Копировать команды") { Workspace.copy(preview.steps.map(\.command).joined(separator: "\n")) }
                        Spacer()
                        Button("Подробнее…") {
                            close(PreviewPresentation(preview: preview, mode: .view, job: job))
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                } else {
                    let preview = appState.previews.preview(.listTasks, for: LaunchJob.placeholder)
                    ForEach(preview.steps) { CodeBlock(text: $0.command, language: .shell) }
                }
            } else {
                ReferenceEntryView(entry: CLIReferenceService.entry(action, scheduler: scheduler, schedule: job?.definition.schedule), compact: true)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { platform = appState.settings.defaultCLIPlatform }
    }
}

extension LaunchJob {
    /// Used only to render generic commands (e.g. `launchctl list`) that don't depend on a job.
    static let placeholder = LaunchJob(
        label: "com.example.task", plistURL: JobScope.userAgent.directory.appending(path: "com.example.task.plist"),
        scope: .userAgent, format: .xml, raw: [:], definition: JobDefinition(), runtime: RuntimeState(domain: .currentGUI)
    )
}
