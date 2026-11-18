import Foundation

/// What a page copied, or `clipboard-set` gave: one clipboard item as types and their data, binary data in base64.
/// The page hook (PageScripts.clipboardHook) sends and receives it as `[type, value, base64]` triples.
public struct Clip: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let type: String
        public let value: String
        public let binary: Bool

        public init(type: String, value: String, binary: Bool = false) {
            self.type = type
            self.value = value
            self.binary = binary
        }
    }

    public var items: [Item]
    /// The page that copied it, or "clipboard-set".
    public var source: String
    /// The copying frame's origin: only pages of that origin may read it back. Nil (`clipboard-set`): any page may.
    public var origin: String?
    public var at: Date

    public init(items: [Item], source: String, origin: String? = nil, at: Date = Date()) {
        self.items = items
        self.source = source
        self.origin = origin
        self.at = at
    }

    /// The types WebKit writes to the system clipboard; a write with none of them fails.
    public static let supported: Set = ["text/plain", "text/html", "text/uri-list", "image/png"]
    /// What one copy may hold, base64 included.
    public static let maxBytes = 16 << 20

    public var isSupported: Bool { items.isEmpty || items.contains { Self.supported.contains($0.type) } }

    /// The hook's triples; nil for anything else a page posts, or more than `maxBytes`.
    public init?(triples: Any?, source: String, origin: String?, at: Date = Date()) {
        guard let list = triples as? [[Any]], list.count <= 32 else { return nil }
        var items: [Item] = []
        for triple in list {
            guard triple.count == 3, let type = triple[0] as? String, let value = triple[1] as? String, let binary = triple[2] as? Bool,
                  !type.isEmpty, type.count <= 200 else { return nil }
            items.append(Item(type: type.lowercased(), value: value, binary: binary))
        }
        guard items.reduce(0, { $0 + $1.value.utf8.count }) <= Self.maxBytes else { return nil }
        self.init(items: items, source: source, origin: origin, at: at)
    }

    public var triples: [[Any]] { items.map { [$0.type, $0.value, $0.binary] } }

    public var text: String? { items.first { $0.type == "text/plain" }?.value }

    /// One line for a reply: the text, cut, or what the item holds when it has no text.
    public var summary: String {
        if let text { return Self.quoted(text, limit: 200) }
        if items.isEmpty { return "nothing (the page cleared the clipboard)" }
        return items.map { "\($0.type) (\(Self.size(of: $0)))" }.joined(separator: ", ")
    }

    /// The `clipboard` reply: the text as a JSON string (what --raw prints), then where it came from and what else it holds.
    public func describe(now: Date = Date()) -> String {
        var notes = ["from \(source), \(Self.ago(now.timeIntervalSince(at)))"]
        let others = items.filter { $0.type != "text/plain" }
        if !others.isEmpty { notes.append("also " + others.map { "\($0.type) (\(Self.size(of: $0)))" }.joined(separator: ", ")) }
        if items.isEmpty { notes.append("the page cleared the clipboard") }
        return "### Result\n" + Self.json(text ?? "") + "\n### Events\n" + notes.map { "- \($0)" }.joined(separator: "\n")
    }

    static func size(of item: Item) -> String {
        let bytes = item.binary ? item.value.count * 3 / 4 : item.value.utf8.count
        return bytes < 1024 ? "\(bytes) B" : bytes < 1024 * 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    static func quoted(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return json(text) }
        return json(String(text.prefix(limit))) + "… (\(text.count) characters)"
    }

    static func json(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s < 60 ? "\(s) s ago" : s < 3600 ? "\(s / 60) min ago" : "\(s / 3600) h ago"
    }
}
