# 0072 -- Tenant provisioner on QA: a realm per tenant, the lifecycle, the narrow credential, tenant identity and hostname

Status: PROPOSED for the design gate and the SECURITY-REVIEWER (written 2026-10-25, task T-0611, GH #3252, REQ-572).
Scope: **QA only.** Production is not approved (portfolio D-019). Nothing here touches a production Keycloak or a
production tenant.

Builds on, and does not contradict: `0042-email-first-login-tenant-directory.md` (Decision 7), `0044-hybrid-identity-model.md`
(realm per tenant, phase 1 ratified 2026-10-05), `0046-admin-scopes-and-role-charter.md` (D4, D5),
`0048-pending-tenant-admin-grant.md` (sections 1 to 3), `0051-org-scoped-role-grants-and-enforcement.md` (M2),
`0006-identity-tables-schema-per-tenant.md` (R5, as narrowed by 0048 section 2).
Amends by reference only: 0048 section 1 item 3 (a second creation path for the pending grant, section 5 below).

Sources: `ai-dala-portfolio` `contracts/provisioning.md` (draft v0.1), `proposals/letflow-realm-options.md` (sandbox rounds 1 to 4 and
"What a new tenant realm must contain, Letflow side"), `proposals/provisioner-decision-package.md`, `DECISIONS.md` D-016 to D-019;
`docs/requirements.yaml` REQ-572 and its amendment of 2026-10-25 (criteria 15 to 21).

Reader's guide: decisions are cited as "0072 D<n>". The realm-creating service is called "the provisioner" (built and run by infra).
"The front door" is the portfolio's landing-page service. "Letflow" is this product.

## 1. Problem

The front door must be able to ask Letflow, server to server, for a tenant that can be used at once: a tenant row and schema, its own Keycloak
realm, and a first administrator. Today none of that is possible without a person: a realm is cloned by hand (runbook
`docs/runbooks/onboarding-new-tenant-realm.md` R1 to R3), only a PLATFORM_ADMIN token can create a tenant, the tenant-to-realm binding is permanent (0048
section 2), and the contract's `tenant_id` cannot even be stored. The owner approved a QA build on 2026-10-25 (D-019). This record fixes the design
choices that the REQ-572 implementation slices and infra's provisioner both depend on.

## 2. D1. One realm per tenant, made by a provisioner; no Keycloak admin client in the Letflow backend

**Decided.** Each provisioned tenant gets its own Keycloak realm. The realm is created by the provisioner (infra's service, next to the QA Keycloak,
reachable only from the front door and Letflow). The provisioner holds **one create-realm-only credential**: a scoped Keycloak creator with
`fullScopeAllowed=false` and a scope mapping for `create-realm` only (D-018, sandbox round 3). With it the provisioner can create a realm; on a realm it
made it gets 403 for users, clients, PUT and DELETE. It cannot read, change or delete a realm it made. Deleting a realm is a separate, rarely used
reaper step (infra), after the order of D4.

**Letflow holds no Keycloak admin credential and gets no admin client.** The Letflow backend only reads a realm's public OIDC endpoints, as today
(`Letflow.Oidc.ProviderRegistry`). Reason: a credential that can create and delete realms, held by the product that serves every customer, is the
largest blast radius in the system (decision 0044 keeps that for a later phase 3); infra's service is the single place that holds it, with a private
network, a rate limit, a cap and an audit log (D-019).

**Rejected for now, and why.**
* *Shared realm with Keycloak Organizations (option 3).* The largest change to the auth path (about 100 references to `idp_realm_id` in 12 files,
  25 to 35 steps by 0044's own estimate), not cleanly reversible, and it breaks the permanent 1:1 tenant-to-realm binding of 0006 R5 / 0048 section 2.
  A demo that later becomes production would have to be split out of a shared realm, which changes users' `sub` and loses each user row.
* *Brokering and SSO through a central realm (option 4).* Decision 0042 Decision 7 ("scope fence: no SSO across realms, no identity-provider
  brokering") and 0044 (deferred until tests S-8 to S-10 and an explicit `email_verified` exception review) forbid it. It needs its own ADR. It stays possible
  later **on top of** this decision, because a brokered login still ends with the tenant realm's own token. Not promised for the demo.
* *Pool of pre-made realms.* A used realm is never freed, so an open demo burns a realm for good. Allowed only by hand for production tenants and first
  pilots, outside this record.
* *A limited Keycloak admin client inside Letflow* (the contract's option (a)). Same strong-credential objection as above.

## 3. D2. What one realm-creation request must contain

The provisioner creates the realm with **one** `POST /admin/realms` (sandbox round 4: all points below hold in a single request with the scoped creator;
after creation the creator cannot change the realm, so the request must be complete). The authoritative copy of the template is in this repository at
**`priv/keycloak/provisioner/v1/`** (versioned directory; infra's service seeds its v1 from `priv/keycloak/realms/bpm-default.json` plus a declarative user
profile, `services/tenant-provisioner/templates/v1` in ai-dala-infra). A future change of the template is a new directory `v2`, never an edit of `v1` in place.
`priv/keycloak/realms/bpm-default.json` stays unchanged (it is a dev seed with demo users and plain passwords and must never be used for a tenant).

The request holds:

| Item | Content |
|---|---|
| Realm name | `t-` plus the first 20 hex characters of `tenant_id` (the provisioner's rule). **Callers bind the realm and the issuer the service returns and never recompute them.** Letflow checks only the bind step's own rules (1 to 64 letters, digits, `_`, `-`, starts with a letter or digit, not `master`, exists on the configured Keycloak, runbook R3). |
| Realm settings | `verifyEmail` true; `duplicateEmailsAllowed` false; `registrationAllowed` false; no `identityProviders` entry (so no Trust Email); `bruteForceProtected` true; a non-empty `passwordPolicy`; users cannot edit their own e-mail (declarative user profile: the `email` attribute read-only for the user; the account API then answers 400 `error-user-attribute-read-only`); SMTP settings are an argument of the call (the shared QA relay), never part of the template and never in git. |
| Realm roles | `TENANT_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`, `AGENT_RUNNER`, `CANDIDATE`, `TENANT_AUDITOR`. **No `PLATFORM_ADMIN`.** `TENANT_ADMIN` is a plain realm role: not a composite, not in `default-roles-<realm>`, in no default group, in no client-scope role mapping (0046 D4; runbook realm checklist). |
| Client `letflow-web` | Public client; the client id is the same global value in every realm; **this tenant's own** redirect URIs and web origins derived from the validated `hostname` (never `*`); `directAccessGrantsEnabled` false. |
| Mappers | `realm-roles` (claim `roles`), `letflow-web-audience` (`aud` contains `letflow-web`); the standard `email` and `email_verified` mappers via the built-in `email` client scope (do not send a `clientScopes` list that drops it). `email_verified` must be the JSON boolean `true` (0048 section 1). |
| Optional | A realm attribute `tenant_id` for tracing only (Letflow reads the claim but does not trust it); the `letflow-mobile` client only when the tenant uses mobile. |
| First administrator | One inline user: e-mail equal to the onboarding `owner_email` (trimmed, lower-cased, ASCII or punycode), `enabled` true, `emailVerified` true, **and `"realmRoles": ["default-roles-<realm>"]` listed on the user itself** (sandbox trap: an inline user gets no default roles unless the request lists them, and the token then carries no roles and the account API answers 401). **No Keycloak admin rights**: no `realm-management` client role, no admin role, no group that grants one. The first sign-in credential is the provisioner's one-time `initial_password` (returned once, absent on a repeat call); who delivers it to the person stays with the front door (section 10). |

Why no Keycloak admin rights for the first administrator: Letflow needs none, and a customer with `realm-admin` could switch on self-registration or Trust
Email and undo the realm checklist and the take-over protections of 0048. `manage-users` for production tenants is not decided (section 10).

A drift test in this repository (REQ-572 criterion 15, with its path corrected to `priv/keycloak/provisioner/v1/`) reads the template and checks it against the
runbook checklist, so the template cannot drift from what Letflow requires. `LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` must never name a template realm (0048:
that setting is safe only for realms whose users an administrator creates, and the template's first administrator is verified).

## 4. D3. The order of calls; realm ownership; permanence

1. The front door calls the provisioner: realm created with the first administrator inline. The response carries `realm`, `issuer` and, once, `initial_password`.
2. The front door calls Letflow **once**: `POST /admin/v1/tenants` with `tenant_id`, `name`, `language`, `tier`, `owner_email`, `expires_at`, `hostname` and
   **`idp_realm_id`** (the realm the provisioner returned). Letflow creates the tenant, binds the realm and stores the pending grant in this one request
   (the single onboarding call, REQ-572 criterion 17). Only the chain "realm first, tenant second" exists: a tenant without a realm is never a normal
   state, and a realm without a tenant is only an orphan the reaper removes.
3. The person signs in through the tenant's own realm; the existing first-login binding (0048 section 1) makes them `TENANT_ADMIN`.

**Resolution of REQ-572 open question 11 (route of the single call).** The `/admin/v1` create route itself takes `idp_realm_id` and performs the
onboarding steps internally (create tenant, bind realm once, store the grant). `POST /api/v1/onboarding` is **not** opened to the provisioner credential:
it sits behind `ApiPipeline` and needs an authenticated `auth_context`; the narrow credential has none (D6). The contract (`contracts/provisioning.md`)
gains the field `idp_realm_id` in the create request; the portfolio owns that contract text and is told in the PR notes.

**Realm ownership.** The provisioner's record counts as "Realm ownership confirmed by" in the runbook checklist (D-019 item 6): the realm is made
only by that service. The runbook names the provisioner as the confirming party, no person is needed. This replaces the checklist's named-person step for
provisioned realms only.

**Permanence.** The binding is permanent (0006 R5, narrowed by 0048 section 2; the partial unique index `tenants_idp_realm_id_partial_index` also keeps one realm to
one tenant). A repeat call never changes it: with the tenant already bound, a different `idp_realm_id` in the body is ignored like every other body field (D5); a repeat that
supplies a realm to a tenant that is still unbound completes the one allowed bind (the same "completion" rule as the grant, D5).
A realm outside this tenant's own, for example one already bound to another tenant, answers 409 `conflict` and writes nothing.
If the provisioner created the realm but Letflow failed, the front door repeats the Letflow call with the same `tenant_id`; no second realm is made
(the provisioner is idempotent on `tenant_id`, the realm name rule is deterministic).

## 5. D4. The lifecycle, and the order of deletion

| Contract call | Letflow does | Contract status |
|---|---|---|
| `suspend` | `Identity.deactivate_tenant/1` (status `:inactive`) | `suspended` |
| `resume` (only from suspended) | `Identity.reactivate_tenant/1` | `active` |
| `expire` (demo ended) | the same deactivation, lifecycle `expired`; data kept | `expired` |
| `DELETE` | step 1 deactivate (and stop the realm provider); step 2 purge the tenant's schema by policy; the provisioner's reaper then deletes the realm | `suspended`, then `deleted` after purge |
| demo to production | `tenant_type` change on the tenant (existing `PATCH /tenants/:slug`, platform operator, audited); no realm move; the realm already comes from the hardened template | n/a |

**Fixed order, never reversed** (Letflow operator, 2026-10-25): (1) deactivate the tenant in Letflow, (2) purge its data per the retention policy, (3) only then
the realm is deleted. Reason: login discovery (`Letflow.LoginDirectory.lookup_by_keys/1`, decision 0042) sends people to every `:active` tenant with a bound realm, and Letflow runs one key-fetching
OIDC worker per realm. The reverse order leaves an active tenant bound to a missing realm.

**What the oidcc worker does on a 404 (found, merged in #3270).** The worker keeps its last JWKS and, when the refresh gets 404, only retries with a random 1 to
30 s backoff forever and never stops. So a deleted realm's cached keys would keep verifying tokens until the node restarts. Deactivation therefore stops the realm's
provider: `Letflow.Oidc.ProviderRegistry.stop/1` (merged 2026-10-25 in `279ecdb1b`, "a deactivated tenant stops its realm provider"; `ensure_started/1` refuses a realm
of an `:inactive` tenant and `GET /api/tenant-config` answers the default config for it). **So the small change this record asked for already exists; two gaps remain for the implementer:**
* the stop is called from the private `stop_realm_provider/1` of `Letflow.Routers.Tenants`, **not** from `Identity.deactivate_tenant/1`. The `/admin/v1` suspend, expire and delete routes and the
  scheduled sweep must reach the same call. Preferred: move the call into one function that all four callers use (a context function, not a router private), with a test per caller;
* `Registry.lookup` is node-local. With more than one node the stop reaches only the node that handled the request. The QA deployment runs one node; the PR states that, and a multi-node
  deployment needs a cluster-wide stop (not designed here).

The purge itself (drop the tenant schema and its `tenant_schemas` registration, keep the `tenants` row `:inactive` with `idp_realm_id` unchanged, lifecycle `deleted`), the demo cap check, the
sweep, and "purge acts only on tenants with a `tenant_lifecycles` row" are as specified in REQ-572 criteria 18 to 21 and are not repeated here. DELETE answers 202 while inside retention and 200 only
after the purge. The realm deletion itself is infra's reaper; Letflow's `deleted` status means "schema gone and the realm may be deleted", and Letflow does not call Keycloak to do it.

## 6. D5. Two findings that change the contract

Found by a read-only study of the code on 2026-10-25 and re-checked against `origin/main`.

### (a) `tenant_id` cannot be stored today; there is no idempotency for tenant creation

Facts. `Tenant.create_changeset/3` (`lib/letflow/identity/tenant.ex`) casts only `[:slug, :display_name, :status, :idp_realm_id, :tenant_type]`; the primary key is `@primary_key {:id, :binary_id, autogenerate: true}`, so
the id cannot be supplied. `Letflow.Routers.Onboarding` documents that it deliberately does not read `Idempotency-Key`; a repeated slug or hostname answers 409 and "is NOT a replay of the original 201".
The contract (rule 3) requires "idempotent by `tenant_id`, a repeated call returns the same result and changes nothing".

**Decided: the front door's `tenant_id` becomes `tenants.id`**, set by a provisioning-only changeset (no existing changeset starts casting `:id`; `PATCH /tenants/:slug` and `POST /tenants` keep
refusing it). The slug is derived deterministically: `t-` plus the 32 lowercase hex digits of the id (its first 20 hex digits are the provisioner's realm name, so the two derivations agree by
construction and the front door can trace one from the other). **No new unique external-id column is needed**: the primary key is the unique key, which gives the replay path for free and a race-free
guarantee from the database (two concurrent POSTs with one `tenant_id`: one insert wins, the other reads the row and answers 200). This is simpler than the alternative named in the task
(slug plus a new external-id column) and the two are equivalent for the front door; the primary key is chosen because a second unique column would have to be kept equal to the id forever.
The replay rule is REQ-572 criterion 6: a repeat with an existing `tenant_id` answers 200 with the same body whatever the other fields say, changes no row, and writes no second grant or audit entry;
while the grant (or the realm bind of D3) is not yet stored, the repeat completes it, then answers 200. A derived slug taken by a tenant with another id answers 409 `conflict`.
Only tenants with a `tenant_lifecycles` row are visible to `/admin/v1`; a tenant made by another route has none and answers 404, byte-identical to an unknown id (INV-5).

Corrections owed to REQ-572 (a BA amendment, not made in this documents-only task): criterion 15 and its drift test path become `priv/keycloak/provisioner/v1/`; criterion 16 says the realm id is the
`tenant_id`, which is wrong: the realm name is the provisioner's `t-<first 20 hex>` and Letflow binds what the provisioner returned (D2, D3); description item (7) and criterion 4 ("`idp_realm_id` NULL") hold
only when no `idp_realm_id` is sent.

Amendment of 0048 section 1 item 3, recorded here as REQ-572 open question 8 requires: a pending grant may also be created by a second path, `create_provisioned/2`, with `created_via = 'provisioning'`
(the CHECK of `20261008000001_create_pending_tenant_admin_grants.exs` widened to `('onboarding','provisioning')`, additive), a nil actor in both audit chains, details `created_via: 'provisioner'`, and the creator
class of the bind and revoke entries taken from the grant row. `create/3` is unchanged and stays the only onboarding path. The grant still names `TENANT_ADMIN` only and still binds only on a verified matching
e-mail (0046 D4 and D5 and 0048 section 3 unchanged). What 0048 section 3 argued for the operator holds for the provisioner: it confers nothing on itself, has no add or replace route, and the person must
sign in through the tenant's own realm.

### (b) The create route takes `hostname` (decided by the portfolio, 2026-10-25)

Facts. `POST /api/v1/onboarding` requires `slug`, `display_name` and `hostname`; the hostname is unique and is what `GET /onboarding?hostname=` resolves. The front door decides the hostname and sends it:
`<slug>.<demo domain>` for demos, the customer's agreed name for production; infra provides DNS and the certificate; **for QA a subdomain of the QA domain**; the production demo domain is the owner's choice and **is
not decided and is not assumed here** (portfolio O-15). Qoimeks has one shared origin and ignores the field.

**Decided.** `POST /admin/v1/tenants` takes `hostname` (required for Letflow) and validates it before any write, answering 400 `invalid_request` naming the field and not echoing the value:
* *format*: trimmed, lower-case, at most 253 characters in total, labels of letters, digits and hyphen (no leading or trailing hyphen, 1 to 63 characters each), no port, no scheme, no path, no underscore, no trailing dot, no IP literal;
* *allowed suffix*: the hostname must be exactly one label followed by a dot and one of the configured suffixes. The suffixes are a **setting**, `LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES` (comma separated, read in `config/runtime.exs`; on QA the QA domain). When it is unset or empty every hostname is refused: no suffix is built into the code, so the production demo domain is purely configuration and no domain is assumed;
* *uniqueness*: the hostname must not already belong to another tenant (the same unique constraint as onboarding), otherwise 409 `conflict`. A repeat with the same `tenant_id` and the same stored hostname is the replay of D5(a), not a conflict; a different hostname on a repeat is ignored like any other body field.

The hostname is stored through the same registry write as onboarding, so `GET /onboarding?hostname=` and host-based tenant resolution work unchanged. The provisioner's own suffix check (QA: `.qa.bizdala.com`)
is a second, independent guard, not a substitute.

## 7. D6. The narrow credential in Letflow

Facts. Today only a PLATFORM_ADMIN token of the platform tenant can create a tenant or deactivate and reactivate one (`:TenantsManage`, `endpoint_policy_key/2` clauses for `POST /tenants`,
`POST /onboarding`, `POST /tenants/:slug/deactivate` in `lib/letflow/api/authorization.ex`). PLATFORM_ADMIN can read and administer every tenant's configuration, so it is far too strong for a front door.

**Option A: a `TENANT_PROVISIONER` role.** Feasible but not small. It touches `@roles` and the `role()` type, new permission atoms, `@platform_permissions`, a `core_role_allows?/2` clause, `endpoint_policy_key/2`, both routers (`Tenants`,
`Onboarding`), `docs/roles.md` and its tests, `@issuable_token_roles` and `validate_issuable_roles/1` in `identity.ex`, and the minting rules of 0051 M2 (a token's roles must be a subset of the minter's; a PLATFORM_ADMIN token is
self-minted and expires within `:platform_admin_token_max_ttl_days`). It also needs an OIDC identity for a machine (a platform-realm service account, a user row in the platform tenant, a token that has to be minted by someone and rotated), and it
collides with about 15 pinned spots (the permission-matrix golden, the tenant-auditor refused set, the role-count number words in `authorization_test.exs`, route-scope snapshots).

**Option B (decided): a provisioner credential outside the role system, as REQ-572 already specifies.** The `/admin/v1` routes are mounted in `lib/letflow/router.ex` **outside** `/api/v1` and its `ApiPipeline`, behind one new plug that accepts only the
provisioner credential: one opaque bearer value, configured as `LETFLOW_PROVISIONER_CREDENTIAL_SHA256` (the lowercase hex SHA-256 of the value, so Letflow never holds the usable secret, INV-4), compared in constant time; unset or blank means every
`/admin/v1` path answers 404 identical to an unmatched path (contract rule 6). A provisioner request builds no `auth_context`, holds no role and no `Authorization.evaluate_access/2` permission. Name used in docs and audit details: "the provisioner".
Reasons: (1) it fails closed by construction: there is no path from the credential into any route that checks roles, so INV-10 has nothing to prove, whereas a new platform role must be proven refused by every tenant route
and by every platform route it should not reach; (2) it is platform-scope by being bound to no tenant at all, a stricter form of "usable only in the platform tenant", since there is no tenant for it to be used in; (3) no new identity, token, user row or Keycloak
account; (4) no change to 0051 M2 or to the issuable-token set, so the minting rules and the 15 pins stay as they are; (5) it is already the shape of the merged requirement text. **Cost:** a small hand-written authentication surface (the plug, the rate limiter,
the constant-time compare) and rotation limited to one hash (REQ-572 open question 4; the owner approved "runbook first, a calendar interval after the first rotation works", D-019 item 2).

**This record therefore decides that the "TENANT_PROVISIONER" in the task text is a credential class, not an entry in `@roles`.** If the design gate or the SECURITY-REVIEWER prefers Option A, the invariants below apply unchanged to it, plus: the role is platform scope only
(`@permission_scope` `:platform`), never in the tenant role set, never issuable in a tenant token, never a group-binding target, honoured only when the token's tenant is the platform tenant (0046 D4), and not mintable by anyone but a PLATFORM_ADMIN (0051 M2).

**Invariants (each needs the named negative test; REQ-572 criteria 2, 3, 11, 13 already hold most of them, the rest are added by the implementer).**

| # | Invariant | Negative test |
|---|---|---|
| P1 | Off when unconfigured (404 identical to an unmatched path) | each of the six routes with the variable unset and with a header |
| P2 | Only the exact credential is accepted; constant-time compare; the 401 body does not differ for a missing and a wrong value (INV-4, INV-8) | no header, malformed header, wrong value, a valid PLATFORM_ADMIN OIDC token (must be 401) |
| P3 | The credential reaches nothing outside `/admin/v1` (INV-10) | the credential sent to one route of every router mounted in `api_pipeline.ex` and to `/api/v1/onboarding`, `/api/v1/tenants`, `/api/v1/identity/*`: never 200 |
| P4 | No `/admin/v1` route reads or returns tenant data, a user, a token, an e-mail address, a slug or a realm in a response (INV-1, INV-2, INV-6); responses are key allowlists | two provisioned tenants A and B: suspend and expire of A change nothing of B and no response for A contains a value stored for B (the INV-10 cross-tenant test: the routes take a tenant id) |
| P5 | The credential cannot create, list or revoke a credential or API token, cannot list tenants, cannot mint or grant any role other than the one `TENANT_ADMIN` pending grant of the first administrator | route inventory test: no such route exists under `/admin/v1` |
| P6 | Only tenants with a `tenant_lifecycles` row are visible, suspended, expired or purged; the platform tenant, a production tenant not provisioned this way and a tenant made by `POST /tenants` answer 404 (INV-5) and are untouched by the sweep | counted before and after, byte-identical 404 bodies |
| P7 | No `PLATFORM_ADMIN` is created in a customer tenant by any provisioning step, and none exists in the template realm (0046 D4) | scan of the realm request builder's output and of the template |
| P8 | The only writes under a tenant prefix are the schema provisioning and the one pending-grant insert, under a prefix derived from the new tenant's id, never from a request value (INV-1, INV-6, INV-7) | source and behaviour test of the prefix derivation |
| P9 | `hostname` is validated before any write; only a configured suffix is accepted (INV-9: the value later feeds redirect URIs and host-based resolution) | tests in D5(b): bad format, unallowed suffix, suffix unset, duplicate |
| P10 | Rate limit per credential (60 requests per 60 s default), 429 with `Retry-After`; a request with a bad credential does not consume the budget | injected clock |
| P11 | No secret in logs, responses, errors, audit or git: only the hash is configured; the request builder output and the template carry no password, key or SMTP secret (INV-4) | scan tests |
| P12 | A failed step answers 500 `internal_error` with no stack, SQL or e-mail (INV-8); an audit write failure is rescued and answers 500 | injected failure |

A tier `production` request creates `tenant_type = production`; REQ-469 lets only a PLATFORM_ADMIN set it. This record **does not settle** that (REQ-572 open question 6): the first build may refuse `tier: production`
on `/admin/v1` (400 `invalid_request`) until the SECURITY-REVIEWER rules, because QA only needs demos. If production is allowed later, demo to production remains the audited platform-operator `PATCH` of D4.

## 8. D7. Settings (not rules), starting values

All are configuration read in `config/runtime.exs` from the environment, with these defaults, changeable without a code change (D-019 items 4 and 5; REQ-572 criterion 19 requires a test that changes each):

| Setting | Starting value | Meaning |
|---|---|---|
| demo cap | 30 | `tenant_lifecycles` rows with tier demo and lifecycle not deleted; a create beyond it answers 409 `conflict` (`demo_cap_reached`) |
| alarm threshold | 25 | a warning-level log line with the count and the cap, no tenant data |
| demo lifetime | 14 days | after creation; sets `expires_at` when the request gives none; the sweep expires the demo |
| retention | 30 more days | counted from expiry or from the deletion request, then purge (and the reaper deletes the realm) |
| sweep interval | a setting | how often the scheduled sweep runs (expire, then purge) |
| allowed hostname suffixes | none (empty refuses all) | D5(b) |

The numbers are the owner's blast-radius choice and are explicitly **starting values**: nothing in code or tests may assume 30, 25, 14 or 30 except as the defaults. The provisioner has its own demo cap and capacity errors
(`demo_cap_reached`, `total_cap_reached`); the two caps are independent and the lower one wins.

## 9. Consequences and what to build, in order

1. This record, reviewed by the design gate and the SECURITY-REVIEWER (the credential and the grant path are security-relevant).
2. A BA amendment of REQ-572 for the corrections of D5(a) (template path, realm name, `idp_realm_id`, `hostname`), and the contract text in the portfolio (`idp_realm_id` in the create request).
3. The template at `priv/keycloak/provisioner/v1/` with the drift test, and the pure request-builder function (REQ-572 criteria 15 and 16).
4. The routes, the credential plug, `tenant_lifecycles`, the grant path, hostname validation, then the sweep and purge (REQ-572 criteria 1 to 14, 17 to 21), with the single provider-stop call of D4 reached by every deactivating caller.
A route add moves the route-count pins and the `forward(...)` pins; the implementer greps `__authz_routes__` and the route-scope snapshots, and a new tenant-level table (none here: `tenant_lifecycles` is global, like `tenants`) would move the tenant table-list pin.

## 10. Out of scope, still the owner's

Production Keycloak and any production tenant (not approved, D-019 item 3); `manage-users` for a production tenant's first administrator (Letflow has no admin client to add logins; decided later); abuse limits beyond the per-credential
limit above (the per-visitor limit belongs to the front door); who sends the welcome e-mail (the front door or Letflow, **never Keycloak**, whose welcome mail needs `manage-users`) and how the first administrator receives `initial_password`;
the production demo domain (not decided, not assumed); credential rotation interval (runbook first); a data erasure on a person's request that needs a path other than the tenant purge; SSO and brokering (own ADR, later).

## 11. Not tested, stated plainly

From the portfolio's sandbox: the optimized Keycloak `start` boot; `requiredActions` on the inline user; long-run behaviour on the real QA Keycloak; the realm's SMTP password is probably stored unencrypted in Keycloak's database (the vault SPI could keep it out; a QA-only residual). This record
is a design decision, not a verification: no code was run for it.

## Sign-off

REVIEWER: pending (design gate). SECURITY-REVIEWER: pending.
