# Secure coding guardrails

These apply to every line written in build mode. Each section gives the rule, then the usual way to do it in common stacks. When the project already has its own helper for a rule (a scoping helper, an upload helper, a base controller check), use the project's helper; it wins over these examples.

## 1. Access control

- **Authenticate every non-public endpoint.** Use the framework's middleware or guard, applied in the same place the neighbouring routes apply it.
- **Authorise every action.** Check what the user's role may do, not only that someone is logged in. Hiding a button is not authorisation; the server-side check is.
- **Check ownership of every record loaded by an ID from the request (IDOR).** Load the record through the user's scope (`$user->orders()->findOrFail($id)`, `Order.objects.get(id=id, owner=request.user)`), or load it and then check (`$this->authorize('update', $order)`, `if (order.tenantId !== user.tenantId) return 403`).
- **Scope multi-tenant data in the query itself.** Filter by tenant, organisation, branch or institution in the query, never by filtering the results afterwards.
- Answer unauthorised requests the way the project already does (403/404, JSON or redirect), without saying whether the record exists.

| Stack | Typical tools |
| --- | --- |
| Laravel | route middleware, Policies and Gates, `$this->authorize()`, `can:` middleware, Spatie permission |
| Node/Express | auth middleware on the router, per-route role check, query scoped by `req.user` |
| Django | `@login_required`, `PermissionRequiredMixin`, querysets filtered by `request.user` |
| Spring | `@PreAuthorize`, method security, repository methods taking the owner |
| ASP.NET | `[Authorize(Policy = ...)]`, resource-based authorisation handlers |

## 2. Injection

- **SQL:** bound parameters always (`where('col', $v)`, `?` / `:name` placeholders, ORM filters). Never build SQL from strings with values in them. Column names, sort fields and directions from the request go through an allowlist.
- **Shell:** avoid shelling out. If you must, use the argument-array form (`Process::run(['convert', $in, $out])`, `subprocess.run([...])`, `execFile`), never a shell string, and never user input.
- **Paths:** never build a filesystem path from user input. Use generated names, `basename()`, then resolve the path and check it stays inside the allowed folder.
- **Templates and code:** no `eval`, `new Function`, `exec` on strings, and no user input in template source.
- **URLs (SSRF):** a server-side fetch of a URL from the request needs a host allowlist. Block internal addresses and follow no redirects to them.
- **Redirects:** redirect only to internal paths or allowlisted hosts.

## 3. Output and the browser

- Escape by default (`{{ }}`, `{{ value }}`, JSX text). Use raw output (`{!! !!}`, `|raw`, `|safe`, `dangerouslySetInnerHTML`, `v-html`, `innerHTML`) only for markup you built yourself, with any data inside escaped (`e()`, `htmlspecialchars`, `escape`).
- Data inside JavaScript in a template goes through a JSON encoder (`@json`, `json_encode` with `JSON_HEX_TAG`), not string concatenation.
- Keep CSRF protection on for every state-changing request; exempt only signed webhooks, with signature verification.
- CORS: list the origins. A wildcard is never combined with credentials.
- State-changing actions use POST/PUT/PATCH/DELETE, never GET.

## 4. Input

- Validate every input at the boundary: type, length, range, format, allowed values. Use the project's style (Form Request, schema, serializer, DTO).
- **Mass assignment:** pass only validated, allowlisted fields to create/update (`$request->validated()`, `only([...])`, explicit DTOs). Never pass `$request->all()` or `req.body` to an ORM, and never leave `$guarded = []`.
- **File uploads:**
  - check size, extension and the real MIME type
  - generate the stored name
  - store outside the public web root, or in object storage with private access
  - never execute or include an upload
  - use the project's upload helper if it has one

## 5. Secrets and configuration

- No secrets in code, tests, fixtures, logs, error messages or commits. Read them from configuration or a secret store, and keep `.env` out of version control.
- In Laravel, read `env()` only inside `config/`; elsewhere use `config()`, because `env()` returns null once config is cached.
- Never log full tokens, passwords, card numbers or national IDs. Mask them.
- Debug mode stays off outside local development.

## 6. Cryptography and randomness

- Passwords: `password_hash` / bcrypt / argon2 (the framework's hasher). Never MD5, SHA1 or a plain fast hash.
- Tokens, OTPs, reset links, API keys: a cryptographic generator (`random_bytes`, `Str::random`, `crypto.randomBytes`, `secrets.token_urlsafe`). Never `rand`, `mt_rand`, `uniqid` or `Math.random`.
- Compare secrets in constant time (`hash_equals`, `crypto.timingSafeEqual`, `hmac.compare_digest`).
- Keep TLS verification on. Never set `verify=false` or `CURLOPT_SSL_VERIFYPEER=false`, even for a quick test.

## 7. Errors and logging

- No empty `catch`, `except: pass` or `.catch(() => {})`. Handle the error, or log it with context and rethrow.
- Users see a plain message; the log gets the exception. Never return `$e->getMessage()`, stack traces or SQL errors to the client.
- A failure must not report success. Check every return value that signals failure.
- Log security-relevant events (login failures, permission denials, data exports, deletes) the way the project already logs.

## 8. Data safety

- **Transactions:** writes that belong together run in one transaction. Every path (success, validation failure, exception, early return) commits or rolls back. Prefer the closure form (`DB::transaction(fn () => ...)`, `transaction.atomic`) where the project uses it.
- **Races:** anything that hands out something limited or unique (a seat, a roll number, a voucher number, stock, a balance) reads under a lock (`lockForUpdate()`, `SELECT ... FOR UPDATE`, optimistic version column), with a unique index as the last defence.
- **Idempotency:** retries, double-clicks and repeated webhooks must not double-charge or double-insert.
- **Deletes:** follow the project's convention (soft delete flags, `deleted_at`, `deleted_by`, or hard delete). Check for dependent records first.
- **Migrations:**
  - add rather than drop or rename
  - give every migration a working down/rollback
  - never edit a migration that has already run anywhere; write a new one
  - plan backfills for existing rows (nulls, legacy dates, existing text in other encodings)
  - large-table changes are flagged for off-peak runs
- **Dates and text:** store in the project's time zone convention, handle legacy or invalid dates the database may already hold, and keep text UTF-8 end to end (collations, column charsets, file encodings).

## 9. Performance

- No query inside a loop when one query with a join, `whereIn` or eager loading (`with()`, `select_related`, `include`) does the same (N+1).
- Lists page on the server. Never `->get()` / `.all()` a large table into memory.
- New filter, join and sort columns on large tables need an index, or the gap goes in the report.
- Exports and batch jobs work in chunks or a queue.

## 10. Dependencies and supply chain

- Prefer the standard library and the packages already in the project.
- A new package goes through the gate. Before asking:
  - confirm the exact name exists on the official registry and is the well-known one, not a look-alike
  - check it is maintained and the licence fits
  - pin the version and commit the lock file
- Never add install hooks (`postinstall`, composer scripts) without the gate.

## 11. Readability: code a person can maintain

- Match the file: naming, structure, formatting, comment density, idioms, response shapes. Someone reading it should not be able to tell which lines the AI wrote.
- Make functions as small as the codebase's usual size, with names that say what they do. No clever one-liners where the codebase writes plain steps.
- Write a comment only for a *why* that the code cannot show: a business rule, a workaround, a non-obvious constraint. Never narrate what the code does, and never leave notes to the reviewer in the code.
- No dead code, commented-out blocks, unused imports, debug output or placeholder TODOs in the final change.
- One concept, one place: reuse the existing helper rather than writing a near-duplicate, but do not invent a shared abstraction for two lines.
