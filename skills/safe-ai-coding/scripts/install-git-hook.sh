#!/usr/bin/env bash
# install-git-hook.sh - adds a git pre-commit hook to the current repository that
# runs the safe-ai-coding review scan and blocks a commit with HIGH findings
# (secrets, injection, destructive changes, elided code...). Part of the
# safe-ai-coding skill. Run it yourself: an agent must ask before changing git hooks.
#
# Usage: bash install-git-hook.sh            install in the current repository
#        bash install-git-hook.sh --remove   remove the hook this script installed
# Exit code: 0 done, 1 refused (another pre-commit hook exists), 2 not a git repository.
# To skip the check once after reviewing the findings: git commit --no-verify

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GITDIR=$(git rev-parse --git-dir 2>/dev/null) || { echo "install-git-hook: not inside a git repository" >&2; exit 2; }
HOOKDIR=$(git rev-parse --git-path hooks)
HOOK="$HOOKDIR/pre-commit"
MARK="# installed by safe-ai-coding"

if [ "${1:-}" = --remove ]; then
  if [ -f "$HOOK" ] && grep -q "$MARK" "$HOOK"; then rm -f "$HOOK"; echo "removed $HOOK"; exit 0; fi
  echo "no safe-ai-coding hook found at $HOOK"; exit 0
fi
if [ -f "$HOOK" ] && ! grep -q "$MARK" "$HOOK"; then
  echo "install-git-hook: $HOOK already exists and was not installed by safe-ai-coding; not touching it." >&2
  echo "Add this line to it yourself:  bash \"$HERE/diff-check.sh\" --fail-on=high HEAD" >&2
  exit 1
fi
mkdir -p "$HOOKDIR"
cat > "$HOOK" <<EOF
#!/usr/bin/env bash
$MARK
# Blocks the commit when the safe-ai-coding scan finds a HIGH item.
if [ -f "$HERE/diff-check.sh" ]; then
  bash "$HERE/diff-check.sh" --fail-on=high HEAD || {
    echo
    echo "safe-ai-coding: commit blocked by HIGH findings above. Fix them, or after a real review: git commit --no-verify"
    exit 1
  }
fi
EOF
chmod +x "$HOOK"
echo "installed $HOOK (remove with: bash \"$HERE/install-git-hook.sh\" --remove)"
