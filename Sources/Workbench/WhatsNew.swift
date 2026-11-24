// "What's New" sheet: shown once after each version change, and from Help → What's New.
//
// The version comes from Info.plist (filled from ./VERSION by scripts/build-app.sh). Under
// `swift run` there is no plist, the version reads "dev", and the sheet never auto-opens.
// `highlights` is a short, user-facing summary of the matching CHANGELOG.md section — update
// both together when bumping VERSION.
import SwiftUI
import AppKit

struct WhatsNew: View {
    let dismiss: () -> Void

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// True once per installed version; marks it seen so the next launch stays quiet.
    static var shouldShowOnLaunch: Bool {
        let key = "lastSeenVersion", version = currentVersion
        guard version != "dev", UserDefaults.standard.string(forKey: key) != version else { return false }
        UserDefaults.standard.set(version, forKey: key)
        return true
    }

    private struct Highlight: Identifiable {
        let icon: String, color: Color, title: String, detail: String
        var id: String { title }
    }

    private let highlights = [
        Highlight(icon: "rectangle.split.3x1", color: .blue, title: "Live Desk",
                  detail: "The testing desk (formerly Claude Quad): chat, iPhone, browser and shell side by side."),
        Highlight(icon: "macwindow.on.rectangle", color: .indigo, title: "Pop panes out",
                  detail: "Open any Live Desk pane in its own window, put it on another screen, and dock it back when you're done (⌥⌘N)."),
        Highlight(icon: "terminal", color: .orange, title: "Real terminals",
                  detail: "Every shell runs your own zsh setup in a full terminal. Split it with ⌘D, and run your project's scripts from the shortcut chips."),
        Highlight(icon: "checklist", color: .teal, title: "Test cases next to your app",
                  detail: "Open your Claude artifact in your own browser or inside the pane, or paste the cases into a checklist and mark Web and Phone as you test."),
        Highlight(icon: "sparkles", color: .purple, title: "A real Claude agent pane",
                  detail: "Develop → Claude now remembers the conversation, shows each file read, edit and command, and has a Stop button."),
        Highlight(icon: "lock.shield", color: .green, title: "Safe by default",
                  detail: "The agent starts in Read only. Accept edits and Bypass all are explicit choices, and Bypass resets every launch."),
        Highlight(icon: "heart", color: .pink, title: "Open source",
                  detail: "Workbench is now MIT licensed. Find the code and report issues from the Help menu."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 4) {
                Text("What's New in Workbench").font(.title2.bold())
                Text("Version " + Self.currentVersion).font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(highlights) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(item.color)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Button("Release Notes") {
                    NSWorkspace.shared.open(AboutPanel.repository.appendingPathComponent("releases"))
                }
                Spacer()
                Button("Continue", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}
