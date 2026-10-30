#!/usr/bin/env bash
# alert-hook.sh - macOS and Linux part of the safe-ai-coding alerts, run by Claude
# Code as a hook. When Claude Code asks for a permission (PermissionRequest) or asks
# a question (PreToolUse on AskUserQuestion), it shows a system notification and
# plays a sound until the question is answered. It never answers anything, so
# Claude Code's own prompt always stays. Windows uses alert-hook.ps1, which also
# has the answer popup. Installed by alerts-setup.pl.
#
# Settings: <claude config dir>/safe-ai-alerts.json: enabled, sound_on, sound (a file
# afplay, mpg123, ffplay, paplay or aplay can play), repeat_every_seconds, stop_after_seconds.
# Exit code: always 0; it prints nothing.

set -u
input=$(cat)
command -v perl >/dev/null 2>&1 || exit 0
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/safe-ai-alerts.json"

# One line from the hook input and the settings, fields separated by \037.
vals=$(printf '%s' "$input" | perl -e '
  BEGIN { @INC = grep { $_ ne "." && $_ ne "" } @INC }
  use JSON::PP ();
  my $raw = do { local $/; <STDIN> };
  my $in = eval { JSON::PP->new->decode($raw) } || {};
  my $c = {};
  if (open my $f, "<", $ARGV[0]) { my $t = do { local $/; <$f> }; $c = eval { JSON::PP->new->decode($t) } || {} }
  my $ev = $in->{hook_event_name} // ""; my $tool = $in->{tool_name} // "";
  my $ask = $ev eq "PermissionRequest" || ($ev eq "PreToolUse" && $tool eq "AskUserQuestion" && !$in->{tool_input}{answers});
  my $on = !(exists $c->{enabled} && !$c->{enabled});
  my $num = sub { my ($v, $d, $lo, $hi) = @_; $v = $d unless defined $v && $v =~ /\A\d+\z/; $v < $lo ? $lo : $v > $hi ? $hi : $v };
  (my $proj = $in->{cwd} // "") =~ s{.*/}{};
  $proj =~ s/[^A-Za-z0-9 ._-]//g;
  (my $snd = $c->{sound} // "") =~ s/[\x00-\x1f]//g;
  $snd = "none" if exists $c->{sound_on} && !$c->{sound_on};
  (my $tr = $in->{transcript_path} // "") =~ s/[\x00-\x1f]//g;
  print join("\037", ($ask && $on) ? 1 : 0, $snd, $num->($c->{repeat_every_seconds}, 5, 1, 60),
             $num->($c->{stop_after_seconds}, 120, 5, 540), $tr, length $proj ? $proj : "your project");
' "$CFG")
IFS=$'\037' read -r go sound every stop transcript proj <<< "$vals"
[ "${go:-0}" = 1 ] || exit 0

mac=0; [ "$(uname -s)" = Darwin ] && mac=1
if [ -z "$sound" ]; then
  if [ "$mac" = 1 ]; then sound=/System/Library/Sounds/Glass.aiff; else sound=/usr/share/sounds/freedesktop/stereo/message.oga; fi
fi

ding() {
  [ "$sound" = none ] && return
  if [ "$mac" = 1 ]; then afplay "$sound"
  elif [ "${sound##*.}" = mp3 ] && command -v mpg123 >/dev/null 2>&1; then mpg123 -q "$sound"
  elif [ "${sound##*.}" = mp3 ] && command -v ffplay >/dev/null 2>&1; then ffplay -nodisp -autoexit -loglevel quiet "$sound"
  elif command -v paplay >/dev/null 2>&1; then paplay "$sound"
  elif command -v aplay >/dev/null 2>&1; then aplay -q "$sound"
  else printf '\a' > /dev/tty; fi
}

notify() {
  msg="Claude Code needs your answer in $proj"    # $proj holds only letters, digits, space, dot, dash and underscore
  if [ "$mac" = 1 ]; then osascript -e "display notification \"$msg\" with title \"Claude Code\""
  elif command -v notify-send >/dev/null 2>&1; then notify-send "Claude Code" "$msg"; fi
}

size() { if [ -n "$transcript" ] && [ -f "$transcript" ]; then wc -c < "$transcript" | tr -d ' '; else echo -1; fi; }
base=$(size)
# Answered = a tool result was written to the transcript after the question appeared.
answered() { [ "$base" -ge 0 ] && [ "$(size)" -gt "$base" ] && tail -c +"$((base + 1))" "$transcript" | grep -q '"tool_result"'; }

(
  notify
  end=$((SECONDS + stop)); rings=0
  while [ "$SECONDS" -lt "$end" ]; do
    answered && break
    ding
    rings=$((rings + 1))
    [ "$base" -lt 0 ] && [ "$rings" -ge 3 ] && break    # no transcript to watch: ring three times only
    sleep "$every"
  done
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
exit 0
