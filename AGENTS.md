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

- `Sources/Workbench/`: the app. `Workbench.swift` (app, menus, `Project` model, About), `QuadWorkspace.swift` (Live Desk mode), `Workspace.swift` (Develop mode + toolbar), `ClaudeAgentPane.swift` (headless `claude -p` runner), `TestStudio.swift`.
- `Sources/SimulatorHost/`: Obj-C bridge into Xcode's **private** SimulatorKit/CoreSimulator.
- `Sources/ShellPTY/`: C helpers for forking PTY shells.
- `Sources/Workbench/ChatTerminal/`: vendored xterm.js page for the terminal-chat pane.
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
- **Agent pane safety invariants** (`ClaudeAgentPane.swift`): permission defaults to Read only, and `.bypass` is never written to UserDefaults (`check.sh` greps for this). The prompt goes in on stdin, not argv. Continuity relies on `--session-id` for the first prompt and `--resume` after.
- **Bundle id is `io.github.aradhyadengree.workbench`** (build-app.sh). It's also the defaults domain, so changing it resets every user's settings. Pre-0.12 builds used `local.workbench.ide`, and `Lifecycle.migrateLegacyDefaults` copies those settings across once.
- **Release signing** happens in `package-release.sh`: Developer ID + hardened runtime + notarytool profile `workbench-notary`. No entitlements are needed. If you add one, re-verify that the simulator pane still loads SimulatorKit.
- **UserDefaults keys are user state:** `paneLayout`, `deskLayout`, `workspaceViewMode`, `projectFolder`, `agentPermission`, `agentModel`, `showFiles`/`showShell` (legacy migration), `productTests.<folder path>`. Renaming one silently resets users' layouts or test history.
- **Repo URL appears in four places:** `AboutPanel.repository` (Workbench.swift), README.md, `.github/ISSUE_TEMPLATE/config.yml`, SECURITY.md / CODE_OF_CONDUCT.md. Move them together.
- **Two resource-bundle layouts.** A single-arch `swift build` emits a flat `Workbench_Workbench.bundle/ChatTerminal`. A universal build (`--arch arm64 --arch x86_64`, which uses Xcode's build system) emits `…bundle/Contents/Resources/ChatTerminal`. `Bundle.url(forResource:…subdirectory:)` resolves both, so keep using it rather than building paths by hand.
- **What's New** (`WhatsNew.swift`) auto-opens once per `VERSION`. Update its `highlights` with CHANGELOG.md on every version bump.
- `Workbench.app/` is a build product. Never commit it (`check.sh` fails if it's tracked).
