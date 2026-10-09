import SwiftUI

enum CodeLanguage {
    case xml, shell, plain
}

/// Lightweight regex highlighter for plist XML and shell commands.
enum SyntaxHighlighter {
    static func highlight(_ text: String, language: CodeLanguage) -> AttributedString {
        var attributed = AttributedString(text)
        let ns = text as NSString
        func paint(_ pattern: String, _ color: Color, group: Int = 0) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range(at: group)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: text),
                      let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
                      let upper = AttributedString.Index(swiftRange.upperBound, within: attributed) else { continue }
                attributed[lower..<upper].foregroundColor = color
            }
        }
        switch language {
        case .xml:
            paint(#"</?[A-Za-z!?][^>]*>"#, .secondary)
            paint(#"<key>([^<]*)</key>"#, .purple, group: 1)
            paint(#"<string>([^<]*)</string>"#, .orange, group: 1)
            paint(#"<(?:integer|real)>([^<]*)</(?:integer|real)>"#, .blue, group: 1)
            paint(#"<(true|false)/>"#, .pink, group: 1)
        case .shell:
            paint(#"^\s*#.*$"#, .secondary)
            paint(#"(^|&& |\| )\s*(launchctl|plutil|systemctl|journalctl|crontab|systemd-analyze|tail|cp|mv|mkdir|cat|grep|rm|test|log|ls|sed|printf)\b"#, .purple, group: 2)
            paint(#"'[^']*'"#, .orange)
            paint(#"\s(-{1,2}[A-Za-z][\w-]*)"#, .teal, group: 1)
        case .plain:
            break
        }
        return attributed
    }
}

/// Selectable, monospaced, highlighted code block with optional copy button.
struct CodeBlock: View {
    var text: String
    var language: CodeLanguage = .shell
    var maxHeight: CGFloat? = nil
    var showsCopy = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView([.vertical, .horizontal]) {
                Text(SyntaxHighlighter.highlight(text, language: language))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: maxHeight == nil)
            if showsCopy {
                Button {
                    Workspace.copy(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .padding(8)
                .help("Скопировать")
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

/// Unified or side-by-side diff with line numbers and add/remove colouring.
struct DiffView: View {
    var before: String
    var after: String
    var path: String
    @State private var sideBySide = false

    var body: some View {
        let lines = ConfigurationDiffService.lineDiff(old: before, new: after)
        let hunks = ConfigurationDiffService.hunks(lines)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Вид", selection: $sideBySide) {
                    Text("Unified").tag(false)
                    Text("Side-by-side").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                Label("\(lines.count { $0.kind == .added })", systemImage: "plus").foregroundStyle(.green)
                Label("\(lines.count { $0.kind == .removed })", systemImage: "minus").foregroundStyle(.red)
                Button("Copy Diff") {
                    Workspace.copy(ConfigurationDiffService.unified(old: before, new: after, path: path))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .font(.caption)
            if hunks.isEmpty {
                Text("Файл не меняется.").foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
                            if index > 0 {
                                Text("⋯").foregroundStyle(.tertiary).padding(.vertical, 2).padding(.leading, 8)
                            }
                            if sideBySide {
                                SideBySideHunk(lines: hunk)
                            } else {
                                ForEach(hunk) { UnifiedLine(line: $0) }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

private struct UnifiedLine: View {
    var line: DiffLine

    var body: some View {
        HStack(spacing: 8) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 32, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 32, alignment: .trailing).foregroundStyle(.tertiary)
            Text(prefix).foregroundStyle(color).frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text).foregroundStyle(line.kind == .context ? Color.primary : color)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(color.opacity(line.kind == .context ? 0 : 0.12))
    }

    private var prefix: String {
        switch line.kind {
        case .context: " "
        case .added: "+"
        case .removed: "-"
        }
    }

    private var color: Color {
        switch line.kind {
        case .context: .secondary
        case .added: .green
        case .removed: .red
        }
    }
}

private struct SideBySideHunk: View {
    var lines: [DiffLine]

    var body: some View {
        // Pair removed lines with following added lines; context goes on both sides.
        let rows = pairs()
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    cell(row.0, side: .removed)
                    Divider()
                    cell(row.1, side: .added)
                }
            }
        }
    }

    private func pairs() -> [(DiffLine?, DiffLine?)] {
        var result: [(DiffLine?, DiffLine?)] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            for i in 0..<max(removed.count, added.count) {
                result.append((i < removed.count ? removed[i] : nil, i < added.count ? added[i] : nil))
            }
            removed.removeAll(); added.removeAll()
        }
        for line in lines {
            switch line.kind {
            case .context: flush(); result.append((line, line))
            case .removed: removed.append(line)
            case .added: added.append(line)
            }
        }
        flush()
        return result
    }

    private func cell(_ line: DiffLine?, side: DiffLine.Kind) -> some View {
        let changed = line.map { $0.kind != .context } ?? false
        let color: Color = side == .added ? .green : .red
        return HStack(spacing: 6) {
            Text(line.flatMap { side == .added ? $0.newNumber : $0.oldNumber }.map(String.init) ?? "")
                .frame(width: 32, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line?.text ?? " ").foregroundStyle(changed ? color : .primary)
                .lineLimit(1)
                .frame(width: 330, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(changed ? color.opacity(0.12) : .clear)
    }
}

/// Key-path change list for plists.
struct StructuredChangesView: View {
    var changes: [StructuredChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(changes) { change in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(change.kind.title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(color(change.kind))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color(change.kind).opacity(0.14), in: Capsule())
                        .frame(width: 92, alignment: .leading)
                    Text(change.keyPath).font(.system(.callout, design: .monospaced).weight(.semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        if let old = change.oldValue { Text("− " + old).foregroundStyle(.red) }
                        if let new = change.newValue { Text("+ " + new).foregroundStyle(.green) }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func color(_ kind: StructuredChange.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .modified: .orange
        }
    }
}
