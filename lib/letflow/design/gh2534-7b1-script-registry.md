# GH 2534 PR 7b-1: tenant-script registry (decision 0053 D1, D6, D9 part, D10)

Decision: `docs/migration/decisions/0053-tenant-scripted-rules.md` (ratified). Split accepted by
the supervisor: 7a runtime (merged, 02c682e0) -> **7b-1 registry (this)** -> 7b-2 policies
(kill switch, `scripts.sod`, `script_readable_master`) -> 7c handler. Rulings applied: HMAC
secret location (advisor Q2), interim read rule (Q3), the API-token SoD hole (advisor, then
tightened by SECURITY-REVIEWER B1, see 6.1). Revision 2: CODE-DESIGN-VALIDATOR findings 1-15
and SECURITY-REVIEWER B1, B2 and non-blocking 1-11 resolved, tagged [CDV n] / [SEC ...].

7b-1 adds tenant-facing MANAGEMENT routes and two permissions. It adds NO execution path for
published scripts (7c), so the kill switch (7b-2) has nothing to stop yet.

## 0. Verified facts (main 02c682e0)

* `Letflow.Secrets` (`lib/letflow/secrets.ex`): `put(attrs, opts)` (:86), `resolve(ref, opts)`
  (:266), `disable(ref, opts)` (:401); names `sec://tenant/<slug>/<namespace>/<name>[#<n>]`
  (:47-48, segments `[a-z0-9_-]`); purposes `:webhook_hmac | :generic` (`Secret.purpose`,
  `Ecto.Enum`, `secrets/secret.ex:35`); consumer/purpose table (:330-335); tenant check by slug
  -> tenant_id (:291-303); `key_id` max+1 with one retry (:154, :211). No tenant-facing secrets
  route; no reserved-namespace rule. Master key loaded at boot in every environment.
* API-token callers: `auth_context.user_id` = the token's owning user; `POST /identity/tokens`
  takes `user_id` AND `roles` from the body; `api_tokens` records no issuer
  (`identity/api_token.ex:26-36`). `auth_context` has no credential kind
  (`auth_pipeline.ex:403-421`, the only builder in `lib/`).
* `ScriptRunner.run/3` (7a): `{:ok, %{output, stats}}` or `{:error, code, detail}`; stats only on
  success; author detail only on error; requires `:tenant`, `:ctx`; raises `ArgumentError` on
  invalid opts.
* `Letflow.EventStore.Registry.JsonSchema.validate/2` validates a payload against a schema with
  a fixed keyword subset (`type`, `minimum`/`maximum`, `minLength`/`maxLength`, `enum`,
  `required`, `properties`, `items`, `additionalProperties: false`); it does not validate a
  schema itself.
* `Letflow.Repository.Canonicaliser.canonicalize_content("application/json", bytes)`: canonical
  JSON (sorted keys; integer-valued floats encoded as integers).
* Tenant tables: `priv/repo/migrations/*` guarded by `if prefix()` + an entry in
  `@tenant_scoped_migration_manifest` (`tenant_provisioning.ex:491-649`); latest
  `20261008000001`. Request bodies are capped at 2 MiB (`api_pipeline.ex:117`).

## 1. Table `script_rules` (tenant migration `20261014000001`)

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `key` | text | `^[a-z][a-z0-9_]{0,63}$` (CHECK) |
| `version` | integer | per key; never reused (rows are never deleted) |
| `hook_kind` | text | CHECK `= 'service_task'` (others reserved for Records E/F/T) |
| `status` | text | CHECK in `draft, discarded, published, retired, revoked` |
| `source` | text | CHECK `octet_length(source) <= 65536` |
| `manifest` | jsonb | section 3 |
| `test_cases` | jsonb | section 4 |
| `sha256` | text | section 2 |
| `contributors` | uuid[] NOT NULL | every user who saved this version, deduplicated |
| `publisher_id` | uuid null | |
| `published_at`, `retired_at`, `revoked_at`, `discarded_at` | utc_datetime_usec null | |
| `self_published` | boolean NOT NULL default false | 7b-2 writes it; false in 7b-1 |
| `inserted_at`, `updated_at` | utc_datetime_usec | |

UNIQUE (`key`, `version`). Index on (`key`, `status`).

**Status machine** [SEC B2, SEC nb 6, CDV 9]: `draft -> draft` (content save), `draft ->
published`, `draft -> discarded`, `published -> retired`, `published -> revoked`, `retired ->
revoked`. There is NO hard delete (`DELETE` route = discard), so a version number is never
reused and a discarded draft's contributors still count for SoD. Several versions of one key may
be `published` at once (pins choose a version, 7c); publishing a new version does not change an
older one.

**Trigger** `script_rules_guard()` (created in the tenant schema by the migration, `BEFORE UPDATE
OR DELETE FOR EACH ROW`), raising `ERRCODE 'LF001'` (`version_immutable`) on any violation, which
the context maps by `postgres.pg_code == "LF001"` (Postgrex puts an unknown SQLSTATE in `:pg_code`; `:code` is nil for it; never by message text) to 409 [CDV 1]:
* DELETE: always refused.
* `OLD.status = 'draft'`:
  * `NEW.status = 'draft'`: only `source`, `manifest`, `test_cases`, `sha256`, `contributors`,
    `updated_at` may change; `contributors` may only grow (`OLD.contributors <@ NEW.contributors`).
  * `NEW.status = 'published'`: content columns unchanged, `publisher_id` and `published_at`
    NOT NULL, and `NOT (NEW.publisher_id = ANY(NEW.contributors))` [SEC nb 6].
  * `NEW.status = 'discarded'`: only `status`, `discarded_at`, `updated_at` change.
  * anything else refused.
* `OLD.status IN ('published', 'retired')`: only `status`, `retired_at`, `revoked_at`,
  `updated_at` may change, and only along the machine above, setting exactly the matching
  timestamp (`retired_at` with retire, `revoked_at` with revoke).
* `OLD.status IN ('revoked', 'discarded')`: every UPDATE refused.
* 7b-2 will extend the trigger for `self_published` and confirmation (noted there).

## 2. sha256 (D1, D6) [CDV 5]

`Letflow.Scripts.Hash.compute(key, version, hook_kind, manifest, test_cases, source)` =
lowercase hex sha256 of
`lp("letflow-script-v1") <> lp(key) <> lp(Integer.to_string(version)) <> lp(hook_kind) <>
lp(canon(manifest)) <> lp(canon(test_cases)) <> lp(source)`, with `lp(x) = <<byte_size(x)::32>>
<> x` (the `Manifest.compute_hash/2` framing) and `canon(v)` = the binary `c` from
`{:ok, c} = Canonicaliser.canonicalize_content("application/json", Jason.encode!(v))` (sorted
keys, integer-valued floats as integers; the `{:error, :invalid_json}` branch cannot occur on
`Jason.encode!` output). It is ALWAYS computed from the row as RELOADED from the
database after the write (jsonb round-trip), in the same transaction, then stored; publish
recomputes from the locked row the same way, so the two can never drift.

## 3. Manifest (validated on save; re-validated at publish) [CDV 10]

```
{ "input_schema":  <schema>,          // REQUIRED
  "output_schema": <schema>,          // REQUIRED
  "fail_codes":    ["code", ...],     // REQUIRED (may be []), each ^[a-z][a-z0-9_]{0,63}$, <= 32, unique
  "limits":        {"instructions": pos_int, "timeout_ms": pos_int, "heap_words": pos_int},  // optional, each <= ScriptRunner.limits() max, else 422
  "reads":         [],                // optional; must be empty in 7b-1 (Q3)
  "restricted_inputs": ["field", ...] // optional; top-level input field names ^[a-z][a-z0-9_]{0,63}$, <= 32, each a key of input_schema.properties
}
```

* Any other key -> 422 `invalid_manifest`. `capabilities` (listed in D1) is REJECTED: D4 makes a
  script a pure function with no platform capability, so a capability list has nothing to grant.
* Schema well-formedness (no validator exists for that): a schema is a JSON object whose keys are
  within `type, properties, required, items, additionalProperties, enum, minimum, maximum,
  minLength, maxLength, title, description`, `"type": "object"` at the top level, recursively
  for `properties` values and `items`; `additionalProperties` only `false`; depth <= 8; canonical
  size <= 32 KiB. Else 422 `invalid_manifest`.
* **Q3 interim read rule (advisor):** stage 1 denies every entity read except the instance's own
  variables and types marked `script_readable_master` by a tenant-wide TENANT_ADMIN (flag in
  7b-2). In 7b-1 nothing can be flagged, so a non-empty `reads` -> 422 `reads_not_allowed`.
* `restricted_inputs` non-empty requires the PUBLISHER to hold `:EntitiesRestrictionsManage`
  at publish (D5; run-time re-check is 7c's).

## 4. Stored test cases (D10) [CDV 4, 6, 7]

`[{ "name": str<=64, "input": object, "expect": {"output": object} | {"fail": code} }]`, 1..32
cases; each `input` canonical <= 16 KiB; whole `test_cases` canonical <= 256 KiB; `source` <= 64
KiB; so a draft body stays far below the 2 MiB request cap. Every `input` must satisfy
`input_schema`, and an `expect.output` must satisfy `output_schema`, at save (422
`invalid_test_case`); `expect.fail` must be in `fail_codes`.

Running a case: `ScriptRunner.run(source, input, tenant: prefix, ctx: %{instance_id:
"00000000-0000-0000-0000-000000000000", node_id: "test", token_id: "case-<i>", now: publish
request time}, fail_codes: manifest.fail_codes, <manifest limits>)`. Pass = `{:ok, %{output:
o}}` with `canon(o) == canon(expect.output)` AND `o` satisfies `output_schema`; or
`{:error, :script_failed, %{fail: %{code: c}}}` with `c == expect.fail`. Each case acquires its
own `ScriptAdmission` slot (concurrency is bounded by 7a's admission, decision 0053 D8); the
whole run is bounded by a 30 s total budget (cases run in order; when the budget is spent the
rest are not run). Outcomes: any case failing -> 422 `test_case_failed` (`{name, outcome code}`,
no values); budget spent -> 422 `test_budget_exceeded`; a `script_busy` outcome -> 503
`script_busy` (retryable; never reported as a test failure).

## 5. Routes (`Letflow.Routers.ScriptRules`, mounted `/script-rules` in `api_pipeline.ex`) [CDV 11, 13, 14]

| Route | Policy key -> permission | Effect |
|---|---|---|
| `GET /` | `:ScriptRulesList` -> `:ScriptsWrite` | paginated (`Letflow.Api.Pagination`, cursor on `key`, `version`): `key, version, status, hook_kind, sha256, publisher_id, published_at, retired_at, revoked_at, discarded_at, self_published`. No source, manifest, test cases or contributors (D9) |
| `GET /:key/versions/:version` | `:ScriptRulesRead` -> `:ScriptsWrite` | all columns incl. source, manifest, test cases, contributors |
| `POST /:key/versions` | `:ScriptsWrite` | new draft (201); body `{hook_kind, source, manifest, test_cases}` |
| `PUT /:key/versions/:version` | `:ScriptsWrite` | replace a draft's source/manifest/test_cases |
| `DELETE /:key/versions/:version` | `:ScriptsWrite` | discard a draft (204) |
| `POST /:key/versions/:version/publish` | `:ScriptsPublish` | body `{sha256}`; section 6 |
| `POST /:key/versions/:version/retire` | `:ScriptsPublish` | body `{reason}` |
| `POST /:key/versions/:version/revoke` | `:ScriptsPublish` | body `{reason}` |
| `POST /:key/dry-run` | `:ScriptsWrite` | body `{version, input}`; section 7 |

* INV-5: an unknown key, an unknown or malformed version (path OR body), another tenant's key and
  a discarded version on read routes all return the SAME plain 404; bodies never echo values.
  Responses are built by explicit allowlist functions (`summary_map/1`, `version_map/1`, INV-2).
* `reason`: trimmed, 1..500 codepoints, refused if it contains any `\p{Cc}`, `\p{Cf}`,
  `\p{Zl}` or `\p{Zp}` character (422 `invalid_reason`) [CDV 8].
* **Authorization touch points** (`lib/letflow/api/authorization.ex`): `@type permission` add
  `:ScriptsWrite`, `:ScriptsPublish`; `@type endpoint_policy_key` add `:ScriptsWrite`,
  `:ScriptsPublish`, `:ScriptRulesList`, `:ScriptRulesRead`; `@permissions` add both (and the
  computed count in `core_permissions/0`'s doc); both tenant scope (not in
  `@platform_permissions`); `endpoint_policy_key/2` clauses for the 9 routes;
  `required_permission/1` clauses (`:ScriptRulesList`, `:ScriptRulesRead` -> `:ScriptsWrite`;
  identity for the two permissions); `core_role_allows?/2`: PROCESS_DESIGNER list gains
  `:ScriptsWrite`; TENANT_ADMIN gets both via tenant scope; PLATFORM_ADMIN gets both (all
  permissions; platform tenant only); TENANT_AUDITOR, PROCESS_OPERATOR, TASK_WORKER,
  AGENT_RUNNER, CANDIDATE none. `docs/roles.md`: exactly two matrix rows (supervisor-approved):
  ScriptsWrite = PLATFORM_ADMIN yes, PROCESS_DESIGNER yes, TENANT_ADMIN yes, others no, scope
  tenant; ScriptsPublish = PLATFORM_ADMIN yes, TENANT_ADMIN yes, others no, scope tenant. Tests
  updated: `authorization_test.exs` (core list, endpoint pairs),
  `authorization_tenant_admin_test.exs`, `authorization_tenant_auditor_test.exs`
  (`@auditor_refused_core`), `roles_matrix_parity_test.exs` (via the two rows).
* Deferred (supervisor): D9 auditor source read (`:AuditRead`) is GH #2548.

## 6. Writes and publish (D6)

### 6.1 Every registry WRITE requires an interactive (OIDC) credential [SEC B1]

`Letflow.Plugs.AuthPipeline.attach_auth_context/4` gains `credential: :oidc | :api_token`
(each branch sets its own value; nothing in a request can choose it). Draft create, save,
discard, publish, retire and revoke require `credential == :oidc`; anything else (an API token,
or a context without the field) -> 403 `api_token_not_allowed` before any other check. Reads
and dry-run are allowed for token callers. Reason: a TENANT_ADMIN can mint a token for ANY user
with any roles (`POST /identity/tokens`), and tokens record no issuer, so attributing a token
edit to its owning user (the advisor's first ruling) would still let an admin author under
another user's id and then publish as themselves. Refusing token writes closes both directions.
Residual, stated: an OIDC login is not always interactive (client-credentials clients exist);
SoD still holds because it is keyed by user id.

### 6.2 Draft create and save [CDV 2]

* Create: one transaction; `pg_advisory_xact_lock(hashtext($1))` with `$1 = prefix <> ":script_rules:" <> key` passed as a BOUND parameter (never interpolated, INV-7);
  `version = coalesce(max(version), 0) + 1` over ALL rows of the key (discarded included); insert
  with `contributors = [caller]`; reload; compute and store `sha256`; audit. The lock removes the
  max+1 race (no unique-index error path).
* Save: one transaction; `SELECT ... FOR UPDATE` on the draft; 409 `version_immutable` if not
  draft; set content and `contributors = OLD.contributors ∪ {caller}`; reload; store `sha256`;
  audit. Concurrent saves serialise on the row lock, so no contributor is lost.
* Discard: `FOR UPDATE`; draft -> discarded, `discarded_at`; audit.

### 6.3 Publish [CDV 6, SEC nb 3, 4]

Pre-checks, no transaction, BEFORE any script runs: credential (6.1); the version exists and is
draft; SoD (below) against the current rows; `restricted_inputs` permission; the body `sha256`
equals the stored `sha256` (409 `content_changed`). Then run the test cases (section 4, no
connection held). Then ONE transaction: the same per-key advisory lock as create, then `FOR UPDATE` on the row; re-check status draft, stored
`sha256` == body `sha256` (else 409 `content_changed`), SoD; set `published`, `publisher_id`,
`published_at`; audit `script_rule.published`.

**SoD set (D6, strict)** [SEC nb 4]: `P` = the highest `version` of this key with `published_at`
NOT NULL (published, retired or revoked); the set is the union of `contributors` over every row
of the key with `version > P` (draft and discarded included) plus this version's own
`contributors` (covers publishing an older draft after a newer publish). The publisher's user id
in the set -> 403 `publisher_is_contributor`. The trigger re-checks this version's own set.

### 6.4 Retire and revoke

`FOR UPDATE`; transition per section 1 (published -> retired; published or retired -> revoked);
audit with the reason. Retiring a version referenced by an active definition is blocked by 7c
(D3), not here.

## 7. Dry-run (D10) [CDV 4, 14, SEC nb 7]

`POST /:key/dry-run {version, input}`; `version` integer of an existing non-discarded version
(draft, published, retired or revoked), else the plain 404; `input` must be a JSON object
satisfying `input_schema`, canonical <= 64 KiB, else 422 `invalid_input`. Runs
`ScriptRunner.run/3` with `tenant: prefix`, `author_detail: true`, `fail_codes:
manifest.fail_codes`, the manifest limits and a dry-run ctx (`instance_id` all zeros,
`node_id: "dry-run"`, `token_id: "dry-run"`, `now`: request time). Dry-run NEVER performs reads,
now or after 7b-2 relaxes `reads` (it gets caller input only), writes no entity and no instance
event.

Response: `{outcome: "ok" | <stable code>, output?, fail?, stats?, author?}`: `output` and
`stats` on success; `fail` on `script_failed`; `author` (sanitised message, line, prints; F-D:
host frames and paths stripped by 7a) on every outcome. "Author" in D10 is read as "the
`ScriptsWrite` caller", who can read the source anyway. **7a change (additive):** with
`author_detail: true`, `ScriptRunner.run/3` also returns `author: %{prints, prints_dropped}` on
success (today only on errors). A success output failing `output_schema` is reported as
`output_invalid`. Audited: `script_rule.dry_run` with key, version, outcome code only.

## 8. Audit (D9) [CDV 12]

`Audit.append_multi/4` in the same Multi as each change; `actor_id` = caller user id;
`resource_type: "script_rule"`, `resource_id` = row id; `before_state` / `after_state` maps with
`key, version, status, sha256` plus:
* `draft_created`: after `contributors`; `draft_updated`: before/after `sha256`, after
  `contributors`; `draft_discarded`: after `discarded_at`;
* `published`: after `publisher_id`, `contributors`, `test_cases_sha256` (sha256 of
  `canon(test_cases)`), `restricted_inputs_checked: true | false`;
* `retired` / `revoked`: after the timestamp and `reason`;
* `dry_run` (`Audit.insert_entry/3`, nothing else written): `outcome`.
Never source, manifest bodies, test-case inputs, dry-run input or output.

## 9. HMAC secret (D9, advisor Q2) [CDV 3, SEC nb 1, 2]

* `Secret.purpose` (`Ecto.Enum`) and the `@type`/`@spec` unions gain `:script_hmac`; the
  consumer table gains consumer `:script_runner`, allowed purposes `[:script_hmac]`; existing
  consumers (`:generic`, `:webhook_dispatcher`) can NOT resolve `:script_hmac`.
* **Reserved namespace `platform`:** `put(attrs, opts)` (namespace from `attrs`),
  `resolve(ref, opts)` and `disable(ref, opts)` (namespace parsed from the reference, pinned or
  not) return `{:error, :reserved_namespace}` for namespace `platform` unless `opts[:platform] ==
  true`. Only `Letflow.Scripts.HmacSecret` passes it (a source-scan test asserts that).
* `HmacSecret.ensure(tenant)` (tenant struct with id and slug): one transaction with
  `pg_advisory_xact_lock(hashtext('script-hmac:' || tenant_id))`; if an `:active` row exists for
  `(tenant_id, "platform", "script-input-hmac")` (checked by tenant id, never by the slug-bearing
  reference) -> `:ok`; else `Secrets.put(%{tenant_id, namespace: "platform", name:
  "script-input-hmac", purpose: :script_hmac, plaintext: :crypto.strong_rand_bytes(32),
  created_by: "system:provisioning"}, platform: true)`. Never logs or returns the plaintext.
* Provisioning: `TenantOnboarding.provision_and_migrate/1` calls it after role seeding (a failure
  leaves the tenant `:migrating`, like role seeding).
* Backfill: `mix letflow.backfill_script_hmac_secrets` (app.start, iterate registrations,
  `ensure/1`, idempotent, `System.halt(1)` on failure, prints counts only). Chosen over the boot
  migration replay because `put` needs the tenant row and must not run inside a schema
  migration's transaction. 7c fails a run closed (`script_rejected` + one operator alert) when
  the secret is missing; never created lazily.

## 10. Tests (TEST-DESIGNER brief)

AC8: published/retired/revoked rows immutable at DB level (raw `Repo.update_all`/delete refused, `postgres.pg_code == "LF001"`); retire and revoke still work through the context; draft->published without publisher or
with the publisher in `contributors` refused by the trigger; publisher in the contributor set
refused (403); a contributor to an earlier DISCARDED draft since the last publish refused; stale
sha256 refused (409); failing stored test blocks publish; zero test cases refused; `script_busy`
during tests -> 503; cross-tenant key/version and malformed body version = exact missing-key 404;
source absent from `GET /`; pagination. Token rule: draft create/save/discard and publish via an
API token -> 403 `api_token_not_allowed`, including a token minted for a non-contributor user;
GET and dry-run via token allowed. Concurrency: two concurrent saves keep both contributors; two
concurrent creates get versions n and n+1. Q3: non-empty `reads` refused. Manifest: unknown key,
`capabilities`, oversize limits, malformed schema refused. Permissions: PD writes and dry-runs
but cannot publish; TA publishes; auditor and other roles 403 everywhere; roles.md parity. New
TA publish tests set `credential: :oidc` in their hand-built `auth_context`. Dry-run: author
detail on success and error, no entity/instance write, audited without values, revoked version
allowed, discarded 404. Secrets: reserved namespace refused for put/resolve/disable without the
flag; only `HmacSecret` passes the flag (source scan); `ensure/1` idempotent under concurrency
(one row); provisioning creates it; the mix task backfills a tenant without one; `:generic`
consumer cannot resolve it.

## 11. Out of scope

7b-2: `script_policy` (kill switch, `scripts.sod`, admin count via GH #2547's helper, advisory
lock, computed effective policy), `script_readable_master`, `self_published` + derived
pending-review list. 7c: route_kind `:script`, pins, activation refusal, the D3 retire block,
dispatcher lease/CAS, pre-fetch, run records with the secret's `#n`, LuaScriptAudit retirement,
missing-secret fail-closed + alert.
