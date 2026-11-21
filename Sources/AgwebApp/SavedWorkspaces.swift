import AppKit
import AgwebCore

/// Workspaces and their tabs outlive the app: saved a second after anything changes and on quit, reopened at
/// launch. A reopened tab loads when it is first shown or driven, so a relaunch doesn't load every page at once.
/// `close` and `close-all` end a workspace for good, and so does a long time unused (Cleanup.swift). A named profile's
/// tabs also keep their dashboard picture, in <root>/thumbnails (Thumbnails.swift).
struct SavedWorkspaces: Codable {
    struct Workspace: Codable {
        var name: String
        var profile: String?
        var current: Int?
        var tabs: [Tab]
        /// `agweb -w NAME adblock off`; nil when it blocks.
        var adBlockOff: Bool?
        /// `unload off` and `sound on`; nil at the default.
        var unloadOff: Bool?
        var soundOn: Bool?
        /// Workspace.lastUsed; nil in files from before it was kept, read as the launch time.
        var lastUsed: Date?
        /// Workspace.usedClock; nil in older files, read as now.
        var usedClock: Double?
    }

    struct Tab: Codable {
        var url: String
        var title: String
        /// sessionStorage by origin; 0600 like the rest, since it holds tokens.
        var session: [String: [String: String]]?
        var lastUsed: Date?
        var usedClock: Double?
        /// Tab.thumbnailName; a named profile's tabs only.
        var thumbnail: String?
    }

    var workspaces: [Workspace]
    /// The tab the window showed, as workspace name and index.
    var displayed: String?
    var displayedIndex: Int?
    var dashboard: Bool?
    /// RunningClock when saved: it carries on from there at the next launch.
    var clock: Double?
}

extension Browser {
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // The tab the person is looking at may be one they log in to by hand.
            await self.model.displayedTab?.captureSession()
            guard !Task.isCancelled else { return }
            self.saveWorkspaces()
            // So a crash loses at most the last second of cookie logins; sessionStorage is saved on commands and quit.
            await Profiles.saveSessionCookies()
        }
    }

    func saveWorkspaces() {
        saveTask?.cancel()
        let displayed = model.displayedTab
        let state = SavedWorkspaces(
            workspaces: model.workspaces.map { workspace in
                .init(name: workspace.name, profile: workspace.profile, current: workspace.tabs.firstIndex { $0.id == workspace.currentID },
                      tabs: workspace.tabs.map { .init(url: $0.currentURL, title: $0.currentTitle,
                                                       session: workspace.profile == nil || $0.session.isEmpty ? nil : $0.session,
                                                       lastUsed: $0.lastUsed, usedClock: $0.usedClock,
                                                       thumbnail: workspace.profile == nil ? nil : $0.thumbnailName) },
                      adBlockOff: workspace.adBlockOff ? true : nil, unloadOff: workspace.unloadOff ? true : nil,
                      soundOn: workspace.soundOn ? true : nil, lastUsed: workspace.lastUsed, usedClock: workspace.usedClock)
            },
            displayed: displayed?.workspace.name, displayedIndex: displayed.flatMap { tab in tab.workspace.tabs.firstIndex { $0 === tab } },
            dashboard: model.dashboardOpen ? true : nil, clock: RunningClock.now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        let file = Agweb.workspacesFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // URLs can carry tokens.
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func restoreWorkspaces() {
        // No file: no tab names a picture. One that can't be read keeps them, as the profile sweep does.
        guard FileManager.default.fileExists(atPath: Agweb.workspacesFile.path) else { pruneThumbnails(); return }
        guard let data = try? Data(contentsOf: Agweb.workspacesFile),
              case let decoder = { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }(),
              let state = try? decoder.decode(SavedWorkspaces.self, from: data) else { return }
        RunningClock.start(from: state.clock ?? 0)
        for saved in state.workspaces where !model.workspaces.contains(where: { $0.name == saved.name }) {
            guard let workspace = try? existingOrNewWorkspace(named: saved.name, profile: saved.profile) else { continue }
            workspace.adBlockOff = saved.adBlockOff == true
            workspace.unloadOff = saved.unloadOff == true
            workspace.soundOn = saved.soundOn == true
            for savedTab in saved.tabs {
                let url = URL(string: savedTab.url).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
                let seeds = workspace.profile == nil ? [:] : savedTab.session ?? [:]
                let tab = addTab(to: workspace, display: false, lazy: url != nil, seeds: seeds)
                tab.pendingURL = url
                tab.url = savedTab.url
                tab.title = savedTab.title
                tab.lastUsed = savedTab.lastUsed ?? tab.lastUsed
                tab.usedClock = savedTab.usedClock ?? RunningClock.now
                if let name = savedTab.thumbnail, UUID(uuidString: name) != nil, workspace.profile != nil {
                    tab.thumbnailName = name
                    tab.thumbnail = NSImage(contentsOf: Self.thumbnailFile(name))
                }
            }
            workspace.lastUsed = saved.lastUsed ?? workspace.lastUsed
            workspace.usedClock = saved.usedClock ?? RunningClock.now
            if let index = saved.current, workspace.tabs.indices.contains(index) { workspace.currentID = workspace.tabs[index].id }
        }
        if let name = state.displayed, let index = state.displayedIndex,
           let tabs = model.workspaces.first(where: { $0.name == name })?.tabs, tabs.indices.contains(index) {
            model.display(tabs[index].id, used: false)
        }
        if state.dashboard == true { model.dashboardOpen = true }
        pruneThumbnails()
        AdBlock.shared.apply()
    }
}
