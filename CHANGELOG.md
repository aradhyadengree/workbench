# Changelog

All notable user-visible changes. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). The version number lives in `VERSION`.

## [Unreleased]

## [0.12.0] - 2026-11-24

First open-source release.

### Added
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
- The **Claude Quad** mode is now called **Live Desk**. Your saved mode carries over.
- Claude agent pane permission now defaults to **Read only**, instead of skipping all permission checks. *Accept edits* and *Bypass all* are explicit choices, and Bypass asks for confirmation and is never remembered.
- New bundle identifier `io.github.aradhyadengree.workbench`. Settings from earlier builds are copied over automatically.
- Release builds are signed with Developer ID and notarized by Apple.
- The app version is read from `VERSION`, and the build number from the git commit count.

### Removed
- The agent pane's sample conversation, the non-functional rating strip, and the placeholder Undo button.
