import Foundation

/// Event recorded by Orbito itself. launchd keeps no per-run history,
/// so this log only contains actions performed or observed by the app.
struct HistoryEvent: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case runNow, stop, load, unload, reload, enable, disable
        case scheduleChanged, edited, rawEdited, created, duplicated, deleted, imported, restored
        case observedFailure, observedRecovery
        case dryRun

        var title: String {
            switch self {
            case .runNow: "Запуск вручную"
            case .stop: "Остановка процесса"
            case .load: "Загрузка в launchd"
            case .unload: "Выгрузка из launchd"
            case .reload: "Перезагрузка"
            case .enable: "Включение"
            case .disable: "Отключение"
            case .scheduleChanged: "Изменение расписания"
            case .edited: "Редактирование"
            case .rawEdited: "Правка plist вручную"
            case .created: "Создание"
            case .duplicated: "Дублирование"
            case .deleted: "Удаление"
            case .imported: "Импорт"
            case .restored: "Восстановление plist"
            case .observedFailure: "Замечена ошибка"
            case .observedRecovery: "Ошибка устранена"
            case .dryRun: "Dry Run"
            }
        }

        var symbol: String {
            switch self {
            case .runNow: "play.fill"
            case .stop: "stop.fill"
            case .load: "arrow.down.circle"
            case .unload: "arrow.up.circle"
            case .reload: "arrow.clockwise"
            case .enable: "power"
            case .disable: "pause.fill"
            case .scheduleChanged: "clock.arrow.circlepath"
            case .edited: "pencil"
            case .rawEdited: "chevron.left.forwardslash.chevron.right"
            case .created: "plus.circle"
            case .duplicated: "plus.square.on.square"
            case .deleted: "trash"
            case .imported: "square.and.arrow.down"
            case .restored: "arrow.uturn.backward"
            case .observedFailure: "exclamationmark.triangle"
            case .observedRecovery: "checkmark.seal"
            case .dryRun: "eye"
            }
        }
    }

    enum Outcome: String, Codable, Sendable {
        case success, failure, observed
    }

    var id = UUID()
    var date: Date
    var label: String
    var kind: Kind
    var outcome: Outcome
    var message: String

    var title: String { kind.title }
    var symbol: String { kind.symbol }
}
