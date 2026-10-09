import Foundation

/// Reads, decodes and writes launchd property lists without losing data.
struct PlistService: Sendable {
    var runner: any CommandRunning = ProcessCommandRunner()

    // MARK: - Reading

    static func decode(_ data: Data, path: String) throws -> (dict: [String: PlistValue], format: PlistFormat) {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw OrbitoError.invalidPlist(path: path, reason: (error as NSError).localizedDescription)
        }
        guard let value = PlistValue(any: object), let dict = value.dictionaryValue else {
            throw OrbitoError.notADictionary(path: path)
        }
        return (dict, PlistFormat(format))
    }

    static func read(_ url: URL) throws -> (dict: [String: PlistValue], format: PlistFormat) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OrbitoError.invalidPlist(path: url.path, reason: (error as NSError).localizedDescription)
        }
        return try decode(data, path: url.path)
    }

    // MARK: - Writing

    static func encode(_ dict: [String: PlistValue], format: PlistFormat) throws -> Data {
        let object = PlistValue.dictionary(dict).foundationValue
        do {
            return try PropertyListSerialization.data(fromPropertyList: object, format: format.writableFormat, options: 0)
        } catch {
            throw OrbitoError.writeFailed(path: "", reason: (error as NSError).localizedDescription)
        }
    }

    static func xmlString(_ dict: [String: PlistValue]) -> String {
        guard let data = try? encode(dict, format: .xml) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Atomically writes `data` after verifying it decodes back to `dict`.
    static func write(_ dict: [String: PlistValue], format: PlistFormat, to url: URL, allowOverwrite: Bool) throws {
        let data = try encode(dict, format: format)
        // Validate the exact bytes we are about to write.
        let decoded = try decode(data, path: url.path)
        guard decoded.dict == dict else {
            throw OrbitoError.writeFailed(path: url.path, reason: "проверка после сериализации не совпала")
        }
        try writeData(data, to: url, allowOverwrite: allowOverwrite)
    }

    static func writeData(_ data: Data, to url: URL, allowOverwrite: Bool) throws {
        let fm = FileManager.default
        if !allowOverwrite, fm.fileExists(atPath: url.path) {
            throw OrbitoError.fileExists(path: url.path)
        }
        do {
            if allowOverwrite {
                try data.write(to: url, options: .atomic)
            } else {
                try Self.createAtomically(data, at: url)
            }
            // launchd refuses plists writable by group/others.
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch let error as OrbitoError {
            throw error
        } catch {
            throw OrbitoError.writeFailed(path: url.path, reason: (error as NSError).localizedDescription)
        }
    }

    /// Writes to a temp file in the same directory, then renames with
    /// `RENAME_EXCL`: atomic, and fails instead of replacing an existing file.
    static func createAtomically(_ data: Data, at url: URL) throws {
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw OrbitoError.fileExists(path: url.path) }
            throw OrbitoError.writeFailed(path: url.path, reason: String(cString: strerror(errno)))
        }
    }

    /// Runs `plutil -lint` as an independent validity check.
    func lint(_ url: URL) async throws {
        let result = try await runner.run(URL(filePath: "/usr/bin/plutil"), arguments: ["-lint", url.path])
        guard result.exitCode == 0 else { throw OrbitoError.lintFailed(result.combinedOutput) }
    }

    // MARK: - Interpreting keys

    static func definition(from dict: [String: PlistValue]) -> JobDefinition {
        var def = JobDefinition()
        def.label = dict["Label"]?.stringValue
        def.program = dict["Program"]?.stringValue
        def.programArguments = dict["ProgramArguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
        def.schedule = schedule(from: dict)
        def.runAtLoad = dict["RunAtLoad"]?.boolValue ?? false
        switch dict["KeepAlive"] {
        case .bool(let value): def.keepAlive = .always(value)
        case .dictionary: def.keepAlive = .conditional
        default: def.keepAlive = .absent
        }
        def.workingDirectory = dict["WorkingDirectory"]?.stringValue
        def.environment = (dict["EnvironmentVariables"]?.dictionaryValue ?? [:]).compactMapValues(\.stringValue)
        def.standardOutPath = dict["StandardOutPath"]?.stringValue
        def.standardErrorPath = dict["StandardErrorPath"]?.stringValue
        def.disabled = dict["Disabled"]?.boolValue
        switch dict["LimitLoadToSessionType"] {
        case .string(let value): def.limitLoadToSessionType = [value]
        case .array(let values): def.limitLoadToSessionType = values.compactMap(\.stringValue)
        default: break
        }
        def.otherTriggers = ["WatchPaths", "QueueDirectories", "StartOnMount", "Sockets", "MachServices", "LaunchEvents"]
            .filter { dict[$0] != nil }
        return def
    }

    static func schedule(from dict: [String: PlistValue]) -> JobSchedule {
        var schedule = JobSchedule()
        switch dict["StartInterval"] {
        case .none: break
        case .integer(let seconds):
            if seconds > 0 { schedule.interval = seconds }
            else { schedule.parseWarnings.append("StartInterval = \(seconds) — должно быть положительным числом.") }
        case .some(let other):
            schedule.parseWarnings.append("StartInterval имеет тип \(other.typeName), ожидается integer. launchd проигнорирует ключ.")
        }

        switch dict["StartCalendarInterval"] {
        case .none: break
        case .dictionary(let entryDict):
            schedule.calendarIsArray = false
            schedule.calendar = [calendarEntry(from: entryDict, index: nil, warnings: &schedule.parseWarnings)]
        case .array(let items):
            schedule.calendarIsArray = true
            for (index, item) in items.enumerated() {
                if let entryDict = item.dictionaryValue {
                    schedule.calendar.append(calendarEntry(from: entryDict, index: index, warnings: &schedule.parseWarnings))
                } else {
                    schedule.parseWarnings.append("StartCalendarInterval[\(index)] имеет тип \(item.typeName) — элемент будет сохранён, но не может быть отображён.")
                }
            }
        case .some(let other):
            schedule.parseWarnings.append("StartCalendarInterval имеет тип \(other.typeName), ожидается dictionary или array.")
        }
        return schedule
    }

    private static func calendarEntry(from dict: [String: PlistValue], index: Int?, warnings: inout [String]) -> CalendarEntry {
        let prefix = index.map { "StartCalendarInterval[\($0)]" } ?? "StartCalendarInterval"
        func int(_ key: String) -> Int? {
            guard let value = dict[key] else { return nil }
            if let int = value.integerValue { return int }
            warnings.append("\(prefix).\(key) имеет тип \(value.typeName), ожидается integer.")
            return nil
        }
        var entry = CalendarEntry(
            minute: int("Minute"), hour: int("Hour"), day: int("Day"),
            weekday: int("Weekday"), month: int("Month")
        )
        entry.extras = dict.filter { !CalendarEntry.knownKeys.contains($0.key) || ($0.value.integerValue == nil) }
        for key in entry.extras.keys where !CalendarEntry.knownKeys.contains(key) {
            warnings.append("\(prefix) содержит неизвестный ключ «\(key)» — он будет сохранён без изменений.")
        }
        for error in entry.validationErrors { warnings.append("\(prefix): \(error)") }
        return entry
    }

    /// Replaces only `StartCalendarInterval` / `StartInterval`; every other key is untouched.
    /// Values launchd would ignore anyway (wrong type, non-positive interval) are kept
    /// verbatim unless a valid replacement is written, so no data is silently dropped.
    static func applying(_ schedule: JobSchedule, to dict: [String: PlistValue]) -> [String: PlistValue] {
        var result = dict
        let existingCalendar = dict["StartCalendarInterval"]
        let calendarMalformed = existingCalendar != nil && existingCalendar?.dictionaryValue == nil && existingCalendar?.arrayValue == nil
        // Array items that could not be parsed are kept at the end, as long as a calendar remains.
        let unparsable = existingCalendar?.arrayValue?.filter { $0.dictionaryValue == nil } ?? []
        let entries = schedule.calendar.map { PlistValue.dictionary($0.plistDictionary) } + (schedule.calendar.isEmpty ? [] : unparsable)

        if entries.isEmpty {
            if !calendarMalformed { result.removeValue(forKey: "StartCalendarInterval") }
        } else if entries.count == 1, !schedule.calendarIsArray {
            result["StartCalendarInterval"] = entries[0]
        } else {
            result["StartCalendarInterval"] = .array(entries)
        }

        let existingInterval = dict["StartInterval"]
        let intervalMalformed = existingInterval != nil && (existingInterval?.integerValue ?? 0) <= 0
        if let interval = schedule.interval {
            result["StartInterval"] = .integer(interval)
        } else if !intervalMalformed {
            result.removeValue(forKey: "StartInterval")
        }
        return result
    }
}
