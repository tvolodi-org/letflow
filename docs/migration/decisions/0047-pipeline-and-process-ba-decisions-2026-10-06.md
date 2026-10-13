# 0047 — BA decisions on pipeline process, review invariant, merge queue and email-first gating (P1..P4, P8, MQ, OQ-3, ordering)

Status: decided by delegation (BA). One item (OQ-3) is a named-accountability marker, not a legal
confirmation: it still has to be confirmed by the named person. This record does not claim
`REVIEWER` or `SECURITY-REVIEWER` sign-off.

Date: 2026-10-06. Owner: `ORCH`. Drafted by `ORCH` from the decisions relayed by the supervisor
session.

Superseded in part by 0049 (`0049-work-board-replaces-letflow-queue.md`): the remote host's "uses the queue and locks" (MQ, line 82-83) and the queue-id keys in P3 are replaced by the GitHub work board; the other decisions stand.

Authority: the user (platform owner) said "All decision or up to business analyst". That
delegation was relayed to `ORCH` by the supervisor session, and is treated here as relayed, not
re-confirmed by the user in this session. Same form as `0043-email-first-login-ba-decisions.md`:
a BA decision note, numbered in the shared decision series, amending by reference only. No
earlier decision record is edited by this one.

Related: `0043-email-first-login-ba-decisions.md`, `0046-admin-scopes-and-role-charter.md`
(the role model; P8 below refers to it), `0004-humanless-pipeline.md`.

## Decisions

### P1. One PR per issue; no docs/chore merges while a functional PR is in CI; batch filings

One pull request per issue or requirement. While a functional PR (one that changes `lib/`,
`web/`, `priv/` or `test/`) is in CI, no docs-only or chore PR is merged into `main`. Issue and
requirement filings (registry, `docs/issues/`, `docs/requirements.yaml`) are batched into one PR
instead of one PR per filing.

Why: a docs or chore merge moves `main` under a functional PR that is mid-CI and forces a rebase
and a CI re-run for no functional reason.

### P2. Overlap check as WF-03 step 0

Before any WF-03 work starts, `ORCH` checks for overlap on four keys: the queue id, the GitHub
issue number, the changed files of every open PR, and `main` (does the fix already exist). A
hit stops the run and is reported.

### P3. Key work on queue id plus GitHub number; next-free-number check at registration

Work items are keyed by queue id plus GitHub issue number, never by an `ISS-` or `REQ-` number
alone (those numbers have been reused). At registration `ORCH` checks the next free `ISS-`, `REQ-`
and decision numbers against `origin/main` and all open PRs, and takes the next free one.

### P4. Failure class per PR; a second failure of the same file or class is a defect

For every PR the CI failure is recorded with its class (compile, format, boundary, test file,
infra). A second failure of the same file or class on the same PR is treated as a defect to be
fixed, not as a flake to be re-run. Local pre-push runs are shaped like CI (same command, same
flags, same env) so a local pass means something.

### P8. New reviewer invariant: platform-vs-tenant authority

`REVIEWER` and `SECURITY-REVIEWER` get one new invariant: any change that grants, checks or
exempts a permission must say whether the permission has platform scope or tenant scope
(`0046` D1, D3) and must show that a platform-scope permission is honoured only for a caller of the
platform tenant. The invariant is INV-10, "platform authority bound to the platform tenant" (INV-9 is taken;
INV-10 lands via `letflow-3`'s rules PR and is not yet on `main`). The invariant text
is NOT written here. It is landed by the `letflow-3` session in the reviewer documentation
(`security-invariants.md` and the reviewer agent files). This record only fixes the intent and the
number.

### MQ. Merge queue

The user confirmed "yes, prepare it and a worker may enable it". Order: `letflow-3` lands the
`ci.yml` `merge_group` trigger change first; the repository setting is enabled only after the
supervisor confirms the workflow change is on `main`.

### OQ-3. Lawful basis for email-first login: the named accountable person

The named accountable person is the platform owner (the user). The user confirms the lawful basis
and controller themself. Until they do, this is recorded as a marker for the REQ-444 gate (the gate
that blocks enabling email-first outside dev); it is not a legal confirmation and no agent may
treat it as one.

### Order of preconditions before email-first login is enabled outside dev

1. QA nginx real-IP configuration (infra task T-0155).
2. SMTP relay with SPF, DKIM and DMARC (infra).
3. Legal confirmation (OQ-3) gates the flag last.

### Remote host `ai-dala-orch`

Silent for about 34 hours at the time of writing. No action. On its return it must use the queue
and locks like every other host (`docs/agents/protocols/TASK_QUEUE.md`).

## Out of scope

The UX navigation requirement is not drafted yet and is not part of this record.

## Conflicts flagged for REVIEWER

None known. `0043` is amended by reference only where it already states the email-first gating;
the ordering above adds sequencing and does not change a ratified decision.
