import Testing
import AgwebCore

private let page = """
- navigation "Main" [ref=e1]
  - link "Home" [ref=e2]
- main [ref=e3]
  - form [ref=e4]
    - textbox "Email" [ref=e5]
    - button "Save" [ref=e6]
"""

@Test func diffShowsChangesUnderTheirParents() throws {
    let after = page.replacingOccurrences(of: "    - button \"Save\" [ref=e6]", with: "    - button \"Saving\" [ref=e6] [disabled]\n    - text: \"Saved\"")
    let diff = try #require(Snapshot.diff(from: page, to: after))
    #expect(diff == """
          - main [ref=e3]
            - form [ref=e4]
        -     - button "Save" [ref=e6]
        +     - button "Saving" [ref=e6] [disabled]
        +     - text: "Saved"
        """)
}

@Test func diffOfTheSameTreeIsNil() {
    #expect(Snapshot.diff(from: page, to: page) == nil)
}

@Test func anEmptiedPageShowsOnlyRemovals() throws {
    let diff = try #require(Snapshot.diff(from: "- link \"Home\" [ref=e2]", to: ""))
    #expect(diff == "- - link \"Home\" [ref=e2]")
}

@Test func aFilledPageShowsOnlyAdditions() throws {
    #expect(try #require(Snapshot.diff(from: "", to: "- link \"Home\" [ref=e2]")) == "+ - link \"Home\" [ref=e2]")
}

@Test func findKeepsTheEnclosingLines() throws {
    let found = try #require(Snapshot.find("save", in: page, max: 20))
    #expect(found.matches == 1)
    #expect(found.tree == """
        - main [ref=e3]
          - form [ref=e4]
            - button "Save" [ref=e6]
        """)
}

@Test func findShowsWhatFollowsInTheSameContainer() throws {
    let found = try #require(Snapshot.find("email", in: page + "\n- contentinfo [ref=e7]", max: 20))
    #expect(found.tree == """
        - main [ref=e3]
          - form [ref=e4]
            - textbox "Email" [ref=e5]
            - button "Save" [ref=e6]
        """)
    let operations = (0..<3).map { "- heading \"GET /op\($0)\" [ref=e\($0)0]\n  - textbox [ref=e\($0)1]\n- button \"TRY\" [ref=e\($0)2]" }.joined(separator: "\n")
    let one = try #require(Snapshot.find("/op1", in: operations, max: 20, after: 2))
    #expect(one.tree == "- heading \"GET /op1\" [ref=e10]\n  - textbox [ref=e11]\n- button \"TRY\" [ref=e12]")
}

@Test func findCapsItsMatches() throws {
    let found = try #require(Snapshot.find("ref=e", in: page, max: 2))
    #expect(found.matches == 6)
    #expect(found.tree.hasSuffix("- (4 more; --max-results to see them)"))
    #expect(Snapshot.find("nothing", in: page, max: 2) == nil)
}

@Test func removedLinesSitUnderTheirOldParents() throws {
    let after = page.replacingOccurrences(of: "  - form [ref=e4]\n    - textbox \"Email\" [ref=e5]\n    - button \"Save\" [ref=e6]", with: "  - text: \"Sent\"")
    let diff = try #require(Snapshot.diff(from: page, to: after))
    #expect(diff == """
          - main [ref=e3]
        -   - form [ref=e4]
        -     - textbox "Email" [ref=e5]
        -     - button "Save" [ref=e6]
        +   - text: "Sent"
        """)
}

@Test func focusMovingIsNoChange() {
    let focused = page.replacingOccurrences(of: "[ref=e5]", with: "[ref=e5] [focused]")
    #expect(Snapshot.diff(from: page, to: focused) == nil)
}

@Test func refLabelsComeFromRoleAndNameOnly() {
    func label(_ line: String) -> String? { Snapshot.refLabel(Substring(line)).map { "\($0.label) \($0.ref)" } }
    #expect(label("    - button \"Save\" [ref=e6]") == "button \"Save\" e6")
    #expect(label("- main [ref=e3]") == "main e3")
    #expect(label("  - heading \"Title\" [level=2] [ref=e9] [focused]") == "heading \"Title\" e9")
    #expect(label("- textbox \"Email\" [value=\"me@x.io\"] [ref=e5]") == "textbox \"Email\" e5")
    #expect(label("- textbox \"Pass\" [value=<hidden>] [ref=e7]") == "textbox \"Pass\" e7")
    #expect(label("- checkbox \"A\" [checked] [disabled] [ref=e12]") == "checkbox \"A\" e12")
    // Quoted text can't claim a ref: an escaped quote stays inside the name, a value's "[ref=e3]" is skipped.
    #expect(label("- link \"say \\\"hi\\\" [ref=e3]\" [ref=e4]") == "link \"say \\\"hi\\\" [ref=e3]\" e4")
    #expect(label("- textbox [value=\"x [ref=e3]\"] [ref=e8]") == "textbox e8")
    #expect(label("- text: \"Saved [ref=e3]\"") == nil)
    #expect(label("- option \"One\" [selected]") == nil)
    #expect(label("- button \"unterminated [ref=e3]") == nil)
}

@Test func findFoldsCaseBeyondASCII() throws {
    let tree = "- heading \"Straße\" [ref=e1]\n- heading \"ΟΔΟΣ\" [ref=e2]\n- link \"File\" [ref=e3]"
    #expect(try #require(Snapshot.find("STRASSE", in: tree, max: 20)).tree.contains("e1"))
    #expect(try #require(Snapshot.find("strasse", in: tree, max: 20)).tree.contains("e1"))
    #expect(try #require(Snapshot.find("οδος", in: tree, max: 20)).tree.contains("e2"))
    #expect(try #require(Snapshot.find("file", in: tree, max: 20)).tree.contains("e3"))
}
