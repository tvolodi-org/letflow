# Runbook: the runtime-update demo module (QA only)

T-1641, UAT decision B5#10 (`docs/uat/ba-decisions/T-1631.md`, item 10). The module `runtime_demo`
(`Letflow.Modules.RuntimeDemo`) holds no data and has one route, `GET /api/v1/modules/runtime_demo/ping`
(permission `RuntimeDemoRead`, held by TENANT_ADMIN). It exists so the runtime-update gates of decision
0055 (D5 skew gate, D9 rollback) can be driven through the product's routes on QA.

## Where it exists

- Tests: listed in `config/test.exs`.
- QA: only a build made with the Docker build argument `LETFLOW_INCLUDE_RUNTIME_DEMO=true`.
  `deploy/redeploy-qa.sh` is the only place that passes it. The argument defaults to `false` in
  `deploy/Dockerfile`, so a production build, `redeploy-test.sh` and a plain `docker build` have no demo module:
  it is in no catalogue, has no route mount and cannot be installed. `config/config.exs` puts it in
  `:demo_modules` (never in `:modules`), so `priv/permission_matrix/effective.golden` does not know it.
- Never add it to a production build. Production is not approved for this project.

## The three releases

One build holds one manifest, so the release is a boot setting, no rebuild:
`LETFLOW_RUNTIME_DEMO_RELEASE` (`0.1.0` default, `0.2.0`, `0.3.0`; anything else stops the boot).

| release | min_upgradable_from | min_data_version |
|---|---|---|
| 0.1.0 | 0.1.0 | 0.1.0 |
| 0.2.0 | 0.1.0 | 0.1.0 |
| 0.3.0 | 0.1.0 | 0.3.0 |

## Changing the release on QA

Edit `LETFLOW_RUNTIME_DEMO_RELEASE` in the host `.env` (the compose `env_file`), then **recreate** the
container with the same arguments `deploy/redeploy-qa.sh` uses (`--project-directory` and
`-f deploy/docker-compose.qa.yml`): `docker compose ... up -d --force-recreate app`. A plain restart keeps the
old container environment. While running this sequence keep `LETFLOW_MODULE_UPGRADE_ON_BOOT=false`, or the
boot upgrade consumes the below-minimum state before the HTTP check.

## The sequence (tenant admin token, per tenant)

1. Release 0.1.0. Install: `POST /api/v1/tenant/modules` with `{"module_id": "runtime_demo", "rationale": "<text>"}`.
   `GET /api/v1/modules/runtime_demo/ping` is 200.
2. Set 0.2.0, recreate. `POST /api/v1/tenant/modules/runtime_demo/upgrade/plan`, then `.../upgrade` with the
   `plan_hash` and a rationale. `POST .../rollback` with `{"target_version": "0.1.0", "rationale": ...}` **succeeds**.
   Upgrade again.
3. Set 0.1.0, recreate (stored data is 0.2.0): `.../rollback` answers `module_version_ahead`, and `/ping`
   answers 503 `module_version_ahead`.
4. Set 0.3.0, recreate: `/ping` for the tenant still at 0.2.0 answers 503 `module_upgrade_required` (the
   `min_data_version` gate). Plan and apply the upgrade; `.../rollback` with target 0.2.0 answers
   `rollback_below_min_data_version`; `/ping` is 200.

Nothing is seeded: a tenant has the module only when its administrator installs it. CI proves every answer
above in `test/letflow/modules/runtime_demo/router_test.exs`; running the sequence on QA after the merge is an
operator step, and the scenario file is a follow-up task (see the sidecar under
`test/fixtures/uat/scenario-env-limitations/`).
