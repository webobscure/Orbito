import SwiftUI

/// "View Terminal Commands": what Orbito will do, as a reproducible Terminal sequence,
/// with configuration diffs and a Linux reference tab.
struct CommandPreviewSheet: View {
    var presentation: PreviewPresentation
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var platform: CLIPlatform = .macOS
    @State private var scheduler: LinuxScheduler = .systemd
    @State private var isRunning = false

    private var preview: CommandPreview { presentation.preview }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if case .dryRun = presentation.mode {
                        MessageRow(text: "Dry Run: ничего не выполнено и не изменено. Команды записаны в Историю команд как CLI-эквивалент.", severity: .info)
                    }
                    if platform == .macOS {
                        macOSContent
                    } else {
                        ReferenceEntryView(entry: CLIReferenceService.entry(preview.action, scheduler: scheduler, schedule: presentation.job?.definition.schedule))
                    }
                }
                .padding(24)
            }
            SheetFooter {
                footer
            }
        }
        .frame(width: 760, height: 720)
        .onAppear { platform = appState.settings.defaultCLIPlatform }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.2)), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Терминальные команды").font(.title2.weight(.bold))
                    Text(preview.title + (preview.label.map { " · \($0)" } ?? "")).foregroundStyle(.secondary)
                }
                Spacer()
                CLIPlatformPicker(platform: $platform, scheduler: $scheduler)
            }
            HStack(spacing: 16) {
                if platform == .macOS {
                    fact("Подключение", preview.connection, "laptopcomputer")
                    fact("Платформа", preview.platform, "apple.logo")
                    fact("Планировщик", preview.backend, "gearshape.2")
                } else {
                    fact("Подключение", "нет — только справочник", "book.closed")
                    fact("Платформа", "Linux (пример)", "terminal")
                    fact("Планировщик", scheduler.title, "gearshape.2")
                }
                fact("Действие", preview.title, "bolt")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private func fact(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var macOSContent: some View {
        if !preview.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(preview.warnings, id: \.self) { MessageRow(text: $0, severity: .warning) }
            }
        }

        ForEach(preview.files) { file in
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(file.before == nil ? "Новый файл" : "Изменение конфигурации", symbol: "doc.badge.gearshape", tint: .orange)
                    Text(file.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if !file.structured.isEmpty, file.before != nil {
                        StructuredChangesView(changes: file.structured)
                    }
                    DiffView(before: file.before ?? "", after: file.after ?? "", path: file.path)
                    if !file.manualCommands.isEmpty {
                        Text("Как изменить файл вручную").font(.subheadline.weight(.semibold))
                        CodeBlock(text: file.manualCommands.joined(separator: "\n"), language: .shell)
                        Text("Команды launchctl ниже не меняют файл — они только применяют уже сохранённую конфигурацию.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }

        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("Последовательность команд", symbol: "list.number", tint: .purple) {
                    Button("Копировать всё") { Workspace.copy(preview.script) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                ForEach(Array(preview.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .frame(width: 22, height: 22)
                            .background(Color.accentColor.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(step.purpose).font(.callout.weight(.semibold))
                                if let condition = step.condition {
                                    Text(condition).font(.caption).foregroundStyle(.secondary)
                                }
                                if step.isDestructive {
                                    Label("меняет состояние", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            CodeBlock(text: step.command, language: .shell)
                        }
                    }
                }
                Text("Команды сгенерированы из реальной конфигурации задания. gui/\(getuid()) — то же, что gui/$(id -u).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch presentation.mode {
        case .view, .dryRun:
            Button("Закрыть") { dismiss() }
                .accessibilityIdentifier("preview.close")
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
        case .confirm(let execute):
            if appState.settings.isDryRun {
                Text("Dry Run включён").foregroundStyle(.secondary)
            }
            Button("Отмена", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            let destructive = preview.steps.contains(where: \.isDestructive) || preview.requiresConfirmation
            // Destructive confirmations never fire on Return.
            Button(role: destructive ? .destructive : nil) {
                isRunning = true
                Task {
                    dismiss()
                    await execute()
                }
            } label: {
                Text(appState.settings.isDryRun ? "Dry Run" : "Выполнить")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(destructive ? nil : .defaultAction)
            .accessibilityIdentifier("preview.execute")
            .disabled(isRunning)
        }
    }
}
