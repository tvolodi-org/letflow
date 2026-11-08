# Demo instance: answers and files for infra (T-1473, D-108)

Answers to the open items O2, O3, O5, O8 and O11 of the infra plan
(`ai-dala-infra/runs/2026-11-07-letflow-demo-instance-plan-001`, step-04 "Open items", step-06 "Still blocked on the
operator"). Every answer was read from the code; the symbol that proves it is named. Nothing here is a secret: the realm
files carry no password, the scripts read passwords from files or the environment.

Files:

| File | Purpose |
|---|---|
| `docs/runbooks/demo-realm/demo-showroom.json` | Keycloak realm `demo-showroom` (the showroom tenant) |
| `docs/runbooks/demo-realm/demo-platform.json` | Keycloak realm `demo-platform` (the platform tenant, operator only) |
| `scripts/demo_smoke_read.sh` | O2: password grant, then one authenticated read |
| `scripts/demo/demo_counts.sh` | O2: "demo data survived" as counts, `snapshot` and `compare` |
| `scripts/demo/demo_platform_bootstrap.sh` | O3: platform tenant and `PLATFORM_ADMIN` on a fresh database |
| `scripts/demo/demo_showroom_seed.sh` | the showroom data (see `docs/runbooks/demo-showroom.md`) |

## Names and values (O11)

| Item | Value |
|---|---|
| Keycloak public URL | `https://auth-demo.letflow.ai-dala.com` |
| Realms | `demo-showroom` (tenant slug `showroom`), `demo-platform` (tenant slug `platform`) |
| Browser client | `letflow-web` (public, standard flow with PKCE, **direct grants off**); redirect URIs and web origin only `https://demo.letflow.ai-dala.com` |
| Smoke and seed client | `letflow-demo-smoke` (public, **direct grants only**, no redirect URIs); same audience and `roles` mappers. The password grant is kept off the browser client of a public host. |
| Brute-force protection | on in both realms: 5 failures, then a lockout that grows to at most 15 minutes |
| Users | showroom: `demo-admin` and `demo-admin2` (`TENANT_ADMIN`), `demo-smoke` (`TASK_WORKER`, the smoke user, a normal tenant user). platform: `demo-platform-admin` (`PLATFORM_ADMIN`). No credentials in the JSON. |
| Roles | the nine built-in role names, exactly `Letflow.Api.Authorization.roles/0` (a test compares them) |

Environment values:

```
OIDC_KEYCLOAK_BASE_URL=https://auth-demo.letflow.ai-dala.com   # backend: discovery and token issuer, see O3
OIDC_CLIENT_ID=letflow-web                                     # backend: the audience a token must carry
BPM_IDP_BASE_URL=https://auth-demo.letflow.ai-dala.com         # what GET /api/tenant-config tells browsers (optional if the line above is set)
VITE_OIDC_AUTHORITY=https://auth-demo.letflow.ai-dala.com/realms/demo-showroom   # web build fallback only, see O5
VITE_OIDC_CLIENT_ID=letflow-web                                # web build fallback only
CORS_ALLOWED_ORIGINS=https://demo.letflow.ai-dala.com          # comma list; empty means no cross-origin caller is allowed
LETFLOW_DEFAULT_TENANT_SLUG=showroom                           # slug of the tenant the app lands on without ?realm= or a remembered slug, see O5
LETFLOW_ENV_LABEL=                                             # banner text; empty = no TEST ENVIRONMENT banner, unset = default banner (QA), see O5
LETFLOW_PLATFORM_TENANT_ID=<uuid printed by demo_platform_bootstrap.sh create>
```

Passwords are set after the import, from files, never from the repository:

```
kcadm.sh set-password -r demo-showroom --username demo-smoke --new-password "$(cat /path/to/file)"
```

(repeat for `demo-admin`, `demo-admin2`, and in `demo-platform` for `demo-platform-admin`).

## O5: OIDC authority and client id at runtime

**Yes, no web rebuild per promote.** The SPA calls `GET /api/tenant-config` at load and uses its `oidc_authority` and
`client_id` (`web/src/auth/tenantConfig.ts`, `fetchTenantConfig`). The backend builds them per request from
`BPM_IDP_BASE_URL`, `KEYCLOAK_BASE_URL` or `OIDC_KEYCLOAK_BASE_URL` (first one set wins) plus the tenant's `idp_realm_id`, and
from `OIDC_CLIENT_ID` (`Letflow.Routers.TenantConfig`). `VITE_OIDC_AUTHORITY` and `VITE_OIDC_CLIENT_ID` are only the fallback
when that request fails, so one build serves every promote.

**Default tenant (runtime setting `LETFLOW_DEFAULT_TENANT_SLUG`).** `?host=` has no host-to-tenant binding, so a visit
to `https://demo.letflow.ai-dala.com/` with no `?realm=` and no remembered slug is answered with the default tenant. Set
`LETFLOW_DEFAULT_TENANT_SLUG=showroom` in the backend environment (a tenant slug, not a realm id; read per request, restart
the backend to change it, no web rebuild). The root URL and deep links in a fresh tab then land on the showroom realm. Order
of choice: `?realm=` first, then the slug remembered in the browser session, then this default. Unset or empty keeps the
constant `bpm-default` (QA and production). A slug that is unknown, inactive or has no realm also falls back to
`bpm-default`. `https://demo.letflow.ai-dala.com/?realm=showroom` still works; an nginx redirect is no longer needed.

**Environment banner (runtime setting `LETFLOW_ENV_LABEL`).** The yellow banner shows for test-type tenants. Three states:
unset keeps the default `TEST ENVIRONMENT` banner (QA); set to empty (or blanks) hides it (the demo instance sets it empty);
set to text shows that text instead (trimmed, at most 40 characters, not translated). The backend serves it as `env_label` in
`GET /api/tenant-config` and the SPA reads it at load: restart the backend to change it, no web rebuild.

## O3: a fresh database, the platform tenant and an internal Keycloak URL

**No separate internal Keycloak URL.** The backend fetches discovery from `OIDC_KEYCLOAK_BASE_URL/realms/<realm>`
(`Letflow.Oidc.ProviderRegistry`) and checks the token `iss` against that same string, so it must be the public issuer. Plain
`http://` is refused in production (`allow_unsafe_http` is set only in `dev.exs` and `test.exs`, not from the environment). The
backend container must therefore resolve and reach `auth-demo.letflow.ai-dala.com` (host DNS, or an `extra_hosts` entry to the
nginx address). Audience: the access token must carry `letflow-web`, and the `roles` claim comes from the realm-roles mapper;
both mappers are in the realm files for both clients.

**The platform tenant.** `LETFLOW_PLATFORM_TENANT_ID` (a UUID, not a secret) is read once at boot
(`Letflow.PlatformTenant.parse_env/1`); `PLATFORM_ADMIN` exists only inside that tenant. A fresh database has no route that
creates the first platform tenant (every tenant route needs a `PLATFORM_ADMIN` of an existing one), and the provisioner
credential makes demo-tier tenants that the sweep expires after 14 days. So the first one is made on the release:

| Step | Command | Result |
|---|---|---|
| 1 | import both realm files, set the passwords | realms and users exist |
| 2 | `RELEASE_CMD="docker exec -i <backend> bin/letflow" bash scripts/demo/demo_platform_bootstrap.sh create` | tenant `platform` created and provisioned; prints `PLATFORM_TENANT_ID=<uuid>` |
| 3 | put the uuid in the backend environment as `LETFLOW_PLATFORM_TENANT_ID`, restart the backend | the pin is read at boot |
| 4 | `... demo_platform_bootstrap.sh finish` | the `PLATFORM_ADMIN` role group is created (`Release.backfill_platform_roles`) and checked (`Release.check_platform_role_groups`) |
| 5 | `SMOKE_PASSWORD_FILE=... BASE_URL=... KEYCLOAK_URL=... bash scripts/demo/demo_platform_bootstrap.sh verify` | `PASS login+read /api/v1/me/access`: the platform user is `PLATFORM_ADMIN` |
| 6 | mint `PLATFORM_ACCESS_TOKEN` in realm `demo-platform` with client `letflow-demo-smoke`, then run the showroom seed with `DEMO_REALM=demo-showroom`, `DEMO_HOSTNAME=<demo host>`, `ADMIN_REALM=demo-showroom`, `BPM_IDP_CLIENT_ID=letflow-demo-smoke`, `BPM_IDP_BASE_URL=https://auth-demo.letflow.ai-dala.com` | the showroom tenant is created and filled |

Why `finish` comes after the restart: `provision_and_migrate` seeds the role groups while the pin is still unset, so
`PLATFORM_ADMIN` is not created in step 2; the backfill adds it and resets `role_claims_synced_at`, so the next login re-syncs
roles. Every step can be repeated: `create` finds the slug and prints the same uuid, `finish` changes nothing when complete.
`demo_platform_bootstrap.sh --print-elixir` prints the expression for an operator without the
script. Exit codes: 0 done, 1 a step failed, 2 bad input.

## First install: the exact order

On an empty database the smoke cannot pass before the seed has made the showroom tenant. Do these in order:

1. **Empty DB boot.** Start the backend on a database with no tenant (`/health` answers; `LETFLOW_PLATFORM_TENANT_ID` is not set yet).
2. **Realm import.** Import both realm files and set the passwords (O3 table, step 1).
3. **Platform tenant.** `demo_platform_bootstrap.sh create` (prints `PLATFORM_TENANT_ID=<uuid>`).
4. **Pin and restart.** Set `LETFLOW_PLATFORM_TENANT_ID`, restart the backend, run `demo_platform_bootstrap.sh finish`, then `verify` (this smoke passes already).
5. **Platform token.** Mint `PLATFORM_ACCESS_TOKEN` in realm `demo-platform` (O3 table, step 6).
6. **Seed.** Run the showroom seed; it creates the `showroom` tenant.
7. **Smoke.** `scripts/demo_smoke_read.sh` (login and authenticated read) must now print `PASS`.
8. **Repeat.** Every step can be repeated safely.

Before step 6 the showroom smoke exits **3** (`tenant not seeded yet`) by design: `promote-demo.sh` treats exit 3 on a first install as
"run the seed, then repeat the smoke", and on a later promote (the tenant existed before) as a failure.

## O2: smoke path and "demo data survived"

**Smoke path.** One authenticated read endpoint: `GET /api/v1/me/modules` (every role may call it; it is tenant-scoped through
the token's realm, so one call proves realm discovery, token verification, user provisioning and the tenant schema; it lists the
installed modules). The smoke user is `demo-smoke` in realm `demo-showroom`, a normal tenant user with the role `TASK_WORKER`.

```
SMOKE_PASSWORD_FILE=/run/secrets/demo_smoke_password \
BASE_URL=http://127.0.0.1:3311 KEYCLOAK_URL=https://auth-demo.letflow.ai-dala.com \
  bash scripts/demo_smoke_read.sh
```

Output is one line: `PASS login+read /api/v1/me/modules modules=<n>` (exit 0), or `FAIL login: HTTP <code>` /
`FAIL read: HTTP <code>` (exit 1); exit 2 is bad input; exit **3** with `NOT SEEDED: tenant not seeded yet (...)` means the login worked, the
read answered 401 and the public `GET /api/tenant-config?realm=<slug>` resolves the slug to the default realm (`bpm-default`), i.e. the
tenant does not exist yet (first install before the seed). The backend answers 401 for a bad token and for a missing tenant alike on
purpose, so the script asks tenant-config; `SMOKE_TENANT_SLUG` (default `showroom`) and `SMOKE_DEFAULT_REALM` (default `bpm-default`)
tune that check. Any other 401 stays `FAIL read` (exit 1). `demo_platform_bootstrap.sh verify` passes `SMOKE_TENANT_SLUG=platform`
(its tenant must be bound to realm `demo-platform`, otherwise a 401 there also reads as exit 3). It never prints the password, token or body. Defaults are in the script
header; `SMOKE_REALM`, `SMOKE_CLIENT_ID`, `SMOKE_USER`, `SMOKE_READ_PATH` and `EXPECT_JQ` can be overridden. After five wrong
passwords Keycloak locks the user for a while; the script never retries.

**What survived** is a set of `key value` counts from one read-only SQL statement:

```
PSQL="docker exec -i <postgres> psql -U <user> -d <db> -X -A -t -F ' '" bash scripts/demo/demo_counts.sh snapshot > before.txt
# ... promote ...
PSQL=... bash scripts/demo/demo_counts.sh snapshot > after.txt
bash scripts/demo/demo_counts.sh compare before.txt after.txt     # exit 0, or one "LOST key before after" per violation
```

| Key | Meaning |
|---|---|
| `tenants` | rows in `public.tenants` |
| `tenant.<slug>.status.<status>` | the tenant's status |
| `tenant.<slug>.modules_active`, `tenant.<slug>.module.<id>` | installed (active) modules; the version is not compared |
| `tenant.<slug>.users`, `.users_active` | users and active users |
| `tenant.<slug>.records.<entity_type>` | current, not deleted records per record type |
| `tenant.<slug>.ledger_entries.<cause>`, `.ledger_legs` | ledger postings per cause, and legs |
| `tenant.<slug>.documents` | documents |

`compare` fails when a key of `before` is missing in `after` or lower (extra keys are fine; a promote may add data) and
exits 2 on an empty file. Keycloak realm and user counts stay on infra's side. Expected after the showroom seed on the pinned
build (from `test/scripts/demo_showroom_seed_test.exs`): `records.catalog_item` at least 10, `records.location_node` at least 6,
`records.assets_card` 6, ledger causes receipt, issue, transfer, hand_over, return, write_off and opening at least 1 each.

## O8: websockets and SSE

**Neither.** The app is plain JSON over HTTP. This search finds nothing in code (exit status 1, no output):

```
grep -rn --include='*.ex' --include='*.exs' --include='*.ts' --include='*.tsx' --include='*.dart' \
  "send_chunked\|Plug.Conn.chunk\|WebSockAdapter\|EventSource\|WebSocket\|text/event-stream" lib web/src apps/mobile/lib
```

and `deploy/nginx/letflow-test.conf` already says "JSON API only — no WebSocket upgrade headers or caching rules needed".
Upgrade headers are harmless but not needed. Timeouts: the SPA client and the seed use 60 s; the longest calls are document
printing and imports, so `proxy_read_timeout 60s` is enough, and `client_max_body_size 5m` is enough for the seed.

## Findings

* The demo root URL lands on showroom once `LETFLOW_DEFAULT_TENANT_SLUG=showroom` is set (see O5).
* No internal Keycloak URL (see O3).
* `Letflow.Release` has no function that creates the platform tenant; the bootstrap script runs an `rpc` expression. Promote it
  into `Release` if infra wants an `eval`-only path.
