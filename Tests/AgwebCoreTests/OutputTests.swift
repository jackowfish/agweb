import Foundation
import Testing
import AgwebCore

let evalReply = "### Result\n\"a\\nb\"\n### Page\n- URL: https://example.com/\n- Title: Example"

@Test func rawIsTheAnswerWithStringsUnquoted() {
    #expect(Output.raw(evalReply) == "a\nb")
    #expect(Output.raw("### Result\n{\"n\":1}\n### Page\n- URL: x") == "{\"n\":1}")
    #expect(Output.raw("### Page\n- URL: x\n### Tabs\n- 0: a") == "")
    #expect(Output.raw("no workspaces") == "no workspaces")
}

@Test func headingsInAnAnswerAreContent() {
    let article = "### Result\n# Title\n\nIntro\n\n### Overview\nMore\n### Page\n- URL: x"
    #expect(Output.raw(article) == "# Title\n\nIntro\n\n### Overview\nMore")
}

@Test func jsonParsesSections() throws {
    let object = try #require(JSONSerialization.jsonObject(with: Data(Output.json(evalReply, ok: true).utf8)) as? [String: Any])
    #expect(object["ok"] as? Bool == true)
    #expect(object["result"] as? String == "a\nb")
    #expect(object["page"] as? [String: String] == ["url": "https://example.com/", "title": "Example"])
}

@Test func jsonPassesObjectsThroughAndReportsErrors() throws {
    #expect(Output.json("{\"workspaces\":[]}", ok: true) == "{\"workspaces\":[]}")
    let error = try #require(JSONSerialization.jsonObject(with: Data(Output.json("Error: boom", ok: false).utf8)) as? [String: Any])
    #expect(error["ok"] as? Bool == false && error["error"] as? String == "boom")
}

@Test func changesStayAList() throws {
    let reply = "### Page\n- URL: x\n### Changes\n- call: POST https://a/1 => 201\n- call: POST https://a/2 => 201"
    let object = try #require(JSONSerialization.jsonObject(with: Data(Output.json(reply, ok: true).utf8)) as? [String: Any])
    #expect(object["changes"] as? [String] == ["- call: POST https://a/1 => 201", "- call: POST https://a/2 => 201"])
}

@Test func historyIsItsOwnList() throws {
    let reply = "### Page\n- URL: https://a/2\n- Title: Two\n### History\n- -1: [One](https://a/1)\n- 0 (current): [Two](https://a/2)"
    #expect(Output.raw(reply) == "- -1: [One](https://a/1)\n- 0 (current): [Two](https://a/2)")
    let object = try #require(JSONSerialization.jsonObject(with: Data(Output.json(reply, ok: true).utf8)) as? [String: Any])
    #expect(object["history"] as? [String] == ["- -1: [One](https://a/1)", "- 0 (current): [Two](https://a/2)"])
    #expect(object["page"] as? [String: String] == ["url": "https://a/2", "title": "Two"])
}

@Test func rawNotesAreTheEventsAndPageNotes() {
    let reply = "### Result\n\"42\"\n### Page\n- URL: https://a.test/\n- Note: main content only\n- Console: 2 new errors\n### Events\n- the tab moved since your last command"
    #expect(Output.raw(reply) == "42")
    #expect(Output.rawNotes(reply) == ["Note: main content only", "Console: 2 new errors", "the tab moved since your last command"])
    #expect(Output.rawNotes("### Result\n1\n### Page\n- URL: x").isEmpty)
}

@Test func textIsCutAtALineAndSaysSo() {
    let page = "\n### Page\n- URL: x"
    #expect(Output.capText("### Result\nshort" + page, limit: 100) == "### Result\nshort" + page)
    let lines = (1...30).map { "line \($0) of the page" }.joined(separator: "\n")
    let cut = Output.capText("### Result\n" + lines + page, limit: 200)
    let answer = Output.raw(cut)
    #expect(answer.hasPrefix("line 1 of the page\n"))
    #expect(answer.hasSuffix("… (cut at 1 KB of 1 KB: text <ref> reads one part, --filename=page.md saves all of it)"))
    #expect(answer.contains("line 9 of the page\n") && !answer.contains("line 11 "))
    #expect(cut.hasSuffix(page + "\n- Note: text cut at 1 KB of 1 KB; --filename saves all of it"))
    #expect(Output.rawNotes(Output.capText("### Result\n" + lines + "\n### Page\n- URL: x\n- Note: no article here", limit: 200))
        == ["Note: no article here; text cut at 1 KB of 1 KB; --filename saves all of it"])
    // One long line is cut inside it, never inside a character.
    let wide = Output.raw(Output.capText("### Result\n" + String(repeating: "é", count: 200) + page, limit: 101))
    #expect(wide.hasPrefix(String(repeating: "é", count: 50) + "\n\n…"))
}

@Test func aPagesHeadingNamedLikeASectionStaysInTheAnswer() {
    let markdown = Output.demoteTitles("# API\n\n### Request body\n\nJSON\n\n### History\n\nv1\n\n### Overview")
    #expect(markdown == "# API\n\n#### Request body\n\nJSON\n\n#### History\n\nv1\n\n### Overview")
    #expect(Output.raw("### Result\n" + markdown + "\n### Page\n- URL: x") == markdown)
}
