import Foundation
import Testing
@testable import AgwebCore

@Test func proxySchemesParse() throws {
    #expect(try ProxySpec.parse("socks5://10.0.0.5:1080") == ProxySpec(kind: .socks5, host: "10.0.0.5", port: 1080))
    #expect(try ProxySpec.parse("socks5h://proxy.lan:1080").kind == .socks5)
    #expect(try ProxySpec.parse("http://proxy.lan:3128/") == ProxySpec(kind: .http, host: "proxy.lan", port: 3128))
    #expect(try ProxySpec.parse("HTTPS://Proxy.example.com:443").kind == .https)
}

@Test func proxyCredentialsAndIPv6() throws {
    let spec = try ProxySpec.parse("https://pa%40ul:s3%3Acret@[::1]:8443")
    #expect(spec == ProxySpec(kind: .https, host: "::1", port: 8443, username: "pa@ul", password: "s3:cret"))
    #expect(spec.description == "https://pa%40ul@[::1]:8443")
    #expect(try ProxySpec.parse(spec.description) == ProxySpec(kind: .https, host: "::1", port: 8443, username: "pa@ul"))
    #expect(try ProxySpec.parse("socks5://paul@h:1").username == "paul")
    #expect(throws: Failure.self) { try ProxySpec.parse("socks5://paul@h:1").validate() }
}

@Test(arguments: ["ftp://h:21", "socks4://h:1080", "http://h", "http://h:0", "http://h:70000", "http://h:80/path", "http://h:80?a=1",
                  "http://:80", "h:80", "http://:pw@h:80", "http://u:@h:80", "not a url"])
func badProxiesAreRefused(text: String) {
    #expect(throws: Failure.self) { try ProxySpec.parse(text) }
}

@Test func proxyErrorsAndDescriptionsNeverShowThePassword() {
    let secret = "hunter2secret"
    for text in ["ftp://u:\(secret)@h:1", "http://u:\(secret)@h", "http://u:\(secret)@h:1/x", "http://u:\(secret)@h:99999"] {
        do { _ = try ProxySpec.parse(text); Issue.record("accepted \(text)") } catch { #expect(!"\(error)".contains(secret)) }
    }
    #expect(!(try! ProxySpec.parse("socks5://u:\(secret)@h:1")).description.contains(secret))
}

@Test func socksCredentialsFitTheirFields() {
    #expect(throws: Failure.self) { try ProxySpec(kind: .socks5, host: "h", port: 1, username: String(repeating: "u", count: 256), password: "p").validate() }
    #expect(throws: Never.self) { try ProxySpec(kind: .http, host: "h", port: 1, username: String(repeating: "u", count: 256), password: "p").validate() }
}
