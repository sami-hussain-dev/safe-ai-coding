#!/usr/bin/env perl
# symbol-check.pl - flags references, on the lines a change adds, to things that
# do not exist in the repository: PHP classes, traits and static methods,
# Laravel views, Blade components, route names and config files, and relative
# JS/TS and Python imports. These are typical AI "hallucinations": a name that
# is invented, misspelled, not imported or not created yet. A name that differs
# from the real file only in letter case is flagged too: it works on Windows and
# macOS but fails on Linux. Part of the safe-ai-coding skill (diff-check.sh calls it).
#
# Usage: perl symbol-check.pl <diff-file> [<self-prefix>]    (run it from the repository root)
#   diff-file    git diff -U0 --no-color --no-ext-diff -M <base>, with untracked
#                files appended as new-file blocks
#   self-prefix  path prefix whose files are skipped (the skill's own folder)
# Output: one TSV line per finding, sorted by file and line:
#   SEVERITY  FILE  LINE  MESSAGE  SNIPPET
#   WARN = the reference does not resolve; INFO = it may still come from a package.
# Exit code: 0, also when there are findings; 2 when the diff file cannot be read.
# It only reads files inside the repository; it never runs, loads or includes them.
BEGIN { @INC = grep { $_ ne '.' && $_ ne '' } @INC }
use strict;
use warnings;
use Cwd qw(realpath);

my $MAX = 2_000_000;    # bytes: larger files are never read
my ($DIFF, $SELF) = @ARGV;
$SELF = '' unless defined $SELF;
if (!defined $DIFF || $DIFF eq '') {
    print STDERR "usage: perl symbol-check.pl <diff-file> [<self-prefix>]\n";
    exit 2;
}
my $DFH;
if (-d $DIFF || !open($DFH, '<:raw', $DIFF)) {
    print STDERR "symbol-check: cannot read diff file: $DIFF\n";
    exit 2;
}
my $ROOT = realpath('.');
if (!defined $ROOT) {
    print STDERR "symbol-check: cannot resolve the current directory\n";
    exit 2;
}
binmode STDOUT;
binmode STDERR;
# Windows and macOS file systems ignore letter case by default.
my $FOLD = $^O =~ /\A(?:MSWin32|msys|cygwin|darwin)\z/;

my $ID = qr/[A-Za-z_\x80-\xff][A-Za-z0-9_\x80-\xff]*/;
my $QN = qr/\\?$ID(?:\\$ID)*/;

# Classes a namespaced file must import or write with a leading backslash.
my %BUILTIN = map { lc($_) => 1 } qw(
    stdClass Exception ErrorException Error TypeError ValueError ArithmeticError DivisionByZeroError
    ArgumentCountError JsonException Throwable Closure Generator Traversable Iterator IteratorAggregate
    ArrayAccess Countable JsonSerializable Stringable Serializable UnitEnum BackedEnum WeakMap WeakReference
    Fiber DateTime DateTimeImmutable DateTimeInterface DateTimeZone DateInterval DatePeriod ArrayObject
    ArrayIterator SplStack SplQueue SplObjectStorage SplFixedArray SplPriorityQueue SplHeap SplMinHeap
    SplMaxHeap SplDoublyLinkedList SplFileInfo SplFileObject SplTempFileObject DirectoryIterator
    FilesystemIterator RecursiveDirectoryIterator RecursiveIteratorIterator GlobIterator IteratorIterator
    LogicException BadFunctionCallException BadMethodCallException DomainException InvalidArgumentException
    LengthException OutOfRangeException RuntimeException OutOfBoundsException OverflowException
    RangeException UnderflowException UnexpectedValueException PDO PDOStatement PDOException
    ReflectionClass ReflectionMethod ReflectionProperty ReflectionFunction ReflectionException
    ReflectionNamedType ZipArchive SimpleXMLElement DOMDocument DOMElement DOMXPath CURLFile finfo
    IntlDateFormatter NumberFormatter Collator Normalizer Locale mysqli Imagick Redis SoapClient SoapFault
    XMLReader XMLWriter
);

# Laravel's built-in facade aliases (config/app.php lists them up to Laravel 8;
# later versions merge them in with Facade::defaultAliases()).
my %DEFAULT_ALIASES = map { $_ => "Illuminate\\Support\\Facades\\$_" } qw(
    App Artisan Auth Blade Broadcast Bus Cache Config Context Cookie Crypt Date DB Event File Gate Hash
    Http Lang Log Mail Notification Password Process Queue RateLimiter Redirect Request Response Route
    Schedule Schema Session Storage URL Validator View Vite
);
$DEFAULT_ALIASES{$_} = "Illuminate\\Support\\$_" for qw(Arr Js Number Str Uri);
$DEFAULT_ALIASES{Eloquent} = 'Illuminate\\Database\\Eloquent\\Model';

# Route names that laravel/ui's Auth::routes() registers.
my @AUTH_ROUTES = qw(login logout register password.request password.email password.reset
    password.update password.confirm verification.notice verification.verify verification.resend);

my %RESOURCE = (
    resource     => [qw(index create store show edit update destroy)],
    apiResource  => [qw(index store show update destroy)],
    singleton    => [qw(show edit update create store destroy)],
    apiSingleton => [qw(show update store destroy)],
);

# Libraries map these namespaces, but the classes come from PHP extensions.
my @EXT_NS = ('MongoDB\\BSON\\', 'MongoDB\\Driver\\');

my @JS_EXT = qw(.js .mjs .cjs .jsx .ts .tsx .mts .cts .d.ts .vue .svelte .json .css .scss .sass .less);
my @JS_INDEX = qw(index.js index.mjs index.cjs index.jsx index.ts index.tsx index.vue);
my %JS_KW = map { $_ => 1 } qw(return typeof instanceof in of new delete void throw case do else yield await);

# ---------------------------------------------------------------- diff

my %ADD;    # file => { new line number => added text }
{
    my ($state, $file, $ln, $old, $new) = ('none', undef, 0, 0, 0);
    while (my $l = <$DFH>) {
        $l =~ s/\r?\n\z//;
        if ($l =~ /\Adiff --git /) { ($state, $file) = ('header', undef); next }
        if ($l =~ /\Adiff --(?:cc|combined) /) { ($state, $file) = ('skip', undef); next }
        if ($state eq 'hunk') {
            my $c = substr($l, 0, 1);
            # Synthetic blocks for untracked files always say +1, so a '+' line
            # still counts after the hunk's own count is used up.
            if ($c eq '+') { $ADD{$file}{$ln} = substr($l, 1) if defined $file; $ln++; $new--; next }
            if ($c eq ' ') { $ln++; $old--; $new--; next }
            next if $c eq '\\';
            if ($c eq '-' && !($old <= 0 && $new <= 0 && $l =~ /\A--- /)) { $old--; next }
            $state = 'header';
        }
        next if $state eq 'skip';
        if ($l =~ /\A\+\+\+ (.*)\z/s) { $file = new_path($1); next }
        if ($l =~ /\A@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) {
            ($state, $old, $ln, $new) = ('hunk', defined $1 ? $1 : 1, $2, defined $3 ? $3 : 1);
        }
    }
    close $DFH;
}

sub unquote {
    my ($p) = @_;
    if ($p =~ /\A"((?:[^"\\]|\\.)*)"/s) {
        my $s = $1;
        my %e = (a => "\a", b => "\b", t => "\t", n => "\n", v => "\x0b", f => "\f", r => "\r");
        $s =~ s/\\([0-7]{3}|.)/length($1) == 3 ? chr(oct $1) : exists $e{$1} ? $e{$1} : $1/ges;
        return $s;
    }
    $p =~ s/\t\z//;    # git ends the name with a tab when it contains a space
    return $p;
}

sub new_path {
    my $p = unquote($_[0]);
    return undef if $p eq '/dev/null';
    return $1 if $p =~ m{\Ab/(.+)\z}s;
    # diff.mnemonicPrefix writes w/ (work tree), i/ (index), c/ (commit) or o/
    return $1 if $p =~ m{\A[ciow]/(.+)\z}s && !-e $p;
    return $p;
}

# ---------------------------------------------------------------- paths

my (%LS, %FOUND, %INROOT, %TEXT);

sub dir_of { return $_[0] =~ m{\A(.*)/[^/]*\z}s ? $1 : '' }
sub base_of { return $_[0] =~ m{([^/]*)\z}s ? $1 : $_[0] }
sub join_path { my ($x, $y) = @_; return $x eq '' ? $y : $y eq '' ? $x : "$x/$y" }

sub norm_path {
    my ($p) = @_;
    return undef if !defined $p || $p =~ m{\A/} || $p =~ /\A[A-Za-z]:/ || $p =~ /\0/;
    my @out;
    for my $c (split m{/+}, $p) {
        next if $c eq '' || $c eq '.';
        if ($c eq '..') { return undef unless @out; pop @out; next }
        push @out, $c;
    }
    return join '/', @out;
}

# Is this existing path, once symlinks are resolved, still inside the repository?
sub in_root {
    my ($p) = @_;
    return $INROOT{$p} if exists $INROOT{$p};
    my $r = realpath($p eq '' ? '.' : $p);
    my ($x, $root) = $FOLD ? (lc(defined $r ? $r : ''), lc $ROOT) : (defined $r ? $r : '', $ROOT);
    my $pre = $root eq '/' ? '/' : "$root/";
    return $INROOT{$p} = (defined $r && ($x eq $root || index($x, $pre) == 0)) ? 1 : 0;
}

# Directory listing as { lower-case name => [real names] }, or undef.
sub entries {
    my ($d) = @_;
    return $LS{$d} if exists $LS{$d};
    my $h;
    if (opendir(my $dh, $d eq '' ? '.' : $d)) {
        $h = {};
        for my $e (readdir $dh) { push @{ $h->{lc $e} }, $e unless $e eq '.' || $e eq '..' }
        closedir $dh;
    }
    return $LS{$d} = $h;
}

sub names_in { my $e = entries($_[0]); return $e ? sort map { @$_ } values %$e : () }

# Walks a repository-relative path one component at a time against the real
# directory listings, so a name that differs only in letter case is caught on
# case-insensitive file systems too. Returns (status, path): 'ok' or 'case' with
# the real path, 'missing', or 'outside' (leaves the repository or cannot be read).
sub find_path {
    my ($rel) = @_;
    my $p = norm_path($rel);
    return ('outside', $rel) unless defined $p;
    return @{ $FOUND{$p} } if $FOUND{$p};
    my ($cur, $case, @r) = ('', 0);
    for my $c (split m{/}, $p) {
        my $e = entries($cur);
        if (!$e) { @r = ('outside', $p); last }
        my $names = $e->{lc $c};
        if (!$names) { @r = (in_root($cur) ? 'missing' : 'outside', $p); last }
        my ($hit) = grep { $_ eq $c } @$names;
        if (!defined $hit) { ($hit) = sort @$names; $case = 1 }
        $cur = join_path($cur, $hit);
    }
    @r = (!in_root($cur) ? 'outside' : $case ? 'case' : 'ok', $cur) unless @r;
    $FOUND{$p} = \@r;
    return @r;
}

sub read_text {
    my $p = norm_path($_[0]);
    return undef if !defined $p || $p eq '';
    return $TEXT{$p} if exists $TEXT{$p};
    my $t;
    if (!($SELF ne '' && index($p, $SELF) == 0) && -f $p && (-s _ || 0) <= $MAX && in_root($p)
        && open(my $fh, '<:raw', $p)) {
        local $/;
        $t = <$fh>;
        close $fh;
        $t = '' unless defined $t;
        $t =~ s/\r\n/\n/g;
    }
    return $TEXT{$p} = $t;
}

sub read_json {
    my $t = read_text($_[0]);
    return undef unless defined $t;
    my $j = eval { require JSON::PP; JSON::PP->new->relaxed->decode($t) };
    return ref $j eq 'HASH' ? $j : undef;
}

# Files below a directory, skipping hidden folders, vendor/ and node_modules/.
sub files_under {
    my ($dir, $re, $cap) = @_;
    my ($st, $real) = find_path($dir);
    return () unless $st eq 'ok' && -d $real;
    my (@out, @todo) = ();
    @todo = ($real);
    my $dirs = 0;
    while (@todo && @out < $cap && $dirs++ < 5000) {
        my $d = shift @todo;
        for my $name (names_in($d)) {
            my $p = join_path($d, $name);
            if (-d $p) {
                push @todo, $p if $name !~ /\A\./ && $name ne 'node_modules' && $name ne 'vendor' && in_root($p);
            } elsif ($name =~ $re) {
                push @out, $p;
            }
        }
    }
    return @out;
}

# ---------------------------------------------------------------- output

my (@OUT, %OUTSEEN);

# Single-line, terminal-safe text: tabs become spaces; control, bidi and
# zero-width characters become '?'.
sub clean {
    my ($s, $max) = @_;
    $s = '' unless defined $s;
    $s =~ s/\t/ /g;
    my $u = $s;
    if (utf8::decode($u)) {
        $u =~ s/[\x00-\x1f\x7f-\x9f\x{200b}\x{202a}-\x{202e}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{feff}\x{e0000}-\x{e007f}]/?/g;
        $u = substr($u, 0, $max - 3) . '...' if length($u) > $max;
        utf8::encode($u);
        return $u;
    }
    $s =~ s/[\x00-\x1f\x7f-\x9f]/?/g;
    $s = substr($s, 0, $max - 3) . '...' if length($s) > $max;
    return $s;
}

sub finding {
    my ($sev, $f, $n, $msg) = @_;
    return if $OUTSEEN{"$f\0$n\0$msg"}++;
    my $snip = defined $ADD{$f}{$n} ? $ADD{$f}{$n} : '';
    $snip =~ s/\A\s+|\s+\z//g;
    push @OUT, [$sev, clean($f, 1000), $n, clean($msg, 600), clean($snip, 200)];
}

# Closest candidate by edit distance, for a "did you mean" hint.
sub suggest {
    my ($want, @cands) = @_;
    my $max = length($want) <= 4 ? 1 : length($want) <= 10 ? 2 : 3;
    my ($best, $bd);
    my %seen;
    for my $c (sort @cands) {
        next if $c eq $want || $seen{$c}++;
        my $d = lev(lc $want, lc $c, $max);
        ($best, $bd) = ($c, $d) if $d <= $max && (!defined $bd || $d < $bd);
    }
    return $best;
}

sub lev {
    my ($s, $t, $max) = @_;
    my ($n, $m) = (length $s, length $t);
    return $max + 1 if abs($n - $m) > $max;
    my @prev = (0 .. $m);
    for my $i (1 .. $n) {
        my @cur = ($i);
        my $c = substr($s, $i - 1, 1);
        my $low = $i;
        for my $j (1 .. $m) {
            my $v = $prev[$j - 1] + ($c eq substr($t, $j - 1, 1) ? 0 : 1);
            $v = $prev[$j] + 1 if $prev[$j] + 1 < $v;
            $v = $cur[$j - 1] + 1 if $cur[$j - 1] + 1 < $v;
            push @cur, $v;
            $low = $v if $v < $low;
        }
        return $max + 1 if $low > $max;
        @prev = @cur;
    }
    return $prev[$m];
}

# Sibling file with the closest name to a missing one, without the extension.
sub suggest_file {
    my ($path, $ext) = @_;
    my ($st, $dir) = find_path(dir_of($path));
    return undef unless $st eq 'ok' || $st eq 'case';
    (my $want = base_of($path)) =~ s/\Q$ext\E\z//;
    return suggest($want, map { my $x = $_; $x =~ s/\Q$ext\E\z// ? $x : () } names_in($dir));
}

# ---------------------------------------------------------------- masks
# A mask is a copy of the source in which comments and the insides of string
# literals are blanked (string delimiters and newlines kept), so patterns match
# code only while offsets still line up with the original.

sub blank { (my $t = $_[0]) =~ tr/\n/ /c; return $t }

sub mask_php {
    my ($s, $code) = @_;    # $code: start inside PHP code rather than inline HTML
    my $o = '';
    my $len = length $s;
    pos($s) = 0;
    while (pos($s) < $len) {
        if (!$code) {
            if ($s =~ /\G(.*?)(<\?(?:php(?![\w])|=|(?=\s)))/gcs) { $o .= blank($1) . $2; $code = 1 }
            else { $s =~ /\G(.*)/gcs; $o .= blank($1) }
            next;
        }
        if ($s =~ /\G\?>/gc) { $o .= '?>'; $code = 0; next }
        if ($s =~ /\G((?:\/\/|#(?!\[))(?:[^\n?]+|\?(?!>))*)/gc) { $o .= blank($1); next }
        if ($s =~ /\G(\/\*.*?(?:\*\/|\z))/gcs) { $o .= blank($1); next }
        if ($s =~ /\G'((?:[^'\\]++|\\.)*+)('?)/gcs) { $o .= "'" . blank($1) . $2; next }
        if ($s =~ /\G"((?:[^"\\]++|\\.)*+)("?)/gcs) { $o .= '"' . blank($1) . $2; next }
        if ($s =~ /\G`((?:[^`\\]++|\\.)*+)(`?)/gcs) { $o .= '`' . blank($1) . $2; next }
        if ($s =~ /\G(<<<[ \t]*(["']?)($ID)\2[ \t]*\n)/gc) {
            my ($head, $label) = ($1, $3);
            $o .= $head;
            if ($s =~ /\G(.*?)(?=^[ \t]*\Q$label\E(?![A-Za-z0-9_\x80-\xff]))/gcms) { $o .= blank($1) }
            else { $s =~ /\G(.*)/gcs; $o .= blank($1) }
            next;
        }
        if ($s =~ /\G([^'"`\/#<?]+)/gc) { $o .= $1; next }
        $s =~ /\G(.)/gcs;
        $o .= $1;
    }
    return $o;
}

sub php_part { return substr(mask_php("<?php\n" . $_[0], 0), 6) }

# Blade gives two masks: 'html' (Blade comments and @verbatim blanked) for
# component tags, and 'code' (only what Blade compiles to PHP: {{ }}, {!! !!},
# directive arguments, @php blocks, <?php ?> and :attribute="" values on
# components) so that inline JavaScript and page text are not read as PHP.
sub mask_blade {
    my ($s) = @_;
    my $h = $s;
    $h =~ s/(\{\{--.*?--\}\}|\@verbatim\b.*?\@endverbatim\b|\@\{\{.*?\}\})/blank($1)/gse;
    my $c = blank($h);
    my @spans;
    while ($h =~ /\{\{.*?\}\}|\{!!.*?!!\}|(?<![\w@])\@php\b(?!\s*\().*?\@endphp\b|<\?(?:php\b|=).*?(?:\?>|\z)/gs) {
        push @spans, [$-[0], $+[0]];
    }
    while ($h =~ /(?<![\w@])\@[A-Za-z_]\w*[ \t]*(?=\()/g) {
        push @spans, [$-[0], close_paren($h, $+[0])];
    }
    while ($h =~ /<x-[\w\-.:]+((?:[^>"']++|"[^"]*"|'[^']*')*)>/gs) {
        my ($at, $attrs) = ($-[1], $1);
        while ($attrs =~ /(?<=\s):[\w\-.]+\s*=\s*"([^"]*)"/g) { push @spans, [$at + $-[1], $at + $+[1]] }
    }
    for my $sp (sort { $a->[0] <=> $b->[0] } @spans) {
        my ($st, $en) = @$sp;
        substr($c, $st, $en - $st) = php_part(substr($h, $st, $en - $st));
    }
    return ($h, $c);
}

# Offset just after the parenthesis that closes the one at $_[1] (string-aware).
sub close_paren {
    my $i = $_[1];
    my $lim = $i + 5000;
    my $depth = 0;
    pos($_[0]) = $i;
    while (pos($_[0]) < $lim && $_[0] =~ /\G(?:(\()|(\))|'(?:[^'\\\n]++|\\.)*'|"(?:[^"\\\n]++|\\.)*"|[^()'"\n]++|(\n)|.)/gcs) {
        if (defined $1) { $depth++ }
        elsif (defined $2) { return pos($_[0]) if --$depth <= 0 }
        elsif (defined $3 && $depth > 3) { last }
    }
    my $nl = index($_[0], "\n", $i);
    return $nl < 0 ? length($_[0]) : $nl;
}

sub mask_js {
    my ($s) = @_;
    my ($o, $prev) = ('', '');
    my @st = (0);    # top: open braces in this code level, or 'T' inside template text
    my $len = length $s;
    pos($s) = 0;
    while (pos($s) < $len) {
        if ($st[-1] eq 'T') {
            if ($s =~ /\G((?:[^`\\\$]++|\\.|\$(?!\{))+)/gcs) { $o .= blank($1); next }
            if ($s =~ /\G`/gc) { $o .= '`'; pop @st; $prev = 'v'; next }
            if ($s =~ /\G\$\{/gc) { $o .= '${'; push @st, 0; $prev = '('; next }
            $s =~ /\G(.)/gcs;
            $o .= blank($1);
            next;
        }
        if ($s =~ /\G(\/\/[^\n]*)/gc) { $o .= blank($1); next }
        if ($s =~ /\G(\/\*.*?(?:\*\/|\z))/gcs) { $o .= blank($1); next }
        if ($s =~ /\G'((?:[^'\\\n]++|\\.)*+)('?)/gcs) { $o .= "'" . blank($1) . $2; $prev = 'v'; next }
        if ($s =~ /\G"((?:[^"\\\n]++|\\.)*+)("?)/gcs) { $o .= '"' . blank($1) . $2; $prev = 'v'; next }
        if ($s =~ /\G`/gc) { $o .= '`'; push @st, 'T'; next }
        if ($s =~ /\G\{/gc) { $o .= '{'; $st[-1]++; $prev = '{'; next }
        if ($s =~ /\G\}/gc) {
            if ($st[-1] == 0 && @st > 1) { pop @st; $o .= '}'; $prev = 'v'; next }
            $st[-1]-- if $st[-1] > 0;
            $o .= '}';
            $prev = '}';
            next;
        }
        if ($s =~ /\G\//gc) {
            # a slash after an operator, keyword or line start begins a regex literal
            if (($prev eq '' || $prev =~ /\A[(,=:\[!&|?{};+\-*%<>~^}]\z/ || $prev eq 'k')
                && $s =~ /\G((?:[^\\\/\[\n]++|\\.|\[(?:[^\]\\\n]++|\\.)*\])*)\//gc) {
                $o .= '/' . blank($1) . '/';
                $prev = 'v';
                next;
            }
            $o .= '/';
            $prev = '/';
            next;
        }
        if ($s =~ /\G([A-Za-z_\$\x80-\xff][\w\$\x80-\xff]*)/gc) { $o .= $1; $prev = $JS_KW{$1} ? 'k' : 'v'; next }
        if ($s =~ /\G(\s+)/gc) { $o .= $1; next }
        if ($s =~ /\G([0-9][\w.]*)/gc) { $o .= $1; $prev = 'v'; next }
        $s =~ /\G(.)/gcs;
        $o .= $1;
        $prev = $1 =~ /[)\]]/ ? 'v' : $1;
    }
    return $o;
}

# .vue and .svelte: only the <script> blocks are code.
sub mask_sfc {
    my ($s) = @_;
    my $o = blank($s);
    while ($s =~ /<script\b[^>]*>(.*?)<\/script\s*>/gis) {
        my ($st, $len) = ($-[1], $+[1] - $-[1]);
        substr($o, $st, $len) = mask_js(substr($s, $st, $len));
    }
    return $o;
}

sub mask_py {
    my ($s) = @_;
    my $o = '';
    my $len = length $s;
    pos($s) = 0;
    while (pos($s) < $len) {
        if ($s =~ /\G(#[^\n]*)/gc) { $o .= blank($1); next }
        if ($s =~ /\G((?<![\w])[rRbBuUfF]{0,2})('''|""")(.*?)(\2|\z)/gcs) { $o .= $1 . $2 . blank($3) . $4; next }
        if ($s =~ /\G((?<![\w])[rRbBuUfF]{0,2})(['"])((?:(?!\2)[^\\\n]|\\.)*)(\2?)/gcs) { $o .= $1 . $2 . blank($3) . $4; next }
        $s =~ /\G([A-Za-z_]\w*|\s+|[^\sA-Za-z_#'"]+|.)/gcs;
        $o .= $1;
    }
    return $o;
}

# ---------------------------------------------------------------- lines

sub line_starts {
    my @s = (0);
    while ($_[0] =~ /\n/g) { push @s, pos($_[0]) }
    return \@s;
}

sub line_of {
    my ($s, $off) = @_;
    my ($lo, $hi) = (0, $#$s);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi + 1) / 2);
        if ($s->[$mid] <= $off) { $lo = $mid } else { $hi = $mid - 1 }
    }
    return $lo + 1;
}

# Calls $cb->(line number, original line, mask line, offset) for each added line.
sub each_added {
    my ($F, $mask, $cb) = @_;
    my ($t, $s) = ($F->{text}, $F->{starts});
    for my $n (sort { $a <=> $b } keys %{ $F->{add} }) {
        next if $n < 1 || $n > @$s;
        my $st = $s->[$n - 1];
        my $en = $n < @$s ? $s->[$n] - 1 : length $t;
        my $ml = substr($mask, $st, $en - $st);
        next unless $ml =~ /\S/;
        $cb->($n, substr($t, $st, $en - $st), $ml, $st);
    }
}

# The string literal that starts at offset $_[2] of the original ($_[0]) and its
# mask ($_[1]). Returns (value, offset after it), or nothing when the value is
# built at run time (interpolated, concatenated or escaped).
sub lit {
    my $p = $_[2];
    my $q = substr($_[0], $p, 1);
    return unless $q eq "'" || $q eq '"';
    my $e = index($_[1], $q, $p + 1);
    return if $e < 0;
    my $v = substr($_[0], $p + 1, $e - $p - 1);
    return if $v =~ /\\/ || ($q eq '"' && $v =~ /[\$\{]/);
    return if substr($_[1], $e + 1, 200) =~ /\A\s*[.+]/;
    return ($v, $e + 1);
}

# ---------------------------------------------------------------- per file

sub kind {
    my ($f) = @_;
    return 'blade' if $f =~ /\.blade\.php\z/i;
    return 'php'   if $f =~ /\.(?:php|phtml)\z/i;
    return 'sfc'   if $f =~ /\.(?:vue|svelte)\z/i;
    return 'js'    if $f =~ /\.(?:[cm]?js|jsx|[cm]?ts|tsx)\z/i;
    return 'py'    if $f =~ /\.pyi?\z/i;
    return undef;
}

# The working-tree file with the diff's added lines laid over it, so the added
# text is what gets checked even if the file changed after the diff was made.
sub source_of {
    my ($f) = @_;
    my $add = $ADD{$f};
    my $t = read_text($f);
    if (!defined $t) {
        return undef if -e $f;    # too big, unreadable or outside the repository
        $t = '';
    }
    my @l = split /\n/, $t, -1;
    my $changed = 0;
    for my $n (sort { $a <=> $b } keys %$add) {
        next if $n < 1 || ($n <= @l && $l[$n - 1] eq $add->{$n});
        $l[$n - 1] = $add->{$n};
        $changed = 1;
    }
    return $changed ? join("\n", map { defined $_ ? $_ : '' } @l) : $t;
}

sub check_file {
    my ($f, $k) = @_;
    my $text = source_of($f);
    return unless defined $text;
    my $F = { file => $f, kind => $k, text => $text, starts => line_starts($text), add => $ADD{$f}, seen => {} };
    if ($k eq 'blade') { @$F{qw(html mask)} = mask_blade($text) }
    else { $F->{mask} = $k eq 'php' ? mask_php($text, 0) : $k eq 'py' ? mask_py($text) : $k eq 'sfc' ? mask_sfc($text) : mask_js($text) }
    die "internal error: mask length differs\n" if length($F->{mask}) != length $text;
    if ($k eq 'php' || $k eq 'blade') { check_php($F) }
    elsif ($k eq 'py') { check_py($F) }
    else { check_js($F) }
}

# ---------------------------------------------------------------- PHP

my (%UP, %PROJ, %CI, %AL, %VR, %VN, %RN, %VC, %REG);

# Nearest folder, from the file's own up to the repository root, that holds
# the marker: returns it as a path prefix ('' or 'dir/'), or undef.
sub find_up {
    my ($f, $what) = @_;
    my $d = dir_of($f);
    while (1) {
        my $key = "$what\0$d";
        if (!exists $UP{$key}) {
            my $pre = $d eq '' ? '' : "$d/";
            $UP{$key} = $what eq 'artisan' ? -f "${pre}artisan"
                      : (-f "${pre}composer.json" || -f "${pre}vendor/composer/autoload_psr4.php");
        }
        return $d eq '' ? '' : "$d/" if $UP{$key};
        return undef if $d eq '';
        $d = dir_of($d);
    }
}

sub php_sq { (my $s = $_[0]) =~ s/\\([\\'])/$1/g; return $s }

sub php_project {
    my $root = find_up($_[0], 'composer');
    return undef unless defined $root;
    return $PROJ{$root} ||= load_project($root);
}

# PSR-4 map from vendor/composer/autoload_psr4.php (all installed packages)
# plus composer.json (project namespaces, also before "composer dump-autoload").
sub load_project {
    my ($root) = @_;
    (my $base = $root) =~ s{/\z}{};
    my $cj = read_json("${root}composer.json");
    my $vendor = "${root}vendor";
    if ($cj && ref $cj->{config} eq 'HASH' && defined $cj->{config}{'vendor-dir'} && !ref $cj->{config}{'vendor-dir'}) {
        my $v = norm_path($root . $cj->{config}{'vendor-dir'});
        $vendor = $v if defined $v && $v ne '';
    }
    my (%map, %outside);
    my $add = sub {
        my ($pfx, $dir) = @_;
        my $d = norm_path($dir);
        if (!defined $d) { $outside{$pfx} = 1; return }
        push @{ $map{$pfx} }, $d unless grep { $_ eq $d } @{ $map{$pfx} || [] };
    };
    my $t = read_text("$vendor/composer/autoload_psr4.php");
    if (defined $t) {
        while ($t =~ /^\s*'((?:[^'\\]|\\.)*)'\s*=>\s*array\s*\((.*)\)\s*,?\s*$/mg) {
            my ($p1, $list) = ($1, $2);
            my $pfx = php_sq($p1);
            while ($list =~ /(\$vendorDir|\$baseDir)\s*\.\s*'((?:[^'\\]|\\.)*)'|'((?:[^'\\]|\\.)*)'/g) {
                my ($var, $rel, $abs) = ($1, $2, $3);
                if (defined $var) {
                    (my $r = php_sq($rel)) =~ s{\A/}{};
                    $add->($pfx, join_path($var eq '$vendorDir' ? $vendor : $base, $r));
                } else {
                    my $a = php_sq($abs);
                    my ($fa, $fr) = $FOLD ? (lc $a, lc $ROOT) : ($a, $ROOT);
                    if (index($fa, "$fr/") == 0) { $add->($pfx, substr($a, length($ROOT) + 1)) }
                    else { $outside{$pfx} = 1 }
                }
            }
        }
    }
    for my $sect (qw(autoload autoload-dev)) {
        my $ps = $cj && ref $cj->{$sect} eq 'HASH' ? $cj->{$sect}{'psr-4'} : undef;
        next unless ref $ps eq 'HASH';
        for my $pfx (sort keys %$ps) {
            my $v = $ps->{$pfx};
            for my $d (ref $v eq 'ARRAY' ? @$v : ($v)) { $add->($pfx, $root . $d) if defined $d && !ref $d }
        }
    }
    my @psr4 = map { [$_, $map{$_}] } sort { length($b) <=> length($a) || $a cmp $b } grep { /\\\z/ } keys %map;
    return { root => $root, base => $base, vendor => $vendor, psr4 => \@psr4,
             fallback => $map{''} || [], outside => \%outside, status => {} };
}

sub classmap {
    my ($P) = @_;
    return $P->{cm} if $P->{cm};
    my %cm;
    my $t = read_text("$P->{vendor}/composer/autoload_classmap.php");
    if (defined $t) {
        while ($t =~ /^\s*'((?:[^'\\]|\\.)*)'\s*=>\s*(\$vendorDir|\$baseDir)\s*\.\s*'((?:[^'\\]|\\.)*)'/mg) {
            my ($c, $var, $p) = ($1, $2, $3);
            ($p = php_sq($p)) =~ s{\A/}{};
            $cm{ php_sq($c) } = join_path($var eq '$vendorDir' ? $P->{vendor} : $P->{base}, $p);
        }
    }
    return $P->{cm} = \%cm;
}

sub class_status {
    my ($P, $fq) = @_;
    $P->{status}{$fq} ||= [class_lookup($P, $fq)];
    return @{ $P->{status}{$fq} };
}

# ('ok', file) | ('case', real file) | ('missing', expected file) | ('unknown')
sub class_lookup {
    my ($P, $fq) = @_;
    for my $x (@EXT_NS) { return ('unknown') if index($fq, $x) == 0 }
    my $cm = classmap($P);
    return ('ok', $cm->{$fq}) if exists $cm->{$fq};
    my ($mapped, $outside, $case, $expect, $expect_dir);
    # like Composer: every matching prefix, longest first, compared case-sensitively
    for my $e (@{ $P->{psr4} }) {
        my ($pfx, $dirs) = @$e;
        next unless index($fq, $pfx) == 0;
        $outside = 1 if $P->{outside}{$pfx};
        (my $rest = substr($fq, length $pfx)) =~ s{\\}{/}g;
        for my $d (@$dirs) {
            my $p = join_path($d, "$rest.php");
            my ($st, $real) = find_path($p);
            if ($st eq 'outside') { $outside = 1; next }
            $mapped = 1;
            return ('ok', $real) if $st eq 'ok' && -f $real;
            $case = $real if $st eq 'case' && -f $real && !defined $case;
            $expect = $p unless defined $expect;
            if (!defined $expect_dir) { my ($ds) = find_path(dir_of($p)); $expect_dir = $p if $ds eq 'ok' }
        }
    }
    for my $d (@{ $P->{fallback} }) {
        (my $rest = $fq) =~ s{\\}{/}g;
        my ($st, $real) = find_path(join_path($d, "$rest.php"));
        return ('ok', $real) if $st eq 'ok' && -f $real;
    }
    return ('case', $case) if defined $case;
    return ('unknown') if $outside || !$mapped;
    return ('missing', defined $expect_dir ? $expect_dir : $expect);
}

# 'use App\Models;' imports a namespace, which is a folder, not a class file.
sub ns_exists {
    my ($P, $fq) = @_;
    for my $e (@{ $P->{psr4} }) {
        my ($pfx, $dirs) = @$e;
        next unless index("$fq\\", $pfx) == 0;
        (my $rest = substr("$fq\\", length $pfx)) =~ s{\\}{/}g;
        for my $d (@$dirs) {
            my ($st, $real) = find_path(join_path($d, $rest));
            return 1 if $st eq 'ok' && -d $real;
        }
    }
    return 0;
}

# Namespaces, imports, trait uses and class declarations of one PHP file.
sub php_context {
    my ($F) = @_;
    my ($m, $s) = ($F->{mask}, $F->{starts});
    my (@ev, %decl);
    my $B = qr/(?:\A|[;{}]|<\?php|<\?=|\@php)\s*/;
    while ($m =~ /$B(namespace)\b(?!\s*\\)\s*($QN)?\s*[;{]/g) { push @ev, [$-[1], 'ns', defined $2 ? $2 : ''] }
    while ($m =~ /$B(use)(?>\s+)(?!\()/g) { push @ev, [$-[1], 'use', $+[1]] }
    while ($m =~ /(?:\A|[;{}\]]|<\?php)\s*(?:(?:abstract|final|readonly)\s+)*(class|interface|trait|enum)\s+($ID)/g) {
        push @ev, [$-[1], 'class'];
        $decl{ lc $2 } = 1;
    }
    while ($m =~ /\bnew\s+class\b/g) { push @ev, [$-[0], 'class'] }
    my @sec = ({ start => -1, ns => '', alias => {} });
    my ($inclass, @uses) = (0);
    for my $e (sort { $a->[0] <=> $b->[0] } @ev) {
        my ($off, $type, $data) = @$e;
        if ($type eq 'ns') { push @sec, { start => $off, ns => $data, alias => {} }; $inclass = 0; next }
        if ($type eq 'class') { $inclass = 1; next }
        # 'use' inside a class body pulls in a trait; before it, it imports a name
        my $kind = $inclass ? 'trait' : 'import';
        for my $u (parse_use($m, $data, $kind)) {
            my ($name, $alias, $at, $mod) = @$u;
            push @uses, { name => $name, line => line_of($s, $at), kind => $kind, mod => $mod, sec => $#sec };
            next if $kind ne 'import' || $mod ne '';
            (my $fq = $name) =~ s/\A\\//;
            $sec[-1]{alias}{ lc(defined $alias ? $alias : ($fq =~ /([^\\]+)\z/)[0]) } = $fq;
        }
    }
    return { sec => \@sec, uses => \@uses, decl => \%decl };
}

# The names one 'use' statement lists: [name, alias, offset, 'function'|'const'|''].
sub parse_use {
    my (undef, $pos, $kind) = @_;
    pos($_[0]) = $pos;
    my ($mod, @out) = ('');
    $mod = $1 if $kind eq 'import' && $_[0] =~ /\G\s*(function|const)(?>\s+)/gc;
    while (1) {
        $_[0] =~ /\G\s*/gc;
        my $at = pos($_[0]);
        last unless $_[0] =~ /\G($QN)/gc;
        my $name = $1;
        if ($kind eq 'import' && $_[0] =~ /\G\\\s*\{/gc) {
            while (1) {
                my $imod = $_[0] =~ /\G\s*(function|const)(?>\s+)/gc ? $1 : $mod;
                $_[0] =~ /\G\s*/gc;
                my $iat = pos($_[0]);
                last unless $_[0] =~ /\G($ID(?:\\$ID)*)/gc;
                my $inner = $1;
                my $alias = $_[0] =~ /\G\s+as\s+($ID)/gc ? $1 : undef;
                push @out, ["$name\\$inner", $alias, $iat, $imod];
                last unless $_[0] =~ /\G\s*,/gc;
            }
        } else {
            my $alias = $_[0] =~ /\G\s+as\s+($ID)/gc ? $1 : undef;
            push @out, [$name, $alias, $at, $mod];
        }
        last unless $_[0] =~ /\G\s*,/gc;
    }
    pos($_[0]) = undef;
    return @out;
}

sub section_at {
    my ($ctx, $off) = @_;
    for my $sec (reverse @{ $ctx->{sec} }) { return $sec if $sec->{start} <= $off }
    return $ctx->{sec}[0];
}

# PHP name resolution: (fully qualified name, how it was resolved).
sub resolve_name {
    my ($name, $sec) = @_;
    return (substr($name, 1), 'fq') if substr($name, 0, 1) eq '\\';
    my ($first, $rest) = split /\\/, $name, 2;
    my $imp = $sec->{alias}{ lc $first };
    if (defined $rest) {
        return ("$imp\\$rest", 'import') if defined $imp;
        return ($sec->{ns} ne '' ? "$sec->{ns}\\$name" : $name, 'qualified');
    }
    return ($imp, 'import') if defined $imp;
    return ("$sec->{ns}\\$name", 'ns') if $sec->{ns} ne '';
    return ($name, 'global');
}

# Reports, once per file, a class that does not exist. Returns (file, class)
# when it was found, so that its methods can be checked.
sub class_ref {
    my ($F, $n, $name, $sec, $what, $import) = @_;
    my ($fq, $how) = resolve_name($name, $sec);
    return ($F->{file}, $fq) if $how eq 'ns' && $F->{decl}{ lc $name };
    if ($fq !~ /\\/) {
        # global name: a Laravel alias, a built-in class or an unknown global class
        my $al = $F->{aliases}{ lc $fq };
        return unless defined $al;
        ($fq, $how) = ($al, 'alias');
    }
    my $P = $F->{proj} or return;
    my ($st, $path) = class_status($P, $fq);
    return ($path, $fq) if $st eq 'ok';
    return if $st eq 'unknown' || ($import && ns_exists($P, $fq)) || $F->{seen}{ lc $fq }++;
    if ($st eq 'case') {
        finding('WARN', $F->{file}, $n, "$what $fq: the file is $path (letter case differs), so autoloading fails on case-sensitive file systems such as Linux");
        return;
    }
    my $msg = "$what $fq not found (expected $path)";
    if ($how eq 'ns') {
        my $al = $F->{aliases}{ lc $name };
        $msg .= defined $al ? ": missing import; '$name' is a global alias, so add 'use $name;' or 'use $al;'"
              : $BUILTIN{ lc $name } ? ": missing import; '$name' is a built-in PHP class, so write \\$name or add 'use $name;'"
              : ": missing 'use' import, misspelled or hallucinated";
    } else {
        $msg .= ': hallucinated, misspelled or not created yet';
    }
    my $s = suggest_file($path, '.php');
    if (defined $s) { (my $ns = $fq) =~ s/[^\\]+\z//; $msg .= "; did you mean $ns$s?" }
    finding('WARN', $F->{file}, $n, $msg);
    return;
}

sub class_info {
    my ($file, $fq) = @_;
    my $short = ($fq =~ /([^\\]+)\z/)[0];
    my $key = "$file\0" . lc $short;
    return $CI{$key} if exists $CI{$key};
    my $t = read_text($file);
    return $CI{$key} = undef unless defined $t;
    my $m = mask_php($t, 0);
    return $CI{$key} = undef
        unless $m =~ /(?:\A|[;{}\]]|<\?php)\s*(?:(?:abstract|final|readonly)\s+)*(class|interface|trait|enum)\s+\Q$short\E(?![A-Za-z0-9_\x80-\xff])([^{;]*)\{/gi;
    my ($kind, $head, $body) = (lc $1, $2, pos($m) - 1);
    # Methods can also come from a parent class, a trait or __callStatic.
    my $open = $kind eq 'interface' || $head =~ /\bextends\b/i || $m =~ /\bfunction\s+&?\s*__callStatic\b/i;
    pos($m) = $body;
    $open = 1 if !$open && $m =~ /\G.*?[{;}]\s*use\s+[\\A-Za-z_\x80-\xff]/gs;
    pos($m) = 0;
    my %meth;
    while ($m =~ /\bfunction\s+&?\s*($ID)\s*\(/g) { $meth{ lc $1 } = $1 }
    return $CI{$key} = { kind => $kind, open => $open ? 1 : 0, methods => \%meth };
}

sub method_ref {
    my ($F, $n, $name, $member, $file, $fq) = @_;
    my $ci = class_info($file, $fq) or return;
    return if $ci->{open} || $ci->{methods}{ lc $member };
    return if $ci->{kind} eq 'enum' && $member =~ /\A(?:cases|from|tryFrom)\z/i;
    my $msg = "${name}::${member}() not found in $file: hallucinated or misspelled method";
    my $s = suggest($member, values %{ $ci->{methods} });
    $msg .= "; did you mean $s()?" if defined $s;
    finding('WARN', $F->{file}, $n, $msg);
}

sub check_php {
    my ($F) = @_;
    $F->{proj} = php_project($F->{file});
    $F->{lara} = find_up($F->{file}, 'artisan');
    $F->{aliases} = defined $F->{lara} ? laravel_aliases($F->{lara}) : {};
    my $ctx = php_context($F);
    blade_uses($F, $ctx) if $F->{kind} eq 'blade';
    $F->{decl} = $ctx->{decl};
    for my $u (@{ $ctx->{uses} }) {
        next if $u->{mod} ne '' || !exists $F->{add}{ $u->{line} };
        my $sec = $ctx->{sec}[ $u->{sec} ];
        if ($u->{kind} eq 'trait') { class_ref($F, $u->{line}, $u->{name}, $sec, 'trait'); next }
        (my $fq = $u->{name}) =~ s/\A\\//;
        class_ref($F, $u->{line}, "\\$fq", $sec, 'class', 1) if $fq =~ /\\/;
    }
    each_added($F, $F->{mask}, sub {
        my ($n, $o, $m, $off) = @_;
        my $sec = section_at($ctx, $off);
        php_line($F, $n, $m, $sec);
        laravel_line($F, $n, $o, $m, $off, $sec) if defined $F->{lara};
    });
    if ($F->{kind} eq 'blade' && defined $F->{lara}) {
        each_added($F, $F->{html}, sub {
            my ($n, $o, $m) = @_;
            while ($m =~ /<x-([A-Za-z0-9][\w\-.:]*)/g) { component_ref($F, $n, $1) }
        });
    }
}

# Blade's @use('App\Models\User') and @use('App\Models\User', 'Alias').
sub blade_uses {
    my ($F, $ctx) = @_;
    my ($t, $m) = ($F->{text}, $F->{mask});
    while ($t =~ /\@use\s*\(\s*(['"])\\?($QN)\1(?:\s*,\s*(['"])($ID)\3)?\s*\)/g) {
        my ($at, $name, $alias) = ($-[0], $2, $4);
        next unless substr($m, $at, 1) eq '@';
        $ctx->{sec}[0]{alias}{ lc(defined $alias ? $alias : ($name =~ /([^\\]+)\z/)[0]) } = $name;
        push @{ $ctx->{uses} }, { name => $name, line => line_of($F->{starts}, $at), kind => 'import', mod => '', sec => 0 };
    }
}

sub php_line {
    my ($F, $n, $m, $sec) = @_;
    # Foo::bar(), Foo::CONST, Foo::$prop and Foo::class
    while ($m =~ /(?<![\w\$\\>:\x80-\xff])($QN)\s*::\s*(\$?)($ID)(\s*\()?/g) {
        my ($name, $var, $member, $call) = ($1, $2, $3, $4);
        next if $name =~ /\A(?:self|static|parent)\z/i || $name =~ /\Anamespace\\/i;
        my ($file, $fq) = class_ref($F, $n, $name, $sec, 'class');
        next if !defined $file || $var ne '' || !defined $call || lc $member eq 'class';
        method_ref($F, $n, $name, $member, $file, $fq);
    }
    while ($m =~ /\b(?:new|instanceof)\s+($QN)/g) {
        my $c = $1;
        class_ref($F, $n, $c, $sec, 'class') unless $c =~ /\A(?:class|static|self|parent)\z/i;
    }
    while ($m =~ /\bcatch\s*\(\s*([^)\$]+)/g) {
        for my $c (split /\s*\|\s*/, $1) {
            $c =~ s/\s+\z//;
            class_ref($F, $n, $c, $sec, 'class') if $c =~ /\A$QN\z/;
        }
    }
    while ($m =~ /\b(?:extends|implements)\s+($QN(?:\s*,\s*$QN)*)/g) {
        class_ref($F, $n, $_, $sec, 'class') for split /\s*,\s*/, $1;
    }
}

# ---------------------------------------------------------------- Laravel

sub laravel_aliases {
    my ($L) = @_;
    return $AL{$L} if $AL{$L};
    my (%al, $defaults);
    $defaults = 1;
    my $t = read_text("${L}config/app.php");
    if (defined $t) {
        my $m = mask_php($t, 0);
        my $at;
        while ($t =~ /(['"])aliases\1\s*=>/g) {
            my $p = $-[0];
            if (substr($m, $p, 1) eq substr($t, $p, 1)) { $at = $+[0]; last }
        }
        pos($t) = undef;
        if (defined $at) {
            if (substr($m, $at, 300) =~ /\A\s*(?:\\?Illuminate\\Support\\Facades\\)?Facade\s*::\s*defaultAliases\b/) {
                my $mg = index($m, 'merge', $at);
                $at = $mg if $mg >= 0 && $mg - $at < 300;
            } else {
                $defaults = 0;
            }
            my $end = close_bracket($m, $at);
            my $seg_t = substr($t, $at, $end - $at);
            my $seg_m = substr($m, $at, $end - $at);
            while ($seg_t =~ /(['"])($ID)\1\s*=>\s*(?:(\\?$QN)\s*::\s*class|(['"])\\?($QN)\4)/g) {
                my ($p, $k, $c1, $c2) = ($-[0], $2, $3, $5);
                next unless substr($seg_m, $p, 1) eq substr($seg_t, $p, 1);
                (my $c = defined $c1 ? $c1 : $c2) =~ s/\A\\//;
                $al{ lc $k } = $c;
            }
        }
    }
    if ($defaults) {
        for my $k (sort keys %DEFAULT_ALIASES) { $al{ lc $k } = $DEFAULT_ALIASES{$k} unless exists $al{ lc $k } }
    }
    return $AL{$L} = \%al;
}

# Offset after the bracket that closes the first [ or ( at or after $from in a mask.
sub close_bracket {
    my ($m, $from) = @_;
    my $len = length $m;
    my $i = $from;
    $i++ while $i < $len && substr($m, $i, 1) ne '[' && substr($m, $i, 1) ne '(';
    my $depth = 0;
    for (; $i < $len; $i++) {
        my $c = substr($m, $i, 1);
        if ($c eq '[' || $c eq '(') { $depth++ }
        elsif ($c eq ']' || $c eq ')') { return $i + 1 if --$depth == 0 }
    }
    return $len;
}

sub laravel_line {
    my ($F, $n, $o, $m, $off, $sec) = @_;
    my (@views, @routes, @configs);
    while ($m =~ /(?<![\w\$>:\\])\\?view\s*\(\s*(?=['"])|\bView\s*::\s*make\s*\(\s*(?=['"])|->\s*(?:view|markdown|loadView)\s*\(\s*(?=['"])|::\s*loadView\s*\(\s*(?=['"])/g) {
        push @views, pos($m);
    }
    while ($m =~ /\bRoute\s*::\s*view\s*\(\s*(?=['"])/g) {
        my (undef, $after) = lit($o, $m, pos($m));
        push @views, $after + $+[0] if defined $after && substr($m, $after) =~ /\A\s*,\s*(?=['"])/;
    }
    if ($F->{kind} eq 'blade') {
        # @includeIf, @includeWhen, @includeUnless and @includeFirst may name optional views
        while ($m =~ /\@(?:include|extends|component|each)(?![\w])\s*\(\s*(?=['"])/g) { push @views, pos($m) }
        while ($m =~ /\@inject\s*\(\s*(['"])[^'"\n]*\1\s*,\s*(?=['"])/g) {
            my ($v) = lit($o, $m, pos($m)) or next;
            $v =~ s/\A\\//;
            class_ref($F, $n, "\\$v", $sec, 'class') if $v =~ /\A$QN\z/ && $v =~ /\\/;
        }
    }
    while ($m =~ /(?<![\w\$>:\\])\\?(?:route|to_route)\s*\(\s*(?=['"])|\b(?:URL|Redirect)\s*::\s*(?:route|signedRoute|temporarySignedRoute)\s*\(\s*(?=['"])|->\s*(?:redirectToRoute|signedRoute|temporarySignedRoute)\s*\(\s*(?=['"])/g) {
        push @routes, pos($m);
    }
    while ($m =~ /->\s*route\s*\(\s*(?=['"])/g) {
        my $at = $off + $-[0];
        my $from = $at > 120 ? $at - 120 : 0;
        # ->route('x') also reads a route parameter from a request; only
        # redirect()->route() and url()->route() take a route name
        push @routes, pos($m) if substr($F->{mask}, $from, $at - $from) =~ /(?:\b(?:redirect|url)\s*\(\s*\)|\b[Rr]edirector)\s*\z/;
    }
    while ($m =~ /(?<![\w\$>:\\])\\?config\s*\(\s*(?=['"])|\bConfig\s*::\s*get\s*\(\s*(?=['"])|\bconfig\s*\(\s*\)\s*->\s*get\s*\(\s*(?=['"])/g) {
        push @configs, pos($m);
    }
    view_ref($F, $n, $o, $m, $_) for @views;
    route_ref($F, $n, $o, $m, $_) for @routes;
    config_ref($F, $n, $o, $m, $_) for @configs;
}

sub view_roots {
    my ($L) = @_;
    return $VR{$L} if $VR{$L};
    my @r = ("${L}resources/views");
    my $t = read_text("${L}config/view.php");
    if (defined $t) {
        my $m = mask_php($t, 0);
        while ($m =~ /\b(resource_path|base_path)\s*\(\s*(?=['"])/g) {
            my $fn = $1;
            my ($v) = lit($t, $m, pos($m)) or next;
            push @r, ($fn eq 'resource_path' ? "${L}resources/" : $L) . $v;
        }
    }
    my %seen;
    return $VR{$L} = [grep { defined $_ && $_ ne '' && !$seen{$_}++ } map { norm_path($_) } @r];
}

# ('ok') | ('case', real file) | ('missing', expected file) | ('unknown')
sub view_status {
    my ($L, $v) = @_;
    (my $p = $v) =~ s{\.}{/}g;
    my ($case, $out, $exp);
    for my $r (@{ view_roots($L) }) {
        $exp = "$r/$p.blade.php" unless defined $exp;
        for my $x ('.blade.php', '.php', '.css', '.html') {
            my ($st, $real) = find_path("$r/$p$x");
            return ('ok') if $st eq 'ok' && -f $real;
            $case = $real if $st eq 'case' && -f $real && !defined $case;
            $out = 1 if $st eq 'outside';
        }
    }
    return ('case', $case) if defined $case;
    return ('unknown') if $out || !defined $exp;
    return ('missing', $exp);
}

sub view_names {
    my ($L) = @_;
    if (!$VN{$L}) {
        my @names;
        for my $root (@{ view_roots($L) }) {
            for my $f (files_under($root, qr/\.(?:blade\.php|php|html|css)\z/, 20000)) {
                (my $r = substr($f, length($root) + 1)) =~ s/\.(?:blade\.php|php|html|css)\z//;
                $r =~ s{/}{.}g;
                push @names, $r;
            }
        }
        $VN{$L} = \@names;
    }
    return @{ $VN{$L} };
}

sub view_ref {
    my ($F, $n, $o, $m, $p) = @_;
    my ($v) = lit($o, $m, $p) or return;
    return if $v !~ m{\A[\w\-][\w\-./]*\z} || $v =~ m{\.\.|//|[/.]\z};
    my ($st, $path) = view_status($F->{lara}, $v);
    if ($st eq 'case') {
        finding('WARN', $F->{file}, $n, "view '$v': the file is $path (letter case differs), so it fails on case-sensitive file systems such as Linux");
    } elsif ($st eq 'missing') {
        my $msg = "view '$v' not found (expected $path)";
        my $s = suggest($v, view_names($F->{lara}));
        $msg .= "; did you mean '$s'?" if defined $s;
        finding('WARN', $F->{file}, $n, $msg);
    }
}

# Literal start of a name built at run time ("admin.$x" or 'admin.' . $x).
sub static_prefix {
    my ($t, $m, $p) = @_;
    my $q = substr($t, $p, 1);
    return undef unless $q eq "'" || $q eq '"';
    my $e = index($m, $q, $p + 1);
    return undef if $e < 0;
    my $v = substr($t, $p + 1, $e - $p - 1);
    $v =~ s/[\$\{].*\z//s if $q eq '"';
    return length($v) >= 2 ? $v : undef;
}

# Route names defined in routes/**/*.php (and name prefixes set in
# RouteServiceProvider): full names, group prefixes ending in '.', and
# prefixes of names built at run time.
sub route_names {
    my ($L) = @_;
    return $RN{$L} if $RN{$L};
    my (%names, %pfx, %wild);
    my $add = sub { my $v = shift; if ($v =~ /\.\z/) { $pfx{$v} = 1 } elsif ($v ne '') { $names{$v} = 1 } };
    my @files = files_under("${L}routes", qr/\.php\z/i, 500);
    push @files, "${L}app/Providers/RouteServiceProvider.php";
    for my $rf (@files) {
        my $t = read_text($rf);
        next unless defined $t;
        my $m = mask_php($t, 0);
        while ($m =~ /(?:->|::)\s*name\s*\(\s*(?=['"])/g) {
            my $p = pos($m);
            my ($v) = lit($t, $m, $p);
            if (defined $v) { $add->($v); next }
            my $w = static_prefix($t, $m, $p);
            $wild{$w} = 1 if defined $w;
        }
        while ($t =~ /(['"])as\1\s*=>\s*(?=['"])/g) {
            my ($st, $p) = ($-[0], $+[0]);
            next unless substr($m, $st, 1) eq substr($t, $st, 1);    # code, not a comment
            my ($v) = lit($t, $m, $p);
            if (defined $v) { $add->($v) }
            else { my $w = static_prefix($t, $m, $p); $wild{$w} = 1 if defined $w }
        }
        while ($m =~ /\bRoute\s*::\s*(resource|apiResource|singleton|apiSingleton)\s*\(\s*(?=['"])/g) {
            my $kind = $1;
            my ($v) = lit($t, $m, pos($m)) or next;
            (my $b = $v) =~ s{\A.*/}{};    # 'admin/photos' is named photos.*
            $names{"$b.$_"} = 1 for @{ $RESOURCE{$kind} };
        }
        while ($m =~ /\bRoute\s*::\s*(resources|apiResources)\s*\(\s*\[/g) {
            my $kind = $1 eq 'resources' ? 'resource' : 'apiResource';
            my $st = $+[0];
            my $end = close_bracket($m, $st - 1);
            my $seg_t = substr($t, $st, $end - $st);
            my $seg_m = substr($m, $st, $end - $st);
            while ($seg_t =~ /(['"])([\w\-.\/]+)\1\s*=>/g) {
                my ($at, $v) = ($-[0], $2);
                next unless substr($seg_m, $at, 1) eq substr($seg_t, $at, 1);
                $v =~ s{\A.*/}{};
                $names{"$v.$_"} = 1 for @{ $RESOURCE{$kind} };
            }
        }
        while ($m =~ /->\s*names\s*\(\s*(?=['"\[])/g) {
            my $p = pos($m);
            if (substr($m, $p, 1) eq '[') {
                my $end = close_bracket($m, $p);
                my $seg_t = substr($t, $p, $end - $p);
                my $seg_m = substr($m, $p, $end - $p);
                while ($seg_t =~ /=>\s*(?=['"])/g) {
                    my ($v) = lit($seg_t, $seg_m, $+[0]);
                    $add->($v) if defined $v;
                }
            } else {
                my ($v) = lit($t, $m, $p) or next;
                $names{"$v.$_"} = 1 for @{ $RESOURCE{resource} };
            }
        }
        if ($m =~ /\b(?:Auth\s*::\s*routes|Route\s*::\s*auth)\s*\(/) { $names{$_} = 1 for @AUTH_ROUTES }
    }
    return $RN{$L} = { names => \%names, prefixes => [sort keys %pfx], wild => [sort keys %wild] };
}

sub route_ok {
    my ($R, $v, $depth) = @_;
    return 1 if $R->{names}{$v};
    for my $w (@{ $R->{wild} }) { return 1 if index($v, $w) == 0 }
    return 0 if $depth > 4;
    for my $px (@{ $R->{prefixes} }) {
        return 1 if length($v) > length($px) && index($v, $px) == 0 && route_ok($R, substr($v, length $px), $depth + 1);
    }
    return 0;
}

sub route_ref {
    my ($F, $n, $o, $m, $p) = @_;
    my ($v) = lit($o, $m, $p) or return;
    return if $v eq '' || $v =~ /[\s\$]/;
    my $R = route_names($F->{lara});
    return if route_ok($R, $v, 0);
    my $msg = "route name '$v' not defined in routes/ (could also come from a package)";
    my $s = suggest($v, keys %{ $R->{names} });
    $msg .= "; did you mean '$s'?" if defined $s;
    finding('WARN', $F->{file}, $n, $msg);
}

# Config file names that installed packages ship (merged even when unpublished).
sub vendor_config {
    my ($F, $name) = @_;
    my $v = $F->{proj} ? $F->{proj}{vendor} : "$F->{lara}vendor";
    if (!$VC{$v}) {
        my %h;
        for my $org (names_in($v)) {
            for my $pkg (names_in("$v/$org")) {
                next unless in_root("$v/$org/$pkg");
                for my $sub ('config', 'src/config', 'src/Config', 'resources/config') {
                    for my $f (names_in("$v/$org/$pkg/$sub")) { $h{ lc $1 } = 1 if $f =~ /\A(.+)\.php\z/ }
                }
            }
        }
        $VC{$v} = \%h;
    }
    return $VC{$v}{ lc $name };
}

sub config_ref {
    my ($F, $n, $o, $m, $p) = @_;
    my ($v) = lit($o, $m, $p) or return;
    return unless $v =~ /\A([\w\-]+)(?:\.|\z)/;
    my $name = $1;
    my $L = $F->{lara};
    my ($st, $path) = find_path("${L}config/$name.php");
    return if ($st eq 'ok' && -f $path) || $st eq 'outside';
    my ($ds, $dp) = find_path("${L}config/$name");
    return if $ds eq 'ok' && -d $dp;    # config/<name>/ holds nested config files
    my $msg;
    if ($st eq 'case' && -f $path) {
        $msg = "config('$v'): the file is $path (letter case differs), and config keys are case-sensitive";
    } else {
        return if vendor_config($F, $name);
        $msg = "config file config/$name.php not found for config('$v') (fine if a package provides it)";
        my $s = suggest_file("${L}config/$name.php", '.php');
        $msg .= "; did you mean config/$s.php?" if defined $s;
    }
    finding('INFO', $F->{file}, $n, $msg);
}

# Literal names registered with Blade::component() and friends; 'off' when an
# installed package provides components of its own.
sub component_registry {
    my ($F) = @_;
    my $L = $F->{lara};
    return $REG{$L} if $REG{$L};
    my (%names, $off);
    my $vendor = $F->{proj} ? $F->{proj}{vendor} : "${L}vendor";
    my $pk = read_text("$vendor/composer/installed.json");
    $pk = read_text("${L}composer.json") unless defined $pk;
    if (defined $pk) {
        while ($pk =~ /"([a-z0-9_.\-]+\/[a-z0-9_.\-]+)"/g) {
            my $name = $1;
            $off = 1 if $name =~ m{(?:\A|/)blade-|jetstream|livewire|filament|wireui|\A[\w.\-]+/mary\z|laravel-components|blade-ui-kit};
        }
    }
    for my $pf (files_under("${L}app", qr/\.php\z/, 3000)) {
        next unless $pf =~ m{/Providers/};
        my $t = read_text($pf);
        next unless defined $t;
        my $m = mask_php($t, 0);
        while ($m =~ /\bBlade\s*::\s*(?:component|components|anonymousComponentPath|anonymousComponentNamespace|componentNamespace)\s*\(/g) {
            my $st = $+[0];
            my $end = index($m, ';', $st);
            $end = length $m if $end < 0;
            my ($seg_t, $seg_m) = (substr($t, $st, $end - $st), substr($m, $st, $end - $st));
            my $found = 0;
            while ($seg_m =~ /(?=['"])/g) {
                my ($v, $after) = lit($seg_t, $seg_m, pos($seg_m));
                last unless defined $after;
                $names{$v} = 1;
                $found = 1;
                pos($seg_m) = $after;
            }
            $off = 1 unless $found;
        }
    }
    my $ns = 'App\\';
    if ($F->{proj}) {
        for my $e (@{ $F->{proj}{psr4} }) { if (grep { $_ eq norm_path("${L}app") } @{ $e->[1] }) { $ns = $e->[0]; last } }
    }
    return $REG{$L} = { off => $off, names => [sort keys %names], ns => "${ns}View\\Components\\" };
}

sub studly { return join '', map { ucfirst } split /[-_]+/, $_[0] }

sub component_ref {
    my ($F, $n, $name) = @_;
    return if $name =~ /\A(?:slot|dynamic-component)\z/ || $name =~ /:/;
    my $reg = component_registry($F);
    return if $reg->{off};
    for my $r (@{ $reg->{names} }) {
        my $k = $r;
        $k =~ s/\Acomponents\.//;
        return if $name eq $r || $name eq $k || index($name, "$r-") == 0 || index($name, "$r.") == 0;
    }
    (my $p = $name) =~ s{\.}{/}g;
    my $root = view_roots($F->{lara})->[0];
    return unless defined $root;
    my @cand = map { "$root/components/$_" } ("$p.blade.php", "$p.php", "$p/index.blade.php", "$p/" . base_of($p) . '.blade.php');
    my $case;
    for my $c (@cand) {
        my ($st, $real) = find_path($c);
        return if ($st eq 'ok' && -f $real) || $st eq 'outside';
        $case = $real if $st eq 'case' && -f $real && !defined $case;
    }
    my $cls = $reg->{ns} . join('\\', map { studly($_) } split m{/}, $p);
    if ($F->{proj}) {
        my ($st, $path) = class_status($F->{proj}, $cls);
        return if $st eq 'ok' || $st eq 'unknown';
        $case = $path if $st eq 'case' && !defined $case;
    } else {
        (my $cp = $cls) =~ s{\A[^\\]+\\}{};
        $cp =~ s{\\}{/}g;
        my ($st, $real) = find_path("$F->{lara}app/$cp.php");
        return if $st ne 'missing' && $st ne 'case';
        $case = $real if $st eq 'case' && !defined $case;
    }
    if (defined $case) {
        finding('WARN', $F->{file}, $n, "Blade component <x-$name>: the file is $case (letter case differs), so it fails on case-sensitive file systems such as Linux");
        return;
    }
    finding('WARN', $F->{file}, $n, "Blade component <x-$name> not found (expected $cand[0] or class $cls)");
}

# ---------------------------------------------------------------- JavaScript / TypeScript

sub check_js {
    my ($F) = @_;
    each_added($F, $F->{mask}, sub {
        my ($n, $o, $m) = @_;
        while ($m =~ /\b(?:from|import)\s*(?=['"])|\bimport\s*\(\s*(?=['"])|(?<![\w\$.])require\s*(?:\.\s*resolve\s*)?\(\s*(?=['"])/g) {
            my ($v) = lit($o, $m, pos($m)) or next;
            js_ref($F, $n, $v);
        }
    });
}

sub js_ref {
    my ($F, $n, $spec) = @_;
    (my $s = $spec) =~ s/[?#].*\z//s;
    return unless $s =~ m{\A\.\.?(?:/|\z)};
    my $base = norm_path(join_path(dir_of($F->{file}), $s));
    return unless defined $base;    # leaves the repository
    my @c = $base eq '' ? () : ($base, map { "$base$_" } @JS_EXT);
    push @c, map { join_path($base, $_) } @JS_INDEX, 'package.json';
    # TypeScript ESM code imports './x.js' for the source file x.ts
    push @c, map { "$1$_" } qw(.ts .tsx .mts .cts) if $base =~ /\A(.+)\.[cm]?jsx?\z/;
    my ($case, $out);
    for my $c (@c) {
        my ($st, $real) = find_path($c);
        return if $st eq 'ok' && -f $real;
        $case = $real if $st eq 'case' && -f $real && !defined $case;
        $out = 1 if $st eq 'outside';
    }
    if (defined $case) {
        finding('WARN', $F->{file}, $n, "import '$spec': the file is $case (letter case differs), so it fails on case-sensitive file systems such as Linux");
        return;
    }
    return if $out;
    my $msg = "import '$spec' does not resolve to a file";
    my ($ds, $dir) = find_path(dir_of($base));
    if ($ds eq 'ok') {
        (my $want = base_of($base)) =~ s/\.[^.]+\z//;
        my $sg = suggest($want, map { (my $x = $_) =~ s/\.[^.]+\z//; $x } names_in($dir));
        $msg .= "; did you mean '" . join_path(dir_of($s), $sg) . "'?" if defined $sg;
    }
    finding('WARN', $F->{file}, $n, $msg);
}

# ---------------------------------------------------------------- Python

sub check_py {
    my ($F) = @_;
    my ($m, $add) = ($F->{mask}, $F->{add});
    my $dir = dir_of($F->{file});
    while ($m =~ /(?:^|;)[ \t]*(from)[ \t]+(\.+)[ \t]*((?!import\b)[A-Za-z_]\w*(?:[ \t]*\.[ \t]*[A-Za-z_]\w*)*)?[ \t]*import\b/mg) {
        my ($at, $dots, $mod, $end) = ($-[1], $2, $3, $+[0]);
        my $base = norm_path(join_path($dir, join('/', ('..') x (length($dots) - 1))));
        next unless defined $base;    # above the repository root
        if (defined $mod) {
            my $line = line_of($F->{starts}, $at);
            next unless exists $add->{$line};
            (my $mp = $mod) =~ s/[ \t]*\.[ \t]*/\//g;
            (my $label = "$dots$mod") =~ s/[ \t]+//g;
            py_report($F, $line, $label, py_exists($base, $mp), join_path($base, $mp));
            next;
        }
        # from . import a, b   /   from . import (a,\n b)
        my $rest = substr($m, $end, 5000);
        my ($list, $lo);
        if ($rest =~ /\A[ \t]*\(([^)]*)/) { ($list, $lo) = ($1, $end + $-[1]) }
        elsif ($rest =~ /\A((?:[^\n\\]|\\\n?)*)/) { ($list, $lo) = ($1, $end + $-[1]) }
        else { next }
        while ($list =~ /([A-Za-z_]\w*)(?:\s+as\s+[A-Za-z_]\w*)?/g) {
            my ($nm, $nat) = ($1, $lo + $-[1]);
            my $line = line_of($F->{starts}, $nat);
            next unless exists $add->{$line};
            my @r = py_exists($base, $nm);
            next if $r[0] eq 'ok' || $r[0] eq 'outside';
            my $init = read_text(join_path($base, '__init__.py'));
            if (defined $init) {
                my $im = mask_py($init);
                next if $im =~ /(?<![\w.])\Q$nm\E\b/ || $im =~ /\b__getattr__\b/;
            }
            py_report($F, $line, "from $dots import $nm", @r, join_path($base, $nm));
        }
    }
}

# ('ok') | ('case', real path) | ('missing') | ('outside')
sub py_exists {
    my ($base, $mp) = @_;
    my $p = join_path($base, $mp);
    my ($case, $out);
    for my $c ("$p.py", "$p.pyi", $p) {
        my ($st, $real) = find_path($c);
        my $hit = $c eq $p ? -d $real : -f $real;
        return ('ok') if $st eq 'ok' && $hit;
        $case = $real if $st eq 'case' && $hit && !defined $case;
        $out = 1 if $st eq 'outside';
    }
    # compiled extension modules: name.pyd, name.cpython-312-x86_64-linux-gnu.so
    my ($ds, $dreal) = find_path(dir_of($p));
    if ($ds eq 'ok') {
        my $last = base_of($p);
        for my $x (names_in($dreal)) { return ('ok') if $x =~ /\A\Q$last\E(?:\.[\w\-]+)*\.(?:so|pyd)\z/ }
    }
    return ('case', $case) if defined $case;
    return ('outside') if $out;
    return ('missing');
}

sub py_report {
    my ($F, $n, $label, $st, $path, $want) = @_;
    return if $st eq 'ok' || $st eq 'outside';
    if ($st eq 'case') {
        finding('WARN', $F->{file}, $n, "relative import '$label': the file is $path (letter case differs), and Python imports are case-sensitive");
        return;
    }
    $want = $path if !defined $want;
    my $msg = "relative import '$label' not found (expected $want.py or $want/)";
    my ($ds, $dir) = find_path(dir_of($want));
    if ($ds eq 'ok') {
        my $sg = suggest(base_of($want), map { (my $x = $_) =~ s/\.pyi?\z//; $x } names_in($dir));
        $msg .= "; did you mean '$sg'?" if defined $sg;
    }
    finding('WARN', $F->{file}, $n, $msg);
}

# ---------------------------------------------------------------- run

for my $f (sort keys %ADD) {
    next if $SELF ne '' && index($f, $SELF) == 0;
    my $k = kind($f) or next;
    eval { check_file($f, $k); 1 } or print STDERR 'symbol-check: skipped ', clean($f, 300), ': ', clean($@, 300), "\n";
}
for my $r (sort { $a->[1] cmp $b->[1] || $a->[2] <=> $b->[2] || $a->[3] cmp $b->[3] } @OUT) {
    print join("\t", @$r), "\n";
}
exit 0;
