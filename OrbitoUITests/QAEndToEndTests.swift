import XCTest

/// End-to-end QA against the real launchd of this Mac.
/// Touches ONLY `com.orbito.qa-test` / `com.orbito.qa-invalid` and their own files.
/// Every GUI step is verified independently via launchctl and the plist bytes.
final class QAEndToEndTests: XCTestCase {
    static let label = "com.orbito.qa-test"
    static let invalidLabel = "com.orbito.qa-invalid"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var uid: String { String(getuid()) }
    var plistPath: String { "\(home)/Library/LaunchAgents/\(Self.label).plist" }
    var invalidPath: String { "\(home)/Library/LaunchAgents/\(Self.invalidLabel).plist" }
    var outLog: String { "\(home)/Library/Logs/Orbito/\(Self.label).out.log" }
    var errLog: String { "\(home)/Library/Logs/Orbito/\(Self.label).err.log" }
    var backups: String { "\(home)/Library/Application Support/Orbito/Backups/\(Self.label)" }
    var historyFile: String { "\(home)/Library/Application Support/Orbito/command-history.json" }
    var evidenceFile: String { ProcessInfo.processInfo.environment["ORBITO_QA_EVIDENCE"] ?? NSTemporaryDirectory() + "orbito-qa-evidence.jsonl" }

    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Shell helpers (read-only system inspection)

    @discardableResult
    func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func printService() -> (code: Int32, out: String) { run("/bin/launchctl", ["print", "gui/\(uid)/\(Self.label)"]) }

    func field(_ name: String, in text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("\(name) = ") }.map { String($0.dropFirst(name.count + 3)) }
    }

    func disabledOverride() -> String? {
        let out = run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).out
        return out.split(separator: "\n").first { $0.contains("\"\(Self.label)\"") }.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    func plistBytes(_ path: String? = nil) -> Data? { FileManager.default.contents(atPath: path ?? plistPath) }

    func plistDict() -> [String: Any]? {
        guard let data = plistBytes() else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    func evidence(_ scenario: String, _ facts: [String: String]) {
        var record = facts
        record["scenario"] = scenario
        record["time"] = ISO8601DateFormatter().string(from: .now)
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        if let handle = FileHandle(forWritingAtPath: evidenceFile) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: evidenceFile, contents: data + Data("\n".utf8))
        }
    }

    func waitUntil(_ timeout: TimeInterval = 20, _ description: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Timed out: \(description)")
    }

    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func launch(_ extra: [String] = []) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-OrbitoSection", "all", "-developerMode", "NO", "-previewBeforeChanges", "NO", "-dryRun", "NO",
            "-confirmRunNow", "NO", "-showSystemJobs", "NO", "-autoRefresh", "YES", "-refreshInterval", "5",
            "-cliTooltips", "YES", "-defaultCLIPlatform", "macOS",
        ] + extra
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
    }

    func selectQATask(_ label: String = QAEndToEndTests.label) {
        let row = app.descendants(matching: .any)["task.\(label)"]
        if !row.waitForExistence(timeout: 20) {
            app.typeKey("r", modifierFlags: .command)
            XCTAssertTrue(row.waitForExistence(timeout: 20), "row \(label)")
        }
        row.click()
    }

    func button(_ id: String) -> XCUIElement {
        let element = app.buttons[id]
        if !element.waitForExistence(timeout: 15) {
            try? app.debugDescription.write(toFile: evidenceFile + ".hierarchy.txt", atomically: true, encoding: .utf8)
            XCTFail("button \(id)")
        }
        return element
    }

    // MARK: The scenario

    @MainActor
    func testFullLifecycle() throws {
        // Preconditions: never touch anything that isn't ours.
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistPath), "QA plist already exists — refusing to run")
        XCTAssertEqual(printService().code, 113, "QA label already loaded — refusing to run")
        try? FileManager.default.removeItem(atPath: evidenceFile)
        let foreignBefore = run("/bin/ls", ["\(home)/Library/LaunchAgents"]).out
        let foreignHashBefore = foreignAgentsFingerprint()

        launch()
        defer { cleanup() }

        try stepCreate()
        try stepEditSchedule()
        try stepReload()
        try stepRunNow()
        try stepDisable()
        try stepEnable()
        try stepDryRun()
        try stepCommandPreview()
        try stepCLITooltip()
        try stepConfigurationDiff()
        try stepFailedReloadRestoresBackup()
        try stepInvalidPlist()
        try stepReadOnlySystemJobs()
        try stepDelete()

        // Other agents untouched.
        XCTAssertEqual(foreignAgentsFingerprint(), foreignHashBefore)
        evidence("Foreign LaunchAgents untouched", ["before": foreignBefore, "fingerprintEqual": "true"])
    }

    /// Bytes of every plist in ~/Library/LaunchAgents except the QA ones.
    func foreignAgentsFingerprint() -> [String: Data] {
        let dir = "\(home)/Library/LaunchAgents"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var result: [String: Data] = [:]
        for name in names where !name.hasPrefix("com.orbito.qa-") {
            result[name] = FileManager.default.contents(atPath: "\(dir)/\(name)") ?? Data()
        }
        return result
    }

    func stepCreate() throws {
        app.buttons["Новое задание"].firstMatch.click()
        let name = app.textFields["wizard.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Orbito QA Test")
        let label = app.textFields["wizard.label"]
        label.click()
        label.typeKey("a", modifierFlags: .command)
        label.typeText(Self.label)
        button("wizard.next").click()

        let exe = app.textFields["command.executable"]
        XCTAssertTrue(exe.waitForExistence(timeout: 10))
        exe.click()
        exe.typeText("/bin/date")
        button("wizard.next").click()   // schedule (default daily 08:00)
        button("wizard.next").click()   // logging (defaults)
        button("wizard.next").click()   // review
        screenshot("01-create-review")
        button("wizard.create").click()

        waitUntil(20, "plist created and loaded") { plistBytes() != nil && printService().code == 0 }
        let dict = try XCTUnwrap(plistDict())
        XCTAssertEqual(dict["Label"] as? String, Self.label)
        XCTAssertEqual(dict["ProgramArguments"] as? [String], ["/bin/date"])
        let sci = try XCTUnwrap(dict["StartCalendarInterval"] as? [String: Int])
        XCTAssertEqual(sci, ["Hour": 8, "Minute": 0])
        XCTAssertEqual(dict["StandardOutPath"] as? String, outLog)
        let attrs = try FileManager.default.attributesOfItem(atPath: plistPath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        let print = printService().out
        XCTAssertEqual(field("state", in: print), "not running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (outLog as NSString).deletingLastPathComponent))
        screenshot("02-created")
        evidence("Create", ["plist": String(decoding: plistBytes()!, as: UTF8.self), "launchctl.state": field("state", in: print) ?? "?", "print.exit": "0", "disabledOverride": disabledOverride() ?? "none"])
    }

    func stepEditSchedule() throws {
        selectQATask()
        let before = try XCTUnwrap(plistDict())
        button("detail.schedule").click()
        let picker = app.datePickers["schedule.time"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        // Focus the hour field and type 09:30.
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        picker.typeText("09")
        picker.typeKey(.tab, modifierFlags: [])
        picker.typeText("30")
        picker.typeKey(.tab, modifierFlags: [])
        screenshot("03-schedule-editor")
        button("schedule.save").click()

        waitUntil(20, "schedule written") { (plistDict()?["StartCalendarInterval"] as? [String: Int]) == ["Hour": 9, "Minute": 30] }
        let after = try XCTUnwrap(plistDict())
        // Only StartCalendarInterval changed.
        var b = before; var a = after
        b.removeValue(forKey: "StartCalendarInterval"); a.removeValue(forKey: "StartCalendarInterval")
        XCTAssertEqual(NSDictionary(dictionary: b), NSDictionary(dictionary: a))
        // launchd picked up the new trigger (reload happened).
        waitUntil(15, "launchd descriptor 09:30") {
            let out = printService().out
            return out.contains("\"Hour\" => 9") && out.contains("\"Minute\" => 30")
        }
        let backupsList = (try? FileManager.default.contentsOfDirectory(atPath: backups)) ?? []
        XCTAssertFalse(backupsList.isEmpty, "backup created")
        evidence("Edit Schedule + Save", ["plist.StartCalendarInterval": "\(after["StartCalendarInterval"]!)", "launchd.descriptor": printService().out.components(separatedBy: "descriptor = {").last?.prefix(80).description ?? "", "backups": backupsList.joined(separator: ",")])
    }

    func stepReload() throws {
        selectQATask()
        let bytes = plistBytes()
        let start = Date()
        button("detail.reload").click()
        // bootout+bootstrap are visible in launchd's unified log.
        waitUntil(20, "reload logged") {
            let log = run("/usr/bin/log", ["show", "--start", Self.logDate(start.addingTimeInterval(-1)), "--style", "compact", "--predicate", "eventMessage CONTAINS \"\(Self.label)\""]).out
            return log.contains("bootout") || log.contains("removing service") || log.contains("Bootstrap") || log.contains("service inactive")
        }
        waitUntil(15, "loaded after reload") { printService().code == 0 }
        XCTAssertEqual(plistBytes(), bytes, "reload must not change the file")
        evidence("Reload", ["print.exit": "0", "fileUnchanged": "true", "state": field("state", in: printService().out) ?? "?"])
    }

    static func logDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    func stepRunNow() throws {
        selectQATask()
        let runsBefore = Int(field("runs", in: printService().out) ?? "0") ?? 0
        button("detail.run").click()
        waitUntil(20, "job ran") {
            let out = printService().out
            return (Int(field("runs", in: out) ?? "0") ?? 0) > runsBefore && field("last exit code", in: out) == "0"
        }
        waitUntil(10, "stdout written") { (try? String(contentsOfFile: outLog, encoding: .utf8))?.isEmpty == false }
        let out = printService().out
        evidence("Run Now", ["runs.before": "\(runsBefore)", "runs.after": field("runs", in: out) ?? "?", "lastExit": field("last exit code", in: out) ?? "?", "stdout": (try? String(contentsOfFile: outLog, encoding: .utf8)) ?? ""])
    }

    func stepDisable() throws {
        selectQATask()
        let bytes = plistBytes()
        button("detail.toggleDisabled").click()
        let confirm = app.buttons["Отключить"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "confirmation required")
        screenshot("04-disable-confirm")
        confirm.click()
        waitUntil(20, "disabled + unloaded") { disabledOverride()?.hasSuffix("disabled") == true && printService().code == 113 }
        XCTAssertEqual(plistBytes(), bytes, "disable must not change plist")
        evidence("Disable", ["print-disabled": disabledOverride() ?? "none", "print.exit": "113 (not loaded)", "fileUnchanged": "true", "fileExists": "\(FileManager.default.fileExists(atPath: plistPath))"])
    }

    func stepEnable() throws {
        selectQATask()
        button("detail.toggleDisabled").click()
        waitUntil(20, "enabled + loaded") { disabledOverride()?.hasSuffix("enabled") == true && printService().code == 0 }
        evidence("Enable", ["print-disabled": disabledOverride() ?? "none", "print.exit": "0", "state": field("state", in: printService().out) ?? "?"])
    }

    /// Snapshot of everything Dry Run must leave untouched.
    func systemSnapshot() -> [String: String] {
        let out = printService().out
        return [
            "plist": plistBytes().map { $0.base64EncodedString() } ?? "missing",
            "print.exit": "\(printService().code)",
            "state": field("state", in: out) ?? "?",
            "runs": field("runs", in: out) ?? "?",
            "disabled": disabledOverride() ?? "none",
            "trash": "\(FileManager.default.fileExists(atPath: "\(home)/.Trash/\(Self.label).plist"))",
        ]
    }

    func stepDryRun() throws {
        launch(["-developerMode", "YES", "-dryRun", "YES"])
        selectQATask()
        let before = systemSnapshot()
        for id in ["detail.reload", "detail.toggleDisabled", "detail.run"] {
            button(id).click()
            let close = app.buttons["preview.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 10), "dry-run sheet for \(id)")
            if id == "detail.reload" { screenshot("05-dry-run") }
            close.click()
        }
        // Delete via menu in Dry Run.
        button("detail.more").click()
        app.menuItems["Удалить…"].click()
        let close = app.buttons["preview.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.click()

        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let after = systemSnapshot()
        XCTAssertEqual(before, after, "Dry Run changed the system")
        let history = (try? String(contentsOfFile: historyFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(history.contains("cliEquivalent"))
        evidence("Dry Run (reload, disable, run, delete)", ["before": "\(before.filter { $0.key != "plist" })", "after": "\(after.filter { $0.key != "plist" })", "plistUnchanged": "\(before["plist"] == after["plist"])"])
    }

    func stepCommandPreview() throws {
        launch(["-developerMode", "YES", "-previewBeforeChanges", "YES", "-dryRun", "NO", "-commandHistory", "YES"])
        selectQATask()
        let started = Date()
        button("detail.reload").click()
        let expected = ["launchctl bootout gui/\(uid)/\(Self.label)", "launchctl bootstrap gui/\(uid) \(plistPath)"]
        for command in expected {
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", command, command)).firstMatch.waitForExistence(timeout: 10), "preview shows \(command)")
        }
        screenshot("06-command-preview")
        button("preview.execute").click()
        waitUntil(20, "reloaded after confirm") { printService().code == 0 }
        // Executed commands (Command History) == previewed commands, same order.
        var executed: [String] = []
        waitUntil(10, "history written") {
            executed = executedCommands(since: started)
            return executed.count >= 2
        }
        XCTAssertEqual(executed, expected)
        evidence("Command Preview matches execution", ["preview": expected.joined(separator: " | "), "executed": executed.joined(separator: " | ")])
    }

    func executedCommands(since date: Date) -> [String] {
        guard let data = FileManager.default.contents(atPath: historyFile),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return records
            .filter { ($0["kind"] as? String) == "executed" && ($0["label"] as? String) == Self.label }
            .filter { (iso.date(from: $0["date"] as? String ?? "") ?? .distantPast) >= date.addingTimeInterval(-1) }
            .reversed()
            .compactMap { $0["command"] as? String }
    }

    func stepCLITooltip() throws {
        launch(["-developerMode", "YES", "-cliTooltips", "YES"])
        selectQATask()
        let historyBefore = (try? String(contentsOfFile: historyFile, encoding: .utf8)) ?? ""
        let run = button("detail.run")
        run.hover()
        let kickstart = "launchctl kickstart gui/\(uid)/\(Self.label)"
        let hint = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", kickstart, kickstart)).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "macOS tooltip shows real command")
        screenshot("07-cli-tooltip-macos")
        let linux = app.popovers.radioButtons["Linux"].firstMatch
        XCTAssertTrue(linux.waitForExistence(timeout: 5))
        linux.click()
        XCTAssertTrue(app.staticTexts["Reference Only"].waitForExistence(timeout: 5))
        let systemd = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "systemctl --user start example.service", "systemctl --user start example.service")).firstMatch
        XCTAssertTrue(systemd.waitForExistence(timeout: 5))
        screenshot("08-cli-tooltip-linux")
        app.typeKey(.escape, modifierFlags: [])
        // Reference never executes anything.
        let historyAfter = (try? String(contentsOfFile: historyFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(historyAfter.contains("systemctl"))
        XCTAssertEqual(historyBefore.count, historyAfter.count, "no command recorded while viewing tooltip")
        evidence("CLI Tooltip macOS/Linux", ["macOS": kickstart, "linux": "systemctl --user start example.service (Reference Only)", "historyUnchanged": "true"])
    }

    func stepConfigurationDiff() throws {
        launch(["-developerMode", "YES"])
        selectQATask()
        let bytes = plistBytes()
        button("detail.schedule").click()
        let picker = app.datePickers["schedule.time"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        picker.typeText("10")
        picker.typeKey(.tab, modifierFlags: [])
        let diff = app.disclosureTriangles["Configuration Diff"].firstMatch
        let diffGroup = diff.exists ? diff : app.staticTexts["Configuration Diff"].firstMatch
        XCTAssertTrue(diffGroup.waitForExistence(timeout: 10), "diff available")
        diffGroup.click()
        let keyPath = app.staticTexts["StartCalendarInterval.Hour"]
        XCTAssertTrue(keyPath.waitForExistence(timeout: 5), "structured diff shows key path")
        screenshot("09-configuration-diff")
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(plistBytes(), bytes, "cancelling the editor must not write")
        evidence("Configuration Diff", ["keyPath": "StartCalendarInterval.Hour", "cancelledWithoutWrite": "true"])
    }

    func stepFailedReloadRestoresBackup() throws {
        launch(["-developerMode", "YES", "-previewBeforeChanges", "NO"])
        selectQATask()
        let original = try XCTUnwrap(plistBytes())
        let backupsBefore = (try? FileManager.default.contentsOfDirectory(atPath: backups))?.count ?? 0
        button("detail.more").click()
        app.menuItems["Открыть plist…"].click()
        button("raw.edit").click()
        let editor = app.textViews["raw.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        // Lint-valid, but launchd rejects ProgramArguments as a string (bootstrap error 5).
        editor.typeText("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Label</key><string>\(Self.label)</string><key>ProgramArguments</key><string>/bin/date</string></dict></plist>
        """)
        let review = button("raw.review")
        if review.isEnabled {
            review.click()
            button("raw.save").click()
            // Orbito must report failure, restore the file and bring the old job back.
            let banner = app.staticTexts["Операция не выполнена"]
            XCTAssertTrue(banner.waitForExistence(timeout: 30), "failure reported")
            screenshot("10-failed-reload")
            waitUntil(20, "original restored and loaded") { plistBytes() == original && printService().code == 0 }
            let backupsAfter = (try? FileManager.default.contentsOfDirectory(atPath: backups))?.count ?? 0
            XCTAssertGreaterThan(backupsAfter, backupsBefore)
            evidence("Failed reload → restore", ["fileRestoredByteForByte": "true", "launchdRestored": "print exit 0", "backups": "\(backupsBefore)→\(backupsAfter)"])
        } else {
            // Validation rejected the plist before touching anything.
            screenshot("10-validation-blocked")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertEqual(plistBytes(), original)
            evidence("Failed reload → blocked by validation", ["fileUnchanged": "true"])
        }
    }

    func stepInvalidPlist() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidPath))
        try Data("<plist><dict><key>Label</key>".utf8).write(to: URL(fileURLWithPath: invalidPath))
        defer { try? FileManager.default.removeItem(atPath: invalidPath) }
        launch()
        let row = app.descendants(matching: .any)["task.\(Self.invalidLabel)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue((row.label + (row.value as? String ?? "")).contains("Неверный plist"), "badge shows invalid: \(row.label)")
        row.click()
        XCTAssertFalse(button("detail.schedule").isEnabled, "invalid plist not editable")
        screenshot("11-invalid-plist")
        XCTAssertEqual(run("/bin/launchctl", ["print", "gui/\(uid)/\(Self.invalidLabel)"]).code, 113, "never loaded")
        evidence("Invalid plist", ["badge": "Неверный plist", "editable": "false", "loaded": "no"])
    }

    func stepReadOnlySystemJobs() throws {
        let daemons = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/LaunchDaemons"))?.filter { $0.hasSuffix(".plist") } ?? []
        guard let file = daemons.first,
              let data = FileManager.default.contents(atPath: "/Library/LaunchDaemons/\(file)"),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = dict["Label"] as? String else {
            evidence("Read-only system jobs", ["result": "NOT TESTED: no readable daemon"])
            return
        }
        launch(["-showSystemJobs", "YES"])
        selectQATask(label)
        XCTAssertFalse(button("detail.run").isEnabled)
        XCTAssertFalse(button("detail.schedule").isEnabled)
        XCTAssertFalse(button("detail.toggleDisabled").isEnabled)
        screenshot("12-read-only-daemon")
        XCTAssertEqual(FileManager.default.contents(atPath: "/Library/LaunchDaemons/\(file)"), data)
        evidence("Read-only system jobs", ["daemon": label, "run/schedule/disable": "disabled"])
    }

    func stepDelete() throws {
        launch()
        selectQATask()
        button("detail.more").click()
        app.menuItems["Удалить…"].click()
        let confirm = app.buttons["Удалить"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "delete requires confirmation")
        screenshot("13-delete-confirm")
        confirm.click()
        waitUntil(20, "deleted + unloaded") { plistBytes() == nil && printService().code == 113 }
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.Trash"))?.filter { $0.hasPrefix(Self.label) } ?? []
        let backupsList = (try? FileManager.default.contentsOfDirectory(atPath: backups)) ?? []
        evidence("Delete", ["plistExists": "false", "print.exit": "113", "trash": trashed.joined(separator: ","), "backups": "\(backupsList.count)"])
    }

    // MARK: Cleanup — only QA-owned artefacts, verified by label

    func cleanup() {
        app?.terminate()
        if printService().code == 0 { run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"]) }
        for path in [plistPath, invalidPath] {
            if let data = FileManager.default.contents(atPath: path),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               (dict["Label"] as? String)?.hasPrefix("com.orbito.qa-") != true {
                continue // not ours — never delete
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        let trash = "\(home)/.Trash"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [] where name.hasPrefix(Self.label) {
            let path = "\(trash)/\(name)"
            if let data = FileManager.default.contents(atPath: path),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               dict["Label"] as? String == Self.label {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try? FileManager.default.removeItem(atPath: outLog)
        try? FileManager.default.removeItem(atPath: errLog)
        try? FileManager.default.removeItem(atPath: backups)
        try? FileManager.default.removeItem(atPath: "\(home)/Library/Application Support/Orbito/Backups/\(Self.invalidLabel)")
    }
}
