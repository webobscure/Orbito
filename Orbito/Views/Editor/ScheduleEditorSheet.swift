import SwiftUI

struct ScheduleEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model: ScheduleEditorViewModel
    @State private var showFragment = false
    @State private var localPreview: PreviewPresentation?

    init(job: LaunchJob) {
        _model = State(initialValue: ScheduleEditorViewModel(job: job))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Расписание", subtitle: model.job.displayName, symbol: "clock.badge")

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SchedulePicker(draft: $model.draft)

                    GlassCard(style: .glass, tint: .accentColor) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Итог").font(.caption).foregroundStyle(.secondary)
                            Text(model.summary).font(.headline)
                            if !model.preview.isEmpty {
                                HStack(spacing: 8) {
                                    ForEach(model.preview.prefix(3), id: \.self) { date in
                                        Text(ScheduleFormatter.relativeDay(date))
                                            .font(.caption.monospacedDigit())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    if appState.settings.developerMode, let newDict = model.updatedPlist, model.hasChanges {
                        DisclosureGroup("Configuration Diff", isExpanded: $showFragment) {
                            VStack(alignment: .leading, spacing: 10) {
                                StructuredChangesView(changes: ConfigurationDiffService.structured(old: model.job.raw, new: newDict))
                                DiffView(before: PlistService.xmlString(model.job.raw), after: PlistService.xmlString(newDict), path: model.job.plistURL.path)
                            }
                            .padding(.top, 6)
                        }
                        .font(.callout)
                    } else {
                        DisclosureGroup("Будет записано в plist", isExpanded: $showFragment) {
                            CodeBlock(text: model.plistFragment.isEmpty ? "(ключи расписания будут удалены)" : model.plistFragment, language: .xml)
                        }
                        .font(.callout)
                    }

                    if model.job.runtime.loaded == .yes {
                        MessageRow(
                            text: model.job.runtime.pid != nil
                                ? "Задание сейчас выполняется (PID \(model.job.runtime.pid!)). Применение изменений перезагрузит его и остановит текущий процесс."
                                : "После сохранения задание будет перезагружено в launchd (bootout + bootstrap). Остальные задания не затрагиваются.",
                            severity: model.job.runtime.pid != nil ? .warning : .info
                        )
                    } else {
                        MessageRow(text: "Задание не загружено — изменится только файл.", severity: .info)
                    }
                }
                .padding(24)
            }

            SheetFooter {
                if appState.settings.developerMode, let newDict = model.updatedPlist {
                    Button {
                        localPreview = PreviewPresentation(preview: appState.previews.previewChange(.editSchedule, job: model.job, newDict: newDict), mode: .view, job: model.job)
                    } label: {
                        Label("Терминальные команды", systemImage: "terminal")
                    }
                    .cliHint(.editSchedule, job: model.job)
                    Spacer()
                }
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if model.isSaving { ProgressView().controlSize(.small) } else { Text(appState.settings.isDryRun ? "Dry Run" : "Сохранить и применить") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("schedule.save")
                .disabled(model.built == nil || !model.hasChanges || model.isSaving)
            }
        }
        .frame(width: 720, height: 760)
        .sheet(item: $localPreview) { CommandPreviewSheet(presentation: $0) }
    }
}

extension ScheduleEditorSheet {
    private func save() {
        guard let newDict = model.updatedPlist else { return }
        let preview = appState.previews.previewChange(.editSchedule, job: model.job, newDict: newDict)
        appState.gateEditor(preview, job: model.job, present: { localPreview = $0 }, dryRunDone: { dismiss() }) {
            if await model.save(using: appState) { dismiss() }
        }
    }
}

struct SheetHeader: View {
    var title: String
    var subtitle: String?
    var symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.2)), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.bold))
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}

struct SheetFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            content
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

struct DuplicateSheet: View {
    var job: LaunchJob
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var error: String?
    @State private var working = false
    @State private var localPreview: PreviewPresentation?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Дублировать задание", subtitle: job.label, symbol: "plus.square.on.square")
            Form {
                TextField("Новый Label", text: $label)
                    .font(.body.monospaced())
                if let validation = validationError {
                    MessageRow(text: validation, severity: .error)
                }
                if let error { MessageRow(text: error, severity: .error) }
                Text("Копия будет создана в ~/Library/LaunchAgents и не будет загружена в launchd, чтобы задание не выполнялось дважды.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            SheetFooter {
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(appState.settings.isDryRun ? "Dry Run" : "Создать копию") {
                    var dict = job.raw
                    dict["Label"] = .string(label)
                    let preview = appState.previews.previewCreate(dict: dict, label: label, load: false, duplicateOf: job.label)
                    appState.gateEditor(preview, job: job, present: { localPreview = $0 }, dryRunDone: { dismiss() }) {
                        working = true
                        do {
                            try await appState.duplicate(job, as: label)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validationError != nil || working)
            }
        }
        .frame(width: 480)
        .onAppear { label = LabelValidator.uniqueCopyLabel(for: job.label, existing: appState.allLabels) }
        .sheet(item: $localPreview) { CommandPreviewSheet(presentation: $0) }
    }

    private var validationError: String? {
        do {
            try LabelValidator.validateNew(label, existingLabels: appState.allLabels, directory: JobScope.userAgent.directory)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
