# Mobile tier — architecture

**Status:** specification only; nothing built. See [`README.md`](README.md) for
provenance and [`../migration/stage-9-mobile.md`](../migration/stage-9-mobile.md)
for where this sits in the migration plan.

---

## 1. Governing principle

The mobile app is a **generic interpreter of server-delivered definitions** —
identical in principle to the React SPA in `web/`.

- One **tenant-agnostic build** serves every tenant.
- The app ships **renderers** that operate over JSON definitions fetched at
  runtime.
- **No per-tenant code or assets are bundled.**
- The app executes **no tenant script on-device** — no Lua, JS or WASM runtime.
  Declarative field logic (`visible_when`, `computed`, cross-field validation) in
  the platform's own `Letflow.Engine.Expr` grammar IS evaluated on-device, exactly
  as the SPA does, with the server re-evaluating on submit and winning. **Amended
  2026-09-09** by [`../migration/decisions/0020-frontend-architecture.md`](../migration/decisions/0020-frontend-architecture.md)
  clause **D1a**; this bullet previously read "no tenant logic on-device" with all
  evaluation server-side, which `MOB-3`'s airplane-mode launch makes impossible.

This reuse of principle is what makes the tier cheap: it consumes the *same*
server contracts the SPA already exposes — definition fetch, form/list/process/
task APIs, batched formula evaluation, version-pinned task payloads.

## 2. Placement and stack

```
apps/mobile/                 # new top-level app, peer to web/
  lib/
    bootstrap/   auth/   api/   definitions/
    renderers/   form/ list/ process/ task/
    features/    design_system/   i18n/   shared/
```

Stack — backend-agnostic, which is why it transferred unchanged from a Zig
platform to an Elixir one:

| Concern | Choice |
|---|---|
| Framework / language | Flutter 3.x · Dart 3 |
| Routing | `go_router` |
| State | `Riverpod` |
| HTTP | `Dio` |
| Auth | `flutter_appauth` — OIDC Authorization-Code + PKCE |
| Token storage | `flutter_secure_storage` (Keychain / EncryptedSharedPreferences) |
| Local cache | Isar, or equivalent local store |
| i18n | `intl` |

Platform targets: **Android API 26+**, **iOS 15+**.

The stack choice is recorded as
[`../migration/decisions/0012-mobile-tier-stack.md`](../migration/decisions/0012-mobile-tier-stack.md),
which also covers why the tier is not folded into `web/` as a responsive
breakpoint.

## 3. What the tier needs from Letflow's backend

Three touch-points, and **only** three — everything else is client-side.
R-Co's version of this section carried them as *"verify against the backend."*
Verified against Letflow on **2026-08-21**, all three are gaps:

| # | Needed | State in Letflow (verified 2026-08-21) |
|---|---|---|
| 1 | An **unauthenticated** `tenant-config` endpoint returning `{ realm_url, locales, default_locale, branding, environment_kind }`, for slug-based bootstrap before any token exists. | `Letflow.Routers.TenantConfig` exists but is a **stub** — its routes land in `REQ-078` (`pending`). More importantly it is mounted by `Letflow.Plugs.ApiPipeline` *behind* `Letflow.Plugs.AuthPipeline`, so even once implemented it will require a token the bootstrap sequence does not have yet. **Both an implementation gap and a pipeline-placement gap.** |
| 2 | A **definition delta-sync** endpoint, `GET /definitions/delta?since=…`, so a device can warm an offline cache and refresh incrementally. | Absent. No `delta` route exists under `Letflow.Routers.Definitions`. Was flagged as *"may be new"* in R-Co too — it is genuinely new work, not a port. |
| 3 | **Version-pinned task payloads** carrying `{ form_id, form_version }`. | Absent — `form_id` and `form_version` appear nowhere in `lib/`. Version pinning exists in the engine for *definitions* (`Letflow.Engine.PinResolver`), but task payloads carrying a pinned **form** version is a separate contract the task API does not yet emit. |

Gap 1 is the blocking one: without an unauthenticated tenant-config, the app
cannot reach the point of showing a login screen. Gaps 2 and 3 block `MOB-3`
(cache/delta/pinning) but not the shell.

**Closed 2026-09-27.** All three gaps above are now closed: gap 1 by `REQ-124`
(done 2026-08-22), gap 2 by `REQ-125` (done 2026-08-23), gap 3 by `REQ-126` (done
2026-08-22) — see `../migration/stage-9-mobile.md`'s gap table for per-gap detail
and status-log citations.

**Added 2026-09-28 (`REQ-418`).** The response now returns six keys, not
five: `client_id` was added as a sixth, platform-global value so the mobile
app's OIDC client id is never compiled into the app binary. See
`lib/letflow/design/req418-mobile-oidc-client.md` §2.3 for the full
disclosure rationale.

These three are why S9 depends on S4 rather than running as a fully independent
track. R-Co could treat mobile as parallel-from-day-one because its backend was
already shipped; Letflow's is not.

## 4. v1 boundary

v1 is **online-first with a read-through definition cache.**

The camera scan of barcodes and QR codes (`REQ-732`) is **online only**: every scanned text is resolved by
`POST /api/v1/modules/codes/resolve`, and there is no offline queue or local lookup for it.

Voice on the stock count and document screens (`REQ-747`) is **online only** too: the recording is sent as bytes
to `POST /api/v1/modules/stock/voice/draft` (a typed phrase to `.../draft-text`), is never stored on the device, and only
fills a draft for the user to check.

### Scope table (added 2026-10-01, `REQ-430`)

| Requirement | Scope | Delivered by |
|---|---|---|
| `MOB-1` — generic definition-interpreter shell | done | `REQ-419` (scaffold), `REQ-294` (Dart `Letflow.Engine.Expr` evaluator) |
| `MOB-2` — tenant bootstrap | done | `REQ-418` (OIDC `client_id` disclosure), `REQ-421` (bootstrap sequence), `REQ-282` (per-tenant branding) |
| `MOB-3` — offline definition cache, delta sync, version pinning | done | `REQ-423` (cache + delta sync), `REQ-424` (pinned form version resolution) |
| `MOB-4` — generic renderers, six mandatory states | done | `REQ-426` (state framework + list renderer), `REQ-427` (form renderer), `REQ-428` (task + process-instance renderer) |
| `MOB-5` — on-device security | done | `REQ-422` |
| `MOB-6` — API client | done | `REQ-425` |
| `MOB-7` — i18n | done | `REQ-429` |
| `MOB-8` — v1 scope boundary (this section's own gate) | done | `REQ-430` |

`REQ-385` confirmed no code change was needed for a related backend question
under `REQ-126`'s frozen-at-creation architecture — noted here as context,
not as a delivering REQ for any MOB-N row. `REQ-417` (`MOBILE-DEV` role
reactivation) and `REQ-420` (CI mobile gate) are infrastructure/process
requirements, not MOB-N deliverables, and are intentionally absent from the
table above.

### Explicitly out of v1 (deferred, not forgotten)

- **Offline writes** — no optimistic write queue. This is the important one:
  offline writes require a conflict model the platform does not have and
  does not currently need. **Guarded statically by `REQ-430`'s**
  `apps/mobile/test/guards/v1_scope_boundary_guard_test.dart`, which fails
  the build if a `.dart` file under `lib/` persists a store write shaped
  like an outgoing HTTP request (method/url/body).
- **Push-based cache invalidation.** **Guarded statically by the same
  `REQ-430` guard**, which fails the build on a push/messaging dependency
  (`firebase_messaging` or equivalent) in `pubspec.yaml`/`pubspec.lock`.
- **An on-device form builder.** No dependency or code-shape signature
  exists to statically guard against a feature with no implementation
  surface to scan; this exclusion is enforced by requirement scope
  (MOB-1..MOB-8 define the entire build surface; a form builder is not
  among them) rather than a static check.

Keeping these out is what makes the tier *additive*. Each of them, added, would
pull a new subsystem into the backend rather than a new screen into the app.

**Offline *form population* is in; offline *submission* is out (2026-09-08).**
The line above is easy to misread as "nothing works offline but reading," so
state it precisely. Under
[`../migration/decisions/0020-frontend-architecture.md`](../migration/decisions/0020-frontend-architecture.md)
clause **D1a**, a cached form is **fillable** with no server reachable: its
`computed` fields recompute, its `visible_when` conditions resolve, and its
cross-field validation runs, all evaluated on-device in the
`Letflow.Engine.Expr` grammar (MOB-4). What stays out of v1 is the **write
queue** — the user still cannot submit until connectivity returns.

The distinction is not arbitrary. Evaluating a pure expression against local
data needs no conflict model; queueing a write does. D1a supplies the first and
deliberately not the second, so this section's exclusion of offline writes
stands unchanged.

## 5. Relationship to `web/`

The SPA and the mobile app are **two clients of one contract**, not two
codebases with a shared core. They share no code — one is TypeScript/React, the
other Dart/Flutter — and that is accepted deliberately. What they share is the
definition format and the API, and that sharing is enforced by both consuming
the same endpoints rather than by a common library.

Practically: when a definition-format change lands, it must be applied to both
renderers. There is no compiler that will catch a miss. The mitigation is that
the format is server-delivered and versioned, so a stale client fails loudly on
an unknown field rather than silently mis-rendering — `MOB-4`'s six mandatory
renderer states exist for exactly this reason.

## 6. Application modules (decision 0039)

[`../migration/decisions/0039-platform-module-solution-layering.md`](../migration/decisions/0039-platform-module-solution-layering.md)
D5 introduces a per-tenant **installed-module list** that controls both
navigation and API access. The mobile app must follow the same contract as the
SPA.

### First feature folder: `codes` (`REQ-732`)

The first module feature lives in `apps/mobile/lib/features/codes/` (scan screen, controller, resolve client; only
`mobile_scanner_source.dart` imports the camera package). It is declared in `module_manifest.json` and registered in
`kFeatureRegistry`, so it is reachable only when `codes` is installed. It needs the camera permission: Android
`CAMERA` (with `uses-feature camera required=false`) and iOS `NSCameraUsageDescription`. If the permission is refused
the screen offers a typed-code fallback.

The `stock` feature records a spoken phrase with the `record` package (only `voice/package_recorder_port.dart` imports it).
It needs the microphone permission: Android `RECORD_AUDIO` and iOS `NSMicrophoneUsageDescription`. If the permission is
refused, or a voice part is down, the typed phrase, typing and scanning keep working.

### Navigation and routes

The app builds its top-level navigation and route set from the installed-module
list returned by:

```
GET /api/v1/me/modules
→ {"installed_modules": [{"module_id": "<id>", "version": "<vsn>"}, …]}
```

Confirmed in `lib/letflow/routers/me.ex:78` (`git grep -n "authz_get.*modules" -- lib/letflow/routers/me.ex`).

A module's screens are **not reachable at all** for a tenant whose installed list
does not include that module — the entry point is simply not added to the route
table. This matches D5's principle that a module's absence is not information to
leak.

### Per-module feature folders

Each module's Flutter code lives in `apps/mobile/lib/features/<id>/`, mirroring
`web/src/modules/<id>/` on the SPA side. No module code lives outside its own
`features/<id>/` subtree. The `features/` root acts as the core/module boundary
(see below).

### Module API base path

Every authenticated call scoped to a specific module uses the path:

```
/api/v1/modules/<id>/…
```

Confirmed in `lib/letflow/plugs/api_pipeline.ex:166` (`git grep -n "forward.*modules" -- lib/letflow/plugs/api_pipeline.ex`).

A request to this path for a module the tenant has **not** installed returns
`404`, not `403` (D5: "a module's absence is not information to leak"). The API
client MUST treat a `404` on any `/api/v1/modules/<id>/` path as a
"module not available" state, not as a generic not-found, and route the user
accordingly rather than crashing or showing a generic error screen.

### Core / module import boundary (D3)

The same two-rule boundary that governs `web/src/modules/` applies here:

1. No file outside `apps/mobile/lib/features/<id>/` may import code from inside
   it, except the one sanctioned place that reads the full module list (the
   navigation bootstrap, which reads `installed_modules` and wires routes).
2. A file in `apps/mobile/lib/features/a/` may not import from
   `apps/mobile/lib/features/b/` unless `b` is in `a`'s declared `depends_on`.

Enforcement mechanism: a linting step (exact tool TBD at implementation time,
matching the Dart/Flutter ecosystem) enforcing the same structural rule as the
SPA's ESLint `no-restricted-imports` check (0039 D3). It must fail the build,
not produce a warning.

## 7. Security hardening before corporate-tier deployment

**Status: documented now, not implemented in v1 (REQ-422).**

Two hardening measures are **required before any corporate-tier deployment**
of the mobile tier, and are **not implemented in v1**:

- **Certificate pinning.** v1 trusts the platform's system certificate store
  (`android/app/src/main/res/xml/network_security_config.xml`'s
  `<certificates src="system">`, `docs/mobile/architecture.md` — this
  section). A corporate-tier deployment, where the client may run on a
  managed device inside a network with a corporate TLS-inspecting proxy or
  where the threat model includes a compromised system trust store, needs
  pinning the platform's own certificate/public key so a MITM proxy with an
  installed root CA cannot intercept API traffic.
- **Root/jailbreak detection.** v1 performs no device-integrity check. A
  corporate-tier deployment needs a check (e.g. `flutter_jailbreak_detection`
  or an equivalent) gating access to tenant-scoped data on an
  un-rooted/un-jailbroken device, since OS-secure storage's guarantees
  (Keystore/Keychain hardware-backing) are weakened or bypassable on a rooted
  device.

Both are `[S]`-priority per `docs/mobile/requirements.md` MOB-5 — required
before corporate-tier, not before v1. Tracked here so the gap is a recorded
decision, not a silent omission discovered later.
