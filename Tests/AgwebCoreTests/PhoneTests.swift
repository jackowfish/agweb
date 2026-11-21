import Testing
@testable import AgwebCore

@Test func phoneUserAgentKeepsTheSafariVersion() {
    let mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Safari/605.1.15"
    #expect(Phone.userAgent(desktop: mac)
        == "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1")
    #expect(Phone.userAgent(desktop: "").contains("Version/26.0 Mobile/"))
}
