import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Login item via SMAppService (no helper, no private API).
enum LoginItemService {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Включено"
        case .notRegistered: "Выключено"
        case .requiresApproval: "Требует подтверждения в Системных настройках → Основные → Объекты входа"
        case .notFound: "Недоступно для этой сборки"
        @unknown default: "Неизвестно"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Posts notifications only about failures actually observed by the running app.
enum NotificationService {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func notifyFailure(label: String, name: String, detail: String) {
        let content = UNMutableNotificationContent()
        content.title = "Ошибка задания: \(name)"
        content.body = detail
        content.sound = .default
        content.userInfo = ["label": label]
        let request = UNNotificationRequest(identifier: "failure-\(label)-\(Date.now.timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum Workspace {
    @MainActor static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Shell-quoted rendering of argv, for copying only — never executed by the app.
    static func shellCommand(_ argv: [String]) -> String {
        argv.map { arg in
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-=:+,@%"))
            if !arg.isEmpty, arg.unicodeScalars.allSatisfy(safe.contains) { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
