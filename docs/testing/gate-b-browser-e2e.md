# GATE B browser end-to-end tests (Playwright)

The API walk of GATE B cannot see screen bugs: an id shown instead of a name, a Complete button that never appears, ISO dates
in Russian, a document screen that overflows at 390 px, a session that logs out when the access token expires. Two Playwright
specs drive the real screens in a real browser against a real backend and the real Keycloak sign-in (no stubs, no session
injection):

| Spec | What it checks |
|---|---|
| `web/tests/e2e/gate-b-stock.e2e.spec.ts` | S1 a count order made on screen; S2 a receipt made, issued, then claimed and completed from My Tasks; S3 an opening balance issued by user 1 and approved by user 2 (user 1 may not approve it: separation of duties); S4 Balances and Movements show rows and no screen shows a uuid (the R1 check); S5 the document screen at 1440 and 390 px (side by side, then no horizontal overflow) with screenshots; S6 dates in Russian are `DD-MM-YYYY` (no ISO date, no slash date) |
| `web/tests/e2e/gate-b-relogin.e2e.spec.ts` | the T-1400 fix on the real network: a `refresh_token` grant is POSTed to the token endpoint before the access token expires; no navigation to the identity provider's authorize page during 3 token lifespans of read-only activity; one injected 401 leads to exactly one renew and a replay, not a logout |

The pattern of the no-uuid check lives in `web/tests/e2e/support/noUuid.ts`, a copy of `web/src/test-utils/noUuidInDom.ts`;
`web/tests/unit/e2eNoUuid.test.ts` fails when the two drift apart.

## Run it locally

Needs docker compose, Elixir/OTP as in `.tool-versions`, Node 22, curl, jq, openssl.

```
bash scripts/e2e/stack_up.sh                       # Postgres + Keycloak + backend on :4000 + seed; writes .e2e/env
cd web && npm ci && npx playwright install chromium
set -a; . ../.e2e/env; set +a
npm run test:e2e:gate-b                            # the click-through; the web dev server is started by Playwright
E2E_RELOGIN=1 E2E_TOKEN_LIFESPAN=90 npm run test:e2e:gate-b   # adds the relogin spec (about 5 minutes)
bash ../scripts/e2e/stack_up.sh --down             # stop everything, remove the volume
```

`stack_up.sh` uses its own compose project (`letflow-e2e`), so it does not touch another checkout's database. If a stack of
another checkout holds the ports (5462 Postgres, 8082 Keycloak, 4000 backend), set `LETFLOW_DB_PORT`, `LETFLOW_KEYCLOAK_PORT`
and `PORT`. It generates throwaway secrets, creates the second approver `e2e-approver` (role `TENANT_ADMIN`) through the Keycloak
admin API, sets the realm access token lifespan (`E2E_TOKEN_LIFESPAN`, default 90 s) and runs `scripts/e2e/gate_b_seed.sh`
(masters only: org units, locations, items, lots, codes; the specs make the documents themselves). The realm template is not
edited.

## Run it against QA

Both specs read everything from the environment, so the same files run against a deployed environment:

| Variable | Meaning |
|---|---|
| `E2E_BASE_URL` | the deployed web app, for example `https://qa.example` (default `http://127.0.0.1:4173`) |
| `E2E_NO_WEBSERVER=1` | do not start the local dev server (QA runs) |
| `E2E_REALM` | optional `?realm=` for hosts that need it |
| `E2E_ADMIN_USER`, `E2E_ADMIN_PASSWORD` | a tenant administrator with the stock permissions |
| `E2E_ADMIN2_USER`, `E2E_ADMIN2_PASSWORD` | a second tenant administrator in the same realm (G3 is skipped without it) |
| `E2E_RUN_TAG` | text put into every note the spec makes, so a rerun on one tenant does not collide (default `e2e<time>`) |
| `E2E_SHOTS_DIR` | where S5 writes its screenshots (default `web/test-results/gate-b-shots`) |
| `BPM_IDP_BASE_URL` | the identity provider, when the helpers need it |

The tenant needs the masters of `gate_b_seed.sh` (org unit "Warehouse team" and "Sales team", location "Central warehouse" and
"Showroom", item "Laptop"); run `gate_b_seed.sh` first on a fresh tenant (`BASE_URL`, `TENANT_SLUG`, `ADMIN_*` in the
environment). Without the credentials every spec skips with a message; in CI the job fails instead.

```
cd web
E2E_NO_WEBSERVER=1 E2E_BASE_URL=https://qa.example E2E_ADMIN_USER=... E2E_ADMIN_PASSWORD=... \
E2E_ADMIN2_USER=... E2E_ADMIN2_PASSWORD=... npm run test:e2e:gate-b
```

### The relogin check on QA

Precondition: a realm with the Keycloak default access token lifespan (5 minutes), for example a fresh tenant realm with
defaults, or a test realm that infra sets back to 5 minutes. The gate-b3 realm has a 30 minute lifespan (raised for the
partner demo): a 5 minute test cannot show a refresh at about 4 minutes there, and the spec skips itself when the lifespan it
reads from the first token response is over 600 s. Run with `E2E_RELOGIN=1`; with the 5 minute default it takes about
15 minutes (3 lifespans). The spec writes the network log, without tokens, to `web/test-results/gate-b-relogin.log`.

## In CI

The job `Stock browser e2e (playwright)` in `.github/workflows/stock-e2e.yml` starts the same stack on the runner and runs the
click-through. It does not slow ordinary pull requests: its steps run only when the change touches the stock screens or the e2e
stack (`web/src/modules/stock/`, `web/src/pages/tasks/`, the two specs and their helpers, `scripts/e2e/`; the rule is
`scripts/ci_stock_e2e_paths.sh`), and always on the nightly schedule and on a manual dispatch. A run whose steps are skipped
reports success under the same name, so the check can be made required without blocking other pull requests. Adding it to the
required checks of the `main-queue` ruleset is a repository setting and is done by the operator. The relogin spec runs only on
the nightly schedule and on manual dispatch, with a 90 s access token lifespan (90 and not 60: the client renews 60 s before
expiry, so 60 s would refresh at once and prove nothing). Screenshots, the relogin log and traces are uploaded as the artifact
`stock-e2e-results`.
