import AgwebCore
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

// The dashboard's pictures, taken only while a tab's process is awake, never by waking a suspended one, and never on a
// timer: as a tab goes hidden, 3 and 15 s after a tab finishes loading (an app fills itself in after its load) while
// it is hidden or the dashboard can be seen, as an agent's command ends and 1, 3, 10 and 25 s later while the dashboard
// can be seen, as the dashboard opens or comes back into view for tabs
// not yet suspended, and at quit for the tabs on screen. A picture taken mid-load is
// kept only until a full one comes and never replaces another. Named-profile tabs keep theirs in <root>/thumbnails, so
// after a relaunch the dashboard shows each tab as it was left, before it loads; a fresh workspace keeps nothing on disk.
extension Browser {
    static var thumbnailConfig: WKSnapshotConfiguration {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 480
        return config
    }

    static let thumbnailsFolder = Agweb.root.appendingPathComponent("thumbnails")
    /// Writes and deletes in order, off the main thread; quit waits for it.
    static let thumbnailQueue = DispatchQueue(label: "agweb.thumbnails", qos: .utility)

    /// Loaded and its process running: a covered window lets WebKit suspend even the displayed tab.
    private func canPicture(_ tab: Tab) -> Bool {
        tab.pendingURL == nil && !tab.unloaded && tab.webView.url != nil && MainWindow.isRendering(mainWindow.window) && !["suspended", "not running"].contains(tab.state)
    }

    /// Before the tab's view is hidden, so the picture is what was on screen. `save: false` keeps it in memory only.
    func captureThumbnail(_ tab: Tab, save: Bool = true) {
        guard canPicture(tab) else { return }
        let loading = tab.webView.isLoading
        guard !loading || tab.thumbnail == nil else { return }
        tab.webView.takeSnapshot(with: Self.thumbnailConfig) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, let image else { return }
                self.setThumbnail(tab, image, loading: loading, save: save)
            }
        }
    }

    /// As an agent's command ends, while the dashboard is open: right away, then at 1, 3, 10 and 25 s for a page that
    /// renders late or keeps changing (each only while someone can see it). A long command shows its result when it
    /// ends. Kept in memory; the tab's picture as it goes hidden is the one saved.
    func captureAfterCommand(_ tab: Tab) {
        guard model.dashboardOpen else { return }
        // Commands back to back would cancel every chain before its first picture: one now, at most each second.
        if windowSeen, Date().timeIntervalSince(tab.thumbnailAt) > 1 {
            // Stamped at the request: commands faster than a snapshot must not each start one.
            tab.thumbnailAt = Date()
            captureThumbnail(tab, save: false)
        }
        // The next command on the tab takes over with its own pictures.
        tab.commandPictures?.cancel()
        tab.commandPictures = Task { [weak tab] in
            var waited = 0.0
            for at in [0.2, 1, 3, 10, 25] {
                try? await Task.sleep(for: .seconds(at - waited))
                waited = at
                guard !Task.isCancelled, let tab, tab.workspace.tabs.contains(where: { $0 === tab }), model.dashboardOpen else { return }
                // Mid-command (one that touches no page, like `tab-list`) or out of sight: skip this one, not the rest.
                if !tab.workspace.busy, windowSeen, Date().timeIntervalSince(tab.thumbnailAt) > 0.5 { captureThumbnail(tab, save: false) }
            }
        }
    }

    /// After a load finishes in a hidden tab: a page an agent or a redirect moved while nobody looked, or one opened
    /// behind the current tab. Again later for an app that fills itself in after its load (a hidden page's timers are
    /// throttled), still long before the tab is suspended.
    func captureAfterLoad(_ tab: Tab) {
        // A redirect chain or a page reloading itself: pictures after the last load only.
        tab.thumbnailTask?.cancel()
        // Weak: a closed tab's web view must go at once, not play on until the last picture.
        tab.thumbnailTask = Task { [weak tab] in
            for delay in [3.0, 12.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let tab, tab.workspace.tabs.contains(where: { $0 === tab }) else { return }
                guard !tab.webView.isLoading else { continue }
                // A tab held awake after a command loads under an open dashboard too.
                if mainWindow.isHidden(tab.webView) { captureThumbnail(tab) } else if model.dashboardOpen, windowSeen { captureThumbnail(tab, save: false) }
            }
        }
    }

    /// As the dashboard opens or comes back into view: tabs whose process still runs (agents' tabs, and those hidden in
    /// the last few minutes) may have changed since their picture.
    func captureAwake(but skipped: Int?) {
        // Without the process state every hidden tab reads "hidden", suspended ones too.
        guard let any = model.workspaces.first?.tabs.first, any.webView.responds(to: NSSelectorFromString("_webProcessState")) else { return }
        for tab in model.workspaces.flatMap(\.tabs) where ["hidden", "visible"].contains(tab.state) && !tab.webView.isLoading && tab.id != skipped {
            captureThumbnail(tab)
        }
    }

    /// Ignored for a tab closed meanwhile: its file is already deleted and must stay so.
    func setThumbnail(_ tab: Tab, _ image: NSImage, loading: Bool, save: Bool = true) {
        guard tab.workspace.tabs.contains(where: { $0 === tab }) else { return }
        tab.thumbnail = image
        tab.thumbnailAt = Date()
        tab.thumbnailWhileLoading = loading
        guard save, !loading, tab.workspace.profile != nil,
              let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let file = Self.thumbnailFile(tab.thumbnailName)
        Self.thumbnailQueue.async {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return }
            // A picture of a logged-in page: 0600 like the rest of the root.
            try? FileManager.default.createDirectory(at: Self.thumbnailsFolder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let temporary = file.appendingPathExtension("tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data as Data, attributes: [.posixPermissions: 0o600]) else { return }
            if rename(temporary.path, file.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        }
    }

    func deleteThumbnail(_ tab: Tab) {
        let file = Self.thumbnailFile(tab.thumbnailName)
        Self.thumbnailQueue.async { try? FileManager.default.removeItem(at: file) }
    }

    static func thumbnailFile(_ name: String) -> URL { thumbnailsFolder.appendingPathComponent(name + ".jpg") }

    /// At launch, after the tabs are back: the pictures of tabs closed while agweb wasn't saving.
    func pruneThumbnails() {
        let kept = Set(model.workspaces.flatMap(\.tabs).map { $0.thumbnailName + ".jpg" })
        Self.thumbnailQueue.async {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.thumbnailsFolder.path)) ?? []
            for name in files where !kept.contains(name) { try? FileManager.default.removeItem(at: Self.thumbnailsFolder.appendingPathComponent(name)) }
        }
    }

    /// At quit: the tabs on screen never went hidden, so their pictures are taken now, within a second in all.
    func captureForQuit() async {
        if MainWindow.isRendering(mainWindow.window) {
            let tabs = model.workspaces.flatMap(\.tabs).filter { canPicture($0) && !mainWindow.isHidden($0.webView) }
            _ = try? await withTimeout(1, "thumbnails") {
                for tab in tabs where !tab.webView.isLoading && !Task.isCancelled {
                    if let image = try? await tab.snapshot(Self.thumbnailConfig, timeout: 1) { self.setThumbnail(tab, image, loading: false) }
                }
            }
        }
        await withCheckedContinuation { done in Self.thumbnailQueue.async { done.resume() } }
    }

    /// For `dashboard --filename`: tabs an agent is on, and those without a picture.
    func refreshThumbnails() async {
        let config = Self.thumbnailConfig
        for tab in model.workspaces.flatMap(\.tabs) where canPicture(tab) {
            // Idle tabs keep their picture: a snapshot of a suspended tab would wake its process.
            let active = tab.workspace.busy || tab.awakeUntil > Date() || keptRunning(tab)
            let missing = tab.thumbnail == nil || (tab.thumbnailWhileLoading && !tab.webView.isLoading)
            let loading = tab.webView.isLoading
            guard active || missing, !loading || tab.thumbnail == nil else { continue }
            if let image = try? await tab.snapshot(config, timeout: 3) { setThumbnail(tab, image, loading: loading, save: missing) }
        }
    }
}
