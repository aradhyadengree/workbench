// Live Desk: the side-by-side testing workspace (chat, test cases, simulator, browser, shell).
// Layout, pop-out windows and focus live in DeskState (DeskState.swift) so a pane can move
// between this window's grid and its own window without restarting.

import SwiftUI

struct QuadWorkspace: View {
    @ObservedObject var project: Project
    @ObservedObject private var desk: DeskState
    @ObservedObject private var targets: TestTargets
    @State private var address = ""

    init(project: Project) {
        self.project = project
        _desk = ObservedObject(wrappedValue: project.desk)
        _targets = ObservedObject(wrappedValue: project.targets)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Product URL or localhost:3000", text: $address).textFieldStyle(.roundedBorder).onSubmit(load)
                Button("Load both", action: load).disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Open the URL in the browser and mobile web preview")
                LocalPreviewButton(sessions: project.terminals) { url in
                    address = url.absoluteString
                    load()
                    desk.expanded = nil
                }
                Menu("Layout") { layoutMenu }.fixedSize()
            }.padding(7)
            Divider()
            if let expanded = desk.expanded, !desk.isDetached(expanded) { pane(expanded) }
            else if desk.gridLayout.columns.isEmpty { allDetached }
            else { grid }
        }
        .onAppear { address = targets.web.address; desk.appear(project: project) }
        .onDisappear { desk.disappear() }
        .onChange(of: project.folder) { address = ""; project.simulatorUDID = "" }
    }

    @ViewBuilder private var layoutMenu: some View {
        if desk.expanded != nil { Button("Show All Panes") { desk.expanded = nil } }
        Button("Testing Layout") { desk.layout = .testing; desk.expanded = nil }
            .help("Terminal chat, Test cases, Simulator and Browser side by side at full height")
        Button("Default Layout") { desk.layout = DeskLayout(); desk.expanded = nil }
        Section("Panes") {
            ForEach(DeskTool.allCases, id: \.self) { tool in
                Toggle(tool.rawValue, isOn: Binding(get: { desk.layout.contains(tool) },
                                                    set: { desk.setVisible(tool, $0, project: project) }))
                    // Hiding the last pane would leave an empty desk with no header to recover from.
                    .disabled(desk.layout.contains(tool) && desk.layout.columns.flatMap(\.tools).count == 1)
            }
        }
        if !desk.detached.isEmpty {
            Section("Windows") {
                ForEach(DeskTool.allCases.filter(desk.isDetached), id: \.self) { tool in
                    Button("Dock " + tool.rawValue) { desk.dock(tool) }
                }
                Button("Dock All Windows") { desk.dockAll() }
            }
        }
    }

    private var allDetached: some View {
        ContentUnavailableView {
            Label("Every pane is in its own window", systemImage: "macwindow.on.rectangle")
        } actions: {
            Button("Dock All Windows") { desk.dockAll() }
        }
    }

    private var grid: some View {
        let layout = desk.gridLayout
        return GeometryReader { geo in
            let widths = DeskLayout.lengths(geo.size.width, weights: layout.columns.map(\.width), minimum: 164)
            HStack(spacing: 0) {
                ForEach(Array(layout.columns.enumerated()), id: \.element.id) { index, column in
                    let weights = column.tools.map { layout.heights[$0] ?? 1 }
                    let heights = DeskLayout.lengths(geo.size.height, weights: weights, minimum: 95)
                    VStack(spacing: 0) {
                        ForEach(Array(column.tools.enumerated()), id: \.element) { row, tool in
                            pane(tool).frame(height: heights[row])
                            if row + 1 < column.tools.count {
                                DeskDivider(vertical: false, space: geo.size.height, minimum: 95, index: row,
                                            weights: weights) { pair in
                                    desk.layout.heights[tool] = pair.0
                                    desk.layout.heights[column.tools[row + 1]] = pair.1
                                }
                            }
                        }
                    }.frame(width: widths[index])
                    if index + 1 < layout.columns.count {
                        DeskDivider(vertical: true, space: geo.size.width, minimum: 164, index: index,
                                    weights: layout.columns.map(\.width)) { pair in
                            // The grid hides popped-out panes, so map back to the real columns by id.
                            let ids = (column.id, layout.columns[index + 1].id)
                            if let a = desk.layout.columns.firstIndex(where: { $0.id == ids.0 }),
                               let b = desk.layout.columns.firstIndex(where: { $0.id == ids.1 }) {
                                desk.layout.columns[a].width = pair.0
                                desk.layout.columns[b].width = pair.1
                            }
                        }
                    }
                }
            }
        }
    }

    private func load() {
        targets.web.address = address; targets.web.go()
        targets.phone.address = address; targets.phone.go()
        desk.previewRequest = UUID()
        desk.mobileWeb = true
    }

    private func pane(_ tool: DeskTool) -> some View {
        let isExpanded = desk.expanded == tool
        // Outline only when there's a choice of pane for keyboard commands to act on.
        let showsFocus = desk.focused == tool && desk.expanded == nil && desk.gridLayout.columns.flatMap(\.tools).count > 1
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Label(tool.rawValue, systemImage: "line.3.horizontal")
                    .font(.caption.bold()).lineLimit(1)
                    .draggable("workbench-pane:" + tool.rawValue)
                    .help("Drag onto another pane header to swap positions")
                Spacer(minLength: 0)
                if tool == .phone { PhoneTargetMenu(desk: desk) }
                Menu {
                    Button("Open in New Window") { desk.popOut(tool, project: project) }
                    Divider()
                    ForEach(DeskLayout.Edge.allCases, id: \.self) { edge in
                        Menu("Move " + edge.rawValue + " of") {
                            ForEach(DeskTool.allCases.filter { $0 != tool }, id: \.self) { other in
                                Button(other.rawValue) { desk.layout.move(tool, beside: other, edge: edge); desk.expanded = nil }
                            }
                        }
                    }
                    Divider()
                    Button("Hide Pane") { desk.setVisible(tool, false, project: project) }
                        .disabled(desk.layout.columns.flatMap(\.tools).count == 1)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Pane options")
                Button { desk.popOut(tool, project: project) } label: { Image(systemName: "macwindow.badge.plus") }
                    .buttonStyle(.plain).help("Open in a new window, e.g. on another screen (⌥⌘N)")
                Button { desk.expanded = isExpanded ? nil : tool } label: {
                    Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }.buttonStyle(.plain).help(isExpanded ? "Show all panes (⇧⌘↩)" : "Expand pane (⇧⌘↩)")
            }.padding(.horizontal, 7).frame(height: 27)
                .background(desk.highlighted == tool ? Color.accentColor.opacity(0.3)
                            : showsFocus ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                .dropDestination(for: String.self) { items, _ in
                    guard let value = items.first, value.hasPrefix("workbench-pane:"),
                          let source = DeskTool(rawValue: String(value.dropFirst(15))), source != tool else { return false }
                    desk.layout.swap(source, tool); return true
                } isTargeted: { over in if over { desk.highlighted = tool } else if desk.highlighted == tool { desk.highlighted = nil } }
            DeskPaneContent(tool: tool, project: project)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
        .background(DeskPaneMarker(tool: tool, desk: desk))
        .overlay { if showsFocus { Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5).allowsHitTesting(false) } }
    }
}

/// The live contents of a Live Desk pane, shared by the grid and popped-out windows.
struct DeskPaneContent: View {
    let tool: DeskTool
    @ObservedObject var project: Project
    @ObservedObject private var desk: DeskState
    @ObservedObject private var targets: TestTargets

    init(tool: DeskTool, project: Project) {
        self.tool = tool
        self.project = project
        _desk = ObservedObject(wrappedValue: project.desk)
        _targets = ObservedObject(wrappedValue: project.targets)
    }

    var body: some View {
        switch tool {
        case .chat: ChatPane(console: project.chat).id(project.folder)
        case .phone:
            if desk.mobileWeb {
                PhoneSimulatorFrame(activeDeviceUDID: $project.simulatorUDID, mobileBrowser: targets.phone,
                                    sharedAddress: true, webRequest: desk.previewRequest)
            } else { SimulatorPane(active: $project.simulatorUDID) }
        case .web: BrowserPane(browser: targets.web)
        case .shell: TerminalGroup(sessions: project.terminals, folder: project.folder)
        case .cases: TestCasesPane(store: project.testCases).id(project.folder)
        }
    }
}

/// iOS Simulator vs Mobile Web for the phone pane.
struct PhoneTargetMenu: View {
    @ObservedObject var desk: DeskState
    var body: some View {
        Menu {
            Button("iOS Simulator") { desk.mobileWeb = false }
            Button("Mobile Web") { desk.mobileWeb = true }
        } label: { Image(systemName: desk.mobileWeb ? "globe" : "iphone") }
        .menuStyle(.borderlessButton).fixedSize().help("Choose phone target")
    }
}

private struct DeskDivider: View {
    let vertical: Bool
    let space: CGFloat
    let minimum: CGFloat
    let index: Int
    let weights: [Double]
    let set: ((Double, Double)) -> Void
    @State private var start: [Double]?
    var body: some View {
        Rectangle().fill(.quaternary).frame(width: vertical ? 5 : nil, height: vertical ? nil : 5)
            .contentShape(Rectangle()).onHover { over in
                if over { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let initial = start ?? weights
                    start = initial
                    let extent = space - CGFloat(initial.count - 1) * 5 - minimum * CGFloat(initial.count)
                    guard extent > 1 else { return }
                    let delta = vertical ? drag.translation.width : drag.translation.height
                    let sum = initial[index] + initial[index + 1]
                    let value = min(sum - 0.001, max(0.001, initial[index] + delta * initial.reduce(0,+) / extent))
                    set((value, sum - value))
                }.onEnded { _ in start = nil })
    }
}

private struct LocalPreviewButton: View {
    @ObservedObject var sessions: TerminalSessions
    let open: (URL) -> Void
    var body: some View {
        if let latest = sessions.previewLinks.first {
            Menu {
                Section("Local URLs from terminal output") {
                    ForEach(sessions.previewLinks.indices, id: \.self) { index in
                        let link = sessions.previewLinks[index]
                        Button("zsh " + String(link.shellNumber) + " · " + link.url.absoluteString) { open(link.url) }
                    }
                }
            } label: {
                Label("Preview :" + String(latest.url.port ?? (latest.url.scheme == "https" ? 443 : 80)),
                      systemImage: "play.rectangle")
            } primaryAction: { open(latest.url) }
            .fixedSize().help("Open " + latest.url.absoluteString + " in both previews")
        }
    }
}
