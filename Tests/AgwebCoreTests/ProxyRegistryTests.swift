import Foundation
import Testing
@testable import AgwebCore

@Test func registryReadsEntriesAndKeepsBadOnesByName() {
    let data = Data(#"{"work": {"kind": "socks5", "host": "h", "port": 1080, "username": "u", "password": "p"}, "bad": {"kind": "ftp", "host": "h", "port": 1}, "noport": {"kind": "http", "host": "h", "port": 0}, "odd": 5}"#.utf8)
    let entries = ProxyRegistry.entries(data)
    #expect(entries?["work"] == .proxy(ProxySpec(kind: .socks5, host: "h", port: 1080, username: "u", password: "p")))
    #expect(entries?["bad"] == .unreadable)
    #expect(entries?["noport"] == .unreadable)
    #expect(entries?["odd"] == .unreadable)
    #expect(entries?["other"] == nil)
}

@Test func registryThatIsNotAnObjectReadsAsNil() {
    #expect(ProxyRegistry.entries(Data("{".utf8)) == nil)
    #expect(ProxyRegistry.entries(Data(#"["work"]"#.utf8)) == nil)
    #expect(ProxyRegistry.entries(Data("{}".utf8)) == [:])
}

@Test func settingOneProxyLeavesTheOthersAsTheyWere() throws {
    let start = Data(#"{"bad": {"kind": "ftp"}, "keep": {"host": "k", "kind": "http", "port": 3128}}"#.utf8)
    let set = try ProxyRegistry.setting("work", to: ProxySpec(kind: .socks5, host: "h", port: 1080), in: start)
    let entries = try #require(ProxyRegistry.entries(set))
    #expect(entries["work"] == .proxy(ProxySpec(kind: .socks5, host: "h", port: 1080)))
    #expect(entries["keep"] == .proxy(ProxySpec(kind: .http, host: "k", port: 3128)))
    #expect(entries["bad"] == .unreadable)
    let removed = try #require(ProxyRegistry.entries(try ProxyRegistry.setting("work", to: nil, in: set)))
    #expect(removed["work"] == nil && removed["keep"] != nil)
    #expect(try ProxyRegistry.entries(ProxyRegistry.setting("a", to: ProxySpec(kind: .http, host: "h", port: 1), in: nil))?.count == 1)
}

@Test func anUnreadableFileIsNeverRewritten() {
    #expect(throws: Failure.self) { try ProxyRegistry.setting("work", to: nil, in: Data("{".utf8)) }
}
