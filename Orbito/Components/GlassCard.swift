import SwiftUI

/// Content surface. `.glass` uses real Liquid Glass and is meant for
/// controls and summary tiles; `.surface` keeps long content readable.
struct GlassCard<Content: View>: View {
    enum Style { case glass, surface }

    var style: Style = .surface
    var tint: Color?
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @AppStorage("reduceTransparency") private var appReduceTransparency = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let inner = content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        switch (systemReduceTransparency || appReduceTransparency) ? .surface : style {
        case .glass:
            inner.glassEffect(.regular.tint(tint?.opacity(0.18)), in: shape)
        case .surface:
            inner
                .background(.background.secondary.opacity(0.75), in: shape)
                .background((tint ?? .clear).opacity(0.07), in: shape)
                .overlay(shape.strokeBorder((tint ?? Color.secondary).opacity(tint == nil ? 0.25 : 0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
    }
}

struct CardHeader: View {
    var title: String
    var symbol: String
    var tint: Color = .accentColor
    var trailing: AnyView?

    init(_ title: String, symbol: String, tint: Color = .accentColor) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    init(_ title: String, symbol: String, tint: Color = .accentColor, @ViewBuilder trailing: () -> some View) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .font(.headline)
            Spacer()
            trailing
        }
    }
}

/// Soft ambient backdrop that gives glass something to refract.
struct AmbientBackground: View {
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            Circle()
                .fill(tint.opacity(0.10))
                .frame(width: 520, height: 520)
                .blur(radius: 120)
                .offset(x: -260, y: -220)
            Circle()
                .fill(Color.purple.opacity(0.07))
                .frame(width: 460, height: 460)
                .blur(radius: 120)
                .offset(x: 320, y: 260)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct EmptyStateView: View {
    var title: String
    var message: String
    var symbol: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
            }
        }
    }
}

struct KeyValueRow: View {
    var key: String
    var value: String
    var monospaced = false
    var copyable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button {
                    Workspace.copy(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Скопировать")
            }
        }
        .font(.callout)
    }
}

/// Floating result banner with glass background.
struct BannerView: View {
    var banner: Banner
    var dismiss: () -> Void
    @State private var expanded = false

    private var color: Color {
        switch banner.style {
        case .success: .green
        case .warning: .orange
        case .error: .red
        case .info: .blue
        }
    }

    private var symbol: String {
        switch banner.style {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(banner.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 12)
                if !banner.details.isEmpty {
                    Button(expanded ? "Скрыть" : "Подробнее") {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                    .buttonStyle(.borderless)
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderless)
                .help("Закрыть")
            }
            if expanded || banner.style == .error || banner.style == .warning {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(banner.details, id: \.self) { line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .glassEffect(.regular.tint(color.opacity(0.15)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
}
