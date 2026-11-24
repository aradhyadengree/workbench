// Test Cases pane (Live Desk). Two views of the same project's test plan:
// - Page: wherever the test cases live (usually a Claude artifact link), opened either in the
//   built-in browser (shared persistent WebKit store, so a sign-in survives relaunches) or handed
//   to a real browser the user picks (Safari, Chrome…), which already has their logins. macOS
//   can't embed another app's window, so an external browser opens beside Workbench, not inside.
// - Checklist: test cases imported from text (pasted, or a .md/.txt/.csv file) with a Web and a
//   Phone verdict per case, exportable as Markdown.
//
// Invariants:
// - Per project folder, in UserDefaults: "testCases.<path>" = JSON [TestCase],
//   "testCasesPage.<path>" = page URL, "testCasesView.<path>" = "page" | "checklist".
//   App-wide: "testPlanBrowser" = browser bundle id, or "builtin".
//   Changing a key or TestCase's coding keys drops users' progress.
// - Import never fetches anything. A pasted link opens in the Page view instead.
// - Verdicts reuse `Verdict` from TestRun.swift so results read the same as Test Studio's.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// === MODEL ===

struct TestCase: Codable, Identifiable, Equatable {
    var id = UUID()
    var section: String
    var title: String
    var detail: String
    var web: Verdict = .untested
    var phone: Verdict = .untested
    var note = ""

    var done: Bool { web != .untested && phone != .untested }
    var failed: Bool { web == .failed || phone == .failed }
}

/// Turns pasted text into test cases. Tries, in order: CSV, Markdown table, checklist items,
/// one-case-per-heading, top-level list items, then one case per non-empty line.
enum TestCaseParser {
    static func parse(_ raw: String) -> [TestCase] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        if let rows = csv(lines) ?? table(lines) { return rows }
        return checklist(lines) ?? headings(lines) ?? listItems(lines) ?? plainLines(lines)
    }

    // --- tables (CSV / Markdown) ---

    private static let titleKeys = ["title", "test case", "testcase", "test", "scenario", "case", "name", "description"]

    private static func cases(header: [String], rows: [[String]]) -> [TestCase]? {
        let keys = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func column(_ names: [String]) -> Int? {
            for name in names { if let i = keys.firstIndex(where: { $0 == name || $0.hasPrefix(name) }) { return i } }
            return nil
        }
        let idCol = column(["id", "#", "tc", "no"])
        let sectionCol = column(["module", "feature", "area", "section", "category", "suite"])
        guard let titleCol = column(titleKeys) ?? (keys.count > 1 && idCol == 0 ? 1 : (keys.isEmpty ? nil : 0)) else { return nil }
        let result: [TestCase] = rows.compactMap { row in
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil }?.trimmingCharacters(in: .whitespaces) ?? "" }
            let title = cell(titleCol)
            guard !title.isEmpty else { return nil }
            let id = cell(idCol)
            let details = keys.indices.filter { $0 != titleCol && $0 != idCol && $0 != sectionCol }
                .compactMap { i -> String? in
                    let value = cell(i)
                    return value.isEmpty ? nil : header[i].trimmingCharacters(in: .whitespaces) + ": " + value
                }
            return TestCase(section: cell(sectionCol), title: (id.isEmpty ? "" : id + " · ") + clean(title),
                            detail: details.joined(separator: "\n").replacingOccurrences(of: "<br>", with: "\n"))
        }
        return result.isEmpty ? nil : result
    }

    private static func csv(_ lines: [String]) -> [TestCase]? {
        let rows = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = rows.first, !first.hasPrefix("|"), !first.hasPrefix("#"), first.contains(","),
              titleKeys.contains(where: { first.lowercased().contains($0) }) else { return nil }
        return cases(header: csvFields(first), rows: rows.dropFirst().map(csvFields))
    }

    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if c == "\"" {
                if quoted, chars.first == "\"" { current.append("\""); chars.removeFirst() } else { quoted.toggle() }
            } else if c == ",", !quoted { fields.append(current); current = "" }
            else { current.append(c) }
        }
        return fields + [current]
    }

    private static func table(_ lines: [String]) -> [TestCase]? {
        let rows = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("|") }
        guard rows.count >= 3, rows[1].allSatisfy({ "|-: ".contains($0) }) else { return nil }
        func cells(_ row: String) -> [String] {
            row.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
        }
        return cases(header: cells(rows[0]), rows: rows.dropFirst(2).map(cells))
    }

    // --- Markdown structure ---

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, clean(String(line.dropFirst(hashes + 1))))
    }

    private static let checkbox = #/^\s*[-*+]\s+\[[ xX]\]\s+(.+)$/#
    private static let bullet = #/^([-*+]|\d+[.)])\s+(.+)$/#

    private static func checklist(_ lines: [String]) -> [TestCase]? {
        var result: [TestCase] = [], section = ""
        for line in lines {
            if let h = heading(line) { section = h.text; continue }
            if let match = line.wholeMatch(of: checkbox) {
                result.append(TestCase(section: section, title: clean(String(match.1)), detail: ""))
            } else if !result.isEmpty, line.hasPrefix(" ") || line.hasPrefix("\t"),
                      !line.trimmingCharacters(in: .whitespaces).isEmpty {
                append(line, to: &result[result.count - 1])
            }
        }
        return result.isEmpty ? nil : result
    }

    /// "## TC-01: Login" + body → one case per heading at the deepest level that has a body.
    private static func headings(_ lines: [String]) -> [TestCase]? {
        let levels = lines.compactMap { heading($0)?.level }
        guard let deepest = Set(levels).max(), levels.filter({ $0 == deepest }).count >= 2 else { return nil }
        var result: [TestCase] = [], section = ""
        var current: TestCase?
        for line in lines {
            if let h = heading(line) {
                if let c = current { result.append(c); current = nil }
                if h.level == deepest { current = TestCase(section: section, title: h.text, detail: "") }
                else { section = h.text }
            } else if current != nil, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                append(line, to: &current!)
            }
        }
        if let c = current { result.append(c) }
        return result.count >= 2 ? result : nil
    }

    private static func listItems(_ lines: [String]) -> [TestCase]? {
        var result: [TestCase] = [], section = ""
        for line in lines {
            if let h = heading(line) { section = h.text; continue }
            if let match = line.wholeMatch(of: bullet) {
                result.append(TestCase(section: section, title: clean(String(match.2)), detail: ""))
            } else if !result.isEmpty, line.first?.isWhitespace == true,
                      !line.trimmingCharacters(in: .whitespaces).isEmpty {
                append(line, to: &result[result.count - 1])
            }
        }
        return result.count >= 2 ? result : nil
    }

    private static func plainLines(_ lines: [String]) -> [TestCase] {
        lines.map { clean($0) }.filter { !$0.isEmpty }.map { TestCase(section: "", title: $0, detail: "") }
    }

    private static func append(_ line: String, to item: inout TestCase) {
        let text = line.trimmingCharacters(in: .whitespaces)
        item.detail += (item.detail.isEmpty ? "" : "\n") + text.replacingOccurrences(of: "**", with: "")
    }

    /// Drops Markdown emphasis and heading/bullet leftovers; keeps the words.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t#*-:"))
    }
}

// === STORE ===

/// A browser that can open the test plan: the built-in pane, or an installed browser app.
struct PlanBrowser: Identifiable, Hashable {
    static let builtinID = "builtin"
    let id: String          // bundle identifier, or `builtinID`
    let name: String
    let appURL: URL?

    static let builtin = PlanBrowser(id: builtinID, name: "Built-in", appURL: nil)
    private static let probe = URL(string: "https://example.com")!

    /// Every app registered for https links, as Launch Services reports them (Safari, Chrome, Arc…).
    static func installed() -> [PlanBrowser] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url -> PlanBrowser? in
            guard let id = Bundle(url: url)?.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
            return PlanBrowser(id: id, name: FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: ""), appURL: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var systemDefaultID: String {
        NSWorkspace.shared.urlForApplication(toOpen: probe).flatMap { Bundle(url: $0)?.bundleIdentifier } ?? builtinID
    }

    var icon: NSImage {
        appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
    }
}

final class TestCaseStore: ObservableObject {
    enum View: String { case page, checklist }

    @Published var cases: [TestCase] = [] { didSet { save() } }
    @Published var view: View { didSet { UserDefaults.standard.set(view.rawValue, forKey: "testCasesView." + folder.path) } }
    /// Defaults to Built-in: the point of the pane is seeing the plan beside the app under test.
    @Published var browserID = UserDefaults.standard.string(forKey: "testPlanBrowser") ?? PlanBrowser.builtinID {
        didSet { UserDefaults.standard.set(browserID, forKey: "testPlanBrowser"); browserChanged() }
    }
    @Published var link = ""
    @Published var editingLink = false
    let browsers = [PlanBrowser.builtin] + PlanBrowser.installed()
    let page = Browser()
    let folder: URL
    private var key: String { "testCases." + folder.path }

    init(folder: URL) {
        self.folder = folder
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "testCases." + folder.path)
            .flatMap { try? JSONDecoder().decode([TestCase].self, from: $0) } ?? []
        var link = defaults.string(forKey: "testCasesPage." + folder.path) ?? ""
        // Builds before this fix saved every built-in navigation, so a sign-in redirect could
        // replace the user's link. Drop those so the user is asked for the plan again.
        if Self.isSignInPage(link) { link = ""; defaults.removeObject(forKey: "testCasesPage." + folder.path) }
        view = View(rawValue: defaults.string(forKey: "testCasesView." + folder.path) ?? "")
            ?? (saved.isEmpty && !link.isEmpty ? .page : .checklist)
        cases = saved
        self.link = link
        if !browsers.contains(where: { $0.id == browserID }) { browserID = PlanBrowser.builtinID }
        // Built-in reloads silently; an external browser is never launched just because Workbench started.
        if !link.isEmpty, isBuiltin { page.address = link; page.go() }
    }

    var isBuiltin: Bool { browserID == PlanBrowser.builtinID }
    var browser: PlanBrowser { browsers.first { $0.id == browserID } ?? .builtin }

    /// Opens the plan in the chosen browser. Returns an error message, or nil on success.
    @discardableResult func open(link newLink: String) -> String? {
        guard let url = Browser.normalize(newLink) else { return "Enter an http or https link." }
        link = url.absoluteString
        UserDefaults.standard.set(link, forKey: "testCasesPage." + folder.path)
        view = .page
        editingLink = false
        if isBuiltin { page.address = link; page.go() } else { openExternally() }
        return nil
    }

    func openExternally() {
        guard let app = browser.appURL, let url = Browser.normalize(link) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func browserChanged() {
        guard !link.isEmpty, !editingLink else { return }
        if isBuiltin { page.address = link; page.go() } else { page.started = false }
    }

    /// Identity-provider and login pages are never a test plan; a saved link pointing at one is
    /// the leftover of a sign-in redirect, not something the user chose.
    static func isSignInPage(_ link: String) -> Bool {
        guard let url = Browser.normalize(link), let host = url.host?.lowercased() else { return false }
        let providers = ["accounts.google.com", "appleid.apple.com", "idmsa.apple.com",
                         "login.microsoftonline.com", "login.live.com", "github.com/login"]
        if providers.contains(where: { host == $0 || (host + url.path).hasPrefix($0) }) { return true }
        return host.hasSuffix("claude.ai") && ["/login", "/magic-link", "/sso"].contains { url.path.hasPrefix($0) }
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(cases), forKey: key) }

    var doneCount: Int { cases.filter(\.done).count }
    var failedCount: Int { cases.filter(\.failed).count }

    func report() -> String {
        func mark(_ v: Verdict) -> String {
            switch v { case .passed: "✅ Pass"; case .failed: "❌ Fail"; case .blocked: "⛔ Blocked"; case .untested: "—" }
        }
        func count(_ v: Verdict) -> Int { cases.filter { $0.web == v || $0.phone == v }.count }
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        var lines = [
            "# Test results: \(folder.lastPathComponent)", "",
            "\(date) · \(cases.count) cases · \(count(.failed)) with a failure · \(count(.blocked)) blocked · \(cases.count - doneCount) not finished",
            "", "| # | Test case | Web | Phone | Note |", "|---|---|---|---|---|",
        ]
        for (i, c) in cases.enumerated() {
            let title = (c.section.isEmpty ? "" : c.section + " › ") + c.title
            let cell = { (s: String) in s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
            lines.append("| \(i + 1) | \(cell(title)) | \(mark(c.web)) | \(mark(c.phone)) | \(cell(c.note)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// === VIEW ===

struct TestCasesPane: View {
    @ObservedObject private var store: TestCaseStore
    @State private var filter = Filter.all
    @State private var expanded: Set<UUID> = []
    @State private var message = ""
    @State private var dropping = false
    @State private var link = ""
    @Environment(\.colorScheme) private var colorScheme

    enum Filter: String, CaseIterable { case all = "All", todo = "To do", failed = "Failed" }

    /// The store comes from Project (one per folder) so the pane keeps its page and progress
    /// when it moves between the main window and a popped-out window.
    init(store: TestCaseStore) { _store = ObservedObject(wrappedValue: store) }

    private var visible: [Binding<TestCase>] {
        $store.cases.filter { item in
            switch filter {
            case .all: true
            case .todo: !item.wrappedValue.done
            case .failed: item.wrappedValue.failed
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !message.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { message = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(8).background(Color.blue.opacity(0.1))
            }
            if store.view == .page {
                if store.link.isEmpty || store.editingLink { linkState }
                else if store.isBuiltin {
                    if store.page.started {
                        // Navigation (incl. sign-in redirects) never rewrites the saved link; only
                        // Open / Change Link do. Saving navigations once replaced a user's artifact
                        // link with Google's sign-in URL.
                        BrowserPage(browser: store.page, placeholder: "Link to your test cases (Claude artifact, doc…)")
                    } else { linkState }
                } else { externalState }
            } else if store.cases.isEmpty { emptyState } else { list }
        }
        .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
        .overlay { if dropping { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).padding(2) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            importFile(url); return true
        } isTargeted: { dropping = $0 }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $store.view) {
                Label("Page", systemImage: "globe").tag(TestCaseStore.View.page)
                Label("Checklist", systemImage: "checklist").tag(TestCaseStore.View.checklist)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            .help("Page shows your test plan's link; Checklist tracks Web and Phone verdicts")
            if store.view == .checklist, !store.cases.isEmpty {
                ProgressView(value: Double(store.doneCount), total: Double(max(1, store.cases.count)))
                    .frame(width: 60).tint(store.failedCount > 0 ? .red : .green)
                Text("\(store.doneCount)/\(store.cases.count)").font(.system(size: 11, design: .monospaced))
                if store.failedCount > 0 {
                    Text("\(store.failedCount) failed").font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red, in: Capsule()).foregroundStyle(.white)
                }
                Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            Spacer(minLength: 0)
            if store.view == .page { browserMenu }
            Button { pasteCases() } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.plain).help("Paste test cases from the clipboard")
            Menu {
                Button("Paste Test Cases") { pasteCases() }
                Button("Open File…") { openFile() }
                Button("Change Test Plan Link…") { store.view = .page; link = store.link; store.editingLink = true }
                Divider()
                Button("Copy Results as Markdown") { copyResults() }.disabled(store.cases.isEmpty)
                Button("Export Results…") { exportResults() }.disabled(store.cases.isEmpty)
                Divider()
                Button("Reset All Verdicts") {
                    for i in store.cases.indices { store.cases[i].web = .untested; store.cases[i].phone = .untested }
                }.disabled(store.cases.isEmpty)
                Button("Remove All Test Cases", role: .destructive) { store.cases = []; expanded = [] }
                    .disabled(store.cases.isEmpty)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
    }

    /// Browser picker, like Claude desktop's "open links in": your real browser keeps your logins.
    private var browserMenu: some View {
        Menu {
            Section("Open test plan in") {
                ForEach(store.browsers) { option in
                    Button {
                        store.browserID = option.id
                    } label: {
                        Label { Text(option.name + (option.id == PlanBrowser.systemDefaultID ? " (default)" : "")) }
                            icon: { Image(nsImage: option.icon) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: store.browser.icon).resizable().frame(width: 14, height: 14)
                Text(store.browser.name).font(.system(size: 11))
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Choose where the test plan opens: inside this pane, or in a browser you're already signed in to")
    }

    private var linkState: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Open your test plan").font(.headline)
            Text("Paste the link to your Claude artifact or any doc. Workbench remembers it for this project.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("https://claude.ai/…", text: $link).textFieldStyle(.roundedBorder)
                    .onSubmit { openLink() }
                Picker("in", selection: $store.browserID) {
                    ForEach(store.browsers) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                Button("Open") { openLink() }.buttonStyle(.borderedProminent)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                if store.editingLink { Button("Cancel") { store.editingLink = false } }
            }
            .frame(maxWidth: 520)
            Text(store.isBuiltin
                 ? "Opens inside this pane. Private Claude artifacts need one sign-in here; it's remembered. With Google, choose \"Enter your password\" or \"Try another way\": passkeys only work in browser apps."
                 : "Opens in \(store.browser.name), where you're already signed in. macOS doesn't let apps embed another browser, so it opens beside Workbench.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if link.isEmpty { link = store.link } }
    }

    private var externalState: some View {
        VStack(spacing: 12) {
            Image(nsImage: store.browser.icon).resizable().frame(width: 48, height: 48)
            Text("Test plan opens in \(store.browser.name)").font(.headline)
            Text(store.link).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).frame(maxWidth: 420)
            HStack {
                Button { store.openExternally() } label: { Label("Open in \(store.browser.name)", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderedProminent)
                Button("Change Link") { link = store.link; store.editingLink = true }
                Button("Show Here Instead") { store.browserID = PlanBrowser.builtinID }
            }
            Text("To track Web and Phone verdicts in Workbench, copy the test cases from the page and paste them in Checklist.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openLink() {
        if let issue = store.open(link: link) { message = issue }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Bring your test cases").font(.headline)
            Text("Copy them from your Claude artifact or any doc, then paste. Checklists, headings, numbered lists, Markdown tables and CSV all work. You can also drop a .md, .txt or .csv file here.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { pasteCases() } label: { Label("Paste Test Cases", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.borderedProminent)
                Button("Open File…") { openFile() }
            }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let items = visible
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let section = item.wrappedValue.section
                    if !section.isEmpty, index == 0 || items[index - 1].wrappedValue.section != section {
                        Text(section.uppercased())
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                    }
                    row(item)
                    Divider().opacity(0.5)
                }
                if items.isEmpty {
                    Text(filter == .failed ? "Nothing has failed." : "Every case has a verdict.")
                        .font(.caption).foregroundStyle(.secondary).padding(16)
                }
            }
        }
    }

    private func row(_ item: Binding<TestCase>) -> some View {
        let open = expanded.contains(item.wrappedValue.id)
        let number = (store.cases.firstIndex { $0.id == item.wrappedValue.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    if open { expanded.remove(item.wrappedValue.id) } else { expanded.insert(item.wrappedValue.id) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                        Text("\(number).").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(item.wrappedValue.title).font(.system(size: 12.5))
                            .foregroundStyle(item.wrappedValue.done ? Color.secondary : Color.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                verdictChip("Web", icon: "globe", verdict: item.web)
                verdictChip("Phone", icon: "iphone", verdict: item.phone)
            }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if !item.wrappedValue.detail.isEmpty {
                        Text(item.wrappedValue.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    TextField("Note (what you saw, bug link…)", text: item.note, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11.5)).lineLimit(1...4)
                }
                .padding(.leading, 34)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(item.wrappedValue.failed ? Color.red.opacity(0.07) : Color.clear)
        .contextMenu {
            Button("Copy Title") { copy(item.wrappedValue.title) }
            Button("Mark Both Passed") { item.wrappedValue.web = .passed; item.wrappedValue.phone = .passed }
            Button("Reset Verdicts") { item.wrappedValue.web = .untested; item.wrappedValue.phone = .untested }
            Divider()
            Button("Delete Test Case", role: .destructive) { store.cases.removeAll { $0.id == item.wrappedValue.id } }
        }
    }

    /// Click cycles Untested → Passed → Failed → Blocked; right-click picks one directly.
    /// A plain Button, not a Menu: macOS menu buttons strip the label's colours.
    private func verdictChip(_ label: String, icon: String, verdict: Binding<Verdict>) -> some View {
        let v = verdict.wrappedValue
        let color: Color = switch v { case .passed: .green; case .failed: .red; case .blocked: .orange; case .untested: .secondary }
        let symbol = switch v { case .passed: "checkmark"; case .failed: "xmark"; case .blocked: "minus"; case .untested: icon }
        return Button {
            let all = Verdict.allCases
            verdict.wrappedValue = all[(all.firstIndex(of: v)! + 1) % all.count]
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(v == .untested ? Color.secondary : Color.white)
            .background(v == .untested ? Color.secondary.opacity(0.15) : color, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(Verdict.allCases, id: \.self) { option in Button(option.rawValue) { verdict.wrappedValue = option } }
        }
        .help("\(label): \(v.rawValue). Click to change, or right-click to choose.")
    }

    // === IMPORT / EXPORT ===

    private func load(_ text: String, from source: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http"), !trimmed.contains("\n"), !trimmed.contains(" ") {
            link = trimmed
            openLink()
            message = "Opened the link in Page view (\(store.browser.name)). To track verdicts, copy the test cases from the page and paste them in Checklist."
            return
        }
        let parsed = TestCaseParser.parse(trimmed)
        guard !parsed.isEmpty else { message = "Couldn't find any test cases in " + source + "."; return }
        if !store.cases.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Import \(parsed.count) test cases?"
            alert.informativeText = "You already have \(store.cases.count) cases here."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Add to List")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: store.cases = parsed
            case .alertSecondButtonReturn: store.cases += parsed
            default: return
            }
        } else {
            store.cases = parsed
        }
        filter = .all
        message = "Imported \(parsed.count) test cases from \(source). Click Web or Phone on a case to record a verdict."
    }

    private func pasteCases() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            message = "The clipboard has no text. Copy your test cases first."; return
        }
        load(text, from: "the clipboard")
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, UTType(filenameExtension: "md") ?? .plainText, .text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    private func importFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            message = "Couldn't read \(url.lastPathComponent) as text."; return
        }
        load(text, from: url.lastPathComponent)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyResults() {
        copy(store.report())
        message = "Results copied as Markdown. Paste them into Claude or an issue."
    }

    private func exportResults() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "test-results.md"
        panel.directoryURL = store.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.report().write(to: url, atomically: true, encoding: .utf8); message = "Saved " + url.lastPathComponent + "." }
        catch { message = error.localizedDescription }
    }
}
