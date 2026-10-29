# Building AI and LLM features safely

Use this list when the change adds or touches an AI feature: chat, summaries, classification, extraction, embeddings or search, agents or tool calling. The checklist follows the OWASP Top 10 for LLM Applications (2025); the review scan catches some of it automatically.

## 1. Prompt injection (LLM01)

- Treat everything that reaches the model from outside as untrusted: user messages, uploaded files, web pages, emails, database rows written by users, and tool results.
- Never build the **system** prompt from user input. Put user content in a clearly separated user message. Tell the model it is data.
- Do not give the model a capability you would not give the person who wrote the input.

## 2. Sensitive information disclosure (LLM02)

- Send the provider only what the task needs:
  - no passwords, tokens or keys
  - no full documents when a summary of fields will do
  - no national ID or card numbers
- Personal data needs the user's consent and a provider whose terms fit (data retention, training opt-out, region).
- Never put secrets in the prompt or the system prompt; the model can repeat them.
- Do not log full prompts and responses if they can contain personal data. If you must log them, mask them and expire them.

## 3. Supply chain (LLM03)

- Pin model names and SDK versions.
- Download models and datasets only from their official source, and verify checksums where they are offered.

## 4. Improper output handling (LLM05)

Model output is untrusted input. Never pass it to any of these:

- `eval`, `exec` or a shell
- SQL, without bound parameters
- `innerHTML`, `{!! !!}` or `dangerouslySetInnerHTML`, without escaping
- a file path
- a redirect
- a URL the server will fetch

Validate structured output (JSON) against a schema before using it.

## 5. Excessive agency (LLM06)

- Give tools the least power that works:
  - read-only where possible
  - scoped to the current user's data
  - an allowlist of actions
- Destructive or costly actions need a human confirmation step: deleting, paying, sending email, changing permissions.
- The tool layer checks authorisation on every call. Never trust the model to decide who may do what.

## 6. System prompt leakage (LLM07)

Assume the system prompt will be read by users. Put nothing in it that is secret or that grants access.

## 7. Vector and embedding weaknesses (LLM08)

- Filter retrieval by the current user's permissions (tenant and owner) in the query itself, before the results reach the model.
- Content from other tenants must never be retrievable.

## 8. Misinformation (LLM09)

- Show sources for factual answers.
- Do not let model output alone decide money, health, legal or exam outcomes; a person or a deterministic rule decides.

## 9. Unbounded consumption (LLM10)

- Every call has a timeout, a maximum token count, a rate limit per user and a monthly spending cap.
- Cache repeated requests.
- Reject inputs over a size limit before calling the provider.

## Keys and configuration

- Provider keys live in server-side configuration only. They never go in frontend code, mobile apps or `VITE_`, `NEXT_PUBLIC_` or `REACT_APP_` variables.
- Use separate keys per environment, and rotate a key at once if it ever appears in a commit, a log or a chat.
