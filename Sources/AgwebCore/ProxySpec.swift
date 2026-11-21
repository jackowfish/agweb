import Foundation

/// A named profile's proxy: `socks5://` (names resolved by the proxy; `socks5h://` is the same), `http://` (a CONNECT
/// proxy) or `https://` (TLS to the proxy, then CONNECT), always with a port, optionally `user[:password]@`.
public struct ProxySpec: Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable { case socks5, http, https }
    public var kind: Kind
    /// IPv6 without brackets.
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?

    public init(kind: Kind, host: String, port: Int, username: String? = nil, password: String? = nil) {
        (self.kind, self.host, self.port, self.username, self.password) = (kind, host, port, username, password)
    }

    /// Errors never repeat the text: it may hold a password.
    public static func parse(_ text: String) throws -> ProxySpec {
        guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased() else {
            throw Failure("the proxy must look like socks5://host:port, http://host:port or https://host:port")
        }
        guard let kind = scheme == "socks5h" ? .socks5 : Kind(rawValue: scheme) else {
            throw Failure("proxy scheme \(scheme) isn't supported; use socks5, http or https")
        }
        guard let host = url.host, !host.isEmpty else { throw Failure("the proxy has no host") }
        guard let port = url.port else { throw Failure("the proxy needs a port, like \(kind)://\(host):\(kind == .socks5 ? 1080 : 8080)") }
        guard url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else {
            throw Failure("a proxy is only scheme://[user[:password]@]host:port, with no path or query")
        }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let spec = ProxySpec(kind: kind, host: bare, port: port, username: url.user, password: url.password)
        try spec.validate(complete: false)
        return spec
    }

    /// Also run on what profiles/proxies.json holds. Not `complete`: the password may still come from --secret-cmd.
    public func validate(complete: Bool = true) throws {
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || "/@[]".contains($0) }) else {
            throw Failure("the proxy's host isn't valid")
        }
        guard (1...65535).contains(port) else { throw Failure("the proxy's port must be 1 to 65535") }
        if username == "" { throw Failure("the proxy's username is empty") }
        if password != nil, username == nil { throw Failure("a proxy password needs a username: \(kind)://user@\(hostPort)") }
        if password == "" { throw Failure("the proxy's password is empty") }
        if complete, username != nil, password == nil {
            throw Failure("a proxy username needs a password: inline, or --secret-cmd/--secret-file to keep it out of your transcript")
        }
        // SOCKS5's username/password exchange carries each in at most 255 bytes.
        if kind == .socks5, (username?.utf8.count ?? 0) > 255 || (password?.utf8.count ?? 0) > 255 {
            throw Failure("a SOCKS5 username or password is at most 255 bytes")
        }
    }

    var hostPort: String { (host.contains(":") ? "[\(host)]" : host) + ":\(port)" }

    /// The proxy as a URL without its password, percent-encoding the username: what replies, lists and logs show.
    public var description: String {
        let user = username.map { ($0.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? $0) + "@" } ?? ""
        return "\(kind)://\(user)\(hostPort)"
    }
}
