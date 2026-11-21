import AppKit
import AgwebCore
import Darwin

/// Tabs nobody used for Settings.unloadIdleMinutes lose their web content process, as Safari and Chrome discard
/// background tabs: about 120 MB each on a real site, where WebKit's own suspension keeps the page in memory. The tab
/// stays where it was with its URL, title and history, and WebKit keeps cookies and storage outside the page's process;
/// the next command or the person showing it reloads the page, which loses only what the page held in memory.
extension Browser {
    /// AGWEB_UNLOAD_SECONDS (the selftest) replaces the setting; 0 never unloads.
    static let unloadSecondsOverride = Double(ProcessInfo.processInfo.environment["AGWEB_UNLOAD_SECONDS"] ?? "")
    /// For 10 minutes after macOS says memory is short, tabs unused 5 minutes go too, whatever the setting (but never
    /// at Never).
    static let unloadUnderPressure = 300.0

    func scheduleUnloadIdle() {
        guard Self.unloadSecondsOverride != 0 else { return }
        let every = min(60, max(1, (Self.unloadSecondsOverride ?? 60) / 2))
        let timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.unloadIdle() }
        }
        timer.tolerance = every / 4
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.pressureUntil = Date().addingTimeInterval(600)
                self?.unloadIdle()
            }
        }
        pressure.resume()
        memoryPressure = pressure
    }

    /// A tab that may lose its page now: idle past the limit, in a workspace that allows it (`unload off` doesn't), not
    /// shown, not driven, recorded, asked about, held, capturing, downloading or loading, and neither shown nor heard
    /// playing within the limit.
    private func unloadable(_ tab: Tab, limit: Double, now: Double) -> Bool {
        let workspace = tab.workspace
        guard !workspace.unloadOff, !workspace.busy, workspace.recorder == nil, !tab.unloaded, tab.pendingURL == nil,
              tab.id != model.displayedTabID, !needsVisible(tab), tab.asking == nil, tab.liveCaptures == 0, tab.held.button == nil,
              tab.held.modifiers.isEmpty, !tab.downloading, !tab.webView.isLoading, now - max(tab.usedClock, tab.seenClock) > limit,
              let scheme = tab.webView.url?.scheme, scheme == "http" || scheme == "https" else { return false }
        return tab.processID > 0
    }

    func unloadIdle() {
        let setting = Self.unloadSecondsOverride ?? Double(Settings.store.integer(forKey: Settings.unloadIdleMinutes)) * 60
        guard setting > 0 else { return }
        let limit = pressureUntil > Date() ? min(setting, Self.unloadUnderPressure) : setting
        let now = RunningClock.now
        let tabs = model.workspaces.flatMap(\.tabs)
        for tab in tabs where tab.id == model.displayedTabID && !model.dashboardOpen || tab.audible { tab.seenClock = now }
        var done = Set<pid_t>()
        for tab in tabs where unloadable(tab, limit: limit, now: now) {
            let pid = tab.processID
            guard pid != getpid(), !done.contains(pid) else { continue }
            done.insert(pid)
            // Every tab in the process goes with it (a popup shares its opener's), so each must qualify.
            let sharing = tabs.filter { $0.processID == pid }
            guard sharing.allSatisfy({ unloadable($0, limit: limit, now: now) }) else { continue }
            // WebKit's own _killWebContentProcess leaves the process running on macOS 26. WebKit reports this end like a
            // crash, which webViewWebContentProcessDidTerminate leaves unloaded. No await since the pid was read, so it
            // is still this page's process.
            guard kill(pid, SIGKILL) == 0 else { continue }
            for each in sharing {
                each.unloaded = true
                each.awaitingExit = true
                each.lostPages = true
            }
        }
    }
}
