import AgwebCore
import AppKit
import CryptoKit
import Foundation
import WebKit

/// One passkey as Settings lists it: under its profile, or a fresh workspace's (in memory).
struct PasskeyEntry: Identifiable {
    let passkey: Passkey
    /// "profile NAME" or "workspace NAME, in memory": the Settings section it's in.
    let group: String
    let delete: () throws -> Void
    var id: String { passkey.id }
}

/// Where a workspace's passkeys live: its named profile's file, or the fresh workspace itself.
enum PasskeyOwner {
    case profile(String)
    case workspace(Workspace)

    init(_ workspace: Workspace) { self = workspace.profile.map { .profile($0) } ?? .workspace(workspace) }
}

/// agweb as a passkey authenticator for its pages. A ceremony is answered only
/// for the agent's own tab during its command and for 10 s after, or right after the person's own click or key in
/// it; the origin comes from WebKit, never from the page.
@MainActor @Observable
final class Passkeys: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = Passkeys()
    static let handlerName = "agwebPasskey"
    /// How long after an agent command or the person's input a tab may still use passkeys: a site's button often
    /// fetches its options from the server first.
    static let grace = ProcessInfo.processInfo.environment["AGWEB_PASSKEY_SECONDS"].flatMap(TimeInterval.init) ?? 10
    static let perSite = 20

    @ObservationIgnored weak var browser: Browser?
    /// Bumped on every change, for Settings to redraw.
    private(set) var revision = 0
    /// Commands whose page may use passkeys while they run and for `grace` after: the ones acting on it, not
    /// `console` or `list` polling.
    static let commands: Set = ["open", "goto", "reload", "click", "dblclick", "check", "uncheck", "fill", "select", "type", "press",
                                "keydown", "keyup", "mousedown", "mouseup", "eval", "wait"]

    var enabled: Bool { Settings.store.bool(forKey: Settings.passkeys) }

    // MARK: Store

    /// Named profiles' passkeys: the login Keychain for the person's instance, a 0600 file in any other root
    /// (AGWEB_PASSKEY_STORE=keychain tries the Keychain there).
    @ObservationIgnored let store: PasskeyStore = Agweb.isDefaultRoot
        // Only a test build (its own bundle id, so its own Keychain items): another root of the person's build would share theirs.
        || (Agweb.isTestBuild(Agweb.bundleIdentifier) && ProcessInfo.processInfo.environment["AGWEB_PASSKEY_STORE"] == "keychain")
        ? KeychainPasskeyStore(service: Agweb.bundleIdentifier + ".passkey")
        : FilePasskeyStore(file: Agweb.root.appendingPathComponent("passkeys.json"))

    private func store(_ owner: PasskeyOwner) -> PasskeyStore {
        if case .workspace(let workspace) = owner { return workspace.passkeys }
        return store
    }

    /// What Settings and `agweb passkey list` show; an unreadable store shows as none.
    func list(_ owner: PasskeyOwner) -> [Passkey] { (try? stored(owner)) ?? [] }

    /// Read afresh each time: another instance on the root, or the person in Settings, may have changed it.
    private func stored(_ owner: PasskeyOwner) throws -> [Passkey] {
        do {
            switch owner {
            case .workspace(let workspace): return workspace.passkeys.all()
            case .profile(let name): return try store.all().filter { ($0.profile ?? "") == name }
            }
        } catch { throw Refusal("NotAllowedError", "\(error)") }
    }

    /// Whether an agent made it, by the protected copy; unreadable or unmarked counts as the person's. `telling`: a locked
    /// Keychain throws its own reason instead.
    private func agentMade(_ passkey: Passkey, _ store: PasskeyStore, telling: Bool = false) throws -> Bool {
        do { return try store.secret(passkey.id, interactive: false).agentMade } catch let failure as Failure where telling && failure.description.contains("Keychain is locked") {
            throw failure
        } catch { return false }
    }

    /// What `profile delete` must not take with it: the passkeys the person made there.
    func personMade(profile name: String) throws -> [String] {
        try store.all().filter { $0.profile == name && !((try? agentMade($0, store)) ?? false) }.map { "the passkey for \($0.label)" }
    }

    /// A deleted profile's passkeys go with it, or the profile stays: one made later with that name would get them.
    func forget(profile name: String) throws {
        defer { revision += 1 }
        setUsesKey(false, .profile(name))
        for passkey in try store.all() where passkey.profile == name { try? store.delete(passkey.id, interactive: false) }
        let left = try store.all().filter { $0.profile == name }.count
        if left > 0 { throw Failure("\(left) of profile \(name)'s passkeys couldn't be deleted from the Keychain, so the profile stays; try again, or delete them in Settings ▸ Passkeys") }
    }

    /// Every passkey Settings shows: named profiles' and fresh workspaces' (in memory).
    func entries() -> [PasskeyEntry] {
        var entries: [PasskeyEntry] = []
        for passkey in (try? store.all()) ?? [] {
            let owner = PasskeyOwner.profile(passkey.profile ?? "")
            entries.append(PasskeyEntry(passkey: passkey, group: "profile \(passkey.profile ?? "?")") { [weak self] in try self?.delete(passkey.id, owner) })
        }
        for workspace in browser?.model.workspaces ?? [] where workspace.profile == nil {
            for passkey in workspace.passkeys.all() {
                entries.append(PasskeyEntry(passkey: passkey, group: "workspace \(workspace.name), in memory") { [weak self] in
                    try self?.delete(passkey.id, .workspace(workspace))
                })
            }
        }
        return entries.sorted { ($0.passkey.rpID, $0.passkey.created) < ($1.passkey.rpID, $1.passkey.created) }
    }

    /// The shim is a user script: pages get it, or lose it, from their next load.
    func settingChanged() {
        for workspace in browser?.model.workspaces ?? [] { workspace.installScripts() }
    }

    /// Settings: the person's delete, after the owner check; the Keychain may ask them.
    func delete(_ id: String, _ owner: PasskeyOwner) throws {
        guard list(owner).contains(where: { $0.id == id }) else { return }
        try store(owner).delete(id, interactive: true)
        revision += 1
    }

    /// `passkey delete`: an agent deletes only a passkey an agent made.
    func agentDelete(_ id: String, _ owner: PasskeyOwner) throws -> Passkey {
        guard let passkey = list(owner).first(where: { $0.id == id }) else { throw Failure("no passkey \(id) in this workspace's profile; agweb passkey list shows them") }
        guard try agentMade(passkey, store(owner), telling: true) else { throw Failure("the passkey for \(passkey.label) is the person's; they delete it in Settings ▸ Passkeys") }
        try store(owner).delete(id, interactive: false)
        revision += 1
        return passkey
    }

    // MARK: Security key

    /// Whether the owner's sign-ups and sign-ins go to a security key plugged into the Mac instead of agweb's passkeys.
    func usesKey(_ owner: PasskeyOwner) -> Bool {
        if Settings.store.bool(forKey: Settings.securityKeyAll) { return true }
        return switch owner {
        case .workspace(let workspace): workspace.securityKey
        case .profile(let name): (Settings.store.stringArray(forKey: Settings.securityKeyProfiles) ?? []).contains(name)
        }
    }

    func setUsesKey(_ on: Bool, _ owner: PasskeyOwner) {
        switch owner {
        case .workspace(let workspace): workspace.securityKey = on
        case .profile(let name):
            let names = (Settings.store.stringArray(forKey: Settings.securityKeyProfiles) ?? []).filter { $0 != name } + (on ? [name] : [])
            Settings.store.set(names.sorted(), forKey: Settings.securityKeyProfiles)
        }
        revision += 1
    }

    /// The one ceremony the key serves, and its tab, whose page may cancel it.
    private final class KeyUse {
        let tab: Tab
        var key: SecurityKey?
        var cancelled = false
        init(_ tab: Tab) { self.tab = tab }
    }

    @ObservationIgnored private var keyInUse: KeyUse?

    /// Runs `body` on the first key plugged in, off the main actor, after the PIN when the site wants user verification.
    /// The person sees each step as a sheet; a wrong PIN asks again.
    private func withKey<T: Sendable>(_ tab: Tab, rpID: String, doing: String, userVerification: String, timeout: TimeInterval, noKey: String,
                                      _ body: @escaping @Sendable (SecurityKey, [CChar]?, _ builtInUV: Bool) throws -> T) async throws -> T {
        guard keyInUse == nil else { throw Refusal("NotAllowedError", "the security key is busy with another request") }
        guard let window = browser?.mainWindow.window, window.isVisible, !window.isMiniaturized else {
            throw Refusal("NotAllowedError", "the security key needs the person, and Agweb's window is closed or minimized")
        }
        let use = KeyUse(tab)
        keyInUse = use
        defer { keyInUse = nil }
        let cancelled = Refusal("NotAllowedError", "the page cancelled the request", quiet: true)
        let found: SecurityKey?
        do { found = try await Task.detached { try SecurityKey.first(timeout: timeout) }.value } catch let failure as KeyFailure {
            throw Refusal(failure.name, failure.reason)
        }
        guard let key = found else { throw Refusal("NotAllowedError", noKey) }
        guard !use.cancelled else { throw cancelled }
        use.key = key
        // As Chrome does: "preferred" verifies when the key can, with its built-in sensor before its PIN.
        let verify = userVerification == "required" || (userVerification != "discouraged" && (key.hasPIN || key.hasUV))
        if userVerification == "required" && !key.hasPIN && !key.hasUV { throw Refusal("NotAllowedError", SecurityKeyError.reason(0x35)) }
        var usePIN = verify && !key.hasUV, wrongPIN = false
        // Worded as Safari's and Chrome's security key prompts; the workspace line says which agent asked.
        let asker = "\n\nRequested in workspace “\(tab.workspace.name)”."
        while true {
            var pin: [CChar]?
            defer { if pin != nil { KeyPrompt.zero(&pin!) } }
            if usePIN {
                guard window.attachedSheet == nil else { throw Refusal("NotAllowedError", "another question is open in the window") }
                tab.events.append("security key: waiting for the person to enter its PIN in Agweb's window")
                let left = wrongPIN ? key.pinRetries() : nil
                let detail = wrongPIN ? "Incorrect PIN." + (left.map { " \($0) \($0 == 1 ? "attempt" : "attempts") remaining." } ?? "")
                    : "Enter your security key PIN to \(doing) “\(rpID)”."
                pin = await KeyPrompt.pin(on: window, title: "Enter your security key PIN", detail: detail + asker)
                guard pin != nil else { throw Refusal("NotAllowedError", "the person cancelled") }
                guard !use.cancelled else { throw cancelled }
            }
            guard window.attachedSheet == nil else { throw Refusal("NotAllowedError", "another question is open in the window") }
            tab.events.append("security key: waiting for the person to touch it")
            let end = KeyPrompt.touch(on: window, title: "Use your security key with “\(rpID)”",
                                      detail: "Insert your security key and touch it." + asker) { key.cancel() }
            let result = await Task.detached { [pin, verify, key] in Result { try body(key, pin, verify && key.hasUV) } }.value
            end()
            switch result {
            case .success(let value): return value
            case .failure(let failure as KeyFailure) where failure.code == SecurityKeyError.pinInvalid:
                wrongPIN = true
            case .failure(let failure as KeyFailure) where failure.code == SecurityKeyError.pinRequired && !usePIN && key.hasPIN:
                usePIN = true
            case .failure(let failure as KeyFailure) where use.cancelled && failure.code == 0x2d: throw cancelled
            case .failure(let failure as KeyFailure): throw Refusal(failure.name, failure.reason)
            case .failure(let error): throw error
            }
        }
    }

    /// The page aborted its request: a key waiting for the touch stops.
    private func cancelKey(for tab: Tab?) {
        guard let tab, let use = keyInUse, use.tab === tab else { return }
        use.cancelled = true
        use.key?.cancel()
    }

    private static func timeout(_ options: [String: Any]) -> TimeInterval {
        min(max((options["timeout"] as? Double).map { $0 / 1000 } ?? 120, 30), 300)
    }

    private func keyCreate(_ options: [String: Any], challenge: [UInt8], origin: String, host: String, tab: Tab, credProps: Bool) throws -> Prepared {
        let rpID = try rpID(options, key: "rp", host: host)
        let rpName = Self.clean((options["rp"] as? [String: Any])?["name"] as? String)
        let user = options["user"] as? [String: Any] ?? [:]
        guard let handle = (user["id"] as? String).flatMap(WebAuthn.fromBase64url), (1...64).contains(handle.count) else {
            throw Refusal("TypeError", "user.id must be 1 to 64 bytes")
        }
        let userName = Self.clean(user["name"] as? String), displayName = Self.clean(user["displayName"] as? String)
        let params = (options["pubKeyCredParams"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String ?? "public-key") == "public-key" }
        let wanted = params.isEmpty ? [WebAuthn.es256] : params.compactMap { $0["alg"] as? Int }
        let selection = options["authenticatorSelection"] as? [String: Any] ?? [:]
        let residentKey = selection["residentKey"] as? String ?? (selection["requireResidentKey"] as? Bool == true ? "required" : "discouraged")
        let exclude = (options["excludeCredentials"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).flatMap(WebAuthn.fromBase64url) }
        let clientData = WebAuthn.clientDataJSON(type: "webauthn.create", challenge: challenge, origin: origin, crossOrigin: false)
        let hash = [UInt8](SHA256.hash(data: Data(clientData)))
        let noKey = "the profile uses a security key (agweb passkey hardware), and none is plugged in"
        return Prepared(title: "", detail: "", button: "", key: true) { [self] _ in
            let (made, discoverable) = try await withKey(tab, rpID: rpID, doing: "create a passkey for", userVerification: selection["userVerification"] as? String ?? "preferred",
                                                         timeout: Self.timeout(options), noKey: noKey) { key, pin, builtInUV in
                guard let algorithm = wanted.first(where: { [WebAuthn.es256, WebAuthn.eddsa].contains($0) && key.algorithms.contains($0) }) else {
                    throw KeyFailure(code: 0x26)
                }
                let rk: Bool? = residentKey == "required" ? true : residentKey == "preferred" && (pin != nil || builtInUV) ? true : nil
                let made = try key.register(clientDataHash: hash, rpID: rpID, rpName: rpName, userID: handle, userName: userName, displayName: displayName,
                                            algorithm: algorithm, residentKey: rk, uv: builtInUV, exclude: exclude, pin: pin)
                return (made, rk == true)
            }
            tab.events.append("passkey created on the security key for \(rpID) (user \(userName.isEmpty ? displayName : userName))")
            var reply: [String: Any] = [
                "id": WebAuthn.base64url(made.id), "clientDataJSON": WebAuthn.base64url(clientData),
                "attestationObject": WebAuthn.base64url(WebAuthn.attestationObject(format: made.format, statement: made.statement, authenticatorData: made.authData)),
                "authenticatorData": WebAuthn.base64url(made.authData), "algorithm": made.algorithm, "transports": ["usb"], "attachment": "cross-platform",
                "credProps": credProps, "rk": discoverable,
            ]
            if let info = WebAuthn.publicKeyInfo(algorithm: made.algorithm, raw: made.publicKey) { reply["publicKey"] = WebAuthn.base64url(info) }
            return reply
        }
    }

    private func keyGet(_ options: [String: Any], challenge: [UInt8], origin: String, rpID: String, host: String, tab: Tab, noKey: String) throws -> Prepared {
        let allow = (options["allowCredentials"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).flatMap(WebAuthn.fromBase64url) }
        let appID = (options["extensions"] as? [String: Any])?["appid"] as? String
        if let appID, !(PublicSuffixes.bundled.map { WebAuthn.appIDAllowed(appID, host: host, suffixes: $0) } ?? false) {
            throw Refusal("SecurityError", "\(host) can't use the AppID \(Self.clean(appID))")
        }
        let clientData = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: challenge, origin: origin, crossOrigin: false)
        let hash = [UInt8](SHA256.hash(data: Data(clientData)))
        return Prepared(title: "", detail: "", button: "", key: true) { [self] _ in
            let (signed, viaAppID) = try await withKey(tab, rpID: rpID, doing: "sign in to", userVerification: options["userVerification"] as? String ?? "preferred",
                                                       timeout: Self.timeout(options), noKey: noKey) { key, pin, builtInUV in
                // A key registered through U2F answers for the AppID, not the rp id; a silent probe tells which.
                var rp = rpID
                if let appID, !allow.isEmpty {
                    do { _ = try key.sign(clientDataHash: hash, rpID: rpID, allow: allow, uv: false, pin: nil, probe: true) } catch let failure as KeyFailure
                        where failure.code == SecurityKeyError.noCredentials { rp = appID } catch {}
                }
                return (try key.sign(clientDataHash: hash, rpID: rp, allow: allow, uv: builtInUV, pin: pin), rp != rpID)
            }
            tab.events.append("signed in to \(rpID) with the security key"
                + (signed.count > 1 ? " (it holds \(signed.count) accounts for the site; agweb used the first)" : ""))
            var reply: [String: Any] = ["id": WebAuthn.base64url(signed.id), "clientDataJSON": WebAuthn.base64url(clientData),
                                        "authenticatorData": WebAuthn.base64url(signed.authData), "signature": WebAuthn.base64url(signed.signature),
                                        "attachment": "cross-platform"]
            if !signed.userHandle.isEmpty { reply["userHandle"] = WebAuthn.base64url(signed.userHandle) }
            if appID != nil { reply["extensions"] = ["appid": viaAppID] }
            return reply
        }
    }

    // MARK: Ceremonies

    /// `quiet`: the page gets the error, the agent's Events don't, for a request nobody made (a page's own timer).
    private struct Refusal: Error {
        let name: String, message: String, quiet: Bool
        init(_ name: String, _ message: String, quiet: Bool = false) { (self.name, self.message, self.quiet) = (name, message, quiet) }
    }

    /// What a ceremony would do, checked; `commit` does it. The person's own click asks them first.
    private struct Prepared {
        let title: String, detail: String, button: String
        /// A security key's ceremony: the person's touch is their OK, so no sheet asks first.
        var key = false
        /// `byPerson`: the person said yes in the sheet, so the Keychain may ask them too.
        let commit: (_ byPerson: Bool) async throws -> [String: Any]
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let tab = browser?.tab(for: message.webView)
        if (message.body as? [String: Any])?["kind"] as? String == "cancel" {
            cancelKey(for: tab)
            return replyHandler(nil, nil)
        }
        func refuse(_ refusal: Refusal) {
            if !refusal.quiet { tab?.events.append("passkey request refused: \(refusal.message)") }
            replyHandler(["error": ["name": refusal.name, "message": refusal.message]], nil)
        }
        func run(_ prepared: Prepared, byPerson: Bool) {
            Task { @MainActor in
                do {
                    let reply = try await prepared.commit(byPerson)
                    tab?.passkeyAt = Date()
                    replyHandler(["credential": reply], nil)
                } catch let refusal as Refusal { refuse(refusal) } catch { refuse(Refusal("NotAllowedError", "\(error)")) }
            }
        }
        do {
            guard let tab else { throw Refusal("NotAllowedError", "agweb doesn't know this page") }
            let (prepared, byPerson) = try prepare(message, tab)
            guard byPerson && !prepared.key else { return run(prepared, byPerson: byPerson) }
            // An agent's request needs no prompt; the person sees what agweb's passkey is before it's made or used.
            guard let window = browser?.mainWindow.window, window.isVisible, window.attachedSheet == nil else {
                throw Refusal("NotAllowedError", "another question is open in the window")
            }
            tab.events.append("the person was asked to confirm a passkey request (their own click in the tab)")
            let alert = NSAlert()
            alert.messageText = prepared.title
            alert.informativeText = prepared.detail
            // No default button: a page that asks while the person types must not get a passkey from their Return key,
            // and the button wakes only after a moment, so a double-click the page invited can't land on it.
            let confirm = alert.addButton(withTitle: prepared.button)
            confirm.keyEquivalent = ""
            confirm.isEnabled = false
            alert.addButton(withTitle: "Cancel")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { confirm.isEnabled = true }
            let commits = tab.commits
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return refuse(Refusal("NotAllowedError", "the person cancelled")) }
                // The page that asked is gone: a passkey it never receives would only shadow the account's real one.
                guard self?.browser?.tab(for: tab.webView) === tab, tab.commits == commits else {
                    return refuse(Refusal("NotAllowedError", "the page changed while the question was open", quiet: true))
                }
                run(prepared, byPerson: true)
            }
        } catch let refusal as Refusal { refuse(refusal) } catch { refuse(Refusal("NotAllowedError", "\(error)")) }
    }

    /// The checks, and whether the person (not an agent) asked: their click in the tab, no agent command on it.
    private func prepare(_ message: WKScriptMessage, _ tab: Tab) throws -> (Prepared, byPerson: Bool) {
        // First, and quiet: a page asking by itself (a timer, an ad frame) must not fill the agent's Events.
        let now = Date()
        let workspace = tab.workspace
        let personClicked = now.timeIntervalSince(tab.passkeyInputAt) < Self.grace
        // During `ask` the tab is the person's: their click there asks them. So is a click of theirs after the agent's
        // last command began, even inside the agent's window: it gets the sheet and the passkey is theirs.
        let byAgent = tab.asking == nil
            && ((workspace.busy && workspace.passkeyCommand && workspace.current === tab) || now < tab.agentUntil)
            && !(personClicked && tab.passkeyInputAt > workspace.lastCommandAt ?? .distantPast)
        guard byAgent || personClicked else {
            throw Refusal("NotAllowedError", "passkeys answer only during an agent's command on this tab or right after the person's own click in it", quiet: true)
        }
        guard enabled else { throw Refusal("NotAllowedError", "passkeys are off in Agweb's Settings") }
        let origin = message.frameInfo.securityOrigin
        let scheme = origin.protocol.lowercased(), host = origin.host.lowercased()
        guard !scheme.isEmpty, !host.isEmpty else { throw Refusal("NotAllowedError", "a sandboxed or data: frame can't use passkeys") }
        guard WebAuthn.isSecure(scheme: scheme, host: host) else { throw Refusal("SecurityError", "passkeys need https") }
        let originText = WebAuthn.origin(scheme: scheme, host: host, port: origin.port)
        // Native code can't read a frame's Permissions Policy, and anything the page reports could be forged.
        if !message.frameInfo.isMainFrame && !tab.isTop(originText) {
            throw Refusal("NotAllowedError", "a frame from another site can't use agweb's passkeys")
        }
        // Mid-navigation the tab's URL may already be the next page's, which a frame of that site would match.
        if !message.frameInfo.isMainFrame && tab.webView.isLoading {
            throw Refusal("NotAllowedError", "a frame can't use passkeys while the page loads; try again once it has")
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let options = body["publicKey"] as? [String: Any] else { throw Refusal("TypeError", "malformed passkey request") }
        guard let challenge = (options["challenge"] as? String).flatMap(WebAuthn.fromBase64url), !challenge.isEmpty else {
            throw Refusal("TypeError", "the request has no challenge")
        }
        let owner = PasskeyOwner(tab.workspace)
        if kind == "create" && usesKey(owner) {
            return (try keyCreate(options, challenge: challenge, origin: originText, host: host, tab: tab, credProps: body["credProps"] as? Bool ?? false), !byAgent)
        }
        if kind == "get" {
            let rpID = try rpID(options, key: nil, host: host)
            let allowed = Set((options["allowCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            // A site that names only credentials agweb doesn't hold wants another authenticator: the key, if one is plugged in.
            let held = try stored(owner)
            let foreign = !allowed.isEmpty && !held.contains { $0.rpID == rpID && allowed.contains($0.id) }
            if usesKey(owner) || foreign {
                let noKey = usesKey(owner) ? "the profile uses a security key (agweb passkey hardware), and none is plugged in"
                    : "no agweb passkey for \(rpID) is among those the site accepts, and no security key is plugged in"
                return (try keyGet(options, challenge: challenge, origin: originText, rpID: rpID, host: host, tab: tab, noKey: noKey), !byAgent)
            }
        }
        switch kind {
        case "create": return (try create(options, challenge: challenge, origin: originText, host: host, owner: owner, tab: tab, credProps: body["credProps"] as? Bool ?? false), !byAgent)
        case "get": return (try get(options, challenge: challenge, origin: originText, host: host, owner: owner, tab: tab), !byAgent)
        default: throw Refusal("TypeError", "unknown passkey request \(Self.clean(kind))")
        }
    }

    private func rpID(_ options: [String: Any], key: String?, host: String) throws -> String {
        let rpID = (key.map { (options[$0] as? [String: Any])?["id"] } ?? options["rpId"]) as? String ?? host
        let allowed = PublicSuffixes.bundled.map { WebAuthn.rpIDAllowed(rpID, host: host, suffixes: $0) } ?? (rpID.lowercased() == host)
        guard allowed else { throw Refusal("SecurityError", "\(host) can't use passkeys for \(Self.clean(rpID))") }
        return rpID.lowercased()
    }

    private func place(_ workspace: Workspace) -> String {
        let keychain = store is KeychainPasskeyStore ? "in your login Keychain" : "in this instance's passkeys file"
        return workspace.profile.map { "\(keychain), for profile \($0)" } ?? "in this workspace's memory only (gone when the workspace closes or Agweb quits)"
    }

    /// The Keychain may ask the person only after their own OK, and then off the main thread: the whole app (every
    /// agent's command) would wait on its dialog.
    private func keychainCall<T>(_ owner: PasskeyOwner, byPerson: Bool, _ body: @escaping @Sendable (PasskeyStore, Bool) throws -> T) async throws -> T {
        let store = store(owner)
        if byPerson, let keychain = store as? KeychainPasskeyStore {
            return try await Task.detached { try body(keychain, true) }.value
        }
        return try body(store, false)
    }

    private func create(_ options: [String: Any], challenge: [UInt8], origin: String, host: String, owner: PasskeyOwner, tab: Tab, credProps: Bool) throws -> Prepared {
        let rpID = try rpID(options, key: "rp", host: host)
        let user = options["user"] as? [String: Any] ?? [:]
        guard let handle = (user["id"] as? String).flatMap(WebAuthn.fromBase64url), (1...64).contains(handle.count) else {
            throw Refusal("TypeError", "user.id must be 1 to 64 bytes")
        }
        let params = options["pubKeyCredParams"] as? [[String: Any]] ?? []
        guard params.isEmpty || params.contains(where: { $0["alg"] as? Int == WebAuthn.es256 && ($0["type"] as? String ?? "public-key") == "public-key" }) else {
            throw Refusal("NotSupportedError", "agweb's passkeys are ES256 (-7) only")
        }
        if (options["authenticatorSelection"] as? [String: Any])?["authenticatorAttachment"] as? String == "cross-platform" {
            throw Refusal("NotAllowedError", "the site asked for a security key; agweb passkey hardware on uses one plugged into this Mac")
        }
        let handleText = WebAuthn.base64url(handle)
        let excluded = Set((options["excludeCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        // Signing up again with the same account replaces its passkey, as other authenticators do.
        func replaced() throws -> [Passkey] {
            let list = try stored(owner).filter { $0.rpID == rpID }
            if list.contains(where: { excluded.contains($0.id) }) {
                throw Refusal("InvalidStateError", "this profile already has a passkey for that account on \(rpID)")
            }
            let same = list.filter { $0.userHandle == handleText }
            guard list.count - same.count < Self.perSite else {
                throw Refusal("NotAllowedError", "this profile already holds \(Self.perSite) passkeys for \(rpID); delete some with agweb passkey delete")
            }
            return same
        }
        let replacing = try !replaced().isEmpty
        let userName = Self.clean(user["name"] as? String), displayName = Self.clean(user["displayName"] as? String)
        let shown = userName.isEmpty ? displayName : userName
        return Prepared(
            title: "Create a passkey for \(rpID)?",
            detail: "Agweb keeps this passkey for \(shown.isEmpty ? "your account" : shown) \(place(tab.workspace)). "
                + "Agents working there can sign in with it too. It isn't saved to Apple Passwords or 1Password; Settings ▸ Passkeys lists it."
                + (replacing ? " It replaces the passkey Agweb has for this account, which then no longer signs in." : ""),
            button: "Create Passkey"
        ) { [self] byPerson in
            let old = try replaced()
            // The person may replace even when the Keychain wants their OK to read the old one; the add then asks.
            let replacesPersons = try old.contains { try !agentMade($0, store(owner), telling: !byPerson) }
            // An agent deletes only what an agent made, and replacing is deleting.
            if replacesPersons && !byPerson {
                throw Refusal("InvalidStateError", "this profile has the person's passkey for that account on \(rpID); only the person can replace it")
            }
            let personMade = byPerson
            let key = P256.Signing.PrivateKey()
            var idBytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, idBytes.count, &idBytes) == errSecSuccess else { throw Refusal("NotAllowedError", "no random bytes for the passkey's id") }
            let profile: String? = if case .profile(let name) = owner { name } else { nil }
            let passkey = Passkey(id: WebAuthn.base64url(idBytes), rpID: rpID, userHandle: handleText, userName: userName, displayName: displayName,
                                  profile: profile, created: Date(), lastUsed: nil, byPerson: personMade)
            let authData = WebAuthn.authenticatorData(rpID: rpID, flags: WebAuthn.flags(create: true, synced: profile != nil), credentialID: idBytes,
                                                      coseKey: WebAuthn.coseKey(publicKey: key.publicKey))
            let clientData = WebAuthn.clientDataJSON(type: "webauthn.create", challenge: challenge, origin: origin, crossOrigin: false)
            let secret = PasskeySecret(key: key.derRepresentation, rpID: rpID, userHandle: handleText, profile: profile, byPerson: personMade)
            do {
                try await keychainCall(owner, byPerson: byPerson) { try $0.add(passkey, secret, interactive: $1) }
            } catch { throw Refusal("NotAllowedError", "couldn't save the passkey: \(error)") }
            for passkey in old { try? store(owner).delete(passkey.id, interactive: false) }
            revision += 1
            tab.events.append("passkey created for \(passkey.label)")
            return ["id": passkey.id, "clientDataJSON": WebAuthn.base64url(clientData),
                    "attestationObject": WebAuthn.base64url(WebAuthn.attestationObject(authenticatorData: authData)),
                    "authenticatorData": WebAuthn.base64url(authData), "publicKey": WebAuthn.base64url(key.publicKey.derRepresentation),
                    "credProps": credProps]
        }
    }

    private func get(_ options: [String: Any], challenge: [UInt8], origin: String, host: String, owner: PasskeyOwner, tab: Tab) throws -> Prepared {
        let rpID = try rpID(options, key: nil, host: host)
        let candidates = try stored(owner)
        let allowedIDs = Set((options["allowCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        // With no list, the site lets the authenticator choose: the one used last.
        guard let chosen = candidates.filter({ $0.rpID == rpID && (allowedIDs.isEmpty || allowedIDs.contains($0.id)) })
            .max(by: { ($0.lastUsed ?? $0.created) < ($1.lastUsed ?? $1.created) }) else {
            throw Refusal("NotAllowedError", "no agweb passkey for \(rpID) in this " + (tab.workspace.profile.map { "profile (\($0))" } ?? "fresh workspace"))
        }
        let shown = chosen.userName.isEmpty ? chosen.displayName : chosen.userName
        return Prepared(
            title: "Sign in to \(rpID)" + (shown.isEmpty ? "?" : " as \(shown)?"),
            detail: "With the passkey Agweb keeps \(place(tab.workspace)).",
            button: "Sign In"
        ) { [self] byPerson in
            guard var passkey = try stored(owner).first(where: { $0.id == chosen.id }) else {
                throw Refusal("NotAllowedError", "the passkey for \(chosen.label) was deleted")
            }
            let authData = WebAuthn.authenticatorData(rpID: rpID, flags: WebAuthn.flags(create: false, synced: passkey.profile != nil))
            let clientData = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: challenge, origin: origin, crossOrigin: false)
            let signature: Data, secret: PasskeySecret
            do {
                let id = passkey.id
                secret = try await keychainCall(owner, byPerson: byPerson) { try $0.secret(id, interactive: $1) }
                // The listing can be rewritten without the Keychain asking; the key's own copy can't.
                guard secret.rpID == rpID, secret.userHandle == passkey.userHandle, secret.profile == passkey.profile else {
                    throw Failure("its Keychain item was changed outside Agweb")
                }
                signature = try secret.signingKey().signature(for: Data(authData + SHA256.hash(data: Data(clientData)))).derRepresentation
            } catch {
                throw Refusal("NotAllowedError", "the passkey for \(chosen.label) can't be used: \(error)")
            }
            passkey.lastUsed = Date()
            store(owner).used(passkey)
            revision += 1
            tab.events.append("signed in with a passkey for \(passkey.label)")
            return ["id": passkey.id, "clientDataJSON": WebAuthn.base64url(clientData), "authenticatorData": WebAuthn.base64url(authData),
                    "signature": WebAuthn.base64url(signature), "userHandle": secret.userHandle]
        }
    }

    /// Page-supplied names reach replies and Settings: one line, no control characters, short.
    private static func clean(_ text: String?) -> String {
        String((text ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }.prefix(64)
            .map(Character.init))
    }
}

extension Tab {
    /// Whether `origin` is the tab's top document's: a frame may use passkeys only on its own page.
    func isTop(_ origin: String) -> Bool {
        guard let url = webView.url, let scheme = url.scheme, let host = url.host else { return false }
        return WebAuthn.origin(scheme: scheme.lowercased(), host: host.lowercased(), port: url.port ?? 0) == origin
    }
}
