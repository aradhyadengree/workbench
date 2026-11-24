import SwiftUI

struct QuadWorkspace: View {
    @ObservedObject var project: Project
    @ObservedObject var targets: TestTargets
    @Binding var simulatorUDID: String
    @State private var address = ""
    @State private var previewRequest = UUID()
    @State private var mobileWeb = false
    @State private var focused: DeskTool?
    @State private var highlighted: DeskTool?
    @State private var layout = (UserDefaults.standard.data(forKey: "deskLayout")
        .flatMap { try? JSONDecoder().decode(DeskLayout.self, from: $0) }) ?? DeskLayout()

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
                    focused = nil
                }
                Menu("Layout") {
                    if focused != nil { Button("Show All Panes") { focused = nil } }
                    Button("Restore Photo Layout") { layout = DeskLayout(); focused = nil }
                }.fixedSize()
            }.padding(7)
            Divider()
            if let focused { pane(focused) }
            else {
                GeometryReader { geo in
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
                                            layout.heights[tool] = pair.0
                                            layout.heights[column.tools[row + 1]] = pair.1
                                        }
                                    }
                                }
                            }.frame(width: widths[index])
                            if index + 1 < layout.columns.count {
                                DeskDivider(vertical: true, space: geo.size.width, minimum: 164, index: index,
                                            weights: layout.columns.map(\.width)) { pair in
                                    layout.columns[index].width = pair.0
                                    layout.columns[index + 1].width = pair.1
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { address = targets.web.address }
        .onChange(of: project.folder) { address = ""; simulatorUDID = "" }
        .onChange(of: layout) { save() }
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: "deskLayout") }
    private func load() {
        targets.web.address = address; targets.web.go()
        targets.phone.address = address; targets.phone.go()
        previewRequest = UUID()
        mobileWeb = true
    }

    private func pane(_ tool: DeskTool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Label(tool.rawValue, systemImage: "line.3.horizontal")
                    .font(.caption.bold()).lineLimit(1)
                    .draggable("workbench-pane:" + tool.rawValue)
                    .help("Drag onto another pane header to swap positions")
                Spacer(minLength: 0)
                if tool == .phone {
                    Menu {
                        Button("iOS Simulator") { mobileWeb = false }
                        Button("Mobile Web") { mobileWeb = true }
                    } label: { Image(systemName: mobileWeb ? "globe" : "iphone") }
                    .menuStyle(.borderlessButton).fixedSize().help("Choose phone target")
                }
                Menu {
                    ForEach(DeskLayout.Edge.allCases, id: \.self) { edge in
                        Menu("Move " + edge.rawValue + " of") {
                            ForEach(DeskTool.allCases.filter { $0 != tool }, id: \.self) { other in
                                Button(other.rawValue) { layout.move(tool, beside: other, edge: edge); focused = nil }
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Move pane")
                Button { focused = focused == tool ? nil : tool } label: {
                    Image(systemName: focused == tool ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }.buttonStyle(.plain).help(focused == tool ? "Show all panes" : "Expand pane")
            }.padding(.horizontal, 7).frame(height: 27)
                .background(highlighted == tool ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12))
                .dropDestination(for: String.self) { items, _ in
                    guard let value = items.first, value.hasPrefix("workbench-pane:"),
                          let source = DeskTool(rawValue: String(value.dropFirst(15))), source != tool else { return false }
                    layout.swap(source, tool); return true
                } isTargeted: { over in if over { highlighted = tool } else if highlighted == tool { highlighted = nil } }
            switch tool {
            case .chat: ChatPane(console: project.chat).id(project.folder)
            case .phone:
                if mobileWeb { PhoneSimulatorFrame(activeDeviceUDID: $simulatorUDID, mobileBrowser: targets.phone, sharedAddress: true, webRequest: previewRequest) }
                else { SimulatorPane(active: $simulatorUDID) }
            case .web: BrowserPane(browser: targets.web)
            case .shell: TerminalGroup(sessions: project.terminals, folder: project.folder)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
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
