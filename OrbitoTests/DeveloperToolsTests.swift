import Foundation
import Testing
@testable import Orbito

@Suite("Command Preview")
struct CommandPreviewTests {
    let service = CommandPreviewService(uid: 501, backupDirectory: "/backups")

    func job(loaded: Tristate = .yes, pid: Int? = nil, disabled: Bool? = false) throws -> LaunchJob {
        let (dict, _) = try PlistService.decode(Data(Fixtures.daily.utf8), path: "x")
        var job = LaunchJob.make(from: dict, at: URL(filePath: "/Users/user/Library/LaunchAgents/com.onkron.market-prices.plist"), loaded: loaded)
        job.runtime.pid = pid
        job.runtime.disabledOverride = disabled
        return job
    }

    @Test func runNowUsesRealServiceTarget() throws {
        let preview = service.preview(.runNow, for: try job())
        #expect(preview.steps.map(\.command) == ["launchctl kickstart gui/501/com.onkron.market-prices"])
        let restart = service.preview(.runNow, for: try job(pid: 42), killRunning: true)
        #expect(restart.steps.first?.command == "launchctl kickstart -k gui/501/com.onkron.market-prices")
    }

    @Test func runNowWarnsWhenNotLoaded() throws {
        let unloaded = try job(loaded: .no)
        #expect(!service.preview(.runNow, for: unloaded).warnings.isEmpty)
    }

    @Test func loadUnloadReloadEnableDisable() throws {
        let j = try job()
        #expect(service.preview(.load, for: j).steps.map(\.command) == ["launchctl bootstrap gui/501 /Users/user/Library/LaunchAgents/com.onkron.market-prices.plist"])
        #expect(service.preview(.unload, for: j).steps.map(\.command) == ["launchctl bootout gui/501/com.onkron.market-prices"])
        #expect(service.preview(.reload, for: j).steps.map(\.command) == [
            "launchctl bootout gui/501/com.onkron.market-prices",
            "launchctl bootstrap gui/501 /Users/user/Library/LaunchAgents/com.onkron.market-prices.plist",
        ])
        #expect(service.preview(.disable, for: j).steps.map(\.command) == [
            "launchctl disable gui/501/com.onkron.market-prices",
            "launchctl bootout gui/501/com.onkron.market-prices",
        ])
        // Enabling an unloaded job also bootstraps it.
        let notLoaded = try job(loaded: .no)
        #expect(service.preview(.enable, for: notLoaded).steps.count == 2)
        #expect(service.preview(.unload, for: j).steps.allSatisfy { $0.isDestructive })
    }

    @Test func pathsWithSpacesAreQuoted() throws {
        let dict: [String: PlistValue] = ["Label": .string("a"), "Program": .string("/bin/echo")]
        let j = LaunchJob.make(from: dict, at: URL(filePath: "/Users/u/My Agents/a.plist"))
        #expect(service.preview(.load, for: j).steps.first?.command == "launchctl bootstrap gui/501 '/Users/u/My Agents/a.plist'")
    }

    @Test func scheduleChangeProducesPlutilAndDiff() throws {
        let j = try job()
        var draft = ScheduleDraft(schedule: j.definition.schedule)
        draft.times = [TimeOfDay(hour: 8, minute: 0)]
        let newDict = PlistService.applying(try draft.build(), to: j.raw)
        let preview = service.previewChange(.editSchedule, job: j, newDict: newDict)

        let file = try #require(preview.files.first)
        #expect(file.manualCommands == [#"plutil -replace StartCalendarInterval -json '{"Hour":8,"Minute":0}' /Users/user/Library/LaunchAgents/com.onkron.market-prices.plist"#])
        #expect(file.structured == [StructuredChange(kind: .modified, keyPath: "StartCalendarInterval.Hour", oldValue: "12", newValue: "8")])
        let commands = preview.steps.map(\.command)
        #expect(commands.contains("plutil -lint /Users/user/Library/LaunchAgents/com.onkron.market-prices.plist"))
        #expect(commands.suffix(2) == [
            "launchctl bootout gui/501/com.onkron.market-prices",
            "launchctl bootstrap gui/501 /Users/user/Library/LaunchAgents/com.onkron.market-prices.plist",
        ])
        #expect(commands.first?.hasPrefix("mkdir -p /backups/com.onkron.market-prices && cp ") == true)
    }

    @Test func scheduleChangeForUnloadedOrDisabledJobDoesNotReload() throws {
        let newDict = PlistService.applying(LaunchdScheduleFixture.eight, to: try job().raw)
        let unloaded = service.previewChange(.editSchedule, job: try job(loaded: .no), newDict: newDict)
        #expect(!unloaded.steps.contains { $0.command.contains("bootout") })
        let disabled = service.previewChange(.editSchedule, job: try job(disabled: true), newDict: newDict)
        #expect(!disabled.steps.contains { $0.command.contains("bootstrap") })
        #expect(disabled.warnings.contains { $0.contains("отключено") })
    }

    @Test func plutilCommandsForAllTypes() {
        let old: [String: PlistValue] = ["Label": .string("x"), "StartInterval": .integer(60), "Gone": .bool(true)]
        let new: [String: PlistValue] = ["Label": .string("x"), "StartInterval": .integer(300), "RunAtLoad": .bool(true), "Nice": .real(1.5), "Name.With.Dots": .string("it's"), "Args": .array([.string("a"), .integer(1)])]
        let commands = service.plutilCommands(old: old, new: new, path: "/p.plist")
        #expect(commands.contains("plutil -replace StartInterval -integer 300 /p.plist"))
        #expect(commands.contains("plutil -replace RunAtLoad -bool YES /p.plist"))
        #expect(commands.contains("plutil -replace Nice -float 1.5 /p.plist"))
        #expect(commands.contains("plutil -remove Gone /p.plist"))
        #expect(commands.contains(#"plutil -replace 'Name\.With\.Dots' -string 'it'\''s' /p.plist"#))
        #expect(commands.contains(#"plutil -replace Args -json '["a",1]' /p.plist"#))
        #expect(!commands.contains { $0.contains("Label") })
    }

    @Test func createPreviewNeverOverwrites() {
        let dict: [String: PlistValue] = ["Label": .string("com.example.new"), "ProgramArguments": .array([.string("/bin/zsh")]), "StandardOutPath": .string("/Users/u/Library/Logs/Orbito/x.log")]
        let preview = service.previewCreate(dict: dict, label: "com.example.new", load: true)
        let commands = preview.steps.map(\.command)
        #expect(commands.first == "mkdir -p /Users/u/Library/Logs/Orbito")
        #expect(commands.contains { $0.hasPrefix("test ! -e ") })
        #expect(commands.last == "launchctl bootstrap gui/501 \(JobScope.userAgent.directory.appending(path: "com.example.new.plist").path)")
        #expect(preview.files.first?.before == nil)
    }

    @Test func scriptRunsInExecutionOrder() throws {
        let j = try job()
        let newDict = PlistService.applying(LaunchdScheduleFixture.eight, to: j.raw)
        let lines = service.previewChange(.editSchedule, job: j, newDict: newDict).script.components(separatedBy: "\n").filter { !$0.hasPrefix("#") }
        // Backup first, single plutil edit, lint, then reload.
        #expect(lines.first?.hasPrefix("mkdir -p /backups/com.onkron.market-prices && cp ") == true)
        #expect(lines.first?.hasSuffix("/com.onkron.market-prices-$(date +%Y%m%d-%H%M%S).plist") == true)
        #expect(lines.filter { $0.hasPrefix("plutil -replace") }.count == 1)
        #expect(lines.firstIndex { $0.hasPrefix("plutil -replace") }! < lines.firstIndex { $0.hasPrefix("plutil -lint") }!)

        let create = service.previewCreate(dict: ["Label": .string("com.n"), "Program": .string("/bin/echo")], label: "com.n", load: false)
        let script = create.script
        #expect(script.contains("test ! -e "))
        #expect(script.range(of: "test ! -e ")!.lowerBound < script.range(of: "cat > ")!.lowerBound)
        #expect(script.components(separatedBy: "cat > ").count == 2)
    }

    @Test func reloadPreviewMatchesOperationForDisabledJobs() throws {
        let disabled = service.preview(.reload, for: try job(disabled: true))
        #expect(disabled.steps.isEmpty)
        #expect(!disabled.warnings.isEmpty)
        var unknown = try job()
        unknown.runtime.overridesKnown = false
        unknown.runtime.disabledOverride = nil
        #expect(service.preview(.reload, for: unknown).steps.isEmpty)
        let running = service.preview(.reload, for: try job(pid: 7))
        #expect(running.requiresConfirmation)
    }

    @Test func kickstartKillIsDestructive() throws {
        let preview = service.preview(.runNow, for: try job(pid: 9), killRunning: true)
        #expect(preview.steps.first?.isDestructive == true)
        #expect(preview.requiresConfirmation)
        #expect(preview.warnings.contains { $0.contains("PID 9") })
    }

    @Test func realsUseXMLNotJSON() {
        let commands = service.plutilCommands(old: [:], new: ["D": .dictionary(["v": .real(1.0)])], path: "/p")
        #expect(commands.first?.contains(" -xml ") == true)
        #expect(commands.first?.contains("<real>1</real>") == true)
        #expect(commands.first?.contains("-json") == false)
    }

    @Test func scriptIsCopyable() throws {
        let preview = service.preview(.reload, for: try job())
        #expect(preview.script.contains("launchctl bootout gui/501/com.onkron.market-prices\n"))
        #expect(preview.script.hasPrefix("# Orbito — Перезагрузить (com.onkron.market-prices)"))
    }
}

enum LaunchdScheduleFixture {
    static let eight = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)])
}

@Suite("Linux CLI reference")
struct CLIReferenceTests {
    @Test func everyActionHasReferenceForBothSchedulers() {
        for action in CLIAction.allCases {
            for scheduler in LinuxScheduler.allCases {
                let entry = CLIReferenceService.entry(action, scheduler: scheduler)
                #expect(entry.isReferenceOnly)
                #expect(!entry.title.isEmpty)
                // No equivalent → must explain the difference instead of inventing a command.
                if entry.commands.isEmpty { #expect(entry.differences?.isEmpty == false, "\(action) \(scheduler)") }
                // Examples never reference this Mac's real tasks.
                #expect(!entry.commands.contains { $0.command.contains("launchctl") })
            }
        }
    }

    @Test func systemdRunNowStartsServiceNotTimer() {
        let entry = CLIReferenceService.entry(.runNow, scheduler: .systemd)
        #expect(entry.commands.map(\.command) == ["systemctl --user start example.service"])
    }

    @Test func expectedExamples() {
        #expect(CLIReferenceService.entry(.viewLogs, scheduler: .systemd).commands.first?.command == "journalctl --user -u example.service -n 100 --no-pager")
        #expect(CLIReferenceService.entry(.disable, scheduler: .systemd).commands.first?.command == "systemctl --user disable --now example.timer")
        #expect(CLIReferenceService.entry(.listTasks, scheduler: .cron).commands.first?.command == "crontab -l")
        #expect(CLIReferenceService.entry(.runNow, scheduler: .cron).commands.isEmpty)
        #expect(CLIReferenceService.entry(.delete, scheduler: .cron).commands.contains { $0.command == "crontab -r" && $0.isDestructive })
    }

    @Test func similarSchedulesAreLabelledApproximate() {
        let daily = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)])
        #expect(CLIReferenceService.similarCron(daily) == "0 8 * * *")
        #expect(CLIReferenceService.similarOnCalendar(daily) == ["*-*-* 08:00:00"])
        let weekdays = JobSchedule(calendar: [1, 2, 3, 4, 5].map { CalendarEntry(minute: 30, hour: 9, weekday: $0) }, calendarIsArray: true)
        #expect(CLIReferenceService.similarCron(weekdays) == "30 9 * * 1,2,3,4,5")
        #expect(CLIReferenceService.similarOnCalendar(weekdays) == ["Mon *-*-* 09:30:00", "Tue *-*-* 09:30:00", "Wed *-*-* 09:30:00", "Thu *-*-* 09:30:00", "Fri *-*-* 09:30:00"])
        // Each OnCalendar expression is its own systemd-analyze argument.
        let entry = CLIReferenceService.entry(.editSchedule, scheduler: .systemd, schedule: weekdays)
        #expect(entry.commands.first?.command.hasPrefix("systemd-analyze calendar 'Mon *-*-* 09:30:00' 'Tue *-*-* 09:30:00'") == true)
        // Duplicates must not fool the cross-product check.
        let tricky = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8), CalendarEntry(minute: 0, hour: 8), CalendarEntry(minute: 30, hour: 9), CalendarEntry(minute: 0, hour: 9)], calendarIsArray: true)
        #expect(CLIReferenceService.similarCron(tricky) == nil)
        let twice = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8), CalendarEntry(minute: 0, hour: 20)], calendarIsArray: true)
        #expect(CLIReferenceService.similarCron(twice) == "0 8,20 * * *")
        // Not a cross product → no single cron line.
        let irregular = JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8, weekday: 1), CalendarEntry(minute: 30, hour: 17, weekday: 5)], calendarIsArray: true)
        #expect(CLIReferenceService.similarCron(irregular) == nil)
        #expect(CLIReferenceService.similarCron(JobSchedule(interval: 900)) == "*/15 * * * *")
        #expect(CLIReferenceService.similarCron(JobSchedule(interval: 7 * 60)) == nil)

        let cronEntry = CLIReferenceService.entry(.editSchedule, scheduler: .cron, schedule: daily)
        #expect(cronEntry.differences?.contains("НЕ точный эквивалент") == true)
        #expect(cronEntry.commands.contains { $0.command.hasPrefix("0 8 * * * ") })
    }
}

@Suite("Configuration diff")
struct ConfigurationDiffTests {
    @Test func lineDiff() {
        let lines = ConfigurationDiffService.lineDiff(old: "a\nb\nc", new: "a\nB\nc\nd")
        #expect(lines.map(\.kind) == [.context, .removed, .added, .context, .added])
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["B", "d"])
    }

    @Test func unifiedOutput() {
        let text = ConfigurationDiffService.unified(old: "[Timer]\nOnCalendar=*-*-* 12:00:00\nPersistent=true", new: "[Timer]\nOnCalendar=*-*-* 08:00:00\nPersistent=true", path: "x.timer")
        #expect(text.contains("-OnCalendar=*-*-* 12:00:00\n+OnCalendar=*-*-* 08:00:00\n Persistent=true"))
        #expect(text.hasPrefix("--- x.timer"))
    }

    @Test func identicalTextHasNoHunks() {
        #expect(ConfigurationDiffService.hunks(ConfigurationDiffService.lineDiff(old: "a\nb", new: "a\nb")).isEmpty)
    }

    @Test func structuredPlistDiff() {
        let old: [String: PlistValue] = ["A": .integer(1), "B": .dictionary(["X": .string("x")]), "C": .bool(true)]
        let new: [String: PlistValue] = ["A": .integer(2), "B": .dictionary(["X": .string("x"), "Y": .integer(5)]), "D": .string("d")]
        let changes = ConfigurationDiffService.structured(old: old, new: new)
        #expect(changes.contains(StructuredChange(kind: .modified, keyPath: "A", oldValue: "1", newValue: "2")))
        #expect(changes.contains(StructuredChange(kind: .added, keyPath: "B.Y", oldValue: nil, newValue: "5")))
        #expect(changes.contains(StructuredChange(kind: .removed, keyPath: "C", oldValue: "true", newValue: nil)))
        #expect(changes.contains(StructuredChange(kind: .added, keyPath: "D", oldValue: nil, newValue: "\"d\"")))
        #expect(changes.count == 4)
    }
}

@Suite("Command history")
struct CommandHistoryTests {
    @Test func sanitizesSecrets() {
        #expect(HistorySanitizer.sanitize("API_TOKEN=abc123 run") == "API_TOKEN=*** run")
        #expect(HistorySanitizer.sanitize("tool --password hunter2 --verbose") == "tool --password *** --verbose")
        #expect(HistorySanitizer.sanitize("https://user:s3cret@example.com/x") == "https://user:***@example.com/x")
        #expect(HistorySanitizer.sanitize("\t\tDB_PASSWORD => topsecret") == "\t\tDB_PASSWORD => ***")
        #expect(HistorySanitizer.sanitize("launchctl kickstart gui/501/com.x") == "launchctl kickstart gui/501/com.x")
        #expect(HistorySanitizer.sanitize("\t<key>API_TOKEN</key>\n\t<string>abc</string>") == "\t<key>API_TOKEN</key>\n\t<string>***</string>")
        #expect(HistorySanitizer.sanitize(#"-json '{"API_TOKEN":"abc","PATH":"/bin"}'"#) == #"-json '{"API_TOKEN":"***","PATH":"/bin"}'"#)
        #expect(HistorySanitizer.sanitize("SESSION_COOKIE=xyz") == "SESSION_COOKIE=***")
        #expect(HistorySanitizer.sanitize("https://u:p@ss@host/x") == "https://u:***@host/x")
        #expect(HistorySanitizer.sanitize("<key>Label</key><string>com.x</string>") == "<key>Label</key><string>com.x</string>")
    }

    @Test func dryRunScriptWithSecretsIsMasked() throws {
        let service = CommandPreviewService(uid: 501, backupDirectory: "/b")
        let dict: [String: PlistValue] = ["Label": .string("com.s"), "Program": .string("/bin/echo"), "EnvironmentVariables": .dictionary(["API_TOKEN": .string("supersecret")])]
        let create = service.previewCreate(dict: dict, label: "com.s", load: false)
        let record = HistorySanitizer.clean(CommandRecord(kind: .cliEquivalent, action: "x", command: create.script, exitCode: nil))
        #expect(!record.command.contains("supersecret"))
        let job = LaunchJob.make(from: ["Label": .string("com.s"), "Program": .string("/bin/echo")], at: URL(filePath: "/a.plist"))
        let edit = service.previewChange(.editConfiguration, job: job, newDict: dict)
        let cleaned = HistorySanitizer.clean(CommandRecord(kind: .cliEquivalent, action: "x", command: edit.script, exitCode: nil))
        #expect(!cleaned.command.contains("supersecret"))
    }

    @Test func truncatesLongOutput() {
        let text = String(repeating: "x", count: 20_000)
        #expect(HistorySanitizer.truncate(text).count < 16_100)
    }

    @Test @MainActor func storeIsBoundedAndClearable() async throws {
        let tmp = try TempDir()
        let store = CommandHistoryStore(store: JSONFileStore(url: tmp.url.appending(path: "h.json")))
        for i in 0..<1005 { store.append(CommandRecord(kind: .executed, action: "a", command: "cmd \(i)", exitCode: 0)) }
        #expect(store.records.count == 1000)
        #expect(store.records.first?.command == "cmd 1004")
        await store.flush()
        let reloaded = CommandHistoryStore(store: JSONFileStore(url: tmp.url.appending(path: "h.json")))
        #expect(reloaded.records.count == 1000)
        store.clear()
        #expect(store.records.isEmpty)
        store.isEnabled = false
        store.append(CommandRecord(kind: .executed, action: "a", command: "x", exitCode: 0))
        #expect(store.records.isEmpty)
    }

    @Test func recordingRunnerRecordsOnlyInsideContext() async throws {
        let sink = RecordSink()
        let runner = RecordingCommandRunner(base: MockRunner { _, _ in CommandResult(exitCode: 3, stdout: "out", stderr: "SECRET_TOKEN=xyz") }, recorder: sink)
        _ = try await runner.run(URL(filePath: "/bin/launchctl"), arguments: ["list"])
        #expect(await sink.records.isEmpty)
        _ = try await CommandContext.$current.withValue(.init(label: "com.x", action: "Перезагрузка")) {
            try await runner.run(URL(filePath: "/bin/launchctl"), arguments: ["bootout", "gui/501/com.x"])
        }
        let record = try #require(await sink.records.first)
        #expect(record.command == "launchctl bootout gui/501/com.x")
        #expect(record.exitCode == 3)
        #expect(record.label == "com.x")
        #expect(record.kind == .executed)
    }

    @Test func journalRecordsFileOperations() async throws {
        let env = try JobOperationsTests.Env()
        let sink = RecordSink()
        var ops = env.operations
        ops.journal = OperationJournal(recorder: sink)
        let job = try env.install(Fixtures.daily, name: "com.onkron.market-prices.plist", loaded: .no)
        _ = try await CommandContext.$current.withValue(.init(label: job.label, action: "Изменение расписания")) {
            try await ops.saveSchedule(LaunchdScheduleFixture.eight, for: job)
        }
        let kinds = await sink.records.map(\.kind)
        #expect(kinds.contains(.fileOperation))
        #expect(await sink.records.contains { $0.command.hasPrefix("Резервная копия") })
        #expect(await sink.records.contains { $0.command.hasPrefix("Атомарная запись plist") })
    }
}

actor RecordSink: CommandRecording {
    private(set) var records: [CommandRecord] = []
    func record(_ record: CommandRecord) async { records.append(record) }
}

@Suite("Dry Run")
@MainActor
struct DryRunTests {
    @Test func dryRunRecordsAndChangesNothing() async throws {
        let tmp = try TempDir()
        let defaults = UserDefaults(suiteName: "orbito-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.developerMode = true
        settings.dryRun = true
        let launchctl = MockLaunchctl()
        let state = AppState(
            settings: settings,
            history: HistoryStore(store: JSONFileStore(url: tmp.url.appending(path: "history.json"))),
            commandHistory: CommandHistoryStore(store: JSONFileStore(url: tmp.url.appending(path: "commands.json"))),
            metadata: MetadataStore(store: JSONFileStore(url: tmp.url.appending(path: "meta.json"))),
            launchctl: launchctl
        )
        state.commandHistory.isEnabled = true
        let (dict, _) = try PlistService.decode(Data(Fixtures.daily.utf8), path: "x")
        let job = LaunchJob.make(from: dict, at: tmp.url.appending(path: "a.plist"))

        state.reload(job)
        state.unload(job)
        state.runNow(job)

        #expect(await launchctl.calls.isEmpty)
        #expect(state.commandHistory.records.count == 3)
        #expect(state.commandHistory.records.allSatisfy { $0.kind == .cliEquivalent })
        if case .dryRun = state.previewPresentation?.mode {} else { Issue.record("expected dry-run presentation") }
    }

    @Test func confirmationOpenWhileDryRunTurnsOnDoesNotExecute() async throws {
        let tmp = try TempDir()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "orbito-tests-\(UUID().uuidString)")!)
        settings.developerMode = true
        settings.previewBeforeChanges = true
        let launchctl = MockLaunchctl()
        let state = AppState(
            settings: settings,
            history: HistoryStore(store: JSONFileStore(url: tmp.url.appending(path: "history.json"))),
            commandHistory: CommandHistoryStore(store: JSONFileStore(url: tmp.url.appending(path: "commands.json"))),
            metadata: MetadataStore(store: JSONFileStore(url: tmp.url.appending(path: "meta.json"))),
            launchctl: launchctl
        )
        let (dict, _) = try PlistService.decode(Data(Fixtures.daily.utf8), path: "x")
        let job = LaunchJob.make(from: dict, at: tmp.url.appending(path: "a.plist"))
        state.unload(job)
        guard case .confirm(let execute) = state.previewPresentation?.mode else {
            Issue.record("expected confirm preview")
            return
        }
        settings.dryRun = true
        await execute()
        #expect(await launchctl.calls.isEmpty)
        #expect(state.commandHistory.records.contains { $0.kind == .cliEquivalent })

        // Direct calls are refused too.
        settings.dryRun = true
        await state.perform(job, kind: .reload, success: "x") { try await state.operations.reload(job); return nil }
        #expect(await launchctl.calls.isEmpty)
        await #expect(throws: OrbitoError.self) { try await state.duplicate(job, as: "com.copy") }
        _ = try? await state.create(dict: ["Label": .string("com.n")], metadata: JobMetadata(), load: false)
        #expect(await launchctl.calls.isEmpty)
    }

    @Test func developerFeaturesRequireDeveloperMode() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "orbito-tests-\(UUID().uuidString)")!)
        settings.dryRun = true
        settings.cliTooltips = true
        #expect(!settings.isDryRun)
        #expect(!settings.showsCLITooltips)
        settings.developerMode = true
        #expect(settings.isDryRun)
        #expect(settings.showsCLITooltips)
    }
}
