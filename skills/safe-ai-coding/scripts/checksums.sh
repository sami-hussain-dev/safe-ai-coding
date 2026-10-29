#!/usr/bin/env bash
# checksums.sh - verify (or, for maintainers, write) CHECKSUMS.sha256 for the
# safe-ai-coding skill folder, so a copy you received can be checked for files
# that were changed, removed or added after it was packaged.
#
# Usage: bash checksums.sh            verify every file against CHECKSUMS.sha256
#        bash checksums.sh --write    regenerate CHECKSUMS.sha256 (maintainers only)
# Exit code: 0 every file matches, 1 a file is changed, missing or unexpected, 2 on errors.
#
# A checksum file shipped inside the same zip only catches accidental or partial
# changes. To trust a copy, compare the SHA-256 this script prints for
# CHECKSUMS.sha256 itself with the value the sender gave you another way.

set -u
SKILL=$(cd "$(dirname "$0")/.." && pwd)
cd "$SKILL" || exit 2
if command -v sha256sum >/dev/null 2>&1; then SUM="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SUM="shasum -a 256"
else echo "checksums: need sha256sum or shasum" >&2; exit 2; fi
hash_of() { $SUM "$1" | awk '{ print $1 }'; }
files() { find . -type f ! -name CHECKSUMS.sha256 ! -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort; }

if [ "${1:-}" = --write ]; then
  files | while IFS= read -r f; do printf '%s  %s\n' "$(hash_of "$f")" "$f"; done > CHECKSUMS.sha256
  echo "wrote CHECKSUMS.sha256 for $(wc -l < CHECKSUMS.sha256 | tr -d ' ') files"
  echo "SHA-256 of CHECKSUMS.sha256: $(hash_of CHECKSUMS.sha256)  (give this to recipients separately)"
  exit 0
fi

[ -f CHECKSUMS.sha256 ] || { echo "checksums: CHECKSUMS.sha256 not found in $SKILL" >&2; exit 2; }
bad=0; listed=$(mktemp) || exit 2
trap 'rm -f "$listed"' EXIT
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  [ -n "$line" ] || continue
  want=${line%%  *}; f=${line#*  }
  printf '%s\n' "$f" >> "$listed"
  if [ ! -f "$f" ]; then echo "MISSING     $f"; bad=1
  elif [ "$(hash_of "$f")" != "$want" ]; then echo "CHANGED     $f"; bad=1; fi
done < CHECKSUMS.sha256
files | while IFS= read -r f; do grep -qxF -- "$f" "$listed" || echo "UNEXPECTED  $f"; done > "$listed.extra"
if [ -s "$listed.extra" ]; then cat "$listed.extra"; bad=1; fi
rm -f "$listed.extra"
echo "SHA-256 of CHECKSUMS.sha256: $(hash_of CHECKSUMS.sha256)  (compare with the value the sender gave you)"
if [ "$bad" = 0 ]; then echo "OK: every file matches CHECKSUMS.sha256"; exit 0; fi
echo "NOT OK: the skill folder differs from what was packaged; do not use it until you know why" >&2
exit 1
