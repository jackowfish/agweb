import Foundation

/// `emulate --device iphone`: an iPhone's viewport and user agent on macOS WebKit, for checking a site's phone layout.
/// Touch, `(hover: none)`, `(pointer: coarse)`, devicePixelRatio and `screen.*` stay the Mac's.
public enum Phone {
    /// An iPhone 15's CSS viewport in Safari, as Playwright's descriptor has it.
    public static let viewport = (width: 390, height: 844)
    public static let platform = "iPhone"

    /// iPhone Safari's user agent with the Mac Safari version in `desktop`. iOS 26 Safari reports the OS as 18_6 for every
    /// release, like macOS's frozen 10_15_7.
    public static func userAgent(desktop: String) -> String {
        let version = desktop.range(of: #"Version/[0-9.]+"#, options: .regularExpression).map { String(desktop[$0]) } ?? "Version/26.0"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) \(version) Mobile/15E148 Safari/604.1"
    }
}
