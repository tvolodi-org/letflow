# Orphans of the platform area

Inventory items of area `platform` that no process of this area uses. Not deleted, not judged by the writer.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
| /verify/:handle -> VerifyCertificatePage | web/src/router.tsx:116 | public page, outside the login, that checks a certificate by its one-time public handle and reads `GET /api/public/certificate/:handle` | router comment "BilimBaga T4a" and REQ-357 / decision 0028 (named in `web/src/pages/VerifyCertificatePage.tsx` header); the API half is in `lib/letflow/modules/exam/router.ex` | the exam application's certificate check; it sits in the platform inventory only because its route is in the core router file outside `/admin`, not because it is a platform function; the process belongs in area `exam` ("Verify a certificate by its public handle") | give a process |
