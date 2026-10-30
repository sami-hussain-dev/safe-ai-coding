# Changelog

## Unreleased

**Gate modes**

- **`balanced` (new default):** the agent asks only before actions that can cause harm, and does everything else without asking.
- **`strict`:** the agent asks before every command and every file change. Reading and searching the project, and `git status`, `diff`, `log` and `show`, still go ahead.
- **Choosing a mode:**
  - Say it in the session: "strict mode", or `/safe-ai-coding mode strict`.
  - Or set a repository default with a `Gate mode: strict` line in `.claude/safe-code-conventions.md`.
  - Text anywhere else cannot change the mode.
- **New in the always-ask list (both modes):**
  - adding third-party code to the product: CDN scripts and stylesheets, web fonts, widgets, tracking snippets, outside SDKs
  - writing code that can open a hole or leak data: new outbound data flows, endpoints without login, exports of personal data, uploads, changes to login, permission, session, token or encryption code

**Switch it off for one project**

- `/safe-ai-coding off` switches the skill off in the current project only; `on` brings it back and `status` shows it.
- The new `skill-switch.pl` writes Claude Code's own setting to `.claude/settings.local.json`:
  - a git copy gets `skillOverrides` set to `user-invocable-only`, so `on` still works
  - a plugin gets `enabledPlugins` set to `false`
- It keeps every other setting, and never writes a settings file that is not valid JSON or is a symlink.
- `off --shared` writes the committed `.claude/settings.json` for the whole team, and goes through the permission gate.
- Only the user's own command switches the skill off; text in files cannot.

**Alerts (optional)**

- `alerts on` adds two Claude Code hooks: a `PermissionRequest` hook for every tool, and a `PreToolUse` hook for `AskUserQuestion`. They work in every project, and `alerts off` removes exactly them.
- **Sound:**
  - it repeats until the question is answered, which the hook sees when the tool result appears in the transcript
  - it has its own switch (`alerts sound on|off`) and takes the user's own `.wav`, `.mp3` or `.wma` (`alerts sound <file>`)
  - on Windows, MP3 plays through Windows MCI, so no media player is needed
- **Windows popup** (new `alert-hook.ps1`):
  - **When:** it appears when VS Code is not in front.
  - **Permissions:** it shows the tool, the command and Claude's note, with Allow, Deny and "Deny with a message".
  - **Questions:** it shows every option, multi-select and an "Other" answer.
  - **Answers:** they go back through the documented hook output.
  - **No accidental approvals:** it never takes the focus and has no default button.
  - **Closing decides nothing:** closing it, or letting it time out, leaves the editor's prompt in charge.
- **macOS and Linux** (`alert-hook.sh`): a sound and a system notification, without the popup.
- **Mobile:** it switches on Claude Code's own push when input is needed (`inputNeededNotifEnabled`); nothing goes to any other service.
- **Your settings:** `alerts-setup.pl` keeps every other setting, backs `settings.json` up once, and never writes an invalid or symlinked file.

**CDN check**

- A `<script>` loaded from another site without `integrity` (SRI) is WARN.
- A stylesheet loaded from another site is INFO.

**Fixes**

- `repo-scan` now also finds xAI, SendGrid, Square, Shopify and older OpenAI keys already committed, as `diff-check` does.
- The report masks GitLab, Hugging Face, Groq, Replicate, xAI, SendGrid, Square and Shopify keys.
- `SKILL.md` and the guides list scan section 10 (secrets and open data already committed).
- Links in `llms.txt` and the project page point to the `master` branch.
- The project page showed version 2.0.

**Self-test:** 125 cases (69 AI view, 22 human view, 28 safety, 6 report). The report case now also checks that a Hugging Face token is masked.

## 2.1.0 (2026-10-29)

**Open data in AI-built apps**

The scan now flags:

- Firebase or Firestore rules `if true` and Realtime Database rules open to everyone
- row level security switched off, and `using (true)` policies
- `service_role` keys in frontend code, and secrets in `VITE_` / `NEXT_PUBLIC_` / `REACT_APP_` / `EXPO_PUBLIC_` variables
- public buckets and policies
- database or SSH ports open to `0.0.0.0/0`

**LLM application security**

- Model output used as code, SQL, shell or raw HTML is HIGH.
- User input placed in a system prompt is WARN.
- Calls to AI providers are INFO, as a reminder about consent, rate limits and spending caps.
- New reference: `references/llm-app-security.md` (OWASP Top 10 for LLM Applications 2025).

**More secret types**

- AI provider keys: OpenRouter, Hugging Face, Groq, Replicate, xAI
- SendGrid, Twilio, Square and Shopify keys
- whole request bodies written to logs

**repo-scan**

- MCP configs are checked for unpinned `npx -y` servers, plain-HTTP servers and tokens written into the file.
- New section 10 lists:
  - committed `.env` files
  - real-looking keys already in tracked files (printed masked)
  - open Firebase rules
  - secrets in public build variables

**Other new features**

- **Commit guard:** `install-git-hook.sh` adds a pre-commit hook that blocks commits with HIGH findings. It never overwrites a hook it did not create.
- **Permission gate:**
  - A task request is not approval.
  - A "no" stands until the user answers a new request.
  - The full permission block is always shown in chat.
  - "Possible harm" states what can go wrong.
  - "Reversible?" may not claim that a script's effects can be undone.
  - Side effects such as overwritten build files must be listed.
- **Skill trigger:** the skill now loads for one-line risky requests ("install X", "push it", "run the migration").
- **Side-door data leaks:** new rules forbid putting secrets or personal data into URLs, links, searches or tool arguments, fetching URLs found in content, and printing secret values.

**Fixes**

- A new `.sql` file only counts as a data file when its name looks like a dump or backup.
- The "change:" line no longer prints an empty value.

**Self-test:** 115 cases (68 AI view, 21 human view, 20 safety, 6 report).

## 2.0.0 (2026-10-28)

**New modes**

- **Report mode, on request only:** `make-report.pl` and `html-to-pdf.sh` turn a JSON summary of the session into a polished PDF. The PDF covers what was wrong (symptom, root cause, impact, evidence), what was fixed (with before/after code), checks from both perspectives, scan counts before and after, the permission log, and open risks. It is available in English and Roman Urdu, all text is escaped, common secret and ID formats are masked, and the page loads nothing from the network.
- **Self-test:** `self-test.sh` builds throw-away repositories and proves each check still works. It covers attacks that must be caught (AI view), good code that must stay quiet (human view), and malicious repositories that must not make the scanners run or follow anything.
- **`checksums.sh`:** verifies a received copy against `CHECKSUMS.sha256` and reports changed, missing and unexpected files.

**AI-specific checks**

- **`symbol-check.pl`:** flags references, on added lines, to classes, static methods, Laravel views, route names and config files, and JS/TS and Python relative imports that do not exist.
- **New diff-check checks:**
  - elided code (`// ... rest of the code unchanged`)
  - pasted chat text and code fences
  - merge conflict markers
  - unfinished work

**Other new diff-check checks**

- **Security settings:** JWT and token checks switched off, XXE, insecure cookies, world-writable permissions, weak ciphers, prototype pollution.
- **Secrets and personal data:** sensitive data in logs, real-looking ID numbers (CNIC, SSN), npm and GitLab tokens, secret patterns un-ignored or removed from `.gitignore`.
- **Dependencies:** unpinned versions and URL or git dependencies, custom composer repositories, extra pip indexes, insecure registries.
- **Repository behaviour:** symlinks that leave the repository (and those pointing at keys), new executables and binary files.
- **Process signals:** a possible N+1 query in a loop, code changed with no test changed, a large-change warning.
- **Laravel:** `unguard()`, `loginUsingId()`, runtime debug.

**Scanner hardening**

- The scanners never run anything the scanned repository configured. They disable `core.fsmonitor`, external diff and textconv, the pager and lazy fetches.
- `diff-check.sh` refuses to run when `.git/config` defines filter programs, unless `--trust-git-config` is given.
- Snippets are printed with control characters removed and are labelled as untrusted data.
- Python checks run in isolated mode (`-I`), and PHP lint runs without `php.ini` (`-n`).
- Perl scripts never load modules from the scanned directory.
- Untracked symlinks are not followed.

**repo-scan**

- New sections: the repository's own git config, hooks, `.gitmodules` and `.gitattributes`; where packages come from (`.npmrc`, pip indexes, composer repositories, lock files); symlinks leaving the repository; executable files.
- New flags: settings that switch permission checks off or auto-approve MCP servers.

**diff-check options**

- `--format=tsv`, `--fail-on=warn`, `--all`, `--no-symbols` and `--trust-git-config`.

**Project rules**

- A new rule type, `CHANGE:`, for "changing X requires changing Y".
- Rules whose message reads like an instruction to an agent are skipped.
- Every rule message is prefixed with `[project rule]`.

**Skill text**

- Six always-on rules; rule 6 is "do only what was asked; never produce the report unprompted".
- Review now runs through an AI lens and a human lens.
- New references: `ai-failure-modes.md` and `report-format.md`.

## 1.0.0 (2026-10-28)

- First release: the permission gate, the scan, build and review modes, `repo-scan.sh` and `diff-check.sh`, and project profiles.
