# Report format (report mode)

Report mode runs **only when the user asks**. The agent writes one JSON file with the facts of the session. `scripts/make-report.pl` turns it into a print-ready HTML page, and `scripts/html-to-pdf.sh` prints that page to PDF.

```bash
perl "<skill>/scripts/make-report.pl" report.json report.html [--lang=en|ur]
bash "<skill>/scripts/html-to-pdf.sh" report.html report.pdf
```

Full examples are in `templates/report-example.json` (English) and `templates/report-example-ur.json` (Roman Urdu).

## Fields

`title`, `summary`, `problems` and `fixes` are required; everything else is optional, and an empty section is left out.

| Field | Type | Meaning |
| --- | --- | --- |
| `language` | `"en"` or `"ur"` | Labels in English or Roman Urdu. Write the text fields in the same language |
| `title` | string | One line: the problem in plain words ("Fee discount applied twice") |
| `status` | `"fixed"`, `"partial"` or `"open"` | Overall result |
| `project`, `branch`, `commit`, `date`, `prepared_by`, `requested_by` | string | Header details. `date` as `YYYY-MM-DD` |
| `summary` | string | Three to five sentences for a non-technical reader: what was wrong, who it affected, what changed, how it was checked |
| `problems[]` | object | `id` (`P1`), `title`, `severity` (`critical`, `high`, `medium`, `low` or `info`), `where` (file:line or area), `symptom` (what people saw), `root_cause` (why it happened), `impact` (who or what was affected, with numbers if known), `evidence` (how we know), `found_by` (`ai`, `human`, `scan`, `test` or `user`) |
| `fixes[]` | object | `id` (`F1`), `title`, `fixes` (problem ids), `change` (what changed), `why_correct`, `files[]`, `before` / `after` (short code snippets from `git diff`), `code_language` |
| `verification[]` | object | `check`, `perspective` (`ai`, `human` or `both`), `result` (`pass`, `fail`, `partial` or `not-run`), `detail` |
| `scans` | object | `before` and `after`, each `{high, warn, info}` from `diff-check.sh`, plus a `note` |
| `approvals[]` | object | The permission log: `action`, `harm`, `decision` (`approved`, `declined` or `safer-option`), `when` |
| `files_changed[]` | object | `path`, `added`, `removed` (from `git diff --numstat`) |
| `remaining_risks[]`, `next_steps[]` | string | What is still open and what should happen next |

## Writing it well

- **Facts only.** Every sentence comes from this session, the repository or the user. A missing fact stays missing; never guess numbers.
- **Problem before fix.** Each problem names its symptom (what people saw) and its root cause (why). "The discount was applied in both the controller and the model" is a root cause; "the total was wrong" is only the symptom.
- **Evidence for every claim:** the test that failed before and passes now, the query result, the scan count.
- **Plain language** in `summary`, `symptom` and `impact`; technical detail in `root_cause`, `change` and the snippets.
- **Short snippets:** the few lines that show the change, not whole files.
- **Honest verification:** list what was not run as `not-run`.
- **No secrets or real personal data.** The renderer masks common key formats, `password = '...'`-style values and ID-number patterns, but write the JSON as if it did not.
- Keep the JSON and HTML outside the repository unless the user wants them committed.
