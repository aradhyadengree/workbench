import SwiftUI
import WebKit
import UniformTypeIdentifiers
import SimulatorHost

/// Shows a long-lived WKWebView (a Browser's page, the chat terminal) that may move between
/// windows: Live Desk panes pop out into their own windows and dock back.
///
/// Guard: SwiftUI must never own the web view itself. A view can have one superview, and when
/// SwiftUI tears down the old host it removes the view it returned from makeNSView — if that
/// were the page, it would rip it out of the window it just moved to and leave that blank.
/// So each host is a plain container; the newest container to appear takes the page
/// (latest wins), and an old container going away takes nothing with it.
struct WebSurface: NSViewRepresentable {
    let page: WKWebView
    func makeNSView(context: Context) -> WebHost { let host = WebHost(); host.adopt(page); return host }
    func updateNSView(_ host: WebHost, context: Context) {
        // Re-adopt only an orphaned page; stealing here would ping-pong between live hosts.
        if page.superview == nil || host.page !== page { host.adopt(page) }
    }

    final class WebHost: NSView {
        private(set) weak var page: WKWebView?
        func adopt(_ page: WKWebView) {
            self.page = page
            guard page.superview !== self else { return }
            page.removeFromSuperview()
            page.frame = bounds
            page.autoresizingMask = [.width, .height]
            addSubview(page)
        }
    }
}

final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let page: WKWebView = {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = Browser.safariUserAgentSuffix
        return WKWebView(frame: .zero, configuration: config)
    }()

    /// WKWebView's default user agent has no "Version/… Safari/…" token, which Google's sign-in
    /// treats as an embedded (untrusted) browser. Claim the Safari installed on this Mac so
    /// sign-in pages (Google → claude.ai) behave as they do in Safari.
    static let safariUserAgentSuffix: String = {
        let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        let version = safari.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "18.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    /// Real windows for sized pop-ups (OAuth "Continue with Google"). They must stay real
    /// WKWebViews created from WebKit's configuration so window.opener survives; loading them
    /// in the main view instead breaks the sign-in hand-back.
    private var popups: [NSWindow] = []
    @Published var additionalTabs: [Browser] = []
    @Published var selectedTab: ObjectIdentifier?
    @Published var title = "New tab"
    var activeTab: Browser { additionalTabs.first { ObjectIdentifier($0) == selectedTab } ?? self }

    func addTab() {
        let tab = Browser()
        additionalTabs.append(tab)
        selectedTab = ObjectIdentifier(tab)
    }
    func closeTab(_ tab: Browser) {
        guard let index = additionalTabs.firstIndex(where: { $0 === tab }) else { return }
        tab.page.stopLoading()
        additionalTabs.remove(at: index)
        if selectedTab == ObjectIdentifier(tab) {
            selectedTab = additionalTabs.prefix(index).last.map(ObjectIdentifier.init)
        }
    }
    @Published var address = ""
    @Published var issue = ""
    @Published var started = false
    override init() { super.init(); page.navigationDelegate = self; page.uiDelegate = self }
    /// Without a UI delegate WebKit drops every new-window request silently.
    /// Sized pop-ups (window.open with width/height, which sign-in flows use) get a real window;
    /// plain target=_blank links load in this same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard windowFeatures.width != nil || windowFeatures.height != nil else {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }
        let size = NSSize(width: CGFloat(truncating: windowFeatures.width ?? 520),
                          height: CGFloat(truncating: windowFeatures.height ?? 680))
        let popup = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = action.request.url?.host ?? "Sign in"
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }
    /// The page called window.close() (e.g. sign-in finished).
    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
    }
    func windowWillClose(_ notification: Notification) {
        popups.removeAll { $0 === notification.object as? NSWindow }
    }
    /// "localhost:3000" → http://localhost:3000, "example.com" → https://example.com.
    /// Nil unless the result is an http(s) URL with a host.
    static func normalize(_ address: String) -> URL? {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = ["localhost", "127.0.0.1", "[::1]"].contains { raw.components(separatedBy: "/").first == $0 || raw.hasPrefix($0 + ":") }
        let target = raw.contains("://") ? raw : (local ? "http://" : "https://") + raw
        guard let url = URL(string: target), let host = url.host, !host.isEmpty,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    func go() {
        selectedTab = nil
        guard let url = Self.normalize(address) else { issue = "Enter an HTTP or HTTPS address."; return }
        started = true; issue = ""; page.load(URLRequest(url: url))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        title = webView.title ?? webView.url?.host ?? "Web preview"
        address = webView.url?.absoluteString ?? address; issue = ""
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { issue = error.localizedDescription }
    }
}

struct BrowserPane: View {
    @ObservedObject var browser: Browser
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach([browser] + browser.additionalTabs, id: \.self) { tab in
                            BrowserTabLabel(tab: tab, selected: browser.activeTab === tab,
                                            select: { browser.selectedTab = tab === browser ? nil : ObjectIdentifier(tab) },
                                            close: tab === browser ? nil : { browser.closeTab(tab) })
                        }
                    }
                }.scrollIndicators(.hidden)
                Button { browser.addTab() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("Open a new browser tab")
            }.padding(.horizontal, 8).frame(height: 28).background(.bar)
            BrowserPage(browser: browser.activeTab).id(ObjectIdentifier(browser.activeTab))
        }
    }
}

private struct BrowserTabLabel: View {
    @ObservedObject var tab: Browser
    let selected: Bool
    let select: () -> Void
    let close: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) { Label(tab.title, systemImage: "globe").lineLimit(1) }
            if let close { Button(action: close) { Image(systemName: "xmark") }.help("Close tab") }
        }.font(.caption).buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 3)
            .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct BrowserPage: View {
    @ObservedObject var browser: Browser
    var placeholder = "localhost:3000 or a URL"
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            // Navigation Bar (< > ⟳ Address)
            HStack(spacing: 6) {
                Button { browser.page.goBack() } label: { Image(systemName: "chevron.left") }
                    .help("Back").disabled(!browser.page.canGoBack)
                Button { browser.page.goForward() } label: { Image(systemName: "chevron.right") }
                    .help("Forward").disabled(!browser.page.canGoForward)
                Button {
                    if browser.page.url != nil { browser.page.reload() } else { browser.go() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                Button { browser.address = "" } label: { Image(systemName: "c.circle") }
                    .help("Clear address")

                TextField(placeholder, text: $browser.address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { browser.go() }

                Button("Go") { browser.go() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(WorkbenchTheme.toolColor(.browser))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                    .frame(height: 1)
            }

            if !browser.issue.isEmpty {
                Text(browser.issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(4)
            }

            if browser.started {
                WebSurface(page: browser.page)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 36))
                        .foregroundStyle(WorkbenchTheme.toolColor(.browser))
                    Text("Web Preview")
                        .font(.headline)
                    Text("Enter http://localhost:3000 or any hosted URL above to test live.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Load localhost:3000") {
                        browser.address = "http://localhost:3000"
                        browser.go()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
            }
        }
    }
}

struct Device: Decodable, Identifiable, Hashable {
    let name: String
    let udid: String
    let state: String
    let isAvailable: Bool
    var id: String { udid }
}

func simctl(_ args: [String]) async throws -> Data {
    try await Task.detached(priority: .utility) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + args
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        return result
    }.value
}

struct SimulatorPane: View {
    @State private var devices: [Device] = []
    @State private var selected = ""
    @Binding var active: String
    @State private var display: WBDisplayHost?
    @State private var connecting = false
    @State private var retry = UUID()
    @State private var message = "Looking for iOS devices…"
    @State private var refresh = UUID()
    @State private var installMessage = ""
    @State private var installing = false
    @State private var capturingScreenshot = false

    @MainActor private func saveScreenshot() {
        guard !capturingScreenshot, display != nil, !active.isEmpty else { return }
        let device = active
        let name = devices.first(where: { $0.id == device })?.name ?? "Simulator"
        capturingScreenshot = true
        Task {
            defer { capturingScreenshot = false }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                _ = try await simctl(["io", device, "screenshot", "--type=png", temporary.path])
                let data = try Data(contentsOf: temporary)
                guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + " - " +
                    ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".png"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                if active == device { installMessage = "Saved " + url.lastPathComponent }
            } catch {
                if active == device { installMessage = "Screenshot failed. " + error.localizedDescription }
            }
        }
    }

    private func installApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard let identifier = Bundle(url: file)?.bundleIdentifier else {
            installMessage = "Choose a simulator .app with a bundle identifier."; return
        }
        let device = active
        installing = true; installMessage = "Installing " + file.lastPathComponent + "…"
        Task {
            defer { installing = false }
            do {
                _ = try await simctl(["install", device, file.path])
                _ = try await simctl(["launch", device, identifier])
                if active == device { installMessage = "Launched " + identifier }
            } catch {
                if active == device { installMessage = "Couldn’t launch this build. Choose an iOS Simulator build for this device." }
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            PaneBar(title: "Simulator", icon: "iphone") {
                if let display {
                    Button {
                        display.pressHome { error in
                            if let error, self.display === display { installMessage = error.localizedDescription }
                        }
                    } label: { Label("Home", systemImage: "house") }
                    .help("Go to the connected device’s Home Screen")
                    Button(action: saveScreenshot) { Image(systemName: "camera") }
                        .disabled(capturingScreenshot).accessibilityLabel("Save simulator screenshot")
                        .help("Save simulator screenshot as PNG")
                }
                Button { refresh = UUID() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh devices")
            }
            if !devices.isEmpty {
                HStack {
                    Picker("Device", selection: $selected) {
                        ForEach(devices) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                    if active == selected && display != nil {
                        Button("Disconnect") { active = ""; message = "Select a device and connect." }.help("Detach the view and leave the device running")
                    } else {
                        Button(connecting && selected == active ? "Starting…" : "Connect") {
                            if active == selected { retry = UUID() } else { active = selected }
                        }.disabled(selected.isEmpty || (connecting && selected == active))
                    }
                }.padding(8)
            }
            if let display {
                SimulatorDisplay(host: display).id(ObjectIdentifier(display))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(4)
                if !installMessage.isEmpty {
                    Text(installMessage).font(.caption).lineLimit(2).help(installMessage)
                }
                Button("Install and Launch .app…", action: installApp).disabled(installing).padding(.bottom, 8)
            } else {
                ContentUnavailableView("iOS Simulator", systemImage: "iphone", description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: refresh) {
            struct Inventory: Decodable { let devices: [String: [Device]] }
            do {
                let data = try await simctl(["list", "devices", "available", "-j"])
                let inventory = try JSONDecoder().decode(Inventory.self, from: data)
                guard !Task.isCancelled else { return }
                devices = inventory.devices.filter { $0.key.contains(".iOS-") }.sorted { $0.key > $1.key }
                    .flatMap(\.value).filter(\.isAvailable)
                selected = devices.first(where: { $0.id == active })?.id ?? devices.first(where: { $0.state == "Booted" })?.id ?? devices.first?.id ?? ""
                if active.isEmpty { message = devices.isEmpty ? "Install an iOS runtime in Xcode Settings, then refresh." : "Connect to run and control an iOS device here." }
            } catch { message = "Couldn’t reach CoreSimulator. Open Xcode and refresh devices." }
        }
        .task(id: active + retry.uuidString) {
            display = nil; installMessage = ""; connecting = false
            let id = active
            guard !id.isEmpty else { return }
            connecting = true; message = "Starting device…"
            do {
                _ = try await simctl(["bootstatus", id, "-b"])
                try Task.checkCancellation()
                message = "Connecting display and input…"
                let host = try await SimulatorDisplay.connect(id)
                try Task.checkCancellation()
                display = host
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            connecting = false
        }
    }
}
