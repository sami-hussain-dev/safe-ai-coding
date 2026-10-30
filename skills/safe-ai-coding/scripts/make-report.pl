#!/usr/bin/env perl
# make-report.pl - renders a JSON account of a change (what was wrong, what was
# fixed, how it was checked) as a print-ready HTML page. Part of the
# safe-ai-coding skill: report mode, used only when the user asks for a report.
# html-to-pdf.sh then prints the page to PDF.
#
# Usage: perl make-report.pl <input.json> <output.html> [--lang=en|ur]
#   --lang  overrides the JSON "language" field; default en. ur = Roman Urdu
#           (Urdu written in Latin letters).
#   Layout: ../templates/report-template.html, relative to this script.
#   Footer version: first line of ../VERSION, else "dev". When SOURCE_DATE_EPOCH
#   is set, it fixes the "generated" time, so the output can be repeated exactly.
# Exit code: 0 on success (prints the output path); 2 when the input cannot be
# read, is not valid JSON or lacks a required field (stderr says which). Bad
# optional fields are reported as warnings on stderr and skipped.
#
# Input: UTF-8 JSON (a BOM, or UTF-16 with a BOM, is accepted). Required: title,
# summary, problems, fixes (use [] when there are none), and a title in every
# problem and fix. Everything else is optional.
#   {
#     "language": "en" | "ur",
#     "title": "...", "status": "fixed" | "partial" | "open",          (default fixed)
#     "project": "...", "branch": "...", "commit": "...", "date": "YYYY-MM-DD",
#     "prepared_by": "...", "requested_by": "...",
#     "summary": "...",
#     "problems": [ { "id": "P1", "title": "...", "severity": "critical|high|medium|low|info",
#                     "where": "...", "symptom": "...", "root_cause": "...", "impact": "...",
#                     "evidence": "...", "found_by": "ai|human|scan|test|user" } ],
#     "fixes": [ { "id": "F1", "title": "...", "fixes": ["P1"], "change": "...",
#                  "why_correct": "...", "files": ["path"], "before": "code",
#                  "after": "code", "code_language": "php" } ],
#     "verification": [ { "check": "...", "perspective": "ai|human|both",
#                         "result": "pass|fail|partial|not-run", "detail": "..." } ],
#     "scans": { "before": { "high": 0, "warn": 0, "info": 0 },
#                "after":  { "high": 0, "warn": 0, "info": 0 }, "note": "..." },
#     "approvals": [ { "action": "...", "harm": "...",
#                      "decision": "approved|declined|safer-option", "when": "..." } ],
#     "files_changed": [ { "path": "...", "added": 0, "removed": 0 } ],
#     "remaining_risks": ["..."], "next_steps": ["..."]
#   }
# Missing ids become P1.. and F1..; a check without a result is shown as not run.
# In text, a blank line starts a paragraph, a newline is a line break, lines that
# all start with "- " (or "1. ") form a list, and `backticks` mark code.
#
# Safety. The page has no JavaScript and a Content-Security-Policy that blocks
# scripts and every network request. Every string is HTML-escaped; control
# characters become '?', and hidden unicode (bidi controls, zero-width and tag
# characters) is shown as <U+XXXX>. Before that, every string is masked:
#   - PEM private key blocks: the key body becomes ****
#   - AWS key ids (AKIA/ASIA + 16), GitHub tokens (ghp_ gho_ ghu_ ghs_ ghr_
#     github_pat_), GitLab glpat-, Slack xox?- tokens, Google AIza keys, sk- /
#     sk_live_ / sk_test_ keys, Hugging Face hf_, Groq gsk_, Replicate r8_, xAI
#     xai-, SendGrid SG., Square sq0csp-, Shopify shpat_, JWTs and Bearer/Basic
#     credentials: the prefix stays, then ****
#   - passwords in URLs (scheme://user:****@host) and secret URL parameters
#     (?token=, &api_key=, &signature=, ...)
#   - values given to a name containing password, passwd, passphrase, secret,
#     token, api_key/apikey, private_key or access_key: quoted after = => : := or
#     a comma (define('DB_PASSWORD', '...')), unquoted as NAME=value, or as a
#     whole "NAME = value" / "name: value" line. The first 2 characters stay,
#     then ****; values shorter than 8 become ****. Left alone: $variables,
#     {{ }} and <?= ?> templates, rule lists ("required|min:8"), sentences, URLs
#     and placeholders ("changeme", "xxx").
#   - Pakistani CNIC 12345-1234567-1 -> 12345-*******-1, and 123-45-6789 -> ***-**-6789
# Masking is pattern based: a secret in an unusual format still gets through.

BEGIN { @INC = grep { $_ ne '.' && $_ ne '' } @INC }    # never load modules from the current directory
use strict;
use warnings;
use Encode ();
use FindBin ();
use JSON::PP ();
use Time::Local ();

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $USAGE     = 'usage: perl make-report.pl <input.json> <output.html> [--lang=en|ur]';
my $MAX_INPUT = 10 * 1024 * 1024;
my @SEV       = qw(critical high medium low info);
my $HIDDEN    = qr/[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{200B}\x{2060}-\x{2064}\x{FEFF}\x{E0000}-\x{E007F}]/;

# Labels. Single quotes on purpose: several contain sprintf formats such as %2$d.
my %LABEL = (
    en => {
        eyebrow => 'Change report',
        st_fixed => 'Fixed', st_partial => 'Partly fixed', st_open => 'Open',
        m_project => 'Project', m_branch => 'Branch', m_commit => 'Commit', m_date => 'Date',
        m_prepared_by => 'Prepared by', m_requested_by => 'Requested by',
        s_summary => 'Summary', glance => 'At a glance',
        s_problems => 'What was wrong', i_problems => 'Each problem as it was found, before anything was changed.',
        s_fixes => 'What we fixed', i_fixes => 'What changed, why it is the right fix, and the code before and after.',
        s_verification => 'Verification', i_verification => 'How the change was checked, by the AI agent and by people.',
        s_scans => 'Scans before and after', i_scans => 'Red-flag scan of the change, before and after the fix.',
        s_approvals => 'Approvals', i_approvals => 'Risky actions the agent asked permission for, and the harm it named.',
        s_files => 'Files changed',
        s_risks => 'Remaining risks', i_risks => 'What is still not covered. Read these before relying on the change.',
        s_steps => 'Next steps',
        sev_critical => 'Critical', sev_high => 'High', sev_medium => 'Medium', sev_low => 'Low', sev_info => 'Info',
        f_where => 'Where', f_found_by => 'Found by', f_fixed_by => 'Fixed by', no_fix => 'No fix listed',
        f_symptom => 'Symptom', f_root_cause => 'Root cause', f_impact => 'Impact', f_evidence => 'Evidence',
        by_ai => 'AI', by_human => 'Human', by_scan => 'Scan', by_test => 'Test', by_user => 'User',
        f_fixes => 'Fixes', f_change => 'Change', f_why => 'Why it is correct', f_files => 'Files',
        before => 'Before', after => 'After',
        h_check => 'Check', h_perspective => 'Perspective', h_result => 'Result', h_detail => 'Detail',
        p_ai => 'AI', p_human => 'Human', p_both => 'AI + human',
        r_pass => 'Pass', r_fail => 'Fail', r_partial => 'Partial', 'r_not-run' => 'Not run',
        v_summary => '%d checks: %d by the AI, %d by people, %d by both.',
        lv_high => 'High', lv_warn => 'Warn', lv_info => 'Info',
        h_action => 'Action', h_harm => 'Possible harm', h_decision => 'Decision', h_when => 'When',
        d_approved => 'Approved', d_declined => 'Declined', 'd_safer-option' => 'Safer option',
        h_file => 'File', h_added => 'Added', h_removed => 'Removed', h_stat => 'Share', total => 'Total',
        t_problems => 'Problems found', t_fixes => 'Fixes made', t_checks => 'Checks passed',
        t_approvals => 'Permission requests', t_scan => 'Scan HIGH findings',
        covers => 'cover %d of %d problems', before_after => "before \x{2192} after",
        n_sev => '%d %s', n_failed => '%d failed', n_partial => '%d partial', n_not_run => '%d not run',
        n_approved => '%d approved', n_declined => '%d declined', n_safer => '%d safer option',
    },
    ur => {
        eyebrow => 'Tabdeeli ki report',
        st_fixed => 'Theek ho gaya', st_partial => 'Kuch hissa theek hua', st_open => 'Abhi baqi hai',
        m_project => 'Project', m_branch => 'Branch', m_commit => 'Commit', m_date => 'Tareekh',
        m_prepared_by => 'Tayyar kiya', m_requested_by => 'Kis ke kehne par',
        s_summary => 'Khulasa', glance => 'Ek nazar mein',
        s_problems => 'Pehle kya masla tha', i_problems => 'Har masla waise hi jaise mila, kuch badalne se pehle.',
        s_fixes => 'Kya theek kiya', i_fixes => 'Kya badla, yeh hal sahi kyun hai, aur code pehle aur baad mein.',
        s_verification => 'Jaanch', i_verification => 'Tabdeeli ko kaise jaancha gaya: AI agent ne bhi aur insaanon ne bhi.',
        s_scans => 'Scan: pehle aur baad mein', i_scans => 'Fix se pehle aur baad mein tabdeeli ka red-flag scan.',
        s_approvals => 'Ijazatein', i_approvals => 'Woh khatarnak kaam jin ke liye agent ne ijazat maangi, aur jo nuqsan us ne bataya.',
        s_files => 'Badli gayi files',
        s_risks => 'Baqi khatre', i_risks => 'Jo abhi poori tarah mehfooz nahi. Is tabdeeli par bharosa karne se pehle inhein parhein.',
        s_steps => 'Agle qadam',
        sev_critical => 'Intehai sangeen', sev_high => 'Sangeen', sev_medium => 'Darmiyana', sev_low => 'Kam', sev_info => 'Maloomat',
        f_where => 'Kahan', f_found_by => 'Kis ne pakra', f_fixed_by => 'Hal', no_fix => 'Koi hal darj nahi',
        f_symptom => 'Kya nazar aaya', f_root_cause => 'Asal wajah', f_impact => 'Asar', f_evidence => 'Saboot',
        by_ai => 'AI', by_human => 'Insaan', by_scan => 'Scan', by_test => 'Test', by_user => 'User',
        f_fixes => 'Kis masle ka hal', f_change => 'Kya badla', f_why => 'Yeh sahi kyun hai', f_files => 'Files',
        before => 'Pehle', after => 'Baad mein',
        h_check => 'Jaanch', h_perspective => 'Kis ne jaancha', h_result => 'Nateeja', h_detail => 'Tafseel',
        p_ai => 'AI', p_human => 'Insaan', p_both => 'AI + insaan',
        r_pass => 'Kamyab', r_fail => 'Nakam', r_partial => 'Adhoora', 'r_not-run' => 'Nahi chalaya',
        v_summary => '%d jaanchein: AI ne %d, insaanon ne %d, dono ne %d.',
        lv_high => 'Sangeen', lv_warn => 'Tanbeeh', lv_info => 'Maloomat',
        h_action => 'Kaam', h_harm => 'Mumkina nuqsan', h_decision => 'Faisla', h_when => 'Kab',
        d_approved => 'Manzoor', d_declined => 'Na-manzoor', 'd_safer-option' => 'Mehfooz rasta',
        h_file => 'File', h_added => 'Shamil', h_removed => 'Hazf', h_stat => 'Hissa', total => 'Kul',
        t_problems => 'Masail mile', t_fixes => 'Hal kiye', t_checks => 'Kamyab jaanchein',
        t_approvals => 'Ijazat ki darkhwastein', t_scan => 'Scan ke sangeen nataij',
        covers => '%2$d mein se %1$d masail ka hal', before_after => "pehle \x{2192} baad mein",
        n_sev => '%d %s', n_failed => '%d nakam', n_partial => '%d adhoori', n_not_run => '%d nahi chalayi',
        n_approved => '%d manzoor', n_declined => '%d na-manzoor', n_safer => '%d mehfooz rasta',
    },
);

# Accepted spellings of the enum fields, after lower-casing and turning spaces
# and underscores into hyphens.
my %ALIAS = (
    severity    => { map({ $_ => $_ } @SEV), informational => 'info', moderate => 'medium' },
    status      => { map({ $_ => $_ } qw(fixed partial open)), 'partly-fixed' => 'partial',
                     'partially-fixed' => 'partial', resolved => 'fixed', 'not-fixed' => 'open', unfixed => 'open' },
    found_by    => { map({ $_ => $_ } qw(ai human scan test user)), tests => 'test', scanner => 'scan',
                     person => 'human', reviewer => 'human' },
    perspective => { map({ $_ => $_ } qw(ai human both)), 'ai+human' => 'both', 'human+ai' => 'both',
                     'ai-and-human' => 'both', 'human-and-ai' => 'both' },
    result      => { map({ $_ => $_ } qw(pass fail partial not-run)), passed => 'pass', failed => 'fail',
                     skipped => 'not-run', 'not-tested' => 'not-run' },
    decision    => { map({ $_ => $_ } qw(approved declined safer-option)), denied => 'declined',
                     rejected => 'declined', safer => 'safer-option' },
);

my %KEYS = (
    top          => [qw(language title status project branch commit date prepared_by requested_by summary
                        problems fixes verification scans approvals files_changed remaining_risks next_steps)],
    problem      => [qw(id title severity where symptom root_cause impact evidence found_by)],
    fix          => [qw(id title fixes change why_correct files before after code_language)],
    verification => [qw(check perspective result detail)],
    scans        => [qw(before after note)],
    counts       => [qw(high warn info)],
    approval     => [qw(action harm decision when)],
    file         => [qw(path added removed)],
);

my $SECRET_WORD = qr/(?i:password|passwd|passphrase|secret|token|api[_-]?key|apikey|private[_-]?key|access[_-]?key)/;
# Bounded on both sides: an unbounded identifier run would make long strings slow.
my $SECRET_NAME = qr/[A-Za-z0-9_.-]{0,40}?$SECRET_WORD[A-Za-z0-9_.-]{0,40}/;
my $URL_SECRET  = qr/(?i:access_?token|refresh_?token|id_?token|auth_?token|token|api_?key|apikey|key|secret|client_?secret|password|passwd|pwd|sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token)/;

my ($IN, $OUT, $LANG_ARG) = parse_args(@ARGV);
my ($IN_SHOWN, $OUT_SHOWN) = (shown($IN), shown($OUT));
my $T;           # labels of the chosen language
my $SECNO = 0;   # section number on the page
my %PIDX;        # problem id -> position (1-based)

my $ok = eval { main(); 1 };
unless ($ok) { my $e = "$@"; $e =~ s/\s+\z//; fail("internal error: $e") }
exit 0;

sub main {
    my $r = normalize(read_json($IN));
    my $lang = $LANG_ARG // $r->{language} // 'en';
    $T = $LABEL{$lang};
    my $content = render($r);
    my $page = read_template();
    my %val = (
        LANG      => $lang eq 'ur' ? 'ur-Latn' : 'en',
        TITLE     => esc($r->{title}),
        CONTENT   => $content,
        GENERATED => esc(generated()),
        VERSION   => esc(version()),
    );
    # One pass, so placeholder-like text inside the content is never replaced again.
    $page =~ s/\{\{(LANG|TITLE|CONTENT|GENERATED|VERSION)\}\}/$val{$1}/g;
    write_out($OUT, $page);
    print "$OUT_SHOWN\n";
}

# ---------------------------------------------------------------- arguments and files

sub parse_args {
    my (@pos, $lang);
    while (@_) {
        my $arg = shift;
        if ($arg eq '--') { push @pos, @_; last }
        elsif ($arg eq '-h' || $arg eq '--help') { print "$USAGE\n"; exit 0 }
        elsif ($arg =~ /\A--lang=(.*)\z/s) { $lang = $1 }
        elsif ($arg eq '--lang') { @_ or fail("--lang needs a value: en or ur\n$USAGE"); $lang = shift }
        elsif ($arg =~ /\A-./) { fail('unknown option ' . shown($arg) . "\n$USAGE") }
        else { push @pos, $arg }
    }
    fail("expected an input .json file and an output .html file\n$USAGE") unless @pos == 2;
    if (defined $lang) {
        my $l = lang_code($lang);
        fail('unknown --lang value ' . shown($lang) . ' (use en or ur)') unless $l;
        $lang = $l;
    }
    fail('the output file must end in .html or .htm: ' . shown($pos[1])) unless $pos[1] =~ /\.html?\z/i;
    return @pos, $lang;
}

sub lang_code {
    my $l = lc(shift // '');
    $l =~ s/^\s+|\s+$//g;
    return 'en' if $l =~ /\Aen(?:[-_][a-z0-9]+)*\z/;
    return 'ur' if $l =~ /\A(?:ur(?:[-_][a-z0-9]+)*|roman[-_ ]?urdu)\z/;
    return undef;
}

sub read_json {
    my $path = shift;
    fail("cannot read $IN_SHOWN: no such file") unless -e $path;
    fail("cannot read $IN_SHOWN: not a regular file") unless -f _;
    fail("cannot read $IN_SHOWN: larger than 10 MB, which no report needs") if -s _ > $MAX_INPUT;
    open(my $fh, '<:raw', $path) or fail("cannot read $IN_SHOWN: $!");
    my $bytes = do { local $/; <$fh> };
    close $fh;
    $bytes = '' unless defined $bytes;
    my $text = decode_input($bytes);
    fail("invalid JSON in $IN_SHOWN: the file is empty") if $text !~ /\S/;
    my $data = eval { JSON::PP->new->decode($text) };
    unless (defined $data) {
        my $e = "$@";
        $e =~ s/\A(.*) at .*? line \d+\.?\s*\z/$1/s;
        $e =~ s/\s+\z//;
        if ($e =~ /character offset (\d+)/) {
            my $pre = substr($text, 0, $1);
            my $line = ($pre =~ tr/\n//) + 1;
            my $col = length($pre) - rindex($pre, "\n");
            $e .= " (line $line, column $col)";
        }
        fail("invalid JSON in $IN_SHOWN: " . short($e, 300));
    }
    fail("invalid JSON in $IN_SHOWN: the top level must be an object { ... }") unless ref $data eq 'HASH';
    return $data;
}

sub decode_input {
    my $b = shift;
    return Encode::decode('UTF-16LE', substr($b, 2)) if $b =~ /\A\xFF\xFE/;
    return Encode::decode('UTF-16BE', substr($b, 2)) if $b =~ /\A\xFE\xFF/;
    $b =~ s/\A\xEF\xBB\xBF//;
    my $t = eval { Encode::decode('UTF-8', $b, Encode::FB_CROAK | Encode::LEAVE_SRC) };
    return $t if defined $t;
    note_warn("$IN_SHOWN is not valid UTF-8; unreadable bytes are shown as \x{FFFD}");
    return Encode::decode('UTF-8', $b);
}

sub read_template {
    my $f = "$FindBin::RealBin/../templates/report-template.html";
    open(my $fh, '<:raw', $f) or fail('cannot read the template ' . shown($f) . ": $!");
    my $t = do { local $/; <$fh> };
    close $fh;
    $t = Encode::decode('UTF-8', defined $t ? $t : '');
    $t =~ s/\A\x{FEFF}//;
    fail('the template ' . shown($f) . ' has no {{CONTENT}} placeholder') unless $t =~ /\{\{CONTENT\}\}/;
    return $t;
}

sub version {
    open(my $fh, '<:raw', "$FindBin::RealBin/../VERSION") or return 'dev';
    my $v = <$fh>;
    close $fh;
    return 'dev' unless defined $v;
    $v = Encode::decode('UTF-8', $v);
    $v =~ s/\A\x{FEFF}//;
    $v = oneline(clean($v));
    $v = substr($v, 0, 40) if length $v > 40;
    return length $v ? $v : 'dev';
}

sub generated {
    my $sde = $ENV{SOURCE_DATE_EPOCH};
    if (defined $sde && $sde =~ /\A\d{1,12}\z/) {
        my @g = gmtime($sde);
        return sprintf('%04d-%02d-%02d %02d:%02d UTC', $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1]);
    }
    my $now = time;
    my @l = localtime($now);
    my $off = int((Time::Local::timegm(@l[0 .. 5]) - $now) / 60);
    my $sign = $off < 0 ? '-' : '+';
    $off = abs $off;
    return sprintf('%04d-%02d-%02d %02d:%02d UTC%s%02d:%02d',
        $l[5] + 1900, $l[4] + 1, $l[3], $l[2], $l[1], $sign, int($off / 60), $off % 60);
}

sub write_out {
    my ($path, $html) = @_;
    fail("cannot write $OUT_SHOWN: it is a directory") if -d $path;
    fail("refusing to write $OUT_SHOWN: it is the input file") if -e $path && same_file($path, $IN);
    # Write next to the target, then rename: a failed run never leaves half a page.
    my $tmp = "$path.tmp$$";
    open(my $fh, '>:raw', $tmp) or fail("cannot write $OUT_SHOWN: $!");
    my $okw = print {$fh} Encode::encode('UTF-8', $html);
    $okw = close($fh) && $okw;
    unless ($okw && rename($tmp, $path)) {
        my $e = "$!";
        unlink $tmp;
        fail("cannot write $OUT_SHOWN: $e");
    }
}

sub same_file {
    my ($x, $y) = @_;
    my @a = stat $x;
    my @b = stat $y;
    return 0 unless @a && @b;
    return ($a[0] == $b[0] && $a[1] == $b[1]) if $a[1] && $b[1];
    # Some Windows builds report no inode numbers: compare the resolved paths.
    require Cwd;
    my ($p, $q) = (Cwd::abs_path($x), Cwd::abs_path($y));
    return defined $p && defined $q && lc $p eq lc $q;
}

sub fail {
    print STDERR 'make-report: ', printable(shift), "\n";
    exit 2;
}

sub note_warn { print STDERR 'make-report: warning: ', printable(shift), "\n" }

# ---------------------------------------------------------------- text cleaning and masking

sub printable {
    my $s = shift;
    $s = '' unless defined $s;
    $s =~ s/\r\n?/\n/g;
    $s =~ s/($HIDDEN)/sprintf('<U+%04X>', ord $1)/ge;
    $s =~ tr/\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F/?/;
    return $s;
}

sub shown {    # a command-line value (bytes) as printable text
    my $s = shift;
    $s = '' unless defined $s;
    utf8::decode($s);
    return printable($s);
}

sub short {
    my ($s, $n) = @_;
    $n ||= 60;
    $s = oneline($s);
    return length $s > $n ? substr($s, 0, $n - 3) . '...' : $s;
}

sub oneline { my $s = shift; $s = '' unless defined $s; $s =~ s/\s+/ /g; $s =~ s/^ | $//g; return $s }
sub trim { my $s = shift; $s =~ s/\A\s+|\s+\z//g; return $s }

sub clean {
    my $s = shift;
    $s = '' unless defined $s;
    $s =~ s/\r\n?/\n/g;
    $s =~ s/\x{2028}/\n/g;
    $s =~ s/\x{2029}/\n\n/g;
    $s =~ s/($HIDDEN)/sprintf('<U+%04X>', ord $1)/ge;
    $s =~ s/[\x{D800}-\x{DFFF}]/\x{FFFD}/g;
    $s =~ tr/\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F/?/;
    return mask($s);
}

sub mask {
    my $s = shift;
    # Private keys: a whole block, or a BEGIN line followed by key material.
    $s =~ s{-----BEGIN ([A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?)-----(?:(?!-----END ).){0,20000}?-----END \1-----}
           {-----BEGIN $1-----\n****\n-----END $1-----}gs;
    $s =~ s{(-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----)(?:[ \t]*\n?[ \t]*(?:[A-Za-z0-9+/=]{16,}|[A-Za-z-]+:[^\n]*))+}
           {$1\n****}g;
    # Credentials in URLs.
    $s =~ s{\b([a-zA-Z][a-zA-Z0-9+.-]{1,20}://[^\s/:\@'"<>]{1,100}:)([^\s/\@'"<>]{1,200})\@}
           { my ($k, $v) = ($1, $2); $v =~ /\A\*+\z/ ? "$k$v\@" : "$k****\@" }ge;
    $s =~ s{([?&]$URL_SECRET=)([^&\s#'"<>]{1,500})}{ my ($k, $v) = ($1, $2); $k . mask_value($v, 0) }ge;
    # Well-known token formats: keep the prefix that says what kind of key it was.
    $s =~ s{(?<![A-Za-z0-9])(AKIA|ASIA)[A-Z0-9]{16,}}{$1****}g;
    $s =~ s{(?<![A-Za-z0-9_])(gh[pousr]_)[A-Za-z0-9]{20,}}{$1****}g;
    $s =~ s{(?<![A-Za-z0-9_])(github_pat_)[A-Za-z0-9_]{20,}}{$1****}g;
    $s =~ s{(?<![A-Za-z0-9_-])(glpat-|hf_|gsk_|r8_|xai-|sq0csp-|shpat_)[A-Za-z0-9_-]{16,}}{$1****}g;
    $s =~ s{(?<![A-Za-z0-9_-])(SG\.)[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}}{$1****}g;
    $s =~ s{(?<![A-Za-z0-9])(xox[A-Za-z0-9]-)[A-Za-z0-9-]{8,}}{$1****}g;
    $s =~ s{(?<![A-Za-z0-9_-])(AIza)[0-9A-Za-z_-]{30,}}{$1****}g;
    $s =~ s{(?<![A-Za-z0-9_])((?:sk|rk)_(?:live|test)_)[0-9A-Za-z]{8,}}{$1****}g;
    $s =~ s{(?<![A-Za-z0-9_-])(sk-)(?=[A-Za-z0-9_-]{0,300}[0-9A-Z])[A-Za-z0-9_-]{20,}}{$1****}g;
    $s =~ s{(?<![A-Za-z0-9_-])(eyJ)[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}}{$1****}g;
    $s =~ s{\b((?i:bearer|basic))([ \t]+)(?=[A-Za-z0-9._~+/=-]*[0-9])[A-Za-z0-9._~+/-]{12,}=*}{$1$2****}g;
    # Values given to secret-looking names.
    $s =~ s{($SECRET_NAME["'`]?[ \t]*(?:=>|:=|=|:)[ \t]*)(["'`])((?:\\.|(?!\2)[^\\\n]){0,500})\2}
           { my ($k, $q, $v) = ($1, $2, $3); $k . $q . mask_value($v, 0) . $q }ge;
    $s =~ s{(["'])($SECRET_NAME)\1([ \t]*,[ \t]*)(["'])((?:\\.|(?!\4)[^\\\n]){0,500})\4}
           { my ($q1, $k, $sep, $q2, $v) = ($1, $2, $3, $4, $5); "$q1$k$q1$sep$q2" . mask_value($v, 0) . $q2 }ge;
    $s =~ s{((?<![A-Za-z0-9_\$])$SECRET_NAME=)([^\s'"`&;,<>]{1,500})}{ my ($k, $v) = ($1, $2); $k . mask_value($v, 1) }ge;
    $s =~ s{^([ \t]*(?:export[ \t]+)?$SECRET_NAME[ \t]*=[ \t]*)([^\s'"`]\S{0,500})(?=[ \t]*(?:\#.*)?$)}
           { my ($k, $v) = ($1, $2); $k . mask_value($v, 1) }gme;
    $s =~ s{^([ \t]*$SECRET_NAME[ \t]*:[ \t]+)([^\s'"`]\S{0,500})(?=[ \t]*$)}
           { my ($k, $v) = ($1, $2); $k . mask_value($v, 1) }gme;
    # National-ID-looking numbers.
    $s =~ s{(?<![0-9])([0-9]{5})-[0-9]{7}-([0-9])(?![0-9])}{$1-*******-$2}g;
    $s =~ s{(?<![0-9])[0-9]{3}-[0-9]{2}-([0-9]{4})(?![0-9])}{***-**-$1}g;
    return $s;
}

sub mask_value {
    my ($v, $bare) = @_;
    return $v if keep_value($v, $bare);
    return length($v) >= 8 ? substr($v, 0, 2) . '****' : '****';
}

sub keep_value {    # true for values that are clearly not a secret
    my ($v, $bare) = @_;
    return 1 if $v !~ /\S/ || $v =~ /\*{3}/;
    return 1 if $v =~ /\A[\$%{<\@&#]/ || $v =~ /\|/ || $v =~ /\S\s+\S+\s+\S/;
    return 1 if $v =~ m{\A[a-z][a-z0-9+.-]*://}i;
    return 1 if $bare && $v =~ /[()\[\]{}]|->|::/;
    my $l = lc $v;
    return 1 if $l =~ /\A(?:required|nullable|sometimes|confirmed|string|integer|numeric|boolean|bail|filled|present
                          |hidden|null|none|nil|undefined|true|false|yes|no|on|off|bearer|basic|example|sample
                          |changeme|change[_-]me|placeholder|dummy|test|password|passwd|secret|token|redacted|masked
                          |x+|\.+)\z/x;
    return 1 if $l =~ /\A(?:same|different|min|max|size|between|exists|unique|in|not_in|regex|required_[a-z_]+|current_password):/;
    return 1 if $l =~ /\A(?:your|my|enter)[ _-]/;
    return 0;
}

# ---------------------------------------------------------------- reading the fields

sub text_of { my $v = shift; return undef if !defined $v || ref $v; return "$v" }

sub unknown_keys {
    my ($h, $path, $kind) = @_;
    my %ok = map { $_ => 1 } @{ $KEYS{$kind} };
    for my $k (sort keys %$h) {
        note_warn("unknown field $path" . short($k, 40) . ' ignored') unless $ok{$k};
    }
}

sub opt_text {
    my ($h, $k, $path) = @_;
    return '' unless defined $h->{$k};
    my $v = text_of($h->{$k});
    unless (defined $v) { note_warn("$path$k: expected text, ignored"); return '' }
    return trim(clean($v));
}

sub opt_code {    # like opt_text, but keeps the indentation of the first line
    my ($h, $k, $path) = @_;
    return '' unless defined $h->{$k};
    my $v = text_of($h->{$k});
    unless (defined $v) { note_warn("$path$k: expected text, ignored"); return '' }
    $v = clean($v);
    $v =~ s/\A(?:[ \t]*\n)+//;
    $v =~ s/\s+\z//;
    return $v;
}

sub opt_list {    # a list of text; a single string counts as a list of one
    my ($h, $k, $path) = @_;
    return [] unless defined $h->{$k};
    my $v = $h->{$k};
    $v = [$v] unless ref $v;
    unless (ref $v eq 'ARRAY') { note_warn("$path$k: expected a list of text, ignored"); return [] }
    my @out;
    for my $i (0 .. $#$v) {
        my $t = text_of($v->[$i]);
        unless (defined $t) { note_warn("$path$k\[$i]: expected text, skipped"); next }
        $t = trim(clean($t));
        push @out, $t if length $t;
    }
    return \@out;
}

sub opt_objects {    # an optional list of objects
    my ($h, $k) = @_;
    return [] unless defined $h->{$k};
    unless (ref $h->{$k} eq 'ARRAY') { note_warn("$k: expected a list, ignored"); return [] }
    my @out;
    for my $i (0 .. $#{ $h->{$k} }) {
        my $e = $h->{$k}[$i];
        if (ref $e eq 'HASH') { push @out, [ $e, "$k\[$i]." ] }
        else { note_warn("$k\[$i]: expected an object, skipped") }
    }
    return \@out;
}

sub opt_enum {    # -> (canonical value or '', the text as written when the value is unknown)
    my ($h, $k, $path, $kind) = @_;
    my $raw = oneline(opt_text($h, $k, $path));
    return ('', '') if $raw eq '';
    (my $key = lc $raw) =~ s/[\s_]+/-/g;
    $key =~ s/-?\+-?/+/g;
    return ($ALIAS{$kind}{$key}, '') if $ALIAS{$kind}{$key};
    note_warn("$path$k: unknown value '" . short($raw, 40) . "', shown as written");
    return ('', $raw);
}

sub opt_count {
    my ($h, $k, $path) = @_;
    return undef unless defined $h->{$k};
    my $v = text_of($h->{$k});
    return $1 + 0 if defined $v && $v =~ /\A\s*(\d{1,9})\s*\z/;
    note_warn("$path$k: expected a whole number, ignored");
    return undef;
}

sub normalize {
    my $d = shift;
    my @err;
    for my $k (qw(title summary)) {
        my $v = text_of($d->{$k});
        if (!exists $d->{$k}) { push @err, "$k (missing)" }
        elsif (!defined $v || $v !~ /\S/) { push @err, "$k (must be non-empty text)" }
    }
    for my $k (qw(problems fixes)) {
        if (!exists $d->{$k}) { push @err, "$k (missing; use [] when there are none)"; next }
        if (ref $d->{$k} ne 'ARRAY') { push @err, "$k (must be a list)"; next }
        for my $i (0 .. $#{ $d->{$k} }) {
            my $e = $d->{$k}[$i];
            if (ref $e ne 'HASH') { push @err, "$k\[$i] (must be an object)"; next }
            my $t = text_of($e->{title});
            next if defined $t && $t =~ /\S/;
            push @err, "$k\[$i].title (" . (exists $e->{title} ? 'must be non-empty text' : 'missing') . ')';
        }
    }
    fail("$IN_SHOWN: missing or invalid required field(s): " . join('; ', @err)) if @err;
    unknown_keys($d, '', 'top');

    my %r;
    $r{title} = oneline(opt_text($d, 'title', ''));
    $r{summary} = opt_text($d, 'summary', '');
    my $lang = oneline(opt_text($d, 'language', ''));
    if (length $lang) {
        $r{language} = lang_code($lang) or note_warn("language: unknown value '" . short($lang, 20) . "', using en");
    }
    ($r{status}, $r{status_raw}) = opt_enum($d, 'status', '', 'status');
    $r{status} = 'fixed' if $r{status} eq '' && $r{status_raw} eq '';
    $r{$_} = oneline(opt_text($d, $_, '')) for qw(project branch commit date prepared_by requested_by);
    note_warn("date: expected YYYY-MM-DD, shown as written") if length $r{date} && $r{date} !~ /\A\d{4}-\d{2}-\d{2}\z/;

    my @P;
    for my $i (0 .. $#{ $d->{problems} }) {
        my ($p, $path) = ($d->{problems}[$i], "problems[$i].");
        unknown_keys($p, $path, 'problem');
        my %q = (n => $i + 1, fixed_by => []);
        $q{id} = short(opt_text($p, 'id', $path), 24);
        $q{id} = 'P' . ($i + 1) unless length $q{id};
        $q{title} = oneline(opt_text($p, 'title', $path));
        ($q{sev}, $q{sev_raw}) = opt_enum($p, 'severity', $path, 'severity');
        ($q{by}, $q{by_raw}) = opt_enum($p, 'found_by', $path, 'found_by');
        $q{$_} = opt_text($p, $_, $path) for qw(where symptom root_cause impact evidence);
        if (exists $PIDX{ $q{id} }) { note_warn("${path}id: '$q{id}' is used by more than one problem") }
        else { $PIDX{ $q{id} } = $i + 1 }
        push @P, \%q;
    }
    $r{problems} = \@P;

    my @F;
    for my $i (0 .. $#{ $d->{fixes} }) {
        my ($f, $path) = ($d->{fixes}[$i], "fixes[$i].");
        unknown_keys($f, $path, 'fix');
        my %q = (n => $i + 1);
        $q{id} = short(opt_text($f, 'id', $path), 24);
        $q{id} = 'F' . ($i + 1) unless length $q{id};
        $q{title} = oneline(opt_text($f, 'title', $path));
        $q{refs} = [ map { short($_, 24) } @{ opt_list($f, 'fixes', $path) } ];
        $q{files} = [ map { oneline($_) } @{ opt_list($f, 'files', $path) } ];
        $q{$_} = opt_text($f, $_, $path) for qw(change why_correct);
        $q{before} = opt_code($f, 'before', $path);
        $q{after} = opt_code($f, 'after', $path);
        $q{lang} = short(opt_text($f, 'code_language', $path), 20);
        note_warn("${path}before and after are the same code") if length $q{before} && $q{before} eq $q{after};
        my %seen;
        for my $ref (grep { !$seen{$_}++ } @{ $q{refs} }) {
            if ($PIDX{$ref}) { push @{ $P[ $PIDX{$ref} - 1 ]{fixed_by} }, { id => $q{id}, n => $q{n} } }
            else { note_warn("${path}fixes: '$ref' is not the id of a problem in this report") }
        }
        push @F, \%q;
    }
    $r{fixes} = \@F;

    my @V;
    for (@{ opt_objects($d, 'verification') }) {
        my ($v, $path) = @$_;
        unknown_keys($v, $path, 'verification');
        my %q = (check => opt_text($v, 'check', $path), detail => opt_text($v, 'detail', $path));
        unless (length $q{check}) { note_warn("${path}check: missing, row skipped"); next }
        ($q{persp}, $q{persp_raw}) = opt_enum($v, 'perspective', $path, 'perspective');
        ($q{result}, $q{result_raw}) = opt_enum($v, 'result', $path, 'result');
        if ($q{result} eq '' && $q{result_raw} eq '') {
            note_warn("${path}result: missing, shown as not run");
            $q{result} = 'not-run';
        }
        push @V, \%q;
    }
    $r{verification} = \@V;

    my %S = (before => {}, after => {}, note => '');
    if (defined $d->{scans}) {
        if (ref $d->{scans} ne 'HASH') { note_warn('scans: expected an object, ignored') }
        else {
            unknown_keys($d->{scans}, 'scans.', 'scans');
            for my $w (qw(before after)) {
                my $o = $d->{scans}{$w};
                next unless defined $o;
                if (ref $o ne 'HASH') { note_warn("scans.$w: expected an object, ignored"); next }
                unknown_keys($o, "scans.$w.", 'counts');
                $S{$w}{$_} = opt_count($o, $_, "scans.$w.") for qw(high warn info);
            }
            $S{note} = opt_text($d->{scans}, 'note', 'scans.');
        }
    }
    $r{scans} = \%S;

    my @A;
    for (@{ opt_objects($d, 'approvals') }) {
        my ($ap, $path) = @$_;
        unknown_keys($ap, $path, 'approval');
        my %q = map { $_ => opt_text($ap, $_, $path) } qw(action harm when);
        unless (length $q{action}) { note_warn("${path}action: missing, row skipped"); next }
        $q{when} = oneline($q{when});
        ($q{dec}, $q{dec_raw}) = opt_enum($ap, 'decision', $path, 'decision');
        push @A, \%q;
    }
    $r{approvals} = \@A;

    my @C;
    for (@{ opt_objects($d, 'files_changed') }) {
        my ($c, $path) = @$_;
        unknown_keys($c, $path, 'file');
        my %q = (path => oneline(opt_text($c, 'path', $path)));
        unless (length $q{path}) { note_warn("${path}path: missing, row skipped"); next }
        $q{$_} = opt_count($c, $_, $path) for qw(added removed);
        push @C, \%q;
    }
    $r{files_changed} = \@C;

    $r{remaining_risks} = opt_list($d, 'remaining_risks', '');
    $r{next_steps} = opt_list($d, 'next_steps', '');

    # A report must not say "fixed" when its own data says otherwise.
    if ($r{status} eq 'fixed') {
        my @open = map { $_->{id} } grep { !@{ $_->{fixed_by} } } @P;
        note_warn('status is fixed, but no fix lists problem(s) ' . join(', ', @open)) if @open;
        my $failed = grep { $_->{result} eq 'fail' } @V;
        note_warn("status is fixed, but $failed check(s) failed") if $failed;
    }
    note_warn('problems is empty: the report lists nothing that was wrong') unless @P;
    return \%r;
}

# ---------------------------------------------------------------- HTML helpers

sub t { my $k = shift; my $v = $T->{$k}; return defined $v ? $v : $k }
sub tf { my $k = shift; return sprintf(t($k), @_) }

sub esc {
    my $s = shift;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
}

sub inline {    # escaped text; `backticks` become <code>
    my $s = esc(shift);
    $s =~ s{`([^`\n]+)`}{<code>$1</code>}g;
    return $s;
}

sub block {    # paragraphs, line breaks and simple lists
    my $t = shift;
    my @out;
    for my $para (split /\n[ \t]*(?:\n[ \t]*)+/, $t) {
        $para =~ s/\A\n+|\n+\z//g;
        next unless $para =~ /\S/;
        my @lines = split /\n/, $para;
        if (!grep { !/\A[ \t]*[-*\x{2022}][ \t]+\S/ } @lines) {
            s/\A[ \t]*[-*\x{2022}][ \t]+// for @lines;
            push @out, '<ul class="tl">' . join('', map { '<li>' . inline($_) . '</li>' } @lines) . '</ul>';
        } elsif (!grep { !/\A[ \t]*\d{1,3}[.)][ \t]+\S/ } @lines) {
            my ($start) = $lines[0] =~ /(\d+)/;
            s/\A[ \t]*\d{1,3}[.)][ \t]+// for @lines;
            my $st = $start == 1 ? '' : qq{ start="$start"};
            push @out, qq{<ol class="tl"$st>} . join('', map { '<li>' . inline($_) . '</li>' } @lines) . '</ol>';
        } else {
            push @out, '<p>' . join('<br>', map { inline($_) } @lines) . '</p>';
        }
    }
    return join('', @out);
}

sub est {    # rough number of printed lines a text needs at about $w characters per line
    my ($s, $w) = @_;
    my $n = 0;
    $n += 1 + int(length($_) / $w) for split /\n/, $s;
    return $n;
}

sub section {    # heading, intro and items ({ html, long }); the heading stays with the first item
    my ($cls, $title, $intro, @items) = @_;
    $SECNO++;
    my $head = sprintf('<div class="sec-head"><h2><span class="n">%02d</span>%s</h2>%s</div>',
        $SECNO, esc($title), length($intro // '') ? '<p class="intro">' . esc($intro) . '</p>' : '');
    my $first = shift @items;
    my $html = !$first ? $head
             : $first->{long} ? $head . $first->{html}
             : qq{<div class="keep">$head$first->{html}</div>};
    $html .= "\n" . $_->{html} for @items;
    return qq{<section class="sec sec-$cls">\n$html\n</section>\n};
}

sub fields {    # rows: [label key, value, class, value-is-html]
    my @rows = grep { length $_->[1] } @_;
    return '' unless @rows;
    my $html = '<dl class="fields">';
    for (@rows) {
        my ($k, $v, $cls, $raw) = @$_;
        $html .= '<dt>' . esc(t($k)) . '</dt><dd' . ($cls ? qq{ class="$cls"} : '') . '>' . ($raw ? $v : block($v)) . '</dd>';
    }
    return "$html</dl>";
}

sub where_html {
    my $w = shift;
    return $w =~ /\s/ || $w =~ /`/ ? inline($w) : '<code>' . esc($w) . '</code>';
}

# ---------------------------------------------------------------- page parts

sub render {
    my $r = shift;
    my @parts = (band($r), summary_sec($r));
    push @parts, problems_sec($r) if @{ $r->{problems} };
    push @parts, fixes_sec($r) if @{ $r->{fixes} };
    push @parts, verification_sec($r) if @{ $r->{verification} };
    push @parts, scans_sec($r->{scans}) if has_scans($r->{scans});
    push @parts, approvals_sec($r) if @{ $r->{approvals} };
    push @parts, files_sec($r) if @{ $r->{files_changed} };
    push @parts, list_sec('risks', 's_risks', 'i_risks', 'ul', $r->{remaining_risks}) if @{ $r->{remaining_risks} };
    push @parts, list_sec('steps', 's_steps', '', 'ol', $r->{next_steps}) if @{ $r->{next_steps} };
    return join("\n", @parts);
}

sub band {
    my $r = shift;
    my ($cls, $label, $ico) = $r->{status} ne ''
        ? ("st-$r->{status}", t("st_$r->{status}"), { fixed => "\x{2713}", partial => "\x{25D0}", open => '!' }->{ $r->{status} })
        : ('st-other', $r->{status_raw}, "\x{2022}");
    my @meta;
    for my $k (qw(project branch commit date prepared_by requested_by)) {
        next unless length $r->{$k};
        my $v = $k eq 'branch' || $k eq 'commit' ? '<code>' . esc($r->{$k}) . '</code>' : esc($r->{$k});
        push @meta, '<div><dt>' . esc(t("m_$k")) . "</dt><dd>$v</dd></div>";
    }
    return '<header class="band"><div class="band-top"><span class="eyebrow">' . esc(t('eyebrow')) . '</span>'
        . qq{<span class="status $cls"><span class="ico" aria-hidden="true">$ico</span>} . esc($label) . '</span></div>'
        . '<h1>' . inline($r->{title}) . '</h1>'
        . (@meta ? '<dl class="meta">' . join('', @meta) . '</dl>' : '') . "</header>\n";
}

sub summary_sec {
    my $r = shift;
    my $html = '<div class="summary">' . block($r->{summary}) . '</div>' . tiles($r);
    return section('summary', t('s_summary'), '', { html => $html, long => est($r->{summary}, 90) > 30 });
}

sub tile {
    my ($tone, $num, $small, $label, $sub) = @_;
    return qq{<div class="tile tone-$tone"><div class="tn">} . esc($num) . ($small ne '' ? '<small>' . esc($small) . '</small>' : '')
        . '</div><div class="tl">' . esc($label) . '</div>' . ($sub ne '' ? qq{<div class="ts">$sub</div>} : '') . '</div>';
}

sub tiles {
    my $r = shift;
    my ($P, $F, $V, $A, $S) = @$r{qw(problems fixes verification approvals scans)};
    my @t;
    if (@$P) {
        my %c;
        $c{ $_->{sev} }++ for grep { $_->{sev} ne '' } @$P;
        my $tone = $c{critical} || $c{high} ? 'bad' : $c{medium} ? 'warn' : 'info';
        my $sub = join('', map { qq{<span class="mini"><i class="sw sev-$_"></i>} . esc(tf('n_sev', $c{$_}, lc t("sev_$_"))) . '</span>' }
                           grep { $c{$_} } @SEV);
        push @t, tile($tone, scalar @$P, '', t('t_problems'), $sub);
    }
    if (@$F || @$P) {
        my $covered = grep { @{ $_->{fixed_by} } } @$P;
        my $tone = !@$P || $covered == @$P ? 'ok' : 'warn';
        push @t, tile($tone, scalar @$F, '', t('t_fixes'), @$P ? esc(tf('covers', $covered, scalar @$P)) : '');
    }
    if (@$V) {
        my %c;
        $c{ $_->{result} || 'other' }++ for @$V;
        my $tone = $c{fail} ? 'bad' : $c{partial} || $c{'not-run'} || $c{other} ? 'warn' : 'ok';
        my @s;
        push @s, tf('n_failed', $c{fail}) if $c{fail};
        push @s, tf('n_partial', $c{partial}) if $c{partial};
        push @s, tf('n_not_run', $c{'not-run'}) if $c{'not-run'};
        push @t, tile($tone, $c{pass} || 0, ' / ' . scalar(@$V), t('t_checks'), esc(join(" \x{b7} ", @s)));
    }
    if (@$A) {
        my %c;
        $c{ $_->{dec} || 'other' }++ for @$A;
        my @s;
        push @s, tf('n_approved', $c{approved}) if $c{approved};
        push @s, tf('n_safer', $c{'safer-option'}) if $c{'safer-option'};
        push @s, tf('n_declined', $c{declined}) if $c{declined};
        push @t, tile('info', scalar @$A, '', t('t_approvals'), esc(join(" \x{b7} ", @s)));
    }
    my ($hb, $ha) = ($S->{before}{high}, $S->{after}{high});
    if (defined $hb || defined $ha) {
        my $num = defined $hb && defined $ha ? "$hb \x{2192} $ha" : defined $ha ? $ha : $hb;
        my $tone = defined $ha ? ($ha ? 'bad' : 'ok') : 'info';
        push @t, tile($tone, $num, '', t('t_scan'), defined $hb && defined $ha ? esc(t('before_after')) : '');
    }
    return @t ? '<p class="glance">' . esc(t('glance')) . '</p><div class="tiles">' . join('', @t) . '</div>' : '';
}

sub problems_sec {
    my $r = shift;
    my @cards;
    for my $p (@{ $r->{problems} }) {
        my $sev = $p->{sev} ne '' ? $p->{sev} : 'other';
        my $badge = $p->{sev} ne '' ? qq{<span class="badge sev-$sev">} . esc(t("sev_$sev")) . '</span>'
                  : $p->{sev_raw} ne '' ? '<span class="badge sev-other">' . esc($p->{sev_raw}) . '</span>' : '';
        my @facts;
        push @facts, '<span><span class="k">' . esc(t('f_where')) . '</span>' . where_html($p->{where}) . '</span>' if length $p->{where};
        if ($p->{by} ne '' || $p->{by_raw} ne '') {
            my $by = $p->{by} ne '' ? t("by_$p->{by}") : $p->{by_raw};
            push @facts, '<span><span class="k">' . esc(t('f_found_by')) . '</span><span class="chip">' . esc($by) . '</span></span>';
        }
        if (@{ $p->{fixed_by} }) {
            push @facts, '<span><span class="k">' . esc(t('f_fixed_by')) . '</span>'
                . join(' ', map { qq{<a class="chip ok" href="#f-$_->{n}">} . esc($_->{id}) . '</a>' } @{ $p->{fixed_by} }) . '</span>';
        } else {
            push @facts, '<span class="chip warn">' . esc(t('no_fix')) . '</span>';
        }
        my $html = qq{<article class="card prob sev-$sev" id="p-$p->{n}"><div class="card-head">$badge<span class="id">} . esc($p->{id})
            . '</span><h3>' . inline($p->{title}) . '</h3></div>'
            . '<div class="facts">' . join('', @facts) . '</div>'
            . fields([ 'f_symptom', $p->{symptom} ], [ 'f_root_cause', $p->{root_cause}, 'cause' ],
                     [ 'f_impact', $p->{impact} ], [ 'f_evidence', $p->{evidence}, 'evidence' ])
            . '</article>';
        my $lines = 4;
        $lines += est($p->{$_}, 78) for qw(symptom root_cause impact evidence);
        push @cards, { html => $html, long => $lines > 50 };
    }
    return section('problems', t('s_problems'), t('i_problems'), @cards);
}

sub fixes_sec {
    my $r = shift;
    my ($P, @cards) = ($r->{problems});
    for my $f (@{ $r->{fixes} }) {
        my $refs = '';
        if (@{ $f->{refs} }) {
            $refs = '<div class="refs">' . join('', map {
                my $pi = $PIDX{$_};
                $pi ? qq{<a class="ref" href="#p-$pi"><span class="id">} . esc($_) . '</span>' . inline($P->[ $pi - 1 ]{title}) . '</a>'
                    : '<span class="ref"><span class="id">' . esc($_) . '</span></span>';
            } @{ $f->{refs} }) . '</div>';
        }
        my $files = @{ $f->{files} } ? '<div class="paths">' . join('', map { '<code>' . esc($_) . '</code>' } @{ $f->{files} }) . '</div>' : '';
        my ($code, $code_lines) = compare($f);
        my $html = qq{<article class="card fix" id="f-$f->{n}"><div class="card-head"><span class="id">} . esc($f->{id})
            . '</span><h3>' . inline($f->{title}) . '</h3></div>'
            . fields([ 'f_fixes', $refs, '', 1 ], [ 'f_change', $f->{change} ], [ 'f_why', $f->{why_correct} ], [ 'f_files', $files, '', 1 ])
            . $code . '</article>';
        my $lines = 4 + @{ $f->{refs} } + est($f->{change}, 78) + est($f->{why_correct}, 78) + $code_lines;
        push @cards, { html => $html, long => $lines > 50 };
    }
    return section('fixes', t('s_fixes'), t('i_fixes'), @cards);
}

sub compare {    # before/after code -> (html, estimated printed lines)
    my $f = shift;
    my @b = length $f->{before} ? split(/\n/, $f->{before}, -1) : ();
    my @a = length $f->{after} ? split(/\n/, $f->{after}, -1) : ();
    return ('', 0) unless @b || @a;
    dedent(\@b);
    dedent(\@a);
    my ($kb, $ka) = (@b && @a) ? line_diff(\@b, \@a) : ();
    my $width = 0;
    for (@b, @a) { (my $x = $_) =~ s/\t/    /g; $width = length $x if length $x > $width }
    # Two columns of code fit about 56 characters per line on A4; wider code is stacked.
    my $side = @b && @a && $width <= 56;
    my $lang = length $f->{lang} ? '<span class="lang">' . esc($f->{lang}) . '</span>' : '';
    my $html = '<div class="compare ' . ($side ? 'side' : 'stack') . '">'
        . (@b ? pane('before', \@b, $kb, $lang) : '') . (@a ? pane('after', \@a, $ka, $lang) : '') . '</div>';
    my $w = $side ? 54 : 108;
    my ($nb, $na) = (est(join("\n", @b), $w), est(join("\n", @a), $w));
    return ($html, 2 + ($side ? ($nb > $na ? $nb : $na) : $nb + $na + 2));
}

sub pane {
    my ($kind, $lines, $keep, $lang) = @_;
    my $mark = $kind eq 'before' ? 'del' : 'add';
    my $sym = $kind eq 'before' ? "\x{2212}" : '+';
    my $body = '';
    for my $i (0 .. $#$lines) {
        my $cls = $keep && !$keep->[$i] ? "ln $mark" : 'ln';
        # Block-level lines with no newline between them: a newline inside <pre> would add a blank line.
        $body .= qq{<span class="$cls">} . (length $lines->[$i] ? esc($lines->[$i]) : ' ') . '</span>';
    }
    return qq{<figure class="code $kind"><figcaption><span>$sym } . esc(t($kind)) . "</span>$lang</figcaption><pre><code>$body</code></pre></figure>";
}

sub dedent {    # remove the indentation all non-blank lines share
    my $l = shift;
    my $pre;
    for (@$l) {
        next unless /\S/;
        my ($ws) = /\A([ \t]*)/;
        if (!defined $pre) { $pre = $ws; next }
        chop $pre while length $pre && index($ws, $pre) != 0;
        last unless length $pre;
    }
    return unless defined $pre && length $pre;
    $_ = /\S/ ? substr($_, length $pre) : '' for @$l;
}

sub line_diff {    # longest common subsequence of lines -> keep-flags for each side
    my ($x, $y) = @_;
    my ($n, $m) = (scalar @$x, scalar @$y);
    return () if $n * $m > 160_000;
    my @xs = map { (my $s = $_) =~ s/\s+\z//; $s } @$x;
    my @ys = map { (my $s = $_) =~ s/\s+\z//; $s } @$y;
    my @L = map { [ (0) x ($m + 1) ] } 0 .. $n;
    for my $i (reverse 0 .. $n - 1) {
        for my $j (reverse 0 .. $m - 1) {
            $L[$i][$j] = $xs[$i] eq $ys[$j] ? $L[$i + 1][$j + 1] + 1
                       : $L[$i + 1][$j] >= $L[$i][$j + 1] ? $L[$i + 1][$j] : $L[$i][$j + 1];
        }
    }
    return () unless $L[0][0];
    my (@kx, @ky);
    my ($i, $j) = (0, 0);
    while ($i < $n && $j < $m) {
        if ($xs[$i] eq $ys[$j]) { $kx[$i++] = 1; $ky[$j++] = 1 }
        elsif ($L[$i + 1][$j] >= $L[$i][$j + 1]) { $i++ }
        else { $j++ }
    }
    return (\@kx, \@ky);
}

sub verification_sec {
    my $r = shift;
    my $V = $r->{verification};
    my %c;
    $c{ $_->{persp} || 'other' }++ for @$V;
    my $rows = '';
    for my $v (@$V) {
        my $persp = $v->{persp} ne '' ? qq{<span class="persp p-$v->{persp}">} . esc(t("p_$v->{persp}")) . '</span>'
                  : $v->{persp_raw} ne '' ? '<span class="persp p-other">' . esc($v->{persp_raw}) . '</span>' : '';
        my $res = $v->{result} ne ''
            ? qq{<span class="pill r-$v->{result}"><span aria-hidden="true">}
              . { pass => "\x{2713}", fail => "\x{2717}", partial => "\x{25D0}", 'not-run' => "\x{25CB}" }->{ $v->{result} }
              . '</span>' . esc(t("r_$v->{result}")) . '</span>'
            : '<span class="pill r-other">' . esc($v->{result_raw}) . '</span>';
        $rows .= '<tr><td>' . block($v->{check}) . "</td><td>$persp</td><td>$res</td><td>" . block($v->{detail}) . "</td></tr>\n";
    }
    my $html = '<p class="vsum">' . esc(tf('v_summary', scalar @$V, $c{ai} || 0, $c{human} || 0, $c{both} || 0)) . '</p>'
        . '<table class="t"><colgroup><col class="w-check"><col class="w-persp"><col class="w-result"><col></colgroup><thead><tr>'
        . join('', map { '<th>' . esc(t($_)) . '</th>' } qw(h_check h_perspective h_result h_detail))
        . "</tr></thead><tbody>\n$rows</tbody></table>";
    return section('verification', t('s_verification'), t('i_verification'), { html => $html, long => @$V > 6 });
}

sub has_scans {
    my $S = shift;
    return 1 if length $S->{note};
    for my $w (qw(before after)) { return 1 if grep { defined } values %{ $S->{$w} } }
    return 0;
}

sub scans_sec {
    my $S = shift;
    my @lv = grep { defined $S->{before}{$_} || defined $S->{after}{$_} } qw(high warn info);
    my $max = 1;
    for my $w (qw(before after)) {
        for (@lv) { my $v = $S->{$w}{$_}; $max = $v if defined $v && $v > $max }
    }
    my $rows = '';
    for my $l (@lv) {
        my ($nb, $na) = ($S->{before}{$l}, $S->{after}{$l});
        my $bars = '';
        for ([ 'b', 'before', $nb ], [ 'a', 'after', $na ]) {
            my ($c, $k, $v) = @$_;
            next unless defined $v;
            my $pct = sprintf('%.1f', 100 * $v / $max);
            $bars .= qq{<div class="bar $c"><span>} . esc(t($k)) . qq{</span><span class="track"><span class="fill" style="width:$pct%"></span></span><span class="cnt">$v</span></div>};
        }
        my $delta = '<span class="delta"></span>';
        if (defined $nb && defined $na) {
            my $d = $na - $nb;
            $delta = $d < 0 ? qq{<span class="delta down">\x{2212}} . (-$d) . '</span>'
                   : $d > 0 ? qq{<span class="delta up">+$d</span>} : '<span class="delta same">=</span>';
        }
        $rows .= qq{<div class="scan-row lv-$l"><span class="scan-lvl">} . esc(t("lv_$l")) . qq{</span><div class="bars">$bars</div>$delta</div>};
    }
    my $html = '<div class="scan">' . $rows . (length $S->{note} ? '<div class="scan-note">' . block($S->{note}) . '</div>' : '') . '</div>';
    return section('scans', t('s_scans'), t('i_scans'), { html => $html, long => 0 });
}

sub approvals_sec {
    my $r = shift;
    my $A = $r->{approvals};
    my $rows = '';
    for my $ap (@$A) {
        my $dec = $ap->{dec} ne ''
            ? qq{<span class="pill d-$ap->{dec}"><span aria-hidden="true">}
              . { approved => "\x{2713}", declined => "\x{2717}", 'safer-option' => "\x{21AA}" }->{ $ap->{dec} }
              . '</span>' . esc(t("d_$ap->{dec}")) . '</span>'
            : $ap->{dec_raw} ne '' ? '<span class="pill d-other">' . esc($ap->{dec_raw}) . '</span>' : '';
        $rows .= '<tr><td>' . block($ap->{action}) . '</td><td>' . block($ap->{harm}) . "</td><td>$dec</td><td>" . esc($ap->{when}) . "</td></tr>\n";
    }
    my $html = '<table class="t"><colgroup><col class="w-action"><col><col class="w-decision"><col class="w-when"></colgroup><thead><tr>'
        . join('', map { '<th>' . esc(t($_)) . '</th>' } qw(h_action h_harm h_decision h_when))
        . "</tr></thead><tbody>\n$rows</tbody></table>";
    return section('approvals', t('s_approvals'), t('i_approvals'), { html => $html, long => @$A > 6 });
}

sub files_sec {
    my $r = shift;
    my $C = $r->{files_changed};
    my ($max, $ta, $tr, $any) = (1, 0, 0, 0);
    for (@$C) {
        my $s = ($_->{added} // 0) + ($_->{removed} // 0);
        $max = $s if $s > $max;
        $ta += $_->{added} // 0;
        $tr += $_->{removed} // 0;
        $any = 1 if defined $_->{added} || defined $_->{removed};
    }
    my $rows = '';
    for my $c (@$C) {
        my ($ad, $rm) = ($c->{added}, $c->{removed});
        my $stat = '';
        if (defined $ad || defined $rm) {
            my ($pa, $pr) = map { sprintf('%.1f', 100 * ($_ // 0) / $max) } $ad, $rm;
            $stat = qq{<span class="dstat"><span class="a" style="width:$pa%"></span><span class="r" style="width:$pr%"></span></span>};
        }
        $rows .= '<tr><td><code class="path">' . esc($c->{path}) . '</code></td>'
            . '<td class="num add">' . (defined $ad ? "+$ad" : "\x{2013}") . '</td>'
            . '<td class="num del">' . (defined $rm ? "\x{2212}$rm" : "\x{2013}") . "</td><td>$stat</td></tr>\n";
    }
    my $foot = @$C > 1 && $any
        ? '<tfoot><tr><td>' . esc(t('total')) . qq{</td><td class="num add">+$ta</td><td class="num del">\x{2212}$tr</td><td></td></tr></tfoot>} : '';
    my $html = '<table class="t"><colgroup><col><col class="w-count"><col class="w-count"><col class="w-stat"></colgroup><thead><tr>'
        . '<th>' . esc(t('h_file')) . '</th><th class="num">' . esc(t('h_added')) . '</th><th class="num">' . esc(t('h_removed'))
        . '</th><th>' . esc(t('h_stat')) . "</th></tr></thead><tbody>\n$rows</tbody>$foot</table>";
    return section('files', t('s_files'), '', { html => $html, long => @$C > 10 });
}

sub list_sec {
    my ($cls, $title, $intro, $tag, $items) = @_;
    my $html = qq{<$tag class="$cls">} . join('', map { '<li>' . block($_) . '</li>' } @$items) . "</$tag>";
    my $lines = 0;
    $lines += est($_, 85) + 1 for @$items;
    return section($cls, t($title), $intro ? t($intro) : '', { html => $html, long => $lines > 30 });
}
