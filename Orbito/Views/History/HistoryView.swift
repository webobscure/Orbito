import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var appState
    @State private var search = ""
    @State private var confirmClear = false

    var body: some View {
        let events = appState.history.events.filter {
            search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.message.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search)
        }
        let grouped = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }

        Group {
            if appState.history.events.isEmpty {
                EmptyStateView(
                    title: "История пуста",
                    message: "Здесь появятся действия, выполненные Orbito (запуски, изменения расписания, создание и удаление), а также ошибки, замеченные во время работы приложения. launchd сам не хранит историю запусков.",
                    symbol: "clock.arrow.circlepath"
                )
            } else {
                List {
                    Section {
                        Label("Журнал содержит только события Orbito. Запуски по расписанию launchd не протоколирует — смотрите логи заданий.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(grouped.keys.sorted(by: >), id: \.self) { day in
                        Section(day.formatted(date: .complete, time: .omitted).capitalized) {
                            ForEach(grouped[day] ?? []) { event in
                                HistoryRow(event: event) {
                                    if let job = appState.jobs.first(where: { $0.label == event.label }) { appState.open(job) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AmbientBackground())
        .navigationTitle("История")
        .searchable(text: $search, placement: .toolbar, prompt: "Поиск в истории")
        .toolbar {
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("Очистить", systemImage: "trash")
            }
            .disabled(appState.history.events.isEmpty)
        }
        .confirmationDialog("Очистить историю Orbito?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { appState.history.clear() }
        } message: {
            Text("Удаляется только журнал Orbito. Задания и логи не затрагиваются.")
        }
    }
}

private struct HistoryRow: View {
    var event: HistoryEvent
    var open: () -> Void

    private var color: Color {
        switch event.outcome {
        case .success: .green
        case .failure: .red
        case .observed: event.kind == .observedFailure ? .orange : .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.title).font(.body.weight(.semibold))
                    Text(event.outcome == .failure ? "не выполнено" : (event.outcome == .observed ? "наблюдение" : ""))
                        .font(.caption)
                        .foregroundStyle(color)
                    Spacer()
                    Text(event.date.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button(event.label, action: open)
                    .buttonStyle(.link)
                    .font(.caption.monospaced())
                if !event.message.isEmpty {
                    Text(event.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
