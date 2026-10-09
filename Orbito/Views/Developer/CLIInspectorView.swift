import SwiftUI

/// Read-only launchctl inspector. Runs only `print`, `print-disabled`, `list`, `blame`.
struct CLIInspectorView: View {
    @Environment(AppState.self) private var appState
    @State private var jobID: String?
    @State private var query: Query = .print
    @State private var result: CommandResult?
    @State private var command = ""
    @State private var isRunning = false
    @State private var filter = ""

    enum Query: String, CaseIterable, Identifiable {
        case print, blame, disabled, list, domain
        var id: String { rawValue }
        var title: String {
            switch self {
            case .print: "print <service>"
            case .blame: "blame <service>"
            case .disabled: "print-disabled"
            case .list: "list"
            case .domain: "print <domain>"
            }
        }
        var needsJob: Bool { self == .print || self == .blame }
    }

    var body: some View {
        let job = jobID.flatMap(appState.job(withID:))
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Задание", selection: $jobID) {
                    Text("Выберите задание").tag(String?.none)
                    ForEach(appState.jobs) { Text($0.label).tag(String?.some($0.id)) }
                }
                .frame(maxWidth: 340)
                Picker("Запрос", selection: $query) {
                    ForEach(Query.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)
                Spacer()
                Button {
                    Task { await run(job) }
                } label: {
                    Label("Выполнить", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(isRunning || (query.needsJob && job == nil))
            }
            .padding(14)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(command.isEmpty ? arguments(for: job).map { "launchctl " + Workspace.shellCommand($0) } ?? "—" : command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    if let result {
                        Text("exit \(result.exitCode)").font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(result.exitCode == 0 ? Color.green : .red)
                    }
                    TextField("Фильтр строк", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                if isRunning {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result {
                    let text = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                    let filtered = filter.isEmpty ? text : text.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
                    CodeBlock(text: filtered.isEmpty ? "(пусто)" : filtered, language: .plain)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    EmptyStateView(title: "CLI Inspector", message: "Только чтение: Orbito выполняет здесь лишь запросы состояния launchctl. Каждая команда попадает в Историю команд.", symbol: "stethoscope")
                }
            }
            .padding(14)
        }
        .background(AmbientBackground())
        .navigationTitle("CLI Inspector")
        .onAppear { if jobID == nil { jobID = appState.selectedJobID } }
    }

    private func arguments(for job: LaunchJob?) -> [String]? {
        let domain = job?.runtime.domain.target ?? LaunchDomain.currentGUI.target
        switch query {
        case .print: return job.map { ["print", $0.runtime.domain.serviceTarget($0.label)] }
        case .blame: return job.map { ["blame", $0.runtime.domain.serviceTarget($0.label)] }
        case .disabled: return ["print-disabled", domain]
        case .list: return ["list"]
        case .domain: return ["print", domain]
        }
    }

    private func run(_ job: LaunchJob?) async {
        guard let args = arguments(for: job) else { return }
        isRunning = true
        command = "launchctl " + Workspace.shellCommand(args)
        result = await appState.inspect(args)
        isRunning = false
    }
}
