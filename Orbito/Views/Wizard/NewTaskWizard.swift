import SwiftUI
import UniformTypeIdentifiers

struct NewTaskWizard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model: NewTaskViewModel
    @State private var isDropTargeted = false
    @Namespace private var stepNamespace
    @State private var localPreview: PreviewPresentation?

    init(existingLabels: Set<String>) {
        _model = State(initialValue: NewTaskViewModel(existingLabels: existingLabels))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Новое задание", subtitle: "Шаг \(model.step.rawValue + 1) из \(WizardStep.allCases.count) · \(model.step.title)", symbol: "plus.circle")
            stepIndicator
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            Group {
                switch model.step {
                case .info: infoStep
                case .command: commandStep
                case .schedule: scheduleStep
                case .logging: loggingStep
                case .review: reviewStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(model.step)

            footer
        }
        .frame(width: 720, height: 760)
        .animation(appState.settings.animation, value: model.step)
        .sheet(item: $localPreview) { CommandPreviewSheet(presentation: $0) }
        .onAppear { model.logDirectory = appState.settings.defaultLogDirectory }
    }

    private var createPreview: CommandPreview {
        appState.previews.previewCreate(dict: model.plistDictionary, label: model.form.trimmedLabel, load: model.loadAfterCreate)
    }

    private func create() {
        appState.gateEditor(createPreview, job: nil, present: { localPreview = $0 }, dryRunDone: { dismiss() }) {
            if await model.create(using: appState) { dismiss() }
        }
    }

    // MARK: Chrome

    private var stepIndicator: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(WizardStep.allCases) { step in
                    let isCurrent = step == model.step
                    let isDone = step.rawValue < model.step.rawValue
                    HStack(spacing: 6) {
                        Image(systemName: isDone ? "checkmark.circle.fill" : step.symbol)
                        if isCurrent { Text(step.title).fontWeight(.semibold) }
                    }
                    .font(.callout)
                    .foregroundStyle(isCurrent ? Color.accentColor : (isDone ? .green : .secondary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(isCurrent ? .regular.tint(Color.accentColor.opacity(0.2)) : .regular, in: Capsule())
                    .glassEffectID(step.id, in: stepNamespace)
                    .onTapGesture {
                        if step.rawValue < model.step.rawValue { model.step = step }
                    }
                }
            }
        }
    }

    private var footer: some View {
        SheetFooter {
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            Spacer()
            Button("Отмена", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if model.step != .info {
                Button("Назад") { model.back() }
            }
            if model.step == .review {
                Button {
                    create()
                } label: {
                    if model.isCreating { ProgressView().controlSize(.small) } else { Text(appState.settings.isDryRun ? "Dry Run" : (model.loadAfterCreate ? "Создать и загрузить" : "Создать")) }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("wizard.create")
                .disabled(!model.errors(for: .review).isEmpty || model.isCreating)
            } else {
                Button("Далее") { model.next() }
                    .accessibilityIdentifier("wizard.next")
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvance)
            }
        }
    }

    // MARK: Steps

    private var infoStep: some View {
        Form {
            Section {
                TextField("Название", text: $model.form.displayName, prompt: Text("Например, ONKRON Market Prices"))
                    .accessibilityIdentifier("wizard.name")
                    .onChange(of: model.form.displayName) { model.nameChanged() }
                TextField("Label", text: Binding(
                    get: { model.form.label },
                    set: { model.form.label = $0; model.labelEditedManually = true }
                ), prompt: Text("com.example.my-task"))
                .accessibilityIdentifier("wizard.label")
                .font(.body.monospaced())
                if let error = model.labelError, !model.form.label.isEmpty {
                    MessageRow(text: error, severity: .error)
                } else if !model.form.label.isEmpty {
                    MessageRow(text: "Файл: ~/Library/LaunchAgents/\(model.form.trimmedLabel).plist", severity: .info)
                }
                TextField("Описание (только для Orbito)", text: $model.form.notes, axis: .vertical)
                    .lineLimit(2...4)
            } footer: {
                Text("Label — уникальный идентификатор задания в launchd. Используйте обратную доменную запись: com.company.task.")
            }
        }
        .formStyle(.grouped)
    }

    private var commandStep: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 28))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                    Text("Перетащите сюда скрипт (.sh, .zsh, .py, .php, .js) или исполняемый файл")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Интерпретатор будет подобран автоматически, без shell-строк.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary.opacity(0.5))
                )
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, url.isFileURL else { return false }
                    model.useFile(url)
                    return true
                } isTargeted: { isDropTargeted = $0 }
            }
            CommandFields(form: $model.form)
            ValidationSection(validation: model.form.validateCommand())
        }
        .formStyle(.grouped)
    }

    private var scheduleStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SchedulePicker(draft: $model.draft)
                Toggle("Также запускать при загрузке (RunAtLoad)", isOn: $model.form.runAtLoad)
                Toggle("Перезапускать при завершении (KeepAlive)", isOn: $model.form.keepAlive)
                if model.form.keepAlive {
                    MessageRow(text: "KeepAlive перезапускает процесс после каждого завершения. Для периодических задач обычно не нужен.", severity: .warning)
                }
            }
            .padding(24)
        }
    }

    private var loggingStep: some View {
        Form {
            LogFields(form: $model.form) { model.setLogDirectory($0) }
            Section {
                Button("Вернуть пути по умолчанию") {
                    model.form.standardOutPath = ""
                    model.form.standardErrorPath = ""
                    model.updateDefaultLogPaths()
                }
                Text("По умолчанию: \(model.logDirectory). Каталог будет создан при создании задания.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ValidationSection(validation: model.form.validateLogs())
        }
        .formStyle(.grouped)
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        KeyValueRow(key: "Название", value: model.form.displayName.isEmpty ? "—" : model.form.displayName)
                        KeyValueRow(key: "Label", value: model.form.trimmedLabel, monospaced: true)
                        KeyValueRow(key: "Команда", value: Workspace.shellCommand(model.form.argv), monospaced: true)
                        KeyValueRow(key: "Рабочая директория", value: model.form.workingDirectory.isEmpty ? "—" : model.form.workingDirectory, monospaced: true)
                        KeyValueRow(key: "Расписание", value: model.scheduleSummary)
                        KeyValueRow(key: "stdout", value: model.form.standardOutPath.isEmpty ? "—" : model.form.standardOutPath, monospaced: true)
                        KeyValueRow(key: "stderr", value: model.form.standardErrorPath.isEmpty ? "—" : model.form.standardErrorPath, monospaced: true)
                    }
                }
                ForEach(model.errors(for: .review), id: \.self) { MessageRow(text: $0, severity: .error) }
                Toggle("Сразу загрузить в launchd (\(LaunchDomain.currentGUI.target))", isOn: $model.loadAfterCreate)
                Text("Предпросмотр plist").font(.headline)
                CodeBlock(text: model.plistPreview, language: .xml)
                Text("CLI Preview").font(.headline)
                let preview = createPreview
                CodeBlock(text: preview.steps.map(\.command).joined(separator: "\n"), language: .shell)
                HStack {
                    ForEach(preview.warnings, id: \.self) { MessageRow(text: $0, severity: .info) }
                    Spacer()
                    if appState.settings.developerMode {
                        Button("Все команды…") {
                            localPreview = PreviewPresentation(preview: preview, mode: .view, job: nil)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(24)
        }
    }
}
