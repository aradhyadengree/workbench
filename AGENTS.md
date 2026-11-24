# Workbench: agent guide

A native macOS (SwiftUI + AppKit) workspace for testing a product on web and iOS side by side:
terminal chat, an embedded iOS Simulator display, a browser, and shells, plus a small editor
("Develop") and a per-platform test recorder ("Test Studio"). Swift Package, no Xcode project.

## Commands

| What | Command |
|---|---|
| Dev run | `swift run` |
| Build the .app | `./scripts/build-app.sh` → `./Workbench.app` (gitignored) |
| Fast checks (all CI runs, on Linux) | `./scripts/lint.sh` |
| Full local gate (lint + build + .app) | `./scripts/check.sh` |
| Release artifacts | `./scripts/package-release.sh` → `dist/` (universal DMG + zip + SHA256SUMS) |

There are no unit tests yet. Verify UI changes by building and running the app.

## Structure

- `Sources/Workbench/`: the app. `Workbench.swift` (app, menus, `Project` model, About), `QuadWorkspace.swift` (Live Desk grid) + `DeskState.swift` (its layout, pop-out pane windows, focus, Live Desk menu), `Workspace.swift` (Develop mode + toolbar), `ClaudeAgentPane.swift` (headless `claude -p` runner), `TestStudio.swift`, `Terminal.swift` (shells, splits) on `XTerm.swift` (the shared xterm.js page + bridge), `ProjectCommands.swift` (shortcut chips).
- `Sources/SimulatorHost/`: Obj-C bridge into Xcode's **private** SimulatorKit/CoreSimulator.
- `Sources/ShellPTY/`: C helpers for forking PTY shells.
- `Sources/Workbench/ChatTerminal/`: vendored xterm.js page behind every terminal (chat pane and Terminal pane).
- `VERSION`: the only place the app version lives. `build-app.sh` writes it into Info.plist.

## Conventions

- Conventional Commits. User-visible changes get a line under `## [Unreleased]` in CHANGELOG.md.
- Theme colors come from `WorkbenchTheme` (Theme.swift), not inline values in new code.
- Keep README feature claims true: if you rename a button, grep README.md for its label.

## Landmines

- **SimulatorHost uses mangled Swift symbols** (`$s12SimulatorKit14SimDisplayViewC…`) called with the `swiftcall` ABI. They are specific to an Xcode version (developed on Xcode 26.6). Don't "clean up" the typedefs or attributes. Any change needs a real Xcode + simulator runtime to test, because the compiler can't check it.
- **SimulatorKit can only be loaded once per process.** Switching Xcode needs an app restart (`WBLoadSimulatorKit` enforces this on purpose).
- **Resource bundle name is load-bearing.** `ChatConsole` looks up `Workbench_Workbench.bundle` in `Contents/Resources`, the name SwiftPM derives from package + target. Renaming the package or target breaks the chat pane in the packaged app only. `swift run` keeps working, so you won't notice.
- **`xterm.js` is vendored and minified.** Don't reformat it. Its `LICENSE` must ship next to it (`check.sh` enforces this).
- **Shell environment is imported once at launch** (`ShellEnvironment.swift`): the user's login shell prints its env, which is `setenv`'d into the app so non-shell children (agent pane, xcrun, git) get the user's PATH. New shell-spawning code must go through `ShellEnvironment.whenReady`. Test with `env -i HOME=$HOME PATH=/usr/bin:/bin ./.build/debug/Workbench`, not from your own shell, which already has the PATH.
- **Terminal pane shells run `zsh -il` through wrapper dotfiles** (`TerminalPaneRC`, `ZDOTDIR` set only for that shell in `ShellPTY.c`). Each wrapper sources the user's own file. Then `.zshrc` restores `ZDOTDIR`, points `HISTFILE` back at the user's history, and adds the `.nvmrc` hook. Keep that order and the restores, or nested shells, `.zlogin` and history will read Workbench's directory instead of the user's.
- **Terminal output uses backpressure**: the PTY reader is suspended until xterm.js has parsed each chunk (`XTermPage.write` completion). A suspended `DispatchSource` must be resumed before it is cancelled (`Shell.stop`), or libdispatch crashes. WebKit doesn't repaint a test window that sits behind other windows, so check terminal output by reading `terminal.buffer`, not a screenshot.
- **Agent pane safety invariants** (`ClaudeAgentPane.swift`): permission defaults to Read only, and `.bypass` is never written to UserDefaults (`check.sh` greps for this). The prompt goes in on stdin, not argv. Continuity relies on `--session-id` for the first prompt and `--resume` after.
- **Bundle id is `io.github.aradhyadengree.workbench`** (build-app.sh). It's also the defaults domain, so changing it resets every user's settings. Pre-0.12 builds used `local.workbench.ide`, and `Lifecycle.migrateLegacyDefaults` copies those settings across once.
- **Release signing** happens in `package-release.sh`: Developer ID + hardened runtime + notarytool profile `workbench-notary`. No entitlements are needed. If you add one, re-verify that the simulator pane still loads SimulatorKit.
- **UserDefaults keys are user state:** `paneLayout`, `deskLayout`, `workspaceViewMode`, `projectFolder`, `agentPermission`, `agentModel`, `showFiles`/`showShell` (legacy migration), `productTests.<folder path>`, `testCases.<folder path>` / `testCasesPage.<folder path>` / `testCasesView.<folder path>`, `testPlanBrowser` (Test cases pane), `deskLayoutAddedCases` (one-time layout migration), `deskDetached` + AppKit's `NSWindow Frame LiveDeskPane.<pane title>` (popped-out panes). Renaming one silently resets users' layouts or test history.
- **Repo URL appears in four places:** `AboutPanel.repository` (Workbench.swift), README.md, `.github/ISSUE_TEMPLATE/config.yml`, SECURITY.md / CODE_OF_CONDUCT.md. Move them together.
- **Two resource-bundle layouts.** A single-arch `swift build` emits a flat `Workbench_Workbench.bundle/ChatTerminal`. A universal build (`--arch arm64 --arch x86_64`, which uses Xcode's build system) emits `…bundle/Contents/Resources/ChatTerminal`. `Bundle.url(forResource:…subdirectory:)` resolves both, so keep using it rather than building paths by hand.
- **`DeskTool` raw values are pane titles and are persisted** in `deskLayout`. Renaming one drops that pane from saved layouts. A new pane needs a one-time migration like `DeskState.savedLayout()`, and the migration must write the layout back, or the pane vanishes on the next launch.
- **Live Desk panes can move between windows**, so their state must live in `Project` (`targets`, `simulatorUDID`, `testCases`, `desk`), never in a pane view's `@State`/`@StateObject`, or popping out restarts it. Web views go through `WebSurface`, whose container-host design is load-bearing (see its guard comment).
- **What's New** (`WhatsNew.swift`) auto-opens once per `VERSION`. Update its `highlights` with CHANGELOG.md on every version bump.
- `Workbench.app/` is a build product. Never commit it (`check.sh` fails if it's tracked).
