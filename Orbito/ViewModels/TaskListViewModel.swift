import Foundation

enum TaskFilter: String, CaseIterable, Identifiable {
    case all, loaded, disabled, errors, scheduled, unscheduled
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .loaded: "Загруженные"
        case .disabled: "Отключённые"
        case .errors: "С ошибками"
        case .scheduled: "С расписанием"
        case .unscheduled: "Без расписания"
        }
    }

    func matches(_ job: LaunchJob) -> Bool {
        switch self {
        case .all: true
        case .loaded: job.runtime.loaded == .yes
        case .disabled: job.isDisabled == .yes
        case .errors: job.hasErrors
        case .scheduled: job.definition.schedule.isTimeBased
        case .unscheduled: !job.definition.schedule.isTimeBased
        }
    }
}

enum TaskSort: String, CaseIterable, Identifiable {
    case name, nextRun, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "По названию"
        case .nextRun: "По следующему запуску"
        case .status: "По состоянию"
        }
    }
}

@MainActor
@Observable
final class TaskListViewModel {
    var searchText = ""
    var filter: TaskFilter = .all
    var sort: TaskSort = .name
    var scopeFilter: JobScope?

    func visibleJobs(_ jobs: [LaunchJob], section: SidebarSection, nextRun: (LaunchJob) -> Date?) -> [LaunchJob] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = jobs.filter { job in
            guard Self.sectionMatches(section, job), filter.matches(job) else { return false }
            if let scopeFilter, job.scope != scopeFilter { return false }
            return query.isEmpty || job.searchableText.lowercased().contains(query)
        }
        switch sort {
        case .name:
            return filtered.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .status:
            return filtered.sorted {
                let a = JobHealth(job: $0).sortRank, b = JobHealth(job: $1).sortRank
                return a != b ? a < b : $0.displayName < $1.displayName
            }
        case .nextRun:
            let dates = Dictionary(filtered.map { ($0.id, nextRun($0) ?? .distantFuture) }, uniquingKeysWith: { a, _ in a })
            return filtered.sorted { dates[$0.id]! < dates[$1.id]! }
        }
    }

    static func sectionMatches(_ section: SidebarSection, _ job: LaunchJob) -> Bool {
        switch section {
        case .active: job.runtime.loaded == .yes && job.isDisabled != .yes
        case .disabled: job.isDisabled == .yes
        case .errors: job.hasErrors
        default: true
        }
    }

    var isFiltering: Bool { !searchText.isEmpty || filter != .all || scopeFilter != nil }

    func reset() {
        searchText = ""
        filter = .all
        scopeFilter = nil
    }
}
