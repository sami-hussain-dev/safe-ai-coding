#!/usr/bin/env perl
# hidden-unicode.pl - reads NUL-separated file paths on stdin and prints every
# line that contains invisible or direction-changing unicode, with the hidden
# characters made visible. Part of the safe-ai-coding skill (used by repo-scan.sh).
#
# Usage: <paths, NUL-separated> | perl hidden-unicode.pl [path-prefix-to-skip]
#
# Flagged: bidi embeddings/overrides/isolates (U+202A-202E, U+2066-2069), tag
# characters (U+E0000-E007F), zero-width space (U+200B), word joiner and
# invisible operators (U+2060-2064), and a BOM anywhere but the start of a line.
# Left out on purpose: ZWNJ/ZWJ (U+200C/200D) and LRM/RLM (U+200E/200F), which
# Urdu, Arabic, Persian and Hebrew text use legitimately.
BEGIN { @INC = grep { $_ ne '.' && $_ ne '' } @INC }    # never load modules from the scanned repository
use strict;
use warnings;

my $skip = shift // '';
my $re = qr/\xE2\x80[\x8B\xAA-\xAE]|\xE2\x81[\xA0-\xA4\xA6-\xA9]|\xF3\xA0[\x80\x81][\x80-\xBF]|(?<=.)\xEF\xBB\xBF/;

sub codepoint {
    my @b = map { ord } split //, shift;
    return (($b[0] & 0x0F) << 12) | (($b[1] & 0x3F) << 6) | ($b[2] & 0x3F) if @b == 3;
    return (($b[0] & 0x07) << 18) | (($b[1] & 0x3F) << 12) | (($b[2] & 0x3F) << 6) | ($b[3] & 0x3F);
}

my %seen;
local $/ = "\0";
while (my $f = <STDIN>) {
    chomp $f;
    next if $f eq '' || $seen{$f}++;
    next if $skip ne '' && index($f, $skip) == 0;
    next unless -f $f && -s _ && -s _ < 5_000_000;
    open(my $fh, '<:raw', $f) or next;
    read($fh, my $head, 8000);
    if (defined $head && $head =~ /\0/) { close $fh; next }    # binary
    seek($fh, 0, 0);
    # Third-party and minified code often carries such bytes as encoded data.
    my $thirdparty = $f =~ m{(^|/)(node_modules|vendor|bower_components|site-packages)/|\.min\.[a-z]+$};
    local $/ = "\n";
    my $n = 0;
    while (my $line = <$fh>) {
        $n++;
        next unless $line =~ $re;
        my $at = $-[0];
        my $from = $at > 60 ? $at - 60 : 0;
        my $show = substr($line, $from, 160);
        $show =~ s/($re)/sprintf("<U+%04X>", codepoint($1))/ge;
        $show =~ s/[\r\n]+$//;
        $show = "...$show" if $from > 0;
        my $tag = ($thirdparty || length($line) > 1000) ? "TP\t" : "";
        print "$tag$f:$n: $show\n";
    }
    close $fh;
}
