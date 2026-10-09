import Foundation

enum ScheduleMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none, daily, weekdays, weekly, monthly, hourly, interval, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Без расписания"
        case .daily: "Ежедневно"
        case .weekdays: "По дням недели"
        case .weekly: "Еженедельно"
        case .monthly: "Ежемесячно"
        case .hourly: "Каждый час"
        case .interval: "Каждые N минут"
        case .advanced: "Расширенный"
        }
    }

    var symbol: String {
        switch self {
        case .none: "minus.circle"
        case .daily: "sun.max"
        case .weekdays: "calendar.day.timeline.left"
        case .weekly: "calendar"
        case .monthly: "calendar.badge.clock"
        case .hourly: "clock"
        case .interval: "timer"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// Recognised shapes of a `StartCalendarInterval` list.
enum CalendarPattern: Equatable {
    case daily([TimeOfDay])
    case weekdays(Set<Int>, [TimeOfDay])
    case monthly(Int, [TimeOfDay])
    case hourly(Int)
    case none
}

struct EditableEntry: Identifiable, Hashable, Sendable {
    var id = UUID()
    var entry: CalendarEntry
}

/// Editable form state of a schedule. Converts to and from `JobSchedule`
/// without touching rules the user did not change.
struct ScheduleDraft: Hashable, Sendable {
    var mode: ScheduleMode = .daily
    var times: [TimeOfDay] = [TimeOfDay(hour: 8, minute: 0)]
    var weekdays: Set<Int> = Weekday.workdays
    var weeklyDay: Int = 1
    var monthDay: Int = 1
    var hourlyMinute: Int = 0
    var intervalMinutes: Int = 30
    var advancedEntries: [EditableEntry] = []
    var advancedIntervalSeconds: Int?
    let original: JobSchedule

    init(schedule: JobSchedule = .none) {
        original = schedule
        advancedEntries = schedule.calendar.map { EditableEntry(entry: $0) }
        advancedIntervalSeconds = schedule.interval

        switch (schedule.hasCalendar, schedule.interval) {
        case (false, nil):
            mode = .none
        case (false, let seconds?):
            if seconds % 60 == 0 {
                mode = .interval
                intervalMinutes = seconds / 60
            } else {
                mode = .advanced
            }
        case (true, .some):
            mode = .advanced
        case (true, nil):
            switch Self.classify(schedule.calendar) {
            case .daily(let t):
                mode = .daily; times = t
            case .weekdays(let days, let t):
                times = t
                if days.count == 1, let day = days.first { mode = .weekly; weeklyDay = day }
                else { mode = .weekdays; weekdays = days }
            case .monthly(let day, let t):
                mode = .monthly; monthDay = day; times = t
            case .hourly(let minute):
                mode = .hourly; hourlyMinute = minute
            case .none:
                mode = .advanced
            }
        }
        if !schedule.parseWarnings.isEmpty { mode = .advanced }
    }

    // MARK: Classification

    static func classify(_ entries: [CalendarEntry]) -> CalendarPattern {
        guard !entries.isEmpty,
              entries.allSatisfy({ $0.extras.isEmpty && $0.month == nil && $0.validationErrors.isEmpty })
        else { return .none }

        if entries.count == 1, let entry = entries.first,
           let minute = entry.minute, entry.hour == nil, entry.day == nil, entry.weekday == nil {
            return .hourly(minute)
        }

        guard entries.allSatisfy({ $0.hour != nil && $0.minute != nil }) else { return .none }
        let times = Set(entries.map { TimeOfDay(hour: $0.hour!, minute: $0.minute!) })
        let sortedTimes = times.sorted()

        if entries.allSatisfy({ $0.day == nil && $0.weekday == nil }) {
            return entries.count == times.count ? .daily(sortedTimes) : .none
        }
        if entries.allSatisfy({ $0.day == nil && $0.weekday != nil }) {
            let days = Set(entries.compactMap(\.normalizedWeekday))
            let pairs = Set(entries.map { "\($0.normalizedWeekday!)-\($0.hour!)-\($0.minute!)" })
            guard pairs.count == entries.count, pairs.count == days.count * times.count else { return .none }
            return .weekdays(days, sortedTimes)
        }
        if entries.allSatisfy({ $0.weekday == nil && $0.day != nil }) {
            let days = Set(entries.compactMap(\.day))
            guard days.count == 1, let day = days.first, entries.count == times.count else { return .none }
            return .monthly(day, sortedTimes)
        }
        return .none
    }

    // MARK: Building

    var validationErrors: [String] {
        var errors: [String] = []
        switch mode {
        case .daily, .weekdays, .weekly, .monthly:
            if times.isEmpty { errors.append("Добавьте хотя бы одно время запуска.") }
        default: break
        }
        switch mode {
        case .weekdays where weekdays.isEmpty:
            errors.append("Выберите хотя бы один день недели.")
        case .monthly where !(1...31).contains(monthDay):
            errors.append("Число месяца должно быть от 1 до 31.")
        case .hourly where !(0...59).contains(hourlyMinute):
            errors.append("Минута должна быть от 0 до 59.")
        case .interval where intervalMinutes < 1:
            errors.append("Интервал должен быть не меньше 1 минуты.")
        case .advanced:
            for (index, item) in advancedEntries.enumerated() {
                errors += item.entry.validationErrors.map { "Правило \(index + 1): \($0)" }
            }
            if let seconds = advancedIntervalSeconds, seconds < 1 {
                errors.append("StartInterval должен быть положительным.")
            }
        default: break
        }
        return errors
    }

    var warnings: [String] {
        var warnings: [String] = []
        if mode == .monthly, monthDay > 28 {
            warnings.append("В месяцах, где нет \(monthDay)-го числа, задание не запустится.")
        }
        if mode == .interval || (mode == .advanced && advancedIntervalSeconds != nil) {
            warnings.append("StartInterval отсчитывается от момента загрузки задания, а не от начала часа. Если Mac спит, пропущенные запуски не повторяются.")
        }
        return warnings
    }

    func build() throws -> JobSchedule {
        let errors = validationErrors
        guard errors.isEmpty else { throw OrbitoError.scheduleInvalid(errors) }

        var schedule = JobSchedule()
        let sortedTimes = Array(Set(times)).sorted()
        switch mode {
        case .none:
            break
        case .daily:
            schedule.calendar = sortedTimes.map { CalendarEntry(minute: $0.minute, hour: $0.hour) }
        case .weekdays:
            schedule.calendar = Weekday.ordered.filter(weekdays.contains).flatMap { day in
                sortedTimes.map { CalendarEntry(minute: $0.minute, hour: $0.hour, weekday: day) }
            }
        case .weekly:
            schedule.calendar = sortedTimes.map { CalendarEntry(minute: $0.minute, hour: $0.hour, weekday: weeklyDay) }
        case .monthly:
            schedule.calendar = sortedTimes.map { CalendarEntry(minute: $0.minute, hour: $0.hour, day: monthDay) }
        case .hourly:
            schedule.calendar = [CalendarEntry(minute: hourlyMinute)]
        case .interval:
            schedule.interval = intervalMinutes * 60
        case .advanced:
            schedule.calendar = advancedEntries.map(\.entry)
            schedule.interval = advancedIntervalSeconds
        }

        // Unchanged rules keep their exact original encoding (e.g. Weekday 7).
        if Self.normalizedSet(schedule.calendar) == Self.normalizedSet(original.calendar),
           schedule.calendar.count == original.calendar.count {
            schedule.calendar = original.calendar
        }
        schedule.calendarIsArray = schedule.calendar.count > 1 || (schedule.calendar.count == 1 && original.calendarIsArray)
        return schedule
    }

    private static func normalizedSet(_ entries: [CalendarEntry]) -> Set<CalendarEntry> {
        Set(entries.map { entry in
            var copy = entry
            copy.weekday = entry.normalizedWeekday
            return copy
        })
    }
}
