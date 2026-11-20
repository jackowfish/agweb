/// Snapshot text, pruned: what changed since the last one, or the lines matching a search. Either way each line
/// comes with the lines above it that place it in the tree, so the agent needs no full snapshot to act on it.
public enum Snapshot {
    private static func depth(_ line: Substring) -> Int { line.prefix { $0 == " " }.count / 2 }

    /// Indices of the lines that enclose a line at `depth` sitting just before `index`, outermost first.
    private static func ancestors(of depth: Int, before index: Int, in lines: [Substring]) -> [Int] {
        var found: [Int] = [], depth = depth, k = index - 1
        while k >= 0, depth > 0 {
            let d = Self.depth(lines[k])
            if d < depth {
                found.append(k)
                depth = d
            }
            k -= 1
        }
        return found.reversed()
    }

    /// `+ ` added and `- ` removed lines, each under the unchanged lines enclosing it (indented by two); nil when
    /// nothing changed. Focus moving is left out: every click moves it.
    public static func diff(from old: String, to new: String) -> String? {
        func lines(_ tree: String) -> [Substring] {
            // An empty tree has no lines, not one empty line.
            tree.isEmpty ? [] : tree.replacingOccurrences(of: " [focused]", with: "").split(separator: "\n", omittingEmptySubsequences: false)
        }
        let before = lines(old), after = lines(new)
        let changes = after.difference(from: before)
        guard !changes.isEmpty else { return nil }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [String] = [], shown = Set<Substring>()
        // A removed line's parents come from the old tree, an added one's from the new; neither from changed lines.
        func context(_ line: Substring, _ index: Int, in tree: [Substring], changed: Set<Int>) {
            for k in ancestors(of: depth(line), before: index, in: tree) where !changed.contains(k) && !shown.contains(tree[k]) {
                out.append("  " + tree[k])
                shown.insert(tree[k])
            }
        }
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                context(before[i], i, in: before, changed: removed)
                out.append("- " + before[i])
                i += 1
            } else if j < after.count, inserted.contains(j) {
                context(after[j], j, in: after, changed: inserted)
                out.append("+ " + after[j])
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return out.joined(separator: "\n")
    }

    /// The role and name a snapshot line gives its ref ("button \"Save\"", "e12"); nil for a line without a ref.
    /// Quoted names and values are skipped whole, so page text quoting "[ref=e3]" can't claim e3. A scanner, not a
    /// Regex: a 50,000-line snapshot took 9 s through Swift's Regex.
    public static func refLabel(_ line: Substring) -> (label: Substring, ref: Substring)? {
        let bytes = line.utf8
        var i = bytes.startIndex
        func at(_ text: String) -> Bool {
            var k = i
            for byte in text.utf8 {
                guard k < bytes.endIndex, bytes[k] == byte else { return false }
                k = bytes.index(after: k)
            }
            i = k
            return true
        }
        func lower(_ byte: UInt8) -> Bool { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) }
        func digits() -> Bool {
            let start = i
            while i < bytes.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i = bytes.index(after: i) }
            return i > start
        }
        // A JSON string from its opening quote, escapes included.
        func quoted() -> Bool {
            guard at("\"") else { return false }
            while i < bytes.endIndex {
                let byte = bytes[i]
                i = bytes.index(after: i)
                if byte == UInt8(ascii: "\\") {
                    guard i < bytes.endIndex else { return false }
                    i = bytes.index(after: i)
                } else if byte == UInt8(ascii: "\"") {
                    return true
                }
            }
            return false
        }
        while i < bytes.endIndex, bytes[i] == UInt8(ascii: " ") { i = bytes.index(after: i) }
        guard at("- ") else { return nil }
        let start = i
        while i < bytes.endIndex, lower(bytes[i]) || bytes[i] == UInt8(ascii: "-") { i = bytes.index(after: i) }
        guard i > start else { return nil }
        var end = i
        let afterRole = i
        if !(at(" ") && quoted()) { i = afterRole } else { end = i }
        while at(" [") {
            if at("ref=e") {
                let ref = bytes.index(i, offsetBy: -1)
                guard digits() else { return nil }
                let refEnd = i
                guard at("]") else { return nil }
                return (Substring(line[start..<end]), Substring(line[ref..<refEnd]))
            }
            if at("value=") {
                guard at("<hidden>") || quoted() else { return nil }
            } else {
                let name = i
                while i < bytes.endIndex, lower(bytes[i]) { i = bytes.index(after: i) }
                guard i > name else { return nil }
                if at("=") { guard digits() else { return nil } }
            }
            guard at("]") else { return nil }
        }
        return nil
    }

    /// The lines containing `query` (any case) as a pruned tree: each with the lines enclosing it and up to `after`
    /// lines that follow it in the same container (a heading's form fields and buttons); nil when none match.
    public static func find(_ query: String, in tree: String, max: Int, after: Int = 10) -> (tree: String, matches: Int)? {
        let lines = Output.lines(tree)
        // ASCII query, ASCII line: the tree lowercased once and searched with the standard library, where Foundation's
        // case-insensitive range(of:) on every line took 0.8 s over 165,000 lines (lowercasing keeps every line break, so
        // the line numbers agree). Anything else keeps Foundation's full case folding: strasse finds Straße, οδος ΟΔΟΣ.
        let ascii = query.allSatisfy(\.isASCII), needle = query.lowercased()
        let lowered = ascii ? Output.lines(tree.lowercased()) : []
        let matching = lines.indices.filter { index in
            ascii && lines[index].utf8.allSatisfy({ $0 < 128 }) ? lowered[index].contains(needle)
                : lines[index].range(of: query, options: .caseInsensitive) != nil
        }
        guard !matching.isEmpty else { return nil }
        let shown = matching.prefix(Swift.max(max, 1)), wanted = Set(shown)
        // One pass with the chain of enclosing lines: walking back from each match took 39 s for 1500 matches.
        var keep = Set<Int>(), chain: [(depth: Int, index: Int)] = []
        for index in lines.indices where index <= shown.last! {
            let level = depth(lines[index])
            while let last = chain.last, last.depth >= level { chain.removeLast() }
            if wanted.contains(index) { keep.formUnion(chain.map(\.index)) }
            chain.append((level, index))
        }
        for index in shown {
            let level = depth(lines[index])
            keep.insert(index)
            var k = index + 1
            while k < lines.count, k - index <= after, depth(lines[k]) >= level {
                keep.insert(k)
                k += 1
            }
        }
        var out = keep.sorted().map { String(lines[$0]) }
        if matching.count > max { out.append("- (\(matching.count - max) more; --max-results to see them)") }
        return (out.joined(separator: "\n"), matching.count)
    }
}
