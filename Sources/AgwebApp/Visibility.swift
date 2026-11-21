import AppKit
import WebKit

// WebKit throttles only tabs it sees as hidden (view hidden, out of the window, or the window occluded); tabs stacked
// under the displayed one all count as visible, so every covered page animated and painted at full rate. A tab is
// shown only while it is displayed, its agent's command runs on it, it is being recorded, a key or button is held in
// it, or for a while after the agent's last command on it (toggling around every command would refetch on each
// visibilitychange).
extension Browser {
    static let awakeAfterCommand = Double(ProcessInfo.processInfo.environment["AGWEB_AWAKE_SECONDS"] ?? "") ?? 30

    func needsVisible(_ tab: Tab) -> Bool {
        if model.displayedTabID == tab.id, !model.dashboardOpen { return true }
        let workspace = tab.workspace
        guard workspace.currentID == tab.id else { return false }
        // A drag or a held Shift spans commands; a page seeing hidden mid-drag cancels it.
        let holding = tab.held.button != nil || !tab.held.modifiers.isEmpty
        return workspace.busy || workspace.recorder != nil || holding || tab.awakeUntil > Date()
    }

    /// A tab using the fake camera or mic stays awake too, as a capturing page does in Safari: hidden, its frames would
    /// slow to about one a second and its process would be suspended. Muted while nothing else needs it shown.
    func updateVisibility() {
        for tab in model.workspaces.lazy.flatMap(\.tabs) {
            let needed = needsVisible(tab), capturing = tab.liveCaptures > 0
            setHidden(tab, !needed && !capturing)
            if tab.workspace.name != Self.userWorkspace { tab.setMuted(!needed) }
        }
    }

    /// Before a command on `tab`: shown, so rAF, hover and rendering run again, and kept awake after the command. A
    /// page shown again refetches on visibilitychange (SWR, React Query), so the command waits for that first.
    func wake(_ tab: Tab) async {
        tab.workspace.actedOn = tab
        tab.workspace.working(on: tab)
        tab.markUsed()
        guard mainWindow.isHidden(tab.webView) else { return }
        setHidden(tab, false)
        guard tab.pendingURL == nil else { return }
        await tab.activityStateApplied()
        await tab.settle()
    }

    /// Hidden agent tabs are muted too: a page playing audio holds its process in the foreground, so it would never be
    /// suspended. The person's own tabs keep playing, as in any browser.
    private func setHidden(_ tab: Tab, _ hidden: Bool) {
        guard mainWindow.isHidden(tab.webView) != hidden else { return }
        mainWindow.setHidden(tab.webView, hidden)
        if tab.workspace.name != Self.userWorkspace { tab.setMuted(hidden) }
    }

    /// AgentWindow reports key while agweb is in the background, so a password field focused there by an agent, a
    /// page or the person before they switched away turns on secure input as in the front window: every event tap on
    /// the Mac (keyboard tools, window switchers) then goes blind until the field loses focus. WebKit sends no notice
    /// of it, so it is turned off when agweb goes to the background, after each command and twice a second (a page's
    /// own focus). Only a window's first responder can hold it: WebKit resets it when a view resigns.
    func releaseSecureInput() {
        let enabled = NSSelectorFromString("_secureEventInputEnabledForTesting"), reset = NSSelectorFromString("_resetSecureInputState")
        guard !NSApp.isActive else { return }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        for view in NSApp.windows.compactMap({ $0.firstResponder as? WKWebView }) where view.responds(to: enabled) && view.responds(to: reset) {
            guard unsafeBitCast(view.method(for: enabled), to: Get.self)(view, enabled) else { continue }
            unsafeBitCast(view.method(for: reset), to: Call.self)(view, reset)
        }
    }

    func keepAwakeAfterCommand(_ tab: Tab) {
        tab.awakeUntil = Date().addingTimeInterval(Self.awakeAfterCommand)
        Task {
            try? await Task.sleep(for: .seconds(Self.awakeAfterCommand + 0.1))
            self.updateVisibility()
        }
    }
}
