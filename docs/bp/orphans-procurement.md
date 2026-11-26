# Orphans of the procurement area

Every inventory item of the area (the 14 routes of `lib/letflow/modules/procurement/router.ex`) is used by at least
one process of `docs/bp/procurement.json`, so there are no orphans.

The inventory lists routes only: the module has no pack, no screens, no write handlers and no `*rules*`/`*policy*`
files (`python3 scripts/uat/bp_inventory.py procurement --summary` gives `{"route": 14}`). There is no procurement screen
in `web/src`; every process is an API process.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|

## Orphan review (BA, D-169, T-2560, 2026-11-21): decision for every entry

Entries come from the earlier notes of this file and from the `docs/bp/dead-code.json` rows of area `procurement`;
each re-checked with `grep -rn` over `lib/` and `test/` and `git log -S`. They are function-level, so not table rows (the
table accepts inventory items only). Nothing is deleted.

**(a) Used, and in the map (leaves the list).**
- `LineEvents.record_officer/3`, `record_supplier/3`, `record_reference/3`, `cancel_line/3`
  (`lib/letflow/modules/procurement/line_events.ex:69,73,77,85`; dead-code.json says `dynamic_suspect`): they are called by
  the router (`router.ex:16..19`, the officer, supplier, reference and cancel routes), so they are system functions of
  BP-PROCUREMENT-03 and BP-PROCUREMENT-04. Added 2026-10-29, `b999e3e81` (GH #3188, REQ-558).

**(c) Real orphans (no production caller; kept, with proposal).**
- `PurchaseRequests.update_draft/4` (`purchase_requests.ex:64`). What: the requester replaces the content of an open draft.
  Callers: tests only (`grep -rn "update_draft" lib/letflow/modules/procurement` finds only the definition and moduledoc);
  no route. History: added 2026-10-28, `706c31874` (GH #3162, REQ-544 part 1). Why: part-1 context API before the BPM
  submit operation of part 2 replaced the flow. Proposal: GIVE A PROCESS (a route "edit my draft") or remove; owner decides.
- `PurchaseRequests.submit/3` (`purchase_requests.ex:80`). What: issues the requester's own draft. Callers:
  `purchase_requests_test.exs:135,234` only; production uses `submit_for_bpm/3`
  (BP-PROCUREMENT-01). Same history. Proposal: the owner may remove it as superseded by `submit_for_bpm/3`; it is not removed here.
- `PurchaseRequest.priorities/0` and `kinds/0` (`purchase_request.ex:44,47`; dead-code.json `no_caller`). What: return the
  accepted priority and line kind lists. No caller in `lib/` or `test/`. History: added 2026-10-28, `706c31874`. Why: a
  list for a form that does not exist. Proposal: KEEP until a procurement screen needs the lists (REQ-544 has no screen yet).
