# 0048 -- Pending tenant-administrator grant: first-login binding rules, bind-once realm, and consistency with 0046

Status: ACCEPTED (REVIEWER sign-off 2026-10-13, see "Sign-off").
Interim note: letflow-fc's open question Q7 on the ISS-1030 design was never answered; the design's default
stands as an INTERIM decision, pending fc review. Nothing here should be read as fc-ratified until then.
Decisions below were fixed by the BA's binding answers to ISS-1030 / Q-1012 / GH #2312
(letflow-9a, 2026-10-07) and the design `lib/letflow/design/iss1030-onboarding-administrator.md`
(OQ-13). This record writes them down; it does not re-decide them.

Date: 2026-10-13. Written by `ELIXIR-DEV` with the PR 2 implementation. Owner: `ORCH`.

Amends, by reference only: `0006-identity-tables-schema-per-tenant.md` R5 (narrow exception, section
2 below). Consistent with, and does not change: `0043-email-first-login-ba-decisions.md`,
`0044-hybrid-identity-model.md` (realm-per-tenant, Phase 1; brokering deferred) and
`0046-admin-scopes-and-role-charter.md` (D4, D5, D8).

## Context

`POST /onboarding` collected an administrator and dropped it: nothing created the person, nothing
granted a role, and a tenant with no `idp_realm_id` could not be reached by any token. PR 1
(ISS-1030) stopped the silent drop and added a bind-once route for the realm. PR 2 lets the operator
name the first administrator by e-mail address at onboarding time, so that the person becomes the
tenant's `TENANT_ADMIN` the first time they sign in through the tenant's own realm.

## 1. The binding rules (design section 7)

1. **Storage.** A new table `pending_tenant_admin_grants` in the tenant's own schema (not a column
   on `tenants`). The table pins `role_name = 'TENANT_ADMIN'` and `created_via = 'onboarding'` with
   CHECK constraints: the grant is `TENANT_ADMIN` only, enforced by the database.
2. **Key.** The e-mail address, normalised by trim + lower-case ONLY (no plus-tag or dot folding),
   ASCII only (an internationalised address is given in punycode), at most 254 characters, unique
   per tenant. The address is held only while the grant is open and is scrubbed to NULL when the
   grant is bound or revoked.
3. **Creation.** ONLY by the onboarding call (`POST /onboarding` with `admin_email`), v1. There is no
   create, update or replace route for a grant anywhere. `admin_email` is optional; when absent the
   response says plainly that the tenant has no administrator and names the runbook.
4. **Binding.** At a user's first login (the OIDC auth pipeline, between JIT provisioning and the
   per-request role read) a grant binds only when ALL hold: the token is signed by the tenant's own
   realm; the e-mail claim is non-blank ASCII and equals the stored key after trim + lower-case; the
   claim `email_verified` is the JSON boolean `true`; the address stored on the user row at JIT time
   equals the claim address; no other user of the tenant holds the same address; the user is active
   and has no synced role claims (or was just created). `preferred_username` and `display_name` are
   never read.
5. **Per-realm setting.** For a realm that cannot supply `email_verified`, an operator-set setting
   (`LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS`, read at boot) lets the e-mail bind without the
   verified flag. Default OFF. Server-side only: no database column, API, tenant setting, claim or
   request field can set it.
6. **Exactly once, atomically.** One transaction locks the grant row, writes the membership in the
   `TENANT_ADMIN` group (the only membership written), marks the grant consumed (the update must change
   exactly one row), stamps the user's role-claims marker, and writes BOTH audit entries. A failure
   of any step is a silent no-op: the request continues as if no grant existed, status, body and
   headers unchanged, and the next login retries. A bind never raises and never fails a request.
7. **No TTL.** Compensated by visibility, not expiry: the operator lists grants with their AGE and
   can revoke an open one; the tenant's own administrator can READ its tenant's grants (not create or
   revoke them).
8. **Audit split.** The tenant audit chain is readable by the tenant's `:AuditRead` holders, so no
   entry written to it names a platform operator: created and revoked entries carry a NIL actor.
   The operator's user id is written only to the platform tenant's own chain, in the same
   transaction, referencing the same grant id. Lock order everywhere: grant row, user row (locked before the membership insert), membership,
   tenant chain, platform chain (always last). No entry in either chain, and no log line, ever
   contains an e-mail address.

## 2. Narrow exception to decision 0006 R5 ("`idp_realm_id` immutable after creation")

`idp_realm_id` may be set ONCE, from NULL, through the bind-once route of PR 1
(`POST /onboarding/:id/bind-realm`, or the `idp_realm_id` field of the onboarding call, which uses
the same audited path after provisioning). It is never changed and never cleared. Only the platform
operator (`:TenantsManage`, platform scope) can do it, only while the tenant is `active`, under a
row lock, with a unique-index conflict answered 409 without naming the other tenant. The only
changeset that casts `idp_realm_id` on an existing row is `Tenant.realm_bind_changeset/2`. Every
other rule of R5 (the realm-to-tenant-to-schema chain is a 1:1 bijection) is unchanged.

## 3. Why a bootstrap grant is consistent with 0046

0046 D4 gives `PLATFORM_ADMIN` no power inside a customer tenant, and D5 makes `TENANT_ADMIN` the
tenant's own owner role. A bootstrap grant is not "the operator adding administrators inside a
customer tenant":

* The operator holds and exercises no tenant power. It writes one pending record, for one person it
  names at the moment the tenant is created, and confers nothing on itself.
* The operator has no route to add, change or replace an administrator afterwards. The revoke route
  exists only to withdraw an unused grant; removing a bound administrator is the tenant's own
  `DELETE /groups/:id/members/:user_id`.
* The grant takes effect only through that person's own verified login in the tenant's own realm,
  where `TENANT_ADMIN` is conferred by the tenant's own data (a membership in the tenant's own
  group), exactly as for any other `TENANT_ADMIN`.
* The grant can only ever name `TENANT_ADMIN`, never `PLATFORM_ADMIN` (database CHECK, plus the
  existing REQ-447 escalation guards unchanged).

It does not contradict 0043 (e-mail-first login discovery is a separate, pre-login mechanism and is
not touched), 0044 (the realm remains the tenant's identity boundary; brokering stays deferred, and
the runbook forbids a brokered provider with "Trust Email" in a tenant realm) or 0046 D8 (the
migration of existing administrators is unchanged).

## Known residuals (accepted, in the runbook)

* A user who registered with the intended administrator's address BEFORE the intended person, in a
  realm without duplicate-e-mail protection, permanently blocks the automatic bind (fail closed). The
  signal is the grant staying open with a growing AGE; the remedy is the realm role path.
* The unverified-e-mail setting is safe only for a realm whose users are created by an
  administrator; the runbook forbids it for realms with self-registration.
* A typo that names a stranger who holds an account in the realm is bounded by closed registration,
  the operator list with AGE, the tenant's own read route and revoke.

## Sign-off

REVIEWER: 2026-10-13 PASS. Checked against 0006 R5 (the narrow bind-once exception of section 2 matches
`Tenant.realm_bind_changeset/2` and `Identity.bind_tenant_realm/3`; the 1:1 realm-tenant bijection of
R5 is unchanged), 0043 (e-mail-first discovery untouched), 0044 (realm-per-tenant, Phase 1, brokering
still deferred; the runbook forbids a brokered "Trust Email" provider), 0046 D4/D5/D8 (the grant names
`TENANT_ADMIN` only, by CHECK; the operator confers nothing on itself and has no add/replace route) and
0004 (no human gate introduced). The lock order in section 1.8 matches the code in
`PendingAdminGrants.transact_bind/7`. Non-blocking follow-up: 0006 R5 itself carries no pointer to this
record and still reads "immutable"; add a one-line "narrowed by 0048 section 2" note there.

Second creation path (REQ-572, 0072 D5(a)): `PendingAdminGrants.create_provisioned/2` stores a grant with `created_via 'provisioning'` for a tenant made by the provisioner credential; it has exactly one caller, `Letflow.TenantProvisioner`. Everything above (TENANT_ADMIN only, by CHECK; no add or replace route) still holds.
