#!/usr/bin/env perl
# alerts-setup.pl - switches the safe-ai-coding alerts on or off. The alerts are two
# Claude Code hooks: when Claude Code asks for a permission or asks a question, a
# sound plays until it is answered, and on Windows a popup shows the same question
# when the editor is not in front, so it can be answered from there. Part of the
# safe-ai-coding skill (the alerts command).
#
# Usage: perl alerts-setup.pl on|off|status|test [permission|question]
#        perl alerts-setup.pl sound on|off|test|<file>
#   on      adds the hooks to <config>/settings.json (PermissionRequest for every tool,
#           PreToolUse for AskUserQuestion), writes <config>/safe-ai-alerts.json with
#           the default alert settings if it does not exist, and switches on Claude
#           Code's mobile push "when actions are required" (inputNeededNotifEnabled)
#           unless you set that yourself. settings.json is copied once to
#           settings.json.bak-safe-ai-alerts before the first change.
#   off     removes exactly those hooks, and the mobile setting if "on" added it;
#           safe-ai-alerts.json stays, with your choices
#   status  shows what is installed
#   test    shows a sample popup (Windows) or plays the sound and notification
#           (macOS, Linux); nothing is sent to Claude Code
#   sound on|off   switches only the sound; the popup and the mobile push stay
#   sound <file>   uses this .wav, .mp3 or .wma file as the alert sound (and switches it on)
#   sound test     plays the chosen sound once
#   <config> is CLAUDE_CONFIG_DIR when set, else ~/.claude. The alerts work in every
#   project and session, whether the skill is on or off there.
# settings.json is rewritten with sorted keys and 2-space indentation; no other setting
# changes. A file that is not valid JSON, or a symlink, is never written.
# The hooks take effect in the next Claude Code session.
# Exit code: 0 done, 2 usage error or unusable settings file.
BEGIN { @INC = grep { $_ ne '.' && $_ ne '' } @INC }    # never load modules from the current directory
use strict;
use warnings;
use Cwd qw(realpath);
use File::Copy qw(copy);
use File::Spec ();
use FindBin ();
use JSON::PP ();

my $USAGE = "usage: perl alerts-setup.pl on|off|status|test [permission|question]\n"
          . '       perl alerts-setup.pl sound on|off|test|<file>';
my ($CMD, $KIND) = @ARGV;
fail($USAGE) unless defined $CMD && $CMD =~ /\A(?:on|off|status|test|sound)\z/ && @ARGV <= 2;
fail($USAGE) if $CMD eq 'sound' && !defined $KIND;
fail($USAGE) if defined $KIND && $CMD ne 'sound' && ($CMD ne 'test' || $KIND !~ /\A(?:permission|question)\z/);

my $WIN = $^O =~ /\A(?:MSWin32|msys|cygwin)\z/;
my $DIR = $ENV{CLAUDE_CONFIG_DIR} || (($ENV{HOME} // $ENV{USERPROFILE} // '.') . '/.claude');
my $SETTINGS = "$DIR/settings.json";
my $ALERTS = "$DIR/safe-ai-alerts.json";
my $SCRIPTS = realpath($FindBin::RealBin);
my @HOOKS = (['PermissionRequest', '*'], ['PreToolUse', 'AskUserQuestion']);
my %DEFAULTS = (enabled => JSON::PP::true(), sound_on => JSON::PP::true(), sound => '', repeat_every_seconds => 5, stop_after_seconds => 120,
                popup => 'when-away', popup_timeout_seconds => 300, focus_apps => ['Code', 'Code - Insiders', 'Cursor']);

exit run_test($KIND // 'permission') if $CMD eq 'test';
exit sound($KIND) if $CMD eq 'sound';

my $s = read_json($SETTINGS);
my $a = read_json($ALERTS);
if ($CMD eq 'status') { status(); exit 0 }

my $before = canon($s);
my $alerts_before = canon($a);
if ($CMD eq 'on') {
    strip_ours($s);
    my $cmd = hook_command();
    for my $h (@HOOKS) {
        my ($event, $matcher) = @$h;
        fail("settings.json: \"hooks\" is not an object; fix it by hand, nothing was changed")
            if exists $s->{hooks} && ref $s->{hooks} ne 'HASH';
        my $list = $s->{hooks}{$event} //= [];
        fail("settings.json: hooks.$event is not a list; fix it by hand, nothing was changed") unless ref $list eq 'ARRAY';
        push @$list, { matcher => $matcher, hooks => [ { type => 'command', command => $cmd, timeout => 600 } ] };
    }
    if (!exists $s->{inputNeededNotifEnabled}) {
        $s->{inputNeededNotifEnabled} = JSON::PP::true();
        $a->{mobile_push_added} = JSON::PP::true();
    }
    for my $k (keys %DEFAULTS) { $a->{$k} = $DEFAULTS{$k} unless exists $a->{$k} }
} else {
    strip_ours($s);
    if ($a->{mobile_push_added}) {
        delete $s->{inputNeededNotifEnabled};
        delete $a->{mobile_push_added};
    }
}

if (canon($s) ne $before) {
    copy($SETTINGS, "$SETTINGS.bak-safe-ai-alerts") if -f $SETTINGS && !-e "$SETTINGS.bak-safe-ai-alerts";
    write_json($SETTINGS, $s);
}
write_json($ALERTS, $a) if canon($a) ne $alerts_before && ($CMD eq 'on' || -f $ALERTS);

if ($CMD eq 'on') {
    print "safe-ai-coding alerts are on (hooks in $SETTINGS).\n";
    print "They take effect in the next Claude Code session, in every project.\n";
    print "Your sound, repeat and popup choices: $ALERTS\n";
    print "Mobile: start Remote Control (/rc) and use the Claude app to get a push when Claude needs you.\n";
} else {
    print "safe-ai-coding alerts are off (hooks removed from $SETTINGS). This takes effect in the next session.\n";
}
exit 0;

sub fail { print STDERR "alerts-setup: $_[0]\n"; exit 2 }

sub canon { JSON::PP->new->canonical->encode($_[0]) }

sub read_json {
    my ($path) = @_;
    my $name = $path =~ m{([^/\\]+)\z} ? $1 : $path;
    return {} unless -e $path || -l $path;
    fail("$name is a symlink; not touching it") if -l $path;
    open(my $fh, '<:raw', $path) or fail("cannot read $path: $!");
    my $text = do { local $/; <$fh> };
    close $fh;
    $text = '' unless defined $text;
    $text =~ s/\A\xEF\xBB\xBF//;
    return {} if $text !~ /\S/;
    my $data = eval { JSON::PP->new->utf8->decode($text) };
    fail("$path is not valid JSON; fix it by hand, nothing was changed") unless defined $data;
    fail("$path must hold a JSON object { ... }; nothing was changed") unless ref $data eq 'HASH';
    return $data;
}

sub write_json {
    my ($path, $data) = @_;
    mkdir $DIR unless -d $DIR;
    my $tmp = "$path.tmp$$";
    open(my $fh, '>:raw', $tmp) or fail("cannot write $path: $!");
    my $ok = print {$fh} JSON::PP->new->utf8->pretty->space_before(0)->canonical->indent_length(2)->encode($data);
    $ok = close($fh) && $ok;
    unless ($ok && rename($tmp, $path)) { my $e = "$!"; unlink $tmp; fail("cannot write $path: $e") }
}

sub winpath {
    my ($p) = @_;
    $p =~ s{\A/cygdrive/([a-zA-Z])/}{uc($1) . ':/'}e or $p =~ s{\A/([a-zA-Z])/}{uc($1) . ':/'}e;
    return $p;
}

sub hook_command {
    return 'powershell -NoProfile -STA -ExecutionPolicy Bypass -File "' . winpath("$SCRIPTS/alert-hook.ps1") . '"' if $WIN;
    return qq{bash "$SCRIPTS/alert-hook.sh"};
}

sub ours {
    my ($h) = @_;
    return 0 unless ref $h eq 'HASH';
    my $c = $h->{command} // '';
    return $c =~ /alert-hook\.(?:ps1|sh)/ && $c =~ /safe-ai-coding/;
}

# Removes our hook entries, and any group, event list or hooks object that only
# held them; everything else stays exactly as it was.
sub strip_ours {
    my ($set) = @_;
    my $hooks = $set->{hooks};
    return unless ref $hooks eq 'HASH';
    for my $event (keys %$hooks) {
        my $list = $hooks->{$event};
        next unless ref $list eq 'ARRAY';
        my $removed = 0;
        my @keep;
        for my $g (@$list) {
            if (ref $g eq 'HASH' && ref $g->{hooks} eq 'ARRAY' && grep { ours($_) } @{ $g->{hooks} }) {
                $g->{hooks} = [ grep { !ours($_) } @{ $g->{hooks} } ];
                $removed = 1;
                next unless @{ $g->{hooks} };
            }
            push @keep, $g;
        }
        next unless $removed;
        if (@keep) { $hooks->{$event} = \@keep } else { delete $hooks->{$event} }
        delete $set->{hooks} unless %$hooks;
        last unless $set->{hooks};
    }
}

sub installed {
    my ($event, $matcher) = @_;
    my $list = ref $s->{hooks} eq 'HASH' ? $s->{hooks}{$event} : undef;
    return 0 unless ref $list eq 'ARRAY';
    for my $g (@$list) {
        next unless ref $g eq 'HASH' && ($g->{matcher} // '') eq $matcher && ref $g->{hooks} eq 'ARRAY';
        return 1 if grep { ours($_) } @{ $g->{hooks} };
    }
    return 0;
}

sub status {
    print "safe-ai-coding alerts ($SETTINGS):\n";
    printf "  %-34s %s\n", 'permission prompts (every tool):', installed('PermissionRequest', '*') ? 'on' : 'off';
    printf "  %-34s %s\n", 'questions (AskUserQuestion):', installed('PreToolUse', 'AskUserQuestion') ? 'on' : 'off';
    my $m = $s->{inputNeededNotifEnabled};
    printf "  %-34s %s\n", 'mobile push when input is needed:',
        (defined $m && $m ? 'on' : 'off') . ' (needs Remote Control, /rc, and the Claude app)';
    my %c = (%DEFAULTS, %$a);
    my $sound = !$c{sound_on} ? 'off' : $c{sound} eq '' ? 'default' : $c{sound};
    printf "  %-34s %s\n", 'settings file:', -f $ALERTS ? $ALERTS : "$ALERTS (not created yet; defaults apply)";
    printf "  %-34s %s, every %s s, for up to %s s\n", 'sound:', $sound, $c{repeat_every_seconds}, $c{stop_after_seconds};
    printf "  %-34s %s\n", 'popup (Windows):', "$c{popup}, closes after $c{popup_timeout_seconds} s";
    printf "  %-34s %s\n", 'enabled:', $c{enabled} ? 'yes' : 'no (switched off in the settings file)';
}

sub sound {
    my ($what) = @_;
    if ($what eq 'test') {
        return run_hook_ps('-SoundTest') if $WIN;
        return run_test('permission');
    }
    my $al = read_json($ALERTS);
    for my $k (keys %DEFAULTS) { $al->{$k} = $DEFAULTS{$k} unless exists $al->{$k} }
    if ($what eq 'on' || $what eq 'off') {
        $al->{sound_on} = $what eq 'on' ? JSON::PP::true() : JSON::PP::false();
        write_json($ALERTS, $al);
        print "Alert sound is $what. The popup and the mobile push are not changed.\n";
        return 0;
    }
    my $file = realpath($what);
    fail("sound file not found: $what") unless defined $file && -f $file;
    fail("the sound must be a .wav, .mp3 or .wma file: $what") unless $file =~ /\.(?:wav|mp3|wma)\z/i;
    $file = winpath($file) if $WIN;
    $al->{sound} = $file;
    $al->{sound_on} = JSON::PP::true();
    write_json($ALERTS, $al);
    print "Alert sound: $file (on). Try it with: alerts sound test\n";
    return 0;
}

# powershell -File waits for an open stdin to end, so it gets an empty one.
sub run_hook_ps {
    open(my $saved, '<&', \*STDIN) or return 1;
    open(STDIN, '<', File::Spec->devnull) or return 1;
    my $rc = system('powershell', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', winpath("$SCRIPTS/alert-hook.ps1"), @_);
    open(STDIN, '<&', $saved);
    return $rc == 0 ? 0 : 1;
}

sub run_test {
    my ($kind) = @_;
    return run_hook_ps('-Test', $kind) if $WIN;
    open(my $h, '|-', 'bash', "$SCRIPTS/alert-hook.sh") or return 1;
    print {$h} '{"hook_event_name":"PermissionRequest","tool_name":"Bash","cwd":"' . ($ENV{PWD} // '') =~ s/["\\]//gr . '"}';
    close $h;
    print "Sound and notification started (three rings, as there is no transcript to watch).\n";
    return 0;
}
