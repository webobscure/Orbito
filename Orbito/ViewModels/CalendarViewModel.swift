import Foundation
import SwiftUI

enum CalendarScale: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "День"
        case .week: "Неделя"
        case .month: "Месяц"
        }
    }
}

struct CalendarEvent: Identifiable, Hashable {
    var jobID: String
    var label: String
    var name: String
    var date: Date
    var color: Color
    var isLoaded: Bool
    var id: String { "\(jobID)-\(date.timeIntervalSince1970)" }
}

@MainActor
@Observable
final class CalendarViewModel {
    var scale: CalendarScale = .week
    var anchor: Date = .now
    var calendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Visible range for the current scale, in the local time zone.
    var range: DateInterval {
        switch scale {
        case .day:
            return calendar.dateInterval(of: .day, for: anchor) ?? DateInterval(start: anchor, duration: 86_400)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: anchor) ?? DateInterval(start: anchor, duration: 7 * 86_400)
        case .month:
            // Full weeks covering the month, for a rectangular grid.
            guard let month = calendar.dateInterval(of: .month, for: anchor),
                  let first = calendar.dateInterval(of: .weekOfYear, for: month.start),
                  let last = calendar.dateInterval(of: .weekOfYear, for: month.end.addingTimeInterval(-1))
            else { return DateInterval(start: anchor, duration: 31 * 86_400) }
            return DateInterval(start: first.start, end: last.end)
        }
    }

    var title: String {
        switch scale {
        case .day: return anchor.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            let r = range
            return "\(r.start.formatted(.dateTime.day().month(.abbreviated))) – \(r.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month: return anchor.formatted(.dateTime.month(.wide).year()).capitalized
        }
    }

    func step(_ direction: Int) {
        let component: Calendar.Component = switch scale {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        anchor = calendar.date(byAdding: component, value: direction, to: anchor) ?? anchor
    }

    func today() { anchor = .now }

    var days: [Date] {
        var result: [Date] = []
        var cursor = range.start
        while cursor < range.end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Planned runs in the visible range. Per-job cap keeps every-minute jobs readable.
    func events(for jobs: [LaunchJob], service: ScheduleService, perJobLimit: Int = 400) -> [CalendarEvent] {
        let r = range
        var events: [CalendarEvent] = []
        for job in jobs where job.loadError == nil && job.isDisabled != .yes && job.definition.schedule.hasCalendar {
            let color = Self.color(for: job.label)
            for date in service.occurrences(of: job.definition.schedule, from: r.start, to: r.end, limit: perJobLimit) {
                events.append(CalendarEvent(jobID: job.id, label: job.label, name: job.displayName, date: date, color: color, isLoaded: job.runtime.loaded == .yes))
            }
        }
        return events.sorted { $0.date < $1.date }
    }

    static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .red, .brown, .yellow]

    /// Stable colour per label (FNV-1a hash; `hashValue` is randomised per launch).
    static func color(for label: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in label.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
