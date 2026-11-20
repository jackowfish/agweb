import AppKit

/// Seconds agweb has been running, carried across launches (SavedWorkspaces.clock) and stopped while the Mac sleeps:
/// cleanup counts only that time, so a week with agweb quit, or a holiday, closes nothing.
@MainActor enum RunningClock {
    private static var base = 0.0
    private static var since = ProcessInfo.processInfo.systemUptime
    static var now: Double { base + ProcessInfo.processInfo.systemUptime - since }
    static func start(from saved: Double) {
        base = saved
        since = ProcessInfo.processInfo.systemUptime
    }
}

extension Browser {
    /// Closes what agweb has run for Settings.closeUnusedDays (0: never) without using: such a workspace, and in a
    /// used one such a tab other than the agent's current one. Leaves alone the person's own workspaces with tabs (no
    /// agent drives them), one running a command, recording or asking the person, and the tab the window shows.
    func closeUnused() {
        let days = Settings.store.integer(forKey: Settings.closeUnusedDays)
        guard days > 0 else { return }
        let now = RunningClock.now, limit = Double(days) * 86_400
        let shown = model.displayedTabID
        // No current tab: the person's own workspace, or an agent's whose last tab closed, which may go once old.
        for workspace in model.workspaces where workspace.currentID != nil || workspace.tabs.isEmpty {
            guard !workspace.busy, workspace.recorder == nil, !workspace.tabs.contains(where: { $0.asking != nil }) else { continue }
            if now - workspace.usedClock > limit, !workspace.tabs.contains(where: { $0.id == shown }) {
                closeWorkspace(workspace)
                continue
            }
            for tab in workspace.tabs where now - tab.usedClock > limit && tab.id != workspace.currentID && tab.id != shown { closeTab(tab) }
        }
    }

    /// Hourly; the first run comes with the restored workspaces.
    func scheduleCloseUnused() {
        closeUnused()
        let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.closeUnused() } }
        timer.tolerance = 300
    }
}
