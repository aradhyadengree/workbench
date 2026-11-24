# Contributing to Workbench

Thanks for helping. Workbench is a small native macOS app, so the loop is short: build, run, try it.

## Set up

Use macOS 14 or later, and Xcode if you're working on the simulator pane.

```sh
git clone https://github.com/aradhyadengree/workbench.git
cd workbench
swift run                 # quick dev loop
./scripts/build-app.sh    # full Workbench.app with icon and bundled resources
./scripts/check.sh        # lint + build; must pass before a PR (CI runs only the lint part)
```

Opening `Package.swift` in Xcode works too.

## Where things live

| Area | Files |
|---|---|
| App shell, menus, About panel | `Sources/Workbench/Workbench.swift` |
| Live Desk layout | `QuadWorkspace.swift`, `DeskLayout.swift` |
| Develop layout, files, editor | `Workspace.swift`, `PaneLayout.swift`, `Editor.swift`, `SyntaxHighlighter.swift` |
| Simulator | `PhoneSimulatorFrame.swift`, `SimulatorDisplay.swift`, `Sources/SimulatorHost/` |
| Terminals | `Terminal.swift`, `ChatConsole.swift`, `ANSIParser.swift`, `Sources/ShellPTY/` |
| Claude agent pane | `ClaudeAgentPane.swift` |
| Test Studio | `TestStudio.swift`, `TestRun.swift` |

Read [AGENTS.md](AGENTS.md) before touching the simulator bridge or the agent pane. It lists the
things that break in ways the compiler won't catch.

## Pull requests

- Keep each PR to one change. Open an issue first for anything large.
- Describe how you tested it. For visual changes, attach a screenshot. For simulator changes, include your macOS and Xcode versions.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for anything users will notice.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for messages, e.g. `fix(simulator): reconnect after Xcode switch`.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

## Code of conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
