import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) var appState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        let jobs = appState.jobs
        let stats = DashboardViewModel.stats(for: jobs)
        let upcoming = DashboardViewModel.upcoming(jobs, service: appState.scheduleService)
        let problems = jobs.filter(\.hasErrors).prefix(6)
        let intervalJobs = DashboardViewModel.intervalJobs(jobs)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if !appState.hasLoadedOnce {
                    loadingTiles
                } else {
                    statTiles(stats)
                }

                if !appState.scanWarnings.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 6) {
                            CardHeader("Ограничения сканирования", symbol: "exclamationmark.bubble", tint: .orange)
                            ForEach(appState.scanWarnings, id: \.self) { MessageRow(text: $0, severity: .warning) }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 20) {
                    upcomingCard(upcoming, intervalJobs: intervalJobs)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 20) {
                        quickActionsCard(upcoming)
                        problemsCard(Array(problems))
                        favoritesCard
                        recentActivityCard
                    }
                    .frame(width: 340)
                }
            }
            .padding(28)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .navigationTitle("Обзор")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.isPresentingNewTask = true
                } label: {
                    Label("Новое задание", systemImage: "plus")
                }
                .help("Новое задание (⌘N)")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Запланированные задачи")
                .font(.largeTitle.weight(.bold))
        }
    }

    private var loadingTiles: some View {
        HStack(spacing: 16) {
            ForEach(0..<4, id: \.self) { _ in
                GlassCard(style: .glass) {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Загрузка…").foregroundStyle(.secondary)
                    }
                    .frame(height: 70)
                }
            }
        }
    }

    private func statTiles(_ stats: DashboardStats) -> some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                StatTile(title: "Всего заданий", value: "\(stats.total)", symbol: "tray.full", tint: .blue) {
                    appState.taskList.reset(); appState.section = .all
                }
                StatTile(title: "Загружено в launchd", value: stats.loadedUnknown && stats.loaded == 0 ? "Unknown" : "\(stats.loaded)",
                         subtitle: stats.running > 0 ? "выполняется: \(stats.running)" : nil, symbol: "bolt.fill", tint: .green) {
                    appState.taskList.reset(); appState.section = .active
                }
                StatTile(title: "Отключено", value: "\(stats.disabled)", symbol: "pause.fill", tint: .gray) {
                    appState.taskList.reset(); appState.section = .disabled
                }
                StatTile(title: "С ошибками", value: "\(stats.withErrors)", symbol: "exclamationmark.triangle.fill", tint: stats.withErrors > 0 ? .orange : .secondary) {
                    appState.taskList.reset(); appState.section = .errors
                }
            }
        }
    }

    private func upcomingCard(_ runs: [UpcomingRun], intervalJobs: [LaunchJob]) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("Ближайшие запуски", symbol: "calendar.badge.clock") {
                    Text("плановое время")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("launchd не гарантирует запуск в точную секунду. Если Mac спал, пропущенный запуск выполняется после пробуждения.")
                }
                if runs.isEmpty {
                    Text(appState.hasLoadedOnce ? "Нет запусков по календарю в ближайшие 7 дней." : "Загрузка…")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 2) {
                        ForEach(runs) { run in
                            UpcomingRow(run: run) {
                                if let job = appState.job(withID: run.jobID) { appState.open(job) }
                            }
                        }
                    }
                }
                if !intervalJobs.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Интервальные задания")
                            .font(.subheadline.weight(.semibold))
                        Text("Время запуска StartInterval зависит от момента загрузки, поэтому не прогнозируется.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(intervalJobs) { job in
                            HStack {
                                StatusDot(health: JobHealth(job: job))
                                Text(job.displayName)
                                Spacer()
                                Text(ScheduleFormatter.describeInterval(job.definition.schedule.interval ?? 0))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func problemsCard(_ problems: [LaunchJob]) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("Требуют внимания", symbol: "stethoscope", tint: .orange)
                if problems.isEmpty {
                    Label("Проблем не обнаружено", systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(problems) { job in
                        Button {
                            appState.open(job)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                JobIcon(job: job, size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.displayName).font(.callout.weight(.semibold))
                                    Text(job.issues.first?.message ?? job.runtime.lastExit.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesCard: some View {
        let favorites = appState.favorites
        if !favorites.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader("Избранное", symbol: "star.fill", tint: .yellow)
                    ForEach(favorites) { job in
                        HStack {
                            StatusDot(health: JobHealth(job: job))
                            Button(job.displayName) { appState.open(job) }
                                .buttonStyle(.plain)
                            Spacer()
                            Button {
                                appState.runNow(job)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(appState.isBusy(job))
                            .help("Запустить сейчас")
                        }
                    }
                }
            }
        }
    }
}

extension DashboardView {
    /// Quick actions for the job that runs next (or the first favourite).
    @ViewBuilder
    func quickActionsCard(_ upcoming: [UpcomingRun]) -> some View {
        let focus = upcoming.first.flatMap { appState.job(withID: $0.jobID) } ?? appState.favorites.first
        if let job = focus {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader("Быстрые действия", symbol: "bolt.fill", tint: .yellow)
                    HStack(spacing: 10) {
                        JobIcon(job: job, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.displayName).font(.callout.weight(.semibold))
                            Text(appState.nextRun(for: job).map { "Следующий: " + ScheduleFormatter.relativeDay($0) } ?? job.label)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GlassEffectContainer(spacing: 8) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            quick("Запустить", "play.fill", .runNow, job) { appState.runNow(job) }
                                .disabled(!job.scope.isEditable || appState.isBusy(job))
                            quick("Расписание", "clock", .editSchedule, job) { appState.scheduleEditorJob = job }
                                .disabled(!job.isEditable)
                            quick("Логи", "doc.text.magnifyingglass", .viewLogs, job) { openWindow(id: "logs", value: job.id) }
                            quick("Конфигурация", "doc.badge.gearshape", .inspect, job) { appState.rawEditorJob = job }
                                .disabled(job.loadError != nil)
                        }
                    }
                }
            }
        }
    }

    private func quick(_ title: String, _ symbol: String, _ action: CLIAction, _ job: LaunchJob, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .cliHint(action, job: job)
    }

    /// Actions Orbito performed or failures it observed — never inferred run history.
    var recentActivityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("Последняя активность", symbol: "clock.arrow.circlepath", tint: .teal) {
                    Button("Все") { appState.section = .activity }
                        .buttonStyle(.borderless)
                }
                let events = appState.history.events.prefix(5)
                if events.isEmpty {
                    Text("Здесь появятся действия Orbito и замеченные ошибки. launchd сам историю запусков не хранит.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(events)) { event in
                        HStack(spacing: 8) {
                            Image(systemName: event.symbol)
                                .foregroundStyle(event.outcome == .failure ? .red : (event.outcome == .observed ? .orange : .green))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.callout)
                                Text(event.label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(event.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var subtitle: String?
    var symbol: String
    var tint: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                }
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).foregroundStyle(.secondary)
                    Text(subtitle ?? " ").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint.opacity(hovering ? 0.16 : 0.08)).interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.snappy(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct UpcomingRow: View {
    var run: UpcomingRun
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(CalendarViewModel.color(for: run.label))
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.name).font(.body.weight(.semibold))
                    Text(run.scheduleText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ScheduleFormatter.relativeDay(run.date))
                        .font(.callout.weight(.medium).monospacedDigit())
                    Text(run.date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? Color.secondary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
