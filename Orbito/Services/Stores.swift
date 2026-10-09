import Foundation

/// Small JSON-file store in Application Support.
struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    var url: URL

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func appSupport(_ name: String) -> JSONFileStore {
        JSONFileStore(url: URL.applicationSupportDirectory.appending(path: "Orbito/\(name)"))
    }
}

/// Local history of actions taken (and failures observed) by Orbito.
@MainActor
@Observable
final class HistoryStore {
    private(set) var events: [HistoryEvent] = []
    private let store: JSONFileStore<[HistoryEvent]>
    private let maxEvents = 2000

    init(store: JSONFileStore<[HistoryEvent]> = .appSupport("history.json")) {
        self.store = store
        events = store.load() ?? []
    }

    func record(_ label: String, _ kind: HistoryEvent.Kind, _ outcome: HistoryEvent.Outcome, _ message: String = "") {
        events.insert(HistoryEvent(date: .now, label: label, kind: kind, outcome: outcome, message: message), at: 0)
        if events.count > maxEvents { events.removeLast(events.count - maxEvents) }
        try? store.save(events)
    }

    func clear() {
        events.removeAll()
        try? store.save(events)
    }
}

/// Display names, notes and favourites, kept outside the plist.
@MainActor
@Observable
final class MetadataStore {
    private(set) var items: [String: JobMetadata] = [:]
    private let store: JSONFileStore<[String: JobMetadata]>

    init(store: JSONFileStore<[String: JobMetadata]> = .appSupport("metadata.json")) {
        self.store = store
        items = store.load() ?? [:]
    }

    func metadata(for label: String) -> JobMetadata { items[label] ?? JobMetadata() }

    func update(_ label: String, _ change: (inout JobMetadata) -> Void) {
        var value = metadata(for: label)
        change(&value)
        items[label] = value
        try? store.save(items)
    }

    func rename(_ old: String, to new: String) {
        guard let value = items[old] else { return }
        items[new] = value
        try? store.save(items)
    }

    func remove(_ label: String) {
        items.removeValue(forKey: label)
        try? store.save(items)
    }
}
