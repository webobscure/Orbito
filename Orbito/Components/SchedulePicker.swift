import SwiftUI

/// Visual schedule editor used by the schedule sheet and the wizard.
struct SchedulePicker: View {
    @Binding var draft: ScheduleDraft
    @Namespace private var glassNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            modePicker
            Group {
                switch draft.mode {
                case .none:
                    Text("Задание не будет запускаться по времени. Оно может запускаться при загрузке (RunAtLoad), по KeepAlive или вручную.")
                        .foregroundStyle(.secondary)
                case .daily:
                    TimesEditor(times: $draft.times)
                case .weekdays:
                    WeekdaySelector(selection: $draft.weekdays, allowsMultiple: true)
                    TimesEditor(times: $draft.times)
                case .weekly:
                    WeekdaySelector(selection: Binding(
                        get: { [draft.weeklyDay] },
                        set: { if let day = $0.first { draft.weeklyDay = day } }
                    ), allowsMultiple: false)
                    TimesEditor(times: $draft.times)
                case .monthly:
                    MonthDaySelector(day: $draft.monthDay)
                    TimesEditor(times: $draft.times)
                case .hourly:
                    HourlyEditor(minute: $draft.hourlyMinute)
                case .interval:
                    IntervalEditor(minutes: $draft.intervalMinutes)
                case .advanced:
                    AdvancedScheduleEditor(entries: $draft.advancedEntries, interval: $draft.advancedIntervalSeconds)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))

            messages
        }
        .animation(.smooth(duration: 0.25), value: draft.mode)
    }

    private var modePicker: some View {
        GlassEffectContainer(spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                ForEach(ScheduleMode.allCases) { mode in
                    let selected = draft.mode == mode
                    Button {
                        draft.mode = mode
                    } label: {
                        Label(mode.title, systemImage: mode.symbol)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .tint(selected ? .accentColor : nil)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .fontWeight(selected ? .semibold : .regular)
                    .glassEffectID(mode, in: glassNamespace)
                }
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        let errors = draft.validationErrors
        let warnings = draft.warnings
        if !errors.isEmpty || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(errors, id: \.self) { MessageRow(text: $0, severity: .error) }
                ForEach(warnings, id: \.self) { MessageRow(text: $0, severity: .warning) }
            }
        }
        if draft.mode != .advanced, !draft.original.calendar.isEmpty || draft.original.interval != nil,
           ScheduleDraft(schedule: draft.original).mode == .advanced {
            MessageRow(text: "Исходное расписание сложнее выбранного режима. При сохранении все его правила будут заменены.", severity: .warning)
        }
    }
}

struct MessageRow: View {
    var text: String
    var severity: IssueSeverity

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: severity.symbol).foregroundStyle(severity.color)
        }
        .font(.callout)
    }
}

// MARK: - Times

struct TimesEditor: View {
    @Binding var times: [TimeOfDay]
    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Время запуска").font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 24) {
                DatePicker("", selection: selectedDate, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(width: 150, height: 150)
                    .disabled(times.isEmpty)

                VStack(alignment: .leading, spacing: 10) {
                    DatePicker("Время", selection: selectedDate, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.stepperField)
                        .accessibilityIdentifier("schedule.time")
                        .disabled(times.isEmpty)

                    FlowChips(times: times, selectedIndex: $selectedIndex) { index in
                        times.remove(at: index)
                        selectedIndex = max(0, min(selectedIndex, times.count - 1))
                    }

                    Button {
                        let last = times.last ?? TimeOfDay(hour: 8, minute: 0)
                        var next = TimeOfDay(hour: (last.hour + 1) % 24, minute: last.minute)
                        while times.contains(next) { next.hour = (next.hour + 1) % 24 }
                        times.append(next)
                        selectedIndex = times.count - 1
                    } label: {
                        Label("Добавить время", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .disabled(times.count >= 24)

                    if times.count > 1 {
                        Text("Несколько времён создают массив StartCalendarInterval.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { if times.isEmpty { times = [TimeOfDay(hour: 8, minute: 0)] } }
    }

    private var selectedDate: Binding<Date> {
        Binding(
            get: {
                guard times.indices.contains(selectedIndex) else { return TimeOfDay(hour: 8, minute: 0).date() }
                return times[selectedIndex].date()
            },
            set: { newValue in
                guard times.indices.contains(selectedIndex) else { return }
                times[selectedIndex] = TimeOfDay(date: newValue)
            }
        )
    }
}

private struct FlowChips: View {
    var times: [TimeOfDay]
    @Binding var selectedIndex: Int
    var remove: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(Array(times.enumerated()), id: \.offset) { index, time in
                HStack(spacing: 4) {
                    Text(time.formatted)
                        .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
                    if times.count > 1 {
                        Button {
                            remove(index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Удалить время")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(index == selectedIndex ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
                .overlay(Capsule().strokeBorder(index == selectedIndex ? Color.accentColor : .clear, lineWidth: 1))
                .contentShape(Capsule())
                .onTapGesture { selectedIndex = index }
            }
        }
    }
}

// MARK: - Days

struct WeekdaySelector: View {
    @Binding var selection: Set<Int>
    var allowsMultiple: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(allowsMultiple ? "Дни недели" : "День недели").font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(Weekday.ordered, id: \.self) { day in
                    let selected = selection.contains { $0 % 7 == day }
                    Button {
                        toggle(day)
                    } label: {
                        Text(Weekday.shortName(day))
                            .font(.callout.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(selected ? Color.white : (day == 0 || day == 6 ? Color.red.opacity(0.8) : .primary))
                            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .animation(.snappy, value: selected)
                }
            }
            if allowsMultiple {
                HStack {
                    Button("Будни") { selection = Weekday.workdays }
                    Button("Выходные") { selection = Weekday.weekend }
                    Button("Все дни") { selection = Set(Weekday.ordered) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    private func toggle(_ day: Int) {
        if !allowsMultiple {
            selection = [day]
            return
        }
        let existing = selection.filter { $0 % 7 == day }
        if existing.isEmpty { selection.insert(day) } else { selection.subtract(existing) }
    }
}

struct MonthDaySelector: View {
    @Binding var day: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Число месяца").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 7), alignment: .leading, spacing: 6) {
                ForEach(1...31, id: \.self) { value in
                    Button {
                        day = value
                    } label: {
                        Text("\(value)")
                            .font(.callout.monospacedDigit())
                            .frame(width: 36, height: 30)
                            .foregroundStyle(day == value ? Color.white : .primary)
                            .background(day == value ? Color.accentColor : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct HourlyEditor: View {
    @Binding var minute: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Минута каждого часа").font(.subheadline.weight(.semibold))
            HStack(spacing: 16) {
                Slider(value: Binding(get: { Double(minute) }, set: { minute = Int($0) }), in: 0...59, step: 1)
                    .frame(maxWidth: 320)
                Stepper(value: $minute, in: 0...59) {
                    Text(String(format: ":%02d", minute))
                        .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                }
            }
            Text("Использует StartCalendarInterval с одним ключом Minute — запуск привязан к часам.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct IntervalEditor: View {
    @Binding var minutes: Int
    private let presets = [5, 10, 15, 30, 60, 120, 360, 720]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Интервал").font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                TextField("Минуты", value: $minutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Stepper("минут", value: $minutes, in: 1...10_080)
            }
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { value in
                        Button(value < 60 ? "\(value) мин" : "\(value / 60) ч") { minutes = value }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .tint(minutes == value ? .accentColor : nil)
                    }
                }
            }
            Text("StartInterval = \(minutes * 60) с. Отсчёт идёт от момента загрузки задания, а не от начала часа.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Advanced

struct AdvancedScheduleEditor: View {
    @Binding var entries: [EditableEntry]
    @Binding var interval: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Правила StartCalendarInterval").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    entries.append(EditableEntry(entry: CalendarEntry(minute: 0, hour: 9)))
                } label: {
                    Label("Правило", systemImage: "plus")
                }
                .buttonStyle(.glass)
            }
            if entries.isEmpty {
                Text("Нет правил. Пустое поле означает «любое значение».")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            ForEach($entries) { $item in
                HStack(alignment: .center, spacing: 10) {
                    OptionalIntField(title: "Месяц", value: $item.entry.month, range: 1...12)
                    OptionalIntField(title: "Число", value: $item.entry.day, range: 1...31)
                    OptionalIntField(title: "День нед.", value: $item.entry.weekday, range: 0...7)
                    OptionalIntField(title: "Час", value: $item.entry.hour, range: 0...23)
                    OptionalIntField(title: "Минута", value: $item.entry.minute, range: 0...59)
                    Button(role: .destructive) {
                        entries.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Удалить правило")
                }
                .padding(10)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(ScheduleFormatter.describe(item.entry) + (item.entry.extras.isEmpty ? "" : " · доп. ключи сохранятся: " + item.entry.extras.keys.sorted().joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            Divider().padding(.vertical, 4)

            Toggle(isOn: Binding(get: { interval != nil }, set: { interval = $0 ? (interval ?? 3600) : nil })) {
                Text("StartInterval (секунды)")
            }
            if let value = interval {
                HStack {
                    TextField("Секунды", value: Binding(get: { value }, set: { interval = $0 }), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text(ScheduleFormatter.describeInterval(max(1, value)))
                        .foregroundStyle(.secondary)
                }
            }
            Text("День недели: 0 и 7 — воскресенье. Пустое поле — любое значение (как в launchd).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct OptionalIntField: View {
    var title: String
    @Binding var value: Int?
    var range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("любое", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .foregroundStyle(value.map { range.contains($0) } == false ? Color.red : .primary)
        }
    }
}
