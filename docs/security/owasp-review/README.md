# OWASP Top 10 self-review by route family

Internal, static self-review of Letflow's HTTP routes against the OWASP Top 10 (2021), one checklist per route family.
Source: item 10 of `docs/uat/ba-decisions/T-1582.md`. It is **not** a penetration test (no running instance was attacked),
it is **not for publication**, and it is **not a production sign-off**: publishing or handing over any result, and any
production approval, are the owner's decision.

## Parts

The item is sized L and says "split in three", so the six families are reviewed in three parts.

| Part | Families | File | Status |
|---|---|---|---|
| 1 | identity and tokens; admin and platform routes | `part-1-identity-admin.md` | done in T-1590 |
| 2 | documents and registers; assets and stock | `part-2-*.md` (not yet written) | not started; cite BA#8 (#4082) for asset and stock tenant isolation instead of redoing it |
| 3 | definitions and scripts; files and import | `part-3-*.md` (not yet written) | not started; INV-3 sandbox, INV-9 outbound URLs, zip and xlsx size caps |
| 4 | follow-up: routes added since B3#10 (reset-password, users import, rollout window and operator screen, sign-up, replay timeline) | `part-4-followup-new-routes.md` | done in T-1693; F4-1 fixed, rest listed |

## Method

Every row of a checklist names one OWASP category, how it was checked (a command, a named test or a function that was read)
and a result. Results are exactly `ok`, `finding F1-n` (a finding in the same part file) or `n/a <reason>`.
Findings list severity (high, medium, low), file and symbol, the invariant from
`docs/agents/instructions/security-invariants.md` they break (or the nearest one), the failure scenario and a one-sentence fix.
Findings are recorded here, not fixed: each fix is a separate, security-reviewed change. The team files no issues; the
operator queues the medium and high findings from the task's step output.

Evidence is static: `git grep`, reading the named function, `mix hex.audit`, `npm audit --package-lock-only`. Where a row
could only be partly checked, the "Checked how" cell says what was not covered and the part file's "Not reviewed" list
repeats it. "ok" means "no problem found by the stated check", not "proven secure".

## OWASP category to invariant

| OWASP 2021 | Meaning used here | Base invariant |
|---|---|---|
| A01 Broken access control | route authorisation, tenant isolation, platform authority | INV-1, INV-2, INV-5, INV-10 |
| A02 Cryptographic failures | token storage, comparison, secrets in logs and responses | INV-4 |
| A03 Injection | SQL, command, template injection on the family's inputs | INV-7 |
| A04 Insecure design | missing guards, lockout, replay, abuse of intended flows | INV-8 and the architecture rules |
| A05 Security misconfiguration | defaults, CORS, unauthenticated routes, exposed information | INV-9 and config |
| A06 Vulnerable and outdated components | advisories on dependencies | none (new check; global result in part 1) |
| A07 Identification and authentication failures | token verification, rate limits, enumeration | INV-10 |
| A08 Software and data integrity failures | trusting claims before local state, unsigned data | INV-3 |
| A09 Logging and monitoring failures | audit entries, denial logging, no secrets in logs | audit |
| A10 Server-side request forgery | tenant-controlled outbound URLs | INV-9 |

## Earlier work this review builds on

- B2#6 hardening (#4096): auth rate limits and logout; runbook `docs/runbooks/auth-rate-limits.md`.
- BA#8 (#4082): asset and stock tenant isolation (parts 2).
- Platform scope separation guards G0..G4 in `test/letflow/api/platform_scope_inventory_test.exs`.
- Decision 0036 (markdown sanitisation dependency) for parts 2 and 3.
