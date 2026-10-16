# 0058 -- WMS offline readiness: partition, conflict rules and what is built now

Status: Accepted: recommended by the advisor session (letflow-ec) and accepted under the user's delegation, relayed by the supervisor (letflow-supervisor-22) on 2026-10-16 and recorded by letflow-2. Offline execution itself is LATER scope (decision 0057 D2); only part (c) is built now.

Related: 0057 (D2 online first, D13 outage default 3 days), 0051 (scope grants), 0012 (mobile tier stack: offline needs its own decision there when scheduled), base document `docs/WMS/WMS_Procurement_Requirements_Draft.md` (HD-02, NF-05).

## (a) Partition

Offline work is a **task package**: the HUMAN_TASKs or warehouse tasks assigned to this user or device, plus the document lines and read-only reference data each needs, as of a snapshot version. It is bounded by 0051 scope grants (warehouse, zone) and by assignment. A task is checked out to ONE device by a **lease** whose expiry is the configured maximum outage (default 3 days, 0057 D13). The server records the checkout; no other device or user can complete the same lines meanwhile. Two tasks touching the same stock are fine: the ledger arbitrates.

## (b) Conflict rules (applied when offline is built)

The server ledger is the only authority. The client records intent and facts, never balances. Replays are idempotent (key = document line + task + device attempt) and applied in the device's own sequence order.

- Facts that cannot be false (received N of item X at location L at time T) are ACCEPTED late: posted at server posting time, client event time kept.
- State-dependent decisions are re-validated at replay and failures are reported typed, never silently reconciled:
  - pick or issue that would make stock negative: 409 `insufficient_stock`, task returns to the supervisor;
  - lease expired, task reassigned or cancelled: 409 `task_not_current` (physically done work is posted by the supervisor as an exception receipt with device evidence);
  - retired location or item: facts already true are accepted, new putaway targets are rejected;
  - stale reference snapshot: typed 409 naming which, the client refreshes and the user re-confirms; a quantity is never auto-corrected.
- A replay batch is not atomic; each command returns its own typed result.
- Counts replayed after a freeze ended are NOT posted; they become a variance proposal through the normal count variance approval.
- After the maximum outage the lease is dead (`lease_expired`): unsynced work goes in as exception evidence, not as commands.

## (c) Built now, in the first schema (the only part with cost today)

1. Every command carries `client_op_id` (idempotency key), `device_id`, a per-device monotonic `client_seq` and `client_event_time`; the ledger stores them beside `posting_seq` / posting time. (Ledger columns: #2657.)
2. Every mutable resource has a `version`, and commands state `expected_version` (typed 409 on mismatch; 412 where the route uses preconditions). (Where the entity base already has versioning, reuse it; otherwise the owning issue.)
3. A stable id for every document line, generated at issue time. (REQ-480 / document slice.)
4. Typed 409 error codes with machine-readable details: the list in (b).
5. Task assignment has an owner plus nullable `leased_to_device` and `lease_expires_at`.
6. Reference data carries a `snapshot_version`, with an API for changes since snapshot N.
7. Tombstones: retire or cancel marks inactive, never deletes.
8. An append-only command log table (received command, result, reasons) audits every replay. (REQ-480.)

Not needed now: merge UIs, sync engines, partition negotiation, client-side balances.

## Placement of the acceptance criteria

Items 1 (ledger columns) and 3-4 in the ledger issue #2657 (REQ-502); item 2 and 7 in the entity base where present and in #2658 / master issues where not; items 5, 6 and 8 and the typed error list in REQ-480 (not yet filed). Items are added to the live issues as comments by letflow-2 on 2026-10-16; the REQ-480 draft is updated before it is filed.

## Not verified

Which of items 2 and 7 the entity base already provides on main was NOT re-read for this record; the implementing issues re-read it.
