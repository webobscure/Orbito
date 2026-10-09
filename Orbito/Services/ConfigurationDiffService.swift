import Foundation

struct DiffLine: Hashable, Sendable, Identifiable {
    enum Kind: Sendable { case context, added, removed }
    var id: Int
    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
}

/// Change of one plist key path.
struct StructuredChange: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case added, removed, modified

        var title: String {
            switch self {
            case .added: "Добавлено"
            case .removed: "Удалено"
            case .modified: "Изменено"
            }
        }
    }

    var kind: Kind
    var keyPath: String
    var oldValue: String?
    var newValue: String?
    var id: String { "\(kind.rawValue):\(keyPath)" }
}

/// Text and structural diffs for configuration previews. Pure functions, no I/O.
enum ConfigurationDiffService {
    /// Line diff via LCS. Plists are small, so O(n·m) is fine; very large inputs fall back to a block diff.
    static func lineDiff(old: String, new: String) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        if a.count * b.count > 4_000_000 {
            var lines: [DiffLine] = []
            for (i, line) in a.enumerated() { lines.append(DiffLine(id: lines.count, kind: .removed, text: line, oldNumber: i + 1)) }
            for (i, line) in b.enumerated() { lines.append(DiffLine(id: lines.count, kind: .added, text: line, newNumber: i + 1)) }
            return lines
        }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                result.append(DiffLine(id: result.count, kind: .context, text: a[i], oldNumber: i + 1, newNumber: j + 1))
                i += 1; j += 1
            } else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] {
                // Removals first on ties, as in conventional unified diffs.
                result.append(DiffLine(id: result.count, kind: .removed, text: a[i], oldNumber: i + 1))
                i += 1
            } else {
                result.append(DiffLine(id: result.count, kind: .added, text: b[j], newNumber: j + 1))
                j += 1
            }
        }
        return result
    }

    /// Changed lines with `context` lines around them; gaps are collapsed.
    static func hunks(_ lines: [DiffLine], context: Int = 3) -> [[DiffLine]] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(lines.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { Array(lines[$0]) }
    }

    /// Unified diff text (for Copy Diff).
    static func unified(old: String, new: String, path: String, context: Int = 3) -> String {
        let lines = lineDiff(old: old, new: new)
        var out = ["--- \(path) (до)", "+++ \(path) (после)"]
        for hunk in hunks(lines, context: context) {
            let oldStart = hunk.first(where: { $0.oldNumber != nil })?.oldNumber ?? 0
            let newStart = hunk.first(where: { $0.newNumber != nil })?.newNumber ?? 0
            let oldCount = hunk.filter { $0.kind != .added }.count
            let newCount = hunk.filter { $0.kind != .removed }.count
            out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            for line in hunk {
                let prefix = switch line.kind {
                case .context: " "
                case .added: "+"
                case .removed: "-"
                }
                out.append(prefix + line.text)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Key-path level comparison of two plist dictionaries.
    static func structured(old: [String: PlistValue], new: [String: PlistValue]) -> [StructuredChange] {
        var changes: [StructuredChange] = []
        compare(.dictionary(old), .dictionary(new), path: "", into: &changes)
        return changes
    }

    private static func compare(_ old: PlistValue?, _ new: PlistValue?, path: String, into changes: inout [StructuredChange]) {
        switch (old, new) {
        case (nil, nil):
            return
        case (nil, let value?):
            changes.append(StructuredChange(kind: .added, keyPath: path, oldValue: nil, newValue: render(value)))
        case (let value?, nil):
            changes.append(StructuredChange(kind: .removed, keyPath: path, oldValue: render(value), newValue: nil))
        case (.dictionary(let a)?, .dictionary(let b)?):
            for key in Set(a.keys).union(b.keys).sorted() {
                compare(a[key], b[key], path: path.isEmpty ? key : "\(path).\(key)", into: &changes)
            }
        case (.array(let a)?, .array(let b)?) where a.count == b.count:
            for index in a.indices {
                compare(a[index], b[index], path: "\(path)[\(index)]", into: &changes)
            }
        case (let a?, let b?):
            if a != b { changes.append(StructuredChange(kind: .modified, keyPath: path, oldValue: render(a), newValue: render(b))) }
        }
    }

    /// Compact one-line rendering of a plist value.
    static func render(_ value: PlistValue) -> String {
        switch value {
        case .string(let s): "\"\(s)\""
        case .integer(let i): "\(i)"
        case .real(let d): "\(d)"
        case .bool(let b): b ? "true" : "false"
        case .date(let d): d.formatted(.iso8601)
        case .data(let d): "<\(d.count) байт>"
        case .array(let items): "[" + items.map(render).joined(separator: ", ") + "]"
        case .dictionary(let dict): "{" + dict.keys.sorted().map { "\($0): \(render(dict[$0]!))" }.joined(separator: ", ") + "}"
        }
    }
}
