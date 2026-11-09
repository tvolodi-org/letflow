# Sign-in and token rate limits (429 with Retry-After)

Part 1 of BA batch 2 item 6 (GH T-1558). Letflow has no login route of its own (Keycloak signs
users in), so the limits sit where a credential can be guessed or a tenant slug enumerated.

## What is limited

| Surface | Counted | Default | Refused with |
|---|---|---|---|
| Every `/api/v1` request (bearer JWT or `lf_tok_` token) | only a presented-but-wrong credential (failed JWT verification, unknown realm or tenant, wrong or revoked API token, unknown tenant slug) | 10 per minute per address | 429 instead of the 401, once the allowance is spent |
| `GET /api/tenant-config`, `GET /api/mobile/tenant-config` | every request | 60 per minute per address | 429 |

Not counted: a request with no `Authorization` header, an expired API token, an expired (but
correctly signed) JWT, and any successful request. A request is never refused before its
credential is checked: a valid JWT or API token is handled normally even when the address's
failure allowance is spent; only a failing credential gets 429 instead of 401. A busy office
behind one address is therefore not throttled by its own good traffic.
`/api/login-discovery`, `/api/public` and `/admin/v1` have their own limiters (unchanged).

## Reading a 429

Status 429, header `retry-after: <seconds>` (at least 1), `cache-control: private, no-store`, and
the same body whatever the cause: it never says whether a tenant slug or token exists.
Telemetry: `[:letflow, :auth_attempt_limit, :outcome]` with `%{outcome: :rate_limited, mode: :failures | :requests}`.
Nothing else is logged; keys hold only the address (IPv6 as its /64).

## Settings

* `LETFLOW_AUTH_FAILURES_PER_MIN` (optional positive integer): failed credentials allowed per
  address per minute. Unset keeps 10. An invalid value stops the boot (the value is not echoed).
* `config :letflow, Letflow.Plugs.AuthAttemptLimit` keys: `failure_capacity`,
  `failure_refill_per_sec`, `request_capacity`, `request_refill_per_sec`, `max_keys`
  (default 100000; when the table is full a failing credential from a new address gets 429, valid ones are unaffected), `sweep_interval_ms`.

The numbers are the BA's UAT assumptions. **Production values are the process owner's decision.**

## Behind a proxy

The address comes from `Letflow.Plugs.ClientIp`: `X-Real-IP` is trusted only from a peer inside
`LETFLOW_TRUSTED_PROXIES`. Without it every user shares the proxy's address, so a guesser can use
up the failure allowance of everyone, but only the failing credentials then see 429; valid ones keep working. Set the trusted proxy list in any shared deployment.

## Not in this part

Idle and absolute session time with the "session ended" screen (part 2) and the logout check
(part 3) are separate tasks.
