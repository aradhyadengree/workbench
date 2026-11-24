import SwiftUI
import WebKit

final class TestTargets: ObservableObject {
    @Published var web = Browser()
    @Published var phone = Browser()
    func reset() { web = Browser(); phone = Browser() }
}

struct TestStudio: View {
    @ObservedObject var web: Browser
    @ObservedObject var phone: Browser
    @Binding var device: String
    let storageKey: String
    @State private var run = TestRun()
    @State private var address = ""
    @AppStorage("testNativeMobile") private var native = false
    @State private var capturing = false
    @State private var evidenceMessage = ""
    @State private var sheet: Sheet?
    @State private var issue = ""
    @State private var visible = "Both"
    @Environment(\.colorScheme) private var colorScheme

    enum Sheet: String, Identifiable { case check, results; var id: String { rawValue } }

    private var passedCount: Int {
        run.checks.filter { $0.web == .passed && $0.mobile == .passed }.count
    }
    private var failedCount: Int {
        run.checks.filter { $0.web == .failed || $0.mobile == .failed }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // URL & Test Controls Header
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WorkbenchTheme.toolColor(.browser))

                TextField("Product URL, e.g. http://localhost:3000", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { loadProduct() }

                Button("Load", action: loadProduct)
                    .buttonStyle(.borderedProminent)
                    .tint(WorkbenchTheme.toolColor(.browser))

                Divider().frame(height: 18)

                Button {
                    sheet = .check
                } label: {
                    Label("Record Check", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                }

                Button {
                    sheet = .results
                } label: {
                    HStack(spacing: 6) {
                        Label("Results (\(run.checks.count))", systemImage: "list.clipboard.fill")
                        if failedCount > 0 {
                            Text("\(failedCount) failed")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                                .foregroundStyle(.white)
                        } else if passedCount > 0 {
                            Text("\(passedCount) pass")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding(10)
            .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)

            Divider()

            // Viewport & Target Selector Bar
            HStack {
                Picker("Show", selection: $visible) {
                    ForEach(["Both", "Web", "Mobile"], id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Button {
                    captureEvidence()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.fill")
                        Text("Capture Evidence")
                    }
                }
                .help("Save screenshots of visible targets and current test report")
                .disabled(capturing || (!web.started && !phone.started && (!native || device.isEmpty)))

                Picker("Mobile target", selection: $native) {
                    Text("Phone Browser").tag(false)
                    Text("iOS Simulator").tag(true)
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(colorScheme == .dark ? WorkbenchTheme.darkElevated : WorkbenchTheme.lightElevated)

            Divider()

            if !evidenceMessage.isEmpty {
                HStack {
                    Image(systemName: evidenceMessage.contains("incomplete") ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(evidenceMessage.contains("incomplete") ? Color.orange : Color.green)
                    Text(evidenceMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer()
                    Button { evidenceMessage = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
            }

            if !web.started && !phone.started && !native && web.issue.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 48))
                        .foregroundStyle(WorkbenchTheme.toolColor(.browser))
                    Text("Cross-Platform Test Studio")
                        .font(.title2.bold())
                    Text("Enter your app's localhost address or hosted URL above to test desktop and mobile side-by-side.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button("Connect an iOS Simulator build…") {
                        native = true
                        visible = "Both"
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if visible != "Mobile" {
                            surface(web, title: "Desktop Web", icon: "desktopcomputer")
                        }
                        if visible == "Both" {
                            Divider()
                        }
                        if visible != "Web" {
                            Group {
                                if native {
                                    SimulatorPane(active: $device)
                                } else {
                                    surface(phone, title: "Phone Browser (390px)", icon: "iphone")
                                        .frame(maxWidth: 390)
                                }
                            }
                            .frame(width: visible == "Both" ? min(405, geometry.size.width * 0.45) : geometry.size.width)
                            .frame(maxHeight: .infinity)
                            .background(colorScheme == .dark ? WorkbenchTheme.darkElevated : WorkbenchTheme.lightElevated)
                        }
                    }
                }
            }
        }
        .onAppear {
            if let data = UserDefaults.standard.data(forKey: storageKey),
               let stored = try? JSONDecoder().decode(TestRun.self, from: data) { run = stored }
            address = web.started ? web.address : run.address
        }
        .onChange(of: native) {
            if !native && web.started && phone.address != address {
                phone.address = address
                phone.go()
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .check:
                CheckForm { title, webResult, mobileResult, note in
                    let target = native ? "iOS Simulator " + (device.isEmpty ? "(disconnected)" : device) :
                        "Phone browser · " + (phone.page.url?.absoluteString ?? "No URL loaded")
                    run.checks.append(TestCheck(
                        title: title, web: webResult, mobile: mobileResult,
                        note: note, address: web.page.url?.absoluteString ?? "",
                        mobileTarget: target
                    ))
                    persist()
                    sheet = nil
                }
            case .results:
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Test Results").font(.title2.bold())
                        Spacer()
                        Button("Done") { sheet = nil }
                    }
                    if run.checks.isEmpty {
                        ContentUnavailableView("No checks recorded", systemImage: "list.clipboard",
                                               description: Text("Try a flow, then record the outcome for each platform."))
                    } else {
                        List(run.checks.reversed()) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).fontWeight(.semibold)
                                HStack(spacing: 8) {
                                    verdictBadge(label: "Web", verdict: item.web)
                                    verdictBadge(label: "Mobile", verdict: item.mobile)
                                }
                                if !item.note.isEmpty {
                                    Text(item.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        HStack {
                            Button("Export Markdown…", action: export)
                            if !issue.isEmpty { Text(issue).foregroundStyle(.red) }
                        }
                    }
                }
                .padding(20)
                .frame(width: 540, height: 400)
            }
        }
    }

    private func verdictBadge(label: String, verdict: Verdict) -> some View {
        let color: Color
        switch verdict {
        case .passed: color = .green
        case .failed: color = .red
        case .blocked: color = .orange
        case .untested: color = .secondary
        }
        return HStack(spacing: 4) {
            Text(label + ":")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verdict.rawValue)
                .font(.caption2.bold())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    private func surface(_ browser: Browser, title: String, icon: String) -> some View {
        VStack(spacing: 0) {
            PaneBar(title: title, icon: icon, iconColor: WorkbenchTheme.toolColor(.browser)) {
                Button { browser.page.goBack() } label: { Image(systemName: "chevron.left") }.help("Back")
                Button { if browser.page.url != nil { browser.page.reload() } else { browser.go() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("Reload")
            }
            if !browser.issue.isEmpty {
                Text(browser.issue).font(.caption).foregroundStyle(.orange).padding(6)
            }
            if browser.started {
                WebSurface(page: browser.page)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: icon).font(.title).foregroundStyle(.secondary)
                    Text("Load a URL to test here").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadProduct() {
        web.address = address
        web.go()
        if !native {
            phone.address = address
            phone.go()
        }
        if web.issue.isEmpty {
            run.address = address
            persist()
        }
    }

    @MainActor private func captureEvidence() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Evidence Here"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        let output = root.appendingPathComponent("Workbench-check-" + UUID().uuidString.prefix(8))
        let webPage = visible != "Mobile" && web.started ? web.page : nil
        let mobilePage = visible != "Web" && !native && phone.started ? phone.page : nil
        let simulator = visible != "Web" && native ? device : ""
        guard webPage != nil || mobilePage != nil || !simulator.isEmpty else {
            evidenceMessage = "Load or connect a visible target first."
            return
        }
        let report = run.report
        capturing = true
        Task {
            defer { capturing = false }
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                for (page, name) in [(webPage, "web.png"), (mobilePage, "phone-web.png")] {
                    guard let page else { continue }
                    let image = try await page.takeSnapshot(configuration: nil)
                    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                          let data = bitmap.representation(using: .png, properties: [:]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: output.appendingPathComponent(name), options: .atomic)
                }
                if !simulator.isEmpty {
                    _ = try await simctl(["io", simulator, "screenshot", output.appendingPathComponent("ios.png").path])
                }
                try report.write(to: output.appendingPathComponent("test-results.md"), atomically: true, encoding: .utf8)
                evidenceMessage = "Evidence saved to " + output.path
            } catch {
                evidenceMessage = "Capture incomplete at " + output.path + ". " + error.localizedDescription
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(run), forKey: storageKey)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "product-test-run.md"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try run.report.write(to: file, atomically: true, encoding: .utf8)
            issue = ""
        } catch {
            issue = error.localizedDescription
        }
    }
}

private struct CheckForm: View {
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var web = Verdict.untested
    @State private var mobile = Verdict.untested
    @State private var note = ""
    let save: (String, Verdict, Verdict, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record a Test Check").font(.title2.bold())
            TextField("Flow tested, e.g. User login with OAuth", text: $title)
                .textFieldStyle(.roundedBorder)

            ForEach(["Web", "Mobile"], id: \.self) { label in
                Picker(label, selection: label == "Web" ? $web : $mobile) {
                    ForEach(Verdict.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            TextField("Observations or steps to reproduce", text: $note, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Check") { save(title, web, mobile, note) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (web == .untested && mobile == .untested))
            }
        }
        .padding(20)
        .frame(width: 490)
    }
}
