# 0087 — How `mes_core` posts to the stock ledger without a third copy of the posting code

Status: **DRAFT, not accepted** (2026-11-13, T-1835). Specification only: no code, no migration, no manifest change, no test. Owner answer A.4 of 2026-11-13: the
posting-kernel decision record comes before any phase 1 booking. **REVIEWER sign-off: PENDING. SECURITY-REVIEWER sign-off: PENDING.** The number 0087 was the
next free one on origin/main at writing (0086 is the highest; re-check before merge).

Sources: `docs/design/core-extraction-design.md` sections 1, 3, 6, 7; `docs/design/mes/05-platform-options.md` sections 4.2, 4.6; `docs/design/mes/09-ledger-proof-P1.md`,
`10-batch-slice-P2.md`, `12-core-decisions-for-owner.md`; `docs/design/mes/13-phase1-plan.md`; `lib/letflow/modules/write_handler_spec.ex` (`posts_ledger`);
`lib/letflow/ledger/handler_post.ex`; `lib/letflow/modules/ledger_registration.ex` (one `posting_guard` slot); `lib/letflow/modules/stock/stock.ex` (registration and handlers);
`lib/letflow/modules/manifest_hash.ex`. Decisions 0073, 0079, 0080 are read, not changed.

## Problem

`mes_core` must move stock: consume raw lots into a batch and produce a finished lot from it. Today two modules (`assets`, `stock`) carry about 1000 shared lines of document and posting code
(core-extraction s0, rows 6 to 13). A third module that copies it is the risk named in `05` s4.6. Reading the catalog code shows a harder fact: a write handler's `posts_ledger` is the name of a
registration "of the **same manifest's** `:ledger` map" (`WriteHandlerSpec` moduledoc; `Letflow.Modules.Catalog` rule 10 checks the name). A `mes_core` handler therefore cannot post to the `stock` ledger.

## Decisions (proposed)

### D1. Where the two posting handlers live

Options: (a) in `stock`, next to the ledger registration; `mes_core` calls them. (b) a separate ledger `mes` owned by `mes_core`. (c) change Catalog rule 10 so a manifest may name another module's registration.

**Proposed: (a).** Reasons: (b) cannot consume stock lots, because balance keys of one ledger are not visible to another, so MES would hold a second copy of the stock and the owner's trace question (raw lot to finished lot to shipment) would span two ledgers.
(c) widens a core rule that decision 0073 set, touches the authority check of every handler and needs its own security review; not needed for phase 1. (a) keeps one registration, one hash surface, one guard.
Cost: `stock` gets two handlers and two causes (task S1) and a version bump. **To verify before any code (guess today):** that a process definition of `mes_core` may call a handler named in `stock` (the resolution in `Letflow.Definitions.ModuleWrites`). If it may not, this record is amended (option c, or a narrow "call a dependency's handler" rule) before task M4.

### D2. What is shared and what is not

Nothing of `Letflow.Modules.Stock.Documents` is copied or moved. The batch is a record with a status flow, not a document kind with draft and issue, so `mes_core` needs no document-kind behaviour. The two handlers use the core
`Letflow.Ledger.HandlerPost` only. The kernel extraction (core-extraction s6, row "Kernel", s7 questions) stays HELD and is **not** decided here; this record only ensures MES adds no copy to what is waiting for it.

### D3. Shared policy helpers

The new causes are two clauses in `Letflow.Modules.Stock.LedgerPolicy`, built from the helpers it already uses (`Letflow.Ledger.Policy`). The policy allowlist (the pure-module scan of `mix letflow.check_boundaries`) is not widened. The batch reference travels in the existing header field `related_document_id` (P1 did this, doc 09 s3).

### D4. Handler code and the hash

New handler names change the manifest hash (handler `name`, module, function, `targets`, `args`, `posts_ledger` are hashed, `manifest_hash.ex`). Both new causes and the version bump are one module version of `stock` per task, a U1 plan and a U2 apply on every installed QA tenant
(step-less, P1 U1/U2 **[V]**). Existing handlers do not move (no hash change for them). Demo and production are not touched by this record; see plan 13 section 12, caveat C1.

### D5. One guard, composed

The lot hold rule and the count freeze share the single `posting_guard` slot. One module `Letflow.Modules.Stock.PostingGuard` calls the freeze check first, then the lot rule (P1 did this, doc 09 s6.2). The rule is off while the stock setting `lot_hold_enabled` is false. A guard error or a missing column fails closed.
This is a hash change (the `ledger` map names the guard), covered by D4.

### D6. Proof of neutrality

Before S1 merges: a canary of 21 commands (11 valid, 10 invalid) over every old cause, with literal expected answers produced from origin/main before the change (doc 09 E1 shape); the golden hash moved on purpose; posting and reversal of every old document kind through the real HTTP routes
give the same ledger rows, document rows and audit entries as before (D-098 golden comparison, core-extraction s7 point 5); old ledger entries still reconcile (P1 L6).

### D7. Security review

Tenant-data paths: the guard reads `catalog_lot.quality_status` and `location_node.customer_location` by tenant prefix only (INV-1, INV-6); typed binds (INV-7); fail closed (INV-8); a refusal shows only the status word, never lot code or note, and an unknown lot is refused as before (INV-2, INV-5). The handlers take the tenant from the token; no tenant identifier in a body (INV-10).
A cross-tenant negative test is a condition of S1 and S2. The status writer takes the exclusive hold of the `stock` ledger so release and posting serialize (P1 L10).

## Not decided here

* The extraction of the shared document and posting kernel (core-extraction s7, all six questions).
* Cross-module `posts_ledger` (option c): rejected for phase 1, may be revisited when a third ledger user needs it.
* Who may release a lot, four-eyes, e-signature (owner questions of doc 12).
* Whether the hold rule list is final (a guess, doc 09 s5).
* Any change to demo or production.

## Later work

Tasks S1, S2, M4, M5 of `docs/design/mes/13-phase1-plan.md`. A requirement entry per task is written by the BA before each build task.
