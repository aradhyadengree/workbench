import SwiftUI
import ShellPTY
import AppKit

// === SHELL: one PTY-backed zsh ===

final class Shell: ObservableObject, Identifiable {
    let id = UUID()
    let number: Int
    @Published var command = ""
    @Published var output = ""
    @Published var isRunning = false
    
    // Command history
    var history: [String] = []
    var historyIndex: Int = -1

    private var previewDetector = LocalPreviewDetector()
    var onLocalURL: ((URL) -> Void)?
    private var reader: DispatchSourceRead?
    private var handle: FileHandle?
    private var generation = UUID()
    private var masterFd: Int32 = -1

    init(number: Int) {
        self.number = number
    }

    private var pendingStart: UUID?

    /// Waits for the user's shell environment (see ShellEnvironment.swift) so the first shell
    /// already has their PATH; only the latest request runs if several arrive while waiting.
    func start(in folder: URL) {
        let request = UUID()
        pendingStart = request
        ShellEnvironment.whenReady { [weak self] in
            guard let self, self.pendingStart == request else { return }
            self.pendingStart = nil
            self.spawn(in: folder)
        }
    }

    private func spawn(in folder: URL) {
        generation = UUID()
        output = ""
        previewDetector = LocalPreviewDetector()
        var fd: Int32 = -1
        let pid = start_shell(folder.path, &fd, TerminalPaneRC.directory()?.path)
        guard pid > 0 else {
            output = "\u{1b}[31mCould not start zsh in \(folder.path)\u{1b}[0m\n"
            return
        }
        masterFd = fd
        isRunning = true
        let token = generation
        let stream = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle = stream
        
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
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
                self.output += "\n\u{1b}[33m[Shell exited]\u{1b}[0m\n"
                self.stop()
                return
            }
            for url in self.previewDetector.consume(bytes.prefix(count)) { self.onLocalURL?(url) }
            let line = String(decoding: bytes.prefix(count), as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            self.output = String((self.output + line).suffix(128000))
        }
        source.resume()
    }

    func stop() {
        pendingStart = nil
        generation = UUID()
        reader?.cancel()
        reader = nil
        handle = nil
        isRunning = false
        masterFd = -1
    }

    func clear() {
        output = ""
    }

    func resize(cols: Int, rows: Int) {
        if masterFd > 0 {
            resize_pty(masterFd, Int32(rows), Int32(cols))
        }
    }

    func sendCommand(_ cmd: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            history.append(trimmed)
            historyIndex = -1
        }
        send(cmd + "\n")
        command = ""
    }

    func historyPrevious() {
        guard !history.isEmpty else { return }
        if historyIndex == -1 {
            historyIndex = history.count - 1
        } else if historyIndex > 0 {
            historyIndex -= 1
        }
        command = history[historyIndex]
    }

    func historyNext() {
        guard !history.isEmpty && historyIndex >= 0 else { return }
        if historyIndex < history.count - 1 {
            historyIndex += 1
            command = history[historyIndex]
        } else {
            historyIndex = -1
            command = ""
        }
    }

    func send(_ value: String) {
        try? handle?.write(contentsOf: Data(value.utf8))
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
            TerminalPane(shell: shell) { sessions.selected = shell.id }.id(shell.id)
        }
    }
}

struct TerminalPane: View {
    @ObservedObject var shell: Shell
    /// Called when the user clicks into this terminal's command field (marks its split focused).
    var onFocus: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // ANSI Terminal Output
            GeometryReader { geo in
                ANSITerminalView(output: shell.output, isDark: colorScheme == .dark)
                    .onChange(of: geo.size) {
                        let cols = max(40, Int(geo.size.width / 7.2))
                        let rows = max(10, Int(geo.size.height / 14.0))
                        shell.resize(cols: cols, rows: rows)
                    }
            }

            Divider()

            // Quick actions & Command input bar
            VStack(spacing: 6) {
                // Quick Action Chips
                HStack(spacing: 6) {
                    quickChip("git status", icon: "arrow.triangle.branch")
                    quickChip("ls -la", icon: "list.bullet")
                    quickChip("swift test", icon: "play.fill")
                    Spacer()
                    Button {
                        shell.send("\u{3}") // Ctrl+C
                    } label: {
                        Label("Ctrl+C", systemImage: "hand.raised.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }.buttonStyle(.bordered).controlSize(.mini).help("Interrupt foreground process")
                }.padding(.horizontal, 8).padding(.top, 4)

                // Input field with history
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(WorkbenchTheme.toolColor(.terminal))

                    CommandInputField(
                        text: $shell.command,
                        onCommit: { shell.sendCommand(shell.command) },
                        onUp: { shell.historyPrevious() },
                        onDown: { shell.historyNext() },
                        onFocus: onFocus
                    )

                    Button("Run") {
                        shell.sendCommand(shell.command)
                    }.controlSize(.small).buttonStyle(.borderedProminent)
                     .tint(WorkbenchTheme.toolColor(.terminal))
                     .disabled(shell.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.horizontal, 8).padding(.bottom, 6)
            }
            .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
        }
    }

    private func quickChip(_ cmd: String, icon: String) -> some View {
        Button {
            shell.sendCommand(cmd)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(cmd).font(.system(size: 10, design: .monospaced))
            }.padding(.horizontal, 6).padding(.vertical, 2)
             .background(Color.secondary.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain)
    }
}

// MARK: - Native AppKit Terminal Output View with ANSI Color Formatting
// === APPKIT BRIDGES: output renderer, command field ===

struct ANSITerminalView: NSViewRepresentable {
    let output: String
    let isDark: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollablePlainDocumentContentTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = isDark ? NSColor(srgbRed: 0.05, green: 0.07, blue: 0.10, alpha: 1.0)
                                          : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        updateContent(textView: textView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.backgroundColor = isDark ? NSColor(srgbRed: 0.05, green: 0.07, blue: 0.10, alpha: 1.0)
                                          : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0)
        updateContent(textView: textView)
    }

    private func updateContent(textView: NSTextView) {
        let defaultColor = isDark ? NSColor(srgbRed: 0.90, green: 0.94, blue: 0.98, alpha: 1.0)
                                  : NSColor(srgbRed: 0.10, green: 0.14, blue: 0.18, alpha: 1.0)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributed = ANSIParser.parse(output, baseFont: font, defaultColor: defaultColor)

        textView.textStorage?.setAttributedString(attributed)
        textView.scrollToEndOfDocument(nil)
    }
}

// MARK: - Native AppKit Text Field Supporting Up/Down History
struct CommandInputField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void
    var onFocus: (() -> Void)? = nil

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandInputField
        init(_ parent: CommandInputField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onUp()
                return true
            } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onDown()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Reports becoming first responder on click, not only on the first keystroke.
    final class FocusField: NSTextField {
        var onFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { DispatchQueue.main.async { self.onFocus?() } }
            return became
        }
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusField()
        field.onFocus = onFocus
        field.placeholderString = "Enter command or choose shortcut…"
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        (field as? FocusField)?.onFocus = onFocus
        if field.stringValue != text {
            field.stringValue = text
        }
    }
}
