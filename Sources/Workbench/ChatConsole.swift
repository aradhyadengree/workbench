import SwiftUI
import WebKit
import ShellPTY

private final class ConsoleBridge: NSObject, WKScriptMessageHandler {
    weak var console: ChatConsole?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let data = message.body as? [String: Any], let type = data["type"] as? String else { return }
        console?.receive(type, value: data["value"])
    }
}

final class ChatConsole: NSObject, ObservableObject, WKNavigationDelegate {
    let page: WKWebView
    private let folder: URL
    private var source: DispatchSourceRead?
    private var stream: FileHandle?
    private let input = DispatchQueue(label: "workbench.chat.input")
    private var columns = 80, rows = 24
    @Published private(set) var ready = false
    @Published private(set) var running = false
    @Published private(set) var started = false
    @Published private(set) var issue = ""

    init(folder: URL) {
        self.folder = folder
        let config = WKWebViewConfiguration(), bridge = ConsoleBridge()
        config.userContentController.add(bridge, name: "consoleBridge")
        page = WKWebView(frame: .zero, configuration: config)
        super.init()
        bridge.console = self
        page.navigationDelegate = self
        let packaged = Bundle.main.url(forResource: "Workbench_Workbench", withExtension: "bundle").flatMap(Bundle.init(url:))
        let resources = packaged ?? Bundle.module
        guard let url = resources.url(forResource: "index", withExtension: "html", subdirectory: "ChatTerminal") else {
            issue = "Terminal resources are missing from the app."; return
        }
        page.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true && action.navigationType == .other ? .allow : .cancel)
    }
    fileprivate func receive(_ type: String, value: Any?) {
        if type == "input", let text = value as? String, let stream {
            input.async { try? stream.write(contentsOf: Data(text.utf8)) }
        } else if let size = value as? [Int], size.count == 2, ["size", "ready"].contains(type) {
            columns = min(4096, max(2, size[0])); rows = min(4096, max(2, size[1]))
            if let stream { resize_pty(stream.fileDescriptor, Int32(rows), Int32(columns)) }
            if type == "ready" { ready = true }
        }
    }

    func start(claude: Bool) {
        guard ready, !running else { return }
        var fd: Int32 = -1
        let pid = start_chat(folder.path, &fd, claude ? 1 : 0)
        guard pid > 0 else { issue = "Couldn’t start a terminal in " + folder.path; return }
        issue = ""; started = true; running = true
        DispatchQueue.global().async { var status: Int32 = 0; waitpid(pid, &status, 0) }
        resize_pty(fd, Int32(rows), Int32(columns))
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
            reader.suspend()
            self.page.callAsyncJavaScript("return await window.writeChunk(chunk)",
                arguments: ["chunk": Data(bytes.prefix(n)).base64EncodedString()], in: nil, in: .page) { _ in reader.resume() }
        }
        reader.resume()
        page.window?.makeFirstResponder(page)
        page.evaluateJavaScript("window.focusConsole()")
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
