# Letflow — mobile tier (`apps/mobile/`)

Flutter/Dart client for Letflow. A **generic interpreter of server-delivered
definitions**, on the same principle as `web/` — see
[`docs/mobile/architecture.md`](../../docs/mobile/architecture.md) for the
governing principle, stack, and v1 boundary, and
[`docs/mobile/requirements.md`](../../docs/mobile/requirements.md) for
`MOB-1..8`.

As of `REQ-423` the app has: shell/module layout and static guards
(`REQ-419`), OIDC Authorization-Code + PKCE bootstrap (`REQ-421`, `MOB-2`),
on-device token-security hardening (`REQ-422`, `MOB-5`), and a local
definition cache with background delta sync and an airplane-mode tenant home
screen (`REQ-423`, `MOB-3` part 1). Pinned-form-version resolution
(`REQ-424`) and the actual form/list/task/process renderers (`REQ-426..428`)
are not built yet.

## Run

```
flutter pub get
flutter analyze
flutter test
flutter run -d emulator-5554
```

## API base URL

The platform API base URL is supplied at build/run time via:

```
--dart-define=LETFLOW_API_BASE_URL=<url>
```

This is a **platform** endpoint per environment (dev/staging/prod) — never a
tenant identifier. The app resolves tenant identity separately, via a slug or
deep link (`MOB-2`, `docs/mobile/architecture.md` §1). One tenant-agnostic
build serves every tenant; the API base URL is the only thing that varies per
environment.

## Reaching a local backend from the emulator

Letflow's dev stack (`docker-compose.yml`, `config/dev.exs`) exposes:

- the Letflow API on `localhost:4000`
- Keycloak on `localhost:8082` (the `LETFLOW_KEYCLOAK_PORT` default;
  per-workspace local state — check your own `LETFLOW_KEYCLOAK_PORT` if it
  has been overridden)

Once per emulator boot, before `flutter run`, forward both ports from the
device to the host:

```
adb reverse tcp:4000 tcp:4000
adb reverse tcp:8082 tcp:8082
```

Then run with:

```
flutter run -d emulator-5554 --dart-define=LETFLOW_API_BASE_URL=http://localhost:4000
```

### Why not `10.0.2.2`

The Android emulator's alias for the host loopback, `10.0.2.2`, reaches the
API fine. It does **not** work for the login flow: Keycloak stamps a token's
`iss` (issuer) claim from the host the browser used to authenticate. A login
reached through `10.0.2.2` yields an `iss` of `10.0.2.2`, which the backend's
configured OIDC issuer (`localhost:<port>`, see `config/dev.exs`) rejects —
the token verifies against the wrong issuer and every subsequent authenticated
call fails.

`adb reverse` avoids this because the device reaches **`localhost`** for both
the API and Keycloak, matching the issuer the backend expects. This is why
`10.0.2.2` is not an acceptable substitute for the two `adb reverse` commands
above, even though it appears to work for unauthenticated calls.

## Structure

```
lib/
  main.dart          # entry point only
  app.dart            # ProviderScope root + go_router (the one sanctioned
                       # app/router file)
  bootstrap/           # startup sequence + navigation bootstrap
  auth/                # OIDC Authorization-Code + PKCE (flutter_appauth)
  api/                 # Dio-backed HTTP client
  definitions/         # definition fetch/cache/version-pin
  renderers/
    renderer_registry.dart   # keyed by definition type; unknown type falls
                              # back to an explicit "unsupported definition
                              # type" widget, never a blank screen
    form/  list/  process/  task/
  features/           # one subdirectory per installed module
    module_manifest.json     # declares each feature's depends_on
  design_system/
  i18n/
  shared/
```

## Local definition cache

**Local definition cache: Sembast, not Isar.**
`docs/migration/decisions/0012-mobile-tier-stack.md` names "Isar or
equivalent" for the local definition cache — the "or equivalent" licenses
substituting another store; the decision record itself says nothing further
about *why* a substitution might be warranted. REQ-423 chose **Sembast**
(`package:sembast`) instead of Isar because it is pure Dart — no generated code
(`build_runner`), no native binary fetched per platform at build time —
which is the deciding property in this project's actual build environment:
this `README.md`'s own network/toolchain notes record that this sandbox has
no reliable package-registry/native-binary-fetch access, so a store
requiring a fresh native-binary/codegen fetch is untestable here by
construction, while a pure-Dart store's package itself (once fetched once,
same as any other `pubspec` dependency) needs nothing further at test or
build time. Sembast is a NoSQL document store (stores/records/values, not
SQL) that has shipped a stable 1.0+ API for years and is maintained by the
Flutter community (tekartik) with no code-generation step. It satisfies the
same "local structured object store" role Isar would have.

Resolved dependency versions (this implementation's `flutter pub get`):
`sembast: 3.8.7`, its transitive `synchronized: 3.4.0+1`, and `path_provider:
2.1.6` / `path: 1.9.1` (added solely to resolve the production on-disk store
location via `getApplicationSupportDirectory()`).

Cache entries are keyed by `(type, id, version)`. `/api/v1/definitions/delta`
discloses no `type` wire key today (it serves `process_definitions` rows
only) — the client stamps every ingested item with the literal
`kProcessDefinitionCacheType = 'process'`, a deliberate, flagged interim
assumption (`apps/mobile/lib/definitions/definitions.dart`), not a bug.

The cache is partitioned per tenant by physical file separation keyed by
`realmUrl` (`ActiveDefinitionCacheHolder`, mirroring `TenantTokenStore`'s own
`realmUrl`-keyed token partition) — opened/closed at the same three points
`navigation_bootstrap.dart`'s `ActiveRealmHolder.currentRealmUrl` is written:
`runTenantBootstrap`, `switchTenant`, and `logout`.

`DefinitionSyncService.syncOnce()` is a straight-line delta sync (never a
loop): at most two HTTP calls per invocation. An `"ARCHIVED"`-status item is
removed from the cache; `"DEPRECATED"` items are retained. A `400` response
to the `since` cursor resets it and performs exactly one full-history
resync — never a retry loop.

### Pinned-form cache — a second, independent Sembast store

REQ-424 (`MOB-3` part 2) adds a **second, independent** Sembast database
file per tenant (`pinned_form_cache_<...>.db`, alongside
`definition_cache_<...>.db`), not a second store inside the existing
per-tenant definition-cache file. Reason: `SembastDefinitionCacheRepository`
already owns its `Database` handle privately, and the pinned-form cache's
key/value shape genuinely differs from the definition cache's —
`form_version` (`instance_definition_snapshots.definition_ver`) is a
`String`, not the `int` `DefinitionCacheEntry.version` uses, and its natural
key is two-part `(formId, formVersion)`, not three-part `(type, id,
version)`. Sharing a store would mean either widening the definition
cache's already-shipped `int` version type or forcing a meaningless
constant `type` component onto every pinned-form key. No new `pubspec.yaml`
dependency — same `package:sembast`, same tenant-partition-by-`realmUrl`
pattern (`ActivePinnedFormCacheHolder`, opened/closed at the same four
points `ActiveDefinitionCacheHolder` is).

`PinnedFormResolver.resolve({taskId, formId, formVersion})` never looks up
"the latest/active version of `formId`" — a `null` `formVersion` short-
circuits to `pinned-version-unavailable` before any I/O; a cache hit on the
exact `(formId, formVersion)` key returns with zero network calls; a cache
miss issues exactly one `GET /api/v1/tasks/:id` and caches the result under
that same pinned key. See
`lib/letflow/design/req424-mobile-pinned-form-version-resolution.md`.

## Session resume without network

`BootstrapController.attemptSessionResume()` (REQ-423) reads only secure
storage — zero network calls — so a previously-authenticated, currently
offline device can reach the tenant home screen without needing bootstrap's
usual three-call network sequence (tenant-config, OIDC exchange,
memberships-or-403) to succeed first. It lands in a dedicated
`BootstrapPhase.resumedOffline` state, deliberately distinct from
`BootstrapPhase.success`: membership and the installed-module list have not
been re-verified from the network.

## Camera scanning

The `codes` module (REQ-732, `lib/features/codes/`) adds a scan screen to the
generic client: the camera reads a barcode or QR code, the raw text goes
unchanged to `POST /api/v1/modules/codes/resolve`, and the screen shows what
the code names. A typed field is the fallback when the camera is refused. The
screen is reachable from the tenant home only when the tenant has the `codes`
module installed.

Package: `mobile_scanner`. It is the one package that reads both barcodes and
QR codes on Android and iOS and returns the raw text. Only
`lib/features/codes/mobile_scanner_source.dart` imports it; the rest of the
module uses the `ScanSource` interface, which tests replace with a fake, so no
test needs a camera. Permissions: Android `CAMERA` (camera not required),
iOS `NSCameraUsageDescription`. The lookup is online only; nothing is stored
on the device.

## Voice recording

The `stock` module (REQ-747, `lib/features/stock/voice/`) lets the count screen
and the receipt, issue and transfer forms fill a line from a spoken phrase. The
phone records AAC-LC into an `.m4a` file, sends it with a language hint (`ru` or
`kk`) to `POST /api/v1/modules/stock/voice/draft`, and shows the answered draft
for the user to check. A typed phrase goes to `.../voice/draft-text`. Voice
never saves, counts, issues or posts by itself. When a voice part is down the
screen says which one, and typing and scanning keep working.

Package: `record`. It is the one package that records AAC-LC into an `.m4a` on
Android and iOS and asks for the microphone permission itself. Only
`lib/features/stock/voice/package_recorder_port.dart` imports it; the rest uses
the `VoiceSource` interface, which tests replace with a fake, so no test needs a
microphone. Permissions: Android `RECORD_AUDIO` (a microphone is not required to
install), iOS `NSMicrophoneUsageDescription` (English only). The recording is a
temporary file that is deleted as soon as it is read; audio and transcript are
kept in memory only and the feature is online only.

## Static guards

`test/guards/` holds three ordinary Dart tests that fail `flutter test` (and
therefore CI) on a violation, not just warn:

- `module_boundary_guard_test.dart` — the core/module import boundary
  (decision `0039` D3): no file outside `lib/features/<id>/` imports from it
  except `lib/bootstrap/navigation_bootstrap.dart`, and a feature only imports
  another feature declared in its `depends_on`.
- `forbidden_dependencies_guard_test.dart` — no script runtime (Lua/JS/WASM),
  no CEL package, no webview package in `pubspec.yaml`/`pubspec.lock`.
- `tenant_identifier_guard_test.dart` — no compiled-in tenant/realm slug
  literal (e.g. `bpm-default`) and no tenant-specific asset.

Each guard's checker is also exercised against an in-test fixture that
violates the rule, to prove the guard actually fires.
