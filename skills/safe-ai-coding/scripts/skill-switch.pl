#!/usr/bin/env perl
# skill-switch.pl - switches the safe-ai-coding skill off or on for one project
# through Claude Code's own settings, or shows its state there. Part of the
# safe-ai-coding skill (the off, on and status commands).
#
# Usage: perl skill-switch.pl off|on|status [--shared] [project-dir]
#   off          the skill no longer loads by itself in this project.
#                Folder install: "skillOverrides": {"safe-ai-coding": "user-invocable-only"},
#                so /safe-ai-coding on still works.
#                Plugin install: "enabledPlugins": {"safe-ai-coding@safe-ai-coding": false};
#                it comes back with /plugin, or with
#                claude plugin enable safe-ai-coding@safe-ai-coding --scope local
#   on           removes that entry again, or writes "on" / true when the other
#                settings file of the project switches the skill off
#   status       prints what the project's settings files say
#   --shared     write .claude/settings.json (the whole team, committed) instead of
#                .claude/settings.local.json (only you, not committed)
#   project-dir  default: the git repository of the current folder, else the current folder
#   SAFE_AI_INSTALL=folder|plugin  overrides the install type found from this script's path
# The settings file is rewritten with sorted keys and 2-space indentation; no other
# setting in it changes. A file that is not valid JSON, or a symlink, is never written.
# The change takes effect in the next Claude Code session.
# Exit code: 0 done, 2 usage error or unusable settings file.
BEGIN { @INC = grep { $_ ne '.' && $_ ne '' } @INC }    # never load modules from the current directory
use strict;
use warnings;
use File::Spec ();
use FindBin ();
use JSON::PP ();

my $NAME   = 'safe-ai-coding';
my $PLUGIN = 'safe-ai-coding@safe-ai-coding';
my $USAGE  = 'usage: perl skill-switch.pl off|on|status [--shared] [project-dir]';

my ($cmd, $shared, $dir);
for my $arg (@ARGV) {
    if ($arg eq '--shared') { $shared = 1 }
    elsif ($arg eq '-h' || $arg eq '--help') { print "$USAGE\n"; exit 0 }
    elsif ($arg =~ /\A-/) { fail("unknown option $arg\n$USAGE") }
    elsif (!defined $cmd) { $cmd = $arg }
    elsif (!defined $dir) { $dir = $arg }
    else { fail($USAGE) }
}
fail($USAGE) unless defined $cmd && $cmd =~ /\A(?:off|on|status)\z/;
if (!defined $dir) {
    $dir = qx(git -c core.fsmonitor=false rev-parse --show-toplevel 2>/dev/null);
    chomp $dir;
    $dir = '.' if $? != 0 || $dir eq '';
}
fail("not a folder: $dir") unless -d $dir;

my $install = $ENV{SAFE_AI_INSTALL} // '';
$install = $FindBin::RealBin =~ m{[\\/]\.claude[\\/]plugins[\\/]} ? 'plugin' : 'folder'
    unless $install =~ /\A(?:folder|plugin)\z/;
my $plugin = $install eq 'plugin';
my ($map, $key) = $plugin ? ('enabledPlugins', $PLUGIN) : ('skillOverrides', $NAME);

my %FILE = (local => '.claude/settings.local.json', team => '.claude/settings.json');
my %WHO  = (local => 'only you', team => 'whole team');
my %S    = map { $_ => read_settings($_) } qw(local team);

if ($cmd eq 'status') {
    print "$NAME in $dir ($install install):\n";
    printf "  %-28s %-12s %s\n", $FILE{$_}, "($WHO{$_})", shown($S{$_}) for qw(local team);
    print '  result: ', (is_off(effective()) ? 'off: it does not load by itself' : 'on'), "\n";
    exit 0;
}

my ($mine, $other) = $shared ? ('team', 'local') : ('local', 'team');
my $s = $S{$mine}{data};
fail("$FILE{$mine}: \"$map\" is not an object; fix it by hand, nothing was changed")
    if exists $s->{$map} && ref $s->{$map} ne 'HASH';
my $before = JSON::PP->new->canonical->encode($s);

if ($cmd eq 'off') {
    $s->{$map}{$key} = $plugin ? JSON::PP::false() : 'user-invocable-only';
} elsif (is_off(value($S{$other}))) {
    $s->{$map}{$key} = $plugin ? JSON::PP::true() : 'on';
} else {
    delete $s->{$map}{$key} if $s->{$map};
    delete $s->{$map} if $s->{$map} && !%{ $s->{$map} };
}

if (JSON::PP->new->canonical->encode($s) eq $before) {
    print "$NAME is already $cmd in $FILE{$mine} of $dir; nothing changed.\n";
} else {
    write_settings($mine, $s);
    print "$NAME is now $cmd in $dir (written to $FILE{$mine}, $WHO{$mine}).\n";
}
if ($cmd eq 'off') {
    print $plugin
        ? "It comes back with /plugin, or: claude plugin enable $PLUGIN --scope " . ($shared ? 'project' : 'local') . "\n"
        : "It no longer loads by itself here; /$NAME on switches it back.\n";
} elsif (is_off(value($S{$other})) && $mine eq 'team') {
    print "Note: your own $FILE{local} still switches it off here.\n";
}
print "This takes effect in the next Claude Code session.\n";
gitignore_hint() unless $shared;
exit 0;

sub fail { print STDERR "skill-switch: $_[0]\n"; exit 2 }

sub read_settings {
    my ($which) = @_;
    my $path = "$dir/$FILE{$which}";
    return { data => {}, exists => 0 } unless -e $path || -l $path;
    fail("$FILE{$which} is a symlink; not touching it") if -l $path;
    open(my $fh, '<:raw', $path) or fail("cannot read $FILE{$which}: $!");
    my $text = do { local $/; <$fh> };
    close $fh;
    $text = '' unless defined $text;
    $text =~ s/\A\xEF\xBB\xBF//;
    return { data => {}, exists => 1 } if $text !~ /\S/;
    my $data = eval { JSON::PP->new->utf8->decode($text) };
    fail("$FILE{$which} is not valid JSON; fix it by hand, nothing was changed") unless defined $data;
    fail("$FILE{$which} must hold a JSON object { ... }; nothing was changed") unless ref $data eq 'HASH';
    return { data => $data, exists => 1 };
}

sub write_settings {
    my ($which, $data) = @_;
    mkdir "$dir/.claude" unless -d "$dir/.claude";
    my $path = "$dir/$FILE{$which}";
    my $tmp = "$path.tmp$$";
    open(my $fh, '>:raw', $tmp) or fail("cannot write $FILE{$which}: $!");
    my $ok = print {$fh} JSON::PP->new->utf8->pretty->space_before(0)->canonical->indent_length(2)->encode($data);
    $ok = close($fh) && $ok;
    unless ($ok && rename($tmp, $path)) { my $e = "$!"; unlink $tmp; fail("cannot write $FILE{$which}: $e") }
}

sub value { my $m = $_[0]{data}{$map}; return ref $m eq 'HASH' ? $m->{$key} : undef }

sub effective { my $v = value($S{local}); return defined $v ? $v : value($S{team}) }

sub is_off {
    my ($v) = @_;
    return 0 unless defined $v;
    return $plugin ? !$v : ($v eq 'off' || $v eq 'user-invocable-only');
}

sub shown {
    my ($f) = @_;
    return 'no file' unless $f->{exists};
    my $v = value($f);
    return 'not set' unless defined $v;
    return $plugin ? ($v ? 'true' : 'false') : "\"$v\"";
}

# settings.local.json is personal: warn when git would commit it.
sub gitignore_hint {
    open(my $saved, '>&', \*STDERR) or return;
    open(STDERR, '>', File::Spec->devnull);    # "not a git repository" is not worth showing
    my $rc = system('git', '-c', 'core.fsmonitor=false', '-C', $dir, 'check-ignore', '-q', '--', $FILE{local});
    open(STDERR, '>&', $saved);
    print "Note: git does not ignore $FILE{local}; add it to .gitignore so it is not committed.\n" if $rc >> 8 == 1;
}
