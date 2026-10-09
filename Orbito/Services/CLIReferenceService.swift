import Foundation

enum CLIPlatform: String, CaseIterable, Identifiable, Sendable {
    case macOS, linux
    var id: String { rawValue }
    var title: String { self == .macOS ? "macOS" : "Linux" }
}

enum LinuxScheduler: String, CaseIterable, Identifiable, Sendable {
    case systemd, cron
    var id: String { rawValue }
    var title: String { rawValue }
}

struct ReferenceCommand: Hashable, Sendable, Identifiable {
    var id = UUID()
    var command: String
    var note: String?
    var isDestructive = false
}

/// Educational Linux example for an Orbito action. Never executed, never tied to a task on this Mac.
struct ReferenceEntry: Hashable, Sendable {
    var title: String
    var summary: String
    var commands: [ReferenceCommand]
    /// How the Linux concept differs from launchd (shown prominently when there is no direct equivalent).
    var differences: String?
    var hasDirectEquivalent: Bool { !commands.isEmpty }
    let isReferenceOnly = true
}

/// Structured, reusable Linux CLI reference. Pure data: it has no ability to run anything.
enum CLIReferenceService {
    static let unit = "example"

    static func entry(_ action: CLIAction, scheduler: LinuxScheduler, schedule: JobSchedule? = nil) -> ReferenceEntry {
        switch scheduler {
        case .systemd: systemd(action, schedule: schedule)
        case .cron: cron(action, schedule: schedule)
        }
    }

    // MARK: systemd

    private static func systemd(_ action: CLIAction, schedule: JobSchedule?) -> ReferenceEntry {
        let service = "\(unit).service", timer = "\(unit).timer"
        func cmd(_ c: String, _ note: String? = nil, destructive: Bool = false) -> ReferenceCommand {
            ReferenceCommand(command: c, note: note, isDestructive: destructive)
        }
        switch action {
        case .runNow:
            return ReferenceEntry(title: "Запустить сервис сейчас", summary: "Запускает связанный .service напрямую; таймер и его расписание не меняются.", commands: [
                cmd("systemctl --user start \(service)"),
            ], differences: "В systemd расписание задаёт .timer, а работу выполняет .service. Запускать нужно именно .service: `start` для .timer лишь активирует расписание.")
        case .stop:
            return ReferenceEntry(title: "Остановить сервис", summary: "Останавливает работающий процесс сервиса.", commands: [
                cmd("systemctl --user stop \(service)", destructive: true),
            ])
        case .load:
            return ReferenceEntry(title: "Сделать таймер активным", summary: "systemd находит unit-файлы сам после daemon-reload; затем таймер запускается.", commands: [
                cmd("systemctl --user daemon-reload", "перечитать unit-файлы"),
                cmd("systemctl --user start \(timer)", "активировать расписание до перезагрузки"),
            ], differences: "Аналога `launchctl bootstrap` нет: нет отдельной «загрузки plist». Unit становится известен после daemon-reload, а работает, когда таймер запущен (start) или включён (enable).")
        case .unload:
            return ReferenceEntry(title: "Остановить таймер", summary: "Расписание перестаёт срабатывать до следующего start/перезагрузки.", commands: [
                cmd("systemctl --user stop \(timer)", destructive: true),
            ], differences: "`stop` для .timer похож на `launchctl bootout`, но если таймер включён (enabled), он снова запустится при следующем входе в систему.")
        case .reload:
            return ReferenceEntry(title: "Применить изменённые unit-файлы", summary: "Перечитывает конфигурацию и перезапускает таймер.", commands: [
                cmd("systemctl --user daemon-reload"),
                cmd("systemctl --user restart \(timer)"),
            ])
        case .enable:
            return ReferenceEntry(title: "Включить таймер", summary: "Включает автозапуск таймера при входе и сразу запускает его.", commands: [
                cmd("systemctl --user enable --now \(timer)"),
            ], differences: "Без `loginctl enable-linger $USER` пользовательские таймеры работают только пока пользователь вошёл в систему.")
        case .disable:
            return ReferenceEntry(title: "Отключить таймер", summary: "Выключает автозапуск и сразу останавливает таймер.", commands: [
                cmd("systemctl --user disable --now \(timer)", destructive: true),
            ])
        case .editSchedule:
            var commands = [
                cmd("systemctl --user edit --full \(timer)", "открывает unit в редакторе; изменить строку OnCalendar="),
                cmd("systemctl --user daemon-reload"),
                cmd("systemctl --user restart \(timer)"),
            ]
            if let calendars = schedule.flatMap(similarOnCalendar) {
                commands.insert(cmd("systemd-analyze calendar \(Workspace.shellCommand(calendars))", "проверить выражения и увидеть следующие срабатывания"), at: 0)
                commands.insert(cmd(calendars.map { "OnCalendar=\($0)" }.joined(separator: "\n"), "строки для секции [Timer] — по одной на правило"), at: 1)
            }
            return ReferenceEntry(title: "Изменить расписание таймера", summary: "Расписание хранится в секции [Timer] (OnCalendar=, OnUnitActiveSec= …).", commands: commands,
                differences: similarNote(schedule, systemd: true) ?? "Команды выше не меняют файл сами — правка делается в редакторе; daemon-reload и restart применяют её.")
        case .editConfiguration:
            return ReferenceEntry(title: "Изменить сервис", summary: "Команда, рабочая директория и окружение задаются в .service.", commands: [
                cmd("systemctl --user edit --full \(service)"),
                cmd("systemctl --user daemon-reload"),
            ])
        case .create:
            return ReferenceEntry(title: "Создать сервис и таймер", summary: "Два файла в ~/.config/systemd/user/, затем daemon-reload и enable.", commands: [
                cmd("mkdir -p ~/.config/systemd/user"),
                cmd("printf '[Unit]\\nDescription=Example\\n\\n[Service]\\nType=oneshot\\nExecStart=/usr/bin/env bash %%h/scripts/example.sh\\n' > ~/.config/systemd/user/\(service)"),
                cmd("printf '[Unit]\\nDescription=Example timer\\n\\n[Timer]\\nOnCalendar=*-*-* 08:00:00\\nPersistent=true\\n\\n[Install]\\nWantedBy=timers.target\\n' > ~/.config/systemd/user/\(timer)"),
                cmd("systemctl --user daemon-reload"),
                cmd("systemctl --user enable --now \(timer)"),
            ], differences: "`Persistent=true` догоняет пропущенные запуски после сна/выключения — похоже на поведение launchd с StartCalendarInterval.")
        case .duplicate:
            return ReferenceEntry(title: "Скопировать unit-файлы", summary: "Копия под новым именем, затем daemon-reload.", commands: [
                cmd("cp ~/.config/systemd/user/\(service) ~/.config/systemd/user/\(unit)-copy.service"),
                cmd("sed 's/\(service)/\(unit)-copy.service/' ~/.config/systemd/user/\(timer) > ~/.config/systemd/user/\(unit)-copy.timer", "если в таймере указан Unit="),
                cmd("systemctl --user daemon-reload"),
            ], differences: "По умолчанию таймер запускает сервис с тем же именем, поэтому копировать нужно оба файла.")
        case .delete:
            return ReferenceEntry(title: "Удалить таймер и сервис", summary: "Отключить, удалить файлы, перечитать конфигурацию.", commands: [
                cmd("systemctl --user disable --now \(timer)", destructive: true),
                cmd("rm ~/.config/systemd/user/\(timer) ~/.config/systemd/user/\(service)", destructive: true),
                cmd("systemctl --user daemon-reload"),
            ])
        case .viewLogs:
            return ReferenceEntry(title: "Логи сервиса", summary: "Вывод сервисов по умолчанию попадает в журнал systemd.", commands: [
                cmd("journalctl --user -u \(service) -n 100 --no-pager"),
                cmd("journalctl --user -u \(service) -f", "следить в реальном времени"),
            ], differences: "В launchd вывод идёт только в файлы StandardOutPath/StandardErrorPath; общего журнала по заданию нет.")
        case .inspect:
            return ReferenceEntry(title: "Состояние таймера и сервиса", summary: "Следующий и последний запуск, результат.", commands: [
                cmd("systemctl --user status \(timer)"),
                cmd("systemctl --user status \(service)"),
                cmd("systemctl --user show \(timer) -p NextElapseUSecRealtime -p LastTriggerUSec"),
            ])
        case .listTasks:
            return ReferenceEntry(title: "Список таймеров", summary: "Все пользовательские таймеры с ближайшими запусками.", commands: [
                cmd("systemctl --user list-timers --all"),
            ])
        }
    }

    // MARK: cron

    private static func cron(_ action: CLIAction, schedule: JobSchedule?) -> ReferenceEntry {
        func cmd(_ c: String, _ note: String? = nil, destructive: Bool = false) -> ReferenceCommand {
            ReferenceCommand(command: c, note: note, isDestructive: destructive)
        }
        switch action {
        case .runNow:
            return ReferenceEntry(title: "Запустить сейчас", summary: "У cron нет команды запуска отдельной записи.", commands: [],
                differences: "Запустите команду из записи вручную в терминале. Учтите: cron выполняет её через /bin/sh с минимальным окружением (короткий PATH, другой HOME/рабочий каталог), поэтому результат может отличаться.")
        case .stop:
            return ReferenceEntry(title: "Остановить", summary: "cron не управляет запущенными процессами.", commands: [],
                differences: "После старта процесс живёт сам по себе. Остановить его можно только обычными средствами (найти PID через `ps` и завершить), cron об этом не знает.")
        case .load, .unload, .reload:
            return ReferenceEntry(title: action.title, summary: "У cron нет понятия загрузки/выгрузки записи.", commands: [
                cmd("crontab -l", "посмотреть установленные записи"),
            ], differences: "Запись активна, пока она есть в установленном crontab. cron перечитывает crontab автоматически после `crontab -e` / `crontab <файл>` — отдельная перезагрузка не нужна.")
        case .enable, .disable:
            return ReferenceEntry(title: action == .enable ? "Включить запись" : "Отключить запись", summary: "Делается правкой crontab: строку закомментировать или раскомментировать.", commands: [
                cmd("crontab -e", action == .enable ? "убрать # в начале строки" : "добавить # в начало строки"),
            ], differences: "Отдельного флага disabled, как в launchd, у cron нет.")
        case .editSchedule:
            var commands = [cmd("crontab -e", "изменить первые пять полей строки (минута час день месяц день_недели)")]
            if let expression = schedule.flatMap(similarCron) {
                commands.append(cmd("\(expression) /path/to/script.sh >> $HOME/example.log 2>&1", "пример строки с похожим расписанием"))
            }
            return ReferenceEntry(title: "Изменить расписание", summary: "Расписание — это пять полей в начале строки crontab.", commands: commands,
                differences: similarNote(schedule, systemd: false) ?? "Сохранение в `crontab -e` сразу применяет изменения.")
        case .editConfiguration, .create, .duplicate:
            return ReferenceEntry(title: action.title, summary: "Записи cron редактируются в crontab пользователя.", commands: [
                cmd("crontab -e"),
                cmd("0 8 * * * /usr/bin/env bash $HOME/scripts/example.sh >> $HOME/example.log 2>&1", "пример строки: ежедневно в 08:00"),
            ], differences: "Знак % в команде cron означает перевод строки — его нужно экранировать как \\%. Команда выполняется через /bin/sh.")
        case .delete:
            return ReferenceEntry(title: "Удалить запись", summary: "Удалите строку в редакторе crontab.", commands: [
                cmd("crontab -e", "удалить нужную строку"),
                cmd("crontab -r", "ОПАСНО: удаляет ВЕСЬ crontab пользователя без подтверждения", destructive: true),
            ])
        case .viewLogs:
            return ReferenceEntry(title: "Логи", summary: "У cron нет отдельного лога для каждой записи.", commands: [
                cmd("grep CRON /var/log/syslog | tail -n 100", "Debian/Ubuntu с rsyslog"),
                cmd("journalctl -u cron -n 100 --no-pager", "Debian/Ubuntu с journald; может потребовать прав"),
            ], differences: "Системный лог показывает только факт запуска. Вывод команды сохраняется, только если в строке есть перенаправление (`>> файл 2>&1`), иначе cron пытается отправить его почтой.")
        case .inspect, .listTasks:
            return ReferenceEntry(title: "Посмотреть записи", summary: "Показывает crontab текущего пользователя.", commands: [
                cmd("crontab -l"),
            ], differences: "cron не хранит ни времени следующего запуска, ни результата последнего.")
        }
    }

    // MARK: Similar (not equivalent) schedules

    /// OnCalendar for simple launchd calendars. Approximate: semantics are documented in `similarNote`.
    static func similarOnCalendar(_ schedule: JobSchedule) -> [String]? {
        guard schedule.interval == nil, !schedule.calendar.isEmpty else { return nil }
        let parts = schedule.calendar.compactMap { entry -> String? in
            guard entry.month == nil, entry.extras.isEmpty, !(entry.day != nil && entry.weekday != nil) else { return nil }
            let weekday = entry.weekday.map { Weekday.englishShort($0) + " " } ?? ""
            let day = entry.day.map { String(format: "*-*-%02d", $0) } ?? "*-*-*"
            let hour = entry.hour.map { String(format: "%02d", $0) } ?? "*"
            let minute = entry.minute.map { String(format: "%02d", $0) } ?? "*"
            return "\(weekday)\(day) \(hour):\(minute):00"
        }
        return parts.count == schedule.calendar.count ? Array(NSOrderedSet(array: parts)) as? [String] : nil
    }

    /// cron expression for launchd calendars expressible as one line.
    static func similarCron(_ schedule: JobSchedule) -> String? {
        if let seconds = schedule.interval {
            guard schedule.calendar.isEmpty, seconds % 60 == 0 else { return nil }
            let minutes = seconds / 60
            if minutes == 1 { return "* * * * *" }
            if minutes < 60, 60 % minutes == 0 { return "*/\(minutes) * * * *" }
            if minutes % 60 == 0, 24 % (minutes / 60) == 0 { return minutes == 60 ? "0 * * * *" : "0 */\(minutes / 60) * * *" }
            return nil
        }
        guard !schedule.calendar.isEmpty, schedule.calendar.allSatisfy({ $0.extras.isEmpty }) else { return nil }
        func field(_ values: [Int?]) -> String? {
            let set = Set(values)
            if set == [nil] { return "*" }
            guard !set.contains(nil) else { return nil }
            return set.compactMap { $0 }.sorted().map(String.init).joined(separator: ",")
        }
        // Only combinations that cron represents exactly as a cross product.
        let entries = schedule.calendar
        guard let minute = field(entries.map(\.minute)), let hour = field(entries.map(\.hour)),
              let dom = field(entries.map(\.day)), let month = field(entries.map(\.month)),
              let dow = field(entries.map { $0.normalizedWeekday }) else { return nil }
        // The cron line fires on every combination of the fields: accept only if that
        // cross product is exactly the set of launchd entries (duplicates ignored).
        let unique = Set(entries.map { [$0.minute, $0.hour, $0.day, $0.month, $0.normalizedWeekday] })
        func values(_ keyPath: KeyPath<CalendarEntry, Int?>) -> [Int?] { Array(Set(entries.map { $0[keyPath: keyPath] })) }
        let weekdays = Array(Set(entries.map(\.normalizedWeekday)))
        var combinations = 0
        for m in values(\.minute) { for h in values(\.hour) { for d in values(\.day) { for mo in values(\.month) { for w in weekdays {
            guard unique.contains([m, h, d, mo, w]) else { return nil }
            combinations += 1
        } } } } }
        guard combinations == unique.count else { return nil }
        return "\(minute) \(hour) \(dom) \(month) \(dow)"
    }

    private static func similarNote(_ schedule: JobSchedule?, systemd: Bool) -> String? {
        guard let schedule, schedule.isTimeBased else { return nil }
        var notes = ["Пример получен из расписания выбранного задания и показан только для сравнения — это НЕ точный эквивалент."]
        if schedule.interval != nil {
            notes.append(systemd
                ? "StartInterval отсчитывается от загрузки; ближе всего OnUnitActiveSec=, а не OnCalendar."
                : "StartInterval отсчитывается от загрузки, а */N в cron привязан к часам.")
        }
        if schedule.calendar.contains(where: { $0.day != nil && $0.weekday != nil }) {
            notes.append(systemd ? "В launchd Day и Weekday объединяются через ИЛИ, в OnCalendar — через И." : "В cron, как и в launchd, Day и Weekday объединяются через ИЛИ.")
        }
        notes.append(systemd
            ? "Пропущенные во сне запуски systemd догоняет только с Persistent=true."
            : "cron не догоняет запуски, пропущенные во время сна или выключения, а launchd выполняет один пропущенный запуск после пробуждения.")
        return notes.joined(separator: " ")
    }
}
