import SwiftUI

struct LogViewerView: View {
    @Environment(AppState.self) private var appState
    @State private var model: LogViewerViewModel?
    var job: LaunchJob

    var body: some View {
        Group {
            if let model {
                LogViewerContent(model: model)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil { model = LogViewerViewModel(job: job, lineCount: appState.settings.logLineCount) }
        }
    }
}

private struct LogViewerContent: View {
    @Bindable var model: LogViewerViewModel
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            statusBar
        }
        .task(id: model.stream) {
            await model.reload()
            model.startPolling()
        }
        .onDisappear { model.stopPolling() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Поток", selection: $model.stream) {
                ForEach(LogStream.allCases.filter { $0 != .launchd || appState.settings.showsAdvancedLogs }) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: appState.settings.showsAdvancedLogs ? 240 : 180)

            TextField("Поиск", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Picker("Строк", selection: $model.lineCount) {
                ForEach([100, 500, 1000, 5000, 20000], id: \.self) { Text("\($0) строк").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.lineCount) { Task { await model.reload() } }

            Spacer()

            Toggle("Авто", isOn: $model.autoRefresh)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Автообновление при изменении файла")
            Toggle("Прокрутка", isOn: $model.autoScroll)
                .toggleStyle(.switch)
                .controlSize(.small)

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        Task { await model.reload() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .help("Обновить")
                    Button {
                        Workspace.copy(model.allText)
                    } label: { Image(systemName: "doc.on.doc") }
                        .help("Копировать видимые строки")
                    if appState.settings.showsAdvancedLogs {
                        Button {
                            FilePanels.exportText(model.allText, suggestedName: "\(model.job.label)-\(model.stream.rawValue).log")
                        } label: { Image(systemName: "square.and.arrow.up") }
                            .help("Экспорт видимых строк")
                    }
                    Button {
                        if let path = model.path { Workspace.open(URL(filePath: path)) }
                    } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Открыть файл")
                        .disabled(model.snapshot.state != .ok)
                    Button {
                        if let path = model.path { Workspace.reveal(URL(filePath: path)) }
                    } label: { Image(systemName: "folder") }
                        .help("Показать в Finder")
                        .disabled(model.snapshot.state != .ok)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.snapshot.state {
        case .notConfigured:
            EmptyStateView(title: "Путь не задан", message: "В plist нет \(model.stream == .stdout ? "StandardOutPath" : "StandardErrorPath"). Добавьте путь в редакторе задания.", symbol: "doc.badge.ellipsis")
        case .missing:
            EmptyStateView(title: "Файла пока нет", message: "\(model.path ?? "")\nlaunchd создаст файл при первом запуске (если каталог существует).", symbol: "doc.questionmark")
        case .unreadable(let reason):
            EmptyStateView(title: "Не удалось прочитать", message: reason, symbol: "lock.doc")
        case .ok:
            let lines = model.visibleLines
            if lines.isEmpty {
                EmptyStateView(title: model.searchText.isEmpty ? "Лог пуст" : "Совпадений нет", message: model.path ?? "", symbol: "doc.text")
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines, id: \.index) { line in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(line.index + 1)")
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 52, alignment: .trailing)
                                    Text(line.text.isEmpty ? " " : line.text)
                                        .foregroundStyle(color(for: line.text))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.vertical, 1)
                                .id(line.index)
                            }
                        }
                        .padding(12)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: model.snapshot.lines.count, initial: true) {
                        if model.autoScroll, let last = lines.last { proxy.scrollTo(last.index, anchor: .bottom) }
                    }
                    .onChange(of: model.snapshot.modified) {
                        if model.autoScroll, let last = model.visibleLines.last { proxy.scrollTo(last.index, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("fatal") || lower.contains("exception") || lower.contains("ошибка") { return .red }
        if lower.contains("warn") { return .orange }
        return .primary
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let path = model.path {
                Label("Файл: \(path)", systemImage: "doc").lineLimit(1).truncationMode(.middle)
            } else if model.stream == .launchd {
                Label("Источник: \(model.diagnosticsOrigin.isEmpty ? "launchctl print + log show" : model.diagnosticsOrigin)", systemImage: "waveform.path.ecg")
            }
            Spacer()
            if model.sameFileForBoth { Text("stdout и stderr пишутся в один файл") }
            if model.snapshot.truncated { Text("показан хвост файла") }
            Text(ByteCountFormatter.string(fromByteCount: Int64(model.snapshot.fileSize), countStyle: .file))
            if let modified = model.snapshot.modified {
                Text("изменён \(modified.formatted(date: .abbreviated, time: .standard))")
            }
            if model.isLoading { ProgressView().controlSize(.mini) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
