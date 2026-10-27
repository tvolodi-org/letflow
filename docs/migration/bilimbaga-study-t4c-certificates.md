# BilimBaga study T4c: certificate features not yet matched by the exam module

Date: 2026-10-26. Read-only written finding for retirement criterion 4 (certificates) in
`bilimbaga-retirement-status.md`, task T4c. No product code, test or requirement file was changed.

## Files read

BilimBaga (`c:\Users\tvolo\dev\ai-dala\BilimBaga`, HEAD `445216d`):
- `backend/internal/certificates/` : `model.go`, `service.go`, `handler.go`, `pdf.go` (tests listed, not read in full)
- `backend/migrations/019_certificates.up.sql`
- `backend/internal/router/router.go` (lines 92, 338, 339: certificate routes)
- `backend/internal/email/service.go` (line 77: certificate link in the result e-mail)
- `frontend/src/api/verify.ts`, `frontend/src/App.tsx` (the `/verify/:code` route),
  `frontend/src/components/results/ResultActions.tsx` (download button, per `certificateEnabled`)

Letflow:
- `lib/letflow/modules/exam/certificate.ex`
- `lib/letflow/modules/exam/certificate_document.ex`
- `lib/letflow/modules/exam/certificate_public_projection.ex`
- `lib/letflow/modules/exam/router.ex` (certificate routes, `render_issue_certificate`, `render_download_certificate`)
- `lib/letflow/routers/tenant_config.ex` (`branding_from_settings/1`), `lib/letflow/routers/public_read.ex`,
  `lib/letflow/public_read.ex` (handle revocation and expiry fields)

## BilimBaga certificate model, in short

One table `certificates` (migration 019): `session_id` unique, `verification_code` UUID unique, `issued_at`,
`employee_name`, `exam_title`, `score_pct`, `template_snapshot` JSONB. There is **no** revoked, expires or
valid_until column and no revoke endpoint or service method (grep for revok/expires/valid_until in
`internal/certificates` and migration 019 finds nothing). Routes: `GET /portal/sessions/{id}/certificate`
(owner), `GET /admin/sessions/{id}/certificate` (`exams:read`), public `GET /verify/{code}`.

## Classification

| # | BilimBaga feature (source) | Class | Letflow counterpart / note |
|---|---|---|---|
| 1 | Guarded issue-on-first-request: owner, submitted, `certificate_enabled`, passed (`service.go` GetOrCreate) | matched | `Certificate.issue_or_get_for_user/3`. Adds a distinct `:grading_pending` refusal and reads exam facts from the session snapshot. |
| 2 | Idempotent issuance, one certificate per session (`UNIQUE(session_id)`, ON CONFLICT DO NOTHING) | matched | Deterministic idempotency key `certificate:issue:<session_id>` on the event store. Weaker than a column constraint, documented in the moduledoc. |
| 3 | Branding/template snapshot at first issuance (`TemplateSnapshot`) | matched (partly, see 4 and 5) | `capture_branding_snapshot/1`, stored in `branding_snapshot`, never re-read. Snapshot content differs: see 4 and 5. |
| 4 | Template field `signatory_name` / `signatory_title` | gap | Letflow branding carries only `app_name`, `logo_url`, `brand_colors`. `CertificateDocument` prints a fixed placeholder "<app> Certification Authority / Automated Issuance". Size S. Next: requirement (tenant signatory settings, snapshot keys, PDF block). |
| 5 | Template: logo embedded in the PDF (`LogoBase64`) | gap | Not ported on purpose (renderer is pure, snapshot holds a URL). Header is text only. `primary_color` is also not used by the PDF. Size M. Next: requirement (decide fetch/cache of the logo bytes, then render). Needs an owner decision on whether BilimBaga tenants need the logo on paper. |
| 6 | PDF content: title, name, exam, score, date, QR, verify URL, certificate ID (`pdf.go`) | matched | `CertificateDocument.render/2` (pdf + eqrcode, decision 0033). Header deliberately not hardcoded to a product name. |
| 7 | PDF with Cyrillic text (BilimBaga uses Helvetica, i.e. also Latin-1 only) | drop (not a regression) | Both sides lack it. Letflow degrades to "?" and flags it in its moduledoc. If kk/ru names matter in production this is a new feature, not parity. Size M if wanted, requirement. |
| 8 | Public verification `GET /verify/{code}` returning `valid`, name, exam, score, issue date; unknown code gives `valid=false` with HTTP 200 | matched in intent, gap in wiring | Backend: `CertificatePublicProjection` through `GET /api/public/certificate/:handle` returns name, exam, score, issued_on, branding. Refusals are a uniform 404 (decision 0028), not `valid=false`. See 9 and 10. |
| 9 | QR code on the PDF opens the verify page | gap (defect; fixed by REQ-592 / #3342: the download now mints a fresh handle per download) | `render_download_certificate` passes `code: certificate.id` (the record id, an interim stand-in, see its comment in `router.ex`) so the QR encodes `<CERTIFICATE_VERIFY_BASE_URL>/verify/<record id>`. The public-read handle is minted once, returned once as `public_handle` on first issuance, and stored hashed, so the PDF cannot contain it. The QR as built therefore points to a path that no route resolves. Size M. Next: requirement (decide how a re-downloaded PDF gets a resolvable code: a persisted verification code, or a re-mintable handle; it touches the public-read decision 0028 and needs a security review). |
| 10 | SPA verify page `/verify/:code` (valid / invalid / temporarily unavailable states) | gap | No `web/` page (already item 1 in the status doc). Size S-M. Next: change, after the decision in 9. |
| 11 | Candidate download in the UI (`ResultActions`) and certificate link in the result e-mail | gap | Letflow has `GET /exam-sessions/:id/certificate/download`; no UI caller found (status doc item 2) and no e-mail link. Size S. Next: change (UI), the e-mail link is a separate S change if the notification path exists. |
| 12 | Admin download for any session (`/admin/sessions/{id}/certificate`, `exams:read`) | gap | The Letflow moduledoc states the admin bypass is intentionally not wired. Size S. Next: requirement (an admin route needs its own permission and a cross-tenant negative test). Low priority unless BilimBaga admins use it; ask the owner. |
| 13 | Revocation of a certificate | drop (no source feature) | BilimBaga has none. Letflow's public-read handles do support `revoked_at` and `expires_at`, but nothing in the exam module calls revoke. The open item in the status doc ("needs owner input whether BilimBaga has it") is answered: it does not. Any revocation is new scope: a requirement only if the owner asks. |
| 14 | Certificate expiry / validity period | drop (no source feature) | None in BilimBaga. Same as 13. |
| 15 | Stored PDF binaries | drop | Neither side stores them; Letflow regenerates on each request. |
| 16 | Verify endpoint returns `valid=false` for an unknown code instead of 404 | drop | Deliberate change (decision 0028, no existence oracle). The SPA verify page must treat the 404 as "invalid". |

## Gaps, ranked

| Gap | Size | Next task type |
|---|---|---|
| 9 QR code points to an unresolvable path (record id, not the handle) | M | requirement (decision plus security review), then a feature task |
| 10 SPA verify page | S-M | change, after 9 |
| 11 Candidate download button (and e-mail link) | S | change |
| 4 Signatory name and title | S | requirement |
| 5 Logo in the PDF | M | requirement (owner decision first) |
| 12 Admin certificate download | S | requirement (ask the owner first) |

## Notes for the planner

- Gap 9 is the one that matters for retirement: criterion 4 says "QR verify", and today a printed QR cannot
  verify. It should come before the verify page (10), which would otherwise be built for a URL that does not
  exist. This also refines the status doc, which listed the missing page as the first gap.
- Revocation and expiry should not be queued: BilimBaga has neither.
- Not run: no code was executed on either side, so the claim in 9 comes from reading
  `router.ex` (`render_download_certificate`) and the REQ-357 comments, not from a request against a running
  instance. A test that downloads the PDF and resolves the encoded code would confirm it.
