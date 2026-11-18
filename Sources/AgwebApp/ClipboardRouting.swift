import AppKit
import WebKit
import AgwebCore

/// Pages never write the system clipboard: an agent's click on a copy button would replace whatever the person
/// copied. The page hook (PageScripts.clipboardHook) sends every write here instead, and the input the page is
/// answering decides where it lands: after the person's own click or key in the tab, on the person's clipboard; after
/// an agent's, or with no input yet, in the workspace's clipboard, which `agweb clipboard` reads and ⌘V pastes from.
/// Reads get the workspace's clipboard after an agent's input; the person's clipboard is never read.
extension ConsoleSink: WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard let tab = browser?.tab(for: message.webView), let body = message.body as? [String: Any] else {
                return replyHandler(nil, nil)
            }
            replyHandler(tab.clipboardCall(body, frame: message.frameInfo), nil)
        }
    }
}

extension Tab {
    /// How long after an input a page may still use the clipboard: WebKit's own window is about 5 s.
    static let clipboardWindow: TimeInterval = 10

    /// The person's input came last. No input at all counts as the agent's, so a copy nobody can place stays off
    /// the person's clipboard.
    var personDrives: Bool { personInputAt > agentInputAt }

    /// The hook's write (triples) or read; the reply is "ok"/"denied" for a write, the triples or nil for a read
    /// (nil: let WebKit answer, which refuses). The hook only calls with a user gesture, but any frame can post to the
    /// handler itself, so: the input must be recent and the call must come from the main frame or the frame clicked
    /// into (an ad's frame can't write or read), and a page reads back only its own origin's copy or what
    /// `clipboard-set` gave (another site never sees what the agent copied elsewhere).
    func clipboardCall(_ body: [String: Any], frame: WKFrameInfo) -> Any? {
        let person = personDrives
        guard Date().timeIntervalSince(person ? personInputAt : agentInputAt) < Self.clipboardWindow,
              frame.isMainFrame || Self.isFocused(frame) else {
            return body["write"] != nil ? "denied" : nil
        }
        let origin = Self.origin(frame.securityOrigin)
        if let triples = body["write"] {
            // An opaque origin (a sandboxed frame, data:) is like no other, not even the next opaque one.
            guard let clip = Clip(triples: triples, source: frame.request.url?.absoluteString ?? currentURL, origin: origin ?? "opaque:\(UUID())"),
                  clip.isSupported else { return "denied" }
            if person {
                guard clip.writeToGeneralPasteboard() else { return "denied" }
            } else {
                workspace.clipboard = clip
                // A page copying on a timer would fill the reply; only its last copy counts.
                events.removeAll { $0.hasPrefix(Self.copiedEvent) || $0 == Self.clearedEvent }
                events.append(clip.items.isEmpty ? Self.clearedEvent : "\(Self.copiedEvent)\(clip.summary) to the workspace clipboard (agweb clipboard)")
            }
            return "ok"
        }
        if body["read"] != nil {
            guard !person, let clip = workspace.clipboard else { return person ? nil : [] }
            return clip.origin == nil || (origin != nil && clip.origin == origin) ? clip.triples : nil
        }
        return nil
    }

    private static let copiedEvent = "copied "
    private static let clearedEvent = "the page cleared the workspace clipboard"

    /// Nil for an opaque origin. Local files count as one origin, so a local build can paste what it copied.
    static func origin(_ origin: WKSecurityOrigin) -> String? {
        if origin.protocol == "file" { return "file://" }
        guard !origin.protocol.isEmpty, !origin.host.isEmpty else { return nil }
        return "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
    }

    /// WebKit's private flag for the frame that has focus: the one the person or an agent last clicked into.
    static func isFocused(_ info: WKFrameInfo) -> Bool {
        let selector = NSSelectorFromString("_isFocused")
        typealias IsFocused = @convention(c) (AnyObject, Selector) -> Bool
        return info.responds(to: selector) && unsafeBitCast(info.method(for: selector), to: IsFocused.self)(info, selector)
    }
}

extension Clip {
    /// The person's copy, as WebKit would have written it; false, and their clipboard left alone, when nothing in it
    /// could be written. An empty copy clears it.
    @MainActor func writeToGeneralPasteboard() -> Bool {
        let item = NSPasteboardItem()
        for entry in items {
            switch (entry.type, entry.binary) {
            case ("text/plain", false): item.setString(entry.value, forType: .string)
            case ("text/html", false): item.setString(entry.value, forType: .html)
            case ("text/uri-list", false):
                if let url = entry.value.split(whereSeparator: \.isNewline).first(where: { !$0.hasPrefix("#") }) { item.setString(String(url), forType: .URL) }
            case ("image/png", true): if let data = Data(base64Encoded: entry.value) { item.setData(data, forType: .png) }
            default: break
            }
        }
        guard items.isEmpty || !item.types.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !item.types.isEmpty { pasteboard.writeObjects([item]) }
        return true
    }
}
