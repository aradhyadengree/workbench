// Imports the user's login-shell environment into Workbench, once per launch.
//
// Why: an app opened from Finder or the Dock inherits launchd's minimal environment
// (PATH=/usr/bin:/bin:/usr/sbin:/sbin). Anything the user set up in ~/.zprofile / ~/.zshrc
// (Homebrew, nvm, pnpm, pyenv, JAVA_HOME…) is missing, so `npm` in the Terminal pane was
// "command not found". The Terminal pane runs `zsh -f` on purpose (its line-based renderer
// can't handle custom prompts or ZLE), so it can't source those files itself.
//
// How: run the user's own shell as an interactive login shell once, print its environment
// after a marker, and copy it into this process with setenv. Every child Workbench spawns
// afterwards (Terminal shells, chat, the agent pane, xcrun) inherits it. Same approach as
// VS Code's "resolve shell environment".
//
// Invariants:
// - Runs once, off the main thread, with a timeout; a broken rc file must never hang launch.
// - Variables that describe the resolving shell itself (PWD, SHLVL, TERM, prompts…) are not
//   imported; ShellPTY.c sets the terminal ones per pane.
// - Callers that spawn shells wait via `whenReady` so the first shell already has the PATH.

import Foundation

enum ShellEnvironment {
    private static let marker = "__WORKBENCH_ENV_7F3A__"
    private static let skipped: Set<String> = [
        "_", "PWD", "OLDPWD", "SHLVL", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
        "COLORTERM", "PS1", "PS2", "PROMPT", "RPROMPT", "PROMPT_EOL_MARK", "ZLE_RPROMPT_INDENT",
        "LINES", "COLUMNS", "SHELL_SESSION_ID", "__CF_USER_TEXT_ENCODING",
    ]
    private static let queue = DispatchQueue(label: "workbench.shell-environment")
    private static var state = State.idle
    private static var waiting: [() -> Void] = []
    private enum State { case idle, loading, ready }

    /// Starts resolving. Safe to call more than once; only the first call does any work.
    static func load() {
        queue.sync {
            guard state == .idle else { return }
            state = .loading
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let imported = resolve()
            DispatchQueue.main.async {
                for (key, value) in imported { setenv(key, value, 1) }
                let callbacks: [() -> Void] = queue.sync {
                    state = .ready
                    defer { waiting = [] }
                    return waiting
                }
                callbacks.forEach { $0() }
            }
        }
    }

    /// Runs `body` on the main thread once the environment is imported (immediately if it is).
    static func whenReady(_ body: @escaping () -> Void) {
        load()
        let ready: Bool = queue.sync {
            if state == .ready { return true }
            waiting.append(body)
            return false
        }
        if ready { body() }
    }

    private static func resolve() -> [String: String] {
        let shell = loginShell()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i -l: read the same files a new Terminal.app window would. The marker separates the
        // environment from anything the rc files print (banners, nvm notices).
        process.arguments = ["-ilc", "printf '%s\\n' \(marker); /usr/bin/env -0"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return [:] }

        // Reading must not block forever on a hung rc file: give up after 10 s.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return [:] }

        let output = String(decoding: data, as: UTF8.self)
        guard let range = output.range(of: marker + "\n") else { return [:] }
        var result: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            guard !key.isEmpty, !skipped.contains(key), !key.hasPrefix("BASH_FUNC_") else { continue }
            result[key] = String(entry[entry.index(after: eq)...])
        }
        // A resolved env without PATH means something went wrong; keep the one we have.
        return result["PATH"] == nil ? [:] : result
    }

    /// The user's shell from the account record, not $SHELL (launchd may not set it).
    private static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }
}


/// Writes the Terminal pane's zsh startup file (see ShellPTY.c). The pane can't source the
/// user's ~/.zshrc (its renderer is line-based), so this file adds back only shell functions
/// an imported environment can't carry, chiefly nvm with .nvmrc switching on cd.
/// Rewritten whenever the bundled text changes; returns nil (bare `zsh -f`) if it can't be.
enum TerminalPaneRC {
    static func directory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Workbench/terminal-zsh", isDirectory: true)
        let file = dir.appendingPathComponent(".zshrc")
        if (try? String(contentsOf: file, encoding: .utf8)) == script { return dir }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            return dir
        } catch { return nil }
    }

    private static let script = #"""
# Workbench Terminal pane startup. Written by Workbench at launch (TerminalPaneRC in
# ShellEnvironment.swift); edits here are overwritten.
#
# The pane renders output as plain lines, so the user's own ~/.zshrc (prompt themes, ZLE
# plugins) isn't sourced. Their PATH and other variables are already imported by
# ShellEnvironment.swift; this file adds only what an environment can't carry: shell functions.

# Nested zsh sessions the user starts must read their own dotfiles, not this one.
if [[ -n $WORKBENCH_USER_ZDOTDIR ]]; then export ZDOTDIR=$WORKBENCH_USER_ZDOTDIR; else unset ZDOTDIR; fi
unset WORKBENCH_USER_ZDOTDIR

# nvm is a shell function, not a program, so it has to be loaded here. --no-use keeps the
# imported default Node until a folder asks for another one via .nvmrc.
export NVM_DIR=${NVM_DIR:-$HOME/.nvm}
if [[ -s $NVM_DIR/nvm.sh ]]; then
  source "$NVM_DIR/nvm.sh" --no-use
  # Switch to a folder's .nvmrc version on cd, and back to the default on leaving it
  # (nvm's README "Calling nvm use automatically" recipe).
  _workbench_nvmrc() {
    local rc=$(nvm_find_nvmrc) current=$(nvm version)
    if [[ -n $rc ]]; then
      local want=$(nvm version "$(<"$rc")")
      if [[ $want == N/A ]]; then
        print "Node $(<"$rc") from ${rc:h:t}/.nvmrc isn't installed. Run: nvm install"
      elif [[ $want != $current ]]; then
        nvm use --silent && print "Using Node $(node -v) from ${rc:h:t}/.nvmrc"
      fi
    elif [[ $current != $(nvm version default) ]]; then
      nvm use default --silent && print "Back to default Node $(node -v)"
    fi
  }
  autoload -U add-zsh-hook
  add-zsh-hook chpwd _workbench_nvmrc
  _workbench_nvmrc
fi

PS1='%F{38;5;39}%1~%f %F{38;5;82}❯%f '
PROMPT_EOL_MARK=''
"""#
}
