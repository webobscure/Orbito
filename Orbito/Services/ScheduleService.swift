import Foundation

/// Computes planned run times from launchd calendar rules.
///
/// Semantics follow launchd: omitted fields are wildcards; when both `Day`
/// and `Weekday` are set the job fires if *either* matches (crontab rule).
/// Local wall-clock times that do not exist (DST spring-forward) are skipped,
/// repeated times (fall-back) fire once at the first occurrence.
/// `StartInterval` has no wall-clock anchor and is never projected.
struct ScheduleService: Sendable {
    var calendar: Calendar = .current
    /// Search horizon for rare rules (e.g. Feb 29).
    var horizonDays = 366 * 4 + 1

    func nextRun(of entry: CalendarEntry, after date: Date) -> Date? {
        guard entry.validationErrors.isEmpty else { return nil }
        guard let start = calendar.dateInterval(of: .minute, for: date)?.end else { return nil }
        let startDay = calendar.startOfDay(for: start)

        for offset in 0..<horizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { return nil }
            let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let year = comps.year, let month = comps.month, let dom = comps.day, let wd = comps.weekday else { continue }
            guard matchesDay(entry, month: month, day: dom, weekday: wd - 1) else { continue }

            let firstDay = offset == 0
            let startTime = calendar.dateComponents([.hour, .minute], from: start)
            let hours = entry.hour.map { [$0] } ?? Array(0...23)
            let minutes = entry.minute.map { [$0] } ?? Array(0...59)
            for hour in hours {
                if firstDay, let startHour = startTime.hour, hour < startHour { continue }
                for minute in minutes {
                    if firstDay, let startHour = startTime.hour, let startMinute = startTime.minute,
                       (hour, minute) < (startHour, startMinute) { continue }
                    let wanted = DateComponents(year: year, month: month, day: dom, hour: hour, minute: minute)
                    guard let candidate = calendar.date(from: wanted) else { continue }
                    // Reject times that don't exist locally (DST gap shifts them).
                    let back = calendar.dateComponents([.day, .hour, .minute], from: candidate)
                    guard back.day == dom, back.hour == hour, back.minute == minute else { continue }
                    if candidate >= start { return candidate }
                }
            }
        }
        return nil
    }

    private func matchesDay(_ entry: CalendarEntry, month: Int, day: Int, weekday: Int) -> Bool {
        if let wantedMonth = entry.month, wantedMonth != month { return false }
        let dayMatches = entry.day.map { $0 == day }
        let weekdayMatches = entry.normalizedWeekday.map { $0 == weekday }
        switch (dayMatches, weekdayMatches) {
        case (nil, nil): return true
        case (let d?, nil): return d
        case (nil, let w?): return w
        case (let d?, let w?): return d || w
        }
    }

    func nextRun(of schedule: JobSchedule, after date: Date) -> Date? {
        schedule.calendar.compactMap { nextRun(of: $0, after: date) }.min()
    }

    /// Upcoming planned runs, merged across entries, de-duplicated.
    func occurrences(of schedule: JobSchedule, from start: Date, to end: Date, limit: Int = 500) -> [Date] {
        var result = Set<Date>()
        for entry in schedule.calendar {
            var cursor = start.addingTimeInterval(-1)
            var produced = 0
            while produced < limit, let next = nextRun(of: entry, after: cursor), next < end {
                result.insert(next)
                cursor = next
                produced += 1
            }
        }
        return result.sorted().prefix(limit).map { $0 }
    }

    func nextRuns(of schedule: JobSchedule, after date: Date, count: Int) -> [Date] {
        var result: [Date] = []
        var cursor = date
        while result.count < count, let next = nextRun(of: schedule, after: cursor) {
            result.append(next)
            cursor = next
        }
        return result
    }

    // MARK: - Analysis

    /// Warnings about ambiguous or surprising rules.
    func warnings(for schedule: JobSchedule) -> [String] {
        var warnings = schedule.parseWarnings
        for (index, entry) in schedule.calendar.enumerated() {
            let name = schedule.calendar.count > 1 ? "Правило \(index + 1): " : ""
            if entry.isEmpty && entry.extras.isEmpty {
                warnings.append("\(name)пустой словарь — launchd запускает задание каждую минуту.")
            } else if entry.minute == nil && entry.validationErrors.isEmpty && !entry.isEmpty {
                warnings.append("\(name)не указана минута — задание будет запускаться каждую минуту в подходящие часы.")
            }
            if entry.day != nil && entry.weekday != nil {
                warnings.append("\(name)указаны и Day, и Weekday — launchd запустит задание, если совпадёт любое из условий.")
            }
            if entry.validationErrors.isEmpty, !entry.isEmpty, nextRun(of: entry, after: .now) == nil {
                warnings.append("\(name)правило никогда не сработает (например, 31-е число в месяце из 30 дней).")
            }
        }
        if schedule.interval != nil && schedule.hasCalendar {
            warnings.append("Заданы и StartInterval, и StartCalendarInterval — сработают оба триггера.")
        }
        return Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings
    }
}

// MARK: - Human-readable descriptions

enum ScheduleFormatter {
    static func describe(_ definition: JobDefinition) -> String {
        let schedule = definition.schedule
        var parts: [String] = []
        if schedule.hasCalendar { parts.append(describeCalendar(schedule.calendar)) }
        if let interval = schedule.interval { parts.append(describeInterval(interval)) }
        if parts.isEmpty {
            if definition.keepAlive.isActive { return "Постоянно (KeepAlive)" }
            if definition.runAtLoad { return "При загрузке (RunAtLoad)" }
            if !definition.otherTriggers.isEmpty { return "По событию: " + definition.otherTriggers.joined(separator: ", ") }
            return "Без расписания"
        }
        if definition.runAtLoad { parts.append("и при загрузке") }
        return parts.joined(separator: "; ")
    }

    static func describeInterval(_ seconds: Int) -> String {
        if seconds % 3600 == 0 {
            let hours = seconds / 3600
            return hours == 1 ? "Каждый час (от момента загрузки)" : "Каждые \(hours) ч (от момента загрузки)"
        }
        if seconds % 60 == 0 { return "Каждые \(seconds / 60) мин" }
        return "Каждые \(seconds) с"
    }

    static func describeCalendar(_ entries: [CalendarEntry]) -> String {
        switch ScheduleDraft.classify(entries) {
        case .daily(let times):
            return "Ежедневно в " + times.map(\.formatted).joined(separator: ", ")
        case .weekdays(let days, let times):
            return describeDays(days) + " в " + times.map(\.formatted).joined(separator: ", ")
        case .monthly(let day, let times):
            return "Ежемесячно, \(day)-го числа в " + times.map(\.formatted).joined(separator: ", ")
        case .hourly(let minute):
            return String(format: "Каждый час в :%02d", minute)
        case .none:
            return entries.count == 1 ? describe(entries[0]) : "\(entries.count) правил: " + entries.map(describe).joined(separator: "; ")
        }
    }

    static func describeDays(_ days: Set<Int>) -> String {
        let normalized = Set(days.map { $0 % 7 })
        if normalized == Weekday.workdays { return "По будням" }
        if normalized == Weekday.weekend { return "По выходным" }
        if normalized.count == 7 { return "Ежедневно" }
        if normalized.count == 1, let day = normalized.first { return "Каждый " + Weekday.fullName(day) }
        return Weekday.ordered.filter(normalized.contains).map(Weekday.shortName).joined(separator: ", ")
    }

    /// Generic description of a single entry with wildcards.
    static func describe(_ entry: CalendarEntry) -> String {
        if entry.isEmpty { return "Каждую минуту" }
        var parts: [String] = []
        if let month = entry.month {
            parts.append(entry.day.map { "\($0) \(Weekday.monthName(month))" } ?? "весь \(Weekday.monthNominative(month))")
        } else if let day = entry.day {
            parts.append("\(day)-го числа")
        }
        if let weekday = entry.weekday {
            parts.append((entry.day != nil ? "или " : "") + Weekday.fullName(weekday))
        }
        switch (entry.hour, entry.minute) {
        case let (hour?, minute?): parts.append("в " + TimeOfDay(hour: hour, minute: minute).formatted)
        case let (hour?, nil): parts.append(String(format: "каждую минуту с %02d:00 до %02d:59", hour, hour))
        case let (nil, minute?): parts.append(String(format: "каждый час в :%02d", minute))
        case (nil, nil): parts.append("каждую минуту")
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func relativeDay(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Сегодня, \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Завтра, \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
