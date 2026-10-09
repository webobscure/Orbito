import Foundation
import Testing
@testable import Orbito

@Suite("Plist reading and writing")
struct PlistServiceTests {
    @Test func readsDailyPlist() throws {
        let tmp = try TempDir()
        let url = try tmp.write("a.plist", Fixtures.daily)
        let (dict, format) = try PlistService.read(url)
        let def = PlistService.definition(from: dict)

        #expect(format == .xml)
        #expect(def.label == "com.onkron.market-prices")
        #expect(def.programArguments == ["/usr/bin/caffeinate", "-i", "/Users/user/Scripts/nightly-prices.sh"])
        #expect(def.executablePath == "/usr/bin/caffeinate")
        #expect(def.scriptPath == "/Users/user/Scripts/nightly-prices.sh")
        #expect(def.standardOutPath == "/tmp/out.log")
        #expect(def.schedule.calendar == [CalendarEntry(minute: 0, hour: 12)])
        #expect(def.schedule.calendarIsArray == false)
        #expect(def.schedule.interval == nil)
    }

    @Test func calendarIntervalAsDictionary() throws {
        let (dict, _) = try PlistService.decode(Data(Fixtures.daily.utf8), path: "x")
        let schedule = PlistService.schedule(from: dict)
        #expect(schedule.calendar.count == 1)
        #expect(!schedule.calendarIsArray)
        #expect(schedule.parseWarnings.isEmpty)
    }

    @Test func calendarIntervalAsArray() throws {
        let (dict, _) = try PlistService.decode(Data(Fixtures.array.utf8), path: "x")
        let schedule = PlistService.schedule(from: dict)
        #expect(schedule.calendarIsArray)
        #expect(schedule.calendar.map(\.weekday) == [1, 3, 5])
        #expect(schedule.calendar.allSatisfy { $0.hour == 9 && $0.minute == 0 })
        #expect(PlistService.definition(from: dict).program == "/bin/echo")
    }

    @Test func startInterval() throws {
        let (dict, _) = try PlistService.decode(Data(Fixtures.interval.utf8), path: "x")
        let def = PlistService.definition(from: dict)
        #expect(def.schedule.interval == 1800)
        #expect(def.schedule.calendar.isEmpty)
        #expect(def.runAtLoad)
        #expect(ScheduleFormatter.describeInterval(1800) == "Каждые 30 мин")
    }

    @Test func wrongTypesProduceWarnings() throws {
        let dict: [String: PlistValue] = [
            "Label": .string("x"),
            "StartInterval": .string("60"),
            "StartCalendarInterval": .dictionary(["Hour": .string("8"), "Minute": .integer(0), "Second": .integer(3)]),
        ]
        let schedule = PlistService.schedule(from: dict)
        #expect(schedule.interval == nil)
        #expect(schedule.calendar.first?.hour == nil)
        #expect(schedule.parseWarnings.count >= 3)
        // Unknown and mistyped keys are retained for round-tripping.
        #expect(schedule.calendar.first?.extras["Second"] == .integer(3))
        #expect(schedule.calendar.first?.extras["Hour"] == .string("8"))
    }

    @Test func savingPreservesUnknownKeys() throws {
        let tmp = try TempDir()
        let url = try tmp.write("a.plist", Fixtures.daily)
        let (dict, format) = try PlistService.read(url)

        var schedule = PlistService.schedule(from: dict)
        schedule.calendar[0].hour = 8
        let updated = PlistService.applying(schedule, to: dict)
        try PlistService.write(updated, format: format, to: url, allowOverwrite: true)

        let (reread, _) = try PlistService.read(url)
        #expect(reread["X-Custom-Key"] == dict["X-Custom-Key"])
        #expect(reread["Nice"] == .integer(5))
        #expect(reread["ProgramArguments"] == dict["ProgramArguments"])
        #expect(reread["StartCalendarInterval"] == .dictionary(["Hour": .integer(8), "Minute": .integer(0)]))
        // Only the schedule key changed.
        var expected = dict
        expected["StartCalendarInterval"] = .dictionary(["Hour": .integer(8), "Minute": .integer(0)])
        #expect(reread == expected)
    }

    @Test func booleansAndRealsRoundTrip() throws {
        let dict: [String: PlistValue] = ["Label": .string("x"), "B": .bool(true), "I": .integer(1), "R": .real(1.5), "D": .data(Data([1, 2]))]
        let data = try PlistService.encode(dict, format: .xml)
        let decoded = try PlistService.decode(data, path: "x").dict
        #expect(decoded == dict)
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains("<true/>"))
        #expect(xml.contains("<integer>1</integer>"))
    }

    @Test func binaryFormatIsPreserved() throws {
        let tmp = try TempDir()
        let dict: [String: PlistValue] = ["Label": .string("bin"), "StartInterval": .integer(60)]
        let url = tmp.url.appending(path: "bin.plist")
        try PlistService.write(dict, format: .binary, to: url, allowOverwrite: false)
        let (read, format) = try PlistService.read(url)
        #expect(format == .binary)
        #expect(read == dict)
    }

    @Test func refusesToOverwriteWhenNotAllowed() throws {
        let tmp = try TempDir()
        let url = try tmp.write("exists.plist", Fixtures.daily)
        #expect(throws: OrbitoError.self) {
            try PlistService.write(["Label": .string("x")], format: .xml, to: url, allowOverwrite: false)
        }
        // Original untouched.
        #expect(try String(contentsOf: url, encoding: .utf8) == Fixtures.daily)
    }

    @Test func invalidPlistThrows() {
        #expect(throws: OrbitoError.self) {
            try PlistService.decode(Data("<plist><dict><key>broken".utf8), path: "bad")
        }
        #expect(throws: OrbitoError.self) {
            try PlistService.decode(try PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0), path: "array")
        }
    }

    @Test func applyingKeepsUnparsableArrayItems() {
        let dict: [String: PlistValue] = [
            "StartCalendarInterval": .array([.dictionary(["Hour": .integer(1)]), .string("junk")]),
        ]
        var schedule = PlistService.schedule(from: dict)
        schedule.calendar[0].hour = 2
        let updated = PlistService.applying(schedule, to: dict)
        #expect(updated["StartCalendarInterval"] == .array([.dictionary(["Hour": .integer(2)]), .string("junk")]))
    }

    @Test func malformedScheduleValuesSurviveUnrelatedEdits() {
        let dict: [String: PlistValue] = ["StartInterval": .string("300"), "StartCalendarInterval": .string("daily")]
        let updated = PlistService.applying(.none, to: dict)
        #expect(updated == dict)
        let replaced = PlistService.applying(JobSchedule(calendar: [CalendarEntry(minute: 0)], interval: 60), to: dict)
        #expect(replaced["StartInterval"] == .integer(60))
        #expect(replaced["StartCalendarInterval"] == .dictionary(["Minute": .integer(0)]))
    }

    @Test func clearingCalendarRemovesJunkItemsToo() {
        let dict: [String: PlistValue] = ["StartCalendarInterval": .array([.dictionary(["Hour": .integer(1)]), .string("junk")])]
        #expect(PlistService.applying(.none, to: dict)["StartCalendarInterval"] == nil)
    }

    @Test func backupNamesAreSanitised() throws {
        #expect(BackupService.safeName("..") == "_..")
        #expect(BackupService.safeName("a/b") == "a_b")
        let tmp = try TempDir()
        let service = BackupService(root: tmp.url.appending(path: "Backups"))
        let url = try service.backup(Data("x".utf8), label: "..")
        #expect(url.path.hasPrefix(tmp.url.appending(path: "Backups").path))
        #expect(service.backups(for: "..").count == 1)
    }

    @Test func applyingRemovesKeysWhenScheduleCleared() {
        let dict: [String: PlistValue] = ["Label": .string("x"), "StartInterval": .integer(5), "StartCalendarInterval": .dictionary(["Minute": .integer(1)])]
        let updated = PlistService.applying(.none, to: dict)
        #expect(updated == ["Label": .string("x")])
    }

    @Test func realPlutilLint() async throws {
        let tmp = try TempDir()
        let good = try tmp.write("good.plist", Fixtures.daily)
        let bad = try tmp.write("bad.plist", "<plist><dict><key>x</dict>")
        let service = PlistService()
        try await service.lint(good)
        await #expect(throws: OrbitoError.self) { try await service.lint(bad) }
    }
}
