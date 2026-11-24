import SwiftUI
import AppKit

struct PaneBar<Actions: View>: View {
    let title: String
    let icon: String
    var iconColor: Color? = nil
    @ViewBuilder var actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor ?? Color.accentColor)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer()
            actions()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                .frame(height: 1)
        }
        .controlSize(.small)
    }
}

struct Entry: Identifiable {
    let url: URL
    var id: URL { url }
    var directory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map {
            $0.isDirectory == true && $0.isSymbolicLink != true
        } ?? false
    }
    var children: [Entry]? { directory ? Self.list(url) : nil }
    
    static func list(_ folder: URL) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.map(Entry.init).sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
}

final class EditorDocument: ObservableObject, Identifiable {
    let id: URL
    @Published var buffer: String
    @Published var saved: String
    @Published var cursorLine: Int = 1
    @Published var cursorColumn: Int = 1
    @Published var fontSize: CGFloat = 13.0
    
    var dirty: Bool { buffer != saved }
    lazy var language: SyntaxLanguage = SyntaxLanguage.detect(for: id)
    lazy var editor = NSTextView.scrollablePlainDocumentContentTextView()
    weak var ruler: LineNumberRulerView?

    init(url: URL, text: String) {
        id = url
        buffer = text
        saved = text
    }

    var lineCount: Int {
        buffer.components(separatedBy: "\n").count
    }
}

final class Project: ObservableObject {
    @Published var folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath) {
        didSet { if folder != oldValue { cachedChat = nil } }
    }
    private var cachedChat: ChatConsole?
    var chat: ChatConsole {
        if let cachedChat { return cachedChat }
        let console = ChatConsole(folder: folder)
        cachedChat = console
        return console
    }
    @Published var hasFolder = false
    @Published var quickOpen = false
    @Published var whatsNew = false
    @Published var layout: PaneLayout = {
        if let data = UserDefaults.standard.data(forKey: "paneLayout"),
           let layout = try? JSONDecoder().decode(PaneLayout.self, from: data) { return layout }
        var layout = PaneLayout()
        if UserDefaults.standard.object(forKey: "showFiles") as? Bool == false { layout.remove(.files) }
        if UserDefaults.standard.object(forKey: "showShell") as? Bool == false { layout.remove(.terminal) }
        return layout
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: "paneLayout") }
    }
    @Published var viewMode = WorkspaceViewMode(stored: UserDefaults.standard.string(forKey: "workspaceViewMode")) {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "workspaceViewMode") }
    }
    @Published var agent = ClaudeAgentState()
    @Published var focusMode = false
    @Published var documents: [EditorDocument] = []
    @Published var selected: URL?
    @Published var entries: [Entry] = []
    @Published var gitBranch: String? = nil
    @Published var gitStatuses: [String: GitStatusType] = [:]
    
    let terminals = TerminalSessions()
    var active: EditorDocument? { documents.first { $0.id == selected } }

    init() {
        let fm = FileManager.default
        let previous = UserDefaults.standard.string(forKey: "projectFolder")
        var directory: ObjCBool = false
        if let previous, fm.fileExists(atPath: previous, isDirectory: &directory), directory.boolValue {
            folder = URL(fileURLWithPath: previous)
            hasFolder = true
        } else if folder.path != "/" {
            hasFolder = true
        } else {
            folder = fm.homeDirectoryForCurrentUser
        }
        if hasFolder { reload() }
        terminals.add(in: folder)
    }

    func showQuickOpen() {
        if !hasFolder { chooseFolder() }
        if hasFolder { quickOpen = true }
    }

    func newFile(at folderURL: URL? = nil) {
        let targetFolder = folderURL ?? folder
        let panel = NSSavePanel()
        panel.directoryURL = targetFolder
        panel.nameFieldStringValue = "untitled.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            if !hasFolder {
                folder = url.deletingLastPathComponent()
                hasFolder = true
                UserDefaults.standard.set(folder.path, forKey: "projectFolder")
                terminals.reset(in: folder)
            }
            reload()
            open(url)
        } catch { alert(error.localizedDescription) }
    }

    func newFolder(at folderURL: URL? = nil) {
        let targetFolder = folderURL ?? folder
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the new folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = "NewFolder"
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let newURL = targetFolder.appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
                reload()
            }
        }
    }

    func delete(url: URL) {
        let alert = NSAlert()
        alert.messageText = "Delete " + url.lastPathComponent + "?"
        alert.informativeText = "This action will move the item to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if let doc = documents.first(where: { $0.id == url }) {
                close(doc)
            }
            reload()
        }
    }

    func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func reload() {
        entries = Entry.list(folder)
        refreshGit()
    }

    func refreshGit() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let branch = GitManager.currentBranch(in: self.folder)
            let statuses = GitManager.fileStatuses(in: self.folder)
            DispatchQueue.main.async {
                self.gitBranch = branch
                self.gitStatuses = statuses
            }
        }
    }

    func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }

    func canLeave() -> Bool {
        documents.allSatisfy(canClose)
    }

    private func canClose(_ doc: EditorDocument) -> Bool {
        guard doc.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to " + doc.id.lastPathComponent + "?"
        alert.informativeText = doc.id.path
        ["Save", "Cancel", "Discard"].forEach { alert.addButton(withTitle: $0) }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(doc)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    @discardableResult func save(_ doc: EditorDocument) -> Bool {
        do {
            let disk = try String(contentsOf: doc.id, encoding: .utf8)
            if disk != doc.saved {
                let confirm = NSAlert()
                confirm.messageText = "Overwrite changes on disk to " + doc.id.lastPathComponent + "?"
                confirm.addButton(withTitle: "Cancel")
                confirm.addButton(withTitle: "Overwrite")
                guard confirm.runModal() == .alertSecondButtonReturn else { return false }
            }
            try doc.buffer.write(to: doc.id, atomically: true, encoding: .utf8)
            doc.saved = doc.buffer
            refreshGit()
            return true
        } catch {
            alert(error.localizedDescription)
            return false
        }
    }

    func open(_ url: URL) {
        viewMode = .develop
        layout.show(.editor)
        if documents.contains(where: { $0.id == url }) {
            selected = url
            return
        }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 4_000_000 else {
                alert("The editor supports text files up to 4 MB.")
                return
            }
            let value = try String(contentsOf: url, encoding: .utf8)
            guard !value.contains("\u{0}") else {
                alert("Choose a UTF-8 text file.")
                return
            }
            documents.append(EditorDocument(url: url, text: value))
            selected = url
        } catch {
            alert(error.localizedDescription)
        }
    }

    func cycleTab(_ delta: Int) {
        guard !documents.isEmpty, let index = documents.firstIndex(where: { $0.id == selected }) else { return }
        selected = documents[(index + delta + documents.count) % documents.count].id
    }

    func close(_ doc: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == doc.id }), canClose(doc) else { return }
        documents.remove(at: index)
        if selected == doc.id {
            selected = documents.dropFirst(index).first?.id ?? documents.last?.id
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let next = panel.url, (next != folder || !hasFolder), canLeave() else { return }
        documents.removeAll()
        selected = nil
        agent = ClaudeAgentState()
        folder = next
        hasFolder = true
        reload()
        UserDefaults.standard.set(next.path, forKey: "projectFolder")
        terminals.reset(in: folder)
    }

    func zoom(in isZoomIn: Bool) {
        guard let active = active else { return }
        if isZoomIn {
            active.fontSize = min(28, active.fontSize + 1)
        } else {
            active.fontSize = max(9, active.fontSize - 1)
        }
    }

    func zoomReset() {
        active?.fontSize = 13.0
    }
}

struct FileTab: View {
    @ObservedObject var document: EditorDocument
    let project: Project
    let selected: Bool
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let presentation = WorkbenchTheme.filePresentation(for: document.id.lastPathComponent, isDirectory: false)
        
        HStack(spacing: 6) {
            // File Icon with vibrant color
            Image(systemName: presentation.icon)
                .font(.system(size: 11))
                .foregroundStyle(presentation.color)

            // File Name
            Button {
                project.selected = document.id
            } label: {
                Text(document.id.lastPathComponent)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? (colorScheme == .dark ? Color.white : Color.black) : Color.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            // Dirty status dot
            if document.dirty {
                Circle()
                    .fill(Color(red: 1.0, green: 0.6, blue: 0.2))
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }

            // Close Tab Button
            Button {
                project.close(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHovering || selected ? Color.primary : Color.secondary.opacity(0.5))
                    .padding(2)
                    .background(isHovering ? Color.secondary.opacity(0.2) : Color.clear, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close " + document.id.lastPathComponent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            selected ? (colorScheme == .dark ? WorkbenchTheme.darkElevated : WorkbenchTheme.lightElevated)
                     : Color.clear
        )
        .overlay(alignment: .bottom) {
            if selected {
                Rectangle()
                    .fill(WorkbenchTheme.toolColor(.editor))
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                .frame(width: 1)
        }
        .onHover { isHovering = $0 }
        .help(document.id.path)
    }
}

struct DocumentPane: View {
    @ObservedObject var document: EditorDocument
    let project: Project
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let relativePath = document.id.pathComponents.dropFirst(project.folder.pathComponents.count).joined(separator: " › ")
        let presentation = WorkbenchTheme.filePresentation(for: document.id.lastPathComponent, isDirectory: false)

        VStack(spacing: 0) {
            // Breadcrumb bar
            HStack(spacing: 8) {
                Image(systemName: presentation.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(presentation.color)

                Text(relativePath.isEmpty ? document.id.lastPathComponent : relativePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button("Save") {
                    project.save(document)
                }
                .controlSize(.small)
                .disabled(!document.dirty)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                    .frame(height: 1)
            }

            // Highlighting Code Editor
            CodeEditor(document: document, isDark: colorScheme == .dark)

            // Developer Status Bar
            HStack(spacing: 14) {
                // Cursor position
                HStack(spacing: 4) {
                    Image(systemName: "character.cursor.ibeam")
                    Text("Ln \(document.cursorLine), Col \(document.cursorColumn)")
                }
                
                // Line count & chars
                Text("\(document.lineCount) lines · \(document.buffer.count) chars")

                Spacer()

                // Language
                HStack(spacing: 4) {
                    Circle()
                        .fill(presentation.color)
                        .frame(width: 6, height: 6)
                    Text(document.language.rawValue)
                }

                // Encoding
                Text("UTF-8")

                // Zoom control
                HStack(spacing: 4) {
                    Button {
                        project.zoom(in: false)
                    } label: {
                        Image(systemName: "minus")
                    }.buttonStyle(.plain)

                    Text("\(Int(document.fontSize))pt")
                        .font(.system(size: 10, design: .monospaced))

                    Button {
                        project.zoom(in: true)
                    } label: {
                        Image(systemName: "plus")
                    }.buttonStyle(.plain)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                    .frame(height: 1)
            }
        }
    }
}

/// Standard About panel. Version comes from Info.plist, which `scripts/build-app.sh` fills from
/// the repo's VERSION file; under `swift run` there is no plist, so it reads "dev".
enum AboutPanel {
    // Public repo; also used by the Help menu. Keep in sync with README links and
    // .github/ISSUE_TEMPLATE/config.yml if the repo moves.
    static let repository = URL(string: "https://github.com/aradhyadengree/workbench")!

    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let credits = NSMutableAttributedString(
            string: "A native macOS workspace for testing products across web and iOS.\n\nOpen source under the MIT License.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: repository.absoluteString,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: repository]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Workbench",
            .applicationVersion: info["CFBundleShortVersionString"] as? String ?? "dev",
            .version: info["CFBundleVersion"] as? String ?? "",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class Lifecycle: NSObject, NSApplicationDelegate {
    // Migration must run before Project() reads its saved layout, folder and modes.
    let project: Project = { migrateLegacyDefaults(); return Project() }()

    /// Builds before 0.12.0 used the bundle id "local.workbench.ide", so their settings live in
    /// that defaults domain. Copy them over once; never overwrite anything already saved.
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != "local.workbench.ide",
              !defaults.bool(forKey: "migratedLegacyDefaults"),
              let legacy = defaults.persistentDomain(forName: "local.workbench.ide") else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: "migratedLegacyDefaults")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        project.canLeave() ? .terminateNow : .terminateCancel
    }
}

struct CloseGuard: NSViewRepresentable {
    final class Observer: NSView {
        static weak var workspaceWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { Self.workspaceWindow = window }
            window?.standardWindowButton(.closeButton)?.target = self
            window?.standardWindowButton(.closeButton)?.action = #selector(closeWorkspace)
        }
        @objc func closeWorkspace() { NSApp.terminate(nil) }
    }
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {}
}

@main struct WorkbenchApp: App {
    @NSApplicationDelegateAdaptor(Lifecycle.self) var lifecycle
    
    var body: some Scene {
        Window("Workbench", id: "workspace") {
            Workspace(project: lifecycle.project)
                .background(CloseGuard())
                .frame(minWidth: 700, minHeight: 430)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Workbench") { AboutPanel.show() }
            }
            CommandGroup(replacing: .help) {
                Button("What's New in Workbench") { lifecycle.project.whatsNew = true }
                Divider()
                Button("Workbench on GitHub") { NSWorkspace.shared.open(AboutPanel.repository) }
                Button("Report an Issue…") { NSWorkspace.shared.open(AboutPanel.repository.appendingPathComponent("issues/new/choose")) }
            }
            CommandMenu("Workspace") {
                Button("Toggle Files Pane") {
                    let project = lifecycle.project
                    project.viewMode = .develop
                    project.focusMode = false
                    if project.layout.index(of: .files) != nil { project.layout.remove(.files) }
                    else { project.layout.show(.files) }
                }.keyboardShortcut("b")

                Button("Toggle Terminal Pane") {
                    let project = lifecycle.project
                    project.viewMode = .develop
                    project.focusMode = false
                    if project.layout.index(of: .terminal) != nil { project.layout.remove(.terminal) }
                    else { project.layout.show(.terminal) }
                }.keyboardShortcut("`", modifiers: .control)

                Button("Quick Open File…") {
                    lifecycle.project.showQuickOpen()
                }.keyboardShortcut("p")

                Button("Focus Editor") {
                    lifecycle.project.viewMode = .develop
                    lifecycle.project.focusMode.toggle()
                }.keyboardShortcut("f", modifiers: [.command, .option])

                Button("Find in File…") {
                    guard let scroll = lifecycle.project.active?.editor,
                          let text = scroll.documentView as? NSTextView else { return }
                    lifecycle.project.viewMode = .develop
                    if text.window == nil { lifecycle.project.focusMode = true }
                    DispatchQueue.main.async {
                        text.window?.makeFirstResponder(text)
                        let item = NSMenuItem()
                        item.tag = NSTextFinder.Action.showFindInterface.rawValue
                        text.performTextFinderAction(item)
                    }
                }.keyboardShortcut("f")

                Button("Next File Tab") {
                    lifecycle.project.cycleTab(1)
                }.keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous File Tab") {
                    lifecycle.project.cycleTab(-1)
                }.keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                Button("Zoom In") {
                    lifecycle.project.zoom(in: true)
                }.keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    lifecycle.project.zoom(in: false)
                }.keyboardShortcut("-", modifiers: .command)

                Button("Reset Zoom") {
                    lifecycle.project.zoomReset()
                }.keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("New Terminal") {
                    if !lifecycle.project.hasFolder { lifecycle.project.chooseFolder(); return }
                    lifecycle.project.viewMode = .develop
                    lifecycle.project.focusMode = false
                    lifecycle.project.layout.show(.terminal)
                    lifecycle.project.terminals.add(in: lifecycle.project.folder)
                }.keyboardShortcut("t", modifiers: [.control, .shift])

                Button("Clear Terminal") {
                    lifecycle.project.terminals.active?.clear()
                }.keyboardShortcut("k", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    if let active = lifecycle.project.active { lifecycle.project.save(active) }
                }.keyboardShortcut("s")
            }

            CommandGroup(after: .newItem) {
                Button("New File…") { lifecycle.project.newFile() }.keyboardShortcut("n")
                Button("Open Folder…") { lifecycle.project.chooseFolder() }.keyboardShortcut("o")
                Button("Close Tab") {
                    if let window = NSApp.keyWindow, window !== CloseGuard.Observer.workspaceWindow {
                        window.performClose(nil); return
                    }
                    if let active = lifecycle.project.active { lifecycle.project.close(active) }
                    else { NSApp.terminate(nil) }
                }.keyboardShortcut("w")
            }
        }
        WindowGroup("Preview", for: PreviewWindowID.self) { $request in
            if let request { PreviewWindow(tool: request.tool).navigationTitle(request.tool.rawValue) }
        }.defaultSize(width: 520, height: 620)
    }
}
