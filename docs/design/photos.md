# Photos for items, lots, locations, asset cards and document lines: one attachment service

Task T-2014 (PM 2026-11-16, owner request). Design only, no code. Architect and designer view. The BA note with
the question, the decisions and the sources is `docs/uat/ba-decisions/T-2014.md`.

Marks: **[V]** verified on origin/main at bb39f4142 (file and symbol named), **[A]** UAT assumption, to be confirmed
by the process owner, **[Q]** open owner question. Every number below that has no existing source is a starting
value and a setting, not a rule.

## 1. What the owner asked for

Several photos per record; a main photo shown as a thumbnail in lists and cards; take a photo with the phone camera;
upload from the desktop (file button, drag and drop, paste); a caption; an order; delete by permission; an optional
photo at count lines and at receipt and issue lines as evidence. Decide storage, permission atoms, limits, offline
upload, audit, export, the open/closed split, and how this relates to the problem-report screenshots and to the
future assets store: **one attachment service, not three**.

## 2. What exists today (inventory)

Five places on main keep uploaded bytes. None of them can carry a record photo as asked.

| # | What | Table and bytes | Rules | Permission | Can it hold the photos? |
|---|------|-----------------|-------|------------|-------------------------|
| 1 | Instance attachments (REQ-211, REQ-212) | `instance_attachments`, link row; bytes in `repository_artifacts.content` **[V]** `lib/letflow/repository/attachment.ex`, `lib/letflow/repository/artifact.ex` | 25 MiB (`@max_upload_bytes 26_214_400`); declared type checked against `@allowed_content_types`, never the bytes ("INV-a"); scanner seam; counted in the storage allowance **[V]** `lib/letflow/repository/attachments.ex` | `AttachmentsRead`, `AttachmentsManage` **[V]** `lib/letflow/api/authorization.ex` | No: attached to a workflow instance, not a record |
| 2 | Signed links (REQ-386, REQ-448 L1) | no table; per-tenant signing key by secret reference, 5-minute expiry **[V]** `lib/letflow/repository/attachment_links.ex` (`@link_expiry_seconds`) | issuing persists state, so it has its own atom | `AttachmentLinksIssue` (issue), `AttachmentsRead` (content) **[V]** `authorization.ex`, comment above `POST /instances/:id/attachments/:attachment_id/link` | Reusable as a mechanism (section 5.7) |
| 3 | Record attachments (REQ-313, REQ-316, REQ-317) | `entity_record_attachments` keyed by `(entity_type, record_id)`; bytes in `repository_artifacts` **[V]** `lib/letflow/repository/entity_attachments.ex` | 25 MiB; same scanner; NOT counted in the storage allowance (`get_storage_usage/1` sums only `instance_attachments`) **[V]** `attachments.ex` `get_storage_usage/1`; writes no audit entry and no history event (`grep -n "Audit\|EventStore\|event" lib/letflow/repository/entity_attachments.ex` prints nothing) | `EntitiesAttachmentsRead`, `EntitiesAttachmentsManage` | No: the upload and delete routes answer 403 `entity_type_managed` for a module-managed type **[V]** `lib/letflow/routers/entities/record_attachments.ex` (`:managed ->` in `handle_create_record_attachment/3` and `handle_delete_record_attachment/4`), and every target record here is module-managed |
| 4 | Purchase request files (REQ-626) | `procurement_attachments`, insert-only, versioned slots; bytes in `repository_artifacts` **[V]** `lib/letflow/modules/procurement/attachments.ex` | 25 MiB; not counted in the allowance (its moduledoc) | procurement routes | No: one document type, versioned by design |
| 5a | Tenant logo (REQ-590) | `tenant_logos`, bytes inline, one row **[V]** `lib/letflow/identity/tenant_logo.ex` | closed type list; **first bytes must match the type** (`signature_matches?/2` for PNG, JPEG, WebP); scanner; audit entry with type, size and sha256, never bytes | tenant settings | No: one image per tenant |
| 5b | Owner review thread images (T-1963) | `problem_report_comment_images`, bytes inline, platform company only **[V]** `priv/repo/migrations/20261115100001_add_owner_review_items.exs` | PNG or JPEG by first bytes, at most 6 per entry, 5 MiB each (`@max_image 5_242_880`, `@max_images 6`) **[V]** `lib/letflow/problem_reports/review.ex`, `comment_image.ex` | `ProblemReportsManage` | No: platform company only |

Not built yet:
- **Problem-report screenshots** (T-1950 part 2). The merged slice 2 is part 1 only: "screenshots follow in part 2"
  **[V]** `docs/design/platform-maintenance.md` (commit 106cadb9c). Owner table line 8 of that file: off by default,
  the user turns it on per report, kept 30 days. The T-1950 task text adds: paste, drop and a file button, several
  images, PNG/JPEG, 5 MB each, type by first bytes, thumbnails before sending (quoted in the BA note).
- **The future assets store**: files on asset cards and documents (passports, warranty scans, invoices). No file on
  main describes it (`grep -rn -i "assets store\|asset store" docs` finds nothing); this design reads it as "files of
  the assets application", purpose `file` below **[A]**.
- **A PWA**: `web/` has no service worker and no web manifest (`grep -rln "serviceWorker\|workbox\|vite-plugin-pwa\|manifest.webmanifest" web/` over sources finds nothing; `web/public` holds `brand/` and `design-system/` only). The phone
  client is the Flutter app `apps/mobile/`, online only (MOB-8, `docs/assets/phone-flows.md` section 6).
- **Plans**: a tenant has `tenant_type` (`test` | `production`) and `storage_allowance_bytes` (default 1 GiB) and
  nothing else **[V]** `lib/letflow/identity/tenant.ex`, `priv/repo/migrations/20260923000001_add_storage_allowance_bytes_to_tenants.exs`.
- **An image library**: `mix.exs` has none (no vix, image or mogrify); `wasmex` is present (sandboxed WASM).

### 2.1 Why the photos cannot simply reuse table 3

1. **Bytes cannot be deleted.** `repository_artifacts` is immutable: `BEFORE UPDATE` and `BEFORE DELETE` triggers
   refuse every mutation, and the link delete is "metadata-only" **[V]** `artifact.ex`, `entity_attachments.ex`
   (`delete/2`). A photo deleted by permission, a 30-day screenshot, or a photo that shows a person must really go.
2. No order, main flag, caption or thumbnail columns.
3. The routes refuse managed types (row 3 above).
4. Not counted in the allowance, no audit.

## 3. Decision: one attachment service

One core service, `Letflow.Attachments` (slice P1, T-2040: the service and the two tables are on main; no route yet), used by every owner of a file:
record photos, evidence photos, asset-store files, problem-report screenshots, and later the review thread images.
Two tables in **each tenant schema** (INV-1 by `:prefix`; `tenant_id` kept in each row as elsewhere):

- `attachment_blobs` (built, P1): `id`, `sha256` (unique per schema: dedup inside one company only, as
  `repository_artifacts` does), `content_type` (set from the first bytes, never from the client), `byte_size`
  (measured), `width`, `height` (read from the image header), `bytes`, `inserted_at`. Deletable. A blob is deleted
  in the same transaction as its last link.
- `attachment_links` (built, P1): `id`, `owner_kind` (an entity type key such as `assets_card`, or `problem_report`),
  `owner_id`, `purpose` (`photo` | `evidence` | `file` | `screenshot`), `position` (1..n, unique per owner and
  purpose), `is_main` (at most one per owner, purpose `photo`, partial unique index), `caption` (at most 200
  characters, plain text), `blob_id`, `thumb_blob_id` (images only), `uploaded_by`, `inserted_at`, `locked_at`
  (evidence, section 5.6), `retain_until` (null = as long as the owner).

An **owner registry** declares per `owner_kind` the purposes it accepts, the per-owner caps and the main-photo rule.
As built in P1 it is a static map in core, `Letflow.Attachments.Owners`, keyed by owner-kind strings, not a module
manifest key (a manifest key would move the manifest hash and every module version pin, and a core file naming a
module file breaks boundary Rule 5); each owner is still one line, added by its own slice. The read and write check of
the owner record, and when evidence locks, are not in the registry: the owner's router passes its own result (P2). The service never decides tenant scope and never checks a role; the module router passes the prefix
and the result of its own permission check, as `Letflow.Modules.Procurement.Attachments` does today.

Storage of the bytes, v1: **PostgreSQL, in the tenant schema**, behind a small `Letflow.Attachments.BlobStore` behaviour (built, P1)
whose only adapter is Postgres. Reasons: the daily database dump already backs it up and restores it with the
tenant (backup content per `ai-dala-portfolio/proposals/letflow-production-plan-T-1569.md` section 2, quoted in the
BA note); tenant isolation and tenant purge (dropping the schema) work with no extra code; no new server, credential
or dependency. An object-store adapter (S3-compatible, per-tenant prefix, server-side encryption, credentials by
secret reference, INV-4) is a later slice when the measured photo volume asks for it (section 8, closed candidate 1).

What stays as it is: tables 1, 3 and 4 keep working and keep their routes; they get no new features. Table 5b moves
onto the service in slice P9. Table 5a stays (one logo per company, no reason to move).

## 4. Which records get photos

| Purpose | Owner kinds (entity type keys **[V]** `priv/modules/*/entity_definitions/`) | Per owner | Main photo |
|---------|---------------------------------------------------------------|-----------|------------|
| `photo` (gallery) | `catalog_item` (stock item), `catalog_lot`, `location_node`, `assets_card` | 10 | yes, shown in lists and cards |
| `evidence` (optional) | stock count line `count_sheet_line`, asset count line `assets_count_line`, `stock_receipt_line`, `stock_issue_line`, `stock_writeoff_line`, `assets_writeoff_line` | 3 per line | no |
| `file` (assets store, later) | `assets_card` and the asset document headers | 20 | no |
| `screenshot` | `problem_report` (platform company schema only) | 6 (as the review thread) | no |

Not in v1, by decision: headers of documents (evidence belongs to the line that is counted or moved), transfer,
hand-over, return, opening and commission lines (no damage or quantity dispute to prove), counterparties and org
units. Each can be added by one registry line. Write-off lines are in because damage is the commonest reason for a
photo **[A]**.

## 5. Rules

### 5.1 Formats, checked by bytes
- Accepted: JPEG, PNG, WebP, decided by the first bytes exactly as `TenantLogo.signature_matches?/2` does; the
  declared type is ignored. Refused: everything else, including GIF (animation), SVG (script), HEIC (no decoder
  anywhere in the stack; the browser converts it, 5.3). Refusal `photo_type_not_allowed`.
- The header must parse to the end of the structure (JPEG segments up to SOS, PNG chunks with CRC, WebP RIFF
  chunks); a broken structure is `photo_malformed`. The **same parse** yields the dimensions, removes the metadata
  (5.2) and feeds the scanner, so no second parser can disagree (skill rule on guards).
- The existing scanner seam runs on the stripped bytes (`Letflow.Repository.AttachmentScanner`, config key
  `:attachment_scanner`); an error refuses (INV-8). Nothing is stored before every check passed.
- Purpose `file` (later) accepts PDF and the office types of `@allowed_content_types`, also checked by first bytes.

### 5.2 Metadata stripped, location included
Done on the server for every upload, whatever the client did, without decoding pixels: JPEG drops APP1 (EXIF, XMP,
GPS), APP13 (IPTC) and COM segments, keeps APP0 and the ICC profile (APP2); PNG drops `eXIf`, `tEXt`, `zTXt`,
`iTXt`, `tIME`; WebP drops the `EXIF` and `XMP ` chunks and clears their flags in `VP8X`. A test fixture with a GPS
tag must come out with none. As built (P1) JPEG and PNG use an allowlist of kept segments and chunks, stricter than this
list: any APPn other than APP0, an ICC APP2 and an Adobe APP14 goes, and everything after the first EOI is cut
(MPF secondary images carry their own EXIF/GPS); every PNG chunk CRC is checked. Because EXIF orientation is removed too, the web client rotates the image before upload
(5.3); an API client that sends a rotated EXIF photo gets it stored as the sensor wrote it (documented, accepted).

### 5.3 Size caps and thumbnails
- The client (web and Flutter) scales a photo to at most 2048 px on the long edge, applies the orientation and
  encodes JPEG at quality 0.85 before upload; this also turns HEIC from an iPhone into JPEG. It makes a thumbnail of
  at most 320 px on the long edge.
- The server refuses an original over 5 MiB (5 242 880 bytes, the value of the review thread, `review.ex`) or over
  4096 px on a side, and a thumbnail over 100 KiB or over 400 px (`photo_too_large`). Starting values, settings **[A]**.
- The server does not decode pixels in v1, so the thumbnail is the client's. Risk: a user who holds the add
  permission can send a thumbnail that does not show the original. Accepted for v1 because only a permitted user can
  do it, it is audited, and the original is one click away. Closing it later means re-encoding on the server inside
  the WASM sandbox that `wasmex` already provides (INV-3), slice P10. A missing thumbnail is allowed; the list then
  shows a placeholder, never the original.

### 5.4 Limits per company and per plan
- Per owner: the counts of section 4. Per company: every blob counts against `storage_allowance_bytes` (default 1
  GiB); refusal `storage_quota_exceeded`, the reason the instance path already returns. `get_storage_usage/1` is
  extended to add `attachment_blobs` (slice P1); the record and procurement tables stay uncounted as today.
- There is no plan on main. Limits are per-company settings with defaults; a plan, when the commercial side defines
  one, sets those settings. No plan logic is built here.
- Per user: at most 60 uploads per rolling hour (the problem report uses 10 per hour, `problem_reports.ex` D8; a
  count of 40 lines with one photo each needs more) **[A]**.

### 5.5 Permission atoms (no role names)
Reading follows the owner: whoever may read the record (or the line) sees its photos. The registry names the
existing read check: `AssetsRead` for `assets_card` and asset lines, `StockRead` for stock and count lines, the
generic read with type access (`EntitiesQuery`) for `catalog_item`, `catalog_lot`, `location_node` **[V]**
`authorization.ex` (`endpoint_policy_key("POST", "/entities/query")`). An unreadable owner and a missing photo answer
the same 404 (INV-5).

Two new tenant-scope atoms (planned, not yet on main):
- `PhotosAdd`: add a photo, change its caption, reorder, choose the main photo. Also needs the owner's read; for
  `evidence` also the owner's write check (`StockCountRecord` for a stock count line, `StockPost` for stock lines,
  `AssetsPost` for asset lines, `AssetsCountRecord` for asset count lines **[V]** `lib/letflow/modules/assets/router.ex`).
- `PhotosDelete`: delete a photo of any user. A user may delete a photo **they** added, without this atom, while
  the photo is not locked; that is the common "wrong shot" case **[A]**.

Grants: TENANT_ADMIN holds both through its all-tenant-scope rule; PLATFORM_ADMIN only inside the platform company;
TENANT_AUDITOR holds neither (read-only, `docs/roles.md`); STOREKEEPER gets `PhotosAdd` through the stock manifest
`role_grants`, as it gets the stock atoms, and not `PhotosDelete` **[A]**. Screenshots keep `ProblemReportsManage`
for reading; the reporter adds them only while sending the report.

### 5.6 Evidence lock
Evidence photos can be added and removed only while the line can still be changed: the count sheet is open, the
document is a draft. When the sheet closes or the document is issued or posted, the service sets `locked_at` on its
evidence links in the same transaction (P1 ships the column and the `photo_locked` refusals; setting the lock and the
`attachment.locked` audit action come with P6); a locked photo cannot be deleted, reordered or re-captioned by anyone
(`photo_locked`). It goes only with its document (documents are never deleted today; retention and legal hold are
the subject of decision 0063, which is still proposed).

### 5.7 Serving
`GET` of the original or the thumbnail through the module route, with the read check; `Content-Type` is the stored
first-bytes value, `X-Content-Type-Options: nosniff`, `Content-Disposition: inline`, `Cache-Control: private,
max-age=86400` (a link id never changes its bytes). The SPA fetches with its bearer token and shows an object URL,
as the instance attachment view already does (`web/src/pages/instances/attachments/AttachmentSuccessView.tsx`, D1: authenticated fetch, then `URL.createObjectURL`, never a raw `<img src>`); no signed link in v1. Signed links (row 2) are reused only for an
export download if one needs it.

### 5.8 Audit
One audit entry per change, in the same transaction, in the owner's company: `attachment.added`,
`attachment.removed`, `attachment.changed` (changed field names only), `attachment.locked`, and one
`attachment.expired` per retention run with the count. Each holds owner kind, owner id, purpose, link id, sha256,
size and type; never bytes, never the caption text (it is user text) — the same shape as the logo audit entry
(`tenant_logo.ex`). Refusals write nothing and are counted on telemetry, as procurement does.

### 5.9 Retention and backup
- `photo` and `file`: kept as long as the owner. Masters are retired, never deleted, so their photos stay until a
  permitted user deletes them.
- `evidence`: as long as the document (5.6).
- `screenshot`: `retain_until` = sent + 30 days (owner table line 8 of `docs/design/platform-maintenance.md`); a daily
  job deletes expired links and their blobs.
- Deleting removes the bytes from the live database at once. They stay in database backups until those backups
  rotate out (seven daily sets today, per the production plan quoted in the BA note); the privacy text must say so.
- Tenant purge drops the schema, photos included.

### 5.10 Export
A dataset `photos` in the data export (`docs/design/data-export.md`, `DataExport` atom): a zip with one folder per
owner kind, files named `<record number or code>-<position>.jpg`, and `manifest.json` (owner kind, owner id, number
or code, position, main, caption, purpose, sha256, size). Capped like the other datasets (rows) and also by bytes
(at most the company's allowance, streamed). Screenshots are never exported to the customer (they live in the
platform company). Slice P7.

### 5.11 Capture and upload in the client
- Web, desktop: a file button (several files), drag and drop onto the gallery, and paste (Ctrl+V) — the same three
  inputs the owner asked for in T-1950 (taken from the lab owner list). The web has no paste or drop upload yet
  (`grep -rln "onPaste\|clipboardData" web/src` finds only the lines editor), so P3 builds one shared component
  that P5 reuses.
- Web on a phone: `<input type="file" accept="image/*" capture="environment">` opens the rear camera in mobile
  browsers; no PWA is needed for that.
- Flutter client: the camera already used by the codes scan screen (`docs/assets/phone-flows.md`, section 1) is
  reused for a still photo; slice P8.
- Before upload the client shows the thumbnails with a remove button; upload is one request per photo with an
  idempotency key, so a retried request after a network failure does not make a second photo.

### 5.12 Offline
v1 is online, as every phone flow is (MOB-8). A photo that fails to upload stays in the open form with "Retry" until
the user leaves it. An offline queue is the open owner question 1 of `docs/assets/phone-flows.md` section 9 **[Q]**;
this design does not decide it. If the owner says yes, the shape is: the queue lives on the device only (IndexedDB in
the browser, files in app storage on the phone), per user, at most 20 photos or 50 MB, cleared at sign-out, each
entry carrying the owner id and its idempotency key, sent when the connection returns, and refused by the server
like any late upload if the line has locked meanwhile (the user sees which photos were refused). The browser queue
needs the PWA shell (service worker) first, which does not exist; that is slice P11, after the owner's answer.

## 6. Relation to the screenshots and the assets store

One service, three uses, the same checks:

| Use | Owner kind, purpose | Schema | Retention | Read |
|-----|---------------------|--------|-----------|------|
| Record and evidence photos | entity type key, `photo` / `evidence` | the customer's | owner / document | the owner's read |
| Assets store files | asset card or document, `file` | the customer's | owner | the owner's read |
| Problem-report screenshots (T-1950 part 2) | `problem_report`, `screenshot` | platform company only (as `problem_reports`, D1) | 30 days | `ProblemReportsManage` |
| Review thread images (today table 5b) | `review_comment`, `screenshot` | platform company only | as the item | `ProblemReportsManage` |

So T-1950 part 2 is built **on** the service (slice P5) instead of adding a sixth table, and table 5b moves onto it
(slice P9). The screenshot keeps its own consent rules (off by default, preview, per report); only the storage,
checks, strip and audit are shared.

## 7. Open and closed build

Open build (all slices P1 to P9): the service, the strip, the caps, the gallery, evidence photos, screenshots,
export, the Flutter capture. Closed candidates, later, each behind a socket the open build already has:
1. Object-store adapter of `BlobStore` (S3-compatible, off-site copies, lifecycle rules) — for large customers.
2. Server-side re-encoding and smart thumbnails, and photo recognition (suggest the item or read a label from a
   photo).
3. Long or per-kind retention policies and legal hold on photos (with decision 0063's hold, once ratified).
None of these is needed to use photos.

## 8. Slices (p2)

Sizes: S = under one day of one task, M = one to two tasks, L = needs a split at planning.

| # | Slice | Contents | Size | After | Review |
|---|-------|----------|------|-------|--------|
| P1 | Service core | the two tables (tenant migration), `Letflow.Attachments` add/list/get/delete/reorder/set-main/caption, the byte checks and strip (5.1, 5.2), caps, allowance counting, audit, owner registry, GPS fixture test; no route | M | — | security (untrusted file input, tenant data) |
| P2 | Gallery routes for one owner | `PhotosAdd`, `PhotosDelete` atoms; routes for `assets_card` in the assets router; permission matrix golden | M | P1 | security (new atoms and routes, INV-10 negative) |
| P3 | Gallery screen | gallery on the asset card: upload by button, drop, paste, camera input on phone, caption, order, main, delete; main-photo thumbnail in the card list; ru/kk/en; screenshot matrix | M | P2 | gui review |
| P4 | Gallery on the other masters | registry lines and screens for `catalog_item`, `catalog_lot`, `location_node` | M | P3 | gui review |
| P5 | Problem-report screenshots | T-1950 part 2 on the service, platform schema, 30-day job | M | P1 | security |
| P6 | Evidence photos | count lines and receipt/issue/write-off lines, evidence lock on close/issue/post, screens | L (split: stock, assets) | P2 | security |
| P7 | Export | `photos` dataset in the data export | S | P4 | security |
| P8 | Flutter capture | photo on count and movement lines in the phone client | M | P6 | — |
| P9 | Move the review thread images | table 5b onto the service, one-off copy, old table dropped after a release | S | P5 | security |
| P10 | Server re-encode (optional) | WASM-sandboxed thumbnail and re-encode | M | P1 | security, needs a decision |
| P11 | Offline queue | only after the owner answers 5.12 | L | P8 and the owner's answer | security |

Order: P1, P2, P3 first (one usable feature, the asset card, in front of the owner), then P5 (already waited for),
P4, P6, P7, P8, P9; P10 and P11 only on demand.

## 9. Risks

1. **Photos show people or other companies' documents.** Strip of location; delete by permission; audited.
2. **Database growth.** 10 photos of about 0.5 to 1 MB on 2 000 cards is 10 to 20 GB, above the 1 GiB default
   allowance, so the allowance refuses before the disk fills; the object-store adapter is the answer for big
   customers (a measured estimate is part of P1's summary) **[A]**.
3. **Image parser bugs.** No pixel decoding in v1; the structure walk is small and fully tested with malformed
   fixtures; a decoder comes only inside the WASM sandbox.
4. **Client thumbnail mismatch.** Accepted for v1 (5.3).
