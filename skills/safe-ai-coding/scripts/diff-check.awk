# diff-check.awk - rule engine behind diff-check.sh (safe-ai-coding skill).
#
# Input files, in this order:
#   EXTRA  findings made by the shell script (TSV: severity, file, line, message, text)
#   NS     name-status list of changed files (TSV: status, path[, new path])
#   diff   unified diff with -U0 (untracked files appear as new files)
# Variables: RULES (validated project rules file or ""), LARAVEL, HASTESTS (1/0),
#   SELF (path prefix to skip), FORMAT (text|tsv), FAILON (high|warn), ALL (1 = no cap).
# Run it under LC_ALL=C: the hidden-unicode patterns match raw UTF-8 bytes.

BEGIN {
    HIDH = "\342\200[\252-\256]|\342\201[\246-\251]|\363\240[\200\201][\200-\277]"
    HIDW = "\342\200\213|\342\201[\240-\244]|.\357\273\277"
    split("\342\200\252 \342\200\253 \342\200\254 \342\200\255 \342\200\256 \342\201\246 \342\201\247 \342\201\250 \342\201\251 \342\200\213 \342\201\240 \342\201\241 \342\201\242 \342\201\243 \342\201\244 \357\273\277", HB, " ")
    split("U+202A U+202B U+202C U+202D U+202E U+2066 U+2067 U+2068 U+2069 U+200B U+2060 U+2061 U+2062 U+2063 U+2064 U+FEFF", HN, " ")
    ELL = "\342\200\246"
    CAP = (ALL == 1 ? 0 : 60)
    nr = 0
    if (RULES != "") {
        while ((getline line < RULES) > 0) {
            sub(/\r$/, "", line)
            if (line ~ /^[ \t]*(#|$)/ || line ~ /^BASE\t/) continue
            c = split(line, a, "\t")
            if (c < 4) continue
            nr++
            RKIND[nr] = (a[1] ~ /^FILE:/ ? "file" : (a[1] ~ /^CHANGE:/ ? "change" : "line"))
            RSEV[nr] = a[1]; sub(/^(FILE|CHANGE):/, "", RSEV[nr])
            RP[nr] = a[2]; RL[nr] = a[3]; RM[nr] = "[project rule] " a[4]; RU[nr] = (c >= 5 ? a[5] : "")
        }
        close(RULES)
    }
}

{ sub(/\r$/, "") }

FILENAME == EXTRA { split($0, a, "\t"); out(a[1], a[2], a[3] + 0, a[4], a[5]); next }
FILENAME == NS    { namestatus($0); next }

/^diff --git / { hdr = 1; newf = 0; oldf = ""; f = ""; next }
hdr && /^new file mode/ { newf = 1; next }
hdr && /^--- / { oldf = substr($0, 5); gsub(/^"|"$/, "", oldf); sub(/^a\//, "", oldf); next }
hdr && /^\+\+\+ / {
    f = substr($0, 5); gsub(/^"|"$/, "", f); sub(/^b\//, "", f)
    if (f == "/dev/null") f = ""
    skip = (SELF != "" && (index(f, SELF) == 1 || (f == "" && index(oldf, SELF) == 1)))
    K = kind(f != "" ? f : oldf)
    if (f != "") isnew[f] = newf
    next
}
/^Binary files / {
    b = $0; sub(/^Binary files (a\/[^ ]+|\/dev\/null) and b\//, "", b); sub(/ differ$/, "", b)
    if (b !~ /^\/dev\/null/ && !(SELF != "" && index(b, SELF) == 1)) out("INFO", b, 0, "binary file in the change: it cannot be reviewed as text", "")
    next
}
/^@@ / { hdr = 0; s = $0; sub(/^@@ -[0-9,]+ \+/, "", s); sub(/[^0-9].*$/, "", s); ln = s + 0; next }
hdr { next }
/^\+/ { if (f != "" && !skip) added(f, ln, substr($0, 2)); ln++; next }
/^-/  { if (!skip) removed(f != "" ? f : oldf, substr($0, 2)); next }

# ---------------------------------------------------------------- helpers

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function clean(s) { gsub(/\t/, " ", s); gsub(/[\001-\010\012-\037\177]/, "?", s); return s }

function out(sev, f, l, msg, txt,    key) {
    if (sev !~ /^(HIGH|WARN|INFO)$/) return
    key = sev SUBSEP f SUBSEP l SUBSEP msg
    if (key in seen) return
    seen[key] = 1
    nf_++; S[nf_] = sev; F[nf_] = clean(f); L[nf_] = l; M[nf_] = clean(msg); T[nf_] = clean(trim(txt))
    cnt[sev]++
}

function visible(t,    i) {
    for (i = 1; i in HB; i++) gsub(HB[i], "<" HN[i] ">", t)
    gsub(/\363\240[\200\201][\200-\277]/, "<TAG>", t)
    return t
}

function mask(t,    res, s, tok) {
    s = t; res = ""
    while (match(s, /[A-Za-z0-9_\/+=-]+/)) {
        tok = substr(s, RSTART, RLENGTH)
        if (length(tok) >= 8) tok = substr(tok, 1, 4) "****"
        res = res substr(s, 1, RSTART - 1) tok
        s = substr(s, RSTART + RLENGTH)
    }
    return res s
}

function kind(f,    lf) {
    lf = tolower(f)
    if (isagent(f)) return "agent"
    if (lf ~ /\.(md|markdown|mdx|txt|rst|adoc)$/) return "doc"
    if (lf ~ /\.blade\.php$/) return "blade"
    if (lf ~ /\.(php|phtml)$/) return "php"
    if (lf ~ /\.(js|mjs|cjs|jsx|ts|tsx|vue|svelte)$/) return "js"
    if (lf ~ /\.py$/) return "py"
    if (lf ~ /\.(rb|rake)$/) return "rb"
    if (lf ~ /\.(java|kt|kts|scala|groovy)$/) return "jvm"
    if (lf ~ /\.cs$/) return "cs"
    if (lf ~ /\.go$/) return "go"
    if (lf ~ /\.sql$/) return "sql"
    if (lf ~ /\.(sh|bash|zsh|ps1|psm1|bat|cmd)$/) return "shell"
    if (lf ~ /\.(html?|twig|jinja2?|j2|erb|ejs|hbs|mustache|cshtml|razor|jsp)$/) return "tpl"
    if (lf ~ /\.(json|ya?ml|toml|ini|xml|conf|cfg|properties|env|lock|rules|tf|hcl)$/ || lf ~ /(^|\/)(\.env[^\/]*|\.npmrc|\.yarnrc|\.gitignore|requirements[^\/]*\.txt|pip\.(conf|ini)|gemfile|go\.mod)$/) return "config"
    if (lf ~ /(^|\/)(dockerfile|makefile|procfile|jenkinsfile|vagrantfile)$/) return "shell"
    return "other"
}

function iscode(k) { return (k == "php" || k == "blade" || k == "js" || k == "py" || k == "rb" || k == "jvm" || k == "cs" || k == "go" || k == "sql" || k == "tpl") }

function isagent(p,    lp) {
    lp = tolower(p)
    return (lp ~ /(^|\/)(claude\.md|claude\.local\.md|agents?\.md|gemini\.md|\.cursorrules|\.clinerules|\.windsurfrules|\.mcp\.json|mcp\.json)$/ ||
            lp ~ /(^|\/)\.aider/ ||
            lp ~ /(^|\/)\.(claude|cursor|gemini|windsurf|continue|roo|kiro|codex)\// ||
            lp ~ /(^|\/)\.github\/(copilot-instructions\.md|instructions\/|prompts\/|chatmodes\/)/ ||
            lp ~ /(^|\/)\.vscode\/(tasks|settings|mcp)\.json$/)
}

function ismig(p,    lp) {
    lp = tolower(p)
    return (lp ~ /(^|\/)(database\/migrations|db\/migrate|db\/migrations|migrations|alembic\/versions|prisma\/migrations)\// ||
            lp ~ /(^|\/)(flyway|liquibase)\//)
}

function istest(f,    lf) {
    lf = tolower(f)
    return (lf ~ /(^|\/)(tests?|__tests__|specs?)\// || f ~ /Tests?\.(php|java|kt|cs|scala)$/ ||
            lf ~ /(_test|_spec|\.test|\.spec)\.[a-z]+$/ || lf ~ /(^|\/)test_[^\/]*\.py$/)
}

function hasreq(t) {
    return (t ~ /[$]request([^a-zA-Z0-9_]|$)|[$]_(GET|POST|REQUEST|COOKIE|FILES)|(^|[^a-zA-Z0-9_>])request[(][)]?|Input::|req[.](body|query|params|headers|cookies)|request[.](GET|POST|args|form|values|json|data|query_params|params|body)|[$]params([^a-zA-Z0-9_]|$)|params[[]|getParameter[(]|FormValue[(]|URL[.]Query[(]|@RequestParam|@PathVariable|[[]From(Query|Body|Route|Form)/)
}

function isroutedef(t) {
    return (t ~ /Route::(get|post|put|patch|delete|any|match|resource|apiResource|group|prefix)|@(Get|Post|Put|Patch|Delete|Request)Mapping|(app|router)[.](get|post|put|patch|delete|use)[(]|urlpatterns|(^|[^a-zA-Z])path[(]["']/)
}

# The URI (first quoted literal) identifies a route across a change; otherwise the trimmed line.
function routekey(t,    s) {
    if (match(t, /[(][ \t]*\[?[ \t]*["'][^"']*["']/)) { s = substr(t, RSTART, RLENGTH); sub(/^[^"']*["']/, "", s); sub(/["']$/, "", s); return s }
    return trim(t)
}

function isauth(t,    lt) {
    lt = tolower(t)
    return (lt ~ /permission:|->middleware[(]|middleware[(][[]|["']auth(:[a-z]+)?["']|can:|@can|->can[(]|->authorize[(]|gate::|@login_required|@permission_required|loginrequired|permissionrequired|[[]authorize|@preauthorize|@secured|@rolesallowed|isauthenticated|requireauth|ensureauth|verifytoken|verify_jwt|jwt_required|csrf|hmac|whitelist|throttle|ratelimit|rate_limit|abort[(][ \t]*403|abort_unless|abort_if|forbidden|unauthori[sz]ed/)
}

# ---------------------------------------------------------------- per file

function namestatus(line,    a, c, st, p, lp) {
    c = split(line, a, "\t"); st = substr(a[1], 1, 1); p = (c >= 3 ? a[3] : a[2])
    if (p == "" || (SELF != "" && index(p, SELF) == 1)) return
    lp = tolower(p)
    nfiles++; changed[p] = st
    if (st == "D") { ndel++; if (ndel <= 10) dels[ndel] = p }
    if (st == "R") out("INFO", p, 0, "renamed from " a[2] ": every reference to the old path must change too", "")
    if (isagent(p)) out("WARN", p, 0, "agent instruction/config file changed: agents obey it automatically, so its owner must review it before merge", "")
    if (st != "D" && lp ~ /(^|\/)\.env(\.[a-z0-9_-]+)?$/ && lp !~ /\.(example|sample|dist|template|defaults?)$/)
        out("HIGH", p, 0, "environment file in the change: it usually holds passwords and keys", "")
    if (st != "D" && (lp ~ /\.(pem|key|p12|pfx|jks|keystore|ppk|kdbx|ovpn)$/ || lp ~ /(^|\/)id_(rsa|dsa|ecdsa|ed25519)$/ ||
        lp ~ /(^|\/)(credentials|service-account[^\/]*|client_secret[^\/]*)\.json$/ || lp ~ /(^|\/)(\.pypirc|\.netrc|\.htpasswd|\.git-credentials)$/))
        out("HIGH", p, 0, "key or credential file in the change", "")
    if (lp ~ /(^|\/)(package\.json|composer\.json|requirements[^\/]*\.txt|pyproject\.toml|pipfile|setup\.py|setup\.cfg|gemfile|go\.mod|cargo\.toml|pom\.xml|build\.gradle(\.kts)?|packages\.config)$/ || lp ~ /\.csproj$/)
        out("WARN", p, 0, "dependencies changed: check each new package exists under that exact name, is the intended one (not a look-alike), is pinned, and has an acceptable licence", "")
    if (lp ~ /(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|poetry\.lock|pipfile\.lock|gemfile\.lock|cargo\.lock|go\.sum)$/)
        out("INFO", p, 0, "lock file changed: confirm it matches an intended dependency change", "")
    if (lp ~ /(^|\/)(\.npmrc|\.yarnrc(\.yml)?|pip\.(conf|ini)|\.pip\/|nuget\.config)$/)
        out("WARN", p, 0, "package registry configuration changed: packages may now come from somewhere else", "")
    if (st == "A" && !ismig(p) && (lp ~ /\.(dump|bak|sqlite3?|db|mdb|csv|xlsx?)$/ ||
        (lp ~ /\.sql(\.gz)?$/ && lp ~ /(dump|backup|bak|export|data|prod|live|full)[^\/]*$/)))
        out("WARN", p, 0, "data file added: it may contain real personal data", "")
    if (lp ~ /(^|\/)(\.github\/workflows\/|\.gitlab-ci\.yml$|jenkinsfile$|azure-pipelines\.yml$|bitbucket-pipelines\.yml$|\.circleci\/)/)
        out("WARN", p, 0, "CI/CD pipeline changed: it runs with deploy credentials", "")
    if (lp ~ /(^|\/)(\.husky\/|\.githooks\/|lefthook\.ya?ml$|\.pre-commit-config\.yaml$|\.envrc$|\.devcontainer\/|\.gitattributes$|\.gitmodules$)/)
        out("WARN", p, 0, "auto-run hook or git behaviour file changed: it acts on every developer's machine", "")
    if (st == "M" && ismig(p))
        out("WARN", p, 0, "existing migration edited: databases that already ran it will not run it again; add a new migration instead", "")
    if (lp ~ /(auth|login|permission|polic(y|ies)|guard|middleware|csrf|session|password|token|crypt|security|acl|role)/ && !isagent(p) && lp !~ /\.(md|txt)$/)
        out("INFO", p, 0, "security-sensitive file: review this change line by line", "")
    if (iscode(kind(p)) && !istest(p) && st != "D") codechanged = 1
    if (istest(p)) testchanged = 1
}

# ---------------------------------------------------------------- per line

function added(f, l, t,    lt, k, pa, pl, cmt) {
    k = K; lt = tolower(t)
    pa = prevadd[f]; pl = prevln[f]; prevadd[f] = t; prevln[f] = l
    nadd++; addedtext[trim(t)] = 1
    if (isroutedef(t)) addedroute[routekey(t)] = 1

    if (t ~ HIDH) out("HIGH", f, l, "hidden bidi/tag unicode: what a reviewer sees differs from what runs or what an agent reads", visible(t))
    else if (t ~ HIDW) out("WARN", f, l, "invisible unicode (zero-width, word joiner or stray BOM)", visible(t))
    if (t ~ /^(<<<<<<<|>>>>>>>)( |$)/ || (k != "doc" && t ~ /^=======$/))
        out("HIGH", f, l, "merge conflict marker left in the file", t)
    secrets(f, l, t, lt)
    pii(f, l, t)
    steering(f, l, t, lt)
    if (k == "agent" || k == "doc") return
    projectrules(f, l, t)

    if (f ~ /(^|\/)\.gitignore$/ && lt ~ /^!.*(\.env|\.pem|\.key|id_rsa|credential|secret)/)
        out("HIGH", f, l, "secret file pattern un-ignored: it can now be committed", t)
    if (isauth(t)) authadd[f]++
    if (istest(f)) testline(f, l, t, 1)
    if (ismig(f)) migline(f, l, t)
    commands(f, l, t, lt)
    manifest(f, l, t, lt)
    cfgsec(f, l, t, lt)
    cloudsec(f, l, t, lt, k)
    if (k == "config") { configline(f, l, t, lt); return }
    if (k == "other" || k == "shell") return
    cmt = (t ~ /^[ \t]*(\/\/|#|\*|\/\*|<!--|\{\{--|--[ \t])/)
    leftovers(f, l, t, lt, k, cmt)
    if (cmt) return
    code(f, l, t, lt, k, pa, pl)
}

function removed(f, t,    lt) {
    if (f == "") return
    lt = tolower(t)
    # Removed protections are judged in END, once every added line is known: a line
    # that reappears elsewhere in the change was moved, not removed.
    if (K != "doc" && K != "agent") {
        if (isauth(t)) { nra++; RAF[nra] = f; RAT[nra] = trim(t) }
        if (isroutedef(t)) { nrr++; RRT[nrr] = routekey(t) }
    }
    if (istest(f)) testline(f, 0, t, 0)
    if (f ~ /(^|\/)\.gitignore$/ && lt ~ /\.env|\.pem|\.key|id_rsa|credential|secret|\.p12|\.pfx|\.sqlite|\.sql/ && lt !~ /^[ \t]*#/)
        out("HIGH", f, 0, "ignore rule removed for '" trim(t) "': that file can now be committed", "")
}

function secrets(f, l, t, lt,    v, lf) {
    lf = tolower(f)
    if (lf ~ /\.(example|sample|dist|template)$/ || lf ~ /(^|\/)(tests?|specs?|__tests__|fixtures?)\//) return
    if (t ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) { out("HIGH", f, l, "private key in the change", "-----BEGIN ... PRIVATE KEY-----"); return }
    if (match(t, /(AKIA|ASIA)[A-Z0-9]+/) && RLENGTH >= 20) { out("HIGH", f, l, "AWS access key id", mask(t)); return }
    if (match(t, /gh[pousr]_[A-Za-z0-9]+/) && RLENGTH >= 40) { out("HIGH", f, l, "GitHub token", mask(t)); return }
    if (match(t, /github_pat_[A-Za-z0-9_]+/) && RLENGTH >= 40) { out("HIGH", f, l, "GitHub token", mask(t)); return }
    if (match(t, /glpat-[A-Za-z0-9_-]+/) && RLENGTH >= 24) { out("HIGH", f, l, "GitLab token", mask(t)); return }
    if (match(t, /xox[abprs]-[A-Za-z0-9-]+/) && RLENGTH >= 15) { out("HIGH", f, l, "Slack token", mask(t)); return }
    if (match(t, /AIza[0-9A-Za-z_-]+/) && RLENGTH >= 39) { out("HIGH", f, l, "Google API key", mask(t)); return }
    if (match(t, /(sk|rk)_live_[0-9A-Za-z]+/) && RLENGTH >= 20) { out("HIGH", f, l, "Stripe live key", mask(t)); return }
    if (match(t, /sk-(proj-|ant-|or-v1-)?[A-Za-z0-9_-]+/) && RLENGTH >= 40) { out("HIGH", f, l, "AI provider or API secret key", mask(t)); return }
    if (match(t, /(hf_|gsk_|r8_|xai-)[A-Za-z0-9]+/) && RLENGTH >= 30) { out("HIGH", f, l, "AI provider token (Hugging Face, Groq, Replicate or xAI)", mask(t)); return }
    if (match(t, /(SG[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+|AC[a-f0-9]+|sq0csp-[A-Za-z0-9_-]+|shpat_[a-f0-9]+)/) && RLENGTH >= 32) { out("HIGH", f, l, "service API key (SendGrid, Twilio, Square or Shopify)", mask(t)); return }
    if (t ~ /_authToken[ \t]*=/ && t !~ /_authToken[ \t]*=[ \t]*[$]\{/) { out("HIGH", f, l, "npm auth token in the change", mask(t)); return }
    if (match(t, /eyJ[A-Za-z0-9_-]+[.]eyJ[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+/) && RLENGTH >= 60) { out("WARN", f, l, "JWT token in the change", mask(t)); return }
    if (t ~ /[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\/ :@"']+:[^\/ @"']+@/ && t !~ /:\/\/[^\/ :@"']+:([*x]+|password|pass|secret|[$%{<])/)
        out("WARN", f, l, "username and password inside a URL", mask(t))
    if (match(lt, /(password|passwd|pwd|secret|api_?key|apikey|access_?key|auth_?token|access_?token|private_?key|client_?secret|token)["']?[ \t]*(=>|=|:)[ \t]*["'][^"' \t]+["']/)) {
        v = substr(t, RSTART, RLENGTH); sub(/^[^=:>]*(=>|=|:)[ \t]*["']/, "", v); sub(/["']$/, "", v)
        if (length(v) >= 8 && v !~ /[|]/ && v !~ /^[$%{<]/ &&
            tolower(v) !~ /^(required|nullable|confirmed|sometimes|string|password|secret|token|changeme|change_me|xxx|your|example|test|dummy|placeholder|null|none|true|false|bearer|basic)/ &&
            v !~ /env|getenv|config|process[.]env|os[.]environ/)
            out("WARN", f, l, "possible hardcoded secret: read it from configuration or a secret store", mask(t))
    }
}

function pii(f, l, t) {
    if (t ~ /(^|[^0-9])[0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]([^0-9]|$)/ && t !~ /12345-1234567-[0-9]|00000-0000000-0|11111-1111111-1/)
        out("WARN", f, l, "looks like a real national ID (CNIC) number: use clearly fake data", mask(t))
    if (t ~ /(^|[^0-9-])[0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]([^0-9-]|$)/ && t !~ /123-45-6789|000-00-0000/)
        out("WARN", f, l, "looks like a real social security number: use clearly fake data", mask(t))
}

function steering(f, l, t, lt) {
    if (lt ~ /ignore (all |any |the )?(previous|prior|above|earlier|preceding|system) (instructions|rules|messages|prompts?)/ ||
        lt ~ /disregard (all |any |the )?(previous|prior|above|earlier|your) (instructions|rules|guidelines)/ ||
        lt ~ /(do not|don't|never) (tell|inform|alert|notify|show) (it to )?(the )?(user|developer|human|reviewer)s? (about|that you|what you|you|anything|of this|this)/ ||
        lt ~ /without (asking|telling|informing|notifying) (the )?(user|developer|human)/ ||
        lt ~ /you are now|new system prompt|act as (an? )?(unrestricted|jailbroken)/)
        out("HIGH", f, l, "prompt-injection style text: an agent that reads this may obey it", t)
    if ((lt ~ /(curl|wget|invoke-webrequest|iwr|invoke-restmethod|irm)[ \t]/ && lt ~ /[|][ \t]*(sudo[ \t]+)?(ba|z|da)?sh([ \t]|$)|[|][ \t]*iex/) ||
        lt ~ /invoke-expression|(^|[^a-z])iex[ \t]*[(]/)
        out("HIGH", f, l, "downloads and runs code in one step (pipe to shell)", t)
    if (lt ~ /(curl|wget|invoke-webrequest|iwr|nc|ncat|scp)[ \t].*([.]env|id_rsa|[.]ssh|[.]aws|credentials|secret|token|passwd)/ ||
        lt ~ /webhook[.]site|requestbin|pipedream[.]net|ngrok[.]io|interact[.]sh|burpcollaborator|oast[.](fun|me|site|live|pro)/)
        out("HIGH", f, l, "looks like it sends secrets or files to an outside address", t)
}

function commands(f, l, t, lt) {
    if (t ~ /migrate:(fresh|reset|refresh|rollback)|db:(wipe|drop|reset)|prisma[ \t]+migrate[ \t]+reset|--force-reset|dropdb[ \t]|rm[ \t]+-[a-zA-Z]*r[a-zA-Z]*f|rm[ \t]+-[a-zA-Z]*f[a-zA-Z]*r|git[ \t]+reset[ \t]+--hard|git[ \t]+push[ \t].*(--force|[ \t]-f([ \t]|$))|git[ \t]+clean[ \t]+-[a-zA-Z]*f|Remove-Item.*-Recurse|rmdir[ \t]+\/s|del[ \t]+\/[sfq]|mkfs|(^|[^a-z])dd[ \t]+if=|shutil[.]rmtree|rimraf/)
        out("HIGH", f, l, "destructive command in code or a script", t)
    if (t ~ /chmod[ \t(].*(777|666|a[+]rwx|o[+]w)|mkdir[(][^)]*0?777|os[.]chmod[(][^)]*0o?777|umask[(][ \t]*0+[ \t]*[)]/)
        out("WARN", f, l, "world-writable permissions", t)
}

function manifest(f, l, t, lt,    lf) {
    lf = tolower(f)
    if (lf ~ /(^|\/)package\.json$/ && t ~ /"(preinstall|install|postinstall|prepare|prepublish|preuninstall|postuninstall)"[ \t]*:/)
        out("HIGH", f, l, "npm install hook added: this command runs on every install, on every machine", t)
    if (lf ~ /(^|\/)composer\.json$/ && t ~ /"(pre|post)-[a-z-]+"[ \t]*:/)
        out("HIGH", f, l, "composer hook added: this command runs on every install or update", t)
    if (lf ~ /(^|\/)(package|composer)\.json$/) {
        if (t ~ /"[^"]+"[ \t]*:[ \t]*"([*]|latest|x|dev-(master|main|develop))"/)
            out("WARN", f, l, "unpinned dependency version: the next install can pull different code", t)
        if (t ~ /"[^"]+"[ \t]*:[ \t]*"(git[+:]|github:|gitlab:|bitbucket:|https?:|file:|link:)/ &&
            t !~ /"(homepage|url|bugs|repository|funding|author|email|[$]schema|license|description|name|main|module|types|readme|source|support|docs|issues|forum|wiki|irc|chat)"[ \t]*:/)
            out("WARN", f, l, "dependency taken from a URL, git or local path: it bypasses the package registry", t)
    }
    if (lf ~ /(^|\/)composer\.json$/ && t ~ /"repositories"[ \t]*:|"type"[ \t]*:[ \t]*"(vcs|path|package|artifact|composer)"/)
        out("WARN", f, l, "custom package repository: packages may not come from Packagist", t)
    if (lf ~ /(^|\/)composer\.json$/ && t ~ /"secure-http"[ \t]*:[ \t]*false/)
        out("HIGH", f, l, "composer allowed to download over plain HTTP", t)
    if ((lf ~ /(^|\/)(requirements[^\/]*\.txt|pip\.(conf|ini)|pyproject\.toml|setup\.cfg)$/) && lt ~ /--extra-index-url|extra-index-url|--trusted-host|trusted-host|index-url[ \t]*=?[ \t]*http:/)
        out("WARN", f, l, "extra or insecure package index: dependency-confusion risk", t)
    if (lf ~ /(^|\/)requirements[^\/]*\.txt$/ && lt ~ /git[+]|https?:\/\/[^ ]+[.](whl|zip|tar[.]gz)/)
        out("WARN", f, l, "dependency taken from a URL or git: it bypasses the package index", t)
    if (lf ~ /(^|\/)(\.npmrc|\.yarnrc(\.yml)?)$/ && (lt ~ /strict-ssl[ \t]*[=:][ \t]*false/ || lt ~ /registry[ \t]*[=:][ \t]*["']?http:/))
        out("HIGH", f, l, "package registry over plain HTTP or with TLS checks off", t)
    if (lf ~ /(^|\/)gemfile$/ && lt ~ /source[ \t]+["']http:/)
        out("WARN", f, l, "gem source over plain HTTP", t)
}

function cfgsec(f, l, t, lt) {
    if (t ~ /["'](secure|http_?only)["'][ \t]*=>[ \t]*false|SESSION_SECURE_COOKIE[ \t]*=[ \t]*false|SESSION_COOKIE_(SECURE|HTTPONLY)[ \t]*=[ \t]*False|CSRF_COOKIE_SECURE[ \t]*=[ \t]*False|(httpOnly|secure)[ \t]*:[ \t]*false/)
        out("WARN", f, l, "cookie or session protection switched off (secure / httpOnly)", t)
    if (t ~ /ALLOWED_HOSTS[ \t]*=[ \t]*[[][ \t]*["'][*]["']/)
        out("WARN", f, l, "any host name accepted (ALLOWED_HOSTS = *)", t)
    if (lt ~ /allow_url_include|ini_set[(][ \t]*["']display_errors["'][ \t]*,[ \t]*["']?(1|on|true)/)
        out("WARN", f, l, "PHP setting that exposes errors or allows remote includes", t)
}

# Cloud and backend-as-a-service settings that leave data open: the usual cause of
# leaks in quickly built (often AI-built) apps.
function cloudsec(f, l, t, lt, k,    lf) {
    lf = tolower(f)
    if (lt ~ /allow[ \t]+(read|write|get|list|create|update|delete)[^;:]*:[ \t]*if[ \t]+true[ \t]*;?/)
        out("HIGH", f, l, "Firebase security rule allows everyone (if true): the whole collection or bucket is public", t)
    if (lf ~ /rules[^\/]*\.json$|database[^\/]*\.json$/ && lt ~ /"[.](read|write)"[ \t]*:[ \t]*(true|"true")/)
        out("HIGH", f, l, "Firebase Realtime Database rule open to everyone", t)
    if (lt ~ /disable[ \t]+row[ \t]+level[ \t]+security/)
        out("HIGH", f, l, "row level security switched off: every API user can read or change every row", t)
    if (lt ~ /create[ \t]+policy/ && lt ~ /(using|with[ \t]+check)[ \t]*[(][ \t]*true[ \t]*[)]/)
        out("WARN", f, l, "database policy that allows every row (using (true)): confirm the table is meant to be public", t)
    if (lt ~ /service_role/ && (k == "js" || k == "tpl" || lf ~ /(^|\/)(public|static|www|resources\/js|src\/(components|pages|app|views))\//))
        out("HIGH", f, l, "service_role key used in frontend code: it bypasses every database policy and every visitor can read it", t)
    if (t ~ /(VITE|NEXT_PUBLIC|REACT_APP|EXPO_PUBLIC|NUXT_PUBLIC|PUBLIC|GATSBY)_[A-Z0-9_]*(SECRET|PRIVATE|SERVICE_ROLE|PASSWORD|PASSWD|ADMIN_KEY)/)
        out("HIGH", f, l, "secret in a public build variable: VITE_/NEXT_PUBLIC_/REACT_APP_ values are shipped to every browser", t)
    if (lt ~ /["']?acl["']?[ \t]*[:=][ \t]*["']public-read(-write)?["']|"principal"[ \t]*:[ \t]*"[*]"|"principal"[ \t]*:[ \t]*[{][ \t]*"aws"[ \t]*:[ \t]*"[*]"|blockpublic(acls|policy)[ \t]*[:=][ \t]*false|allusers|allauthenticatedusers/)
        out("WARN", f, l, "cloud storage or policy opened to the public: confirm nothing private is stored there", t)
    if (lt ~ /0[.]0[.]0[.]0\/0/ && lt ~ /(22|3306|5432|6379|27017|9200|1433)/)
        out("HIGH", f, l, "database or SSH port open to the whole internet (0.0.0.0/0)", t)
}

# LLM features in the application itself (OWASP Top 10 for LLM Applications).
function llmapp(f, l, t, lt, k, req) {
    if (lt ~ /completion|choices[[]0[]]|message[.]content|output_text|response[.]text|generated_text|llm|chatgpt|gpt-|ai_?response|model_?output/ &&
        t ~ /(^|[^a-zA-Z0-9_.>$])eval[ \t]*[(]|exec[ \t]*[(]|new[ \t]+Function[(]|innerHTML|dangerouslySetInnerHTML|v-html|[{]!!|DB::raw|whereRaw|[.]query[(]|cursor[.]execute|shell_exec|system[(]|subprocess|child_process/)
        out("HIGH", f, l, "AI model output used as code, SQL, shell or raw HTML: treat model output as untrusted input (insecure output handling)", t)
    if (req && lt ~ /["']?role["']?[ \t]*(=>|:)[ \t]*["']system["']|system_?prompt|systemprompt|system:[ \t]*[`"']/)
        out("WARN", f, l, "user input placed in a system prompt: users can rewrite the model's instructions (prompt injection)", t)
    if (t ~ /api[.]openai[.]com|api[.]anthropic[.]com|generativelanguage[.]googleapis[.]com|api[.]groq[.]com|openrouter[.]ai|api[.]mistral[.]ai|api[.]cohere|new[ \t]+(OpenAI|Anthropic|GoogleGenerativeAI|Groq)[(]|OpenAI::|Anthropic::|openai[.]chat|client[.]messages[.]create|chat[.]completions[.]create/)
        out("INFO", f, l, "data sent to an AI provider: no secrets or personal data without consent; add a timeout, rate limit and spending cap", t)
}

function configline(f, l, t, lt) {
    if (lt ~ /(^|[^a-z_])(app_)?debug["']?[ \t]*(=|:)[ \t]*["']?(true|1|on)["']?[ \t]*,?[ \t]*$/ && tolower(f) !~ /(example|sample|dist|local|dev|test)/)
        out("WARN", f, l, "debug mode switched on: shows stack traces and settings to visitors", t)
    if (lt ~ /verify_?(ssl|peer|tls)["']?[ \t]*(=|:)[ \t]*["']?(false|0|off)/)
        out("HIGH", f, l, "TLS certificate check switched off", t)
}

# AI leftovers: elided code, pasted chat text and unfinished work. They count on comment lines too.
function leftovers(f, l, t, lt, k, cmt,    ell) {
    ell = "([.][.][.]|" ELL ")"
    if (cmt && (lt ~ (ell "[ \t]*(rest|remaining|existing|other|previous|unchanged|same|more)") ||
        lt ~ /(rest|remainder) of (the )?(code|file|class|function|method|implementation|logic|component|module|methods|functions)( remains?| stays?| is (the same|unchanged)| goes here| unchanged| here| as (before|is))/ ||
        lt ~ /(existing|previous|original|other) (code|logic|methods?|functions?|implementation|content|properties)[ \t]*(remains?( unchanged| the same)?|stays?( the same)?|goes here|unchanged|here|as (it was|before))[ \t]*([.]|[*]\/|-->|--[}][}])?[ \t]*$/ ||
        lt ~ /(code|logic|implementation|methods?|functions?) (remains?|stays?) (unchanged|the same|as (it was|before))[ \t]*([.]|[*]\/|-->|--[}][}])?[ \t]*$/ ||
        lt ~ (ell "[ \t]*(code|logic|implementation)[ \t]*" ell)))
        out("HIGH", f, l, "AI placeholder: code was left out ('rest of the code...'); the file is incomplete", t)
    else if (cmt && lt ~ ("^[ \t]*(//|#|/[*]|[*]|<!--|[{][{]--)[ \t]*" ell "[ \t]*([*]/|-->|--[}][}])?[ \t]*$"))
        out("WARN", f, l, "comment that is only '...': was code left out here?", t)
    if ((cmt || t !~ /["'`]/) &&
        lt ~ /as an ai( language model)?[ ,]|i('m| am) (sorry|unable|not able), (but|i)|here('s| is) the (updated|corrected|modified|complete|full|new|fixed|refactored) (code|file|version|implementation|function)|i('ve| have) (updated|modified|added|fixed|refactored) the (code|file|function|method|class)|certainly! here|sure! here/)
        out("HIGH", f, l, "chat text pasted into the source file", t)
    else if (t ~ /^[ \t]*```[a-zA-Z0-9_-]*[ \t]*$/)
        out("WARN", f, l, "markdown code fence inside a source file: pasted from a chat?", t)
    if (istest(f)) { }
    else if (lt ~ /not (yet )?implemented|your[ _-](api[ _-]?key|token|secret|password|key)[ _-]here|implement (this|me)([^a-z]|$)|lorem ipsum/)
        out("WARN", f, l, "unfinished work left in the change", t)
    else if (cmt && lt ~ /(todo|fixme|xxx|hack)([ \t:(]|$)/)
        out("INFO", f, l, "TODO/FIXME added: is this change finished?", t)
    if (lt ~ /eslint-disable|@ts-ignore|@ts-nocheck|@ts-expect-error|#[ \t]*noqa|#[ \t]*type:[ \t]*ignore|@phpstan-ignore|@psalm-suppress|nosonar|#[ \t]*nosec|\/\/[ \t]*nolint|@suppresswarnings|phpcs:(ignore|disable)|rubocop:disable|pylint:[ \t]*disable|@codingstandardsignore/)
        out("INFO", f, l, "silences a checker or linter: confirm why", t)
}

function code(f, l, t, lt, k, pa, pl,    req, sqlish, rawapi, interp, net) {
    req = hasreq(t)
    llmapp(f, l, t, lt, k, req)
    if ((lt ~ /log::|logger[(.]|console[.](log|info|debug)[(]|logging[.]|error_log[(]/) && t ~ /[$]request->all[(][)]|req[.]body[ 	]*[),]|request[.](POST|data|json)[ 	]*[),]/)
        out("WARN", f, l, "whole request logged: passwords, tokens and personal data end up in the logs", t)

    # SQL injection
    sqlish = (lt ~ /select[ \t].*[ \t]from[ \t]|insert[ \t]+into[ \t]|update[ \t]+[^ \t]+[ \t]+set[ \t]|delete[ \t]+from[ \t]|[ \t]where[ \t]+[^ \t]+[ \t]*(=|<|>|like|in[ \t(])|order[ \t]+by[ \t]/)
    rawapi = (t ~ /DB::(raw|select|statement|update|delete|insert|unprepared)[ \t]*[(]|(where|select|orderBy|having|groupBy)Raw[ \t]*[(]|->query[ \t]*[(]|->exec[ \t]*[(]|mysqli_query|pg_query|[.]raw[ \t]*[(]|[.]query[ \t]*[(]|[.]execute[ \t]*[(]|executeQuery[(]|executeUpdate[(]|createNativeQuery[(]|createQuery[(]|FromSqlRaw|ExecuteSqlRaw|SqlCommand[(]|[.]Exec[(]|[.]QueryRow?[(]|cursor[.]execute|[.]extra[(]|RawSQL[(]/)
    interp = (t ~ /"[^"]*[$][a-zA-Z_{]/ || t ~ /["'][ \t]*[.][ \t]*[$][a-zA-Z_]/ || t ~ /[$][a-zA-Z_][a-zA-Z0-9_>-]*[ \t]*[.][ \t]*["']/ ||
              t ~ /[$][{][^}]+[}]/ || t ~ /(^|[^a-zA-Z0-9_])f["'][^"']*[{][^}]+[}]/ || t ~ /["'][ \t]*[+][ \t]*[a-zA-Z_(]/ ||
              t ~ /[]a-zA-Z_)][ \t]*[+][ \t]*["']/ || t ~ /["'][ \t]*%[ \t]*[(]?[a-zA-Z_]/ || t ~ /[.]format[(]|String[.]Format[(]|fmt[.]Sprintf[(]|sprintf[(]/)
    if ((sqlish || rawapi) && interp) {
        if (req) out("HIGH", f, l, "SQL built from request input: SQL injection; use bound parameters", t)
        else if (sqlish) out("WARN", f, l, "SQL built by string interpolation or concatenation: use bound parameters", t)
        else out("WARN", f, l, "raw query with a variable inside: make sure every value is a bound parameter", t)
    }

    # Command execution and dynamic code
    if (k == "php" && t ~ /(^|[^a-zA-Z0-9_>:$])(exec|shell_exec|system|passthru|proc_open|popen|pcntl_exec)[ \t]*[(]|Process::(run|start|pipe)[(]|new[ \t]+Process[(]/)
        out(req ? "HIGH" : "WARN", f, l, req ? "shell command with request input: command injection" : "runs a shell command: escape every argument, never pass user input", t)
    if (k == "php" && t ~ /`[^`]*[$][a-zA-Z_]/) out("WARN", f, l, "PHP backtick operator runs a shell command", t)
    if (t ~ /(^|[^a-zA-Z0-9_.>$])eval[ \t]*[(]/ || (k == "js" && t ~ /new[ \t]+Function[ \t]*[(]|set(Timeout|Interval)[(][ \t]*["'`]/) || (k == "py" && t ~ /(^|[^a-zA-Z0-9_.])exec[ \t]*[(]/))
        out("HIGH", f, l, "runs a string as code (eval)", t)
    if (k == "js" && (t ~ /child_process|execSync[(]|spawnSync[(]|shell[ \t]*:[ \t]*true/ || t ~ /[.]exec[(][ \t]*`/))
        out(req ? "HIGH" : "WARN", f, l, "runs a shell command from Node", t)
    if (k == "py" && (t ~ /os[.](system|popen)[(]|commands[.]getoutput/ || (t ~ /subprocess[.]/ && t ~ /shell[ \t]*=[ \t]*True/)))
        out("HIGH", f, l, "runs a shell command from Python", t)
    if ((k == "jvm" && t ~ /Runtime[.]getRuntime[(][)][.]exec|new[ \t]+ProcessBuilder/) || (k == "cs" && t ~ /Process[.]Start[(]/) ||
        (k == "go" && t ~ /exec[.]Command[(]/) || (k == "rb" && t ~ /(^|[^a-zA-Z0-9_.])(system|exec|spawn)[(]|%x[(]|Open3[.]/))
        out(req ? "HIGH" : "WARN", f, l, "runs an operating-system command", t)

    # Unsafe deserialisation and XML
    if ((k == "php" && t ~ /(^|[^a-zA-Z0-9_>:])unserialize[ \t]*[(]/) ||
        (k == "py" && (t ~ /pickle[.]loads?[(]|marshal[.]loads[(]|shelve[.]open[(]/ || (t ~ /yaml[.]load[(]/ && t !~ /SafeLoader|safe_load/))) ||
        (k == "jvm" && t ~ /ObjectInputStream|XMLDecoder|enableDefaultTyping/) ||
        (k == "cs" && t ~ /BinaryFormatter|NetDataContractSerializer|TypeNameHandling[.](All|Auto|Objects)/) ||
        (k == "rb" && t ~ /Marshal[.]load|YAML[.]load[(]/))
        out(req ? "HIGH" : "WARN", f, l, "unsafe deserialisation: untrusted data here can run code", t)
    if (t ~ /LIBXML_NOENT|libxml_disable_entity_loader[(][ \t]*false|resolve_entities[ \t]*=[ \t]*True|setExpandEntityReferences[(][ \t]*true|FEATURE_SECURE_PROCESSING[ \t]*,[ \t]*false|DtdProcessing[.]Parse/)
        out("WARN", f, l, "XML parser resolves external entities (XXE): it can read local files", t)

    # TLS, tokens and ciphers
    if (t ~ /verify[ \t]*=[ \t]*False|CURLOPT_SSL_VERIFY(PEER|HOST)[ \t]*,[ \t]*(false|0)|rejectUnauthorized[ \t]*:[ \t]*false|NODE_TLS_REJECT_UNAUTHORIZED|InsecureSkipVerify[ \t]*:[ \t]*true|["']verify["'][ \t]*=>[ \t]*false|withoutVerifying[(]|ServerCertificateValidationCallback|TrustAllCerts|AllowAllHostnameVerifier|VERIFY_NONE/)
        out("HIGH", f, l, "TLS certificate check switched off: traffic can be read or changed in transit", t)
    if (lt ~ /algorithms?["']?[ \t]*(=>|[:=])[ \t]*[[]?[ \t]*["']none["']|verify_signature["']?[ \t]*(=>|:)[ \t]*false|jwt[.]decode[(][^)]*verify[ \t]*=[ \t]*false|ignoreexpiration["']?[ \t]*(=>|:)[ \t]*true/)
        out("HIGH", f, l, "token signature or expiry check switched off: anyone can forge a token", t)
    if (lt ~ /["'](des|des-ede3?|des-ede3?-cbc|des-cbc|rc4|bf-cbc)["']|mode_ecb|aes\/ecb|["']aes-[0-9]+-ecb["']|createcipher[(]|mcrypt_|protocol_(tlsv1|sslv[23])([^_]|$)|protocol_tlsv1_1|sslv3/ || t ~ /DES[.]new[(]|Cipher[.]getInstance[(]["'](DES|RC4)/)
        out("WARN", f, l, "weak or broken cipher or protocol", t)

    # Output escaping (XSS)
    if (k == "blade" && t ~ /[{]!!/) out("WARN", f, l, "unescaped Blade output {!! !!}: wrap any user data inside with e()", t)
    if (t ~ /dangerouslySetInnerHTML|v-html[ \t]*=|[.](inner|outer)HTML[ \t]*[+]?=|insertAdjacentHTML[(]|document[.]write[(]|bypassSecurityTrust|@Html[.]Raw[(]/ ||
        (k == "tpl" && t ~ /<%-|[|][ \t]*(safe|raw)([^a-zA-Z_]|$)|autoescape[ \t]+(false|off)|[.]html_safe/) ||
        (k == "py" && t ~ /mark_safe[(]|Markup[(]/) || (k == "rb" && t ~ /[.]html_safe|(^|[^a-zA-Z0-9_])raw[(]/))
        out("WARN", f, l, "unescaped HTML output: XSS if any part of it comes from users", t)
    if (k == "php" && t ~ /(echo|print)[ \t(].*[$]_(GET|POST|REQUEST|COOKIE)/) out("HIGH", f, l, "request input echoed without escaping: XSS", t)
    if (k == "js" && t ~ /[.]html[(][ \t]*[a-zA-Z_$]/) out("INFO", f, l, "jQuery .html() with a variable: escape it if it holds user data", t)
    if (k == "js" && t ~ /[[][ \t]*["']__proto__["'][ \t]*[]]|__proto__[ \t]*=[^=]|constructor[.]prototype[ \t]*=[^=]/)
        out("WARN", f, l, "writes to an object prototype: prototype pollution if keys come from users", t)

    # CSRF, authentication, CORS
    if (t ~ /csrf_exempt|csrf[(][)][.]disable[(]|csrf[ \t]*:[ \t]*false|IgnoreAntiforgeryToken|skip_before_action[ \t]+:verify_authenticity_token|protect_from_forgery[ \t]+with:[ \t]*:null_session|withoutMiddleware[(][^)]*([Cc]srf|VerifyCsrfToken)/ ||
        (f ~ /VerifyCsrfToken[.]php$/ && t ~ /["'][^"']+["']/))
        out("WARN", f, l, "CSRF protection weakened for this path", t)
    if (t ~ /permitAll[(][)]|AllowAnonymous|@PermitAll|skip_before_action[ \t]+:authenticate|withoutMiddleware[(][^)]*auth/)
        out("WARN", f, l, "authentication skipped here: confirm this must be public", t)
    if (t ~ /Access-Control-Allow-Origin["']?[ \t]*[:,][ \t]*["']?[*]|allowed_origins["']?[ \t]*=>[ \t]*[[][ \t]*["'][*]|origin[ \t]*:[ \t]*["'][*]["']|AllowAnyOrigin[(][)]|CORS_(ORIGIN_)?ALLOW_ALL(_ORIGINS)?[ \t]*=[ \t]*True/)
        out("WARN", f, l, "CORS open to every origin", t)
    if (LARAVEL && t ~ /::unguard[(]/) out("WARN", f, l, "mass-assignment protection switched off for every model", t)
    if (LARAVEL && t ~ /loginUsingId[(]/) out("WARN", f, l, "logs in as a user by id: confirm no other user can reach this path", t)
    if (LARAVEL && t ~ /config[(][ \t]*[[][ \t]*["']app[.]debug["'][ \t]*=>[ \t]*true/) out("WARN", f, l, "debug mode switched on at runtime", t)

    # Mass assignment
    if ((t ~ /[$]request->(all|input)[(][)]/ && t ~ /(create|update|fill|forceFill|insert|updateOrCreate|firstOrCreate|make)[ \t]*[(]/) ||
        t ~ /[$]guarded[ \t]*=[ \t]*[[][ \t]*[]]/ ||
        t ~ /[.](create|update|insert|insertMany|updateOne|updateMany|findByIdAndUpdate|findOneAndUpdate|build)[(][ \t]*req[.]body[ \t]*[,)]/ ||
        t ~ /Object[.]assign[(][^,]+,[ \t]*req[.]body/ || t ~ /fields[ \t]*=[ \t]*["']__all__["']/ || t ~ /params[.]permit!/)
        out("WARN", f, l, "mass assignment: a user can set any column (role, is_admin, owner id); list the allowed fields", t)

    # Weak hashing and randomness for secrets
    if (lt ~ /(^|[^a-z0-9_])(md5|sha1)[ \t]*[(]/ && lt ~ /pass|pwd|secret|token|otp|reset|salt/)
        out("WARN", f, l, "MD5/SHA1 for a secret: use password_hash/bcrypt/argon2, or HMAC-SHA256 for tokens", t)
    if ((t ~ /Math[.]random[(]|(^|[^a-zA-Z0-9_>:])(rand|mt_rand|uniqid|str_shuffle|lcg_value)[ \t]*[(]|random[.](random|randint|choice|choices)[(]|new[ \t]+Random[(]/) &&
        lt ~ /token|secret|otp|password|passwd|nonce|salt|api.?key|reset|verification/)
        out("WARN", f, l, "predictable random value for a secret: use random_bytes / crypto.randomBytes / secrets", t)

    # Sensitive data in logs
    if (lt ~ /log::|logger[(.]|->log[(]|console[.](log|info|warn|error|debug)[(]|logging[.]|(^|[^a-z])log[.](info|debug|warn|warning|error)[(]|error_log[(]|system[.]out[.]print|rails[.]logger/ &&
        lt ~ /password|passwd|secret|token|api.?key|cnic|cvv|card.?number|otp|authorization|cookie/)
        out("WARN", f, l, "sensitive value may be written to a log", t)

    # Debug leftovers
    if ((k == "php" || k == "blade") && t ~ /(^|[^a-zA-Z0-9_>:$])(dd|dump|var_dump|print_r|var_export|ray|xdebug_break)[ \t]*[(]/ && t !~ /print_r[(][^)]*,[ \t]*(true|1)[ \t]*[)]/)
        out("WARN", f, l, "debug output left in", t)
    if ((k == "js" || k == "blade" || k == "tpl") && t ~ /console[.](log|debug|trace|dir|table)[(]|(^|[^a-zA-Z0-9_$])debugger[ \t]*;?[ \t]*$/)
        out("WARN", f, l, "debug output left in", t)
    if ((k == "py" && t ~ /pdb[.]set_trace[(]|(^|[^a-zA-Z0-9_.])breakpoint[(][)]|import[ \t]+i?pdb/) || (k == "rb" && t ~ /binding[.](pry|irb)|byebug/))
        out("WARN", f, l, "debugger left in", t)
    if (k == "php" && t ~ /error_reporting[(][ \t]*0[ \t]*[)]/) out("INFO", f, l, "error reporting switched off: failures become invisible", t)

    # Error handling
    if (t ~ /catch[ \t]*[(][^)]*[)][ \t]*[{][ \t]*[}]/ || t ~ /[.]catch[(][ \t]*([(][^)]*[)]|[a-zA-Z_]+)[ \t]*=>[ \t]*[{][ \t]*[}][ \t]*[)]/ ||
        t ~ /except[^:]*:[ \t]*pass[ \t]*$/ || (k == "py" && t ~ /^[ \t]*pass[ \t]*$/ && pl == l - 1 && pa ~ /^[ \t]*except([ \t].*)?:[ \t]*$/))
        out("WARN", f, l, "error swallowed silently: a failure will look like success", t)
    if ((k == "php" || k == "blade") && t ~ /getMessage[(][)]/ && t !~ /Log::|logger[(]|error_log|report[(]|->(error|warning|info|debug|critical|alert|emergency|notice)[(]/)
        out("WARN", f, l, "raw exception message goes to the user: log it and show a plain message", t)
    if ((k == "js" && t ~ /(res|reply|ctx)[.](send|json|status|body)/ && t ~ /(err|error|e|ex)[.](message|stack)/) ||
        (k == "py" && t ~ /return|Response|jsonify|HTTPException/ && t ~ /str[(][ \t]*(e|ex|exc|err|error)[ \t]*[)]|traceback/) ||
        (k == "cs" && t ~ /(return|Content|BadRequest|Ok|Problem|StatusCode)[ \t(]/ && t ~ /(ex|e|exception)[.](Message|StackTrace)/))
        out("WARN", f, l, "raw exception message goes to the user: log it and show a plain message", t)

    # Files and URLs taken from the request
    if (req && t ~ /file_get_contents|fopen|readfile|unlink|file_put_contents|(^|[^a-zA-Z0-9_])(include|require)(_once)?[ \t(]|Storage::(get|put|delete|download)|->download[(]|->file[(]|send_file|sendFile|res[.]download|readFile|createReadStream|(^|[^a-zA-Z0-9_.])open[(]|File[.](Read|Open|Delete|Exists)|Paths[.]get|new[ \t]+File[(]|os[.]path[.]join/)
        out("HIGH", f, l, "file path built from request input: path traversal; resolve it and check it stays inside an allowed folder", t)
    else if (k == "php" && t ~ /(^|[^a-zA-Z0-9_])(include|require)(_once)?[ \t(]+[^;]*[$]/)
        out("WARN", f, l, "include/require with a variable path", t)
    net = (t ~ /Http::|GuzzleHttp|curl_init[(]|curl_exec[(]|file_get_contents[(][ \t]*["']https?:|fopen[(][ \t]*["']https?:|fsockopen[(]|(^|[^a-zA-Z0-9_.])fetch[(]|axios[.(]|XMLHttpRequest|requests[.](get|post|put|patch|delete|request)[(]|urllib[.]request|httpx[.]|aiohttp|HttpClient|WebClient|RestTemplate|http[.](Get|Post|NewRequest)[(]|Net::HTTP|Faraday|HTTParty|sendBeacon|new[ \t]+WebSocket[(]/)
    if (net && req && lt ~ /url|uri|host|endpoint|link|src|callback|webhook/)
        out("HIGH", f, l, "server fetches a URL that comes from the request: SSRF; allow only known hosts", t)
    else if (net)
        out("INFO", f, l, "outbound network call: check what data leaves, to which host, and that a failure is handled", t)
    if (req && t ~ /redirect[(]|->to[(]|[.]redirect[(]|Redirect[(]|HttpResponseRedirect|header[(][ \t]*["']Location/)
        out("WARN", f, l, "redirect target from request input: open redirect; allow only internal paths", t)
    if (t ~ /[$]_FILES|move_uploaded_file|->file[(]|hasFile[(]|->store(As|Publicly)?[(]|multer|req[.]files?([^a-zA-Z_]|$)|request[.]FILES|IFormFile|MultipartFile|UploadedFile/)
        out("INFO", f, l, "file upload: validate type and size, generate the stored name, keep it out of the public web root", t)

    # Data destruction
    if (t ~ /->truncate[(][)]|::truncate[(][)]|[.]truncate[(][ \t]*[)]|TRUNCATE[ \t]+(TABLE[ \t]+)?[A-Za-z_`"]/ || lt ~ /truncate[ \t]+table[ \t]/)
        out("HIGH", f, l, "TRUNCATE wipes every row of the table", t)
    if (lt ~ /drop[ \t]+(table|database|schema|column|index|view)[ \t]/ && !ismig(f))
        out("HIGH", f, l, "DROP statement: removes structure and data", t)
    if (lt ~ /delete[ \t]+from[ \t]+[^ \t]+[ \t]*(["';)]|$)/ || (lt ~ /update[ \t]+[^ \t]+[ \t]+set[ \t]/ && lt !~ /where/))
        out("WARN", f, l, "DELETE/UPDATE with no WHERE on this line: confirm it cannot hit every row", t)
    if (t ~ /->forceDelete[(]|->delete[(][)]|[.]destroy[(]|[.](deleteMany|delete_many)[(]|[.]delete[(][)]/)
        out("INFO", f, l, "hard delete: confirm this data is not meant to be soft-deleted", t)
    if (t ~ /use[ \t]+(Illuminate\\Database\\Eloquent\\)?SoftDeletes/)
        out("INFO", f, l, "SoftDeletes trait added: changes what every query on this model returns", t)

    # Possible N+1: a query a few added lines below a loop header
    if (t ~ /(^|[^a-zA-Z_])(foreach|for|while)[ \t]*[(]|[.](forEach|each)[(]|[.]map[(]|^[ \t]*for[ \t].*[ \t]in[ \t].*:[ \t]*$/) loopln[f] = l
    else if ((f in loopln) && l - loopln[f] >= 1 && l - loopln[f] <= 6 &&
             t ~ /::(where|find|findOrFail|first|count|get)[(]|->(where|find|first|get|count|exists|pluck)[(]|DB::(table|select)|[.]objects[.](get|filter|all)|[.](findOne|findById|findAll|findUnique|findFirst)[(]|cursor[.]execute|SELECT[ \t]/)
        out("INFO", f, l, "query inside a loop: possible N+1; one query with a join or whereIn may do", t)

    # Laravel: env() is null once config is cached
    if (LARAVEL && k == "php" && f !~ /^config\// && t ~ /(^|[^a-zA-Z0-9_>:$])env[ \t]*[(]/)
        out("WARN", f, l, "env() outside config/: returns null once config is cached; read it through config()", t)

    # Transactions
    if (t ~ /beginTransaction|BEGIN[ \t]+TRAN|START[ \t]+TRANSACTION|BeginTransaction[(]/) { if (!(f in txbegin)) txbegin[f] = l }
    if (t ~ /rollBack|rollback|ROLLBACK|Rollback[(]/) txok[f] = 1
}

function migline(f, l, t) {
    if (t ~ /function[ \t]+up[ \t]*[(]|def[ \t]+(up|upgrade|change)[ \t]*[(:]|exports[.]up|async[ \t]+up[ \t]*[(]|^[ \t]*up[ \t]*[(:]|void[ \t]+Up[(]/) migstate[f] = "up"
    if (t ~ /function[ \t]+down[ \t]*[(]|def[ \t]+(down|downgrade)[ \t]*[(:]|exports[.]down|async[ \t]+down[ \t]*[(]|^[ \t]*down[ \t]*[(:]|void[ \t]+Down[(]/) { migstate[f] = "down"; hasdown[f] = 1 }
    if (migstate[f] != "down" && t ~ /dropColumn|dropIfExists|Schema::drop|->drop[(]|dropTable|drop_table|remove_column|removeColumn|RemoveField|DeleteModel|op[.]drop_|DropTable|DropColumn|renameColumn|rename_column|RenameField|renameTable|rename_table|->change[(][)]|change_column|AlterField|->truncate|DROP[ \t]+(TABLE|COLUMN)/)
        out("HIGH", f, l, "destructive schema change: existing data in this table or column is lost or rewritten", t)
}

function testline(f, l, t, isadd) {
    if (t ~ /assert|expect[(]|[.]should|toBe|toEqual|verify[(]|Assert[.]/) { if (isadd) asrtadd[f]++; else asrtrem[f]++ }
    if (!isadd) return
    if (t ~ /[.]skip[(]|(^|[^a-zA-Z])x(it|describe|test)[(]|@skip|@Ignore|@Disabled|pytest[.]mark[.](skip|xfail)|markTestSkipped|markTestIncomplete|->skip[(]|[[]Ignore|t[.]Skip[(]|(it|describe|test)[.]only[(]/)
        out("WARN", f, l, "test skipped or focused: the suite no longer checks everything", t)
    if (t ~ /assertTrue[(][ \t]*true[ \t]*[)]|expect[(][ \t]*true[ \t]*[)][.]toBe[(][ \t]*true|assert[ \t]+True[ \t]*$/)
        out("WARN", f, l, "assertion that can never fail", t)
}

function projectrules(f, l, t,    r) {
    for (r = 1; r <= nr; r++) {
        if (RKIND[r] == "change" || f !~ RP[r]) continue
        if (RKIND[r] == "file") {
            if (RU[r] != "" && t ~ RU[r]) fok[r, f] = 1
            if (t ~ RL[r] && !((r, f) in fhit)) { fhit[r, f] = l; fhtext[r, f] = t }
        } else if (t ~ RL[r] && (RU[r] == "" || t !~ RU[r])) {
            out(RSEV[r], f, l, RM[r], t)
        }
    }
}

# ---------------------------------------------------------------- report

END {
    for (f in txbegin) if (!(f in txok))
        out("WARN", f, txbegin[f], "transaction opened with no rollback in this change: every failure path must roll back", "")
    for (i = 1; i <= nra; i++) if (!(RAT[i] in addedtext)) authrem[RAF[i]]++
    for (i = 1; i <= nrr; i++) if (!(RRT[i] in addedroute)) routesgone++
    for (f in authrem) if (authrem[f] > authadd[f] + 0) {
        if (routesgone)
            out("WARN", f, 0, "auth/permission/CSRF checks removed together with routes (" authrem[f] " removed, " (authadd[f] + 0) " added): confirm the feature removal is intended and nothing that stays was opened up", "")
        else
            out("HIGH", f, 0, "auth/permission/CSRF checks removed (" authrem[f] " lines removed, " (authadd[f] + 0) " added): confirm nothing was opened up", "")
    }
    if (ndel > 10) {
        lst = ""; for (i = 1; i <= 10; i++) lst = lst (i > 1 ? ", " : "") dels[i]
        out("WARN", "-", 0, ndel " files deleted (first: " lst "): confirm nothing still uses them", "")
    } else for (i = 1; i <= ndel; i++) out("WARN", dels[i], 0, "file deleted: confirm nothing still uses it", "")
    for (f in asrtrem) if (asrtrem[f] > asrtadd[f] + 0)
        out("WARN", f, 0, "fewer assertions than before (" asrtrem[f] " removed, " (asrtadd[f] + 0) " added): was a test weakened to make it pass?", "")
    for (f in isnew) if (isnew[f] && ismig(f) && (kind(f) == "php" || kind(f) == "js") && !(f in hasdown))
        out("WARN", f, 0, "new migration has no down(): it cannot be rolled back", "")
    for (k in fhit) if (!(k in fok)) {
        split(k, kk, SUBSEP)
        out(RSEV[kk[1]], kk[2], fhit[k], RM[kk[1]], fhtext[k])
    }
    for (r = 1; r <= nr; r++) if (RKIND[r] == "change") {
        trig = ""; ok = 0
        for (p in changed) { if (p ~ RP[r] && trig == "") trig = p; if (RU[r] != "" && p ~ RU[r]) ok = 1 }
        if (trig != "" && !ok) out(RSEV[r], trig, 0, RM[r], "")
    }
    if (HASTESTS && codechanged && !testchanged)
        out("INFO", "-", 0, "code changed but no test was added or updated", "")
    if (nfiles > 30 || nadd > 1500)
        out("INFO", "-", 0, "large change (" nfiles " files, " nadd " added lines): reviewers miss problems in big diffs; split it if you can", "")

    split("HIGH WARN INFO", ord, " ")
    for (o = 1; o <= 3; o++) {
        shown = 0
        for (i = 1; i <= nf_; i++) if (S[i] == ord[o]) {
            if (FORMAT == "tsv") { printf "%s\t%s\t%d\t%s\t%s\n", S[i], F[i], L[i], M[i], T[i]; continue }
            if (CAP && shown >= CAP) continue
            shown++
            loc = F[i] (L[i] > 0 ? ":" L[i] : "")
            printf "%-4s  %s  %s\n", S[i], loc, M[i]
            if (T[i] != "") { x = T[i]; if (length(x) > 150) x = substr(x, 1, 147) "..."; printf "      > %s\n", x }
        }
        if (FORMAT != "tsv" && CAP && cnt[ord[o]] > CAP)
            printf "...   %d more %s finding(s) not shown: rerun with --all\n", cnt[ord[o]] - CAP, ord[o]
    }
    if (FORMAT != "tsv") {
        if (nf_ == 0) print "No red flags found by the pattern scan."
        printf "\n%d file(s), %d added line(s) scanned. Findings: %d high, %d warn, %d info.\n", nfiles, nadd, cnt["HIGH"], cnt["WARN"], cnt["INFO"]
    }
    exit ((cnt["HIGH"] > 0 || (FAILON == "warn" && cnt["WARN"] > 0)) ? 1 : 0)
}
