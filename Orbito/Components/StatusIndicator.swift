import SwiftUI

extension JobHealth {
    var color: Color {
        switch self {
        case .running: .blue
        case .loaded: .green
        case .lastRunFailed: .orange
        case .notLoaded: .secondary
        case .disabled: .gray
        case .invalid: .red
        case .unknown: .secondary
        }
    }
}

extension IssueSeverity {
    var color: Color {
        switch self {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

/// Small coloured dot with optional pulse for running jobs.
struct StatusDot: View {
    var health: JobHealth
    @State private var pulse = false

    var body: some View {
        ZStack {
            if health == .running {
                Circle()
                    .fill(health.color.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.4 : 0.8)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(health.color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .onAppear { pulse = true }
        .accessibilityLabel(health.title)
    }
}

struct StatusBadge: View {
    var health: JobHealth
    var compact = false

    var body: some View {
        Label {
            if !compact { Text(health.title) }
        } icon: {
            Image(systemName: health.symbol)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(health.color)
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, 4)
        .background(health.color.opacity(0.13), in: Capsule())
        .help(health.title)
    }
}

/// One independent fact (file / loaded / running / disabled / last exit).
struct FactChip: View {
    var title: String
    var value: String
    var symbol: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension Tristate {
    func text(yes: String, no: String) -> String {
        switch self {
        case .yes: yes
        case .no: no
        case .unknown: "Unknown"
        }
    }

    func color(yes: Color, no: Color) -> Color {
        switch self {
        case .yes: yes
        case .no: no
        case .unknown: .secondary
        }
    }
}

struct JobIcon: View {
    var job: LaunchJob
    var size: CGFloat = 34

    private var symbol: String {
        let exe = (job.definition.executablePath ?? "") as NSString
        switch exe.lastPathComponent {
        case "bash", "zsh", "sh": return "terminal"
        case let name where name.hasPrefix("python"): return "chevron.left.forwardslash.chevron.right"
        case "php": return "server.rack"
        case "node": return "curlybraces"
        default: break
        }
        switch job.scope {
        case .globalDaemon: return "gearshape.2"
        case .globalAgent: return "person.2"
        case .userAgent: return job.definition.schedule.isTimeBased ? "clock" : "bolt"
        }
    }

    var body: some View {
        let color = CalendarViewModel.color(for: job.label)
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .shadow(color: color.opacity(0.3), radius: 4, y: 2)
    }
}
