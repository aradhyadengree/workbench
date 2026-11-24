// One xterm.js terminal (the vendored ChatTerminal/ page) in a WKWebView. Owners connect it to
// a PTY: the Terminal chat pane (ChatConsole) and every Terminal pane shell (Shell).
//
// Bridge protocol with ChatTerminal/bridge.js, messages on "consoleBridge":
//   ready [cols, rows]  page loaded and measured; output may be written from now on
//   size  [cols, rows]  the terminal was resized (forward to the PTY)
//   input "text"        keystrokes/paste to write to the PTY
//   focus null          the terminal gained keyboard focus
// Swift → page: writeChunk(base64) resolves once xterm has parsed it (use it for backpressure),
// focusConsole(), clearConsole().
//
// Invariant: only the bundled file:// page may post messages or navigate; anything else is
// dropped, because terminal output can contain attacker-controlled text.

import WebKit

final class XTermPage: NSObject, WKNavigationDelegate {
    let page: WKWebView
    private(set) var ready = false
    private(set) var columns = 80
    private(set) var rows = 24
    /// Set when the page's resources are missing from the bundle.
    private(set) var loadIssue: String?
    var onInput: ((Data) -> Void)?
    var onResize: ((_ columns: Int, _ rows: Int) -> Void)?
    var onReady: (() -> Void)?
    var onFocus: (() -> Void)?
    /// Output that arrived before the page was ready (a shell prints its prompt immediately).
    private var pending = Data()

    override init() {
        let config = WKWebViewConfiguration(), bridge = Bridge()
        config.userContentController.add(bridge, name: "consoleBridge")
        page = WKWebView(frame: .zero, configuration: config)
        super.init()
        bridge.owner = self
        page.navigationDelegate = self
        // Resource bundle name is load-bearing; see AGENTS.md landmines.
        let packaged = Bundle.main.url(forResource: "Workbench_Workbench", withExtension: "bundle").flatMap(Bundle.init(url:))
        let resources = packaged ?? Bundle.module
        guard let url = resources.url(forResource: "index", withExtension: "html", subdirectory: "ChatTerminal") else {
            loadIssue = "Terminal resources are missing from the app."; return
        }
        page.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true && action.navigationType == .other ? .allow : .cancel)
    }

    /// Writes PTY output; `done` runs once xterm has consumed it (or immediately while buffering).
    func write(_ data: Data, done: @escaping () -> Void = {}) {
        guard ready else {
            pending.append(data)
            if pending.count > 2_000_000 { pending.removeFirst(pending.count - 2_000_000) }
            done(); return
        }
        page.callAsyncJavaScript("return await window.writeChunk(chunk)",
                                 arguments: ["chunk": data.base64EncodedString()], in: nil, in: .page) { _ in done() }
    }

    func focus() {
        page.window?.makeFirstResponder(page)
        page.evaluateJavaScript("window.focusConsole()")
    }

    func clear() { page.evaluateJavaScript("window.clearConsole()") }

    fileprivate func receive(_ type: String, value: Any?) {
        switch type {
        case "input":
            if let text = value as? String { onInput?(Data(text.utf8)) }
        case "focus":
            onFocus?()
        case "size", "ready":
            guard let size = value as? [Int], size.count == 2 else { return }
            columns = min(4096, max(2, size[0])); rows = min(4096, max(2, size[1]))
            onResize?(columns, rows)
            if type == "ready", !ready {
                ready = true
                if !pending.isEmpty { let buffered = pending; pending = Data(); write(buffered) }
                onReady?()
            }
        default: break
        }
    }

    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: XTermPage?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
                  let data = message.body as? [String: Any], let type = data["type"] as? String else { return }
            owner?.receive(type, value: data["value"])
        }
    }
}
