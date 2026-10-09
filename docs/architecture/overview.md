# Архитектура Orbito

Orbito — нативное приложение только для macOS 26+. Оно управляет заданиями `launchd` текущего пользователя. Стек: Swift 6, SwiftUI, AppKit там, где нужно, и Liquid Glass. Linux присутствует только как справочник CLI-команд в Developer Mode.

## Слои

```
Orbito/
├── App/          OrbitoApp (сцены, меню, MenuBarExtra), AppState, AppSettings
├── Models/       PlistValue, LaunchJob, Schedule, ScheduleDraft, TaskStatus, HistoryEvent
├── Services/     launchd: LaunchctlService, PlistService, LaunchAgentScanner, ScheduleService, JobOperations
│                 developer: CommandPreviewService, CLIReferenceService, ConfigurationDiffService, CommandHistoryService
│                 support: CommandRunner, BackupService, LogService, Stores, SystemIntegration
├── ViewModels/   Dashboard, TaskList, TaskEditor/ScheduleEditor, NewTask, LogViewer, Calendar
├── Views/        Dashboard, Tasks, Editor, Wizard, Calendar, Logs, History, Settings, Developer
└── Components/   GlassCard, StatusIndicator, SchedulePicker, CodeView (подсветка, diff), CLIHint
```

Бизнес-логика живёт в `Services` и `ViewModels`. Views только отображают состояние и передают действия в `AppState`.

## Изменения конфигурации

Все действия, которые меняют состояние (запуск, остановка, загрузка, выгрузка, перезагрузка, включение, отключение, удаление, правка, создание), проходят через `AppState.gate` или `gateEditor`:

1. **Dry Run** (Developer Mode). `CommandPreviewService` строит последовательность команд. Она записывается в Историю команд как «CLI-эквивалент». Больше ничего не происходит.
2. **Предпросмотр перед изменениями** (Developer Mode). Пользователь видит diff и команды, затем подтверждает.
3. Иначе — обычное подтверждение для опасных действий или немедленное выполнение.

`JobOperations` выполняет изменения транзакционно:

1. Проверяет, что файл на диске не изменился после сканирования.
2. Делает резервную копию.
3. Атомарно записывает файл и проверяет его повторным декодированием и `plutil -lint`.
4. Проверяет, что служба загружена именно из этого plist.
5. Выполняет `bootout` / `bootstrap`.
6. При ошибке откатывает изменения и честно сообщает результат.

## Developer Mode

| Функция | Где реализована |
|---|---|
| CLI-подсказки (macOS / Linux → systemd / cron) | `CLIHint.swift`, `CommandPreviewService`, `CLIReferenceService` |
| Терминальные команды и diff | `CommandPreviewSheet`, `ConfigurationDiffService` |
| Сырой plist и Advanced Editor | `RawPlistEditorSheet` |
| История команд | `CommandHistoryService`: `RecordingCommandRunner` и `OperationJournal` |
| CLI Inspector | `CLIInspectorView` (только `launchctl print`, `print-disabled`, `list`, `blame`) |
| Расширенные логи | `LogViewerViewModel` (`launchctl print` + `log show`, экспорт) |
| Dry Run | `AppState.gate` / `gateEditor` |

Правила для команд:

- **Вкладка macOS.** Команды генерируются из модели выбранного задания: его Label, домена, пути и изменённых ключей. Шаблонов с выдуманными путями нет.
- **Вкладка Linux.** Справочник с пометкой «Reference Only». Ничего не выполняет и не связан с заданиями этого Mac. Для действий без аналога (например, «запустить запись cron сейчас») показывается объяснение разницы, а не выдуманная команда. Расписание задания переводится в cron или `OnCalendar` только как «похожее» и с явными оговорками.

## История команд

- Записываются только команды, запущенные по действию пользователя: внутри `CommandContext` (task-local).
- Периодическое сканирование не записывается.
- Типы записей: выполненная команда, операция с файлом, внутренняя операция, CLI-эквивалент (Dry Run).
- Перед сохранением секреты маскируются (`HistorySanitizer`), вывод обрезается, хранится не больше 1000 записей.

## Безопасность

- Команды запускаются только как `Process` с абсолютным путём и массивом аргументов. Shell не используется.
- Без App Sandbox: иначе нельзя управлять `~/Library/LaunchAgents` и GUI-доменом. Hardened Runtime включён.
- Системные каталоги (`/Library/…`) доступны только для чтения — это проверяется и в интерфейсе, и в `JobOperations`.
- sudo не используется. SIP и другие защитные механизмы не трогаются.
