# Orphans of the platform area

Inventory items of area `platform` that no process of this area uses. Not deleted, not judged by the writer.

One orphan row: `GET /api/v1/platform-functions`, the read of the compiled platform-function catalogue. It was
added on 2026-11-22 by the pilot G2 build and no process of this area names it yet: the designer that reads it (the
platform-call editor, T-2599 / pilot gap G5a) is pilot work in flight. It is listed rather than given a process so
that the route inventory of D-170 stays green on the real tree (`scripts/uat/check_routes.py`); the owner decides
whether it later gets a task of its own.

Decision (T-2559 review, D-169): `/verify/:handle -> VerifyCertificatePage` (web/src/router.tsx:116, added 2026-10-26 by a7332354b, BilimBaga study T4a, REQ-357 / decision 0028) is USED: it is the public certificate check. It sat here only because its route is in the core router file; it is now task 1 and 2 of BP-PLATFORM-23.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
| GET /api/v1/platform-functions | lib/letflow/routers/platform_functions.ex:36 | reads the compiled catalogue of the platform functions a definition may call, for the caller's tenant | T-2599 (pilot gap G5a), commit 4e39e9cc6, 2026-11-22 | the designer's platform-call editor reads it to offer the functions a definition may call; the pilot work is in flight, so no process of this area names the route yet | keep as a platform function |
