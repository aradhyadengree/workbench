import SwiftUI
import ShellPTY
import AppKit

// === SHELL: one PTY-backed login zsh shown in an xterm.js terminal ===

/// One terminal: a login zsh on a PTY, rendered by xterm.js (XTerm.swift), so it behaves like
/// Terminal.app (prompt themes, vim, Ctrl-R, colours). Output also passes through
/// LocalPreviewDetector, which feeds Live Desk's "Preview :port" button.
final class Shell: ObservableObject, Identifiable {
    let id = UUID()
    let number: Int
    let terminal = XTermPage()
    @Published private(set) var isRunning = false
    /// The shell ended (exit, crash or failed start); the pane offers Restart.
    @Published private(set) var exited = false
    var onLocalURL: ((URL) -> Void)?

    private var previewDetector = LocalPreviewDetector()
    private var reader: DispatchSourceRead?
    private var handle: FileHandle?
    /// Changes on every start/stop so callbacks from an old PTY are ignored.
    private var generation = UUID()
    private var masterFd: Int32 = -1
    private var pendingStart: UUID?
    private var folder: URL?
    /// The reader is suspended while xterm parses a chunk (backpressure). A suspended dispatch
    /// source must be resumed before it is cancelled or released, or libdispatch crashes.
    private var readerSuspended = false
    private let input = DispatchQueue(label: "workbench.shell.input")

    init(number: Int) {
        self.number = number
        terminal.onInput = { [weak self] data in self?.send(data) }
        terminal.onResize = { [weak self] columns, rows in self?.resize(columns: columns, rows: rows) }
    }

    /// Waits for the user's shell environment (see ShellEnvironment.swift) so the first shell
    /// already has their PATH; only the latest request runs if several arrive while waiting.
    func start(in folder: URL) {
        self.folder = folder
        let request = UUID()
        pendingStart = request
        ShellEnvironment.whenReady { [weak self] in
            guard let self, self.pendingStart == request else { return }
            self.pendingStart = nil
            self.spawn(in: folder)
        }
    }

    func restart() {
        guard let folder else { return }
        stop()
        terminal.write(Data("\r\n".utf8))
        start(in: folder)
    }

    private func spawn(in folder: URL) {
        generation = UUID()
        previewDetector = LocalPreviewDetector()
        exited = false
        var fd: Int32 = -1
        let pid = start_shell(folder.path, &fd, TerminalPaneRC.directory()?.path)
        guard pid > 0 else {
            terminal.write(Data("\u{1b}[31mCould not start zsh in \(folder.path)\u{1b}[0m\r\n".utf8))
            exited = true
            return
        }
        masterFd = fd
        isRunning = true
        resize_pty(fd, Int32(terminal.rows), Int32(terminal.columns))
        let token = generation
        let stream = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle = stream

        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.isRunning = false
            }
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader = source
        source.setCancelHandler { try? stream.close() }
        source.setEventHandler { [weak self] in
            guard let self, token == self.generation else { return }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { return }
            guard count > 0 else {
                self.terminal.write(Data("\r\n\u{1b}[33m[Shell exited]\u{1b}[0m\r\n".utf8))
                self.stop()
                self.exited = true
                return
            }
            for url in self.previewDetector.consume(bytes.prefix(count)) { self.onLocalURL?(url) }
            self.readerSuspended = true
            source.suspend()
            self.terminal.write(Data(bytes.prefix(count))) { [weak self] in
                guard let self, token == self.generation, self.readerSuspended else { return }
                self.readerSuspended = false
                source.resume()
            }
        }
        source.resume()
    }

    func stop() {
        pendingStart = nil
        generation = UUID()
        if readerSuspended { readerSuspended = false; reader?.resume() }
        reader?.cancel()
        reader = nil
        handle = nil
        isRunning = false
        masterFd = -1
    }

    /// Clears the visible screen and scrollback (⌘K).
    func clear() { terminal.clear() }

    func resize(columns: Int, rows: Int) {
        if masterFd > 0 { resize_pty(masterFd, Int32(rows), Int32(columns)) }
    }

    /// Types `command` into the shell and presses Return, as if the user had.
    func run(_ command: String) {
        send(Data((command + "\r").utf8))
        terminal.focus()
    }

    func send(_ data: Data) {
        guard let handle else { return }
        // A large paste can fill the PTY buffer; never block the main thread on it.
        input.async { try? handle.write(contentsOf: data) }
    }
}

// === SESSIONS: the shells, which one is focused, split state ===

struct TerminalLink: Equatable {
    let url: URL
    let shellNumber: Int
}

final class TerminalSessions: ObservableObject {
    @Published private(set) var previewLinks: [TerminalLink] = []
    @Published private(set) var shells: [Shell] = []
    /// The focused shell: toolbar buttons, ⌘K and the session picker act on it.
    @Published var selected: UUID? {
        didSet {
            // Picking a shell that isn't on screen while split swaps it into the focused slot.
            guard split.count > 1, let new = selected, !split.contains(new),
                  let old = oldValue, let slot = split.firstIndex(of: old) else { return }
            split[slot] = new
        }
    }
    /// Shells shown side by side or stacked (Split Terminal), in order. Fewer than two means
    /// the pane shows just the selected shell. Not persisted: shells don't survive a relaunch.
    @Published private(set) var split: [UUID] = []
    @Published var splitAxis = SplitAxis.columns
    enum SplitAxis { case columns, rows }
    static let maxSplits = 4
    private var nextNumber = 1
    
    var active: Shell? { shells.first { $0.id == selected } }
    var shown: [Shell] {
        split.count > 1 ? split.compactMap { id in shells.first { $0.id == id } } : active.map { [$0] } ?? []
    }

    /// Adds a new shell beside the focused one and focuses it.
    func splitActive(in folder: URL, axis: SplitAxis) {
        guard split.count < Self.maxSplits else { return }
        let current = selected ?? shells.last?.id
        let shell = add(in: folder, select: false)
        var ids = split.count > 1 ? split : [current].compactMap { $0 }
        let at = current.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? ids.count
        ids.insert(shell.id, at: at)
        if split.count < 2 { splitAxis = axis }
        split = ids          // before selecting, so the swap-into-slot rule above doesn't fire
        selected = shell.id
    }

    /// Back to one terminal; the other shells keep running and stay in the session picker.
    func unsplit() { split = [] }

    @discardableResult
    func add(in folder: URL, select: Bool = true) -> Shell {
        let shell = Shell(number: nextNumber)
        // Clicking into a terminal (a web view, so SwiftUI never sees the click) focuses it.
        let id = shell.id
        shell.terminal.onFocus = { [weak self] in if self?.selected != id { self?.selected = id } }
        nextNumber += 1
        let number = shell.number
        shell.onLocalURL = { [weak self] url in
            guard let self else { return }
            let link = TerminalLink(url: url, shellNumber: number)
            guard self.previewLinks.first != link else { return }
            self.previewLinks = Array(([link] + self.previewLinks.filter { $0 != link }).prefix(8))
        }
        shell.start(in: folder)
        shells.append(shell)
        if select { selected = shell.id }
        return shell
    }

    func close(_ shell: Shell, in folder: URL) {
        guard let index = shells.firstIndex(where: { $0.id == shell.id }) else { return }
        shell.stop()
        previewLinks.removeAll { $0.shellNumber == shell.number }
        shells.remove(at: index)
        split.removeAll { $0 == shell.id }
        if split.count == 1 { split = [] }
        if shells.isEmpty {
            add(in: folder)
        } else if selected == shell.id {
            // Keep focus on screen: the neighbouring split if split, else the neighbouring shell.
            selected = split.first ?? shells[min(index, shells.count - 1)].id
        }
    }

    func reset(in folder: URL) {
        shells.forEach { $0.stop() }
        shells.removeAll()
        split = []
        previewLinks.removeAll()
        nextNumber = 1
        add(in: folder)
    }
}

// === VIEWS: pane toolbar, splits, one terminal ===

struct TerminalGroup: View {
    @ObservedObject var sessions: TerminalSessions
    let folder: URL
    @State private var closing: Shell?
    @State private var commands: [QuickCommand] = []

    var body: some View {
        VStack(spacing: 0) {
            PaneBar(title: "Terminal", icon: "terminal") {
                HStack(spacing: 6) {
                    Picker("Session", selection: $sessions.selected) {
                        ForEach(sessions.shells) { shell in
                            HStack {
                                Text("zsh " + String(shell.number))
                            }.tag(Optional(shell.id))
                        }
                    }.labelsHidden().fixedSize()

                    Button {
                        sessions.add(in: folder)
                    } label: {
                        Image(systemName: "plus")
                    }.help("New terminal session")

                    Menu {
                        // Shortcuts live in Workspace → Split Terminal (Workbench.swift); menu
                        // items inside a view only fire while the menu is open.
                        Button("Split Right  ⌘D") { sessions.splitActive(in: folder, axis: .columns) }
                        Button("Split Down  ⇧⌘D") { sessions.splitActive(in: folder, axis: .rows) }
                        if sessions.split.count > 1 {
                            Divider()
                            Button(sessions.splitAxis == .columns ? "Stack Splits" : "Splits Side by Side") {
                                sessions.splitAxis = sessions.splitAxis == .columns ? .rows : .columns
                            }
                            Button("Unsplit") { sessions.unsplit() }
                        }
                    } label: {
                        Image(systemName: sessions.splitAxis == .rows && sessions.split.count > 1
                              ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    } primaryAction: {
                        sessions.splitActive(in: folder, axis: .columns)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(sessions.split.count >= TerminalSessions.maxSplits)
                    .help("Split terminal (⌘D right, ⇧⌘D down)")

                    Button {
                        sessions.active?.clear()
                    } label: {
                        Image(systemName: "trash")
                    }.help("Clear scrollback (⌘K)")

                    Button {
                        closing = sessions.active
                    } label: {
                        Image(systemName: "xmark")
                    }.help("Close terminal session")
                }
            }
            if sessions.shown.count > 1 { splits }
            else if let shell = sessions.active {
                TerminalPane(shell: shell).id(shell.id)
            }
            Divider()
            QuickCommandBar(commands: commands, target: sessions.active)
        }
        // Re-detected when the pane appears, so a script added to package.json shows up.
        .task(id: folder) { commands = ProjectCommands.detect(in: folder) }
        .onChange(of: sessions.selected) {
            // Keyboard follows the session picker and new splits.
            let shell = sessions.active
            DispatchQueue.main.async { shell?.terminal.focus() }
        }
        .alert(item: $closing) { shell in
            Alert(
                title: Text("Close terminal " + String(shell.number) + "?"),
                message: Text("Closing this shell terminates its active processes."),
                primaryButton: .destructive(Text("Close")) { sessions.close(shell, in: folder) },
                secondaryButton: .cancel()
            )
        }
    }

    /// Native split views give draggable dividers for free.
    @ViewBuilder private var splits: some View {
        if sessions.splitAxis == .columns {
            HSplitView { ForEach(sessions.shown) { split($0).frame(minWidth: 220) } }
        } else {
            VSplitView { ForEach(sessions.shown) { split($0).frame(minHeight: 120) } }
        }
    }

    private func split(_ shell: Shell) -> some View {
        let focused = sessions.selected == shell.id
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(shell.isRunning ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text("zsh " + String(shell.number)).font(.system(size: 11, weight: focused ? .semibold : .regular))
                Spacer(minLength: 0)
                Button { closing = shell } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).help("Close this terminal")
            }
            .padding(.horizontal, 8).frame(height: 22)
            .background(focused ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
            .contentShape(Rectangle())
            .onTapGesture { sessions.selected = shell.id }
            TerminalPane(shell: shell).id(shell.id)
        }
    }
}

/// One terminal's xterm.js surface, with a Restart bar once its shell has ended.
struct TerminalPane: View {
    @ObservedObject var shell: Shell
    var body: some View {
        ZStack(alignment: .bottom) {
            WebSurface(page: shell.terminal.page)
            if shell.exited {
                HStack(spacing: 8) {
                    Text("zsh \(shell.number) has exited").font(.caption)
                    Button("Restart") { shell.restart() }.controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule()).padding(10)
            }
        }
    }
}

/// The project's shortcut chips (ProjectCommands.swift); each runs in the focused terminal.
struct QuickCommandBar: View {
    let commands: [QuickCommand]
    let target: Shell?
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(commands) { item in
                    Button { target?.run(item.command) } label: {
                        Label(item.command, systemImage: item.icon)
                            .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(target?.isRunning != true)
                    .help(target.map { "Run “\(item.command)” in zsh \($0.number)" } ?? "")
                }
            }.padding(.horizontal, 8).padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
    }
}
