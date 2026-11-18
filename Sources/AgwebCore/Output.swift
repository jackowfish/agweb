import Foundation

/// Replies are markdown sections (`### Result`, `### Page`, ...). `--raw` and `--json` reshape them in the CLI.
public enum Output {
    /// Sections that describe the tab rather than answer the command.
    static let context: Set = ["Page", "Tabs", "Events"]
    /// Every title the app emits; a `### Heading` in an answer (an article from `text`, a response body) is content.
    static let titles: Set = context.union(["Result", "Snapshot", "Changes", "Found", "Download", "PDF", "Screenshot", "Video", "Routes", "Static", "History"])

    static func isTitle(_ title: Substring) -> Bool {
        titles.contains(String(title)) || title.hasPrefix("Request ") || title.hasPrefix("Static ")
    }

    public static func sections(_ text: String) -> [(title: String, body: String)] {
        var result: [(String, [Substring])] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### "), isTitle(line.dropFirst(4)) {
                result.append((String(line.dropFirst(4)), []))
            } else if result.isEmpty {
                result.append(("Result", [line]))
            } else {
                result[result.count - 1].1.append(line)
            }
        }
        return result.map { ($0.0, $0.1.joined(separator: "\n").trimmingCharacters(in: .newlines)) }
    }

    /// `text` prints at most this many bytes of its answer, so one page (a feed, a huge table) can't fill an agent's context.
    public static let textLimit = 50_000

    /// A page's `### History` or `### Request body` would read as a reply section and end the answer there; one level
    /// down it stays content.
    public static func demoteTitles(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("### ") && isTitle($0.dropFirst(4)) ? "#" + $0 : $0 }.joined(separator: "\n")
    }

    /// A `text` reply cut to `limit` bytes at a line break, ending with a line that says so, and a Page note for --raw's
    /// stderr; `--filename` writes it whole.
    public static func capText(_ text: String, limit: Int = textLimit) -> String {
        var parts = sections(text)
        guard let i = parts.firstIndex(where: { $0.title == "Result" }), parts[i].body.utf8.count > limit else { return text }
        let body = parts[i].body
        // The byte prefix may end inside a character: decoding turns that into U+FFFD, dropped unless a line break comes first.
        var kept = String(decoding: body.utf8.prefix(limit), as: UTF8.self)
        if let line = kept.lastIndex(of: "\n"), kept.utf8.distance(from: kept.startIndex, to: line) > limit / 2 {
            kept = String(kept[..<line])
        } else {
            while kept.last == "\u{FFFD}" { kept.removeLast() }
        }
        let kb = { (bytes: Int) in "\(max(1, Int((Double(bytes) / 1000).rounded()))) KB" }
        parts[i].body = kept.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n… (cut at \(kb(kept.utf8.count)) of \(kb(body.utf8.count)): text <ref> reads one part, --filename=page.md saves all of it)"
        let note = "text cut at \(kb(kept.utf8.count)) of \(kb(body.utf8.count)); --filename saves all of it"
        if let page = parts.firstIndex(where: { $0.title == "Page" }) {
            var lines = parts[page].body.components(separatedBy: "\n")
            if let n = lines.firstIndex(where: { $0.hasPrefix("- Note: ") }) { lines[n] += "; " + note } else { lines.append("- Note: " + note) }
            parts[page].body = lines.joined(separator: "\n")
        }
        return parts.map { "### \($0.title)\n\($0.body)" }.joined(separator: "\n")
    }

    /// The command's own answer without the page around it; a JSON string comes out unquoted.
    public static func raw(_ text: String) -> String {
        guard let body = sections(text).first(where: { !context.contains($0.title) })?.body else { return "" }
        if body.hasPrefix("\""), let string = try? JSONDecoder().decode(String.self, from: Data(body.utf8)) { return string }
        return body
    }

    /// What a `--raw` reply leaves out of the answer, for stderr: the Events and the Page notes.
    public static func rawNotes(_ text: String) -> [String] {
        sections(text).flatMap { section in
            section.title == "Events" ? section.body.split(separator: "\n")
                : section.title == "Page" ? section.body.split(separator: "\n").filter { $0.hasPrefix("- Note: ") || $0.hasPrefix("- Console: ") } : []
        }.map { String($0.dropFirst(2)) }
    }

    /// One JSON object: `ok`, then each section by lowercased title. JSON bodies stay JSON, `- Key: value` lists
    /// become objects, anything else is a string. Output that is already a JSON object passes through.
    public static func json(_ text: String, ok: Bool) -> String {
        if ok, text.hasPrefix("{"), (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any] { return text }
        var object: [String: Any] = ["ok": ok]
        if !ok {
            object["error"] = text.hasPrefix("Error: ") ? String(text.dropFirst(7)) : text
        } else {
            // Changes, Found and History are lists of lines; read as `- key: value` pairs, two calls would collapse into one.
            for (title, body) in sections(text) {
                object[title.lowercased()] = ["Changes", "Found", "History"].contains(title) ? body.split(separator: "\n").map(String.init) : value(body)
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func value(_ body: String) -> Any {
        if let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: .fragmentsAllowed) { return parsed }
        let lines = body.split(separator: "\n")
        let pairs = lines.compactMap { line -> (String, String)? in
            guard line.hasPrefix("- "), let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[line.index(line.startIndex, offsetBy: 2)..<colon]
            guard !key.contains(" "), !key.isEmpty else { return nil }
            return (key.lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        // Two notes (a reply's own and the window's or a challenge's) both reach the agent.
        if !lines.isEmpty, pairs.count == lines.count { return Dictionary(pairs, uniquingKeysWith: { a, b in a + "; " + b }) }
        return body
    }
}
