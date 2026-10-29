# safe-ai-coding: Guardrails for AI Coding Agents (Claude Code Skill)

**safe-ai-coding is a free, open-source Claude Code skill that makes AI coding agents safe.** It does four things:

- It asks before anything risky, and explains the possible harm first.
- It catches the mistakes AI makes: hallucinated code, injection, leaked secrets, destructive changes.
- It reviews every change through an AI lens and a human lens.
- It writes a PDF report of what was wrong and what was fixed, but only when you ask.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Version](https://img.shields.io/badge/version-2.0.0-indigo)
![Claude Code](https://img.shields.io/badge/Claude%20Code-skill%20%2B%20plugin-0f7f74)
![Self-test](https://img.shields.io/badge/self--test-95%2F95%20passing-success)

Created by **Sami Hussain** · [x8code.com](https://x8code.com) · samihussain9t9@gmail.com

![Review mode output: the scan of a change, with HIGH and WARN findings](docs/images/review-scan.png)

---

## Benefits

| Without safe-ai-coding | With safe-ai-coding |
| --- | --- |
| The agent installs packages, runs migrations or pushes without warning | It stops first and tells you what could go wrong, whether it can be undone, and a safer option |
| AI invents methods, routes, views and imports that do not exist | New code is checked: every referenced class, method, view, route and import must exist |
| `// ... rest of the code unchanged` silently deletes real code | Placeholders and pasted chat text are flagged as HIGH |
| SQL injection, leaked keys and missing ownership checks slip into reviews | 60+ security checks run on every change, in any language |
| Hidden instructions in a dependency's `CLAUDE.md` can steer the agent | Repositories are scanned for injection text, malicious git config, hooks and hidden unicode before work starts |
| "Tested, works!" with nothing actually run | The agent must report exactly what it ran and what it did not |
| No record of what was fixed | A polished PDF report on request: the problem, the root cause, the fix, the evidence |

**Who it is for:**

- Developers using Claude Code every day
- Teams that let AI write production code
- Reviewers and security teams who want AI changes held to the same standard as human ones

## Installation

**Option 1: Claude Code plugin (recommended).** Type these inside Claude Code:

```
/plugin marketplace add sami-hussain-dev/safe-ai-coding
/plugin install safe-ai-coding@safe-ai-coding
```

**Option 2: one git command.**

macOS, Linux or Git Bash:

```bash
git clone --depth 1 https://github.com/sami-hussain-dev/safe-ai-coding.git ~/.claude/skills/safe-ai-coding
```

Windows PowerShell:

```powershell
git clone --depth 1 https://github.com/sami-hussain-dev/safe-ai-coding.git "$env:USERPROFILE\.claude\skills\safe-ai-coding"
```

Restart Claude Code, or run `/reload-plugins`. Use one option, not both.

**Check it works:** type `/safe-ai-coding:safe-ai-coding self-test` in Claude Code. You should see `95 passed, 0 failed`.

| Task | Plugin | Git |
| --- | --- | --- |
| Update | `/plugin` → Marketplaces → safe-ai-coding → Update | `git -C ~/.claude/skills/safe-ai-coding pull` |
| Remove | `/plugin uninstall safe-ai-coding@safe-ai-coding` | delete the folder |

**Requirements:**

- Claude Code
- `git` and `bash`. On Windows, install Git for Windows, which includes Git Bash and Perl.
- Optional: Chrome or Edge, for PDF reports.

## Usage

Just ask Claude Code for the work in your own words; the skill loads by itself. To pick a mode:

| When | Type | You get |
| --- | --- | --- |
| You just cloned a project | `/safe-ai-coding:safe-ai-coding scan` | Anything that could trick or attack the agent |
| You want a feature or a fix | just ask, or `/safe-ai-coding:safe-ai-coding build <task>` | Careful code in your project's style, then an automatic review |
| Before you merge | `/safe-ai-coding:safe-ai-coding review main` | A findings table and a verdict: Ready, Ready with notes, or Not ready |
| You need a document | "Give me a PDF report of this work" | A PDF: what was wrong, what was fixed, the proof |
| After installing or updating | `/safe-ai-coding:safe-ai-coding self-test` | Proof that every check works on your machine |

## Screenshots

**The agent asks before anything risky, and explains the harm:**

![Permission request: what, why, possible harm, reversible, safer option](docs/images/permission-request.png)

**Scan mode: a poisoned instruction file inside `vendor/` and an auto-approve setting, found before any work starts:**

![repo-scan output finding prompt injection in a dependency and bypassPermissions](docs/images/repo-scan.png)

**The PDF report, made only when you ask:**

![First page of an example change report](docs/images/report-example.png)

**The self-test (excerpt): AI view, human view, safety and report checks:**

![self-test output, all PASS](docs/images/self-test.png)

## Tested examples

Every example below was run, and its output is real.

**1. A change with typical AI mistakes** (the demo store in the first screenshot). One scan found:

| Found | Severity |
| --- | --- |
| SQL built from `req.params` | HIGH |
| `// ... rest of the code remains unchanged` | HIGH |
| A migration that drops a column, with no `down()` | HIGH + WARN |
| A new `postinstall` hook | HIGH |
| An import of a file that does not exist (`../services/mailer.js`) | WARN |
| An unpinned `"*"` dependency | WARN |
| `catch (e) {}` | WARN |
| A token written to `console.log` | WARN |

**2. Hallucinated symbols in a real Laravel codebase.** Real references (helpers, views, route names, config) produced no findings. Four invented ones were all caught, with hints. This is the output, with the project's own class and helper names replaced:

```
WARN  class App\Models\Feez not found (expected app/Models/Feez.php): hallucinated, misspelled or not created yet
WARN  Helper::listForUser() not found in app/Helpers/Helper.php: hallucinated or misspelled method
WARN  route name 'country-nope' not defined in routes/ (could also come from a package); did you mean 'country-store'?
WARN  view 'country.missing' not found (expected resources/views/country/missing.blade.php)
```

**3. Forty real, human-written commits of a production codebase.**

- **Pattern scan:** three sources of false alarms were found and fixed before release. The remaining warnings were genuine review points.
- **Missing-symbol check:** over 25 commits it reported one finding, and it was a real defect: a class referenced in a commit before its file existed.

**4. A malicious repository.**

- **The attack:** its `.git/config` contained an fsmonitor command, a filter driver and a git hook, each set to create a marker file.
- **The result:**
  - the scanners reported all three
  - `diff-check` refused to run
  - no marker file was ever created
  - a symlink to `~/.ssh/id_rsa` was flagged HIGH

**5. Hostile report input.** Script tags, an `onerror` image, an AWS-style key, a password and an ID number were all escaped or masked in the PDF.

**6. The self-test.** It covers 95 cases:

| Group | Cases | What they prove |
| --- | --- | --- |
| AI view | 59 | Attacks and AI mistakes are caught |
| Human view | 17 | Good code stays quiet |
| Safety | 13 | Hostile repositories are harmless |
| Report | 6 | Reports are escaped, masked and print to PDF |

All 95 pass.

## Limitations

- **It reduces risk; it does not prove code is safe.** The scans are pattern- and file-based. They catch common mistakes, not every mistake, and someone determined to evade them can.
- **It cannot judge business logic.** The build steps make the agent state and test the rule, but a person must still review every change.
- **Symbol checks have limits.** They cover PHP classes and static methods, Laravel views, routes and config files, and JS/TS and Python relative imports. They do not check instance methods, packages outside your project, or dynamic names. Route and view names from packages may be reported as missing.
- **The skill is instructions, not enforcement.** Hard limits belong in `.claude/settings.json` permission rules, CI and access control (see Hardening).
- **It needs `bash` and `git`.** On Windows that means Git Bash. Syntax checks run only for languages whose tools are installed. PDFs need Chrome, Edge, Chromium or wkhtmltopdf; otherwise you get an HTML file to print.
- **Warnings need judgement.** WARN findings are leads for a reviewer to verify, not proof of a bug.

## Hardening (recommended)

```json
{ "permissions": {
    "deny": [ "Read(./.env)", "Read(./.env.*)", "Read(~/.ssh/**)", "Bash(rm -rf:*)", "Bash(git push --force:*)", "Bash(git reset --hard:*)" ],
    "ask":  [ "Bash(git push:*)", "Bash(npm install:*)", "Bash(composer require:*)", "Bash(pip install:*)", "Bash(curl:*)" ] } }
```

In CI, run:

```bash
bash skills/safe-ai-coding/scripts/diff-check.sh --format=tsv --fail-on=warn origin/main
```

## Why it matters

- **45%** of AI-generated code samples failed security tests in a 2025 study ([Veracode, Jul 2025](https://www.veracode.com/blog/genai-code-security-report/)).
- Code models invented **205,474** unique package names that do not exist ([USENIX Security 2025](https://arxiv.org/abs/2406.10279)).
- **Prompt injection** is the number-one risk in the OWASP Top 10 for LLM Applications 2025 ([OWASP LLM01](https://genai.owasp.org/llmrisk/llm01-prompt-injection/)).
- Hidden unicode in agent rules files can carry invisible instructions ([Pillar Security, Mar 2025](https://www.pillar.security/blog/new-vulnerability-in-github-copilot-and-cursor-how-hackers-can-weaponize-code-agents)).

## Documentation

- [Quick start guide (PDF)](docs/safe-ai-coding-quick-start.pdf)
- [Complete guide, English (PDF)](docs/safe-ai-coding-complete-guide.pdf)
- [Complete guide, Roman Urdu (PDF)](docs/safe-ai-coding-complete-guide-roman-urdu.pdf)
- [Example report, English (PDF)](docs/report-example-en.pdf), and the [Roman Urdu example](docs/report-example-ur.pdf)
- [SKILL.md](skills/safe-ai-coding/SKILL.md): the exact rules the agent follows

## FAQ

**How do I make Claude Code safer?**
Install safe-ai-coding, and add permission rules in `.claude/settings.json` for commands that must never run without asking.

**Can it detect AI hallucinations in code?**
Yes. It checks that the classes, static methods, views, routes, config files and imports used in new code exist in your repository.

**Does it protect against prompt injection?**
Yes. Content is treated as data, never as orders, and instruction files (also inside dependencies) are scanned for hidden or malicious instructions.

**Does it send my code anywhere?**
No. Everything runs locally, and it never executes code from the repository it checks.

**Does it replace human code review?**
No. A person should still approve every change.

**Is it free for commercial use?**
Yes, under the MIT license.

## Author

**Sami Hussain** · [x8code.com](https://x8code.com) · samihussain9t9@gmail.com

Suggestions and bug reports are welcome: [open an issue](https://github.com/sami-hussain-dev/safe-ai-coding/issues). For security issues, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Sami Hussain, x8code.com

<!-- Keywords: Claude Code skill, Claude Code plugin, Claude Code guardrails, Claude Code security, AI coding agent safety, AI code review, AI guardrails, prompt injection protection, hallucinated code detection, LLM security, secure coding, supply chain security, vibe coding safety -->
