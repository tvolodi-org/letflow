# 0006 — Identity tables move behind `:prefix`; `tenant_id` retired from schema-isolated tables

Status: decided and fully shipped. D1 shipped (REQ-063, REVIEWER +
SECURITY-REVIEWER sign-off, RELEASE-VALIDATOR PASS). D2 shipped (REQ-064,
REVIEWER + SECURITY-REVIEWER sign-off, RELEASE-VALIDATOR PASS — 777/777 tests
green). D3 and D4 stand as documented in this record: D3 (tenant_id retained
on the four structurally-global public-schema tables) was never itself a
change to execute — it is what D2 deliberately leaves untouched. D4 (the
cross-tenant reporting mechanism) remains an open forward commitment with no
owning requirement yet, per §7. Owner: ORCH → REVIEWER + SECURITY-REVIEWER.

Supersedes: `0003-ecto-schema-strategy.md` Dimension B, in part (see §6 for the
exact clause superseded and the exact clauses left standing).
Resolves: `lib/letflow/design/req022-tenant-schema-provisioning.md` §7's open question
(users/groups/tenant_role retrofit), open since REQ-022.

## Question

Two questions this record answers together, because the second is a consequence
of the first:

1. Do REQ-015's `users`, `groups`, and `tenant_role` tables — today in the public
   default schema — move behind each tenant's own Postgres schema via Ecto's
   `:prefix`, as every business table already does under Decision B?
2. Once they have, does the `tenant_id` column survive on tables whose isolation
   boundary *is* the Postgres schema?

## Decision

**D1 — `users`, `groups`, and `tenant_role` move into per-tenant schemas**, via
the same `:prefix` mechanism and the same `tenant_scoped_migrations/0` registry
every other tenant-scoped table already uses (REQ-022 §3.4/§4). They stop being
public-schema tables.

**D2 — `tenant_id` is dropped from every table whose isolation boundary is the
Postgres schema.** Concretely, from the eight already-schema-isolated business
tables (`events`, `events_archive`, `instance_projections`,
`process_definitions`, `tokens`, `tasks`, `promotion_reviews`,
`promotion_assertion_runs`) and, as a consequence of D1, from `users` and
`groups`.

**D3 — `tenant_id` is retained, unchanged, wherever it is a real foreign key on a
structurally-global public-schema table**: `tenant_schemas`,
`solution_pack_installs`, `solution_pack_artefact_bases`,
`pack_update_resolutions`. On these tables `tenant_id` is not a redundant copy of
the schema boundary — it is the only scoping the row has, and it carries a
`references(:tenants, type: :binary_id)` FK. D2 does not touch them.

**D4 — the cross-tenant reporting use case that Decision B cited as `tenant_id`'s
justification is re-homed, not dropped.** It is served by querying
`tenant_schemas` for the registered schema list and unioning across schemas (or a
Postgres FDW/`dblink` view built on that list), not by a column on every row of
every tenant table. No such reporting consumer exists in the codebase today —
this is a forward commitment about where the capability lives, not a migration of
existing code.

## Reasoning

### R1 — Decision B's stated justification for `tenant_id` does not survive its own addendum

0003 Dimension B retained `tenant_id` on two grounds, quoted from its own text
(lines 178–181): it is *"useful for cross-tenant admin/reporting queries against a
superuser connection"*, and *"removing an established column from every business
table purely because a second isolation layer was added is not a change R-Co's
migration history shows it as ever having made."*

The second ground is precedent-following, not a technical argument — and 0003
itself concedes (lines 197–199) that *"nothing in this decision's research
surfaced a stated reason for that move (no adp-0x doc or migration header explains
why R-Co added schema-per-tenant on top of the column)."* Letflow inherited a
two-layer design whose second layer R-Co never documented a reason for. Following
an undocumented precedent is a weak basis for a column on every row of every
tenant table, and 0003 was appropriately explicit that this is what it was doing.

The first ground survives as a real need, and D4 keeps it — but it is served by
`tenant_schemas` (which D3 keeps) plus a schema-list union, not by per-row
denormalization. A reporting need that arises at most on an operator's superuser
connection does not justify a column on every business row in the system.

### R2 — the column cannot detect the error it is informally credited with catching

`tenant_id` is sometimes described as a safety check on `:prefix` selection: if
the wrong schema were targeted, the column would disagree and the bug would be
visible. **This is not true of Letflow's actual implementation**, and 0003's own
Addendum (2026-08-17) is what makes it untrue.

That addendum decided the written value is *derived from the `:prefix` being
written into*, via `TenantProvisioning.tenant_id_for_schema_name/1` — its stated
reasoning being that *"a derived value cannot disagree with the schema it is
written into, by construction."* That property is exactly what makes it useless as
a check: a value that is mechanically incapable of disagreeing with the schema
cannot detect a wrong-schema write. If `prefix:` resolves to the wrong tenant, the
row lands in the wrong schema *and* is stamped with the wrong schema's derived
`tenant_id`, consistently. Both layers are wrong together, silently.

So the column is not a verification mechanism, and this record does not remove one.
The addendum's attribution-integrity concern — that a caller-supplied `tenant_id`
could disagree with its schema — is fully resolved by D2, in the strongest
possible way: a column that does not exist cannot carry a wrong value.

### R3 — the shipped migrations already document the column as degenerate

This is not a novel claim by this record; two shipped migration headers state it
directly. `20260816120005_create_events_archive.exs:43-44` and
`20260816193001_create_process_definitions.exs:56-57` both record that *"the
Postgres schema IS the tenant boundary, so tenant_id has at most one distinct
value per schema and a leading-tenant_id index degenerates to its non-tenant
counterpart."* The column's own migrations describe it as carrying no information
within its schema.

There is also in-repo precedent for omitting it: `instance_definition_snapshots`
(`20260816193002`) is a schema-isolated business table that deliberately ships
with **no `tenant_id` at all** and has caused no downstream problem.

### R4 — the identity tables' current public-schema placement is a deferral, not a design

`identity-schema.md` §1 and REQ-022 §7 both record the public-schema placement of
`users`/`groups`/`tenant_role` as explicitly deferred work, not a decided end
state. `20260816000003_create_tenant_role.exs`'s own header goes further and
anticipates this exact change:

> *"name's uniqueness is enforced as a plain global unique index for now, standing
> in for 'unique per tenant schema' under the single-default-schema deferral. Once
> per-tenant schema provisioning lands, each tenant schema carries its own physical
> copy of this table and this same index, which then means unique-per-tenant-schema
> automatically — no index rework needed at that point."*

`tenant_role` therefore needs no constraint redesign under D1; it was written for
this move. `groups` likewise (its only index is `index(:groups, [:tenant_id])`,
which D2 simply drops). **`users` is the exception, and §3 is entirely about it.**

### R5 — the realm→tenant→schema resolution chain is a verified 1:1 bijection

D1 is only sound if a tenant's schema can be resolved *before* any `users` query,
since per-tenant `users` is unreachable until the tenant is known. Verified
directly against the shipped code this session, at three enforcement levels:

1. **One realm cannot bind to two tenants** — `unique_index(:tenants,
   [:idp_realm_id]) WHERE idp_realm_id IS NOT NULL`
   (`20260816000001_create_tenants.exs:38-41`).
2. **One tenant cannot hold two realms** — `idp_realm_id` is a single scalar
   column on `tenants`, not a collection (`lib/letflow/identity/tenant.ex`).
3. **A binding cannot be reassigned** — `Tenant.update_changeset/2` structurally
   omits `:idp_realm_id` from its `cast/3` field list, so no code path in the
   module can change it after creation.

Additionally `Tenant.create_changeset/3` requires `idp_realm_id` for every
non-default tenant when `oidc_mode == :enabled`, and pins the default tenant's
realm to the literal `"bpm-default"`.

So realm↔tenant is a strict partial bijection (nullable only when OIDC is off),
and `AuthPipeline`'s existing step order — verify token → extract realm from `iss`
→ `resolve_tenant_by_realm/1` → *then* touch `users` — already resolves the tenant
from `tenants` (a public-schema table D3 keeps) before any user lookup. The
resolution chain `realm → tenant.id → schema_name_for_tenant/1 → prefix` is
therefore available at exactly the point D1 needs it, with no reordering of the
pipeline. This was the primary risk to D1 and it is closed.

Narrowed by `0048-pending-tenant-admin-grant.md` section 2: `idp_realm_id` may be set once, from NULL, through the audited bind-once route; it is never changed or cleared.

## 3. The `users` constraint semantics change — the load-bearing section

D1 changes the meaning of two shipped unique indexes on `users`, because a unique
index inside a per-tenant schema is per-tenant by construction. **Both changes are
deliberate and are the security-sensitive core of this record.** SECURITY-REVIEWER
must sign off on this section specifically, against INV-1..INV-8.

### 3.1 `unique_index(:users, [:username])` — global → per-tenant

Today two tenants cannot both have a user named `admin`. After D1 they can.

**Adopted deliberately.** Globally-unique usernames across tenants is a
multi-tenancy defect, not a feature: it lets one tenant's registration
enumerate/deny another tenant's namespace, and it leaks the existence of accounts
across the isolation boundary. Per-tenant uniqueness is the correct semantics for a
multi-tenant BPM platform, and it is what R-Co's own post-`GBL-112` arrangement
produces for its per-tenant tables.

The index definition itself needs no change — it becomes per-tenant automatically
once the table is per-schema, exactly as `tenant_role`'s header (R4) predicts for
its own `name` index.

### 3.2 `users_external_identity_partial_index` — global → per-tenant

Today `unique_index(:users, [:external_realm, :external_id]) WHERE external_id IS
NOT NULL` globally guarantees one OIDC identity maps to exactly one user row
system-wide. After D1 the same `(realm, external_id)` pair could exist in two
tenant schemas at once.

**This one requires an explicit argument, and the argument is that R5 makes the
collision unreachable.** `external_realm` is the realm the token was issued by.
By R5, a realm binds to exactly one tenant, and that binding is immutable. So two
rows with the same `external_realm` in two different tenant schemas would require
that realm to be bound to two tenants simultaneously — which
`tenants_idp_realm_id_partial_index` forbids at the database level, on a table D3
keeps in the public schema. The global guarantee is not lost; it is relocated from
`users` to `tenants`, where it is enforced once rather than per-user-row.

`verify_realm_ownership/2` (called in `AuthPipeline` step 3, *before* provisioning)
remains as the application-level guard it already is. It is not newly load-bearing
under this record — it guards the same boundary it guarded before, and the DB
backstop for that boundary moves rather than disappears.

**Divergence note, recorded rather than glossed:** 0003 line 132 and
`identity.ex:41` both document the JIT upsert key as `(tenant_id, external_realm,
external_id)`, but the *shipped* index is `(external_realm, external_id)` without
`tenant_id` — i.e. the database is currently **stricter** than the documented
contract. D1 relaxes the index to match what was documented all along, since
`tenant_id`'s role in that key is taken over by the schema boundary. This is a
pre-existing doc/schema divergence being closed, not a new relaxation invented
here. REQ-B's design step must state this in the migration header so it is not
later mistaken for an accidental weakening.

### 3.3 What D1 forecloses

Per-tenant `users` permanently rules out any cross-tenant user lookup that does
not start from a realm — e.g. a future "find my account by email across all
tenants" login flow, or a single human identity spanning multiple tenants without
a per-tenant row. R-Co's adp-04 already commits to single-tenant-per-user-row, and
nothing in Letflow's roadmap requires otherwise, so this record accepts the
foreclosure. Flagged explicitly so a future requirement needing multi-tenant users
knows it must reopen this record rather than discovering the constraint by
surprise.

## 4. Migration/cutover shape (design-level; REQ-B owns the detail)

`users`/`groups`/`tenant_role` are live tables. The move is not a column drop; it
is a table relocation, and it must be ordered:

1. Add the three tables to `tenant_scoped_migrations/0`, each written with
   REQ-022 §4's mandatory `prefix()`-truthiness guard, so a plain `mix
   ecto.migrate` no-ops on them and only a `replay_migrations/2` run creates them.
2. Replay migrations across every registered tenant schema, creating the three
   tables per-tenant, empty.
3. Copy each public row into the schema its `tenant_id` names — this is the last
   point at which the column is read, and reading it here is exactly its
   legitimate use.
4. Drop the three public-schema tables, following `GBL-112`'s precedent of a
   guarded, separate cutover step rather than a same-migration drop.
5. Drop `tenant_id` from `users` and `groups` (per-schema copies), and from the
   eight D2 business tables.

Steps 3–4 have no production data at stake (no deployment exists yet, per
`CLAUDE.md`'s humanless-operation note), so REQ-B may collapse them if its design
step justifies doing so — but the *ordering* above is not optional, and the
`tenant_id` drop must come last, after every consumer of it is gone.

## 5. Consumers to remove (design-level inventory, verified this session)

- ~13 `TenantProvisioning.tenant_id_for_schema_name/1` call sites whose only
  purpose is stamping the column: `lib/letflow/definitions.ex` (8 sites),
  `lib/letflow/event_store.ex` (4), `lib/letflow/definitions/promotion_review_store.ex` (1).
  Sites binding `{:ok, _tenant_id}` and discarding it are pure validation of the
  prefix string's shape — REQ-B must decide per-site whether that validation is
  still wanted (a `valid_prefix?/1`-style guard) or removable.
- `tenant_id_for_schema_name/1` itself becomes unused by write paths but is still
  needed by step 4's data copy and possibly by D4 reporting — **do not delete the
  function**, only its stamping call sites.
- Two composite indexes lose their leading column and simplify to
  `unique_index([:plan_digest])` (`promotion_reviews`) and
  `unique_index([:idempotency_key])` (`promotion_assertion_runs`). Semantically
  identical inside a per-tenant schema, per R3; the idempotency contract behind the
  latter must be restated in the migration header.
- Schema modules dropping the `field(:tenant_id, Ecto.UUID)` line and its
  `cast`/`validate_required` entries: `Engine.Task`, `Engine.Token`,
  `EventStore.Event`, `EventStore.ArchivedEvent`, `EventStore.InstanceProjection`,
  `Definitions.ProcessDefinition`, `Definitions.PromotionReview`,
  `Definitions.PromotionAssertionRun`, `Identity.User`, `Identity.Group`.
- Moduledoc blocks in `Engine.Task`/`Engine.Token` ("`tenant_id` is never
  caller-supplied") and `Identity.User` ("intra-schema column per Decision B")
  describe a column that will no longer exist and must go with it.

## 6. Exactly what this supersedes in 0003

**Superseded** — Dimension B's clause *"with `tenant_id` columns retained inside
each schema on the tables the adp-0x docs describe, kept as an intra-schema
invariant/query-predicate discipline"*, and the Addendum's write-time derivation
mechanism, which becomes moot for the D2 tables (no column to populate).

**Standing, explicitly not reopened** — Dimension B's actual isolation decision
(schema-per-tenant via Ecto `:prefix`) is unchanged and is the premise this record
argues *from*, not against. Dimension A (Ecto-idiomatic redesign) and Dimension C
(event-store strategy: append-only, deferred partitioning, `(event_id, created_at)`
PK, idempotency sidecar) are untouched. The Addendum's rejection of caller-supplied
`tenant_id` is not reversed — D2 makes it unreachable rather than permitting it.
Option (b)'s deferred session-GUC tenant context remains deferred and is *further*
disfavoured by this record: a GUC exists to populate a column D2 removes.

## 7. Open questions this record does NOT resolve

1. **When does D4's cross-tenant reporting mechanism get built?** Not now — no
   consumer exists. This record commits to *where* it lives, not to building it.
   A future requirement owns it.
2. **Does `tenants.status == :migrating` gate the D1 cutover?** REQ-022 §7's
   secondary open question (provisioning vs. tenant status) is adjacent and stays
   open; REQ-B's design step should state whether the cutover pauses writes via
   that flag or relies on there being no deployment.
3. **Multi-tenant human identity** — foreclosed by §3.3, reopenable only by
   superseding this record.

## 8. Gates required before REQ-B may execute

- **REVIEWER** — decision-record consistency: that §6's supersession is scoped
  correctly and does not silently reopen Dimension B's isolation choice.
- **SECURITY-REVIEWER** — §3 specifically, against INV-1..INV-8. §3.2's argument
  (that `tenants_idp_realm_id_partial_index` relocates rather than removes the
  global OIDC-identity guarantee) is the single claim this record most needs
  independently re-derived rather than accepted.
