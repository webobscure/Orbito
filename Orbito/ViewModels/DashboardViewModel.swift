import Foundation

struct UpcomingRun: Identifiable, Hashable {
    var jobID: String
    var label: String
    var name: String
    var date: Date
    var scheduleText: String
    var id: String { "\(jobID)-\(date.timeIntervalSince1970)" }
}

struct DashboardStats: Equatable {
    var total = 0
    var loaded = 0
    var loadedUnknown = false
    var disabled = 0
    var withErrors = 0
    var running = 0
}

/// Pure derivations for the dashboard; no I/O.
enum DashboardViewModel {
    static func stats(for jobs: [LaunchJob]) -> DashboardStats {
        var stats = DashboardStats()
        stats.total = jobs.count
        stats.loaded = jobs.count { $0.runtime.loaded == .yes }
        stats.loadedUnknown = jobs.contains { $0.runtime.loaded == .unknown }
        stats.disabled = jobs.count { $0.isDisabled == .yes }
        stats.withErrors = jobs.count(where: \.hasErrors)
        stats.running = jobs.count { $0.runtime.pid != nil }
        return stats
    }

    /// Planned runs within `window`, only for jobs launchd will actually fire
    /// (loaded and not disabled).
    static func upcoming(_ jobs: [LaunchJob], service: ScheduleService, now: Date = .now, window: TimeInterval = 7 * 86_400, limit: Int = 12, perJob: Int = 2) -> [UpcomingRun] {
        let end = now.addingTimeInterval(window)
        var runs: [UpcomingRun] = []
        for job in jobs where job.loadError == nil && job.isDisabled != .yes && job.runtime.loaded != .no && job.definition.schedule.hasCalendar {
            let text = ScheduleFormatter.describeCalendar(job.definition.schedule.calendar)
            // A couple of runs per job keeps one frequent job from filling the list.
            for date in service.occurrences(of: job.definition.schedule, from: now, to: end, limit: perJob) {
                runs.append(UpcomingRun(jobID: job.id, label: job.label, name: job.displayName, date: date, scheduleText: text))
            }
        }
        return Array(runs.sorted { $0.date < $1.date }.prefix(limit))
    }

    static func intervalJobs(_ jobs: [LaunchJob]) -> [LaunchJob] {
        jobs.filter { $0.definition.schedule.interval != nil && $0.isDisabled != .yes && $0.loadError == nil }
    }
}
