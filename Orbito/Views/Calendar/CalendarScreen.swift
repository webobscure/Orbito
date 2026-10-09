import SwiftUI

struct CalendarScreen: View {
    @Environment(AppState.self) private var appState
    @State private var model = CalendarViewModel()

    var body: some View {
        let events = model.events(for: appState.jobs, service: appState.scheduleService)

        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.scale {
                case .day:
                    DayTimeline(days: [model.anchor], events: events, calendar: model.calendar, open: open)
                case .week:
                    DayTimeline(days: model.days, events: events, calendar: model.calendar, open: open)
                case .month:
                    MonthGrid(model: model, events: events, open: open)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AmbientBackground())
        .navigationTitle("Календарь")
    }

    private func open(_ event: CalendarEvent) {
        if let job = appState.job(withID: event.jobID) { appState.open(job) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(model.title)
                .font(.title2.weight(.bold))
                .contentTransition(.numericText())
            Spacer()
            Text("Плановое время · \(TimeZone.current.localizedName(for: .shortGeneric, locale: .current) ?? TimeZone.current.identifier)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Время рассчитано по правилам StartCalendarInterval в местном часовом поясе с учётом перехода на летнее/зимнее время. Задания StartInterval не отображаются: их время зависит от момента загрузки.")
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button { withAnimation(.smooth) { model.step(-1) } } label: { Image(systemName: "chevron.left") }
                    Button("Сегодня") { withAnimation(.smooth) { model.today() } }
                    Button { withAnimation(.smooth) { model.step(1) } } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.glass)
            }
            Picker("Масштаб", selection: $model.scale.animation(.smooth)) {
                ForEach(CalendarScale.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Vertical 24h timeline with one column per day.
private struct DayTimeline: View {
    var days: [Date]
    var events: [CalendarEvent]
    var calendar: Calendar
    var open: (CalendarEvent) -> Void
    private let hourHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 56)
                ForEach(days, id: \.self) { day in
                    let isToday = calendar.isDateInToday(day)
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.title3.weight(isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Color.white : .primary)
                            .frame(width: 32, height: 32)
                            .background(isToday ? Color.accentColor : .clear, in: Circle())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(String(format: "%02d:00", hour))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, height: hourHeight, alignment: .topTrailing)
                                    .padding(.trailing, 6)
                                    .id(hour)
                            }
                        }
                        ForEach(days, id: \.self) { day in
                            dayColumn(day)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(max(0, calendar.component(.hour, from: .now) - 2), anchor: .top) }
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let dayEvents = events.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let grouped = Dictionary(grouping: dayEvents) { minuteOfDay($0.date) / 15 }
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle()
                        .fill(.clear)
                        .frame(height: hourHeight)
                        .overlay(alignment: .top) { Divider().opacity(0.6) }
                }
            }
            if calendar.isDateInToday(day) {
                Rectangle()
                    .fill(Color.red)
                    .frame(height: 1.5)
                    .offset(y: CGFloat(minuteOfDay(.now)) / 60 * hourHeight)
            }
            ForEach(grouped.keys.sorted(), id: \.self) { slot in
                let slotEvents = grouped[slot] ?? []
                let y = CGFloat(slot * 15) / 60 * hourHeight
                HStack(spacing: 3) {
                    ForEach(slotEvents.prefix(3)) { event in
                        EventChip(event: event, compact: days.count > 1) { open(event) }
                    }
                    if slotEvents.count > 3 {
                        Text("+\(slotEvents.count - 3)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 3)
                .offset(y: y + 1)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { Divider().opacity(0.6) }
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}

private struct EventChip: View {
    var event: CalendarEvent
    var compact: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(event.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                Text(event.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(event.isLoaded ? Color.primary : .secondary)
            .background(event.color.opacity(hovering ? 0.35 : 0.22), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(event.color).frame(width: 3).padding(.vertical, 2)
            }
            .overlay {
                if !event.isLoaded {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(event.color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(event.name) — \(event.date.formatted(date: .abbreviated, time: .shortened))\(event.isLoaded ? "" : " (не загружено в launchd)")")
    }
}

private struct MonthGrid: View {
    var model: CalendarViewModel
    var events: [CalendarEvent]
    var open: (CalendarEvent) -> Void

    var body: some View {
        let days = model.days
        let calendar = model.calendar
        let month = calendar.component(.month, from: model.anchor)
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Weekday.ordered, id: \.self) { day in
                    Text(Weekday.shortName(day))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
            let rows = days.count / 7
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { column in
                            let day = days[row * 7 + column]
                            let dayEvents = byDay[calendar.startOfDay(for: day)] ?? []
                            MonthCell(
                                day: day,
                                isCurrentMonth: calendar.component(.month, from: day) == month,
                                isToday: calendar.isDateInToday(day),
                                events: dayEvents,
                                open: open
                            )
                        }
                    }
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
    }
}

private struct MonthCell: View {
    var day: Date
    var isCurrentMonth: Bool
    var isToday: Bool
    var events: [CalendarEvent]
    var open: (CalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.white : (isCurrentMonth ? Color.primary : Color.secondary.opacity(0.5)))
                    .frame(width: 24, height: 24)
                    .background(isToday ? Color.accentColor : .clear, in: Circle())
                Spacer()
                if events.count > 3 {
                    Text("\(events.count)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(events.prefix(3)) { event in
                EventChip(event: event, compact: true) { open(event) }
            }
            if events.count > 3 {
                Text("ещё \(events.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary.opacity(isCurrentMonth ? 0.7 : 0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
