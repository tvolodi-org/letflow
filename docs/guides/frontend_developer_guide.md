# Letflow — Frontend Developer Guide

**Audience:** `FRONTEND-DEV`, `CODE-DESIGNER` (when a design touches the API contract
`web/` consumes), `TEST-DESIGNER`, `REVIEWER`.

**Rewritten 2026-08-21.** This guide used to open by telling you your scope was
narrower than the title implied, because Letflow did not own a frontend codebase. That
is no longer true: R-Co's `web/` was migrated into this repository and Letflow owns it —
see [`../migration/decisions/0011-frontend-ownership.md`](../migration/decisions/0011-frontend-ownership.md).
If you find text anywhere in this repo saying `web/` is out of scope to rewrite, or that
your job is only config and CORS, it is stale and predates that decision.

Your scope is now the SPA itself: its components, its types, its tests, and the
integration boundary to Letflow's API.

---

## 1. What you are working on

`web/` — React 18.3.1 + TypeScript 5 + Vite (React version as locked in
`web/package-lock.json`). Start with
[`../../web/README.md`](../../web/README.md): it has the layout, the scripts, the
verified state at migration, and the known drift carried over from R-Co.

The specification lives in [`../frontend/`](../frontend/): the consolidated
requirements (`FNFR-01..07` plus every UI requirement), the design system, and 66
per-requirement files. Those carry **R-Co's** requirement IDs (`TK-UI-02`, `PD-UI-14`,
`SH-03`, …) on purpose — a test name like `GRD-UI-07 §12.4` has to resolve to a
document. Letflow's own work packages are `REQ-NNN` in
[`../requirements.yaml`](../requirements.yaml).

`docs/frontend/` tells you what the frontend is *supposed* to do. It is not a work
queue, and parts of it describe things that were never built — see §6.

## 2. Running and checking it

```
cd web
npm ci
cp .env.example .env.local
npm run dev            # :5173, proxies /api and /health to :4000
```

Four quality commands, all of which must pass before you hand off:

| Command | Gate |
|---|---|
| `npm run type-check` | `tsc --noEmit` |
| `npm run lint` | ESLint at `--max-warnings 0` |
| `npm test` | vitest — 30 files, 178 tests as migrated |
| `npm run guards` | the static-analysis specs; runs a full `vite build` |

Quote real output. "The build passed" is not a result; the terminal output is.

`npm run test:e2e` (Playwright, 37 specs) needs a live backend and a Keycloak realm.
It has never run against Letflow — establishing what can run is `REQ-122`.

## 3. The guard suite

`web/tests/guards/` is the frontend's structural equivalent of the backend's
producer/validator pairing. It scans source and the built bundle against one pattern
list in `web/tests/guards/forbidlist.ts`, and it is why a weak model can change this
codebase without a human reading the diff:

- no mock HTTP adapters (`msw`, `axios-mock-adapter`) anywhere;
- no raw `fetch()` or `axios()` outside `web/src/api/client.ts`;
- no `window.confirm` / `alert` / `prompt`;
- no inline query keys or inline stale times — they belong in `api/queryKeys.ts`;
- no tenant slug hardcoded in source;
- no `.only` / `.skip` left behind;
- no query without a `QueryStateBoundary`.

**If your change trips a guard, your change is probably wrong.** Weakening a pattern to
make it pass inverts the entire point of the mechanism. If a pattern is genuinely wrong,
that is a REVIEWER conversation with a recorded rationale — not an edit you make on the
way past. Add to `forbidlist.ts` when you find a new class of mistake, the same way
[`../anti-patterns.md`](../anti-patterns.md) works on the backend.

## 4. Rules that survived the re-scope

These were the old guide's core and they are still right — they were never about
ownership, they were about not papering over backend problems in the client:

1. **A contract gap is closed on the Letflow side.** If `web/` expects a field, a status
   code, or a pagination cursor that Letflow's API doesn't produce, route it to
   CODE-DESIGNER → ELIXIR-DEV. Do **not** add a shim or adapter inside `web/` that
   normalises the mismatch — that hides the gap from every other client, including the
   mobile tier that will consume the same contract.
2. **A CORS problem is fixed on the Letflow side** (`REQ-118`), never worked around in
   the browser.
3. **Don't silently swap the auth-token storage pattern.** `FNFR-06` forbids tokens in
   `localStorage`/`sessionStorage`. Changing where a token lives is a security-reviewed
   change, not a refactor.
4. **No hardcoded API base URL.** Use the existing env-var pattern; see
   `web/.env.example`.

## 5. What changed about your mandate

You may now add components, change existing ones, add tests, and delete dead code —
gated the same way backend work is. What that means concretely:

- Frontend changes go through the same workflow as `lib/` changes. A change to `web/`
  is **not** exempt from SECURITY-REVIEWER when it touches a tenant-data path (token
  handling, tenant resolution, anything that shapes what one tenant can see).
- Owning the code does not mean the code should change. The drift listed in
  `web/README.md` was recorded rather than fixed on purpose, so the reconciliation has
  an honest baseline. Each item is a sized requirement (`REQ-119`, `REQ-120`, `REQ-121`),
  not a cleanup to do while you are nearby.
- Scope creep is still scope creep. "While I was in there" is how a config requirement
  becomes a component rewrite.

## 6. Known-false statements in `docs/frontend/`

The specification was migrated verbatim and was not all current in R-Co. Colours and
other values now come from the generated `web/src/styles/tokens.css`; read
`docs/design-system/README.md` and `docs/design-system/principles.md` (the old
`docs/frontend/design-system.md` is only a pointer). Legacy inline `style={{...}}` objects
with literal hex values may remain in older pages until they are restyled. (`REQ-119` corrected the other
known-false statement this section used to list — the spec said "React 19"; the code
is React 18.3.1, per `web/package-lock.json`.)

## 7. Self-review checklist

- [ ] `npm run type-check`, `npm run lint`, `npm test`, `npm run guards` all pass, with
      real output quoted
- [ ] No guard pattern was weakened or path-exempted to make the change pass
- [ ] No hardcoded API base URL; no new auth-token storage mechanism
- [ ] Any contract mismatch found was routed to the backend, not shimmed in `web/`
- [ ] Anything touching tenant resolution, token handling, or response shaping is
      flagged for SECURITY-REVIEWER
- [ ] Verified by loading the running app and observing real data, not by a green build
      alone — `test_developer_guide.md`'s Directive T-2 ("real backend, not mocked")
      applies here too
