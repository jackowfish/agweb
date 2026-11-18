import Foundation
import Testing
@testable import AgwebCore

@Test func clipReadsTheHooksTriples() throws {
    let clip = try #require(Clip(triples: [["text/plain", "hi", false], ["IMAGE/PNG", "AAAA", true]], source: "https://a.test/", origin: nil))
    #expect(clip.items == [Clip.Item(type: "text/plain", value: "hi"), Clip.Item(type: "image/png", value: "AAAA", binary: true)])
    #expect(clip.text == "hi")
    #expect((clip.triples[1][2] as? Bool) == true)
}

@Test(arguments: [nil, "text" as Any, [["text/plain", "x"]] as Any, [["text/plain", 1, false]] as Any, [["", "x", false]] as Any])
func clipRefusesAnythingElseAPagePosts(body: Any?) {
    #expect(Clip(triples: body, source: "p", origin: nil) == nil)
}

@Test func clipSummaryQuotesAndCutsTheText() {
    #expect(Clip(items: [.init(type: "text/plain", value: "a \"b\"\nc")], source: "p").summary == #""a \"b\"\nc""#)
    let long = Clip(items: [.init(type: "text/plain", value: String(repeating: "x", count: 250))], source: "p").summary
    #expect(long.hasSuffix("… (250 characters)") && long.hasPrefix("\"" + String(repeating: "x", count: 200) + "\""))
    #expect(Clip(items: [.init(type: "image/png", value: String(repeating: "A", count: 4096), binary: true)], source: "p").summary == "image/png (3.0 KB)")
    #expect(Clip(items: [], source: "p").summary.contains("cleared"))
}

@Test func clipboardReplyRawIsTheText() {
    let now = Date()
    let clip = Clip(items: [.init(type: "text/plain", value: "copied"), .init(type: "text/html", value: "<b>copied</b>")],
                    source: "https://a.test/", at: now.addingTimeInterval(-3))
    let reply = clip.describe(now: now)
    #expect(Output.raw(reply) == "copied")
    #expect(Output.rawNotes(reply) == ["from https://a.test/, 3 s ago", "also text/html (13 B)"])
}

@Test func pasteHasNoVerbOfItsOwn() {
    #expect(Commands.unknown("paste").contains("clipboard-set <text>, then agweb press Meta+v"))
    #expect(Commands.unknown("clipboard-get").hasSuffix("did you mean clipboard?"))
}

@Test func clipNeedsATypeWebKitWritesAndAReasonableSize() {
    #expect(Clip(items: [.init(type: "image/jpeg", value: "AA", binary: true)], source: "p").isSupported == false)
    #expect(Clip(items: [.init(type: "image/jpeg", value: "AA", binary: true), .init(type: "text/plain", value: "x")], source: "p").isSupported)
    #expect(Clip(items: [], source: "p").isSupported)
    #expect(Clip(triples: [["text/plain", String(repeating: "x", count: Clip.maxBytes + 1), false]], source: "p", origin: nil) == nil)
}

@Test func agoCountsDaysPastADay() {
    #expect(Clip.ago(30) == "30 s ago")
    #expect(Clip.ago(7200) == "2 h ago")
    #expect(Clip.ago(3 * 86400 + 5) == "3 d ago")
}
