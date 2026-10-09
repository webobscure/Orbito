import Foundation

enum OrbitoError: LocalizedError, Equatable {
    case invalidPlist(path: String, reason: String)
    case notADictionary(path: String)
    case readOnlyJob(label: String)
    case invalidLabel(String)
    case labelConflict(String)
    case fileExists(path: String)
    case invalidPath(String)
    case executableMissing(String)
    case notExecutable(String)
    case scheduleInvalid([String])
    case launchctl(LaunchctlFailure)
    case lintFailed(String)
    case writeFailed(path: String, reason: String)
    case applyFailed(reason: String, restoredFile: Bool, restoredLaunchd: Bool?)
    case notLoaded(label: String)
    case processFailed(String)
    case foreignService(label: String, loadedPath: String)
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case .invalidPlist(let path, let reason):
            "Не удалось прочитать plist «\(path)»: \(reason)"
        case .notADictionary(let path):
            "Файл «\(path)» не содержит словаря верхнего уровня."
        case .readOnlyJob(let label):
            "Задание «\(label)» находится в системном каталоге и доступно только для чтения."
        case .invalidLabel(let label):
            "Label «\(label)» недопустим. Разрешены латинские буквы, цифры, точка, дефис и подчёркивание."
        case .labelConflict(let label):
            "Задание с Label «\(label)» уже существует."
        case .fileExists(let path):
            "Файл уже существует: \(path). Перезапись запрещена."
        case .invalidPath(let path):
            "Недопустимый путь: «\(path)». Нужен абсолютный путь."
        case .executableMissing(let path):
            "Исполняемый файл не найден: \(path)"
        case .notExecutable(let path):
            "Файл не является исполняемым: \(path)"
        case .scheduleInvalid(let errors):
            "Расписание некорректно:\n" + errors.joined(separator: "\n")
        case .launchctl(let failure):
            failure.localizedDescription
        case .lintFailed(let output):
            "plutil отклонил файл: \(output)"
        case .writeFailed(let path, let reason):
            "Не удалось записать «\(path)»: \(reason)"
        case .applyFailed(let reason, let restoredFile, let restoredLaunchd):
            Self.applyFailureText(reason: reason, restoredFile: restoredFile, restoredLaunchd: restoredLaunchd)
        case .notLoaded(let label):
            "Задание «\(label)» не загружено в launchd. Сначала загрузите его."
        case .processFailed(let message):
            message
        case .foreignService(let label, let loadedPath):
            "Служба «\(label)» в launchd загружена из другого файла: \(loadedPath). Orbito не будет её трогать."
        case .timedOut(let command):
            "Команда не завершилась вовремя и была прервана: \(command). Состояние launchd неизвестно — проверьте задание."
        }
    }

    private static func applyFailureText(reason: String, restoredFile: Bool, restoredLaunchd: Bool?) -> String {
        var text = "Не удалось применить изменения: \(reason)\n"
        text += restoredFile ? "Исходный plist восстановлен из резервной копии." : "Исходный plist восстановить НЕ удалось — используйте резервную копию."
        switch restoredLaunchd {
        case .some(true): text += "\nПредыдущая версия задания снова загружена в launchd."
        case .some(false): text += "\nЗадание НЕ удалось снова загрузить в launchd — состояние launchd отличается от исходного."
        case .none: break
        }
        return text
    }
}
