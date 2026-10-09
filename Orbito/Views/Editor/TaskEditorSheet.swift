import SwiftUI
import UniformTypeIdentifiers

struct TaskEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model: TaskEditorViewModel
    @State private var localPreview: PreviewPresentation?

    init(job: LaunchJob) {
        _model = State(initialValue: TaskEditorViewModel(job: job))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Редактирование", subtitle: model.job.label, symbol: "pencil")
            Form {
                Section("Отображение в Orbito") {
                    TextField("Название", text: $model.form.displayName, prompt: Text(LaunchJob.prettyName(from: model.job.label)))
                    TextField("Описание", text: $model.form.notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                CommandFields(form: $model.form)
                LogFields(form: $model.form)
                Section("Поведение") {
                    Toggle("Запускать при загрузке (RunAtLoad)", isOn: $model.form.runAtLoad)
                    if model.form.keepAliveIsConditional {
                        LabeledContent("KeepAlive", value: "Условный (словарь) — сохраняется без изменений")
                    } else {
                        Toggle("Перезапускать при завершении (KeepAlive)", isOn: $model.form.keepAlive)
                    }
                }
                ValidationSection(validation: model.validation)
                Section {
                    Text("Изменяются только показанные поля. Остальные ключи plist (в т.ч. неизвестные Orbito) сохраняются. Расписание меняется в отдельном редакторе.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            SheetFooter {
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if model.isSaving { ProgressView().controlSize(.small) } else { Text(appState.settings.isDryRun ? "Dry Run" : "Сохранить и применить") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.validation.errors.isEmpty || !model.hasChanges || model.isSaving)
            }
        }
        .frame(width: 660, height: 720)
        .sheet(item: $localPreview) { CommandPreviewSheet(presentation: $0) }
    }
}

extension TaskEditorSheet {
    private func save() {
        guard model.validation.errors.isEmpty else { return }
        // Display name/notes are Orbito metadata; a plist change is previewed only if the file changes.
        guard model.updatedPlist != model.job.raw else {
            if appState.settings.isDryRun {
                appState.showBanner(.info, "Dry Run: ничего не изменено", ["Название и описание не сохранены."])
                dismiss()
            } else {
                Task { if await model.save(using: appState) { dismiss() } }
            }
            return
        }
        let preview = appState.previews.previewChange(.editConfiguration, job: model.job, newDict: model.updatedPlist)
        appState.gateEditor(preview, job: model.job, present: { localPreview = $0 }, dryRunDone: { dismiss() }) {
            if await model.save(using: appState) { dismiss() }
        }
    }
}

struct ValidationSection: View {
    var validation: JobForm.Validation

    var body: some View {
        if !validation.errors.isEmpty || !validation.warnings.isEmpty {
            Section {
                ForEach(validation.errors, id: \.self) { MessageRow(text: $0, severity: .error) }
                ForEach(validation.warnings, id: \.self) { MessageRow(text: $0, severity: .warning) }
            }
        }
    }
}

/// Executable, arguments, working directory and environment.
struct CommandFields: View {
    @Binding var form: JobForm
    @State private var pickingExecutable = false
    @State private var pickingWorkingDir = false

    var body: some View {
        Section("Команда") {
            HStack {
                TextField("Исполняемый файл", text: $form.executable, prompt: Text("/bin/zsh"))
                    .accessibilityIdentifier("command.executable")
                    .font(.body.monospaced())
                Menu {
                    ForEach(ScriptInterpreter.known, id: \.path) { item in
                        Button("\(item.name) — \(item.path)") { form.executable = item.path }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Интерпретаторы")
                Button("Выбрать…") { pickingExecutable = true }
            }
            .fileImporter(isPresented: $pickingExecutable, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { form.executable = url.path }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Аргументы").font(.callout)
                ForEach($form.arguments) { $arg in
                    HStack {
                        TextField("Аргумент", text: $arg.value)
                            .font(.body.monospaced())
                        Button {
                            form.arguments.removeAll { $0.id == arg.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    form.arguments.append(ArgumentItem(value: ""))
                } label: {
                    Label("Добавить аргумент", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Text("Каждый аргумент передаётся отдельно, без shell. Для скрипта: исполняемый файл — интерпретатор, первый аргумент — путь к скрипту.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Рабочая директория", text: $form.workingDirectory, prompt: Text("необязательно"))
                    .font(.body.monospaced())
                Button("Выбрать…") { pickingWorkingDir = true }
            }
            .fileImporter(isPresented: $pickingWorkingDir, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { form.workingDirectory = url.path }
            }
        }

        Section("Переменные окружения") {
            ForEach($form.environment) { $item in
                HStack {
                    TextField("KEY", text: $item.key)
                        .font(.body.monospaced())
                        .frame(maxWidth: 180)
                    Text("=").foregroundStyle(.secondary)
                    TextField("значение", text: $item.value)
                        .font(.body.monospaced())
                    Button {
                        form.environment.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button {
                    form.environment.append(EnvironmentItem(key: "", value: ""))
                } label: {
                    Label("Добавить переменную", systemImage: "plus")
                }
                Spacer()
                if !form.environment.contains(where: { $0.key == "PATH" }) {
                    Button("Добавить PATH с Homebrew") {
                        form.environment.append(EnvironmentItem(key: "PATH", value: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"))
                    }
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

struct LogFields: View {
    @Binding var form: JobForm
    var onPickDirectory: ((URL) -> Void)?
    @State private var pickingDirectory = false

    var body: some View {
        Section("Логи") {
            TextField("stdout", text: $form.standardOutPath, prompt: Text("/Users/…/Library/Logs/task.out.log"))
                .font(.body.monospaced())
            TextField("stderr", text: $form.standardErrorPath, prompt: Text("/Users/…/Library/Logs/task.err.log"))
                .font(.body.monospaced())
            HStack {
                Button("Выбрать каталог логов…") { pickingDirectory = true }
                Spacer()
                Button("Объединить stderr со stdout") { form.standardErrorPath = form.standardOutPath }
                    .disabled(form.standardOutPath.isEmpty)
            }
            .buttonStyle(.borderless)
            .fileImporter(isPresented: $pickingDirectory, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                if let onPickDirectory {
                    onPickDirectory(url)
                } else {
                    let base = form.trimmedLabel.isEmpty ? "task" : form.trimmedLabel
                    form.standardOutPath = url.appending(path: "\(base).out.log").path
                    form.standardErrorPath = url.appending(path: "\(base).err.log").path
                }
            }
            Text("launchd не создаёт отсутствующие каталоги для логов.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
