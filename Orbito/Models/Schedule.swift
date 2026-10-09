import Foundation

/// One `StartCalendarInterval` dictionary. `nil` fields are wildcards,
/// exactly as launchd interprets omitted keys.
struct CalendarEntry: Hashable, Sendable {
    var minute: Int?
    var hour: Int?
    var day: Int?
    /// 0 and 7 both mean Sunday (launchd / crontab semantics).
    var weekday: Int?
    var month: Int?
    /// Keys launchd does not document for calendar entries; preserved verbatim.
    var extras: [String: PlistValue] = [:]

    static let knownKeys = ["Minute", "Hour", "Day", "Weekday", "Month"]

    init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil, extras: [String: PlistValue] = [:]) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
        self.extras = extras
    }

    var isEmpty: Bool {
        minute == nil && hour == nil && day == nil && weekday == nil && month == nil
    }

    /// Weekday normalised to 0...6 (Sunday = 0).
    var normalizedWeekday: Int? { weekday.map { $0 % 7 } }

    var plistDictionary: [String: PlistValue] {
        var dict = extras
        if let minute { dict["Minute"] = .integer(minute) }
        if let hour { dict["Hour"] = .integer(hour) }
        if let day { dict["Day"] = .integer(day) }
        if let weekday { dict["Weekday"] = .integer(weekday) }
        if let month { dict["Month"] = .integer(month) }
        return dict
    }

    /// Range violations for this entry, in user-facing form.
    var validationErrors: [String] {
        var errors: [String] = []
        if let minute, !(0...59).contains(minute) { errors.append("Minute = \(minute) вне диапазона 0–59") }
        if let hour, !(0...23).contains(hour) { errors.append("Hour = \(hour) вне диапазона 0–23") }
        if let day, !(1...31).contains(day) { errors.append("Day = \(day) вне диапазона 1–31") }
        if let weekday, !(0...7).contains(weekday) { errors.append("Weekday = \(weekday) вне диапазона 0–7") }
        if let month, !(1...12).contains(month) { errors.append("Month = \(month) вне диапазона 1–12") }
        return errors
    }
}

/// Time-based triggers of a job, mirroring launchd keys rather than cron.
struct JobSchedule: Hashable, Sendable {
    /// Entries of `StartCalendarInterval`; empty when the key is absent.
    var calendar: [CalendarEntry] = []
    /// Whether `StartCalendarInterval` was stored as an array.
    var calendarIsArray: Bool = false
    /// `StartInterval` in seconds. Relative to load time, not wall clock.
    var interval: Int?
    /// Problems found while parsing (wrong types, out-of-range values…).
    var parseWarnings: [String] = []

    var hasCalendar: Bool { !calendar.isEmpty }
    var isTimeBased: Bool { hasCalendar || interval != nil }

    static let none = JobSchedule()
}

struct TimeOfDay: Hashable, Comparable, Sendable {
    var hour: Int
    var minute: Int

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    var formatted: String { String(format: "%02d:%02d", hour, minute) }

    func date(on base: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
    }

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    init(date: Date, calendar: Calendar = .current) {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        self.hour = comps.hour ?? 0
        self.minute = comps.minute ?? 0
    }
}

enum Weekday {
    /// Display order Monday-first; values in launchd numbering (Sunday = 0).
    static let ordered: [Int] = [1, 2, 3, 4, 5, 6, 0]
    static let workdays: Set<Int> = [1, 2, 3, 4, 5]
    static let weekend: Set<Int> = [6, 0]

    static func shortName(_ value: Int) -> String {
        ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"][value % 7]
    }

    static func fullName(_ value: Int) -> String {
        ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"][value % 7]
    }

    /// English three-letter names used by systemd OnCalendar.
    static func englishShort(_ value: Int) -> String {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][value % 7]
    }

    static func monthNominative(_ value: Int) -> String {
        let names = ["январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"]
        return (1...12).contains(value) ? names[value - 1] : "\(value)"
    }

    static func monthName(_ value: Int) -> String {
        let names = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
        return (1...12).contains(value) ? names[value - 1] : "\(value)"
    }
}
