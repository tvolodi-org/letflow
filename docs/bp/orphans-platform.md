# Orphans of the platform area

Inventory items of area `platform` that no process of this area uses. Not deleted, not judged by the writer.

No orphans. Decision (T-2559 review, D-169): `/verify/:handle -> VerifyCertificatePage` (web/src/router.tsx:116, added 2026-10-26 by a7332354b, BilimBaga study T4a, REQ-357 / decision 0028) is USED: it is the public certificate check. It sat here only because its route is in the core router file; it is now task 1 and 2 of BP-PLATFORM-23.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
