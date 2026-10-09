import Foundation

/// Structured launchctl failure with a human explanation.
struct LaunchctlFailure: Error, Equatable, Sendable {
    var arguments: [String]
    var exitCode: Int32
    var output: String

    var command: String { (["launchctl"] + arguments).joined(separator: " ") }

    var explanation: String {
        let lower = output.lowercased()
        if lower.contains("could not find service") || exitCode == 113 {
            return "Служба не найдена в launchd (не загружена)."
        }
        if lower.contains("service is disabled") || exitCode == 119 {
            return "Служба отключена (disabled). Сначала включите её."
        }
        if lower.contains("already loaded") || lower.contains("already bootstrapped") || exitCode == 17 || exitCode == 37 {
            return "Служба уже загружена или операция уже выполняется."
        }
        if lower.contains("operation not permitted") || exitCode == 1 && lower.contains("not permitted") {
            return "Операция запрещена системой (нужны права администратора или служба защищена)."
        }
        if lower.contains("input/output error") || exitCode == 5 {
            return "launchd отклонил задание (Input/output error). Частые причины: служба уже загружена, отключена, plist содержит ошибку или имеет неверные права доступа."
        }
        if lower.contains("no such process") || exitCode == 3 {
            return "Процесс или служба не найдены."
        }
        if lower.contains("path had bad ownership/permissions") {
            return "У plist неверный владелец или права доступа (файл не должен быть доступен на запись группе/всем)."
        }
        return "launchctl завершился с кодом \(exitCode)."
    }

    var localizedDescription: String {
        let details = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return details.isEmpty ? "\(explanation)\nКоманда: \(command)" : "\(explanation)\n\(details)\nКоманда: \(command)"
    }
}

struct LoadedService: Hashable, Sendable {
    var label: String
    var pid: Int?
    var lastExit: LastExit
}

protocol LaunchctlControlling: Sendable {
    /// Loaded services of a domain, keyed by label.
    func loadedServices(in domain: LaunchDomain) async throws -> [String: LoadedService]
    /// Override database (`print-disabled`): label → isDisabled.
    func disabledOverrides(in domain: LaunchDomain) async throws -> [String: Bool]
    func serviceDetails(_ label: String, in domain: LaunchDomain) async throws -> ServiceDetails?
    func bootstrap(plist: URL, in domain: LaunchDomain) async throws
    func bootout(_ label: String, in domain: LaunchDomain) async throws
    func kickstart(_ label: String, in domain: LaunchDomain, killRunning: Bool) async throws
    func enable(_ label: String, in domain: LaunchDomain) async throws
    func disable(_ label: String, in domain: LaunchDomain) async throws
    func kill(_ signal: String, _ label: String, in domain: LaunchDomain) async throws
}

struct LaunchctlService: LaunchctlControlling {
    static let executable = URL(filePath: "/bin/launchctl")
    var runner: any CommandRunning = ProcessCommandRunner()

    @discardableResult
    private func launchctl(_ arguments: [String]) async throws -> CommandResult {
        let result = try await runner.run(Self.executable, arguments: arguments)
        guard result.exitCode == 0 else {
            throw OrbitoError.launchctl(LaunchctlFailure(arguments: arguments, exitCode: result.exitCode, output: result.combinedOutput))
        }
        return result
    }

    func loadedServices(in domain: LaunchDomain) async throws -> [String: LoadedService] {
        if domain == LaunchDomain.currentGUI {
            // `launchctl list` reports the caller's GUI domain with stable columns.
            let result = try await launchctl(["list"])
            return Self.parseList(result.stdout)
        }
        let result = try await launchctl(["print", domain.target])
        return Self.parsePrintDomainServices(result.stdout)
    }

    func disabledOverrides(in domain: LaunchDomain) async throws -> [String: Bool] {
        let result = try await launchctl(["print-disabled", domain.target])
        return Self.parsePrintDisabled(result.stdout)
    }

    func serviceDetails(_ label: String, in domain: LaunchDomain) async throws -> ServiceDetails? {
        let arguments = ["print", domain.serviceTarget(label)]
        let result = try await runner.run(Self.executable, arguments: arguments)
        if result.exitCode == 113 { return nil }
        guard result.exitCode == 0 else {
            throw OrbitoError.launchctl(LaunchctlFailure(arguments: arguments, exitCode: result.exitCode, output: result.combinedOutput))
        }
        return Self.parseServiceDetails(result.stdout)
    }

    func bootstrap(plist: URL, in domain: LaunchDomain) async throws {
        try await launchctl(["bootstrap", domain.target, plist.path])
    }

    func bootout(_ label: String, in domain: LaunchDomain) async throws {
        try await launchctl(["bootout", domain.serviceTarget(label)])
    }

    func kickstart(_ label: String, in domain: LaunchDomain, killRunning: Bool) async throws {
        var args = ["kickstart"]
        if killRunning { args.append("-k") }
        args.append(domain.serviceTarget(label))
        try await launchctl(args)
    }

    func enable(_ label: String, in domain: LaunchDomain) async throws {
        try await launchctl(["enable", domain.serviceTarget(label)])
    }

    func disable(_ label: String, in domain: LaunchDomain) async throws {
        try await launchctl(["disable", domain.serviceTarget(label)])
    }

    func kill(_ signal: String, _ label: String, in domain: LaunchDomain) async throws {
        try await launchctl(["kill", signal, domain.serviceTarget(label)])
    }

    // MARK: - Parsers

    /// Parses `launchctl list`: `PID\tStatus\tLabel`.
    static func parseList(_ output: String) -> [String: LoadedService] {
        var services: [String: LoadedService] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 3, columns[0] != "PID" else { continue }
            let label = columns[2...].joined(separator: "\t")
            guard !label.isEmpty else { continue }
            let pid = Int(columns[0])
            let lastExit: LastExit = Int(columns[1]).map(LastExit.init(listStatus:)) ?? .none
            services[label] = LoadedService(label: label, pid: pid, lastExit: lastExit)
        }
        return services
    }

    /// Parses the `services = { … }` block of `launchctl print <domain>`.
    /// Rows: `<pid or 0> <last exit or - or (xx)> <label>`.
    static func parsePrintDomainServices(_ output: String) -> [String: LoadedService] {
        var services: [String: LoadedService] = [:]
        var inBlock = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if line.hasPrefix("services = {") { inBlock = true }
                continue
            }
            if line == "}" { break }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 3 else { continue }
            let pidValue = Int(parts[0]) ?? 0
            let lastExit: LastExit = Int(parts[1]).map(LastExit.init(listStatus:)) ?? (parts[1] == "-" ? .none : .unknown)
            let label = parts[2...].joined(separator: " ")
            services[label] = LoadedService(label: label, pid: pidValue > 0 ? pidValue : nil, lastExit: lastExit)
        }
        return services
    }

    /// Parses `"label" => disabled|enabled|true|false`.
    static func parsePrintDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let arrow = line.range(of: "=>") else { continue }
            let label = line[..<arrow.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    static func parseServiceDetails(_ output: String) -> ServiceDetails {
        var details = ServiceDetails(raw: output)
        for rawLine in output.split(whereSeparator: \.isNewline) {
            // Only top-level keys (one tab of indentation).
            guard rawLine.hasPrefix("\t"), !rawLine.hasPrefix("\t\t") else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.range(of: " = ") else { continue }
            let key = String(line[..<eq.lowerBound])
            let value = String(line[eq.upperBound...])
            switch key {
            case "state": details.state = value
            case "pid": details.pid = Int(value)
            case "runs": details.runs = Int(value)
            case "last exit code": details.lastExitCode = value
            case "last exit reason": details.lastExitReason = value
            case "program": details.program = value
            case "domain": details.domain = value
            case "path": details.path = value
            default: break
            }
        }
        return details
    }
}
