// Claude agent pane (Develop mode → "Claude" tab).
//
// Drives the separately installed Claude Code CLI headlessly: one `claude -p` process per
// prompt, reading `--output-format stream-json --verbose` events line by line. Workbench never
// talks to an API itself and never stores credentials — the CLI owns auth, models and limits.
//
// Invariants:
// - Conversation continuity is by session id: the first prompt passes `--session-id <uuid>`,
//   later prompts pass `--resume <uuid>`. Clearing the pane starts a new id. (Verified against
//   Claude Code 2.1.x; both flags are documented in `claude --help`.)
// - The prompt goes in on stdin, never argv, so a prompt starting with "-" can't be read as a flag.
// - Permission defaults to read-only. "Bypass" maps to `bypassPermissions`, needs an explicit
//   confirmation, and is never persisted — every launch starts safe.
// - Everything shown in the pane comes from real CLI events; there is no sample/mock content.
import SwiftUI
import AppKit

// === MODEL ===

struct AgentActivity: Identifiable {
    let id = UUID()
    let icon: String
    let color: Color
    let label: String
}

struct ClaudeMessage: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    var activity: [AgentActivity] = []
    var running = false
    var isError = false
    var duration: String?

    enum Role { case user, assistant }
}

enum AgentPermission: String, CaseIterable {
    case readOnly = "Read only"
    case acceptEdits = "Accept edits"
    case bypass = "Bypass all"

    /// `--permission-mode` value; nil keeps the CLI default, which in `-p` mode declines any
    /// tool call that would need an interactive approval.
    var cliMode: String? {
        switch self {
        case .readOnly: nil
        case .acceptEdits: "acceptEdits"
        case .bypass: "bypassPermissions"
        }
    }
    var color: Color {
        switch self {
        case .readOnly: .secondary
        case .acceptEdits: .green
        case .bypass: .red
        }
    }
    var help: String {
        switch self {
        case .readOnly: "Claude can read the project. Edits and commands that need approval are declined."
        case .acceptEdits: "Claude may edit files in the project. Other commands that need approval are declined."
        case .bypass: "Claude runs every tool without asking, including shell commands."
        }
    }
}

enum AgentModel: String, CaseIterable {
    case cliDefault = "CLI default", fable = "Fable", opus = "Opus", sonnet = "Sonnet", haiku = "Haiku"
    /// CLI aliases resolve to the latest model of each family, so this list doesn't go stale.
    var alias: String? { self == .cliDefault ? nil : rawValue.lowercased() }
}

// === STATE + PROCESS ===

final class ClaudeAgentState: ObservableObject {
    @Published var messages: [ClaudeMessage] = []
    @Published var prompt = ""
    @Published var isRunning = false
    @Published var permission: AgentPermission = AgentPermission(
        rawValue: UserDefaults.standard.string(forKey: "agentPermission") ?? "") ?? .readOnly {
        didSet {
            // Bypass is deliberately not remembered across launches.
            if permission != .bypass { UserDefaults.standard.set(permission.rawValue, forKey: "agentPermission") }
        }
    }
    @Published var model: AgentModel = AgentModel(
        rawValue: UserDefaults.standard.string(forKey: "agentModel") ?? "") ?? .cliDefault {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "agentModel") }
    }

    private var sessionID = UUID()
    private var sessionStarted = false
    private var process: Process?

    static func findCLI() -> String? {
        searchPath.map { $0 + "/claude" }.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// Apps launched from Finder get a minimal PATH, so add the usual install locations.
    private static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin", home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
    }

    func send(in folder: URL, onFinish: @escaping () -> Void = {}) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty else { return }
        messages.append(ClaudeMessage(role: .user, text: text))
        prompt = ""

        guard let executable = Self.findCLI() else {
            messages.append(ClaudeMessage(role: .assistant,
                text: "Claude Code wasn’t found. Install it (https://claude.com/claude-code), sign in once in a terminal, then send again.",
                isError: true))
            prompt = text
            return
        }

        var args = ["-p", "--output-format", "stream-json", "--verbose"]
        args += sessionStarted ? ["--resume", sessionID.uuidString.lowercased()]
                               : ["--session-id", sessionID.uuidString.lowercased()]
        if let alias = model.alias { args += ["--model", alias] }
        if let mode = permission.cliMode { args += ["--permission-mode", mode] }

        let reply = ClaudeMessage(role: .assistant, text: "", running: true)
        messages.append(reply)
        isRunning = true
        run(executable: executable, args: args, prompt: text, folder: folder, replyID: reply.id, onFinish: onFinish)
    }

    func stop() { process?.terminate() }

    func clear() {
        guard !isRunning else { return }
        messages.removeAll()
        sessionID = UUID()
        sessionStarted = false
    }

    private func run(executable: String, args: [String], prompt: String, folder: URL,
                     replyID: UUID, onFinish: @escaping () -> Void) {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = folder
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPath.joined(separator: ":")
        process.environment = env
        self.process = process
        let started = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(prompt.utf8))
                try? stdin.fileHandleForWriting.close()
            } catch {
                DispatchQueue.main.async { self?.finish(replyID, error: error.localizedDescription, started: started, onFinish: onFinish) }
                return
            }
            // stream-json is one JSON object per line; a read can end mid-line, so buffer bytes.
            var pending = Data()
            let reader = stdout.fileHandleForReading
            while case let chunk = reader.availableData, !chunk.isEmpty {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    DispatchQueue.main.async { self?.handle(event, replyID: replyID) }
                }
            }
            process.waitUntilExit()
            let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = process.terminationStatus, reason = process.terminationReason
            DispatchQueue.main.async {
                guard let self else { return }
                let failed = reason == .uncaughtSignal ? "Stopped."
                    : status != 0 ? (errorText.isEmpty ? "Claude exited with status \(status)." : errorText) : nil
                self.finish(replyID, error: failed, started: started, onFinish: onFinish)
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout ClaudeMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func handle(_ event: [String: Any], replyID: UUID) {
        if event["session_id"] != nil { sessionStarted = true }
        switch event["type"] as? String {
        case "assistant":
            let blocks = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { update(replyID) { $0.text += ($0.text.isEmpty ? "" : "\n\n") + text } }
                case "tool_use":
                    let item = Self.activity(name: block["name"] as? String ?? "Tool",
                                             input: block["input"] as? [String: Any] ?? [:])
                    update(replyID) { $0.activity.append(item) }
                default: break
                }
            }
        case "result":
            if event["is_error"] as? Bool == true {
                let detail = event["result"] as? String ?? (event["subtype"] as? String ?? "error")
                update(replyID) { $0.isError = true; if $0.text.isEmpty { $0.text = detail } }
            }
        default: break
        }
    }

    private func finish(_ id: UUID, error: String?, started: Date, onFinish: () -> Void) {
        update(id) { message in
            message.running = false
            message.duration = String(format: "%.1fs", Date().timeIntervalSince(started))
            if let error, message.text.isEmpty || error == "Stopped." {
                message.isError = true
                message.text += (message.text.isEmpty ? "" : "\n\n") + error.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        process = nil
        isRunning = false
        onFinish()
    }

    /// Maps a Claude Code tool call to a one-line activity row. Unknown tools fall through to
    /// a generic row so new CLI tools still show up.
    static func activity(name: String, input: [String: Any]) -> AgentActivity {
        let file = ((input["file_path"] ?? input["notebook_path"]) as? String).map { ($0 as NSString).lastPathComponent }
        switch name {
        case "Read": return AgentActivity(icon: "doc.text", color: .cyan, label: "Read " + (file ?? "file"))
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return AgentActivity(icon: "pencil", color: .orange, label: (name == "Write" ? "Wrote " : "Edited ") + (file ?? "file"))
        case "Bash":
            let command = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return AgentActivity(icon: "terminal", color: .green, label: "$ " + command)
        case "Grep", "Glob":
            return AgentActivity(icon: "magnifyingglass", color: .purple, label: name + " " + (input["pattern"] as? String ?? ""))
        case "WebFetch", "WebSearch":
            return AgentActivity(icon: "globe", color: .blue, label: name + " " + ((input["url"] ?? input["query"]) as? String ?? ""))
        default:
            return AgentActivity(icon: "wrench.and.screwdriver", color: .secondary, label: name)
        }
    }
}

// === VIEW ===

struct ClaudeAgentPane: View {
    @ObservedObject var state: ClaudeAgentState
    let folder: URL
    var onFinish: () -> Void = {}
    @State private var confirmBypass = false
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { Color(red: 0.85, green: 0.45, blue: 0.98) }
    private var canSend: Bool { !state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.isRunning }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if state.messages.isEmpty { emptyState }
                        ForEach(state.messages) { messageView($0) }
                        Color.clear.frame(height: 1).id("chat_end")
                    }
                    .padding(14)
                }
                .onChange(of: state.messages.count) { withAnimation { proxy.scrollTo("chat_end", anchor: .bottom) } }
                .onChange(of: state.messages.last?.activity.count) { proxy.scrollTo("chat_end", anchor: .bottom) }
            }
            .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
            inputDock
        }
        .alert("Let Claude run every tool without asking?", isPresented: $confirmBypass) {
            Button("Bypass Permissions", role: .destructive) { state.permission = .bypass }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claude will be able to run shell commands and change files in \(folder.lastPathComponent) with no prompts. This setting resets when Workbench quits.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            Text("Claude").font(.system(size: 13, weight: .bold))
            Spacer()
            Menu {
                ForEach(AgentPermission.allCases, id: \.self) { mode in
                    Button {
                        if mode == .bypass { confirmBypass = true } else { state.permission = mode }
                    } label: {
                        if state.permission == mode { Label(mode.rawValue, systemImage: "checkmark") } else { Text(mode.rawValue) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(state.permission.color).frame(width: 6, height: 6)
                    Text(state.permission.rawValue).font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(state.permission.help)
            .disabled(state.isRunning)

            Menu {
                ForEach(AgentModel.allCases, id: \.self) { model in
                    Button {
                        state.model = model
                    } label: {
                        if state.model == model { Label(model.rawValue, systemImage: "checkmark") } else { Text(model.rawValue) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(state.model.rawValue).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Model passed to the Claude CLI")
            .disabled(state.isRunning)

            Button { state.clear() } label: { Image(systemName: "square.and.pencil").font(.system(size: 11)) }
                .disabled(state.isRunning || state.messages.isEmpty)
                .help("New conversation")
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder).frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask Claude about " + folder.lastPathComponent).font(.headline)
            Text(ClaudeAgentState.findCLI() == nil
                 ? "Install Claude Code and sign in once in a terminal to use this pane."
                 : "Runs the Claude Code CLI in this folder. " + state.permission.help)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var inputDock: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this project…", text: $state.prompt, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { state.send(in: folder, onFinish: onFinish) }
            if state.isRunning {
                Button { state.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22)).foregroundStyle(.red)
                }
                .buttonStyle(.plain).help("Stop Claude")
            } else {
                Button { state.send(in: folder, onFinish: onFinish) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        .foregroundStyle(canSend ? accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain).disabled(!canSend).help("Send (Return)")
            }
        }
        .padding(10)
        .background(colorScheme == .dark ? WorkbenchTheme.darkElevated : WorkbenchTheme.lightElevated)
        .overlay(alignment: .top) {
            Rectangle().fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder).frame(height: 1)
        }
    }

    /// Inline markdown (bold, code, links) without collapsing the CLI's line breaks.
    private func rich(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder private func messageView(_ msg: ClaudeMessage) -> some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(msg.activity) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).font(.system(size: 11)).foregroundStyle(item.color).frame(width: 14)
                        Text(item.label).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
                if !msg.text.isEmpty {
                    Text(rich(msg.text))
                        .font(.system(size: 13))
                        .foregroundStyle(msg.isError ? Color.red : Color.primary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    if msg.running {
                        ProgressView().controlSize(.mini)
                        Text(msg.activity.isEmpty ? "Thinking…" : "Working…")
                    } else if let duration = msg.duration {
                        Image(systemName: msg.isError ? "exclamationmark.triangle" : "checkmark")
                        Text(duration)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }
}
