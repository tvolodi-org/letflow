# GH 2534 PR 7b-2b: `scripts.sod`, auto-strict, self-published versions and confirmation (decision 0053 D6 + D6 amendment)

Decision: `docs/migration/decisions/0053-tenant-scripted-rules.md` D6, its "D6 amendment
2026-10-14" and "7b rulings" (docs PR #2559). Stacked on 7b-1 (PR #2560) and 7b-2a
(`gh2534-7b2a-script-policy.md`). **Implement only after GH #2547's helper is merged**; this design
is written against the #2547 contract fixed by CODE-DESIGN-VALIDATOR and SECURITY-REVIEWER
(source: `lib/letflow/design/gh2547-tenant-admin-audit-and-count.md` section Contract, on the #2547
branch), relayed by the coordinator 2026-10-14. Section 1 lists exactly what is assumed from it.
Revision 2: CODE-DESIGN-VALIDATOR blocker + 2-7 and SECURITY-REVIEWER F2-F6 resolved, tagged
[CDV n] / [SEC Fn].

What 7b-2b adds: a declared tenant policy `scripts.sod = strict | solo_audited`; a platform flag
that forbids `solo_audited` per tenant; a COMPUTED effective policy evaluated under the tenant
admin lock; auto-strict (a refused solo publish flips the declared policy to `strict`, audited, in
a committed transaction under the lock); `self_published` written only for an allowed solo
publish (trigger extended); the publish-time SoD set stored on the row (`sod_excluded`); a
pending-review list DERIVED at read time; a confirmation route. Nothing in 7b-2b hooks identity
paths (the amendment: "There are no identity hooks").

## 0. Verified facts (this branch, 7b-1 head b3758de2 + 7b-2a design)

* 7b-1 `publish/6` (`lib/letflow/scripts.ex:209-253`): pre-checks (`publishable/5`), then
  `run_test_cases/2` with no connection, then ONE transaction: `lock_key!/2`
  (`pg_advisory_xact_lock(hashtext($1))`, `$1 = prefix <> ":script_rules:" <> key`, :530-532), then
  `lock_row!/3` (`FOR UPDATE`, :534-543), `publishable/5` again, update, `audit!/6`
  (`Audit.insert_entry/3`, :571-580). `publishable/5` (:255-275) has five clauses in this order:
  status draft, sha256 equal, test cases non-empty, `actor.user_id in sod_set(prefix, rule)`
  (-> `:publisher_is_contributor`), restricted inputs. SoD set `sod_set/2` (:279-299): contributors
  of every version above the last version with `published_at` plus this version's own.
* 7b-1 trigger `script_rules_guard()` (`priv/repo/migrations/20261014000001_create_script_rules.exs:88-168`):
  refuses ANY change of `self_published` (:101); the draft -> published branch refuses
  `NEW.publisher_id = ANY(NEW.contributors)` unconditionally (:124); the published/retired branch
  allows only retire and revoke transitions (:144-164).
* `script_rules.self_published boolean NOT NULL default false` exists (migration :42); the list and
  detail maps already return it (`routers/script_rules.ex:223`).
* 7b-2a: `script_policy` singleton row (`id = 1`) with the two kill-switch latches; guard trigger
  `script_policy_guard()` names only `id`/`inserted_at` and DELETE; changesets cast only their
  writer's columns; policy keys `:ScriptPolicyRead -> :ScriptsWrite`, `:ScriptPolicyManage ->
  :ScriptsPublish`; platform routes under `/tenants/:slug/script-policy` (`:TenantsManage`) with the
  9a8aa7ca audit split and the allowlisted `platform_policy_map/1`; `operator` actor map with
  `platform_prefix`; 7b-2a P11 (PLATFORM_ADMIN in the platform tenant passes `:ScriptsPublish`).
* Tenant tier / "enterprise" notion: NOT FOUND. Public `tenants` has `slug, display_name, status,
  idp_realm_id, settings, storage_allowance_bytes, login_disclosure_mode`
  (`identity/tenant.ex:76-94`); grep `enterprise|tier` over `lib/` finds nothing tenant-related.
* GH #2547 helper: NOT in `lib/` yet (contract below is the fixed design, not merged code).

## 1. Assumed from GH #2547 (exact contract; all in `Letflow.Identity`, `prefix` positional)

| # | Function | What 7b-2b relies on |
|---|---|---|
| A1 | `count_tenant_wide_admins(prefix) :: non_neg_integer()` | Distinct users with status `:active` who are members of the group bound to tenant role `"TENANT_ADMIN"` (kind `:platform_role`), OR owners of an `api_tokens` row with `TENANT_ADMIN` in roles, `revoked_at` nil, `expires_at` nil or > now. Deactivated users' tokens do not count (GH #2557). PLATFORM_ADMIN does not count. Scoped holders excluded through `exclude_scoped_holders/2` (excludes no one until 0051 stage 1). One read query; safe inside the caller's transaction and sees its uncommitted writes; raises on DB error. |
| A2 | `tenant_wide_admin_user_ids(prefix) :: [Ecto.UUID.t()]` | The same set as A1, sorted ascending. 7b-2b uses it where it must know WHETHER A GIVEN USER is a counted admin (solo publish, solo switch, confirm). |
| A3 | `tenant_admin_lock_key(prefix) :: integer()` | Pure, signed 64-bit, always outside the int4 range `hashtext` produces, so it never collides with the 7b-1 per-key lock or the 7b-2a masters lock. 7b-2b does not call it directly (only via A4). |
| A4 | `lock_tenant_admins!(prefix) :: :ok` | `pg_advisory_xact_lock(tenant_admin_lock_key(prefix))`; raises `ArgumentError` outside a transaction; re-entrant. Every admin-ADDING path of #2547 takes it. [SEC F5] Every #2547 path takes `lock_tenant_admins!/1` BEFORE the audit chain lock and before any row that 7b-2b locks (`script_rules`, `script_policy`, `script_readable_masters`), and never takes the 7b-1 per-script-key lock. **Confirmed by the #2547 implementer 2026-10-14 (letflow-9c: their paths never take the script-key lock; the admin lock is first).** |

**Binding lock order (coordinator + #2547 implementer):** in every 7b-2b transaction
`lock_tenant_admins!/1` is the FIRST lock. Then, in this order, whichever of the following the
transaction needs: the 7b-1 per-key advisory lock (`lock_key!/2`); the `script_rules` row
`FOR UPDATE`; the 7b-2a master rows `FOR SHARE` (publish only); the `script_policy` row
`FOR UPDATE`; then `Audit.insert_entry/3` (the audit chain lock last). **NEVER call
`lock_tenant_admins!/1` while already holding the per-key lock or any row lock.** This applies to
the auto-strict transaction, the publish transaction, the solo-mode switch (`set_sod/4`), the
platform solo flag (`set_platform_solo_audited/5`) [CDV 3] and confirm: every 7b-2b transaction,
no exception. Consistency with 7b-2a: its kill-switch flip touches only the policy row, its master
writes only the master rows, neither takes the admin lock and both take their row before the audit
chain, so no cycle exists with any 7b-2b path or with #2547 (A4).

**Residual windows stated by #2547 (until GH #2533):** user deactivation/reactivation and
pending-grant revoke do not take the admin lock. Consequence here: a reactivation concurrent with
a solo publish can commit between the count and the publish commit, so a solo publish can land
while a second admin is appearing. The safety property still holds (D6 amendment): the version is
marked `self_published` and appears on the pending-review list as soon as the count is >= 2,
because the list is derived at read time. Deactivation only lowers the count (a concurrent refusal
is the safe direction).

**Residual inherent to D6 [SEC F6]: the sock-puppet second admin.** A sole tenant-wide admin can
add a second account they control (or that a colluder controls) as TENANT_ADMIN and use it to
confirm their own self-published version, or simply to publish under strict mode. D6 states that
two accounts of one person cannot be solved technically. Mitigation: the grant is audited by
#2547 (group-member add / token mint, with actor and target), and the confirmation is audited
with the confirmer's id, so the pair is reconstructable from the tenant chain. Recording the IdP
subject stays a SHOULD (D6).

## 2. Decisions taken in this design (each with its reason)

| # | Decision | Reason |
|---|---|---|
| S1 | Effective SoD is `solo_audited` iff declared `sod = 'solo_audited'` AND `count_tenant_wide_admins(prefix) <= 1`; otherwise `strict`. (`platform_solo_audited_allowed` is implied: the DB CHECK of 3.1 makes declared `solo_audited` impossible while forbidden, so it is not a separate cause [CDV 6].) A solo publish additionally requires the publisher to be in `tenant_wide_admin_user_ids(prefix)`. | D6: solo mode "matters only when the author IS the single tenant-wide admin". With the count alone, a non-counted publisher (a PLATFORM_ADMIN in the platform tenant, 7b-2a P11; after 0051 a scoped TENANT_ADMIN) could self-publish while someone else is the single admin. A2 makes the membership exact. |
| S2 | No tier notion exists, so the platform flag defaults to FORBIDDEN for every tenant (`platform_solo_audited_allowed boolean NOT NULL DEFAULT false`, in `script_policy`). The operator explicitly allows solo mode per tenant. | D6: "default 'forbidden' for enterprise tenants". Without a way to tell enterprise tenants apart, forbidding for all is the only default that satisfies it; a later tier record may change the default for non-enterprise tenants. Stored beside the 7b-2a platform latch (same writer, same audit split, one row read at publish). |
| S3 | The operator forbidding solo mode (allowed true -> false) also sets the declared `sod` to `strict` in the same transaction (audited, class `platform_operator`) when it was `solo_audited`. | The CHECK requires it; it also prevents a later re-allow from silently restoring solo mode without a tenant decision. |
| S4 | [BLOCKER fix] Auto-strict is decided and committed in a SHORT dedicated transaction BEFORE the stored tests: when the declared value is `solo_audited` and the publisher is in the SoD set, `publish` runs `Policy.solo_gate/3` (section 5 step B): `lock_tenant_admins!` first, then the policy row `FOR UPDATE`, recount; count >= 2 -> flip to `strict` + audit, COMMIT, return 403 `publisher_is_contributor`. The publish transaction (step D) keeps the same branch as a backstop for an admin appearing between B and D (also under the admin lock, also committed). Never flip outside the admin lock. | D6 amendment: "A count of 2 or more refuses a solo publish and flips the stored policy to strict in the same transaction (audited)". The first revision only flipped in the publish transaction, which the unlocked pre-check almost always pre-empted, so the flip never happened in the normal case. Step B makes the normal case flip; it runs no script and holds the lock for two short statements. |
| S5 | The switch to `solo_audited` also requires the CALLER to be in `tenant_wide_admin_user_ids/1` (403 `not_tenant_wide_admin`). Switching to `strict` needs only `:ScriptPolicyManage` and reads no count [CDV 5]; it still takes the admin lock first (uniform rule). | D6: "a tenant-wide-admin action (0051 D11)". Strict is always the safer direction; a non-counted caller must not be able to enable solo mode. |
| S6 | Confirmation is allowed for `self_published` versions in status `published` or `retired`, not yet confirmed; the confirmer must be in `tenant_wide_admin_user_ids/1`, NOT in the row's stored `sod_excluded` (the publish-time SoD set, which includes the publisher and contributors to earlier unpublished or discarded versions) [SEC F2], OIDC, and send the stored `sha256`. It does not require count >= 2. | D6: "cleared by a non-contributor admin's confirmation bound to the sha256", and the SoD set is "any revision since the last published version", not only this version's contributors. Storing the set at publish makes it immutable and lets the trigger enforce it (later publishes change what `sod_set/2` would compute now). |
| S7 | Pending-review list = versions with `self_published AND confirmed_at IS NULL AND status IN ('published','retired')`, shown only while `count_tenant_wide_admins(prefix) >= 2` (count read WITHOUT the lock, advisory). | D6 amendment: derived at read time; "still-running" = can still run (published, or retired with pinned instances); revoked cannot run. |
| S8 | Tenant-facing RESPONSES never expose the admin count; they expose `sod.effective` and a reason code (`declared_strict`, `multiple_admins`, `solo_allowed`). The tenant AUDIT carries `admin_count` only in `script_policy.sod_auto_strict` [CDV 5]. | Responses go to `:ScriptsWrite` holders (designers) who do not need it. The auto-strict entry is a SYSTEM action whose cause must be reviewable; the audit chain is read only by `:AuditRead` holders (TENANT_AUDITOR, TENANT_ADMIN), who can already enumerate the admin set from #2547's grant audit entries and the group APIs, so the count discloses nothing new to them. `sod_set` and `published` entries do not carry it (the count is not their cause). |
| S9 | The trigger enforces what it can see in the same schema: `self_published` may become true only at draft -> published and only while the policy row says `sod = 'solo_audited' AND platform_solo_audited_allowed`; `sod_excluded` written at publish and immutable; a confirmer outside `sod_excluded`. The count and admin-set membership are application checks under the admin lock. | Defence in depth without re-implementing the #2547 query in plpgsql (the helper and its extension point stay the single source of the count). |
| S10 | [SEC F4] The platform GET and the platform solo PUT expose only PLATFORM-owned state (`solo_audited.allowed / set_at / reason`) and the 7b-2a latch map; NOT the declared or effective `sod`. | The effective value reveals whether the tenant has 2+ admins and the declared value is a tenant decision with a tenant-authored reason; neither is needed to decide whether to allow solo mode, so no 0046 D4 acceptance is needed. |

## 3. Schema changes (tenant migration `<next>_add_script_sod.exs`, own migration, after 7b-2a's)

### 3.1 `script_policy` gains

| Column | Type | Notes |
|---|---|---|
| `sod` | text NOT NULL default `'strict'` | CHECK `sod IN ('strict','solo_audited')` (declared value only) |
| `sod_set_by` | uuid null | tenant user id; NULL for `platform_operator` and `system` |
| `sod_set_by_class` | text null | CHECK in `('tenant_admin','platform_operator','system')` |
| `sod_set_at` | utc_datetime_usec null | |
| `sod_reason` | text null | CHECK `char_length <= 500`; for `system` the constant `auto_strict` |
| `platform_solo_audited_allowed` | boolean NOT NULL default false | S2 |
| `platform_solo_audited_set_at` | utc_datetime_usec null | no operator id (9a8aa7ca) |
| `platform_solo_audited_reason` | text null | CHECK `char_length <= 500` |

Plus CHECK `NOT (sod = 'solo_audited' AND NOT platform_solo_audited_allowed)`.
**`script_policy_guard()` is NOT replaced [CDV 7]:** it names only `id`, `inserted_at` and
DELETE (7b-2a 2.1), so it already covers the new columns.
Changesets (7b-2a SEC F4 rule extended): `sod_changeset/2` casts only the five `sod*` columns;
`platform_solo_changeset/2` casts only the three `platform_solo_audited*` columns plus, for S3,
the five `sod*` columns (that write is part of the operator's act). Neither casts a kill-switch
column; the 7b-2a latch changesets cast none of these.

### 3.2 `script_rules` gains

| Column | Type | Notes |
|---|---|---|
| `sod_excluded` | uuid[] null | [SEC F2] publish-time SoD set ∪ {publisher}; NULL on drafts, discarded rows and rows published before this migration |
| `confirmed_by` | uuid null | |
| `confirmed_at` | utc_datetime_usec null | |
| `confirmed_sha256` | text null | |

CHECKs: the three `confirmed_*` all NULL or all NOT NULL; `confirmed_by IS NULL OR
(self_published AND sod_excluded IS NOT NULL)`; `sod_excluded IS NULL OR
array_position(sod_excluded, NULL) IS NULL` (as 7b-1's contributors check: a NULL element would
make `= ANY` NULL and silently pass).

### 3.3 Trigger `script_rules_guard()` replaced (`CREATE OR REPLACE FUNCTION`, same name, ERRCODE `LF001`)

Rule changes against the 7b-1 function (everything else unchanged):
1. Identity check: `self_published` removed from the "identity columns are immutable" list.
2. `OLD.status = 'draft'`, `NEW.status = 'draft'` or `'discarded'`: `self_published` stays false;
   `sod_excluded` and the three `confirmed_*` stay NULL.
3. `OLD.status = 'draft'`, `NEW.status = 'published'`: the three `confirmed_*` NULL;
   `NEW.sod_excluded IS NOT NULL AND NEW.contributors <@ NEW.sod_excluded AND NEW.publisher_id =
   ANY(NEW.sod_excluded)`;
   - if `NEW.self_published = false`: `NOT (NEW.publisher_id = ANY(NEW.contributors))` (7b-1 rule);
   - if `NEW.self_published = true`: the policy row (`script_policy WHERE id = 1`, schema-qualified
     with the migration's `prefix()`) has `sod = 'solo_audited'` AND
     `platform_solo_audited_allowed`; else raise (S9). Publisher in contributors is then permitted.
4. `OLD.status IN ('published','retired')`: `self_published` and `sod_excluded` unchanged always.
   A third allowed shape beside retire and revoke, **confirmation**: status unchanged; all of
   `OLD.confirmed_*` NULL and all `NEW.confirmed_*` NOT NULL; `OLD.self_published`;
   `OLD.sod_excluded IS NOT NULL`; `NEW.confirmed_sha256 = OLD.sha256`; `NOT (NEW.confirmed_by =
   ANY(OLD.sod_excluded))`; nothing else but `updated_at` changes. Retire and revoke require
   `confirmed_*` unchanged.
5. `OLD.status IN ('revoked','discarded')`: unchanged (every UPDATE refused).

## 4. Context `Letflow.Scripts.Policy` additions

* `effective_sod(prefix) :: {:strict | :solo_audited, :declared_strict | :multiple_admins | :solo_allowed}`
  Reads row 1 and `count_tenant_wide_admins/1`: declared `strict` -> `declared_strict`; else count
  >= 2 -> `multiple_admins`; else `solo_allowed` [CDV 6]. Authoritative only inside a transaction
  that holds `lock_tenant_admins!/1`; elsewhere display-only.
* `solo_gate(prefix, actor, opts) :: :solo_allowed | {:refused, :auto_strict} | {:refused, :strict}`
  The locked decision. MUST be called inside a transaction in which nothing is locked yet (step B)
  or right after the row locks of the publish transaction with the admin lock already held (step
  D; `opts[:admin_lock_held] == true`). It takes (step B) `lock_tenant_admins!/1`, then row 1
  `FOR UPDATE`, then `count`, `admins`:
  - declared `strict` -> `{:refused, :strict}` (no write);
  - declared `solo_audited` and count >= 2 -> update `sod = 'strict'`, class `system`,
    `sod_set_by = NULL`, `sod_set_at = now`, `sod_reason = 'auto_strict'`; audit
    `script_policy.sod_auto_strict`; `{:refused, :auto_strict}` (the caller COMMITS);
  - declared `solo_audited`, count <= 1, `actor.user_id in admins` -> `:solo_allowed`;
  - otherwise -> `{:refused, :strict}` (no write).
* `set_sod(prefix, sod :: String.t(), reason, tenant_actor) :: {:ok, ScriptPolicy.t()} | {:error, error}`
  Order: credential `:oidc`; `sod` in `["strict","solo_audited"]` (else `:invalid_state`);
  `Validation.reason/1`. Transaction: `lock_tenant_admins!/1` FIRST; row 1 `FOR UPDATE`; equal
  declared value -> no write (7b-2a P9); for `solo_audited` only: `platform_solo_audited_allowed`
  false -> rollback `:solo_audited_forbidden`; caller not in `tenant_wide_admin_user_ids/1` ->
  `:not_tenant_wide_admin`; `count_tenant_wide_admins/1 >= 2` -> `:multiple_tenant_admins`. For
  `strict` no count or admin set is read [CDV 5]. Update via `sod_changeset/2` (`sod_set_by =
  user_id`, class `tenant_admin`, `sod_set_at`, `sod_reason`); audit `script_policy.sod_set`.
* `set_platform_solo_audited(prefix, tenant_id, allowed :: boolean(), reason, operator) :: {:ok, ScriptPolicy.t()} | {:error, error}`
  Order: credential; `allowed` boolean (else `:invalid_state`); reason; `operator.platform_prefix`
  binary (else `:audit_failed`, nothing written). Transaction [CDV 3]: `lock_tenant_admins!/1`
  FIRST; row 1 `FOR UPDATE`; no-op rule; update via `platform_solo_changeset/2`; on true -> false
  with declared `solo_audited`, also `sod = 'strict'`, class `platform_operator`, `sod_set_by =
  NULL`, `sod_reason` = the operator's reason (S3); tenant-chain entry (nil actor), then
  platform-chain entry.
* `pending_review(prefix) :: {[ScriptRule.t()], truncated :: boolean()}`: S7 (count without lock;
  `{[], false}` when count < 2), ordered by `(key, version)`, capped at 500.

## 5. Publish restructured (`Letflow.Scripts.publish/6`, `publish/7`)

**`publishable/5` is split [CDV 2].** 7b-1's single function becomes:
* `publishable(rule, reviewed_sha, may_publish_restricted?) :: :ok | {:error, atom}`: status draft,
  sha256 equal, test cases non-empty, restricted inputs/fields (7b-2a). NO SoD clause.
* `in_sod_set?(prefix, rule, actor) :: {boolean(), [Ecto.UUID.t()]}`: whether `actor.user_id` is in
  `sod_set(prefix, rule)`, and the set (the set is then stored as `sod_excluded`).
The 7b-1 clause `actor.user_id in sod_set(...) -> :publisher_is_contributor` is removed from
`publishable`; the SoD outcome is decided by the steps below, which is what lets the
in-transaction check reach the `self_published` path.

**A. Pre-checks, no transaction:** credential; version exists (`fetch/3`); kill switch (7b-2a);
`publishable/3`; `check_reads/2` (7b-2a); `{in_set, _} = in_sod_set?/3`. If `in_set`, read the
declared `sod` (plain read of row 1):
* declared `strict` -> `{:error, :publisher_is_contributor}` now (no lock, no write: nothing to
  flip; tests not run).
* declared `solo_audited` -> step B.

**B. Auto-strict gate (only when `in_set` and declared `solo_audited`):** a short transaction
`Repo.transaction(fn -> Policy.solo_gate(prefix, actor, []) end)` (admin lock FIRST, policy row,
recount). `{:refused, :auto_strict}` -> the transaction COMMITS the flip and its audit entry; return
`{:error, :publisher_is_contributor}`. `{:refused, :strict}` -> `{:error,
:publisher_is_contributor}`. `:solo_allowed` -> continue (the lock is released at commit; D
re-decides under the lock). The stored tests are NOT run before B's decision.

**C. Stored tests** (7b-1 section 4, 7b-2a per-case kill switch), no connection held.

**D. Publish transaction**, locks in the binding order:
1. `Identity.lock_tenant_admins!(prefix)` (FIRST; nothing locked yet). Taken on EVERY publish
   (also non-contributor ones) so that one code shape holds. Accepted trade-off [CDV r2 note 1]:
   publish transactions of one tenant serialise with each other and with #2547's admin paths;
   the transaction is short (the stored tests run outside it, step C), so the cost is small.
2. `lock_key!(prefix, key)`; 3. `lock_row!(prefix, key, version)`.
4. Re-check: `publishable/3`, kill switch (plain read), `check_reads(prefix, manifest, lock: :share)`.
5. `{in_set, set} = in_sod_set?/3` (recomputed under the per-key lock).
   * `in_set == false` -> `self_published = false`.
   * `in_set == true` -> `Policy.solo_gate(prefix, actor, admin_lock_held: true)` (policy row
     `FOR UPDATE` after the row lock, as the order allows):
     - `:solo_allowed` -> `self_published = true`;
     - `{:refused, :auto_strict}` (a second admin appeared between B and D) -> the transaction
       returns `{:ok, {:refused, :publisher_is_contributor}}` and COMMITS the flip; the context maps
       it to `{:error, :publisher_is_contributor}`;
     - `{:refused, :strict}` -> rollback `:publisher_is_contributor`.
6. Update the row (`published`, `publisher_id`, `published_at`, `self_published`,
   `sod_excluded = set ∪ [actor.user_id]`, deduplicated); audit `script_rule.published`.

The trigger (3.3) re-checks the `self_published` / contributor / `sod_excluded` rules.

## 6. Routes

### 6.1 Tenant (`Letflow.Routers.ScriptPolicy`, 7b-2a mount `/script-policy`)

| Route | Policy key -> permission | Body | Effect |
|---|---|---|---|
| `PUT /sod` | `:ScriptPolicyManage` -> `:ScriptsPublish` | `{sod, reason}` | `set_sod/4`; 200 `policy_map` |
| `GET /pending-review` | `:ScriptPolicyRead` -> `:ScriptsWrite` | | `{items: [summary_map], truncated}` |

`policy_map/1` (7b-2a) gains `"sod": {"declared", "effective", "effective_reason", "set_by",
"set_by_class", "set_at", "reason", "platform_allowed"}` (S8: no count).

### 6.2 Tenant (`Letflow.Routers.ScriptRules`)

| Route | Policy key -> permission | Body | Effect |
|---|---|---|---|
| `POST /:key/versions/:version/confirm` | new key `:ScriptRulesConfirm` -> `:ScriptsPublish` | `{sha256}` | section 6.4 |

`summary_map/1` gains `confirmed_at`; `version_map/1` gains `confirmed_by`, `confirmed_sha256`,
`sod_excluded` (detail route only; `:ScriptsWrite` holders already see `contributors`).

### 6.3 Platform (`Letflow.Routers.Tenants`)

| Route | Policy key | Body | Effect |
|---|---|---|---|
| `PUT /:slug/script-policy/solo-audited` | `:TenantsManage` | `{allowed: bool, reason}` | `set_platform_solo_audited/5`, handler order as 7b-2a 9.2; 200 `platform_policy_map/1` |

`platform_policy_map/1` (7b-2a) gains exactly `"solo_audited": {"allowed", "set_at", "reason"}`
(platform-owned columns only). Never `sod`, `sod_reason`, `sod_set_by`, `sod_set_by_class`, the
effective value or its reason (S10, SEC F3, SEC F4). The platform GET returns the same map.

### 6.4 Confirm (`Letflow.Scripts.confirm(prefix, key, version, reviewed_sha, actor)`)

Order: credential `:oidc`; version parse (else 404). Transaction: `lock_tenant_admins!/1` (FIRST);
`lock_key!/2`; `lock_row!/3` (unknown, foreign or discarded -> plain 404); status
`published`/`retired`, `self_published`, not confirmed -> else 409 `not_pending_review`; stored
sha256 == body sha256 -> else 409 `content_changed`; `actor.user_id in
tenant_wide_admin_user_ids(prefix)` -> else 403 `not_tenant_wide_admin`; `actor.user_id not in
rule.sod_excluded` -> else 403 `confirmer_is_contributor` [SEC F2]; update `confirmed_by`,
`confirmed_at`, `confirmed_sha256 = sha256`; audit `script_rule.confirmed`.

### 6.5 Authorization touch points

`@type endpoint_policy_key` add `:ScriptRulesConfirm`; `endpoint_policy_key/2`:
`("PUT", "/script-policy/sod")` -> `:ScriptPolicyManage`; `("GET", "/script-policy/pending-review")`
-> `:ScriptPolicyRead`; `("POST", "/script-rules/:key/versions/:version/confirm")` ->
`:ScriptRulesConfirm`; `("PUT", "/tenants/:slug/script-policy/solo-audited")` -> `:TenantsManage`.
`required_permission(:ScriptRulesConfirm) -> :ScriptsPublish`. No role or `docs/roles.md` change.
0051 obligation (GH #2533): `PUT /script-policy/sod` and confirm classified admin-plane.

### 6.6 Error atoms and HTTP mapping [CDV 4]

| Atom | Module(s) `@type error` | HTTP | Body `error` | Raised by |
|---|---|---|---|---|
| `:not_found` | Scripts, Policy | 404 plain | (fixed not-found body) | confirm (unknown/foreign/discarded), publish |
| `:api_token_not_allowed` | Scripts, Policy | 403 | `api_token_not_allowed` | publish, confirm, `set_sod`, platform solo PUT |
| `:publisher_is_contributor` | Scripts | 403 | `publisher_is_contributor` | publish steps A, B, D |
| `:not_tenant_wide_admin` | Scripts, Policy | 403 | `not_tenant_wide_admin` | confirm, `set_sod` (to solo) |
| `:confirmer_is_contributor` | Scripts | 403 | `confirmer_is_contributor` | confirm |
| `:not_pending_review` | Scripts | 409 | `not_pending_review` | confirm |
| `:content_changed` | Scripts | 409 | `content_changed` | publish, confirm |
| `:version_immutable` | Scripts | 409 | `version_immutable` | trigger `LF001` (any path) |
| `:solo_audited_forbidden` | Policy | 409 | `solo_audited_forbidden` | `set_sod` (to solo) |
| `:multiple_tenant_admins` | Policy | 409 | `multiple_tenant_admins` | `set_sod` (to solo) |
| `:invalid_state` | Policy | 422 | `invalid_state` | `set_sod`, platform solo PUT |
| `:invalid_reason` | Policy | 422 | `invalid_reason` | `set_sod`, platform solo PUT |
| `:scripts_disabled` | Scripts | 409 | `scripts_disabled` | publish (7b-2a) |
| `:audit_failed` / `{:audit_failed, _}` | Scripts, Policy | 500 | (fixed internal-error body) | any write |

Router replies: `Routers.ScriptRules.reply/3` adds `:not_tenant_wide_admin`,
`:confirmer_is_contributor` (403 via `Response.forbidden/2`) and `:not_pending_review` (409 via
`Response.conflict/2`); `Routers.ScriptPolicy` maps the Policy atoms as in the table; the
`Routers.Tenants` solo handler maps `:api_token_not_allowed`, `:invalid_state`, `:invalid_reason`,
`:not_found` and `:audit_failed` exactly as the 7b-2a kill-switch handler does. Bodies never echo
values.

## 7. Audit (same transaction; 0051 D8 shape; trace id rules as 7b-2a section 7)

| Action | Chain | actor_id | after_state (before_state) |
|---|---|---|---|
| `script_policy.sod_set` | tenant | tenant user | `{"sod", "reason"}` (`{"sod"}`) |
| `script_policy.sod_auto_strict` | tenant | the publishing user (the request that triggered it) | `{"sod": "strict", "set_by_class": "system", "cause": "tenant_wide_admin_count", "admin_count", "key", "version"}` (`{"sod": "solo_audited"}`) (S8) |
| `script_policy.platform_solo_audited_set` | tenant | nil | `{"platform_solo_audited_allowed", "reason", "sod", "actor_class": "platform_operator"}` (`{"platform_solo_audited_allowed", "sod"}`) |
| `platform.tenant_script_solo_audited.set` | platform | operator | `{"tenant_id", "platform_solo_audited_allowed", "reason"}` |
| `script_rule.published` (7b-1, extended) | tenant | publisher | 7b-1 fields plus `"self_published"`, `"sod_excluded"` |
| `script_rule.confirmed` | tenant | confirmer | 7b-1 base (`key, version, status, sha256`) plus `"confirmed_by"`, `"confirmed_sha256"`, `"publisher_id"`, `"sod_excluded"` |

## 8. Acceptance criteria

* AC1 Declared sod defaults to `strict`; `platform_solo_audited_allowed` defaults to false for
  every tenant (existing and new); the DB refuses `solo_audited` while forbidden.
* AC2 `PUT /script-policy/sod` to `solo_audited`: 409 `solo_audited_forbidden` when the platform
  forbids; 409 `multiple_tenant_admins` when the count is >= 2 (a second admin via group membership,
  and separately via an unexpired TENANT_ADMIN token of an active user); 403
  `not_tenant_wide_admin` for a caller not in the admin set; reason mandatory; audited. To
  `strict` always allowed and reads no count. API token -> 403 `api_token_not_allowed`.
* AC3 Platform `PUT /tenants/:slug/script-policy/solo-audited`: 9a8aa7ca split (nil-actor tenant
  entry, operator id only in the platform chain, one transaction); forbidding with declared
  `solo_audited` resets it to `strict`. The PUT and the GET return EXACTLY the
  `platform_policy_map/1` key set (no `sod*` key, no effective value).
* AC4 Solo publish: allowed only when declared solo, count <= 1 and the publisher is in the admin
  set; the version gets `self_published = true`, `sod_excluded` = SoD set ∪ publisher, and the
  published audit entry says so. A publisher outside the admin set (count 1, someone else) -> 403.
* AC5 Auto-strict, NORMAL case (no concurrency): declared solo, count >= 2 (second admin added
  before the publish request), publisher in the SoD set -> 403 `publisher_is_contributor`; the
  declared policy is `strict` afterwards; exactly one `script_policy.sod_auto_strict` entry; NO
  stored test case ran (step B precedes C). A non-contributor publish with count >= 2 does not flip.
* AC5b Auto-strict, BACKSTOP: the second admin is added after step B and before step D (via the
  7b-2a `:before_case` seam during C) -> step D refuses and the flip is committed.
* AC6 Strict declared: a contributor publish -> 403 immediately, no lock taken, no flip, no test
  run, `self_published` stays false. "No lock taken" is shown by holding `lock_tenant_admins!` in
  another process for the whole call: the refusal returns without blocking [CDV r2 note 2].
* AC7 Trigger: raw update setting `self_published = true` at publish while the policy is strict ->
  `LF001`; publish without `sod_excluded` or with a contributor missing from it -> `LF001`; raw
  update of `self_published` or `sod_excluded` on a published row -> `LF001`; confirmation by a
  member of `sod_excluded`, with a wrong `confirmed_sha256`, on a non-self-published row, twice, or
  on a revoked row -> `LF001`.
* AC8 Pending review: a self-published unconfirmed published or retired version appears once the
  count reaches 2 (no identity hook; adding the second admin and then reading the list is enough);
  revoked and confirmed versions never appear; count < 2 -> empty list.
* AC9 Confirm: a counted admin outside `sod_excluded` with the stored sha256 -> 200, audited, leaves
  the list; a contributor of THIS version, the publisher, and a contributor of an earlier DISCARDED
  draft since the last publish -> each 403 `confirmer_is_contributor` [SEC F2]; stale sha -> 409
  `content_changed`; not pending -> 409 `not_pending_review`; API token -> 403; caller not in the
  admin set -> 403 `not_tenant_wide_admin`.
* AC10 Lock order: in step B, step D, `set_sod`, `set_platform_solo_audited` and confirm,
  `lock_tenant_admins!/1` is the first lock (a source-scan test that the call precedes
  `lock_key!`/`lock_row!`/any `FOR UPDATE`/`audit!` in each of those functions, plus a runtime test
  that a process holding the per-key lock does not block step B); stored tests run outside every
  transaction.
* AC11 Concurrency: a solo publish and a #2547 admin-adding path (group-member add) run
  concurrently: either the publish commits first with `self_published = true` and the version is
  then pending review, or the grant commits first and the publish is refused with auto-strict
  committed; never a solo publish that is neither.
* AC12 Error mapping: each row of the 6.6 table produces its status and body code.

## 9. Tests (TEST-DESIGNER brief)

* `test/letflow/scripts/sod_test.exs`: AC1, AC4-AC7, AC8 (derived list as the admin set changes:
  add a group member, mint a TA token, deactivate a user, revoke/expire a token), AC9 at context
  level. Fixtures create admins through the real #2547-audited paths, not raw inserts, so the count
  is the helper's. AC5 asserts "no test case ran" with a script whose stored test would fail if
  executed (so a run would yield `test_case_failed`, not 403).
* `test/letflow/routers/script_policy_sod_test.exs`: AC2, AC8 route, AC12, response allowlists (no
  count field).
* Platform route test: AC3 including the exact key set.
* Concurrency: AC5b, AC10, AC11 with two processes and the sandbox in shared mode (or a
  non-sandboxed tagged test), bounded by explicit timeouts.
* Extend 7b-1 suites: "publisher in contributor set refused" stays (strict default); trigger tests
  for the 3.3 rule changes; `publishable/3` no longer returns `:publisher_is_contributor`.

## 10. Security (INV mapping)

* INV-1: prefix from `scoped_opts` (tenant) or the verified target tenant (platform); the helper
  takes the same prefix.
* INV-2: allowlist maps; no admin count or admin list in any response; platform maps carry only
  platform-owned state (S10).
* INV-3: no new sandbox entry point; step B runs no script.
* INV-4: none.
* INV-5: confirm on an unknown, discarded or foreign version is the plain 404, decided before any
  sha or membership check.
* INV-6: one new route group (`/sod`, `/pending-review`, confirm, platform solo flag); this section.
* INV-7: no new raw SQL beyond the trigger body (schema from `prefix()` only) and the helper's own.
* INV-8: every refusal a stable atom (6.6); a helper raise inside a transaction rolls back and maps
  to 500.
* INV-10: the solo flag is platform-scope (`:TenantsManage`, platform tenant, verified platform
  prefix); the tenant cannot write it, and the DB CHECK makes the declared value follow it.
* SoD property (D6): a version is never published by a contributor unless it is visibly
  `self_published`, audited, and reviewable once a second admin exists; it is confirmable only by
  a counted admin outside the stored publish-time SoD set. Residuals: section 1 (#2547 windows,
  sock-puppet second admin).

## 11. Deferred

* Record P: `self_published` and `sod_excluded` travelling through promotion / pack install and the
  target-side confirmation (the effective value of S1 is the one Record P must use).
* 7c: nothing (runs do not branch on sod).
* A tenant tier notion and a non-enterprise default (S2).
* Closing the #2547 residual windows (deactivation/reactivation, pending-grant revoke) is GH #2533.
* IdP subject recording (D6 SHOULD).
