#!/usr/bin/env bash
# html-to-pdf.sh - prints a local, self-contained HTML file to PDF with a headless
# Chromium browser (Chrome, Edge, Chromium, Brave) or wkhtmltopdf. Part of the
# safe-ai-coding skill (report mode). Each browser gets a fresh private profile
# and a time limit; if one fails or hangs, the next one is tried.
#
# Usage: bash html-to-pdf.sh <input.html> <output.pdf>
#   SAFE_AI_PDF_BROWSER=<path>   try this browser first
#   SAFE_AI_PDF_TIMEOUT=<sec>    time limit per converter (default 90)
# Exit code: 0 PDF written, 1 every converter failed, 2 usage error or no converter.

set -u
umask 077
IN=${1:-}; OUT=${2:-}
if [ -z "$IN" ] || [ -z "$OUT" ]; then echo "usage: bash html-to-pdf.sh <input.html> <output.pdf>" >&2; exit 2; fi
case "$IN$OUT" in -*) echo "html-to-pdf: paths must not start with '-'" >&2; exit 2 ;; esac
case "$IN" in *.html|*.htm|*.HTML|*.HTM) ;; *) echo "html-to-pdf: input must be an .html file" >&2; exit 2 ;; esac
[ -f "$IN" ] || { echo "html-to-pdf: input not found: $IN" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")" || exit 2
LIMIT=${SAFE_AI_PDF_TIMEOUT:-90}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=90 ;; esac

ABS_IN=$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")
ABS_OUT=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
WIN=0; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1 ;; esac
native() { if [ "$WIN" = 1 ] && command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
fileurl() {   # file:/// URL with percent-encoding of everything outside a safe set
  local p=$1
  [ "$WIN" = 1 ] && command -v cygpath >/dev/null 2>&1 && p=$(cygpath -m "$p")
  printf '%s' "$p" | LC_ALL=C awk 'BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
    { out = ""; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1)
        if (c ~ /[A-Za-z0-9._~\/:-]/) out = out c; else out = out sprintf("%%%02X", ord[c]) }
      sub(/^\/+/, "", out); printf "file:///%s", out }'
}
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout "$LIMIT" "$@"; else "$@"; fi; }
sanitize() { LC_ALL=C sed 's/[[:cntrl:]]/?/g' | tail -n 5; }

candidates=()
[ -n "${SAFE_AI_PDF_BROWSER:-}" ] && candidates+=("$SAFE_AI_PDF_BROWSER")
if [ "$WIN" = 1 ]; then
  for p in "/c/Program Files/Google/Chrome/Application/chrome.exe" "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
           "${LOCALAPPDATA:-/nonexistent}/Google/Chrome/Application/chrome.exe" \
           "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" "/c/Program Files/Microsoft/Edge/Application/msedge.exe" \
           "/c/Program Files/BraveSoftware/Brave-Browser/Application/brave.exe"; do
    [ -f "$p" ] && candidates+=("$p")
  done
fi
for p in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
  [ -f "$p" ] && candidates+=("$p")
done
for n in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge microsoft-edge-stable brave-browser; do
  p=$(command -v "$n" 2>/dev/null) && candidates+=("$p")
done
WK=$(command -v wkhtmltopdf 2>/dev/null || true)
if [ "${#candidates[@]}" = 0 ] && [ -z "$WK" ]; then
  echo "html-to-pdf: no Chrome, Edge, Chromium, Brave or wkhtmltopdf found." >&2
  echo "Open $IN in a browser and use Print > Save as PDF, or set SAFE_AI_PDF_BROWSER." >&2
  exit 2
fi

ok() { [ -s "$ABS_OUT" ] && [ "$(head -c 4 "$ABS_OUT" 2>/dev/null)" = "%PDF" ]; }
URL=$(fileurl "$ABS_IN")
errors=""
for b in ${candidates[@]+"${candidates[@]}"}; do
  [ -f "$b" ] || continue
  PROFILE=$(mktemp -d 2>/dev/null) || continue
  rm -f "$ABS_OUT"
  log=$(with_timeout "$b" --headless=new --disable-gpu --no-first-run --no-default-browser-check --disable-extensions \
        --disable-background-networking --disable-component-update --disable-sync --disable-default-apps --mute-audio \
        --user-data-dir="$(native "$PROFILE")" --no-pdf-header-footer --print-to-pdf="$(native "$ABS_OUT")" "$URL" 2>&1)
  rc=$?
  rm -rf "$PROFILE" 2>/dev/null
  if ok; then echo "PDF: $OUT ($(basename "$b"))"; exit 0; fi
  [ "$rc" = 124 ] && why="timed out after ${LIMIT}s" || why="exit $rc"
  errors="$errors
$(basename "$b"): $why: $(printf '%s' "$log" | sanitize)"
done
if [ -n "$WK" ]; then
  rm -f "$ABS_OUT"
  log=$(with_timeout "$WK" --quiet --disable-javascript --print-media-type --page-size A4 --enable-local-file-access "$(native "$ABS_IN")" "$(native "$ABS_OUT")" 2>&1)
  if ok; then echo "PDF: $OUT (wkhtmltopdf)"; exit 0; fi
  errors="$errors
wkhtmltopdf: $(printf '%s' "$log" | sanitize)"
fi
echo "html-to-pdf: every converter failed:$errors" >&2
echo "Open $IN in a browser and use Print > Save as PDF." >&2
exit 1
