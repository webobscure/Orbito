import SwiftUI

struct CommandHistoryView: View {
    @Environment(AppState.self) private var appState
    @State private var search = ""
    @State private var kind: CommandRecord.Kind?
    @State private var onlyFailures = false
    @State private var selection: CommandRecord.ID?
    @State private var confirmClear = false

    var body: some View {
        let records = appState.commandHistory.records.filter { record in
            (kind == nil || record.kind == kind) &&
            (!onlyFailures || !record.succeeded) &&
            (search.isEmpty || [record.command, record.label ?? "", record.action, record.output, record.errorOutput].contains { $0.localizedCaseInsensitiveContains(search) })
        }

        HSplitView {
            List(selection: $selection) {
                if !appState.settings.recordsCommandHistory {
                    Label("Запись истории выключена в настройках Developer Mode.", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    HistoryCommandRow(record: record).tag(record.id)
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 380, idealWidth: 460)
            .overlay {
                if records.isEmpty {
                    EmptyStateView(title: "Команд нет", message: "Здесь появятся команды и операции с файлами, которые Orbito выполняет по вашим действиям. Периодическое сканирование не записывается.", symbol: "terminal")
                }
            }

            Group {
                if let id = selection, let record = appState.commandHistory.records.first(where: { $0.id == id }) {
                    HistoryCommandDetail(record: record)
                } else {
                    EmptyStateView(title: "Выберите запись", message: "Подробности: команда, код выхода, stdout и stderr.", symbol: "sidebar.left")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("История команд")
        .navigationSubtitle("\(records.count) записей")
        .searchable(text: $search, placement: .toolbar, prompt: "Команда, задание, вывод")
        .toolbar {
            Menu {
                Picker("Тип", selection: $kind) {
                    Text("Все типы").tag(CommandRecord.Kind?.none)
                    ForEach(CommandRecord.Kind.allCases, id: \.self) { Text($0.title).tag(CommandRecord.Kind?.some($0)) }
                }
                .pickerStyle(.inline)
                Toggle("Только ошибки", isOn: $onlyFailures)
            } label: {
                Label("Фильтр", systemImage: kind == nil && !onlyFailures ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            Button(role: .destructive) { confirmClear = true } label: { Label("Очистить", systemImage: "trash") }
                .disabled(appState.commandHistory.records.isEmpty)
        }
        .confirmationDialog("Очистить историю команд?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { appState.commandHistory.clear() }
        }
    }
}

private struct HistoryCommandRow: View {
    var record: CommandRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.kind.symbol)
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(record.command.components(separatedBy: "\n").first ?? record.command)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.action)
                    if let label = record.label { Text("· " + label) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(record.date.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let code = record.exitCode {
                    Text("exit \(code)").font(.caption2.monospaced().weight(.semibold)).foregroundStyle(code == 0 ? Color.green : .red)
                } else if record.kind == .executed {
                    Text("ошибка").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var color: Color {
        if !record.succeeded { return .red }
        switch record.kind {
        case .executed: return .blue
        case .fileOperation: return .orange
        case .internalOperation: return .gray
        case .cliEquivalent: return .indigo
        }
    }
}

private struct HistoryCommandDetail: View {
    var record: CommandRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(record.kind.title, systemImage: record.kind.symbol).font(.headline)
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        KeyValueRow(key: "Время", value: record.date.formatted(date: .abbreviated, time: .standard))
                        KeyValueRow(key: "Подключение", value: record.connection)
                        KeyValueRow(key: "Планировщик", value: record.backend)
                        KeyValueRow(key: "Задание", value: record.label ?? "—", monospaced: true)
                        KeyValueRow(key: "Действие", value: record.action)
                        KeyValueRow(key: "Код выхода", value: record.exitCode.map(String.init) ?? "—")
                        KeyValueRow(key: "Длительность", value: String(format: "%.2f с", record.duration))
                    }
                }
                Text(record.kind == .cliEquivalent ? "CLI-эквивалент (не выполнялся)" : "Команда").font(.subheadline.weight(.semibold))
                CodeBlock(text: record.command, language: .shell)
                if !record.output.isEmpty {
                    Text("stdout").font(.subheadline.weight(.semibold))
                    CodeBlock(text: record.output, language: .plain, maxHeight: 260)
                }
                if !record.errorOutput.isEmpty {
                    Text("stderr").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    CodeBlock(text: record.errorOutput, language: .plain, maxHeight: 200)
                }
                Text("Секреты (пароли, токены, ключи) маскируются перед сохранением.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}
