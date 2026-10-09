import Foundation

/// Result of a mutation, shown to the user verbatim.
struct OperationReport: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case success
        /// Part of the operation succeeded; details explain what did not.
        case partial
    }

    var title: String
    var status: Status = .success
    var details: [String] = []
    var backupURL: URL?
}

/// All state-changing operations. Each one validates first, backs up,
/// writes atomically, applies through launchctl and restores on failure.
struct JobOperations: Sendable {
    var launchctl: any LaunchctlControlling
    var plist: PlistService
    var backups: BackupService
    var agentsDirectory: URL = JobScope.userAgent.directory
    /// Delay between bootout and bootstrap retries (launchd tears down asynchronously).
    var retryDelay: Duration = .milliseconds(300)
    var bootstrapAttempts = 5
    /// Records file and internal operations into Command History.
    var journal = OperationJournal()

    // MARK: Editing an existing job

    /// Replaces the schedule keys of `job` and reloads it if it was loaded.
    func saveSchedule(_ schedule: JobSchedule, for job: LaunchJob) async throws -> OperationReport {
        try ensureEditable(job)
        let errors = schedule.calendar.flatMap(\.validationErrors) + ((schedule.interval ?? 1) < 1 ? ["StartInterval должен быть положительным."] : [])
        guard errors.isEmpty else { throw OrbitoError.scheduleInvalid(errors) }
        let updated = PlistService.applying(schedule, to: job.raw)
        return try await replacePlist(of: job, with: updated, actionTitle: "Расписание сохранено")
    }

    /// Writes an arbitrary new dictionary for `job` (used by the editor).
    func saveDefinition(_ dict: [String: PlistValue], for job: LaunchJob) async throws -> OperationReport {
        try ensureEditable(job)
        guard dict["Label"]?.stringValue == job.label else {
            throw OrbitoError.invalidLabel(dict["Label"]?.stringValue ?? "")
        }
        return try await replacePlist(of: job, with: dict, actionTitle: "Задание сохранено")
    }

    private func replacePlist(of job: LaunchJob, with dict: [String: PlistValue], actionTitle: String) async throws -> OperationReport {
        let url = job.plistURL
        let originalData: Data
        do {
            originalData = try Data(contentsOf: url)
        } catch {
            throw OrbitoError.invalidPlist(path: url.path, reason: error.localizedDescription)
        }
        // Refuse to overwrite a file changed on disk since it was scanned.
        let current = try PlistService.decode(originalData, path: url.path)
        guard current.dict == job.raw else {
            throw OrbitoError.writeFailed(path: url.path, reason: "файл был изменён другой программой. Обновите список и повторите.")
        }
        guard dict != job.raw else {
            return OperationReport(title: "Изменений нет", details: ["Файл не изменён."])
        }

        let backupURL = try backups.backup(originalData, label: job.label)
        await journal.file("Резервная копия", backupURL.path)
        var report = OperationReport(title: actionTitle, backupURL: backupURL)
        report.details.append("Резервная копия: \(backupURL.path)")

        // Write + validate.
        do {
            try PlistService.write(dict, format: job.format, to: url, allowOverwrite: true)
            await journal.internal("PropertyListSerialization: файл декодирован обратно и совпал с ожидаемым")
            await journal.file("Атомарная запись plist", url.path)
            try await plist.lint(url)
        } catch {
            let restored = restore(originalData, to: url)
            await journal.file(restored ? "Откат: исходный plist восстановлен" : "Откат НЕ удался", url.path)
            throw OrbitoError.applyFailed(reason: error.localizedDescription, restoredFile: restored, restoredLaunchd: nil)
        }
        report.details.append("Файл записан и прошёл проверку plutil.")

        // Apply only if the job was loaded; otherwise leave launchd alone.
        guard job.runtime.loaded == .yes else {
            if job.runtime.loaded == .no {
                report.details.append("Задание не было загружено в launchd — изменения вступят в силу после загрузки.")
            } else {
                report.status = .partial
                report.details.append("Состояние в launchd неизвестно — задание не перезагружалось. Проверьте его и перезагрузите вручную.")
            }
            return report
        }
        // A disabled service cannot be bootstrapped again: reloading would leave it unloaded.
        guard job.isDisabled == .no else {
            report.status = .partial
            report.details.append("Задание отключено (disabled), поэтому не перезагружалось. Изменения вступят в силу после включения и загрузки.")
            return report
        }
        do {
            try await verifyLoadedInstance(of: job)
        } catch {
            report.status = .partial
            report.details.append(error.localizedDescription)
            report.details.append("Файл сохранён, но задание не перезагружалось, чтобы не затронуть другую службу.")
            return report
        }

        var bootedOut = false
        do {
            do {
                try await launchctl.bootout(job.label, in: job.runtime.domain)
            } catch OrbitoError.launchctl(let failure) where failure.exitCode == 113 || failure.exitCode == 3 {
                // Already gone; continue with bootstrap.
            }
            bootedOut = true
            try await bootstrapWithRetry(plist: url, domain: job.runtime.domain)
            report.details.append("Задание перезагружено в launchd (\(job.runtime.domain.target)).")
            return report
        } catch {
            let restoredFile = restore(originalData, to: url)
            await journal.file(restoredFile ? "Откат: исходный plist восстановлен" : "Откат НЕ удался", url.path)
            var restoredLaunchd: Bool?
            var reason = error.localizedDescription
            if bootedOut {
                // Old definition was unloaded: bring it back, or say plainly that it is gone.
                restoredLaunchd = restoredFile ? (try? await bootstrapWithRetry(plist: url, domain: job.runtime.domain)) != nil : false
            } else {
                // bootout failed (or timed out): launchd state is not known for sure.
                reason += "\nbootout не выполнен. Вероятно, прежняя версия задания осталась загруженной, но проверьте её состояние."
            }
            throw OrbitoError.applyFailed(reason: reason, restoredFile: restoredFile, restoredLaunchd: restoredLaunchd)
        }
    }

    /// Confirms the loaded service with this label was loaded from *this* plist,
    /// so a same-label file elsewhere never causes another job to be booted out.
    private func verifyLoadedInstance(of job: LaunchJob) async throws {
        guard let details = try await launchctl.serviceDetails(job.label, in: job.runtime.domain),
              let loadedPath = details.path else { return }
        let expected = job.plistURL.standardizedFileURL.resolvingSymlinksInPath().path
        let actual = URL(filePath: loadedPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard expected == actual else {
            throw OrbitoError.foreignService(label: job.label, loadedPath: loadedPath)
        }
    }

    private func restore(_ data: Data, to url: URL) -> Bool {
        do {
            try PlistService.writeData(data, to: url, allowOverwrite: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: Creating

    func create(dict: [String: PlistValue], existingLabels: Set<String>, load: Bool) async throws -> OperationReport {
        guard let label = dict["Label"]?.stringValue else { throw OrbitoError.invalidLabel("") }
        try LabelValidator.validateNew(label, existingLabels: existingLabels, directory: agentsDirectory)
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let url = agentsDirectory.appending(path: "\(label).plist")
        // launchd does not create missing log directories; create them only after validation.
        for path in [dict["StandardOutPath"]?.stringValue, dict["StandardErrorPath"]?.stringValue].compactMap({ $0 }) where path.hasPrefix("/") {
            let directory = URL(filePath: path).deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                await journal.file("Создан каталог для логов", directory.path)
            }
        }

        try PlistService.write(dict, format: .xml, to: url, allowOverwrite: false)
        await journal.file("Создан plist (без перезаписи)", url.path)
        do {
            try await plist.lint(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        var report = OperationReport(title: "Задание «\(label)» создано", details: ["Файл: \(url.path)"])
        guard load else {
            report.details.append("Задание не загружено в launchd.")
            return report
        }
        do {
            try await launchctl.bootstrap(plist: url, in: .currentGUI)
            report.details.append("Задание загружено в launchd (\(LaunchDomain.currentGUI.target)).")
        } catch {
            report.status = .partial
            report.title = "Файл создан, но загрузка не удалась"
            report.details.append(error.localizedDescription)
        }
        return report
    }

    /// Creates a copy with a new label. The copy is not loaded, to avoid double runs.
    func duplicate(_ job: LaunchJob, newLabel: String, existingLabels: Set<String>) async throws -> OperationReport {
        guard job.loadError == nil else { throw OrbitoError.invalidPlist(path: job.plistURL.path, reason: job.loadError ?? "") }
        var dict = job.raw
        dict["Label"] = .string(newLabel)
        var report = try await create(dict: dict, existingLabels: existingLabels, load: false)
        report.title = "Создана копия «\(newLabel)»"
        return report
    }

    /// Imports a plist from anywhere into ~/Library/LaunchAgents.
    func importPlist(from source: URL, existingLabels: Set<String>, load: Bool) async throws -> OperationReport {
        let (dict, _) = try PlistService.read(source)
        guard dict["Label"]?.stringValue != nil else {
            throw OrbitoError.invalidPlist(path: source.path, reason: "нет ключа Label")
        }
        return try await create(dict: dict, existingLabels: existingLabels, load: load)
    }

    // MARK: Deleting

    /// Unloads (if loaded), backs up and moves the plist to the Trash.
    func delete(_ job: LaunchJob) async throws -> OperationReport {
        try ensureEditable(job, allowInvalid: true)
        let data = try Data(contentsOf: job.plistURL)
        let backupURL = try backups.backup(data, label: job.label)
        await journal.file("Резервная копия", backupURL.path)
        var report = OperationReport(title: "Задание «\(job.label)» удалено", backupURL: backupURL)
        // Unknown state: still try to unload, otherwise a running job would lose its plist.
        if job.runtime.loaded != .no {
            try await verifyLoadedInstance(of: job)
            do {
                try await launchctl.bootout(job.label, in: job.runtime.domain)
                report.details.append("Выгружено из launchd.")
            } catch OrbitoError.launchctl(let failure) where failure.exitCode == 113 || failure.exitCode == 3 {
                report.details.append("В launchd задание уже не было загружено.")
            }
        }
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: job.plistURL, resultingItemURL: &trashed)
            await journal.file("Перемещено в Корзину", job.plistURL.path)
        } catch {
            throw OrbitoError.processFailed("Задание выгружено из launchd, но файл не удалось переместить в Корзину: \(error.localizedDescription)")
        }
        report.details.append("Файл перемещён в Корзину.")
        report.details.append("Резервная копия: \(backupURL.path)")
        return report
    }

    // MARK: launchd control

    func runNow(_ job: LaunchJob, killRunning: Bool = false) async throws {
        guard job.runtime.loaded != .no else { throw OrbitoError.notLoaded(label: job.label) }
        try await verifyLoadedInstance(of: job)
        try await launchctl.kickstart(job.label, in: job.runtime.domain, killRunning: killRunning)
    }

    /// Sends SIGTERM to the running process (KeepAlive jobs are restarted by launchd).
    func stop(_ job: LaunchJob) async throws {
        try ensureEditable(job, allowInvalid: true)
        guard job.runtime.loaded == .yes else { throw OrbitoError.notLoaded(label: job.label) }
        try await verifyLoadedInstance(of: job)
        try await launchctl.kill("SIGTERM", job.label, in: job.runtime.domain)
    }

    func load(_ job: LaunchJob) async throws {
        try ensureEditable(job)
        try await bootstrapWithRetry(plist: job.plistURL, domain: job.runtime.domain)
    }

    func unload(_ job: LaunchJob) async throws {
        try ensureEditable(job, allowInvalid: true)
        try await verifyLoadedInstance(of: job)
        try await launchctl.bootout(job.label, in: job.runtime.domain)
    }

    func reload(_ job: LaunchJob) async throws {
        try ensureEditable(job)
        guard job.isDisabled == .no else {
            throw OrbitoError.processFailed("Задание отключено (disabled): после выгрузки launchd не загрузит его снова. Сначала включите задание.")
        }
        try await verifyLoadedInstance(of: job)
        try await reload(label: job.label, plist: job.plistURL, domain: job.runtime.domain)
    }

    /// `enable` clears the disabled override; then loads the job if requested.
    func enable(_ job: LaunchJob, loadAfter: Bool) async throws {
        try ensureEditable(job)
        try await launchctl.enable(job.label, in: job.runtime.domain)
        if loadAfter, job.runtime.loaded != .yes {
            try await bootstrapWithRetry(plist: job.plistURL, domain: job.runtime.domain)
        }
    }

    /// `disable` persists in launchd's override database; optionally unloads now.
    func disable(_ job: LaunchJob, unloadNow: Bool) async throws {
        try ensureEditable(job, allowInvalid: true)
        try await launchctl.disable(job.label, in: job.runtime.domain)
        if unloadNow, job.runtime.loaded == .yes {
            try await verifyLoadedInstance(of: job)
            try await launchctl.bootout(job.label, in: job.runtime.domain)
        }
    }

    private func reload(label: String, plist url: URL, domain: LaunchDomain) async throws {
        do {
            try await launchctl.bootout(label, in: domain)
        } catch OrbitoError.launchctl(let failure) where failure.exitCode == 113 || failure.exitCode == 3 {
            // Already gone; continue with bootstrap.
        }
        try await bootstrapWithRetry(plist: url, domain: domain)
    }

    private func bootstrapWithRetry(plist url: URL, domain: LaunchDomain) async throws {
        var lastError: Error?
        for attempt in 0..<max(1, bootstrapAttempts) {
            do {
                try await launchctl.bootstrap(plist: url, in: domain)
                return
            } catch OrbitoError.launchctl(let failure) where failure.exitCode == 5 || failure.exitCode == 37 {
                // launchd may still be tearing the old instance down.
                lastError = OrbitoError.launchctl(failure)
                if attempt < bootstrapAttempts - 1 { try? await Task.sleep(for: retryDelay) }
            }
        }
        throw lastError ?? OrbitoError.processFailed("bootstrap не выполнен")
    }

    private func ensureEditable(_ job: LaunchJob, allowInvalid: Bool = false) throws {
        guard job.scope.isEditable else { throw OrbitoError.readOnlyJob(label: job.label) }
        if !allowInvalid, let error = job.loadError {
            throw OrbitoError.invalidPlist(path: job.plistURL.path, reason: error)
        }
        // Defence in depth: only touch files inside the user's LaunchAgents directory.
        let parent = job.plistURL.deletingLastPathComponent().standardizedFileURL.path
        guard parent == agentsDirectory.standardizedFileURL.path else {
            throw OrbitoError.readOnlyJob(label: job.label)
        }
    }
}
