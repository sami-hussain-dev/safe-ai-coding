# Changelog

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
