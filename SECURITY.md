# Security Policy

## Reporting a vulnerability

Please **don't** open a public issue. Report it privately through
[GitHub Security Advisories](https://github.com/aradhyadengree/workbench/security/advisories/new).
Include the steps to reproduce and the Workbench version (Workbench → About Workbench).
You should hear back within a week.

## Supported versions

Only the latest release on `main` receives fixes.

## What Workbench can do on your machine

Workbench is a developer tool, and by design it runs code on your machine:

- It starts shells with your user account in the project folder you open.
- It runs the `claude` CLI when you ask it to. The agent pane defaults to **Read only**. **Accept edits** lets Claude change files. **Bypass all** lets Claude run any command without asking, needs a confirmation, and resets every launch.
- It loads Xcode's private simulator frameworks into its own process to embed the iPhone display.
- The browser panes load whatever URL you enter.

Reports that show Workbench doing any of these *without* the user asking, or doing more than
described here, are in scope.
