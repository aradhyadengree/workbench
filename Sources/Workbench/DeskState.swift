// Live Desk state shared by the main window and panes popped out into their own windows,
// plus the AppKit window management for those pop-outs (like Claude desktop's "pop a pane out
// into its own window, dock it back when you're done").
//
// Invariants:
// - A popped-out pane stays in `layout`; it is only hidden from the grid. Docking puts it back
//   exactly where it was. If a layout preset dropped it meanwhile, docking re-adds it at home.
// - Closing a pane window docks the pane. Quitting the app does not (windows aren't closed on
//   quit), so popped-out panes reopen on the next launch.
// - Pane windows are shown only while Live Desk is on screen. Develop and Test Studio host the
//   same Browser/simulator objects, and a web view can live in one window at a time.
// - Persisted: "deskLayout" (layout), "deskDetached" ([DeskTool raw value]), and AppKit's
//   "NSWindow Frame LiveDeskPane.<raw value>" (each pane window's frame and screen).
//   DeskTool raw values are pane titles, so renaming one loses all three.

import SwiftUI
import AppKit

final class DeskState: NSObject, ObservableObject, NSWindowDelegate {
    @Published var layout: DeskLayout = DeskState.savedLayout() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: "deskLayout") }
    }
    @Published private(set) var detached: Set<DeskTool> = DeskState.savedDetached() {
        didSet { UserDefaults.standard.set(detached.map(\.rawValue).sorted(), forKey: "deskDetached") }
    }
    /// The pane shown alone, filling the main window ("Expand pane").
    @Published var expanded: DeskTool?
    /// The pane keyboard commands act on: the last one clicked in the main window.
    @Published var focused: DeskTool?
    /// Phone pane shows Mobile Web instead of the iOS Simulator.
    @Published var mobileWeb = false
    /// Bumped by "Load both" so the mobile web preview reloads.
    @Published var previewRequest = UUID()
    /// Pane header under a dragged pane title (drop target for swapping).
    @Published var highlighted: DeskTool?

    private var windows: [DeskTool: NSWindow] = [:]
    private var onScreen = false
    private var clickMonitor: Any?
    /// One invisible marker per grid pane; its frame in the window tells which pane a click hit.
    fileprivate var markers: [DeskTool: WeakView] = [:]

    // === LAYOUT ===

    /// Panes the main window's grid shows: the layout minus popped-out panes.
    var gridLayout: DeskLayout {
        var grid = layout
        for tool in detached { grid.remove(tool) }
        return grid
    }

    func isDetached(_ tool: DeskTool) -> Bool { detached.contains(tool) }

    func setVisible(_ tool: DeskTool, _ show: Bool, project: Project) {
        if show {
            layout.show(tool, below: DeskLayout.home(of: tool))
        } else {
            if detached.contains(tool) { dock(tool) }
            layout.remove(tool)
            if expanded == tool { expanded = nil }
            if focused == tool { focused = nil }
        }
    }

    /// Saved layouts from before the Test cases pane existed get it once, below the chat.
    /// After that, hiding it from the Layout menu sticks.
    private static func savedLayout() -> DeskLayout {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "deskLayout"),
              var layout = try? JSONDecoder().decode(DeskLayout.self, from: data) else { return DeskLayout() }
        if !defaults.bool(forKey: "deskLayoutAddedCases") {
            layout.show(.cases, below: .chat)
            // Persist now: didSet doesn't run for the initial value, so without this the flag
            // sticks but the pane vanishes again on the next launch.
            defaults.set(try? JSONEncoder().encode(layout), forKey: "deskLayout")
            defaults.set(true, forKey: "deskLayoutAddedCases")
        }
        return layout
    }

    private static func savedDetached() -> Set<DeskTool> {
        Set((UserDefaults.standard.stringArray(forKey: "deskDetached") ?? []).compactMap(DeskTool.init(rawValue:)))
    }

    // === POP OUT / DOCK ===

    func popOut(_ tool: DeskTool, project: Project) {
        guard !detached.contains(tool) else { windows[tool]?.makeKeyAndOrderFront(nil); return }
        if !layout.contains(tool) { layout.show(tool, below: DeskLayout.home(of: tool)) }
        detached.insert(tool)
        if expanded == tool { expanded = nil }
        if focused == tool { focused = nil }
        // Next run loop: let the grid drop the pane first, so its web view is free to move.
        DispatchQueue.main.async { self.openWindow(tool, project: project, activate: true) }
    }

    func dock(_ tool: DeskTool) {
        guard detached.contains(tool) else { return }
        if !layout.contains(tool) { layout.show(tool, below: DeskLayout.home(of: tool)) }
        detached.remove(tool)
        if let window = windows.removeValue(forKey: tool) {
            window.delegate = nil
            window.close()
        }
        focused = tool
    }

    func dockAll() { detached.forEach(dock) }

    func toggleDetached(_ tool: DeskTool, project: Project) {
        if detached.contains(tool) { dock(tool) } else { popOut(tool, project: project) }
    }

    /// Live Desk appeared: show (or restore after launch) the pane windows and start tracking clicks.
    func appear(project: Project) {
        onScreen = true
        for tool in detached {
            if let window = windows[tool] { window.orderFront(nil) }
            else { openWindow(tool, project: project, activate: false) }
        }
        startClickMonitor()
    }

    /// Live Desk left the screen (another mode): hide pane windows without docking them.
    func disappear() {
        onScreen = false
        windows.values.forEach { $0.orderOut(nil) }
    }

    /// The pane the user means: a key pane window's pane, else the last-clicked grid pane.
    var commandTarget: DeskTool? {
        if let key = NSApp.keyWindow, let tool = windows.first(where: { $0.value === key })?.key { return tool }
        return focused
    }

    private func openWindow(_ tool: DeskTool, project: Project, activate: Bool) {
        guard windows[tool] == nil, detached.contains(tool), onScreen else { return }
        let size = tool == .phone ? NSSize(width: 440, height: 900) : NSSize(width: 640, height: 780)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = tool.rawValue
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 280, height: 240)
        window.contentView = NSHostingView(rootView: DetachedDeskPane(tool: tool, project: project, desk: self))
        window.delegate = self
        // Restores this pane's last frame (and screen); if that screen is gone, start centred.
        if !window.setFrameUsingName(Self.frameName(tool))
            || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName(tool))
        windows[tool] = window
        if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
    }

    private static func frameName(_ tool: DeskTool) -> String { "LiveDeskPane." + tool.rawValue }

    func windowWillClose(_ notification: Notification) {
        // The user closed a pane window (red button or ⌘W): dock it, like Claude desktop.
        guard let window = notification.object as? NSWindow,
              let tool = windows.first(where: { $0.value === window })?.key else { return }
        windows[tool] = nil
        dock(tool)
    }

    func keepOnTop(_ tool: DeskTool) -> Bool { windows[tool]?.level == .floating }
    func setKeepOnTop(_ tool: DeskTool, _ on: Bool) {
        windows[tool]?.level = on ? .floating : .normal
        objectWillChange.send()
    }

    // === FOCUS ===

    /// Clicks inside web views and the simulator never reach SwiftUI gestures, so focus is
    /// tracked with an AppKit event monitor that never consumes the event.
    private func startClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.onScreen, let window = event.window else { return event }
            let hit = self.markers.first { _, marker in
                guard let view = marker.view, view.window === window else { return false }
                return view.convert(view.bounds, to: nil).contains(event.locationInWindow)
            }?.key
            if let hit, hit != self.focused { self.focused = hit }
            return event
        }
    }
}

/// Weak box so a torn-down pane's marker doesn't linger.
struct WeakView { weak var view: NSView? }

/// Invisible background view that registers where a grid pane is, for click-to-focus.
struct DeskPaneMarker: NSViewRepresentable {
    let tool: DeskTool
    let desk: DeskState
    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        desk.markers[tool] = WeakView(view: view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { desk.markers[tool] = WeakView(view: view) }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A popped-out pane's whole window: its header (with Dock Back) and the live pane.
struct DetachedDeskPane: View {
    let tool: DeskTool
    @ObservedObject var project: Project
    @ObservedObject var desk: DeskState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label(tool.rawValue, systemImage: tool.symbol).font(.caption.bold()).lineLimit(1)
                Spacer(minLength: 0)
                if tool == .phone { PhoneTargetMenu(desk: desk) }
                Toggle(isOn: Binding(get: { desk.keepOnTop(tool) }, set: { desk.setKeepOnTop(tool, $0) })) {
                    Image(systemName: desk.keepOnTop(tool) ? "pin.fill" : "pin")
                }
                .toggleStyle(.button).buttonStyle(.plain)
                .help("Keep this window above other windows")
                Button { desk.dock(tool) } label: { Label("Dock Back", systemImage: "rectangle.portrait.and.arrow.forward") }
                    .buttonStyle(.plain).labelStyle(.iconOnly)
                    .help("Put this pane back in the Live Desk window (⌥⌘N)")
            }
            .padding(.horizontal, 8).frame(height: 27)
            .background(Color.secondary.opacity(0.12))
            DeskPaneContent(tool: tool, project: project)
        }
        .frame(minWidth: 280, minHeight: 240)
    }
}

/// The Live Desk menu: pane toggles and commands on the focused pane. Shortcuts follow Claude
/// desktop where they don't clash with Workbench's own (⌘\ closes the focused pane there too).
struct LiveDeskCommands: Commands {
    @ObservedObject var project: Project
    @ObservedObject var desk: DeskState
    private static let order: [(DeskTool, KeyEquivalent)] = [(.chat, "1"), (.cases, "2"), (.phone, "3"), (.web, "4"), (.shell, "5")]

    var body: some Commands {
        CommandMenu("Live Desk") {
            Button("Testing Layout") { show(); desk.layout = .testing; desk.expanded = nil }
            Button("Default Layout") { show(); desk.layout = DeskLayout(); desk.expanded = nil }
            Divider()
            ForEach(Self.order, id: \.0) { tool, key in
                Toggle(tool.rawValue, isOn: Binding(get: { desk.layout.contains(tool) },
                                                    set: { show(); desk.setVisible(tool, $0, project: project) }))
                    .keyboardShortcut(key, modifiers: [.command, .option])
            }
            Divider()
            Button(desk.expanded == nil ? "Expand Focused Pane" : "Show All Panes") {
                show()
                if desk.expanded != nil { desk.expanded = nil }
                else if let tool = desk.commandTarget, !desk.isDetached(tool) { desk.expanded = tool }
            }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Button(desk.commandTarget.map(desk.isDetached) == true ? "Dock Focused Pane" : "Open Focused Pane in New Window") {
                show()
                if let tool = desk.commandTarget { desk.toggleDetached(tool, project: project) }
            }.keyboardShortcut("n", modifiers: [.command, .option])
            Button("Hide Focused Pane") {
                guard let tool = desk.commandTarget, desk.layout.columns.flatMap(\.tools).count > 1 else { return }
                desk.setVisible(tool, false, project: project)
            }.keyboardShortcut("\\", modifiers: .command)
            if !desk.detached.isEmpty {
                Button("Dock All Windows") { desk.dockAll() }
            }
        }
    }

    private func show() { project.viewMode = .quad }
}
