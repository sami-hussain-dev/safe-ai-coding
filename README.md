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

---

## Install (2 minutes)

**Option 1: as a Claude Code plugin (recommended).** Type these inside Claude Code:

```
/plugin marketplace add sami-hussain-dev/safe-ai-coding
/plugin install safe-ai-coding@safe-ai-coding
```

**Option 2: with git.** Run one command in a terminal.

macOS, Linux or Git Bash:

```bash
git clone --depth 1 https://github.com/sami-hussain-dev/safe-ai-coding.git ~/.claude/skills/safe-ai-coding
```

Windows PowerShell:

```powershell
git clone --depth 1 https://github.com/sami-hussain-dev/safe-ai-coding.git "$env:USERPROFILE\.claude\skills\safe-ai-coding"
```

Then start a new Claude Code session, or run `/reload-plugins`. Use one option, not both.

| Task | Plugin | Git |
| --- | --- | --- |
| Update | `/plugin` → Marketplaces → safe-ai-coding → Update | `git -C ~/.claude/skills/safe-ai-coding pull` |
| Remove | `/plugin uninstall safe-ai-coding@safe-ai-coding` | delete the folder |

**Requirements:**

- Claude Code
- `git` and `bash`. On Windows, install Git for Windows, which includes Git Bash and Perl.
- Optional: Chrome or Edge, for PDF reports.

## Use it

You do not need to learn anything new. Ask Claude Code for the work in your own words, and the skill loads by itself. To pick a mode, use the command (as a plugin it is namespaced):

| When | Type | You get |
| --- | --- | --- |
| You just cloned a project | `/safe-ai-coding:safe-ai-coding scan` | Anything that could trick or attack the agent |
| You want a feature or a fix | just ask, or `/safe-ai-coding:safe-ai-coding build <task>` | Careful code in your project's style, then an automatic review |
| Before you merge | `/safe-ai-coding:safe-ai-coding review main` | A findings table and a clear verdict |
| You need a document | "Give me a PDF report of this work" | A polished PDF: what was wrong, what was fixed, the proof |
| After installing or updating | `/safe-ai-coding:safe-ai-coding self-test` | Proof that every check works on your machine |

## Features

- **Permission gate.** The agent stops before:
  - installs and database writes
  - deleting files, git pushes and history rewrites
  - reading secrets or sending data out
  - changing agent config or weakening security

  It says what it will run, where, the possible harm, whether it can be undone, and a safer option. Then it waits for your yes.
- **AI mistake detection.** It flags:
  - hallucinated classes, methods, routes, views, config files and imports
  - `// ... rest of the code unchanged` placeholders
  - pasted chat text and merge conflict markers
  - weakened or skipped tests
- **Security review.** It looks for:
  - SQL, command and path injection; SSRF; XSS; open redirects
  - unsafe deserialisation; XXE; TLS or JWT checks switched off
  - weak crypto; mass assignment
  - leaked keys, tokens and real ID numbers
  - passwords in logs
- **Data safety.** It flags:
  - `DROP`, `TRUNCATE`, `DELETE`/`UPDATE` without `WHERE`
  - destructive migrations
  - transactions without rollback
  - removed auth checks
  - N+1 queries
- **Supply chain.** It flags install hooks, unpinned or URL dependencies, custom registries and lock files that point to other hosts.
- **Agent protection.** It scans for:
  - prompt-injection text in `CLAUDE.md`, `AGENTS.md`, and Cursor and Copilot rules, including inside `vendor/` and `node_modules/`
  - malicious `.git/config`, hooks and filters
  - symlinks to your private keys
  - hidden unicode (Trojan Source and Rules File Backdoor)
- **Two-lens review.** Every change is read for how AI code fails, and as the teammate and business owner will see it. The verdict is Ready, Ready with notes, or Not ready.
- **PDF reports on request.** In English or Roman Urdu. Secrets are masked, the page has no scripts, and nothing is loaded from the network.
- **Your project's rules.** Add conventions and custom red-flag rules: per line, per file, or "changing X requires changing Y".
- **Safe on untrusted code.** It never executes repository code, git-configured programs, hooks or symlinked files.
- **Proven.** A built-in self-test runs 95 cases: attacks caught, good code left alone, malicious repositories harmless.
- **Any stack.** PHP/Laravel, JavaScript/TypeScript, Python, Java, C#, Go and Ruby.

## Why it matters

- In a 2025 study, **45%** of AI-generated code samples failed security tests ([Veracode, Jul 2025](https://www.veracode.com/blog/genai-code-security-report/)).
- Code models invented **205,474** unique package names that do not exist ([USENIX Security 2025](https://arxiv.org/abs/2406.10279)). Attackers can register such names.
- **Prompt injection** is the number-one risk in the OWASP Top 10 for LLM Applications 2025 ([OWASP LLM01](https://genai.owasp.org/llmrisk/llm01-prompt-injection/)).
- Hidden unicode in agent rules files can carry invisible instructions ([Pillar Security, Mar 2025](https://www.pillar.security/blog/new-vulnerability-in-github-copilot-and-cursor-how-hackers-can-weaponize-code-agents)).

## Documentation

- [Quick start guide (PDF)](docs/safe-ai-coding-quick-start.pdf): 2 minutes, for everyone
- [Complete guide, English (PDF)](docs/safe-ai-coding-complete-guide.pdf)
- [Complete guide, Roman Urdu (PDF)](docs/safe-ai-coding-complete-guide-roman-urdu.pdf)
- [Example report (PDF)](docs/report-example-en.pdf), and the [Roman Urdu example](docs/report-example-ur.pdf)
- [SKILL.md](skills/safe-ai-coding/SKILL.md): the exact rules the agent follows

## FAQ

**How do I make Claude Code safer?**
Install safe-ai-coding. Then add permission rules in `.claude/settings.json` for commands that must never run without asking. The skill handles judgement; the settings give hard limits.

**Can it detect AI hallucinations in code?**
Yes. It checks that the classes, static methods, views, routes, config files and imports used in new code exist in your repository.

**Does it protect against prompt injection?**
Yes. Everything the agent reads is treated as data, never as orders. Instruction files are scanned for hidden or malicious instructions.

**Does it send my code anywhere?**
No. Everything runs locally, and it never executes code from the repository it checks.

**Does it replace human code review?**
No. It makes AI-written code much safer, but a person should still approve every change.

**Is it free for commercial use?**
Yes. It is under the MIT license.

## Hardening (recommended)

Add hard limits in `.claude/settings.json`:

```json
{ "permissions": {
    "deny": [ "Read(./.env)", "Read(./.env.*)", "Read(~/.ssh/**)", "Bash(rm -rf:*)", "Bash(git push --force:*)", "Bash(git reset --hard:*)" ],
    "ask":  [ "Bash(git push:*)", "Bash(npm install:*)", "Bash(composer require:*)", "Bash(pip install:*)", "Bash(curl:*)" ] } }
```

In CI, run:

```bash
bash skills/safe-ai-coding/scripts/diff-check.sh --format=tsv --fail-on=warn origin/main
```

## Author

**Sami Hussain** · [x8code.com](https://x8code.com) · samihussain9t9@gmail.com

Issues and suggestions are welcome: [open an issue](https://github.com/sami-hussain-dev/safe-ai-coding/issues).

## License

[MIT](LICENSE) © 2026 Sami Hussain, x8code.com

<!-- Keywords: Claude Code skill, Claude Code plugin, AI coding agent safety, AI code review, AI guardrails, prompt injection protection, hallucinated code detection, LLM security, secure coding, supply chain security, vibe coding safety, AI pair programming, Laravel security, code review automation -->
