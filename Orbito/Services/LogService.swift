import Foundation

struct LogSnapshot: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case ok
        case missing
        case notConfigured
        case unreadable(String)
    }

    var state: State
    var lines: [String]
    var fileSize: UInt64
    var modified: Date?
    /// True when only the tail of a larger file was read.
    var truncated: Bool
}

/// Reads the tail of log files in fixed-size chunks from the end,
/// so multi-gigabyte logs never get loaded into memory.
struct LogService: Sendable {
    var chunkSize = 64 * 1024
    /// Hard cap on bytes scanned regardless of requested line count.
    var maxBytes = 8 * 1024 * 1024

    func tail(path: String?, lines requested: Int) -> LogSnapshot {
        guard let path, !path.isEmpty else {
            return LogSnapshot(state: .notConfigured, lines: [], fileSize: 0, truncated: false)
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return LogSnapshot(state: .missing, lines: [], fileSize: 0, truncated: false)
        }
        let attributes = try? fm.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date

        guard let handle = FileHandle(forReadingAtPath: path) else {
            return LogSnapshot(state: .unreadable("Нет прав на чтение файла."), lines: [], fileSize: size, modified: modified, truncated: false)
        }
        defer { try? handle.close() }

        do {
            let (data, truncated) = try readTail(handle: handle, size: size, lines: requested)
            var text = String(decoding: data, as: UTF8.self)
            if text.hasSuffix("\n") { text.removeLast() }
            var result = text.isEmpty ? [] : text.components(separatedBy: "\n")
            if truncated, !result.isEmpty { result.removeFirst() } // partial first line
            let dropped = result.count > requested
            if dropped { result = Array(result.suffix(requested)) }
            return LogSnapshot(state: .ok, lines: result, fileSize: size, modified: modified, truncated: truncated || dropped)
        } catch {
            return LogSnapshot(state: .unreadable(error.localizedDescription), lines: [], fileSize: size, modified: modified, truncated: false)
        }
    }

    private func readTail(handle: FileHandle, size: UInt64, lines: Int) throws -> (Data, Bool) {
        var offset = size
        var buffer = Data()
        var newlineCount = 0
        let limit = UInt64(maxBytes)

        while offset > 0, newlineCount <= lines, UInt64(buffer.count) < limit {
            let length = min(UInt64(chunkSize), offset)
            offset -= length
            try handle.seek(toOffset: offset)
            let chunk = try handle.read(upToCount: Int(length)) ?? Data()
            newlineCount += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            buffer.insert(contentsOf: chunk, at: 0)
        }
        return (buffer, offset > 0)
    }
}
