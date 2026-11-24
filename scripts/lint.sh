#!/bin/sh
# Fast repo checks with no build, so they run anywhere (CI runs them on Linux).
#   ./scripts/lint.sh
# Called by .github/workflows/checks.yml on every push/PR and by scripts/check.sh locally.
# Prints one line per problem and exits 1 if any check fails.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
problem() { echo "FAIL: $*"; fail=1; }

# 1. Shell scripts are clean (skipped if shellcheck isn't installed locally).
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh || problem "shellcheck"
else
  echo "skip: shellcheck not installed"
fi

# 2. Never commit build products, release artifacts, or signing material.
bad=$(git ls-files | grep -E '(^|/)(\.build|Workbench\.app|dist)/|\.(p12|pfx|key|pem|cer|certSigningRequest|mobileprovision|p8)$|(^|/)\.env' || true)
[ -z "$bad" ] || problem "files that must not be committed:
$bad"

# 3. No hidden-Unicode tricks (bidi overrides/isolates, tag characters) in source or docs.
#    Vendored, minified xterm.js is excluded. The Perl program is single-quoted on purpose:
#    $ARGV and $. are Perl variables, not shell ones.
# shellcheck disable=SC2016
hidden=$(git ls-files -z -- '*.swift' '*.m' '*.h' '*.c' '*.sh' '*.md' '*.yml' '*.html' '*.js' '*.css' \
  ':!Sources/Workbench/ChatTerminal/xterm.js' \
  | xargs -0 perl -CSD -ne 'print "$ARGV:$.\n" if /[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{E0000}-\x{E007F}]/; close ARGV if eof' 2>/dev/null || true)
[ -z "$hidden" ] || problem "hidden bidi/tag Unicode at:
$hidden"

# 4. VERSION is semver and CHANGELOG.md has a section for it.
version=$(tr -d '[:space:]' < VERSION)
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || problem "VERSION '$version' isn't x.y.z"
grep -q "^## \[$version\]" CHANGELOG.md || problem "CHANGELOG.md has no '## [$version]' section"

# 5. App invariants a compiler can't catch (see AGENTS.md → Landmines).
[ -f Sources/Workbench/ChatTerminal/LICENSE ] || problem "xterm.js LICENSE missing next to the vendored copy"
grep -q 'if permission != .bypass' Sources/Workbench/ClaudeAgentPane.swift \
  || problem "agent pane must never persist Bypass permission mode"
grep -q '"Live Desk"' Sources/Workbench/Workspace.swift || problem "Live Desk mode title missing"

[ "$fail" -eq 0 ] && echo "lint OK"
exit "$fail"
