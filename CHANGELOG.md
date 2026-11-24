# Changelog

All notable user-visible changes. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). The version number lives in `VERSION`.

## [Unreleased]

## [0.12.0] - 2026-11-24

First open-source release.

### Added
- **Test cases** pane in Live Desk. **Page** view opens your test plan's link (such as a Claude artifact) and remembers it per project, inside the pane (one claude.ai sign-in, remembered) or in any installed browser you pick. **Checklist** view imports pasted or dropped test cases (.md/.txt/.csv), tracks Web and Phone verdicts with notes, and copies the results back as Markdown.
- Browser panes no longer ignore new-window requests: sign-in pop-ups (such as Continue with Google) open in their own window, and `target=_blank` links open in place. Built-in browsers identify as Safari so sign-in pages accept them.
- **Layout → Testing Layout**: Terminal chat, Test cases, Simulator and Browser side by side at full height, with the shell hidden.
- **Layout** menu can show or hide any pane.
- **Pop-out panes**: open any Live Desk pane in its own window (header button or ⌥⌘N), move it to another screen, pin it on top, and dock it back. Pages, terminals and chats stay live while they move, and popped-out panes reopen where you left them.
- **Split terminals**: ⌘D splits the Terminal pane side by side, ⇧⌘D stacks it (up to four shells, draggable dividers). Each split is its own shell; the split button's menu stacks, unstacks or unsplits.
- **Live Desk** menu with shortcuts: ⌥⌘1–5 show or hide panes, ⇧⌘↩ expands the focused pane, ⌘\\ hides it. The last-clicked pane is outlined as focused.
- Universal (Apple Silicon + Intel) DMG and zip downloads, built by `scripts/package-release.sh`.
- A **What's New** sheet that appears once after each update. It's also in the Help menu and the status-bar version button.
- MIT license, README, contributing guide, security policy, and issue/PR templates.
- App icon and an **About Workbench** panel showing the version and license.
- **Help** menu links to the repository and issue tracker.
- A **Checks** workflow on every push and pull request: shellcheck, forbidden files, hidden Unicode, VERSION/CHANGELOG, and app invariants (`scripts/lint.sh`).
- Claude agent pane: a real model picker (CLI default, Fable, Opus, Sonnet, Haiku) passed to the CLI.
- Claude agent pane: follow-up prompts continue the same conversation; **New conversation** starts fresh.
- Claude agent pane: a **Stop** button, and live activity rows for files read, edits, and commands.
- The file tree and Git badges refresh when a Claude run finishes.

### Changed
- **Layout → Restore Photo Layout** is now **Default Layout**.
- The **Claude Quad** mode is now called **Live Desk**. Your saved mode carries over.
- Claude agent pane permission now defaults to **Read only**, instead of skipping all permission checks. *Accept edits* and *Bypass all* are explicit choices, and Bypass asks for confirmation and is never remembered.
- New bundle identifier `io.github.aradhyadengree.workbench`. Settings from earlier builds are copied over automatically.
- Release builds are signed with Developer ID and notarized by Apple.
- The app version is read from `VERSION`, and the build number from the git commit count.

### Fixed
- The Terminal pane now has your shell's environment (PATH from `~/.zprofile`/`~/.zshrc`, so Homebrew, nvm, pnpm and friends). Opened from the Dock, it only had macOS's minimal PATH, so `npm` was "command not found".
- `nvm` works in the Terminal pane, and `cd` into a folder with a `.nvmrc` switches to that Node version (and back to your default when you leave).

### Removed
- The agent pane's sample conversation, the non-functional rating strip, and the placeholder Undo button.
