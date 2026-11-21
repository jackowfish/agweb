import AgwebCore
import AppKit
import SwiftUI
import WebKit

// Every tab at once, in the window's content area: thumbnails, not live views. Live ones would all have to be
// visible (see Visibility.swift) and shrinking them would relayout the pages. A thumbnail is a small snapshot
// (Thumbnails.swift), which works on hidden tabs, taken as an agent's command ends; nothing is polled. While the window
// can be seen, even on a second display, the CPU and memory figures and the "ago" labels advance every 5 s; covered,
// minimized, on another Space or with the screens asleep, the dashboard does nothing.
extension Browser {
    func dashboardChanged(_ open: Bool) {
        dashboardTask?.cancel()
        dashboardNap?.cancel()
        dashboardRetake?.cancel()
        dashboardObserver.map(NotificationCenter.default.removeObserver)
        dashboardObserver = nil
        // Before the dashboard hides the displayed tab, which then gets its own picture as it goes hidden; one an agent
        // keeps awake, or one capturing, stays shown, so it is taken here.
        if open, dashboardSeen {
            let hiding = model.displayedTab.flatMap { needsVisible($0) || $0.liveCaptures > 0 ? nil : $0.id }
            captureAwake(but: hiding)
        }
        mainWindow.showDashboard(open)
        updateVisibility()
        scheduleSave()
        guard open else { return }
        dashboardObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                   object: mainWindow.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.dashboardOpen, self.dashboardSeen else { return }
                // Tabs that changed while nobody could see them; again a moment later for one WebKit wakes only now.
                self.captureAwake(but: nil)
                self.dashboardNap?.cancel()
                self.dashboardRetake?.cancel()
                self.dashboardRetake = Task {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled, self.model.dashboardOpen, self.dashboardSeen { self.captureAwake(but: nil) }
                }
            }
        }
        dashboardTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                if self.dashboardSeen {
                    self.model.dashboardNow = Date()
                    if Settings.store.bool(forKey: Settings.showUsage) {
                        self.model.processes = self.usageSampler.sample()
                    } else if !self.model.processes.isEmpty {
                        self.model.processes = [:]
                    }
                }
                // A first sample (after a wait) has no CPU: the next comes half a second later.
                let noCPU = self.model.processes.values.contains { $0.usage.cpu == nil }
                let seconds = self.dashboardSeen ? (noCPU ? 0.5 : 5.0) : 3600
                let nap = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
                self.dashboardNap = nap
                await nap.value
            }
        }
    }

    /// Some of the window is on a screen that is on: a second display counts, a covered window or another Space doesn't.
    var dashboardSeen: Bool { mainWindow.window.occlusionState.contains(.visible) }

    /// What a dashboard tile says the agent did last; never the text it typed, filled or evaluated.
    static func summary(_ request: Request) -> String {
        let shown = CommandLog.textCommands.contains(request.command)
            ? request.command + (request.command == "fill" || request.command == "select" ? request.args.first.map { " \($0)" } ?? "" : "")
            : ([request.command] + request.args.prefix(1)).joined(separator: " ")
        return String(shown.prefix(48))
    }
}

struct DashboardView: View {
    let model: BrowserModel
    /// The order while the pointer is over the grid, so a tile doesn't move away just as it is clicked.
    @State private var frozen: [Int]?
    @AppStorage(Settings.showUsage, store: Settings.store) private var showUsage = true
    @AppStorage(Settings.columns, store: Settings.store) private var columns = 0
    @AppStorage(Settings.textSize, store: Settings.store) private var textSize = TextSize.medium

    var body: some View {
        // Newest first, by when the tab was made (ids only grow); what agents do in a tab never moves it.
        let newest = model.workspaces.flatMap(\.tabs).sorted { $0.id > $1.id }
        let place = Dictionary(uniqueKeysWithValues: (frozen ?? newest.map(\.id)).enumerated().map { ($1, $0) })
        // New tabs go last while frozen.
        let tabs = newest.sorted { (place[$0.id] ?? .max) < (place[$1.id] ?? .max) }
        let usage = showUsage ? model.processes : [:]
        let sharing = Dictionary(grouping: tabs.map(\.processID), by: { $0 }).mapValues(\.count)
        ScrollView {
            if tabs.isEmpty {
                Text("No tabs yet").foregroundStyle(.secondary).padding(40)
            }
            LazyVGrid(columns: grid, spacing: 18) {
                ForEach(tabs) { tab in
                    let pid = tab.processID
                    TabTile(tab: tab, displayed: model.displayedTabID == tab.id, usage: usage[pid]?.usage, now: model.dashboardNow, shared: (sharing[pid] ?? 0) > 1,
                            scale: textSize.scale) {
                        model.onCloseTab?(tab)
                    }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.dashboardOpen = false
                            model.display(tab.id)
                        }
                }
            }
            .padding(16)
            .animation(.default, value: tabs.map(\.id))
        }
        .onHover { inside in frozen = inside ? tabs.map(\.id) : nil }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var grid: [GridItem] {
        columns > 0 ? Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns)
            : [GridItem(.adaptive(minimum: 260, maximum: 520), spacing: 16, alignment: .top)]
    }
}

/// The toolbar's middle while the dashboard is open: tab count and every process counted once, with the split by
/// kind in the tooltip. Empty with Settings ▸ CPU and memory off.
struct UsageTotal: View {
    let model: BrowserModel
    @AppStorage(Settings.showUsage, store: Settings.store) private var showUsage = true
    @AppStorage(Settings.textSize, store: Settings.store) private var textSize = TextSize.medium

    var body: some View {
        let tabs = model.workspaces.reduce(0) { $0 + $1.tabs.count }
        if showUsage, !model.processes.isEmpty {
            total(model.processes, tabs: tabs)
        }
    }

    private func total(_ usage: [pid_t: (name: String, usage: Usage)], tabs: Int) -> some View {
        func sum(_ list: some Sequence<(name: String, usage: Usage)>) -> Usage {
            // The processes with a CPU figure (a new one gets its first after a sample); none when none has one.
            let figures = list.compactMap(\.usage.cpu)
            return Usage(cpu: figures.isEmpty ? nil : figures.reduce(0, +), memory: list.reduce(0) { $0 + $1.usage.memory })
        }
        let kinds: [(String, (String) -> Bool)] = [("Pages", { $0.contains("WebContent") }), ("GPU", { $0.contains("GPU") }),
                                                   ("Network", { $0.contains("Networking") }), ("App and other", { _ in true })]
        var left = Array(usage.values)
        let parts = kinds.map { kind, matches in
            let mine = left.filter { matches($0.name) }
            left.removeAll { matches($0.name) }
            return "\(kind): \(sum(mine).label)"
        }
        return Label("\(tabs) \(tabs == 1 ? "tab" : "tabs") · " + sum(usage.values).label, systemImage: "gauge.with.dots.needle.33percent")
            .font(.system(size: 12 * textSize.scale)).monospacedDigit().foregroundStyle(.primary)
            // The toolbar shows a Label as its icon alone.
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .fixedSize()
            .help(parts.joined(separator: "\n"))
    }
}

private struct TabTile: View {
    let tab: Tab
    let displayed: Bool
    let usage: Usage?
    let now: Date
    let shared: Bool
    /// The Settings text size; macOS text styles have fixed sizes, so these are the styles' sizes scaled.
    let scale: CGFloat
    let close: () -> Void

    var body: some View {
        let workspace = tab.workspace
        let driven = workspace.currentID == tab.id
        VStack(alignment: .leading, spacing: 6) {
            Color(nsColor: .textBackgroundColor)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .top) {
                    if let image = tab.thumbnail {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "globe").font(.system(size: 26 * scale)).foregroundStyle(.tertiary).frame(maxHeight: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(displayed ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                        lineWidth: displayed ? 2 : 1))
                .overlay(alignment: .bottom) {
                    if let asking = tab.asking {
                        Label { Text(asking).lineLimit(2) } icon: { Circle().fill(Color.orange).frame(width: 7, height: 7) }
                            .font(.system(size: 11 * scale))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule()).padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if tab.state != "visible" {
                        Text(tab.state).font(.system(size: 10 * scale)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule()).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10 * scale, weight: .semibold)).frame(width: 22, height: 22)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                    .padding(6)
                }
            HStack(spacing: 6) {
                // As in the sidebar: the agent's tab in the normal color, its other tabs dimmed.
                Text(tab.title.isEmpty ? (tab.url.isEmpty ? "New tab" : tab.url) : tab.title).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(driven || workspace.currentID == nil ? .primary : .secondary)
                Spacer(minLength: 0)
                // Both truncate on a narrow tile, so neither the title nor the workspace is squeezed to "…" alone.
                HStack(spacing: 6) {
                    Label(workspace.name, systemImage: "square.stack").lineLimit(1)
                    if let profile = workspace.profile { Label(profile, systemImage: "person.crop.circle").lineLimit(1) }
                }
                .font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                ActivityDot(tab: tab, working: workspace.workingTabID == tab.id)
            }
            .font(.system(size: 13 * scale))
            if let usage {
                Text(usage.label + (shared ? " · shared" : "")).font(.system(size: 10 * scale)).monospacedDigit().foregroundStyle(.secondary)
                    .help(shared ? "This page shares its process with another tab, so both show the same numbers" : "This page's process")
            }
            if driven, let last = workspace.lastCommand, let at = workspace.lastCommandAt {
                // Advanced with the dashboard's 5 s figures: TimelineViews here measured 2-9x the cost, depending on settings.
                Text("\(last) · \(Self.ago(at, max(now, at)))").font(.system(size: 10 * scale)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private static func ago(_ date: Date, _ now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "\(seconds) s ago" : seconds < 3600 ? "\(seconds / 60) min ago" : "\(seconds / 3600) h ago"
    }
}
