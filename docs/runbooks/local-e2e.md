# Local e2e run (Playwright specs in `web/tests/e2e/`)

Current recipe for GH #2486. It replaces the "What BLOCKED-ON-INFRA requires" text of
`docs/testing/REQ-122-e2e-inventory.md`, which is a historical report (August) and no longer a runbook.

## Ports and variables

| Piece | Default | Set by |
|---|---|---|
| Letflow dev backend | `http://127.0.0.1:4000` | `config/dev.exs` (`http_port: 4000`); also the Vite proxy default (`VITE_API_BASE_URL`) |
| Specs' backend URL | `http://127.0.0.1:4000` | `BPM_TEST_URL` (the spec defaults now match the dev backend; set it only for another backend) |
| Keycloak | `http://localhost:8082` | `docker-compose.yml`, host port `LETFLOW_KEYCLOAK_PORT` (default 8082) |
| Specs' Keycloak URL | `http://localhost:8082` | `BPM_IDP_BASE_URL` (`web/tests/e2e/helpers.ts`); use `localhost`, not `127.0.0.1`, so the token `iss` matches the backend |
| Keycloak client | `letflow-web` | `BPM_IDP_CLIENT_ID` |
| SPA under test | `http://127.0.0.1:4173` | `E2E_BASE_URL`; Playwright's `webServer` starts the dev server itself |

If you changed `LETFLOW_KEYCLOAK_PORT` or the backend port, export `BPM_IDP_BASE_URL` and `BPM_TEST_URL` to match.

## Sequence

1. Start postgres and Keycloak. Keycloak starts with `--import-realm` and mounts `priv/keycloak/realms`,
   so the `bpm-default` realm is imported on first start (clients `letflow-web`, `letflow-mobile`; users
   `admin-user`/`admin-pass`, `designer-user`, `tenant-admin-user`, `operator-user`, `worker-user`):

   ```
   docker compose up -d postgres keycloak
   ```

2. Backend on port 4000 (from the repository root):

   ```
   mix deps.get
   LETFLOW_DEV_DB_CONFIRMED=1 mix ecto.setup
   LETFLOW_DEV_DB_CONFIRMED=1 mix run --no-halt
   ```

3. Specs (from `web/`; `npm ci` once):

   ```
   cd web
   BPM_TEST_URL=http://127.0.0.1:4000 BPM_IDP_BASE_URL=http://localhost:8082 \
     npm run test:e2e -- tests/e2e/tenants.e2e.spec.ts
   ```

   `npm run test:e2e:list` lists the specs without running them. Run one spec at a time while developing.

## Specs that need more than `bpm-default.json`

| Spec | Extra need |
|---|---|
| `oidcf2-subdomain.e2e.spec.ts` | backend only (`GET /api/tenant-config`); no Keycloak |
| `sh05-06.shell.e2e.spec.ts` | nothing (Playwright starts the SPA) |
| `uat-alice-login.e2e.spec.ts` | a `swiftroute` realm with user `alice.bauer` / `Alice-pass-001` (not in `bpm-default.json`) |
| `uat-tenant-url.e2e.spec.ts` | `bpm-default` plus a second tenant realm; `/health/ready` on backend and IdP |
| `env04.e2e.spec.ts`, `onboarding/*`, onboarding pipeline specs | Keycloak master-realm admin credentials (`admin` / `admin` in compose) to create and delete realms; they seed their own tenants via `POST /api/v1/onboarding` or `POST /api/v1/admin/tenants` |
| specs using `worker-user-2` | a user `worker-user-2` / `worker-pass-2`, absent from `bpm-default.json` |
| `pipelines/*` that call `db-exec.ts` | direct database access to the dev database |

Specs mocking `/api/v1/**` still need Keycloak or an injected session, see the spec header.
Use fresh tenants only; never point the specs at a shared or QA backend.
