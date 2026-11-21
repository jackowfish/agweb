import Foundation

/// profiles/proxies.json: `{"work": {"kind": "socks5", "host": …, "port": …, "username"?: …, "password"?: …}}`. Beside
/// profiles.json, which stays a list of names: a build without proxies reads that list, and one it couldn't read would
/// be rewritten down to the profile being opened and every other profile's data swept.
public enum ProxyRegistry {
    public enum Entry: Equatable, Sendable {
        case proxy(ProxySpec)
        /// Kept by name, so its profile refuses to load rather than load without it.
        case unreadable
    }

    /// Nil when the data isn't a JSON object: then no profile's proxy is known.
    public static func entries(_ data: Data) -> [String: Entry]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object.mapValues { value in
            guard JSONSerialization.isValidJSONObject(value), let json = try? JSONSerialization.data(withJSONObject: value),
                  let spec = try? JSONDecoder().decode(ProxySpec.self, from: json), (try? spec.validate()) != nil else { return .unreadable }
            return .proxy(spec)
        }
    }

    /// The file with one profile's proxy set or removed and every other entry left as it was, unreadable ones too.
    /// Throws when the file can't be read as an object: rewriting it would drop the other profiles' proxies.
    public static func setting(_ name: String, to spec: ProxySpec?, in data: Data?) throws -> Data {
        var object: [String: Any] = [:]
        if let data {
            guard let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(unreadableFile) }
            object = read
        }
        if let spec {
            object[name] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec))
        } else {
            object[name] = nil
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    public static let unreadableFile = "profiles/proxies.json can't be read, so no named profile loads pages; fix it, or remove it to drop every profile's proxy"
}
