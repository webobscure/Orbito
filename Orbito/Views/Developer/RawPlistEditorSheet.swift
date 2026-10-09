import SwiftUI

/// Raw plist viewer with an explicit Advanced Editor. Viewing never writes anything;
/// saving requires validation, a diff review and confirmation.
struct RawPlistEditorSheet: View {
    var job: LaunchJob
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isEditing = false
    @State private var reviewing = false
    @State private var isSaving = false

    private var original: String { PlistService.xmlString(job.raw) }

    private var parsed: Result<[String: PlistValue], Error> {
        Result { try PlistService.decode(Data(text.utf8), path: job.plistURL.path).dict }
    }

    private var validationErrors: [String] {
        switch parsed {
        case .failure(let error): return [error.localizedDescription]
        case .success(let dict):
            var errors: [String] = []
            if dict["Label"]?.stringValue != job.label { errors.append("Label нельзя менять в редакторе (используйте «Дублировать»).") }
            if dict["Program"] == nil && dict["ProgramArguments"] == nil { errors.append("Нужен Program или ProgramArguments.") }
            return errors
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: isEditing ? "Advanced Editor" : "Plist", subtitle: job.plistURL.path, symbol: "chevron.left.forwardslash.chevron.right")
            Group {
                if reviewing, case .success(let dict) = parsed {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            StructuredChangesView(changes: ConfigurationDiffService.structured(old: job.raw, new: dict))
                            DiffView(before: original, after: PlistService.xmlString(dict), path: job.plistURL.path)
                            MessageRow(text: "Будет создана резервная копия; файл проверит plutil; загруженное задание будет перезагружено. При ошибке исходный файл восстановится.", severity: .info)
                        }
                        .padding(20)
                    }
                } else if isEditing {
                    TextEditor(text: $text)
                        .accessibilityIdentifier("raw.text")
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.04))
                } else {
                    ScrollView {
                        CodeBlock(text: original, language: .xml)
                            .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isEditing, !reviewing {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(validationErrors, id: \.self) { MessageRow(text: $0, severity: .error) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, validationErrors.isEmpty ? 0 : 8)
            }

            SheetFooter {
                if !isEditing {
                    Button("Показать в Finder") { Workspace.reveal(job.plistURL) }
                    Button("Копировать") { Workspace.copy(original) }
                    if job.isEditable {
                        Button("Редактировать…") {
                            text = original
                            withAnimation(appState.settings.animation) { isEditing = true }
                        }
                        .accessibilityIdentifier("raw.edit")
                    }
                    Button("Закрыть") { dismiss() }
                        .accessibilityIdentifier("raw.close")
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else if !reviewing {
                    Button("Отмена", role: .cancel) { dismiss() }
                    Button("Проверить изменения") { reviewing = true }
                        .accessibilityIdentifier("raw.review")
                        .buttonStyle(.glassProminent)
                        .disabled(!validationErrors.isEmpty || text == original)
                } else {
                    Button("Назад к редактору") { reviewing = false }
                    Button(appState.settings.isDryRun ? "Dry Run" : "Сохранить и применить") { save() }
                        .accessibilityIdentifier("raw.save")
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving)
                }
            }
        }
        .frame(width: 780, height: 700)
        .onAppear { text = original }
    }

    private func save() {
        guard case .success(let dict) = parsed else { return }
        if appState.settings.isDryRun {
            appState.recordDryRun(appState.previews.previewChange(.editConfiguration, job: job, newDict: dict))
            appState.showBanner(.info, "Dry Run: plist не изменён", ["CLI-эквивалент записан в Историю команд."])
            dismiss()
            return
        }
        isSaving = true
        Task {
            if await appState.saveDefinition(dict, for: job, metadata: nil, kind: .rawEdited) { dismiss() }
            isSaving = false
        }
    }
}
