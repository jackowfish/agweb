import AppKit

extension Browser {
    /// Closes what nobody used for Settings.closeUnusedDays (0: never), at launch and then hourly: a workspace whose
    /// last use is that old, and in the others any such tab but the agent's current one. Leaves alone a workspace
    /// running a command, recording or asking the person, and the tab the person is looking at.
    func closeUnused(now: Date = Date()) {
        let days = Settings.store.integer(forKey: Settings.closeUnusedDays)
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let watched = NSApp.isActive ? model.displayedTabID : nil
        for workspace in model.workspaces {
            guard !workspace.busy, workspace.recorder == nil, !workspace.tabs.contains(where: { $0.asking != nil || $0.id == watched }) else { continue }
            if workspace.lastUsed < cutoff {
                closeWorkspace(workspace)
                continue
            }
            for tab in workspace.tabs where tab.lastUsed < cutoff && tab.id != workspace.currentID { closeTab(tab) }
        }
    }

    /// Hourly; the first run comes with the restored workspaces.
    func scheduleCloseUnused() {
        closeUnused()
        let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.closeUnused() } }
        timer.tolerance = 300
    }
}
