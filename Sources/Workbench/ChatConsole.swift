// Terminal chat pane: an xterm.js terminal (XTerm.swift) running Claude Code or a login shell
// in the project folder. Started on demand from the pane's buttons, not at launch.

import SwiftUI
import ShellPTY
import WebKit

final class ChatConsole: ObservableObject {
    let terminal = XTermPage()
    var page: WKWebView { terminal.page }
    private let folder: URL
    private var source: DispatchSourceRead?
    private var stream: FileHandle?
    private let input = DispatchQueue(label: "workbench.chat.input")
    @Published private(set) var ready = false
    @Published private(set) var running = false
    @Published private(set) var started = false
    @Published private(set) var issue = ""

    init(folder: URL) {
        self.folder = folder
        issue = terminal.loadIssue ?? ""
        terminal.onReady = { [weak self] in self?.ready = true }
        terminal.onInput = { [weak self] data in
            guard let self, let stream = self.stream else { return }
            self.input.async { try? stream.write(contentsOf: data) }
        }
        terminal.onResize = { [weak self] columns, rows in
            if let stream = self?.stream { resize_pty(stream.fileDescriptor, Int32(rows), Int32(columns)) }
        }
    }

    func start(claude: Bool) {
        guard ready, !running else { return }
        var fd: Int32 = -1
        let pid = start_chat(folder.path, &fd, claude ? 1 : 0)
        guard pid > 0 else { issue = "Couldn’t start a terminal in " + folder.path; return }
        issue = ""; started = true; running = true
        DispatchQueue.global().async { var status: Int32 = 0; waitpid(pid, &status, 0) }
        resize_pty(fd, Int32(terminal.rows), Int32(terminal.columns))
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        stream = handle; source = reader
        reader.setCancelHandler { try? handle.close() }
        reader.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let n = read(fd, &bytes, bytes.count)
            if n < 0 && errno == EINTR { return }
            guard n > 0 else {
                self.source?.cancel(); self.source = nil; self.stream = nil; self.running = false
                return
            }
            // Backpressure: read no more until xterm has parsed this chunk.
            reader.suspend()
            self.terminal.write(Data(bytes.prefix(n))) { reader.resume() }
        }
        reader.resume()
        terminal.focus()
    }
    deinit { source?.cancel() }
}

struct ChatPane: View {
    @ObservedObject var console: ChatConsole
    var body: some View {
        VStack(spacing: 0) {
            if !console.running {
                HStack {
                    if console.started { Text("Session ended").font(.caption).foregroundStyle(.secondary) }
                    Button("Start Claude") { console.start(claude: true) }.buttonStyle(.borderedProminent)
                    Button("Start shell") { console.start(claude: false) }
                }.disabled(!console.ready).padding(8)
            }
            if !console.issue.isEmpty { Text(console.issue).foregroundStyle(.orange) }
            WebSurface(page: console.page)
        }
    }
}
