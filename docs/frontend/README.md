# `docs/frontend/` — frontend specification

The specification for Letflow's React SPA (`web/`). Migrated from R-Co on
2026-08-21 together with the code it describes — see
[`../migration/decisions/0011-frontend-ownership.md`](../migration/decisions/0011-frontend-ownership.md).

| File | What it is | R-Co origin |
|---|---|---|
| [`frontend-requirements.md`](frontend-requirements.md) | The consolidated spec: 7 non-functional requirements (`FNFR-01..07`), constraints, and every UI requirement grouped by area | `docs/BPM_Platform_Frontend_Requirements.md` |
| [`design-system.md`](design-system.md) | Pointer to `docs/design-system/` and the design repo (old text retired) | `docs/guides/frontend_design_system.md` |
| [`requirements/`](requirements/) | 66 per-requirement files, one per UI requirement ID | `docs/requirements/{ADM-UI,DLQ-UI,IN-UI,PD-UI,SH,TK-UI,WH-UI}-*.md` |

## Requirement families

| Prefix | Area | Count |
|---|---|---|
| `SH` | Application shell — nav, tenant header, error boundary, connectivity | 7 |
| `PD-UI` | Process Designer — the React Flow canvas, node palette, validation | 19 |
| `IN-UI` | Instance Board and instance detail — timeline, history scrubber, tokens | 10 |
| `TK-UI` | Task Inbox — claim, complete, dynamic forms, mobile operability | 10 |
| `ADM-UI` | Admin — users, groups, tokens, audit, health, metrics, onboarding | 11 |
| `DLQ-UI` | Dead-letter queue browsing and replay | 5 |
| `WH-UI` | Webhook subscriptions and delivery attempts | 4 |

## How these IDs relate to Letflow's own requirement IDs

They don't, and deliberately so. These are **R-Co's** requirement IDs, kept
verbatim so the spec stays diffable against R-Co and so the ID in a test name
(`TC-ENV04-08`, `GRD-UI-07 §12.4`) still resolves to a document. Letflow's own
work packages live in [`../requirements.yaml`](../requirements.yaml) as
`REQ-NNN` entries; an S8 requirement that implements or verifies one of these
cites the UI ID in its `description`, the same way S1–S7 requirements cite R-Co
`src/` paths.

Treat this directory as **the specification of what the frontend is supposed to
do**, not as a work queue.

## Accuracy warning

These documents were written against R-Co and were not all kept current there.
The old `design-system.md` claim that colours live in `web/src/styles/tokens.css`
was false when this was written; since then the design system landed (generated
`tokens.css`, see [`../design-system/README.md`](../design-system/README.md)) and
`design-system.md` is only a pointer.

The stack line's version claim ("React 19") was known-false; `REQ-119` corrected it to **React 18.3.1**, the version
actually locked in `web/package-lock.json`.

`web/README.md`'s "Known drift" section is the current list. Fixing further
drift — either by correcting a doc or by building what it describes — is S8
requirement work. **Nothing here was silently edited during the migration**; the
files are as R-Co had them, so that a later reconciliation has an honest
baseline to diff against. This directory's own docs may now diverge from that
frozen baseline as individual drift items get resolved — see each requirement's
status in `../requirements.yaml`.
