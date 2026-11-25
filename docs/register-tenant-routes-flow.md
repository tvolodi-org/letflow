# Register-tenant routes: ordered flow of `handle_create`

Routes 1 (`POST /api/v1/onboarding`, `routers/onboarding.ex`) and 2 (`POST /api/v1/tenants`,
`routers/tenants.ex`) share one order (T-2704). The start key is the slug alone.

| # | Step | Route 1 | Route 2 | Test (`register_routes_test.exs`) |
|---|------|---------|---------|------|
| 1 | Validate input (stateless: schema, byte and grapheme caps, reserved slug/hostname, field shapes) | `Validation.validate` + `validate_create_extras` + `codepoint_fit` | `Validation.validate` | (b) cap and validation tests |
| 2 | Replay check, key = slug alone: `RouteStart.started?` (engine `start_replay_check`) | `create_tenant/6` | `handle_create/1` | (c) replay, other values = 409 |
| 3 | Every state-dependent probe, in this order: realm probe (`verify_realm`, external), realm / hostname / slug taken (DB prechecks), `tenant_type` refusal | `create_tenant/6` then `create_new_tenant/6` | `tenant_type`, slug taken | (c) route 1 probe not_found / unreachable; (c) replay after create committed |
| 4 | Start the instance: `RouteStart.respond` -> `start_register_tenant/2` -> 202 | `start_registration/6` | `RouteStart.respond` | (a)(b) |

An existing start (same slug, same values) answers the first instance whatever the probes would say; the same
slug with other values is the engine's 409. A genuinely new registration meets every probe in step 3.
