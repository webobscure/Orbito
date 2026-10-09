import Foundation

/// Stores timestamped copies of plists before any modification.
struct BackupService: Sendable {
    var root: URL

    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Orbito/Backups", directoryHint: .isDirectory)
    }

    @discardableResult
    func backup(_ data: Data, label: String, date: Date = .now) throws -> URL {
        let safeLabel = Self.safeName(label)
        let directory = root.appending(path: safeLabel, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: date)
        var url = directory.appending(path: "\(safeLabel)-\(stamp).plist")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(safeLabel)-\(stamp)-\(counter).plist")
            counter += 1
        }
        try PlistService.createAtomically(data, at: url)
        return url
    }

    func backups(for label: String) -> [URL] {
        let directory = root.appending(path: Self.safeName(label), directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "plist" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Directory-safe form of a label: no separators, never "." or "..".
    static func safeName(_ label: String) -> String {
        let cleaned = label.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return (cleaned.isEmpty || cleaned.hasPrefix(".")) ? "_" + cleaned : cleaned
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

enum LabelValidator {
    static func isValidSyntax(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 200, !label.hasPrefix("."), !label.contains("..") else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "._-".unicodeScalars.contains(scalar)
        }
    }

    /// Throws when the label is malformed or already used on disk or in launchd.
    static func validateNew(_ label: String, existingLabels: Set<String>, directory: URL) throws {
        guard isValidSyntax(label) else { throw OrbitoError.invalidLabel(label) }
        if label.hasPrefix("com.apple.") { throw OrbitoError.invalidLabel(label) }
        if existingLabels.contains(label) { throw OrbitoError.labelConflict(label) }
        let file = directory.appending(path: "\(label).plist")
        if FileManager.default.fileExists(atPath: file.path) { throw OrbitoError.fileExists(path: file.path) }
    }

    static func suggestedLabel(from name: String, prefix: String = "local") -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        let slug = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let cleaned = slug.unicodeScalars.map { scalar -> Character in
            (CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII) ? Character(scalar) : "-"
        }
        let collapsed = String(cleaned).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "\(prefix).task" : "\(prefix).\(collapsed)"
    }

    static func uniqueCopyLabel(for label: String, existing: Set<String>) -> String {
        var candidate = "\(label).copy"
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(label).copy\(counter)"
            counter += 1
        }
        return candidate
    }
}
