import Foundation
import Testing
@testable import Orbito

@Suite("Schedule editing")
struct ScheduleDraftTests {
    @Test func dailyBuildsDictionary() throws {
        var draft = ScheduleDraft()
        draft.mode = .daily
        draft.times = [TimeOfDay(hour: 8, minute: 0)]
        let schedule = try draft.build()
        #expect(schedule.calendar == [CalendarEntry(minute: 0, hour: 8)])
        #expect(!schedule.calendarIsArray)

        let dict = PlistService.applying(schedule, to: [:])
        #expect(dict["StartCalendarInterval"] == .dictionary(["Hour": .integer(8), "Minute": .integer(0)]))
        let xml = PlistService.xmlString(dict)
        #expect(xml.contains("<key>Hour</key>\n\t\t<integer>8</integer>"))
    }

    @Test func changeNoonToEight() throws {
        let original = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 12)])
        var draft = ScheduleDraft(schedule: original)
        #expect(draft.mode == .daily)
        #expect(draft.times == [TimeOfDay(hour: 12, minute: 0)])
        draft.times = [TimeOfDay(hour: 8, minute: 0)]
        let built = try draft.build()
        #expect(built.calendar == [CalendarEntry(minute: 0, hour: 8)])
    }

    @Test func weekdaysBuildArray() throws {
        var draft = ScheduleDraft()
        draft.mode = .weekdays
        draft.weekdays = Weekday.workdays
        draft.times = [TimeOfDay(hour: 9, minute: 30)]
        let schedule = try draft.build()
        #expect(schedule.calendarIsArray)
        #expect(schedule.calendar.count == 5)
        #expect(schedule.calendar.map(\.weekday) == [1, 2, 3, 4, 5])
        #expect(ScheduleFormatter.describeCalendar(schedule.calendar) == "По будням в 09:30")
    }

    @Test func weeklySingleDay() throws {
        var draft = ScheduleDraft()
        draft.mode = .weekly
        draft.weeklyDay = 0
        draft.times = [TimeOfDay(hour: 10, minute: 0)]
        let schedule = try draft.build()
        #expect(schedule.calendar == [CalendarEntry(minute: 0, hour: 10, weekday: 0)])
        #expect(ScheduleDraft(schedule: schedule).mode == .weekly)
    }

    @Test func multipleRunsPerDay() throws {
        var draft = ScheduleDraft()
        draft.mode = .daily
        draft.times = [TimeOfDay(hour: 20, minute: 0), TimeOfDay(hour: 8, minute: 0)]
        let schedule = try draft.build()
        #expect(schedule.calendarIsArray)
        #expect(schedule.calendar == [CalendarEntry(minute: 0, hour: 8), CalendarEntry(minute: 0, hour: 20)])
        let reparsed = ScheduleDraft(schedule: schedule)
        #expect(reparsed.mode == .daily)
        #expect(reparsed.times.count == 2)
        #expect(ScheduleFormatter.describeCalendar(schedule.calendar) == "Ежедневно в 08:00, 20:00")
    }

    @Test func classifyFromArrayFixture() throws {
        let (dict, _) = try PlistService.decode(Data(Fixtures.array.utf8), path: "x")
        let draft = ScheduleDraft(schedule: PlistService.schedule(from: dict))
        #expect(draft.mode == .weekdays)
        #expect(draft.weekdays == [1, 3, 5])
        #expect(draft.times == [TimeOfDay(hour: 9, minute: 0)])
    }

    @Test func monthlyAndHourly() throws {
        var monthly = ScheduleDraft()
        monthly.mode = .monthly
        monthly.monthDay = 15
        monthly.times = [TimeOfDay(hour: 6, minute: 5)]
        #expect(try monthly.build().calendar == [CalendarEntry(minute: 5, hour: 6, day: 15)])

        var hourly = ScheduleDraft()
        hourly.mode = .hourly
        hourly.hourlyMinute = 15
        #expect(try hourly.build().calendar == [CalendarEntry(minute: 15)])
    }

    @Test func intervalUsesStartInterval() throws {
        var draft = ScheduleDraft()
        draft.mode = .interval
        draft.intervalMinutes = 15
        let schedule = try draft.build()
        #expect(schedule.interval == 900)
        #expect(schedule.calendar.isEmpty)
        #expect(!draft.warnings.isEmpty)
    }

    @Test func irregularScheduleFallsBackToAdvanced() {
        let schedule = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8, weekday: 1), CalendarEntry(minute: 30, hour: 17, weekday: 5)], calendarIsArray: true)
        #expect(ScheduleDraft(schedule: schedule).mode == .advanced)
        let withMonth = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8, month: 3)])
        #expect(ScheduleDraft(schedule: withMonth).mode == .advanced)
        let both = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)], interval: 60)
        #expect(ScheduleDraft(schedule: both).mode == .advanced)
    }

    @Test func advancedRoundTripPreservesEverything() throws {
        let original = JobSchedule(
            calendar: [CalendarEntry(minute: 0, hour: 8, weekday: 7, extras: ["Foo": .string("bar")]), CalendarEntry(day: 1)],
            calendarIsArray: true, interval: 7200
        )
        let draft = ScheduleDraft(schedule: original)
        #expect(draft.mode == .advanced)
        let built = try draft.build()
        #expect(built.calendar == original.calendar)
        #expect(built.interval == 7200)
        #expect(built.calendarIsArray)
    }

    @Test func unchangedWeekdaySevenIsPreserved() throws {
        let original = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 10, weekday: 7)])
        let draft = ScheduleDraft(schedule: original)
        #expect(draft.mode == .weekly)
        #expect(try draft.build().calendar.first?.weekday == 7)
    }

    @Test func validationErrors() {
        var draft = ScheduleDraft()
        draft.mode = .weekdays
        draft.weekdays = []
        #expect(throws: OrbitoError.self) { try draft.build() }

        draft.mode = .advanced
        draft.advancedEntries = [EditableEntry(entry: CalendarEntry(minute: 75, hour: 25))]
        #expect(draft.validationErrors.count == 2)

        draft.mode = .interval
        draft.intervalMinutes = 0
        #expect(!draft.validationErrors.isEmpty)
    }

    @Test func singleEntryArrayKeepsArrayForm() throws {
        let original = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 12)], calendarIsArray: true)
        var draft = ScheduleDraft(schedule: original)
        draft.times = [TimeOfDay(hour: 8, minute: 0)]
        let built = try draft.build()
        #expect(built.calendarIsArray)
        #expect(PlistService.applying(built, to: [:])["StartCalendarInterval"] == .array([.dictionary(["Hour": .integer(8), "Minute": .integer(0)])]))
    }
}

@Suite("Next run calculation")
struct NextRunTests {
    static func calendar(_ tz: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        return calendar
    }

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    let cal = NextRunTests.calendar("Europe/Moscow")
    var service: ScheduleService { ScheduleService(calendar: cal) }

    @Test func dailyLaterToday() {
        let now = Self.date(2026, 10, 8, 7, 30, in: cal)
        let next = service.nextRun(of: CalendarEntry(minute: 0, hour: 8), after: now)
        #expect(next == Self.date(2026, 10, 8, 8, 0, in: cal))
    }

    @Test func dailyTomorrowWhenPassed() {
        let now = Self.date(2026, 10, 8, 8, 0, in: cal)
        let next = service.nextRun(of: CalendarEntry(minute: 0, hour: 8), after: now)
        #expect(next == Self.date(2026, 10, 9, 8, 0, in: cal))
    }

    @Test func weekly() {
        // 2026-10-08 is a Thursday; next Monday is 2026-10-12.
        let now = Self.date(2026, 10, 8, 12, 0, in: cal)
        let next = service.nextRun(of: CalendarEntry(minute: 0, hour: 9, weekday: 1), after: now)
        #expect(next == Self.date(2026, 10, 12, 9, 0, in: cal))
        let sunday7 = service.nextRun(of: CalendarEntry(minute: 0, hour: 9, weekday: 7), after: now)
        #expect(sunday7 == Self.date(2026, 10, 11, 9, 0, in: cal))
    }

    @Test func multipleEntriesMerge() {
        let schedule = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 20), CalendarEntry(minute: 0, hour: 8)], calendarIsArray: true)
        let now = Self.date(2026, 10, 8, 9, 0, in: cal)
        let runs = service.nextRuns(of: schedule, after: now, count: 3)
        #expect(runs == [
            Self.date(2026, 10, 8, 20, 0, in: cal),
            Self.date(2026, 10, 9, 8, 0, in: cal),
            Self.date(2026, 10, 9, 20, 0, in: cal),
        ])
    }

    @Test func hourlyWildcardHour() {
        let now = Self.date(2026, 10, 8, 10, 20, in: cal)
        #expect(service.nextRun(of: CalendarEntry(minute: 15), after: now) == Self.date(2026, 10, 8, 11, 15, in: cal))
    }

    @Test func missingMinuteMeansEveryMinute() {
        let now = Self.date(2026, 10, 8, 8, 10, in: cal)
        #expect(service.nextRun(of: CalendarEntry(hour: 8), after: now) == Self.date(2026, 10, 8, 8, 11, in: cal))
        #expect(service.warnings(for: JobSchedule(calendar: [CalendarEntry(hour: 8)])).contains { $0.contains("каждую минуту") })
    }

    @Test func monthlySkipsShortMonths() {
        let now = Self.date(2026, 2, 1, 0, 0, in: cal)
        #expect(service.nextRun(of: CalendarEntry(minute: 0, hour: 0, day: 31), after: now) == Self.date(2026, 3, 31, 0, 0, in: cal))
    }

    @Test func dayOrWeekdaySemantics() {
        // Day 15 OR Monday: from Thu 2026-10-08 the earliest is Mon 2026-10-12.
        let now = Self.date(2026, 10, 8, 12, 0, in: cal)
        let entry = CalendarEntry(minute: 0, hour: 9, day: 15, weekday: 1)
        #expect(service.nextRun(of: entry, after: now) == Self.date(2026, 10, 12, 9, 0, in: cal))
    }

    @Test func impossibleDateNeverFires() {
        let entry = CalendarEntry(minute: 0, hour: 0, day: 31, month: 2)
        #expect(service.nextRun(of: entry, after: .now) == nil)
        #expect(service.warnings(for: JobSchedule(calendar: [entry])).contains { $0.contains("никогда") })
    }

    @Test func invalidEntryReturnsNil() {
        #expect(service.nextRun(of: CalendarEntry(minute: 99), after: .now) == nil)
    }

    @Test func dstSpringForwardSkipsMissingTime() {
        let ny = Self.calendar("America/New_York")
        let service = ScheduleService(calendar: ny)
        // 2026-03-08 02:00 → 03:00 in New York; 02:30 does not exist that day.
        let now = Self.date(2026, 3, 7, 12, 0, in: ny)
        let next = service.nextRun(of: CalendarEntry(minute: 30, hour: 2), after: now)
        #expect(next == Self.date(2026, 3, 9, 2, 30, in: ny))
    }

    @Test func dstFallBackFiresOnce() {
        let ny = Self.calendar("America/New_York")
        let service = ScheduleService(calendar: ny)
        // 2026-11-01 01:30 happens twice; only one run is planned that day.
        let start = Self.date(2026, 11, 1, 0, 0, in: ny)
        let end = Self.date(2026, 11, 2, 0, 0, in: ny)
        let runs = service.occurrences(of: JobSchedule(calendar: [CalendarEntry(minute: 30, hour: 1)]), from: start, to: end)
        #expect(runs.count == 1)
    }

    @Test func intervalIsNotProjected() {
        #expect(service.nextRun(of: JobSchedule(interval: 60), after: .now) == nil)
    }

    @Test func occurrencesRespectLimit() {
        let now = Self.date(2026, 10, 8, 0, 0, in: cal)
        let runs = service.occurrences(of: JobSchedule(calendar: [CalendarEntry()]), from: now, to: now.addingTimeInterval(86_400), limit: 50)
        #expect(runs.count == 50)
        #expect(runs.first == now)
    }
}
