import AppKit
import Foundation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Системная"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// User preferences persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme); applyTheme() } }
    var autoRefresh: Bool { didSet { defaults.set(autoRefresh, forKey: Keys.autoRefresh) } }
    var refreshInterval: Int { didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) } }
    var showSystemJobs: Bool { didSet { defaults.set(showSystemJobs, forKey: Keys.showSystemJobs) } }
    var backupPath: String { didSet { defaults.set(backupPath, forKey: Keys.backupPath) } }
    var logLineCount: Int { didSet { defaults.set(logLineCount, forKey: Keys.logLineCount) } }
    var notifyFailures: Bool { didSet { defaults.set(notifyFailures, forKey: Keys.notifyFailures) } }
    var confirmRunNow: Bool { didSet { defaults.set(confirmRunNow, forKey: Keys.confirmRunNow) } }
    var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: Keys.reduceMotion) } }
    var reduceTransparency: Bool { didSet { defaults.set(reduceTransparency, forKey: Keys.reduceTransparency) } }
    var defaultLogDirectory: String { didSet { defaults.set(defaultLogDirectory, forKey: Keys.defaultLogDirectory) } }

    // Developer Mode
    var developerMode: Bool { didSet { defaults.set(developerMode, forKey: Keys.developerMode) } }
    var cliTooltips: Bool { didSet { defaults.set(cliTooltips, forKey: Keys.cliTooltips) } }
    var previewBeforeChanges: Bool { didSet { defaults.set(previewBeforeChanges, forKey: Keys.previewBeforeChanges) } }
    var dryRun: Bool { didSet { defaults.set(dryRun, forKey: Keys.dryRun) } }
    var advancedLogs: Bool { didSet { defaults.set(advancedLogs, forKey: Keys.advancedLogs) } }
    var commandHistory: Bool { didSet { defaults.set(commandHistory, forKey: Keys.commandHistory) } }
    var defaultCLIPlatform: CLIPlatform { didSet { defaults.set(defaultCLIPlatform.rawValue, forKey: Keys.defaultCLIPlatform) } }

    private enum Keys {
        static let theme = "theme"
        static let autoRefresh = "autoRefresh"
        static let refreshInterval = "refreshInterval"
        static let showSystemJobs = "showSystemJobs"
        static let backupPath = "backupPath"
        static let logLineCount = "logLineCount"
        static let notifyFailures = "notifyFailures"
        static let confirmRunNow = "confirmRunNow"
        static let reduceMotion = "reduceMotion"
        static let reduceTransparency = "reduceTransparency"
        static let defaultLogDirectory = "defaultLogDirectory"
        static let developerMode = "developerMode"
        static let cliTooltips = "cliTooltips"
        static let previewBeforeChanges = "previewBeforeChanges"
        static let dryRun = "dryRun"
        static let advancedLogs = "advancedLogs"
        static let commandHistory = "commandHistory"
        static let defaultCLIPlatform = "defaultCLIPlatform"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        autoRefresh = Self.bool(defaults, Keys.autoRefresh, default: true)
        refreshInterval = defaults.object(forKey: Keys.refreshInterval) as? Int ?? 15
        showSystemJobs = Self.bool(defaults, Keys.showSystemJobs, default: false)
        backupPath = defaults.string(forKey: Keys.backupPath) ?? BackupService.defaultRoot.path
        logLineCount = defaults.object(forKey: Keys.logLineCount) as? Int ?? 500
        notifyFailures = Self.bool(defaults, Keys.notifyFailures, default: false)
        confirmRunNow = Self.bool(defaults, Keys.confirmRunNow, default: false)
        reduceMotion = Self.bool(defaults, Keys.reduceMotion, default: false)
        reduceTransparency = Self.bool(defaults, Keys.reduceTransparency, default: false)
        defaultLogDirectory = defaults.string(forKey: Keys.defaultLogDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Orbito").path
        developerMode = Self.bool(defaults, Keys.developerMode, default: false)
        cliTooltips = Self.bool(defaults, Keys.cliTooltips, default: true)
        previewBeforeChanges = Self.bool(defaults, Keys.previewBeforeChanges, default: true)
        dryRun = Self.bool(defaults, Keys.dryRun, default: false)
        advancedLogs = Self.bool(defaults, Keys.advancedLogs, default: true)
        commandHistory = Self.bool(defaults, Keys.commandHistory, default: true)
        defaultCLIPlatform = CLIPlatform(rawValue: defaults.string(forKey: Keys.defaultCLIPlatform) ?? "") ?? .macOS
    }

    /// `bool(forKey:)` also accepts "YES"/"1" strings (launch arguments, `defaults write`).
    private static func bool(_ defaults: UserDefaults, _ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    var backupURL: URL {
        backupPath.isEmpty ? BackupService.defaultRoot : URL(filePath: (backupPath as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    /// Developer features are active only while Developer Mode is on.
    var showsCLITooltips: Bool { developerMode && cliTooltips }
    var showsPreviewBeforeChanges: Bool { developerMode && previewBeforeChanges }
    var isDryRun: Bool { developerMode && dryRun }
    var showsAdvancedLogs: Bool { developerMode && advancedLogs }
    var recordsCommandHistory: Bool { developerMode && commandHistory }

    var animation: Animation? { reduceMotion ? nil : .smooth(duration: 0.3) }

    func applyTheme() {
        NSApp?.appearance = theme.appearance
    }
}
