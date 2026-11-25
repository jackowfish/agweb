import AgwebCore
import AppKit
import CFido2
import Foundation

/// A libfido2 call that failed: its code, from fido/err.h.
struct KeyFailure: Error {
    let code: Int
    var name: String { SecurityKeyError.name(code) }
    var reason: String { SecurityKeyError.reason(code) }
}

/// The first security key plugged in over USB, open for one ceremony. Its calls block until the key answers, so they
/// run off the main actor; `cancel` comes from the main actor while one waits for the touch.
final class SecurityKey: @unchecked Sendable {
    struct Registration: Sendable {
        let id: [UInt8], authData: [UInt8], format: String, statement: [UInt8], publicKey: [UInt8], algorithm: Int
    }

    struct Assertion: Sendable {
        let id: [UInt8], authData: [UInt8], signature: [UInt8], userHandle: [UInt8]
        /// How many accounts for the site the key offered; agweb answers with the first.
        let count: Int
    }

    private var device: OpaquePointer?
    let hasPIN: Bool
    /// Built-in user verification, such as a fingerprint.
    let hasUV: Bool
    /// COSE algorithms the key reports; a CTAP 2.0 key reports none and does ES256.
    let algorithms: [Int]

    private static let initialized: Void = fido_init(0)

    /// libfido2 is linked weak: without it installed, its functions are missing and no call may run.
    static let available = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fido_dev_new") != nil // RTLD_DEFAULT
    static let missing = "security keys need libfido2, which isn't installed: brew install libfido2, then restart Agweb"

    /// Nil when no key is plugged in.
    static func first(timeout: TimeInterval) throws -> SecurityKey? {
        _ = initialized
        guard let list = fido_dev_info_new(8) else { throw KeyFailure(code: -9) }
        var ownedList: OpaquePointer? = list
        defer { fido_dev_info_free(&ownedList, 8) }
        var found = 0
        let status = fido_dev_info_manifest(list, 8, &found)
        guard status == FIDO_OK else { throw KeyFailure(code: Int(status)) }
        guard found > 0, let info = fido_dev_info_ptr(list, 0), let path = fido_dev_info_path(info) else { return nil }
        guard let device = fido_dev_new() else { throw KeyFailure(code: -9) }
        var owned: OpaquePointer? = device
        let opened = fido_dev_open(device, path)
        guard opened == FIDO_OK else {
            fido_dev_free(&owned)
            throw KeyFailure(code: Int(opened))
        }
        fido_dev_set_timeout(device, Int32(timeout * 1000))
        var algorithms: [Int] = []
        if let info = fido_cbor_info_new() {
            var held: OpaquePointer? = info
            if fido_dev_get_cbor_info(device, info) == FIDO_OK {
                algorithms = (0..<fido_cbor_info_algorithm_count(info)).map { Int(fido_cbor_info_algorithm_cose(info, $0)) }
            }
            fido_cbor_info_free(&held)
        }
        return SecurityKey(device, algorithms: algorithms)
    }

    private init(_ device: OpaquePointer, algorithms: [Int]) {
        self.device = device
        hasPIN = fido_dev_has_pin(device)
        hasUV = fido_dev_has_uv(device)
        self.algorithms = algorithms.isEmpty ? [WebAuthn.es256] : algorithms
    }

    deinit {
        fido_dev_close(device)
        fido_dev_free(&device)
    }

    func cancel() { fido_dev_cancel(device) }

    /// PIN attempts left before the key blocks it; nil when the key won't say.
    func pinRetries() -> Int? {
        var left: Int32 = 0
        return fido_dev_get_retry_count(device, &left) == FIDO_OK ? Int(left) : nil
    }

    private static func check(_ status: Int32) throws {
        guard status == FIDO_OK else { throw KeyFailure(code: Int(status)) }
    }

    private static func bytes(_ pointer: UnsafePointer<UInt8>?, _ count: Int) -> [UInt8] {
        guard let pointer, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    /// `pin`: nil to make the credential without it. `residentKey`: nil leaves the choice to the key.
    func register(clientDataHash: [UInt8], rpID: String, rpName: String, userID: [UInt8], userName: String, displayName: String,
                  algorithm: Int, residentKey: Bool?, uv: Bool, exclude: [[UInt8]], pin: [CChar]?) throws -> Registration {
        guard let cred = fido_cred_new() else { throw KeyFailure(code: -9) }
        var owned: OpaquePointer? = cred
        defer { fido_cred_free(&owned) }
        try Self.check(fido_cred_set_type(cred, Int32(algorithm)))
        try Self.check(fido_cred_set_clientdata_hash(cred, clientDataHash, clientDataHash.count))
        try Self.check(fido_cred_set_rp(cred, rpID, rpName.isEmpty ? nil : rpName))
        try Self.check(fido_cred_set_user(cred, userID, userID.count, userName, displayName.isEmpty ? nil : displayName, nil))
        if let residentKey { try Self.check(fido_cred_set_rk(cred, residentKey ? FIDO_OPT_TRUE : FIDO_OPT_FALSE)) }
        if uv { try Self.check(fido_cred_set_uv(cred, FIDO_OPT_TRUE)) }
        for id in exclude { try Self.check(fido_cred_exclude(cred, id, id.count)) }
        try Self.check(pin.map { pin in pin.withUnsafeBufferPointer { fido_dev_make_cred(device, cred, $0.baseAddress) } } ?? fido_dev_make_cred(device, cred, nil))
        return Registration(
            id: Self.bytes(fido_cred_id_ptr(cred), fido_cred_id_len(cred)),
            authData: Self.bytes(fido_cred_authdata_raw_ptr(cred), fido_cred_authdata_raw_len(cred)),
            format: fido_cred_fmt(cred).map { String(cString: $0) } ?? "none",
            statement: Self.bytes(fido_cred_attstmt_ptr(cred), fido_cred_attstmt_len(cred)),
            publicKey: Self.bytes(fido_cred_pubkey_ptr(cred), fido_cred_pubkey_len(cred)),
            algorithm: Int(fido_cred_type(cred)))
    }

    /// `probe`: ask without a touch whether the key holds one of `allow` for `rpID` (the AppID choice); throws
    /// noCredentials when it doesn't.
    func sign(clientDataHash: [UInt8], rpID: String, allow: [[UInt8]], uv: Bool, pin: [CChar]?, probe: Bool = false) throws -> Assertion {
        guard let assert = fido_assert_new() else { throw KeyFailure(code: -9) }
        var owned: OpaquePointer? = assert
        defer { fido_assert_free(&owned) }
        try Self.check(fido_assert_set_rp(assert, rpID))
        try Self.check(fido_assert_set_clientdata_hash(assert, clientDataHash, clientDataHash.count))
        for id in allow { try Self.check(fido_assert_allow_cred(assert, id, id.count)) }
        if probe { try Self.check(fido_assert_set_up(assert, FIDO_OPT_FALSE)) }
        if uv && !probe { try Self.check(fido_assert_set_uv(assert, FIDO_OPT_TRUE)) }
        try Self.check(pin.map { pin in pin.withUnsafeBufferPointer { fido_dev_get_assert(device, assert, $0.baseAddress) } } ?? fido_dev_get_assert(device, assert, nil))
        let count = fido_assert_count(assert)
        guard count > 0 else { throw KeyFailure(code: SecurityKeyError.noCredentials) }
        return Assertion(
            id: Self.bytes(fido_assert_id_ptr(assert, 0), fido_assert_id_len(assert, 0)),
            authData: Self.bytes(fido_assert_authdata_raw_ptr(assert, 0), fido_assert_authdata_raw_len(assert, 0)),
            signature: Self.bytes(fido_assert_sig_ptr(assert, 0), fido_assert_sig_len(assert, 0)),
            userHandle: Self.bytes(fido_assert_user_id_ptr(assert, 0), fido_assert_user_id_len(assert, 0)),
            count: count)
    }
}

/// The person's part of a security key ceremony, as sheets on the window: the PIN, then "touch your key". Neither
/// activates the app; the PIN goes from the field to libfido2 and nowhere else.
@MainActor
enum KeyPrompt {
    /// The PIN as C characters for libfido2, which the caller zeroes; nil when the person cancels.
    static func pin(on window: NSWindow, title: String, detail: String) async -> [CChar]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "PIN"
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = await withCheckedContinuation { done in alert.beginSheetModal(for: window) { done.resume(returning: $0) } }
        var pin = field.stringValue.utf8CString
        field.stringValue = ""
        guard response == .alertFirstButtonReturn, pin.count > 1 else {
            zero(&pin)
            return nil
        }
        return Array(pin)
    }

    /// Shows the sheet until the returned closure ends it; the sheet's Cancel calls `cancel`.
    static func touch(on window: NSWindow, title: String, detail: String, cancel: @escaping () -> Void) -> () -> Void {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.icon = NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: nil)
        alert.addButton(withTitle: "Cancel")
        var ended = false
        alert.beginSheetModal(for: window) { _ in if !ended { ended = true; cancel() } }
        return {
            guard !ended else { return }
            ended = true
            window.endSheet(alert.window)
        }
    }

    static func zero(_ pin: inout ContiguousArray<CChar>) {
        pin.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    static func zero(_ pin: inout [CChar]) {
        pin.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }
}
