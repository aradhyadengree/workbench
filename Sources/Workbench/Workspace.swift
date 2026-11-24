import SwiftUI

/// Top-level modes in the toolbar picker. Raw values are persisted under "workspaceViewMode",
/// so they stay stable identifiers; change `title` to rename a mode in the UI.
enum WorkspaceViewMode: String, CaseIterable {
    case quad, develop, test

    var title: String {
        switch self {
        case .quad: "Live Desk"
        case .develop: "Develop"
        case .test: "Test Studio"
        }
    }

    /// Reads the saved mode, also accepting the display names that earlier builds stored.
    init(stored: String?) {
        let legacy = ["Claude Quad": Self.quad, "Develop": .develop, "Test Studio": .test]
        self = stored.flatMap { Self(rawValue: $0) ?? legacy[$0] } ?? .quad
    }
}

struct Workspace: View {
    @ObservedObject var project: Project
    @StateObject private var browser = Browser()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var targets = TestTargets()
    @State private var simulatorID = ""
    @State private var fileFilter = ""
    private var viewMode: WorkspaceViewMode { project.viewMode }

    // MARK: - Filtered File Tree
    private var filteredEntries: [Entry] {
        let query = fileFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return project.entries }
        
        func match(_ entry: Entry) -> Entry? {
            if entry.url.lastPathComponent.lowercased().contains(query) {
                return entry
            }
            if entry.directory, let children = entry.children {
                let filtered = children.compactMap(match)
                if !filtered.isEmpty {
                    return Entry(url: entry.url)
                }
            }
            return nil
        }
        
        return project.entries.compactMap(match)
    }

    // MARK: - Sidebar View
    private var sidebar: some View {
        VStack(spacing: 0) {
            PaneBar(title: "Files", icon: "folder", iconColor: WorkbenchTheme.toolColor(.files)) {
                HStack(spacing: 4) {
                    Button { project.newFile() } label: {
                        Image(systemName: "plus")
                    }.help("New File (⌘N)")

                    Button { project.newFolder() } label: {
                        Image(systemName: "folder.badge.plus")
                    }.help("New Folder")

                    Button { project.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("Refresh files")
                }
            }

            // Quick file filter field
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Filter files…", text: $fileFilter)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !fileFilter.isEmpty {
                    Button { fileFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(colorScheme == .dark ? WorkbenchTheme.darkElevated : WorkbenchTheme.lightElevated)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                    .frame(height: 1)
            }

            // File list with colored language icons & git badges
            List(filteredEntries, children: \.children) { entry in
                let presentation = WorkbenchTheme.filePresentation(
                    for: entry.url.lastPathComponent,
                    isDirectory: entry.directory
                )
                let relativePath = entry.url.pathComponents.dropFirst(project.folder.pathComponents.count).joined(separator: "/")
                let gitStatus = project.gitStatuses[relativePath]
                let isSelected = project.selected == entry.url

                Button {
                    if !entry.directory { project.open(entry.url) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: presentation.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(presentation.color)

                        Text(entry.url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

                        Spacer()

                        // Git Status Badge
                        if let status = gitStatus {
                            Text(status.rawValue)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    (status == .modified ? Color.orange :
                                     status == .untracked ? Color.green :
                                     status == .staged ? Color.cyan : Color.red).opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 3)
                                )
                                .foregroundStyle(
                                    status == .modified ? Color.orange :
                                    status == .untracked ? Color.green :
                                    status == .staged ? Color.cyan : Color.red
                                )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("New File Here…") { project.newFile(at: entry.directory ? entry.url : entry.url.deletingLastPathComponent()) }
                    Button("New Folder Here…") { project.newFolder(at: entry.directory ? entry.url : entry.url.deletingLastPathComponent()) }
                    Divider()
                    Button("Reveal in Finder") { project.revealInFinder(url: entry.url) }
                    Button("Copy Relative Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(relativePath, forType: .string)
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { project.delete(url: entry.url) }
                }
            }
            .listStyle(.sidebar)
        }
        .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
    }

    // MARK: - Editor View
    private var editor: some View {
        VStack(spacing: 0) {
            if let active = project.active {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(project.documents) { doc in
                                FileTab(document: doc, project: project, selected: project.selected == doc.id)
                                    .draggable("file:" + doc.id.path)
                                    .dropDestination(for: String.self) { values, _ in
                                        guard let path = values.first, path.hasPrefix("file:"),
                                              let from = project.documents.firstIndex(where: { $0.id.path == String(path.dropFirst(5)) }),
                                              let to = project.documents.firstIndex(where: { $0.id == doc.id }) else { return false }
                                        project.documents.move(fromOffsets: IndexSet(integer: from), toOffset: from < to ? to + 1 : to)
                                        return true
                                    }.id(doc.id)
                            }
                        }
                    }
                    .frame(height: 32)
                    .scrollIndicators(.hidden)
                    .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                            .frame(height: 1)
                    }
                    .onChange(of: project.selected, initial: true) { proxy.scrollTo(project.selected) }
                }
                DocumentPane(document: active, project: project).id(active.id)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 36))
                            .foregroundStyle(WorkbenchTheme.toolColor(.editor))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.hasFolder ? project.folder.lastPathComponent : "Workbench IDE")
                                .font(.system(size: 24, weight: .bold))
                            Text(project.hasFolder ? project.folder.path : "Lightweight, developer-friendly workspace")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Divider().frame(maxWidth: 360)

                    HStack(spacing: 12) {
                        Button {
                            if project.hasFolder { project.showQuickOpen() } else { project.chooseFolder() }
                        } label: {
                            Label(project.hasFolder ? "Quick Open (⌘P)" : "Open Project Folder…", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WorkbenchTheme.toolColor(.editor))

                        if project.hasFolder {
                            Button("New File (⌘N)") { project.newFile() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
            }
        }
    }

    @ViewBuilder private func content(_ tool: ToolTab) -> some View {
        switch tool {
        case .claude: ClaudeAgentPane(state: project.agent, folder: project.folder) { project.reload() }
        case .editor: editor
        case .files: sidebar
        case .terminal: TerminalGroup(sessions: project.terminals, folder: project.folder)
        case .browser: BrowserPane(browser: browser)
        case .simulator: PhoneSimulatorFrame(activeDeviceUDID: $simulatorID, mobileBrowser: targets.phone)
        }
    }

    private func accept(_ values: [String], in group: PaneGroup, before anchor: ToolTab? = nil) -> Bool {
        guard let value = values.first, value.hasPrefix("tool:"),
              let tool = ToolTab(rawValue: String(value.dropFirst(5))),
              project.layout.index(of: tool) != nil else { return false }
        project.layout.move(tool, into: group.id, before: anchor)
        return true
    }

    private func pane(_ group: PaneGroup) -> some View {
        VStack(spacing: 0) {
            // Pane Tab Header
            HStack(spacing: 4) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(group.tabs, id: \.self) { tool in
                            let isSelected = group.selected == tool
                            let color = WorkbenchTheme.toolColor(tool)
                            Button {
                                project.layout.show(tool)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: tool.icon)
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(color)
                                    Text(tool.rawValue)
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                }
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    isSelected ? color.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                            .buttonStyle(.plain)
                            .draggable("tool:" + tool.rawValue)
                            .dropDestination(for: String.self) { values, _ in accept(values, in: group, before: tool) }
                        }
                    }
                }.scrollIndicators(.hidden)

                Spacer()

                Menu {
                    Menu("Add Tab") {
                        ForEach(ToolTab.allCases, id: \.self) { tool in
                            Button(tool.rawValue) { project.layout.move(tool, into: group.id) }
                        }
                    }
                    if group.tabs.count > 1 {
                        Button("Split Selected Tab into Pane") { project.layout.split(group.selected) }
                    }
                    Menu("Move Tab to Pane") {
                        ForEach(project.layout.groups.filter { $0.id != group.id }) { target in
                            Button(target.tabs.map(\.rawValue).joined(separator: " / ")) {
                                project.layout.move(group.selected, into: target.id)
                            }
                        }
                    }.disabled(project.layout.groups.count < 2)
                    Button("Move Pane Earlier") { project.layout.shift(group.id, by: -1) }
                        .disabled(project.layout.groups.first?.id == group.id)
                    Button("Move Pane Later") { project.layout.shift(group.id, by: 1) }
                        .disabled(project.layout.groups.last?.id == group.id)
                    Divider()
                    Button("Close Pane") { for tool in group.tabs { project.layout.remove(tool) } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Arrange pane")

                Button { project.layout.remove(group.selected) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close selected tool tab")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(height: 29)
            .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                    .frame(height: 1)
            }
            .dropDestination(for: String.self) { values, _ in accept(values, in: group) }

            content(group.selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
        .overlay {
            Rectangle()
                .stroke(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder, lineWidth: 1)
        }
        .clipped()
    }

    private func show(_ tool: ToolTab) {
        project.focusMode = false
        project.layout.show(tool)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch viewMode {
            case .quad:
                // Live Desk: chat, phone, browser and shell side by side
                QuadWorkspace(project: project, targets: targets, simulatorUDID: $simulatorID)
            case .develop:
                GeometryReader { bounds in
                    if project.focusMode {
                        editor
                    } else if project.layout.groups.isEmpty {
                        ContentUnavailableView {
                            Label("Workspace is empty", systemImage: "rectangle.split.2x1")
                        } actions: {
                            Button("Open Editor") { show(.editor) }
                        }
                    } else {
                        let frames = PaneFrames(layout: project.layout, size: bounds.size)
                        ZStack(alignment: .topLeading) {
                            ForEach(project.layout.groups) { group in
                                if let r = frames.panes[group.id] {
                                    pane(group)
                                        .frame(width: r.width, height: r.height)
                                        .position(x: r.midX, y: r.midY)
                                }
                            }
                            ForEach(frames.dividers) { line in
                                ResizeHandle(line: line) { project.layout.shares[line.id] = $0 }
                                    .frame(width: line.rect.width, height: line.rect.height)
                                    .position(x: line.rect.midX, y: line.rect.midY)
                            }
                        }
                        .frame(width: bounds.size.width, height: bounds.size.height)
                    }
                }
            case .test:
                TestStudio(
                    web: targets.web,
                    phone: targets.phone,
                    device: $simulatorID,
                    storageKey: "productTests." + project.folder.path
                ).id(project.folder)
            }

            // Global Workspace Status Bar
            if viewMode != .test && !project.focusMode {
                HStack(spacing: 12) {
                    // Git branch badge
                    if let branch = project.gitBranch {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundStyle(WorkbenchTheme.toolColor(.editor))
                            Text(branch)
                                .fontWeight(.medium)
                            if !project.gitStatuses.isEmpty {
                                Text("\(project.gitStatuses.count) modified")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Spacer()

                    // Quick layout restore
                    if viewMode == .develop {
                        Button {
                            project.layout = PaneLayout()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.split.3x1")
                                Text("Default Layout")
                            }
                        }.buttonStyle(.plain)

                        // Focus Editor toggle
                        Button {
                            project.focusMode.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                Text("Focus")
                            }
                        }.buttonStyle(.plain)
                    }

                    Button { project.whatsNew = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("Workbench " + WhatsNew.currentVersion)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("What's new in this version")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                        .frame(height: 1)
                }
            }
        }
        .onChange(of: project.folder) {
            targets.reset()
            project.refreshGit()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Open Folder…") { project.chooseFolder() }
                        Button("Reload Workspace") { project.reload() }
                        Divider()
                        Text(project.folder.path).font(.caption).foregroundStyle(.secondary)
                    } label: {
                        HStack(spacing: 4) {
                            Text(project.hasFolder ? project.folder.lastPathComponent.uppercased() : "WORKBENCH")
                                .font(.system(size: 12, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            ToolbarItemGroup(placement: .principal) {
                // Workspace Mode Selector matching screenshot
                Picker("Workspace View", selection: $project.viewMode) {
                    ForEach(WorkspaceViewMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button("Quick Open (⌘P)", systemImage: "magnifyingglass") {
                    project.showQuickOpen()
                }

                Button("Open Folder", systemImage: "folder.badge.plus") {
                    project.chooseFolder()
                }
            }
        }
        .sheet(isPresented: $project.quickOpen) { QuickOpen(project: project) { show(.editor) } }
        .sheet(isPresented: $project.whatsNew) { WhatsNew { project.whatsNew = false } }
        .task {
            // A sheet requested before the window is on screen is silently dropped, so wait a beat.
            try? await Task.sleep(for: .milliseconds(700))
            if WhatsNew.shouldShowOnLaunch { project.whatsNew = true }
        }
    }
}

private struct ResizeHandle: View {
    let line: PaneFrames.DividerLine
    let set: (CGFloat) -> Void
    @State private var initial: CGFloat?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor.opacity(0.8) : (colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder))
            .contentShape(Rectangle())
            .onHover { inside in
                isHovering = inside
                if inside {
                    (line.across ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { event in
                        let start = initial ?? line.share
                        initial = start
                        let change = line.across ? event.translation.width : event.translation.height
                        set(min(0.95, max(0.05, start + change / max(1, line.extent))))
                    }
                    .onEnded { _ in initial = nil }
            )
    }
}

struct PreviewWindowID: Codable, Hashable {
    let tool: ToolTab
    var id = UUID()
}

struct PreviewWindow: View {
    let tool: ToolTab
    @StateObject private var browser = Browser()
    @State private var device = ""
    var body: some View {
        Group {
            if tool == .browser { BrowserPane(browser: browser) }
            else { PhoneSimulatorFrame(activeDeviceUDID: $device, mobileBrowser: browser) }
        }.frame(minWidth: 300, minHeight: 250)
    }
}
