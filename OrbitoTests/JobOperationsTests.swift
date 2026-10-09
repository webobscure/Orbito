import Foundation
import Testing
@testable import Orbito

@Suite("Applying changes")
struct JobOperationsTests {
    struct Env {
        let tmp: TempDir
        let agents: URL
        let backups: URL
        let launchctl = MockLaunchctl()
        let runner = MockRunner()

        init() throws {
            tmp = try TempDir()
            agents = tmp.url.appending(path: "LaunchAgents", directoryHint: .isDirectory)
            backups = tmp.url.appending(path: "Backups", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        }

        var operations: JobOperations {
            JobOperations(
                launchctl: launchctl, plist: PlistService(runner: runner),
                backups: BackupService(root: backups), agentsDirectory: agents,
                retryDelay: .milliseconds(1), bootstrapAttempts: 2
            )
        }

        func install(_ xml: String, name: String, loaded: Tristate = .yes) throws -> LaunchJob {
            let url = agents.appending(path: name)
            try xml.write(to: url, atomically: true, encoding: .utf8)
            let (dict, format) = try PlistService.read(url)
            return LaunchJob.make(from: dict, at: url, loaded: loaded, format: format)
        }
    }

    @Test func saveScheduleWritesBacksUpAndReloads() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "com.onkron.market-prices.plist")
        var draft = ScheduleDraft(schedule: job.definition.schedule)
        draft.times = [TimeOfDay(hour: 8, minute: 0)]

        let report = try await env.operations.saveSchedule(try draft.build(), for: job)

        let (saved, _) = try PlistService.read(job.plistURL)
        #expect(saved["StartCalendarInterval"] == .dictionary(["Hour": .integer(8), "Minute": .integer(0)]))
        #expect(saved["X-Custom-Key"] == job.raw["X-Custom-Key"])

        let backup = try #require(report.backupURL)
        #expect(try String(contentsOf: backup, encoding: .utf8) == Fixtures.daily)

        let calls = await env.launchctl.calls
        #expect(calls == [
            .bootout("gui/501", "com.onkron.market-prices"),
            .bootstrap("gui/501", job.plistURL.path),
        ])
        #expect(env.runner.invocations.contains(["/usr/bin/plutil", "-lint", job.plistURL.path]))
    }

    @Test func notLoadedJobOnlyWritesFile() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "a.plist", loaded: .no)
        _ = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
        #expect(await env.launchctl.calls.isEmpty)
    }

    @Test func bootstrapFailureRestoresOriginalPlist() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "com.onkron.market-prices.plist")
        // New file fails twice (all retries); restored file then loads.
        await env.launchctl.failBootstrap(times: 2, code: 5)

        do {
            _ = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
            Issue.record("expected failure")
        } catch let OrbitoError.applyFailed(_, restoredFile, restoredLaunchd) {
            #expect(restoredFile)
            #expect(restoredLaunchd == true)
        }

        #expect(try String(contentsOf: job.plistURL, encoding: .utf8) == Fixtures.daily)
        let bootstraps = await env.launchctl.calls.filter { if case .bootstrap = $0 { true } else { false } }
        #expect(bootstraps.count == 3)
    }

    @Test func permanentFailureReportsLaunchdNotRestored() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "com.onkron.market-prices.plist")
        await env.launchctl.failBootstrap(times: 100, code: 1)

        do {
            _ = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
            Issue.record("expected failure")
        } catch let OrbitoError.applyFailed(_, restoredFile, restoredLaunchd) {
            #expect(restoredFile)
            #expect(restoredLaunchd == false)
            let text = OrbitoError.applyFailed(reason: "x", restoredFile: restoredFile, restoredLaunchd: restoredLaunchd).localizedDescription
            #expect(text.contains("НЕ удалось снова загрузить"))
        }
        #expect(try String(contentsOf: job.plistURL, encoding: .utf8) == Fixtures.daily)
    }

    @Test func bootoutFailureLeavesOldVersionLoaded() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "com.onkron.market-prices.plist")
        await env.launchctl.failBootout(code: 1)
        do {
            _ = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
            Issue.record("expected failure")
        } catch let OrbitoError.applyFailed(_, restoredFile, restoredLaunchd) {
            #expect(restoredFile)
            #expect(restoredLaunchd == nil)
        }
        #expect(try String(contentsOf: job.plistURL, encoding: .utf8) == Fixtures.daily)
        #expect(await env.launchctl.calls == [.bootout("gui/501", "com.onkron.market-prices")])
    }

    @Test func lintFailureRestoresFile() async throws {
        let env = try Env()
        env.runner.handler = { _, _ in CommandResult(exitCode: 1, stdout: "", stderr: "bad") }
        let job = try env.install(Fixtures.daily, name: "a.plist")
        await #expect(throws: OrbitoError.self) {
            _ = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
        }
        #expect(try String(contentsOf: job.plistURL, encoding: .utf8) == Fixtures.daily)
        #expect(await env.launchctl.calls.isEmpty)
    }

    @Test func refusesWhenFileChangedOnDisk() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "a.plist")
        try Fixtures.interval.write(to: job.plistURL, atomically: true, encoding: .utf8)
        await #expect(throws: OrbitoError.self) {
            _ = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
        }
        #expect(try String(contentsOf: job.plistURL, encoding: .utf8) == Fixtures.interval)
    }

    @Test func readOnlyJobsAreRejected() async throws {
        let env = try Env()
        var job = try env.install(Fixtures.daily, name: "a.plist")
        job.scope = .globalDaemon
        await #expect(throws: OrbitoError.readOnlyJob(label: job.label)) {
            _ = try await env.operations.saveSchedule(.none, for: job)
        }
        #expect(await env.launchctl.calls.isEmpty)
    }

    @Test func invalidScheduleIsRejectedBeforeWriting() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "a.plist")
        await #expect(throws: OrbitoError.self) {
            _ = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 61)]), for: job)
        }
        #expect(try String(contentsOf: job.plistURL, encoding: .utf8) == Fixtures.daily)
    }

    @Test func createWritesAndLoads() async throws {
        let env = try Env()
        var form = JobForm()
        form.label = "com.example.new"
        form.executable = "/bin/zsh"
        form.arguments = [ArgumentItem(value: "/tmp/script.sh")]
        var draft = ScheduleDraft()
        draft.mode = .daily
        draft.times = [TimeOfDay(hour: 8, minute: 0)]
        let dict = PlistService.applying(try draft.build(), to: form.applying(to: [:]))

        let report = try await env.operations.create(dict: dict, existingLabels: [], load: true)
        let url = env.agents.appending(path: "com.example.new.plist")
        let (written, _) = try PlistService.read(url)
        #expect(written["ProgramArguments"] == .array([.string("/bin/zsh"), .string("/tmp/script.sh")]))
        #expect(written["RunAtLoad"] == nil)
        #expect(report.title.contains("создано"))
        #expect(await env.launchctl.calls == [.bootstrap(LaunchDomain.currentGUI.target, url.path)])
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o644)
    }

    @Test func createRejectsLabelConflicts() async throws {
        let env = try Env()
        _ = try env.install(Fixtures.daily, name: "com.onkron.market-prices.plist")
        let dict: [String: PlistValue] = ["Label": .string("com.onkron.market-prices"), "Program": .string("/bin/echo")]
        await #expect(throws: OrbitoError.labelConflict("com.onkron.market-prices")) {
            _ = try await env.operations.create(dict: dict, existingLabels: ["com.onkron.market-prices"], load: false)
        }
        // Even if not known to the app, an existing file is never overwritten.
        await #expect(throws: OrbitoError.self) {
            _ = try await env.operations.create(dict: dict, existingLabels: [], load: false)
        }
        #expect(try String(contentsOf: env.agents.appending(path: "com.onkron.market-prices.plist"), encoding: .utf8) == Fixtures.daily)
    }

    @Test func duplicateIsNotLoaded() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "com.onkron.market-prices.plist")
        _ = try await env.operations.duplicate(job, newLabel: "com.onkron.market-prices.copy", existingLabels: [job.label])
        let (copy, _) = try PlistService.read(env.agents.appending(path: "com.onkron.market-prices.copy.plist"))
        #expect(copy["Label"] == .string("com.onkron.market-prices.copy"))
        #expect(copy["X-Custom-Key"] == job.raw["X-Custom-Key"])
        #expect(await env.launchctl.calls.isEmpty)
    }

    @Test func deleteUnloadsBacksUpAndTrashes() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "com.onkron.market-prices.plist")
        let report = try await env.operations.delete(job)
        #expect(!FileManager.default.fileExists(atPath: job.plistURL.path))
        #expect(try String(contentsOf: try #require(report.backupURL), encoding: .utf8) == Fixtures.daily)
        #expect(await env.launchctl.calls == [.bootout("gui/501", "com.onkron.market-prices")])
    }

    @Test func runNowRequiresLoadedJob() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "a.plist", loaded: .no)
        await #expect(throws: OrbitoError.notLoaded(label: job.label)) {
            try await env.operations.runNow(job)
        }
        let loaded = try env.install(Fixtures.daily, name: "b.plist", loaded: .yes)
        try await env.operations.runNow(loaded)
        #expect(await env.launchctl.calls == [.kickstart("gui/501/com.onkron.market-prices", false)])
    }

    @Test func disableAndEnable() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "a.plist", loaded: .yes)
        try await env.operations.disable(job, unloadNow: true)
        var unloaded = job
        unloaded.runtime.loaded = .no
        try await env.operations.enable(unloaded, loadAfter: true)
        #expect(await env.launchctl.calls == [
            .disable("gui/501/com.onkron.market-prices"),
            .bootout("gui/501", "com.onkron.market-prices"),
            .enable("gui/501/com.onkron.market-prices"),
            .bootstrap("gui/501", job.plistURL.path),
        ])
    }

    @Test func sameLabelFromAnotherFileIsNeverReloaded() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "com.onkron.market-prices copy.plist")
        await env.launchctl.setLoadedPath(job.label, env.agents.appending(path: "com.onkron.market-prices.plist").path)

        let report = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
        #expect(report.status == .partial)
        #expect(await env.launchctl.calls.isEmpty)
        await #expect(throws: OrbitoError.self) { try await env.operations.delete(job) }
        await #expect(throws: OrbitoError.self) { try await env.operations.runNow(job) }
        #expect(await env.launchctl.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: job.plistURL.path))
    }

    @Test func matchingLoadedPathAllowsReload() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "com.onkron.market-prices.plist")
        await env.launchctl.setLoadedPath(job.label, job.plistURL.path)
        let report = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
        #expect(report.status == .success)
        #expect(await env.launchctl.calls.count == 2)
    }

    @Test func disabledJobIsNotReloaded() async throws {
        let env = try Env()
        var job = try env.install(Fixtures.daily, name: "a.plist")
        job.runtime.overridesKnown = true
        job.runtime.disabledOverride = true
        let report = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
        #expect(report.status == .partial)
        #expect(await env.launchctl.calls.isEmpty)
        await #expect(throws: OrbitoError.self) { try await env.operations.reload(job) }
    }

    @Test func unknownStateIsPartialAndDeleteStillUnloads() async throws {
        let env = try Env()
        let job = try env.install(Fixtures.daily, name: "a.plist", loaded: .unknown)
        let report = try await env.operations.saveSchedule(JobSchedule(calendar: [CalendarEntry(minute: 0, hour: 8)]), for: job)
        #expect(report.status == .partial)

        let fresh = try env.install(Fixtures.interval, name: "b.plist", loaded: .unknown)
        await env.launchctl.failBootout(code: 113)
        let deleted = try await env.operations.delete(fresh)
        #expect(deleted.details.contains { $0.contains("уже не было загружено") })
        #expect(await env.launchctl.calls.contains(.bootout("gui/501", "com.example.interval")))
    }

    @Test func createLoadFailureIsPartial() async throws {
        let env = try Env()
        await env.launchctl.failBootstrap(times: 1, code: 1)
        let dict: [String: PlistValue] = ["Label": .string("com.example.p"), "Program": .string("/bin/echo")]
        let report = try await env.operations.create(dict: dict, existingLabels: [], load: true)
        #expect(report.status == .partial)
    }

    @Test func editorFormPreservesUnrelatedKeys() throws {
        let (dict, _) = try PlistService.decode(Data(Fixtures.daily.utf8), path: "x")
        let job = LaunchJob.make(from: dict, at: URL(filePath: "/tmp/x.plist"))
        var form = JobForm(job: job)
        #expect(form.executable == "/usr/bin/caffeinate")
        #expect(form.arguments.map(\.value) == ["-i", "/Users/user/Scripts/nightly-prices.sh"])
        form.workingDirectory = "/tmp"
        let updated = form.applying(to: dict)
        var expected = dict
        expected["WorkingDirectory"] = .string("/tmp")
        #expect(updated == expected)
    }
}

@Suite("Labels")
struct LabelTests {
    @Test func syntax() {
        #expect(LabelValidator.isValidSyntax("com.onkron.market-prices"))
        #expect(LabelValidator.isValidSyntax("local.my_task-2"))
        #expect(!LabelValidator.isValidSyntax(""))
        #expect(!LabelValidator.isValidSyntax("has space"))
        #expect(!LabelValidator.isValidSyntax("../escape"))
        #expect(!LabelValidator.isValidSyntax("slash/inside"))
        #expect(!LabelValidator.isValidSyntax("кириллица"))
    }

    @Test func conflicts() throws {
        let tmp = try TempDir()
        _ = try tmp.write("com.exists.plist", "x")
        #expect(throws: OrbitoError.labelConflict("com.loaded")) {
            try LabelValidator.validateNew("com.loaded", existingLabels: ["com.loaded"], directory: tmp.url)
        }
        #expect(throws: OrbitoError.self) {
            try LabelValidator.validateNew("com.exists", existingLabels: [], directory: tmp.url)
        }
        #expect(throws: OrbitoError.self) {
            try LabelValidator.validateNew("com.apple.fake", existingLabels: [], directory: tmp.url)
        }
        try LabelValidator.validateNew("com.free", existingLabels: ["com.loaded"], directory: tmp.url)
    }

    @Test func suggestions() {
        #expect(LabelValidator.suggestedLabel(from: "Ozon Sync") == "local.ozon-sync")
        #expect(LabelValidator.suggestedLabel(from: "Парсер цен").hasPrefix("local."))
        #expect(LabelValidator.isValidSyntax(LabelValidator.suggestedLabel(from: "Парсер цен")))
        #expect(LabelValidator.uniqueCopyLabel(for: "a", existing: ["a.copy"]) == "a.copy2")
    }

    @Test func prettyName() {
        #expect(LaunchJob.prettyName(from: "com.onkron.market-prices") == "Market Prices")
    }

    @Test func shellCommandQuoting() {
        #expect(Workspace.shellCommand(["/bin/zsh", "/Users/u/My Scripts/a.sh", "it's"]) == "/bin/zsh '/Users/u/My Scripts/a.sh' 'it'\\''s'")
    }
}

@Suite("Log tail")
struct LogServiceTests {
    @Test func readsLastLinesOfLargeFile() throws {
        let tmp = try TempDir()
        let url = tmp.url.appending(path: "big.log")
        let lines = (1...50_000).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let snapshot = LogService(chunkSize: 4096).tail(path: url.path, lines: 100)
        #expect(snapshot.state == .ok)
        #expect(snapshot.lines.count == 100)
        #expect(snapshot.lines.first == "line 49901")
        #expect(snapshot.lines.last == "line 50000")
        #expect(snapshot.truncated)
    }

    @Test func smallFileAndMissingStates() throws {
        let tmp = try TempDir()
        let url = try tmp.write("small.log", "a\nb")
        let snapshot = LogService().tail(path: url.path, lines: 100)
        #expect(snapshot.lines == ["a", "b"])
        #expect(!snapshot.truncated)
        #expect(LogService().tail(path: tmp.url.appending(path: "nope.log").path, lines: 10).state == .missing)
        #expect(LogService().tail(path: nil, lines: 10).state == .notConfigured)
    }
}
