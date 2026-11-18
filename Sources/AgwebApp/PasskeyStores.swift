import AgwebCore
import CryptoKit
import Foundation
import Security

extension PublicSuffixes {
    /// The list bundled with the app; nil when it's missing, and callers then fail closed.
    static let bundled: PublicSuffixes? = {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return PublicSuffixes(list: text)
    }()
}

/// Calls on the login Keychain.
enum Keychain {
    static func check(_ status: OSStatus, _ what: String) throws {
        guard status != errSecSuccess else { return }
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        throw Failure("the Keychain refused to \(what): \(reason)")
    }

    /// Agents' calls never raise the Keychain's dialog: it would pop up over the person's work, and the flag
    /// kSecUseAuthenticationUIFail doesn't stop it for the login keychain (tested); this does, failing at once.
    static func quietly<T>(_ interactive: Bool, _ body: () -> T) -> T {
        if !interactive { SecKeychainSetUserInteractionAllowed(false) }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(true) } }
        return body()
    }

    /// The item exists but the Keychain would have asked the person first.
    static func needsOK(_ status: OSStatus) -> Bool { [errSecAuthFailed, errSecInteractionNotAllowed].contains(status) }
}

/// A passkey agweb holds: what lists it, never the key.
struct Passkey: Codable, Identifiable, Equatable {
    var id: String // the credential id, base64url
    var rpID: String
    var userHandle: String
    var userName: String
    var displayName: String
    /// The named profile it belongs to; nil in a fresh workspace's memory.
    var profile: String?
    var created: Date
    var lastUsed: Date?
    /// Made through the person's own click (the sheet); agents may delete only the others. Shown in lists; decisions read
    /// the protected copy.
    var byPerson: Bool?

    var label: String { "\(rpID) (user \(userName.isEmpty ? displayName : userName))" }
}

/// The item's protected data: the key, and the facts a sign-in trusts, repeated where another process can't rewrite
/// them without the Keychain asking (the listed copy can be).
struct PasskeySecret: Codable, Equatable {
    var key: Data // P-256, PKCS#8 DER
    var rpID: String
    var userHandle: String
    var profile: String?
    /// Nil (an item from before the mark) counts as the person's.
    var byPerson: Bool?

    var agentMade: Bool { byPerson == false }

    func signingKey() throws -> P256.Signing.PrivateKey { try P256.Signing.PrivateKey(derRepresentation: key) }
}

protocol PasskeyStore: Sendable {
    func all() throws -> [Passkey]
    /// `interactive`: may the Keychain ask the person (only after their own OK in the sheet).
    func secret(_ id: String, interactive: Bool) throws -> PasskeySecret
    /// Adds only; an id that exists is refused. `interactive` as for `secret`.
    func add(_ passkey: Passkey, _ secret: PasskeySecret, interactive: Bool) throws
    /// Records a sign-in in the listing; best effort.
    func used(_ passkey: Passkey)
    /// `interactive` as for `secret`: only the person's own delete in Settings.
    func delete(_ id: String, interactive: Bool) throws
}

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    // Full precision: the newest passkey for a site signs in when it names none, so two in one second must not tie.
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
}()

private func noPasskey(_ id: String) -> Failure { Failure("no passkey \(id); agweb passkey list shows them") }

/// The person's instance: the login Keychain, one generic-password item per passkey, so the passkeys move to a new
/// Mac with the Keychain. The listing rides in `kSecAttrGeneric`; the key is the item's data.
struct KeychainPasskeyStore: PasskeyStore {
    let service: String

    private func query(_ id: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let id { query[kSecAttrAccount as String] = id }
        return query
    }

    func all() throws -> [Passkey] {
        var out: AnyObject?
        let status = Keychain.quietly(false) {
            SecItemCopyMatching(query().merging([kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]) { $1 } as CFDictionary, &out)
        }
        if status == errSecItemNotFound { return [] }
        try Keychain.check(status, "list passkeys")
        // The id is the item's account, which is unique; the listing's own id could be anything.
        return (out as? [[String: Any]] ?? []).compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  var passkey = (item[kSecAttrGeneric as String] as? Data).flatMap({ try? decoder.decode(Passkey.self, from: $0) }) else { return nil }
            passkey.id = account
            return passkey
        }
    }

    func secret(_ id: String, interactive: Bool) throws -> PasskeySecret {
        var out: AnyObject?
        let status = Keychain.quietly(interactive) { SecItemCopyMatching(query(id).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &out) }
        if status == errSecItemNotFound { throw noPasskey(id) }
        if !interactive && Keychain.needsOK(status) {
            throw Failure("the login Keychain is locked, or wants the person's OK since Agweb was updated; the person unlocks the Mac, or clicks the site's passkey button once and chooses Always Allow")
        }
        try Keychain.check(status, "read the passkey")
        guard let data = out as? Data, let secret = try? decoder.decode(PasskeySecret.self, from: data) else { throw Failure("the passkey's Keychain item can't be read") }
        return secret
    }

    func add(_ passkey: Passkey, _ secret: PasskeySecret, interactive: Bool) throws {
        let fields: [String: Any] = [kSecAttrGeneric as String: try encoder.encode(passkey), kSecValueData as String: try encoder.encode(secret),
                                     kSecAttrLabel as String: "Agweb passkey: \(passkey.label)", kSecAttrComment as String: passkey.rpID]
        let status = Keychain.quietly(interactive) { SecItemAdd(query(passkey.id).merging(fields) { $1 } as CFDictionary, nil) }
        if !interactive && Keychain.needsOK(status) { throw Failure("the login Keychain is locked; the person unlocks the Mac") }
        try Keychain.check(status, "save the passkey")
    }

    func used(_ passkey: Passkey) {
        guard let listing = try? encoder.encode(passkey) else { return }
        _ = Keychain.quietly(false) { SecItemUpdate(query(passkey.id) as CFDictionary, [kSecAttrGeneric as String: listing] as CFDictionary) }
    }

    func delete(_ id: String, interactive: Bool) throws {
        let status = Keychain.quietly(interactive) { SecItemDelete(query(id) as CFDictionary) }
        if !interactive && Keychain.needsOK(status) { throw Failure("the login Keychain is locked, or wants the person's OK since Agweb was updated") }
        if status == errSecItemNotFound { throw noPasskey(id) }
        try Keychain.check(status, "delete the passkey")
    }
}

/// Any other root (tests, experiments): a 0600 file in it, so a test never touches the login Keychain. Read afresh
/// each time; a file that can't be read is refused, never overwritten.
struct FilePasskeyStore: PasskeyStore {
    let file: URL

    private struct Record: Codable { var passkey: Passkey; var secret: PasskeySecret }

    private func records() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file), let records = try? decoder.decode([Record].self, from: data) else {
            throw Failure("\(file.path) can't be read; agweb leaves it as it is")
        }
        return records
    }

    private func write(_ records: [Record]) throws {
        guard writePrivately(try encoder.encode(records), to: file) else { throw Failure("couldn't write \(file.path)") }
    }

    func all() throws -> [Passkey] { try records().map(\.passkey) }

    func secret(_ id: String, interactive: Bool) throws -> PasskeySecret {
        guard let record = try records().first(where: { $0.passkey.id == id }) else { throw noPasskey(id) }
        return record.secret
    }

    func add(_ passkey: Passkey, _ secret: PasskeySecret, interactive: Bool) throws {
        let all = try records()
        guard !all.contains(where: { $0.passkey.id == passkey.id }) else { throw Failure("passkey \(passkey.id) exists") }
        try write(all + [Record(passkey: passkey, secret: secret)])
    }

    func used(_ passkey: Passkey) {
        guard var all = try? records(), let index = all.firstIndex(where: { $0.passkey.id == passkey.id }) else { return }
        all[index].passkey = passkey
        try? write(all)
    }

    func delete(_ id: String, interactive: Bool) throws {
        let all = try records()
        guard all.contains(where: { $0.passkey.id == id }) else { throw noPasskey(id) }
        try write(all.filter { $0.passkey.id != id })
    }
}

/// A fresh workspace's passkeys, gone with it.
/// Used on the main actor only.
final class MemoryPasskeyStore: PasskeyStore, @unchecked Sendable {
    private var records: [(passkey: Passkey, secret: PasskeySecret)] = []

    func all() -> [Passkey] { records.map(\.passkey) }

    func secret(_ id: String, interactive: Bool) throws -> PasskeySecret {
        guard let record = records.first(where: { $0.passkey.id == id }) else { throw noPasskey(id) }
        return record.secret
    }

    func add(_ passkey: Passkey, _ secret: PasskeySecret, interactive: Bool) throws {
        guard !records.contains(where: { $0.passkey.id == passkey.id }) else { throw Failure("passkey \(passkey.id) exists") }
        records.append((passkey, secret))
    }

    func used(_ passkey: Passkey) {
        if let index = records.firstIndex(where: { $0.passkey.id == passkey.id }) { records[index].passkey = passkey }
    }

    func delete(_ id: String, interactive: Bool) throws {
        guard records.contains(where: { $0.passkey.id == id }) else { throw noPasskey(id) }
        records.removeAll { $0.passkey.id == id }
    }
}
