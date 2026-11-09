# Mobile PWA: web build and hosting (M5, D-112)

The same Flutter code as the Android app (`apps/mobile`) is also built as a PWA for iPhone users
without scanners. This runbook covers the build job, the artifact and what infra serves. Sign-in is in
`mobile-web-pwa-signin.md`.

## What the job builds

Workflow `.github/workflows/cd-pwa-web.yml` ("CD (PWA web build)") runs on a push to `main` that touches
`apps/mobile/`, the `scripts/pwa_web_*.sh` files or the workflow itself, and on `workflow_dispatch`. It has no
secrets. It runs `bash scripts/pwa_web_build.sh`, which:

1. refuses a non-HTTPS `PWA_API_BASE_URL` (exit 2, nothing built);
2. runs `flutter build web --release --no-web-resources-cdn` (CanvasKit is served from the bundle);
3. runs `scripts/pwa_web_verify.sh`: CanvasKit and zxing are local, Roboto is bundled, the glyph fallback base
   is a same-origin path, no other host in `index.html`, `manifest.json`, `zxing-config.js`;
4. runs `scripts/pwa_web_package.sh`: `.gz` (and `.br`, brotli is required in CI) next to each text/wasm file when
   smaller, `build-info.json` (sha, built_at, base_href, api_base_url), `SHA256SUMS`, and the tar
   `letflow-pwa-web-<sha12>.tar`.

The artifact is named `letflow-pwa-web` (retention 30 days): the tar, `SHA256SUMS`, `build-info.json`.

Repository variables (Settings, Actions, Variables):

| Variable | Default | Meaning |
|---|---|---|
| `PWA_API_BASE_URL` | `https://qa.bizdala.com` | API the PWA talks to. Baked in at build time: one artifact serves one environment. For another environment run the workflow by hand with another value. |
| `PWA_BASE_HREF` | `/` | Path the PWA is served from; starts and ends with `/`. |

## What infra does

1. `gh run download -n letflow-pwa-web` for the newest successful run; keep the previous tar as the rollback target.
2. Unpack the tar into the nginx root after `sha256sum -c SHA256SUMS` (run inside the unpacked folder).
3. Serve it over HTTPS with `deploy/nginx/letflow-pwa-web.conf.example` as the reference.
4. Allow the PWA origin in the API's CORS list, and add the redirect URI from `mobile-web-pwa-signin.md` in Keycloak.

## Headers and why

The build has no service worker (Flutter ships only a self-unregistering stub) and file names are not content-hashed,
so cache busting is done by HTTP validators:

| Header | Value | Why |
|---|---|---|
| `Cache-Control` | `no-cache` on every file, always | a new deploy is picked up on the next load; unchanged files cost one 304 (`ETag`), CanvasKit is not downloaded again. No `immutable`, no `max-age`: names do not change. |
| `Content-Type` | `application/wasm` for `.wasm` | required for streaming compile |
| `Content-Encoding` | gzip (`gzip_static on`), brotli if `ngx_brotli` is there | the `.gz`/`.br` files are in the tar |
| `Permissions-Policy` | `camera=(self), microphone=(self)` | scanner and voice |
| `X-Content-Type-Options` | `nosniff` | |

`/fonts-fallback/` must answer a real 404 (not `index.html`). Roboto is bundled, which covers English, Russian and Kazakh.
Glyphs outside Roboto (emoji, CJK) show as boxes instead of being fetched from a third party; that is deliberate.

## Operator checks after the first run (cannot run in the build step)

- [ ] The first push to main touching the paths produces artifact `letflow-pwa-web`.
- [ ] `curl -sI -H 'Accept-Encoding: gzip' https://<host>/canvaskit/canvaskit.wasm` shows `content-encoding: gzip`,
      `cache-control: no-cache`, an `etag` and `content-type: application/wasm`; a repeat with `If-None-Match` answers 304.
- [ ] In the browser (DevTools, Network): sign in, open a form with Russian and Kazakh text, scan once: no request to any
      host except the PWA origin and the API (none to `gstatic.com`, `jsdelivr.net`, `unpkg.com`); no missing-glyph boxes.
- [ ] On an iPhone over HTTPS the camera opens after a tap.

Client test kit and the "ready for clients" check before the link goes out: `docs/runbooks/mobile-web-pwa-ready-check.md`.
