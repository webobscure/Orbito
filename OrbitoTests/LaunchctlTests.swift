import Foundation
import Testing
@testable import Orbito

@Suite("launchctl parsing and errors")
struct LaunchctlTests {
    @Test func parsesList() {
        let output = """
        PID\tStatus\tLabel
        -\t0\tcom.onkron.market-prices
        27849\t-9\tcom.apple.progressd
        -\t78\tcom.openai.atlas.update-helper
        40774\t0\tcom.openssh.ssh-agent
        """
        let services = LaunchctlService.parseList(output)
        #expect(services.count == 4)
        #expect(services["com.onkron.market-prices"] == LoadedService(label: "com.onkron.market-prices", pid: nil, lastExit: .exitCode(0)))
        #expect(services["com.apple.progressd"]?.lastExit == .signal(9))
        #expect(services["com.apple.progressd"]?.pid == 27849)
        #expect(services["com.openai.atlas.update-helper"]?.lastExit == .exitCode(78))
        #expect(services["com.openai.atlas.update-helper"]?.lastExit.isFailure == true)
    }

    @Test func parsesPrintDisabled() {
        let output = """

        \tdisabled services = {
        \t\t"com.bjango.istatmenus.agent" => enabled
        \t\t"com.apple.ManagedClientAgent.enrollagent" => disabled
        \t\t"com.legacy.thing" => true
        \t\t"com.legacy.other" => false
        \t}
        """
        let result = LaunchctlService.parsePrintDisabled(output)
        #expect(result == [
            "com.bjango.istatmenus.agent": false,
            "com.apple.ManagedClientAgent.enrollagent": true,
            "com.legacy.thing": true,
            "com.legacy.other": false,
        ])
    }

    @Test func parsesDomainServicesBlock() {
        let output = """
        system = {
        \ttype = system
        \tservices = {
        \t\t    1382      - \tapplication.com.dwarvesv.minimalbar
        \t\t   80170   (pe) \tcom.apple.syncdefaultsd
        \t\t       0      0 \tcom.apple.DataDetectorsLocalSources
        \t\t       0     78 \tcom.example.failed
        \t}
        }
        """
        let services = LaunchctlService.parsePrintDomainServices(output)
        #expect(services["application.com.dwarvesv.minimalbar"]?.pid == 1382)
        #expect(services["application.com.dwarvesv.minimalbar"]?.lastExit == LastExit.none)
        #expect(services["com.apple.syncdefaultsd"]?.lastExit == .unknown)
        #expect(services["com.apple.DataDetectorsLocalSources"]?.pid == nil)
        #expect(services["com.example.failed"]?.lastExit == .exitCode(78))
    }

    @Test func parsesServiceDetails() {
        let output = """
        gui/501/com.onkron.market-prices = {
        \tactive count = 0
        \tstate = not running
        \tprogram = /usr/bin/caffeinate
        \truns = 3
        \tlast exit code = 1
        \tevent triggers = {
        \t\tstate = active
        \t}
        }
        """
        let details = LaunchctlService.parseServiceDetails(output)
        #expect(details.state == "not running")
        #expect(details.runs == 3)
        #expect(details.lastExitCode == "1")
        #expect(details.program == "/usr/bin/caffeinate")
    }

    @Test func buildsCorrectArguments() async throws {
        let runner = MockRunner()
        let service = LaunchctlService(runner: runner)
        let domain = LaunchDomain.gui(uid: 501)
        try await service.bootout("com.onkron.market-prices", in: domain)
        try await service.bootstrap(plist: URL(filePath: "/Users/user/Library/LaunchAgents/com.onkron.market-prices.plist"), in: domain)
        try await service.kickstart("com.x", in: domain, killRunning: true)
        try await service.disable("com.x", in: domain)
        try await service.enable("com.x", in: .user(uid: 501))
        #expect(runner.invocations == [
            ["/bin/launchctl", "bootout", "gui/501/com.onkron.market-prices"],
            ["/bin/launchctl", "bootstrap", "gui/501", "/Users/user/Library/LaunchAgents/com.onkron.market-prices.plist"],
            ["/bin/launchctl", "kickstart", "-k", "gui/501/com.x"],
            ["/bin/launchctl", "disable", "gui/501/com.x"],
            ["/bin/launchctl", "enable", "user/501/com.x"],
        ])
    }

    @Test func labelsWithShellCharactersAreNotInterpreted() async throws {
        let runner = MockRunner()
        let service = LaunchctlService(runner: runner)
        try await service.kickstart("a; rm -rf ~", in: .gui(uid: 501), killRunning: false)
        // Passed as one argv element, never through a shell.
        #expect(runner.invocations.last == ["/bin/launchctl", "kickstart", "gui/501/a; rm -rf ~"])
    }

    @Test func mapsErrors() async {
        let runner = MockRunner { _, args in
            if args.first == "kickstart" {
                return CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service \"x\" in domain for user gui: 501")
            }
            return CommandResult(exitCode: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error")
        }
        let service = LaunchctlService(runner: runner)
        do {
            try await service.kickstart("x", in: .gui(uid: 501), killRunning: false)
            Issue.record("expected failure")
        } catch let OrbitoError.launchctl(failure) {
            #expect(failure.exitCode == 113)
            #expect(failure.explanation.contains("не загружена"))
            #expect(failure.command == "launchctl kickstart gui/501/x")
        } catch {
            Issue.record("unexpected \(error)")
        }
        do {
            try await service.bootstrap(plist: URL(filePath: "/tmp/x.plist"), in: .gui(uid: 501))
            Issue.record("expected failure")
        } catch let OrbitoError.launchctl(failure) {
            #expect(failure.exitCode == 5)
            #expect(failure.localizedDescription.contains("Input/output error"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func serviceDetailsNotFoundIsNil() async throws {
        let runner = MockRunner { _, _ in CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service") }
        let details = try await LaunchctlService(runner: runner).serviceDetails("x", in: .gui(uid: 501))
        #expect(details == nil)
    }

    @Test func domainSelection() {
        var def = JobDefinition()
        #expect(LaunchAgentScanner.domain(for: .userAgent, definition: def, uid: 501) == .gui(uid: 501))
        #expect(LaunchAgentScanner.domain(for: .globalDaemon, definition: def, uid: 501) == .system)
        def.limitLoadToSessionType = ["Background"]
        #expect(LaunchAgentScanner.domain(for: .userAgent, definition: def, uid: 501) == .user(uid: 501))
        def.limitLoadToSessionType = ["Aqua", "Background"]
        #expect(LaunchAgentScanner.domain(for: .globalAgent, definition: def, uid: 501) == .gui(uid: 501))
        #expect(LaunchDomain.system.serviceTarget("com.x") == "system/com.x")
    }

    @Test func realProcessRunnerCapturesOutput() async throws {
        let result = try await ProcessCommandRunner().run(URL(filePath: "/bin/echo"), arguments: ["hello", "$HOME", "a b"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello $HOME a b\n")
    }
}

@Suite("Scanning")
struct ScannerTests {
    @Test func separatesFileLoadedRunningDisabled() async throws {
        let tmp = try TempDir()
        _ = try tmp.write("com.onkron.market-prices.plist", Fixtures.daily)
        _ = try tmp.write("com.example.weekdays.plist", Fixtures.array)
        _ = try tmp.write("com.example.interval.plist", Fixtures.interval)
        _ = try tmp.write("broken.plist", "<plist><dict>")
        _ = try tmp.write("notes.txt", "ignored")

        let launchctl = MockLaunchctl()
        await launchctl.setLoaded([
            "com.onkron.market-prices": LoadedService(label: "com.onkron.market-prices", pid: nil, lastExit: .exitCode(1)),
            "com.example.interval": LoadedService(label: "com.example.interval", pid: 123, lastExit: .none),
        ])
        await launchctl.setOverrides(["com.example.weekdays": true])

        let scanner = LaunchAgentScanner(launchctl: launchctl, directories: [.userAgent: tmp.url], uid: 501)
        let result = await scanner.scan(includeSystem: false)
        let byLabel = Dictionary(uniqueKeysWithValues: result.jobs.map { ($0.label, $0) })

        #expect(result.jobs.count == 4)
        let market = try #require(byLabel["com.onkron.market-prices"])
        #expect(market.runtime.loaded == .yes)
        #expect(market.runtime.isRunning == .no)
        #expect(market.isDisabled == .no)
        #expect(market.runtime.lastExit == .exitCode(1))
        #expect(JobHealth(job: market) == .lastRunFailed)

        let interval = try #require(byLabel["com.example.interval"])
        #expect(interval.runtime.isRunning == .yes)
        #expect(JobHealth(job: interval) == .running)

        let weekdays = try #require(byLabel["com.example.weekdays"])
        #expect(weekdays.runtime.loaded == .no)
        #expect(weekdays.isDisabled == .yes)
        #expect(JobHealth(job: weekdays) == .disabled)

        let broken = try #require(byLabel["broken"])
        #expect(broken.loadError != nil)
        #expect(JobHealth(job: broken) == .invalid)
    }

    @Test func unknownStateWhenLaunchctlFails() async throws {
        let tmp = try TempDir()
        _ = try tmp.write("com.onkron.market-prices.plist", Fixtures.daily)
        let launchctl = MockLaunchctl()
        await launchctl.setListFails(true)
        let result = await LaunchAgentScanner(launchctl: launchctl, directories: [.userAgent: tmp.url], uid: 501).scan(includeSystem: false)
        let job = try #require(result.jobs.first)
        #expect(job.runtime.loaded == .unknown)
        #expect(job.runtime.lastExit == .unknown)
        #expect(JobHealth(job: job) == .unknown)
        #expect(!result.warnings.isEmpty)
    }

    @Test func zeroExitIsNotAnError() {
        var job = LaunchJob.make(from: ["Label": .string("x"), "Program": .string("/bin/echo")], at: URL(filePath: "/tmp/x.plist"))
        job.runtime.lastExit = .exitCode(0)
        #expect(!job.runtime.lastExit.isFailure)
        #expect(JobHealth(job: job) == .loaded)
    }
}
