# 0091 -- Shared stock access: a per-tenant stock-only token for the old Qoimeks app

Status: PROPOSED (T-2087, 2026-11-17; REQ-857, issue #4574; Qoimeks parity G13 part 1). QA only;
production is not approved by this record. Documents only: no code, no migration, no route and no
permission change in this part. The later parts build on the names fixed here: REQ-858 (token life
cycle, admin API), REQ-859 (stock routes under the shared access), REQ-860 (web admin screen, REQ-861
cancelled per owner decision 2026-11-16).

The number 0091 was the next free one on origin/main at T-2087 (0090 is the highest in
`docs/migration/decisions/`; 0090 is decision 0090-negative-balances-per-tenant.md).

Marking: a rule not taken from the owner decision (O), a Qoimeks source (Q) or an existing decision
record (R) is marked **assumption, owner may change** and is listed in the owner table (section 12).

## Sources (checked)

**Owner decision, 2026-11-16, relayed by the PM (T-2034 task text):** "Do whatever needed to support
old Qoimeks functionality, not less but possible more". Parity for the old shared token is required;
the token stays as a scoped per-tenant stock-only credential, revocable by an admin through the API,
with no time limit and no Tokens-page screen (REQ-861 cancelled). (O)

**Qoimeks sources** (read only, outside this repository; copies in
`state/tasks/T-2034/sources/qoimeks-token-extract.md`):

- `Qoimeks/client1-inventory.md` section 8 items 8 and 11 (§8.8: "Old token must keep working
  (`ACCESS_TOKEN_TENANT`, decided 'indefinitely', portfolio-manager 2026-10-27); no setting change on
  phones"; §8.11: operator name as free text, stored with each movement). (Q)
- `Qoimeks/server/internal/api/api.go`: `requireToken` reads the `Authorization` header, compares its
  SHA-256 against `ACCESS_TOKEN_TENANT`; `storeError`/`writeError` write uniform JSON error bodies;
  `GET /catalog` lists SKUs with `id` (integer `sku_id`), `name`, `article`, `unit`, `barcode`;
  `GET /balances` lists balances with `sku_id` (int), `location_id` (int), `quantity` (decimal),
  `sku_name`, `location_name`; `GET /movements` lists movements with `id` (int), `kind`, `sku_id`
  (int), `location_id` (int, nullable), `quantity` (decimal), `operator`, `created_at`; routes for
  codes, feedback, voice and parse also exist. (Q)
- `Qoimeks/server/internal/store/store.go` `NewMovement`: fields `kind` (string), `sku_id` (int64),
  `location_id` (int64), `quantity` (decimal string), `operator` (string, non-empty per 001_init.sql).
  `Movement` struct: `Id` (int64), `Kind`, `SkuId` (int64), `LocationId` (*int64, nullable for
  two-sided transfers), `Quantity` (string), `Operator`, `CreatedAt`. (Q)
- `Qoimeks/server/internal/store/migrations/001_init.sql`: kinds `receipt`, `issue`, `transfer`,
  `adjustment`, `reverse`; `movements` table has `CHECK (operator <> '')`. (Q)
- `Qoimeks/mobile/lib/api.dart`: every call is `baseAddress + path`; the `Authorization` header is the
  shared token value (not `Bearer …`, just the raw value); `X-Operator` carries the operator name. (Q)
- `Qoimeks/docs/self-host.md`: "openssl rand -hex 32" generates the shared token value. (Q)

**Letflow files on origin/main** (checked at T-2087 HEAD by grep):

- `lib/letflow/modules/stock/access.ex`: the guard of the stock document routes accepts only
  `kind: :user` principals; "an API token is a different kind". (R)
- `lib/letflow/api/module_guard.ex`: `check/2` matches `%{kind: :user}` only; an API token (`kind:
  :token`) is refused. (R)
- `lib/letflow/plugs/auth_pipeline.ex`: the `"lf_tok_"` prefix dispatches to the API-token branch;
  `X-Tenant-Slug` carries the tenant; uniform 401 `"invalid or expired bearer token"` on all branch
  failures; a new credential type needing a different resolution (e.g. a tenant segment in a path) is
  "a new branch, not a generalization of this one" (moduledoc). (R)
- `lib/letflow/plugs/auth_attempt_limit.ex`: `mode: :failures` for wrong credentials,
  `mode: :requests` for accepted requests; `defaults/0`: `failure_capacity: 10`,
  `failure_refill_per_sec: 10/60`, `request_capacity: 60`, `request_refill_per_sec: 1`. (R)
- `lib/letflow/identity.ex`: `hash_token_value/1` is SHA-256 hex of the plaintext. (R)
- `lib/letflow/router.ex`: forwards outside `/api/v1` are `/api/tenant-config`,
  `/api/mobile/tenant-config`, `/metrics`, `/api/public`, `/api/login-discovery`, `/api/signup`,
  `/admin/v1`; each is declared as a `forward/2` before the `/api/v1` forward. (R)
- `lib/letflow/modules/stock/router.ex`: `GET /balances` → `Letflow.Ledger.balances/4`;
  `GET /movements` → `Letflow.Ledger.entries/3`; `POST /documents` → `Letflow.Modules.Stock.Documents`;
  `POST /documents/:id/post` → starts the posting instance; `POST /documents/:id/reverse` → starts the
  reversal instance. (R)
- `lib/letflow/modules/stock/actor_label.ex`: `label/2` resolves a user UUID to a person's display
  name; it is INV-1 scoped and returns `nil` for an unknown or non-UUID id. (R)
- `lib/letflow/api/authorization.ex` / `priv/permission_matrix/effective.golden`: `StockRead`,
  `StockPost`, `StockReverse`, `StockReconcile` are declared by module `stock`; STOREKEEPER holds all
  four stock atoms except `StockReconcile` (via `role_grants`). `TokensManage` is held only by
  PLATFORM_ADMIN and TENANT_ADMIN. (R)
- `docs/roles.md`: "The provisioner is a credential, not a role" (the tenant provisioner precedent, R);
  STOREKEEPER holds `StockRead`, `StockPost`, `StockReverse`, `StockCountOrder`, `StockCountRecord`. (R)
- `docs/status/qoimeks-migration-readiness.md` section 1.2 row G13: the gap item this decision closes.
  (R)

## 1. The rule change: stock accepts a named credential in addition to a signed-in user

The current rule: `Letflow.Modules.Stock.Access.check/2` accepts only an interactive OIDC user
(`kind: :user` from `Letflow.Api.Scope.principal_from_conn/1`). Every other principal — including an
API token (`kind: :token`) — receives the same 404 as a tenant without the stock module (INV-5).

The rule change:

1. The stock document and read routes continue to accept interactive users exactly as today. Personal
   accounts keep working unchanged; this decision adds nothing to them and removes nothing from them.
2. A second path, the **shared stock access**, is added alongside the existing routes. It accepts a
   single per-tenant credential (the shared token) **only** at the per-tenant address described in
   section 6. It does **not** relax the guard on any `/api/v1` route.
3. The shared access path is a parallel router, not a modification of the existing guard. The new
   router runs its own authentication, permission check and admission rules (sections 3–8) and then
   calls the same stock context functions the existing routes call; the existing routes are unchanged.

**Why both coexist:** the Qoimeks mobile app has no accounts and cannot be changed to use Keycloak sign-in
without a client-side software release. Personal accounts must keep working for the browser and for phone
users who sign in. The shared access is a migration bridge; personal accounts remain the target long-term
shape (section 11, EXTRA).

## 2. The credential definition: a credential, not a role

The shared access is a **credential** in the sense of `docs/roles.md`: it is not one of the nine roles
(`Authorization.roles/0`) and it adds no role, no permission atom and no entry to the permission matrix.

Exactly:

- It holds exactly the **three permissions** `StockRead`, `StockPost` and `StockReverse`. It never
  holds `StockReconcile`, `StockCountOrder`, `StockCountRecord`, any import permission, `TokensManage`,
  `UsersRead`, `ModulesManage`, `SettingsManage`, `AuditRead` or any other atom. This list is closed:
  no later part of this chain adds an atom here without a new decision record.
- The role list of `Letflow.Api.Authorization.roles/0` does **not** change: the nine roles stay
  unchanged.
- `priv/permission_matrix/effective.golden` does **not** change: the shared access is not a role and
  has no row in the matrix.
- The stock module's `role_grants` (STOREKEEPER's atoms) do **not** change.

**Why three permissions and not more:** the Qoimeks app calls catalog (read), balances (read),
movements list (read), movement post (write receipt/issue/transfer), and movement reverse (reverse). The
count, reconcile and other administrative permissions are not called. `StockReconcile` is intentionally
excluded: a shared credential cannot guarantee who performed the action, so reconcile (which produces an
audited integrity check) requires a personal account. (O: not in the owner text, but consistent with
"a credential, not a role".)

## 3. Activation: the LETFLOW_SHARED_STOCK_ACCESS_TENANTS setting

| Setting | Default | Who sets it | Why here |
|---|---|---|---|
| `LETFLOW_SHARED_STOCK_ACCESS_TENANTS` | unset (none) | Deployment operator, in `config/runtime.exs` alongside existing `LETFLOW_*` settings | Per-owner decision: enabling for a real tenant stays the owner's; QA only until the owner says otherwise (D-050). A deployment setting (not a database row) is the right place because it cannot be changed without a redeploy, keeping the owner's control explicit. **assumption, owner may change** |

Semantics (decided here, used unchanged by REQ-858):

1. The value is a comma-separated list of tenant slugs (e.g. `"qoimeks-qa,other-qa"`). Whitespace
   around commas is trimmed. An unset or empty value means **no tenant** may have a shared access.
2. A tenant whose slug is **not** in the list cannot create a shared access credential, cannot rotate
   it, cannot revoke it and cannot call the shared access routes; it gets the same 401 as an unknown
   slug (section 8).
3. Removing a slug from the list takes effect at the next request (the runtime reads the config once
   per request; no restart is needed). An existing hash row is left in the database but the route
   refuses 401 immediately on the next call, as if no credential existed.
4. This setting is read in the shared access router plug, not in the token life-cycle API (REQ-858):
   the administrator cannot create a shared access for a tenant unless the deployment operator has
   listed it, but a rotation or revocation of an already-created credential is allowed even when the
   slug is not listed (the administrator can always clean up). **assumption, owner may change**

## 4. Storage and life cycle

### 4.1 Storage location

The hash and its metadata are stored in a **new tenant-schema table** named `shared_stock_access`. It
lives in the tenant schema (Ecto `:prefix` scoped, INV-1). The existing `api_tokens` table is not
reused because:

- `api_tokens` requires a `user_id` (a user the token belongs to); the shared access has no user.
- `api_tokens` carries a `roles` list; the shared access holds exactly three fixed permissions (never a
  role).
- The life cycle is different: `api_tokens` expire; this credential has no time limit.
- Keeping the two concepts in separate tables makes the invariant "one per tenant at most" simple to
  enforce with a unique constraint.

### 4.2 Table design (decided here; schema written by REQ-858)

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | Primary key (tenant schema, INV-1) |
| `token_hash` | text NOT NULL | SHA-256 hex of the plaintext value (as `hash_token_value/1`). Unique within the tenant. |
| `actor_id` | UUID NOT NULL | A fixed UUID that serves as the actor in all stock documents written through this access. Generated once at creation; never changed even after rotation (the actor represents the shared access, not the token value). |
| `created_at` | utc_datetime_usec NOT NULL | First creation. |
| `rotated_at` | utc_datetime_usec | Most recent rotation (nil if never rotated). |
| `created_by_user_id` | UUID NOT NULL | The TENANT_ADMIN who created it (audit anchor). |
| `revoked_at` | utc_datetime_usec | Revocation timestamp; nil means active. |
| `revoked_by_user_id` | UUID | The TENANT_ADMIN who revoked it. |

At most one active row per tenant (a unique partial index on the tenant schema, `revoked_at IS NULL`).
The row is never deleted; revocation sets `revoked_at`.

### 4.3 Life cycle

| Action | Who | Effect |
|---|---|---|
| **Create** | TENANT_ADMIN, via REQ-858 API | Generates a random value (or accepts a given value, see below), stores its SHA-256, generates `actor_id`, inserts the row. The plaintext value is returned once, never stored. |
| **Rotate** | TENANT_ADMIN, via REQ-858 API | Generates (or accepts) a new value, updates `token_hash` and `rotated_at`. The old value stops at once. The plaintext is returned once. |
| **Revoke** | TENANT_ADMIN, via REQ-858 API | Sets `revoked_at` and `revoked_by_user_id`. The credential is unusable at the next request. |
| **Given value** | Caller supplies the old Qoimeks token value | Minimum length: 32 hex bytes (the value from `openssl rand -hex 32`, which is 64 hex characters; smaller values are refused with a validation error). **assumption, owner may change** |

**INV-4 compliance:** the plaintext value is returned only at creation or rotation and is never
stored, logged, included in an audit entry, included in an error body or included in a later response.
The audit entries for `token.create` and `token.revoke` carry the `actor_id` and the creating user id,
not the token value or its hash (a hash of a secret is a secret for 32-byte inputs where the input
space is small, but for a 32-byte random input it is a one-way function; regardless, the hash is not
logged to follow `hash_token_value/1`'s own precedent for API tokens). **assumption, owner may change
(the audit entry fields)**

**Why the actor_id does not change on rotation:** rotation is a credential hygiene operation that changes
the proof (the token value) but not the identity of the accessor. Stock documents written before and
after a rotation are attributed to the same actor_id; the rotation timestamp in the table separates them.
If the owner wants "rotation starts a fresh identity" behaviour, that is a later change.

**Who the actor is:** the `actor_id` UUID is not in the `users` table of the tenant schema (INV-1
ensures the users table is tenant-scoped, but this actor is not a user). It cannot sign in because it
has no Keycloak account. It cannot hold a role binding because `Letflow.Identity.create_binding/4`
requires a user UUID that exists in the users table. The actor_id is an opaque identifier that the
stock ledger records; `Letflow.Modules.Stock.ActorLabel.label/2` returns `nil` for it (the UUID is not
in the users table), so stock reads show the operator name from the document body instead (section 5).

## 5. The operator name

**Definition:** the operator name is a free-text string the caller supplies on every write (movement
post and reverse). It represents the person who physically performed the action. The old Qoimeks app
sends it in the `X-Operator` header on every write call.

**Rules (decided here, unchanged by later parts unless a new decision amends):**

| Rule | Value | Mark |
|---|---|---|
| Presence | Required on every write through the shared access; a missing or blank name is refused before the stock context is called. | O (Qoimeks has `CHECK (operator <> '')`) |
| Trimming | Leading and trailing whitespace is trimmed before the check and before storage. | Q (`001_init.sql`) |
| Maximum length | 200 characters after trimming. | **assumption, owner may change** |
| Storage | Stored as a field on the stock document (a new document field or a document header key; the name in the schema is decided by REQ-859 together with the new document kind or as a new header key on existing kinds). | — |
| Display | Shown in the stock read responses (`entered_by_label` / `posted_by_label` / `reversed_by_label`) in place of the user label that `ActorLabel.label/2` returns for a personal account. The actor_id is included in the response as today; the operator name is additive (REQ-859). | — |
| Scope | Stored and shown only for documents posted through the shared access; personal-account documents are unaffected. | — |

## 6. The access path

The shared access is accepted **only** at paths under the prefix:

```
/qoimeks/:tenant_slug
```

declared as:

```elixir
forward "/qoimeks/:tenant_slug", to: Letflow.Routers.SharedStockAccess
```

in `lib/letflow/router.ex`, before the `/api/v1` forward (the same pattern as `/admin/v1`). The
concrete routes under this prefix mirror the old Qoimeks API paths:

| Path | Method | Purpose |
|---|---|---|
| `/qoimeks/:slug/catalog` | GET | List items (SKUs) |
| `/qoimeks/:slug/balances` | GET | Stock balances |
| `/qoimeks/:slug/movements` | GET | Movement history |
| `/qoimeks/:slug/movements` | POST | Post a movement |
| `/qoimeks/:slug/movements/:id/reverse` | POST | Reverse a movement |

The old Qoimeks mobile app changes only its `baseAddress` from the Qoimeks server URL to
`https://<letflow-host>/qoimeks/<tenant-slug>`; the relative paths (`/catalog`, `/balances`,
`/movements`) remain the same (`mobile/lib/api.dart`).

**Why this path:**

- It is outside `/api/v1` and outside `/admin/v1`: the shared access does not enter the existing
  `Letflow.Plugs.ApiPipeline` and cannot accidentally reach any `/api/v1` route.
- The tenant slug is in the **path**, not in a header or body: the router extracts it from `:tenant_slug`
  as Plug path params, so the credential alone does not need to carry a tenant hint (the existing API
  token branch uses `X-Tenant-Slug` header, but a URL-based route is simpler for a fixed mobile app
  whose base address is the only configurable parameter).
- The old Qoimeks mobile app builds every call as `baseAddress + path` (`mobile/lib/api.dart`). By
  choosing the same relative paths under this prefix, only the base address changes on the phones.

**What is not accepted on /api/v1 routes:** the shared access value presented on any `/api/v1` route
is treated as an unknown bearer token and receives 401. No code change is needed to enforce this: the
API pipeline's token branch (`"lf_tok_"` prefix) would look up the hash in `api_tokens`, not in
`shared_stock_access`, and find nothing; the OIDC branch would also fail. The shared access is never
registered as an API token.

## 7. The contract table

Qoimeks paths (from `server/internal/api/api.go`), Letflow paths (from `lib/letflow/modules/stock/router.ex`
and `lib/letflow/modules/stock/stock.ex`), and Letflow functions (confirmed by grep on origin/main
at T-2087):

| Qoimeks call | Qoimeks request fields | Qoimeks response fields | Shared access path | Letflow function | Integer ID mapping |
|---|---|---|---|---|---|
| List items (catalog) | (none; query params for search) | `id` (sku_id int), `name`, `article`, `unit`, `barcode` | `GET /qoimeks/:slug/catalog` | `Letflow.Entities.Query.Compiler.compile/2` on `catalog_item` type, via `POST /entities/query` semantics in the router | A per-tenant `catalog_item_int_ids` table (see below) assigns a stable integer to each `catalog_item.id` UUID. The catalog response includes both the UUID and the integer. |
| Balances | `sku_id` (int, optional filter), `location_id` (int, optional filter) | `sku_id` (int), `location_id` (int), `quantity`, `sku_name`, `location_name` | `GET /qoimeks/:slug/balances` | `Letflow.Ledger.balances/4` (via `Ledger.authorize/3`) | The integer sku_id and location_id in query params are translated to UUIDs via the mapping tables before the ledger call; the response translates back to integers. |
| Movements list | `sku_id` (int, optional), `location_id` (int, optional), cursor/page | `id` (int), `kind`, `sku_id` (int), `location_id` (int, nullable), `quantity`, `operator`, `created_at` | `GET /qoimeks/:slug/movements` | `Letflow.Ledger.entries/3` (via `Ledger.authorize/3`) | As balances. Movement `id` is mapped to a stable per-tenant integer via a `ledger_entry_int_ids` table. |
| Post movement | `kind` (string), `sku_id` (int), `location_id` (int), `quantity`, `operator` | `id` (int), `kind`, `sku_id`, `location_id`, `quantity`, `operator`, `created_at` | `POST /qoimeks/:slug/movements` | `Letflow.Modules.Stock.Documents` create + issue + post (the three steps collapsed into one synchronous call by the shared access router) | sku_id and location_id are translated to UUIDs before the document is created. The posted movement's ledger entry id is mapped to a new integer and returned. |
| Reverse movement | `id` (int, in path) | Same shape as the original | `POST /qoimeks/:slug/movements/:id/reverse` | `Letflow.Modules.Stock.Documents` reverse | The integer id is translated to the ledger entry UUID; the reversal entry gets its own integer. |

**Old-app calls not served by this chain:**

| Qoimeks call | Readiness row |
|---|---|
| `GET /codes` and barcode scanning | G12 (T-2033) |
| `POST /feedback` | G19 (T-2038) |
| `POST /voice` and `POST /parse` | G15 (T-2035) |

**Integer ID mapping rationale:** Qoimeks uses PostgreSQL integer auto-increment IDs for SKUs,
locations and movements. Letflow uses UUIDs. To keep the mobile app unchanged, the shared access router
maintains per-tenant mapping tables (`catalog_item_int_ids`, `location_node_int_ids`,
`ledger_entry_int_ids`) in the tenant schema. Each table maps a Letflow UUID to a stable per-tenant
integer (assigned once, never changed even if the item is renamed or relocated). The integer sequence is
per-tenant, starting at 1. This is storage added by REQ-859 (the code part); this record decides the
approach (a mapping table, not an autoincrement column on the existing tables, to avoid schema migration
coupling).

**assumption, owner may change:** the mapping table approach and sequence starting at 1.

## 8. Refusals and limits

### 8.1 Pre-credential refusals (uniform 401)

Every check before the credential is proven — regardless of the reason — returns exactly:

```
HTTP 401
{"error": "unauthorized", "message": "invalid or expired bearer token"}
```

This is the same body the existing API pipeline sends for all its own 401 cases (INV-5: a caller who
does not know whether the resource exists must not learn from the error body). The conditions that return
this body:

| Condition | 401 body |
|---|---|
| Unknown tenant slug (not in the `tenants` table) | Yes |
| Tenant slug not in `LETFLOW_SHARED_STOCK_ACCESS_TENANTS` | Yes |
| Tenant has no `shared_stock_access` row (credential not yet created) | Yes |
| Token value does not match the stored hash | Yes |
| Tenant is not active | Yes |
| Stock module not enabled for the tenant | Yes |
| `revoked_at` is not nil | Yes |

The wrong-value case is counted by `Letflow.Plugs.AuthAttemptLimit` in `mode: :failures`, using the
IP-based bucket (`ip_bucket_id`). The rate limit uses `AuthAttemptLimit.defaults/0`:
`failure_capacity: 10`, `failure_refill_per_sec: 10/60` (**assumption, owner may change**: the shared
access is not a login, so a tighter limit may be warranted; the same defaults as the existing API token
branch are used here for now).

The error body for the tenant-not-listed case (`LETFLOW_SHARED_STOCK_ACCESS_TENANTS` check) uses the
same 401 body, not a 404: a caller learning that the slug is valid but the access is disabled would
gain information about the deployment configuration. (INV-5 extended to configuration.)

### 8.2 Per-credential request limits

Accepted requests (credential verified) are counted per credential by `AuthAttemptLimit` in
`mode: :requests`. The bucket key is the `token_hash` (or the `id` of the `shared_stock_access` row),
not the IP, because all requests from the mobile fleet share one token value and one IP is not
meaningful. Rate limit: `request_capacity: 60`, `request_refill_per_sec: 1` (**assumption, owner may
change**: same defaults as the existing API token branch; a warehouse with many simultaneous operators
may need a higher capacity).

## 9. Interplay with other ledger rules

| Rule | Interaction |
|---|---|
| **Posting scope (REQ-831, decision 0051 L6)** | The shared access is refused while the tenant's scope enforcement (`ScopeEnforcement`) is `on` or `shadow` (REQ-859 implements this refusal as a pre-flight check in the shared access router). The reason: a scope-enforced tenant routes stock documents to specific org units; the shared access has no role binding and therefore no scope grant, so it cannot satisfy the enforcement check. The refusal is 503 `scope_enforcement_active` or a chosen 409 reason (decided by REQ-859). **assumption, owner may change** |
| **Master checks (REQ-832, L7)** | Applied unchanged. A movement whose item or location does not pass the master check is refused as it would be for a personal account. No exemption. |
| **Four eyes (approval_rules.ex, decision: docs/design/four-eyes-switch.md)** | A document that requires a second approval is **not** approvable by the shared access. The shared access can create a document and issue it, but the approval step requires a personal account. The reason: four-eyes exists to prevent a single person from completing a critical action; a shared secret does not represent a person and cannot be one of the two eyes. **assumption, owner may change** |
| **Negative balances (decision 0090, REQ-833+)** | The shared access follows the tenant's negative-balance setting, same as a personal account. No special handling. |
| **One-line count (T-2028)** | The count route is not in the shared access scope (no `StockCountOrder` or `StockCountRecord`). The shared access cannot initiate or record a count. |
| **Retry by client id (T-2029)** | The idempotency key on a movement post through the shared access is the same client-id mechanism; the caller supplies a client id and the same id + same body returns the same result. The shared access does not change the idempotency design. |
| **Retry by client id: implemented (T-2282)** | The two old-address writes (`POST /qoimeks/:slug/movements`, `POST /qoimeks/:slug/movements/:id/reverse`) take the client operation id of the old Qoimeks protocol: the body field `id`, a UUID string the phone makes once per operation and resends unchanged (also from its offline queue). The rules: (1) it is REQUIRED: missing or not a UUID is 400 `{"error": "id is required"}` and nothing is written (no fresh-key fallback; the phone always sends one). (2) The id is unique per tenant: it is the primary key of the tenant's `stock_create_idempotency` row (key `client:stock_old_movement:<id>`, the table of `ActionIdempotency`, no new table), bound to the document only after the whole post succeeded, under a per-key advisory lock held for the whole call. (3) A repeat with the same id and equal data changes nothing and answers the STORED movement with 200 (the first post answers 201); stock is not doubled. (4) The same id with different data (compared: kind, sku, place, destination place, quantity as a number; NOT operator, source or transcript) is 409 `{"error": "this operation was already posted with different data"}` (`idempotency_key_reuse`); an id that belongs to a reversal used for a post, or a post id used for a reverse, is 409 too. (5) A reversal takes its OWN new id and repeats the same way (200 with the stored reversal); the original reversed again under another id is refused as before (409 `document_reversed`), a reversal cannot be reversed (409 `reversal_cannot_be_reversed`). (6) Concurrent duplicates: one wins (201), the others wait on the lock and get the stored movement (200); one document, one set of balances. A refused request binds nothing. Not changed here: the kind `adjustment` (a count) is still `invalid kind` (400) at this address, as `OldAppWrites` documents. |
| **Ledger append-only triggers** | Unchanged. `ledger_entry_guard_update` refuses UPDATE/DELETE/TRUNCATE; the shared access writes new entries and never modifies stored ones. |
| **Opening balances** | `StockPost` does not include the right to post the special `opening` kind (that is guarded by a separate in-handler check, `REQ-725`). The shared access cannot post opening balances. **assumption, owner may change** |

## 10. Security review

**INV-1 — Tenant data isolation**

Every access path of the shared stock access is scoped to the tenant identified by the slug in the URL.
The slug is resolved to a tenant schema prefix by the router; all Ecto queries carry that prefix. The
`shared_stock_access` table itself lives in the tenant schema (not `public`). No cross-tenant data
access is possible: the token hash stored for tenant A cannot be used to access tenant B's data because
the slug is taken from the URL path, not from the credential. A request with slug `a` and a token that
belongs to tenant `b` resolves tenant `a`, looks up tenant `a`'s `shared_stock_access` row and fails
(the hashes do not match), producing the same 401 as an unknown token (INV-5). The slug must be in
`LETFLOW_SHARED_STOCK_ACCESS_TENANTS` before any `shared_stock_access` row can be created for it,
preventing a misconfigured installation from accidentally enabling shared access on an unintended tenant.

**INV-4 — Secrets by reference only**

The plaintext token value is generated in memory, returned once to the administrator, and never stored,
logged, included in an audit entry or in a later response. The stored value is the SHA-256 hex digest,
computed by `hash_token_value/1` (the same function used for API tokens). The audit entries carry the
`actor_id` and the user id of the administrator, not the value or its hash. The `X-Operator` header
value (the operator name) is a display string, not a secret; it is stored and shown in reads.

**INV-5 — Not-found/forbidden indistinguishability**

All pre-credential failures (section 8.1) return the same 401 body, regardless of the actual reason.
A caller cannot distinguish "unknown slug", "slug not listed", "no credential", "wrong value" or
"inactive tenant" from each other. This follows the existing API pipeline's own practice ("byte-identical
401s", `auth_pipeline.ex` moduledoc) and extends it to the new path.

**INV-6 — New data-access path proves its scoping**

The shared access router is a new data-access path. Its scoping proof: the tenant schema prefix is
derived from the URL slug through a lookup in the global `tenants` table (not taken from the credential).
Every subsequent stock context call passes this prefix. REQ-858 and REQ-859 add the cross-tenant
negative test (`slug A with token B receives 401`) as a required test.

**INV-8 — No unhandled crashes on realistic failure paths**

The shared access router fails closed on every realistic failure:
- Unknown slug → 401 (a lookup miss, handled by the router's own match)
- Slug not in settings → 401 (a string membership check, cannot raise)
- No `shared_stock_access` row → 401 (an Ecto query returning nil, handled)
- DB unavailable → the existing sandbox and pool error handling; the router is wrapped in a standard
  Plug pipeline that returns 503 on a timeout or pool exhaustion
- `AuthAttemptLimit` rate limit → 429 (`send_rate_limited/2` in the existing module)
- Stock context failure → the same 409/422/503 error codes the existing stock routes return

**INV-9 — Tenant-controlled outbound URL validation**

The shared access does not introduce outbound URLs. The only network calls it makes are to the
database (existing, INV-1 scoped) and to the stock context functions (pure Elixir, no outbound HTTP).

**INV-10 — Platform authority is bound to the platform tenant**

The shared access is scoped to a named tenant (the slug in the path). It cannot act on another
tenant's data (INV-1 proof above). The route does not carry a `tenant_id` parameter that the caller
supplies; the tenant is derived from the URL slug. A request for the platform tenant's slug using the
platform tenant's credential cannot call any `/api/v1` route and cannot call any admin operation;
it can only call the stock reads and writes the shared access is scoped to, within the platform tenant's
own schema.

**Residual risks of a shared secret:**

1. **Non-repudiation:** because all operators share one token, the only attribution is the operator name
   they type. A malicious operator could type a false name. This is a known Qoimeks design choice (Q);
   the owner accepts it for the migration period.
2. **Token leak:** a leaked token allows anyone to post movements until the administrator rotates or
   revokes it. The rate limit (section 8.2) reduces but does not eliminate the exposure window. The
   operator is advised to rotate immediately on suspected leak.
3. **Rotation gap:** during the brief window between rotation (new hash stored) and the phones' first
   successful call with the new value, the phones continue to send the old value and receive 401. The
   phones must be reconfigured with the new base address before or after rotation. This is a planned
   operational step.

Enabling the shared access for a real tenant is the owner decision; this record covers QA only.

## 11. EXTRA ideas (not built by this chain)

**EXTRA:** A Letflow web or PWA app signing in with the shared access value as an alternative
authentication method, so warehouse workers without accounts can use the web UI. Not built here; the
shared access is designed as an API bridge, not an interactive session mechanism.

**EXTRA:** Time limit on the shared access (the token automatically expires after N days). The owner
decided no time limit ("the move needs it to keep working, the admin revokes it", decision 2026-11-16).
Adding a time limit would be a new decision record amending section 4.3.

**EXTRA:** Multiple shared access credentials per tenant (one per site or per shift). Not built here;
the design chose one per tenant to match the Qoimeks model. A multi-credential design would need a
new decision record.

**EXTRA:** A webhook or notification when the credential is rotated or revoked. Not built here.

## 11a. Amendment (REQ-859, as built)

Where the build of the old-app address differs from sections 7, 8.1 and 9 above, the build rules:

- Movement ids map through the tenant table `movement_int_ids` (not `ledger_entry_int_ids`); the other
  two tables are `catalog_item_int_ids` and `location_node_int_ids` (migration `20261118100001`).
- Every pre-credential refusal is the 401 that `Letflow.Api.Response.unauthorized/2` sends for the
  detail `invalid or expired bearer token` (the same problem body as the API pipeline), not the
  hand-written `{"error": "unauthorized", ...}` shape shown in section 8.1. Its bytes and headers are
  identical for every refusal reason (test "C2 every refusal is byte-identical").
- Scope enforcement `on` or `shadow` answers 403 `{"error": "scope_enforcement_active"}` (section 9
  said 503 or 409).
- The read authorization has no `conn` principal: `Letflow.Ledger.authorize_shared_access/3` mints a
  tenant-wide, read-only `Authorized` value from the proved tenant row. Its only caller outside the
  ledger files is `Letflow.Routers.SharedStockAccess`; a source scan test in
  `test/letflow/ledger/authorize_test.exs` pins that.
- Known QA limits, to close before production: a timing difference between a listed and an unlisted
  slug, and unbounded page widening and per-row lookups in `Letflow.Modules.Stock.OldAppReads`
  (bounded today only by the per-credential request limit).

## 11b. Amendment (REQ-860, as built)

The two write calls (`POST /movements`, `POST /movements/:id/reverse`) widen a settled ledger rule, so the
build choices are recorded here (decision 0073 note 16.2 said the credential must be exactly `:oidc`):

- **A second credential kind, `:shared_access`.** `Letflow.Ledger.Authority` accepts it for one purpose:
  the rule is not in the ledger but in the function configured as `:shared_access_authority`
  (`{module, function}`, `config/config.exs`), which is `Letflow.SharedStockAccess.may_post?/4`: module
  `stock`, permission `StockPost` or `StockReverse`, and a subject that is the actor of a credential row
  of the tenant that is not revoked, read at the moment of the posting. No role is read. With no
  configuration the kind is refused (fail closed). The HTTP auth context holds only `:oidc` or `:api_token`
  (`AuthPipeline`), so no request value can be `:shared_access`; the one place that sets it is
  `Letflow.Modules.Stock.OldAppWrites` (pinned by T-SEC-3a and T-SEC-3g in
  `test/letflow/ledger/credential_callers_test.exs`).
- **Scope is not re-read at posting time.** The shared-access clause skips the scope check because the
  router refuses a tenant whose scope enforcement is not `off` (403 `scope_enforcement_active`, section
  9) at request time. A switch-on between the request and the posting is not caught; accepted for QA.
- **The operator name is a task output variable.** It is stored as the output variable `operator` of the
  completed `post` / `reverse` task and shown only when the completer is a shared-access actor of the
  tenant, so a personal account cannot fake an operator label.
- **The actor is the credential's synthetic actor id** (a random uuid created with the credential), the
  actor of every step of the document.
- **A refused receipt stays issued.** A receipt cannot be cancelled while its post task is pending; a
  receipt has no realistic ledger refusal. A refused issue, transfer or reversal is discarded, cancelled
  or withdrawn.

## 11c. Amendment (REQ-907, as built)

The real old Qoimeks app (web build 0.1.2, the production APK version) was run against the address and
stopped on its first call. `Letflow.Routers.SharedStockAccess` therefore serves the five calls at two path
forms, and four statements of the "Sources" text above (and of sections 6 and 7) are corrected. The build
and the real app rule over the earlier text:

- **The `/api` path segment.** The app adds `/api` in front of every path (`Qoimeks mobile/lib/api.dart`).
  `GET /qoimeks/<slug>/api/catalog`, `GET .../api/balances`, `GET .../api/movements`,
  `POST .../api/movements` and `POST .../api/movements/:id/reverse` give exactly the answer of the same
  call without `/api`; the paths without `/api` keep answering (the UAT groups `qoimeks-token` and
  `qoimeks-retry` use them). Both forms run the same handler after the same plugs: failure counting,
  authentication, the per-credential request token and the scope enforcement refusal run once per
  request, in the order of the router's moduledoc, so an `/api` path spends the same token as the plain
  one. Every other path under the prefix, with or without `/api` (`/api/voice`, `/api/parse`,
  `/api/feedback`, `/api/codes`, `/api/codes/lookup`), stays 404 `{"error": "not found"}` after
  authentication; those calls are sized in `docs/status/qoimeks-old-client-compat.md` section 5.
- **Correction 1, the paths carry `/api`.** Sources and sections 6 and 7 write them without it.
- **Correction 2, the header is `Authorization: Bearer <code>`.** The text says "the raw value, not
  Bearer"; the app sends `Bearer <code>` (`api.dart` `ApiClient`), and the build accepts exactly that.
- **Correction 3, the catalog is an object.** The old server answers `{"skus": [...], "locations": [...]}`
  with a `code` per item (`store.go` `Catalog`), not a flat list of `id, name, article, unit, barcode`.
  The shape itself is built by REQ-908; this task changes no answer shape.
  REQ-908 as built: a sku row has `id, code, name, unit` (`""` when the item has no base unit),
  `location_id` (the integer of the item's default place, absent when none or not active) and `barcode`
  (absent when none); a location row has `id, code, name`; a balance row has `sku_id, location_id,
  location_code, qty`, sorted by place code. The second place (`alt_location_id`) is not served (D-150).
- **Correction 4, a movement id is text and the quantity field is `qty`.** The id is a UUID on the old
  server and the app reads it as text, not an integer; the quantity of a movement is named `qty`. REQ-909
  builds this; this task changes no answer shape.

Out of scope here: the calls not served (count, codes, voice, feedback, parse), the pairing call, and any
change to the credential or its rules.

## 12. Owner table

Every assumption marked "assumption, owner may change" in the sections above:

| # | Section | Assumption | Stated value | Alternatives the owner may choose |
|---|---|---|---|---|
| A1 | 3 | LETFLOW_SHARED_STOCK_ACCESS_TENANTS is a deployment setting, not a database toggle | Deployment config | A per-tenant database flag toggled through the admin API |
| A2 | 3 | Removing a slug stops the credential at the next request (no grace period) | Immediate | A configurable grace period |
| A3 | 3 | Revocation from the admin API is allowed even when the slug is not listed | Allowed | Only when listed |
| A4 | 4.3 | Minimum token length 32 hex bytes (64 characters) | 64 characters | Shorter (not recommended) or longer |
| A5 | 4.3 | The audit entry fields for the shared access are actor_id and creating user id (not the hash or value) | As API token precedent | Include the hash as a lookup key (safe for 32-byte random values, not recommended by INV-4 practice) |
| A6 | 4.3 | The actor_id does not change on rotation | Same actor before and after rotation | New actor_id on each rotation |
| A7 | 5 | Maximum operator name length 200 characters | 200 | Any other limit |
| A8 | 7 | Per-tenant mapping tables for integer ↔ UUID translation, sequences starting at 1 | Mapping tables | Autoincrement columns on existing tables, or a hash function |
| A9 | 8.1 | Wrong-value rate limit uses `failure_capacity: 10`, `failure_refill_per_sec: 10/60` | Same as API token branch defaults | A tighter limit for a shared credential |
| A10 | 8.2 | Per-credential request rate limit uses `request_capacity: 60`, `request_refill_per_sec: 1` | Same as API token branch defaults | Higher for a fleet of warehouse operators |
| A11 | 9 | Scope enforcement `on` or `shadow` refuses the shared access | Refused (503 or 409) | Allowed for a named org unit the shared access is pinned to |
| A12 | 9 | Four-eyes documents are not approvable by the shared access | Refused | Allowed when the operator names are distinct (not verifiable with a shared token) |
| A13 | 9 | Opening balance kind is not allowed through the shared access | Refused | Allowed |

Enabling the shared access for a real tenant is the owner decision; this record covers QA only.
