# Security advisories

Dependency advisories that affect Letflow: what the advisory was, what the exposure was
in this product, and what bounds it. One entry per advisory, newest first.

A status of `fixed-in-version` means the patched release is in `mix.lock` and
`mix hex.audit` lists no advisory for it. `open` means the product still runs the
affected release.

## EEF-CVE-2026-120287 (GHSA-qj4r-jh2r-rw3f) -- plug before 1.20.4: the multipart framing is not charged against the parser's length limit

- **Date:** 2026-11-22
- **Status:** fixed-in-version -- plug 1.20.4 (`mix.lock`); `mix hex.audit` reports
  "No retired or security advisory packages found".
- **Severity:** MEDIUM (CWE-770, allocation of resources without limits or throttling).
- **Source:** <https://osv.dev/vulnerability/EEF-CVE-2026-120287>. The OSV record
  (read 2026-11-22) states "from 1.13.0 before 1.20.4"; the fix is plug 1.20.4
  (released 2026-11-17).

### What the advisory was

`Plug.Parsers.MULTIPART` charged only the part names, the part header names and values
and the part bodies against the parser's `:length` limit. The framing cost nothing: the
part delimiter, the `:` and CRLF of each header line, the blank line that ends a header
block. So a body built from parts without headers -- or from header lines without a name
and a value -- was charged almost nothing and never reached the limit, while the parser
kept one entry per part until the whole body had been read. The advisory measures 92 MiB
held in the parser process for a 4.5 MB body, and 283 MiB for a body of 50 parts with
30 000 header lines each.

plug 1.20.4 charges the framing too (36 bytes per part plus 56 bytes per header line),
so the `:length` limit bounds the framing and with it the memory the parser holds.

### The exposure in this product, one line

Before plug 1.20.4 an unauthenticated client could send a multipart body to any
`/api/v1` route and have the parser hold tens of times the body size in memory, because
the framing was not charged against the 25 MiB parser limit; plug 1.20.4 charges the
framing, so the parser limit bounds that memory, and the reverse proxy's per-route
`client_max_body_size` bounds the bytes on the wire.

### Where a multipart body is parsed here

| Where | Parser and its limit | Reached before authentication? |
|---|---|---|
| `lib/letflow/plugs/api_pipeline.ex` -- `plug(Plug.Parsers, parsers: [:json, {:multipart, length: 26_214_400}, ...], length: 2_097_152)`, the shared pipeline of every `/api/v1` route (`lib/letflow/router.ex` forwards `/api/v1` to it) | `:multipart` with `length: 26_214_400` (25 MiB) for the whole body: header names and values, part bodies and, from plug 1.20.4, the framing | **Yes.** `Plug.Parsers` is mounted before `Letflow.Plugs.AuthPipeline`, so the body is parsed before the session is checked; the route then answers 401. |
| `lib/letflow/routers/shared_stock_access.ex` -- the old app's voice route, its own `Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"], length: 10_485_760)` | `:multipart` with `length: 10_485_760` (10 MiB) | No -- its own plug chain authenticates first, then parses. |

No other route parses a body: the public routers outside `/api/v1` (`/api/public`,
`/api/signup`, `/api/tenant-config`, `/api/login-discovery`, `/api/mobile/tenant-config`,
`/metrics`, `/health`, `/admin/v1`, `/maintenance/v1`) mount no body parser at all, so
they are not reachable by this advisory.

### The exposure per route that accepts an upload

| Route | Parser limit | What the application itself allows | nginx `client_max_body_size` |
|---|---|---|---|
| `POST /api/v1/instances/:id/attachments` | 25 MiB | 25 MiB (`Letflow.Repository.Attachments.@max_upload_bytes`) | 26m (infra) |
| `POST /api/v1/entities/records/:entity_type/:record_id/attachments` | 25 MiB | 25 MiB (`Letflow.Repository.EntityAttachments.@max_upload_bytes`) | 26m (infra) |
| `POST /api/v1/modules/maintenance/requests/:id/photos` | 25 MiB | 5 MiB original, 100 KiB thumbnail (`Letflow.Attachments.Image`) | 6m (infra) |
| `POST /api/v1/modules/assets/cards/:id/photos` | 25 MiB | 5 MiB original, 100 KiB thumbnail (`Letflow.Attachments.Image`) | 6m (infra) |
| `POST /api/v1/modules/stock/voice/draft` | 25 MiB | 10 MiB (`Letflow.Modules.Stock.VoiceService.@max_audio_bytes`) | 12m (infra) |
| `POST /api/v1/documents/official-form-templates` | 25 MiB | 1 MiB compressed, 10 MiB inflated (`Letflow.Documents.FormTemplate.limits/0`) | not known to this repository |
| `POST /api/v1/platform-problem-reports/:id/comments` | 25 MiB | 6 images of 5 MiB each (`Letflow.ProblemReports.Review`) | not known to this repository |
| `POST /qoimeks/:tenant_slug/api/voice` | 10 MiB (its own parser) | 10 MiB | 12m (infra) |

The nginx column holds the values the infrastructure is reported to use; the vhosts
themselves are not in this repository (the last section below).

The workbook, CSV and xlsx import routes (`POST /api/v1/entities/records/:entity_type/import`,
`POST /api/v1/identity/users/import`, `POST /api/v1/modules/stock/stock-workbook/check`,
`POST /api/v1/modules/stock/stock-workbook/apply`) take a **raw body**, not a multipart
one, so this advisory does not reach them; they are bounded by the shared 2 MiB root
`length:` of the pipeline's parser and by their own inflated-size checks (25 MiB for a
workbook). The nginx limit for them is 3m (infra).

### What bounds a request today

1. **The parser limit.** The multipart parser's `length:` (25 MiB in the API pipeline,
   10 MiB in the old app's voice route) is charged against the header names and values,
   the part bodies and -- from plug 1.20.4 -- the framing. A body that exceeds it is
   refused with `413` and the constant code `request_too_large`
   (`Letflow.Plugs.ApiPipeline`).
2. **The application-level cap.** Each route above measures the bytes it stores and
   refuses them; these caps are the authoritative ones, the parser limit is the earlier
   defence.
3. **The admission gate.** `Letflow.Plugs.Admission` (global pool) is acquired before the
   parser, so at most `global_cap` requests parse a body at the same time: 28 with the
   default `pool_size` 30 and `reserved_headroom` 2 (`config/runtime.exs`; an operator
   can lower `POOL_SIZE`).
4. **The reverse proxy.** The nginx per-route `client_max_body_size` bounds the bytes
   that reach the application at all.

### What this repository cannot say about the reverse proxy

The nginx per-route `client_max_body_size` values (voice 12m, photos 6m, attachments
26m, workbook 3m) are **not in this repository**:

- `deploy/nginx/letflow-test.conf` is the vhost of `letflow-test.ai-dala.com`. It has one
  `location /` proxying to `127.0.0.1:3113` and **no** `client_max_body_size` directive
  at all, so nginx's own default (1 MB) applies there.
- `deploy/nginx/letflow-pwa-web.conf.example` serves the static PWA site and has no
  `proxy_pass`.
- The QA vhost (`qa.bizdala.com`, with its tenant subdomains) and the demo vhost
  (`demo.letflow.ai-dala.com`) live **outside this repository**: infra owns the hosts and
  the reverse proxy (`docs/runbooks/demo-instance.md`, "Who owns what"). The same gap is
  recorded for the Bandit advisories in
  `docs/status/bandit-advisories-exposure-2026-11.md` §3 and §5.

So the per-route limits above are the numbers the infrastructure is reported to use; the
repository can confirm only the parser limits and the application-level caps.
