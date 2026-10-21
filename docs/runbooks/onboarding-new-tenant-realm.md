# Runbook: giving a newly onboarded tenant a realm and a first administrator

ISS-1030 / Q-1012 / GH #2312. Design: `lib/letflow/design/iss1030-onboarding-administrator.md`
(sections 3 and 9; PR 2: sections 4, 5 and 7).

A tenant created through the onboarding wizard or `POST /api/v1/onboarding` is **not yet
loginable** until an identity-provider realm is bound to it: a login reaches a tenant only through
the realm named in the token, and a tenant with no `idp_realm_id` cannot be reached by any token.
The onboarding response says so (`login.status` is `not_yet_loginable`, with `login.next_steps`),
and it says what became of the administrator typed into the wizard (`administrator.state`:
`pending` when an `admin_email` was stored as a pending `TENANT_ADMIN`, `none` when no administrator
was named, `not_stored` when the e-mail could not be stored; `administrator.not_provisioned` lists
the other fields, which are never used). Nothing in Letflow creates a realm or a realm user today;
this runbook is the manual procedure.

Fill the Owner, Evidence and Date columns when an item is done. Evidence is a reference (ticket,
PR, document, inventory entry), never a secret value. Names only: no passwords, tokens or secret
values belong in this file or in any evidence field.

## References

- Infra tasks T-0150 (the realm and persona-account recipe) and T-0158.
- Decision 0044 (realm-per-tenant, Phase 1) and decision 0046 D4/D5 (`PLATFORM_ADMIN` has no
  power inside a customer tenant; `TENANT_ADMIN` is the tenant's owner role).
- `lib/letflow/design/req447-infra-realm-mapping.md`, sections 1 and 3b (every new realm must
  issue `TENANT_ADMIN`).

## Ordered steps

1. **R1 Create the realm.** Clone the `bpm-default` realm definition
   (`priv/keycloak/realms/bpm-default.json`: the `letflow-web` client with its audience mapper and
   the `realm-roles` mapper), including the realm role `TENANT_ADMIN`. Set the `letflow-web` client's valid
   redirect URIs for this tenant's hostname by hand. The wizard no longer collects `client_config`,
   `realm_config` or redirect URIs (GH 2463); it shows one line saying the realm and client are created by infra.
2. **R2 Create the first administrator.** Create the user with the e-mail set and the e-mail
   marked VERIFIED (Letflow binds a pending administrator only on `email_verified=true`; without
   that claim in the token no grant can bind). When the onboarding response said
   `administrator.state = "pending"` for that exact e-mail, the realm role mapping is optional: the
   grant makes the person `TENANT_ADMIN` at their first sign-in (see "Pending administrator" below).
   Otherwise map the realm role `TENANT_ADMIN` to that user.
3. **R3 Bind the realm.** Either give `idp_realm_id` when onboarding (the realm must already
   exist), or bind it afterwards with `POST /api/v1/onboarding/{id}/bind-realm` and the body
   `{"idp_realm_id": "<realm>"}` (operator, `TenantsManage`). The realm id is 1 to 64 letters,
   digits, `_` or `-`, starting with a letter or digit; `master` is refused. The server checks
   that the realm exists on the configured Keycloak before binding. **The binding is permanent:**
   it can be set only while the tenant has no realm, and only for an `active` tenant (a
   `migrating` or deactivated tenant answers 409). It cannot be changed or cleared afterwards, so
   confirm the realm belongs to this customer before you bind it (checklist item "realm ownership
   confirmed by").

   **Activation is automatic.** The onboarding call provisions the tenant schema and then flips
   the tenant from `migrating` to `active` (`Letflow.TenantOnboarding.provision_and_migrate/1`).
   You do not activate the tenant by hand. If it is still `migrating`, see "If the tenant stays
   migrating" below.
4. **R4 First sign-in.** The administrator signs in once. Verify `GET /api/v1/me` shows
   `TENANT_ADMIN` (role names only). Re-read `GET /api/v1/onboarding/{id}`: `login.status` is
   `realm_bound`.
5. **R5 Confirm a pending grant was used.** When a pending administrator was named, read
   `GET /api/v1/onboarding/{id}/pending-admins`: the grant's `state` is `bound` (and `email` is null).
   A grant still `open` with a growing `age_seconds` means the person has not signed in yet, or the
   bind did not happen (see "Pending administrator").

## Pending administrator (ISS-1030 PR 2)

`POST /api/v1/onboarding` accepts an optional `admin_email`. It is validated before the tenant is
created (a malformed or non-ASCII address is a 422 that never echoes the value; an internationalised
address must be given in its punycode `xn--` form) and stored, trimmed and lower-cased, as ONE
pending `TENANT_ADMIN` grant in the new tenant's schema. Only the e-mail is used:
`admin_username` and `admin_display_name` are echoed as not provisioned and never acted on.

The grant becomes active when the person first signs in through THIS tenant's realm with a token
whose `email` equals the stored address and whose `email_verified` is `true`. `preferred_username` is
never consulted. It binds exactly once; the bound user gets the `TENANT_ADMIN` group membership and
nothing else. The tenant must have a bound realm first (R3). A login that does not bind behaves
identically with or without a pending grant.

**List (operator).** `GET /api/v1/onboarding/{id}/pending-admins` returns each grant with `state`
(`open`, `bound`, `revoked`), `age_seconds` (open grants only), `created_by_user_id` (read from the
platform audit chain) and, for bound grants, `bound_user_id`. There is no TTL: an unused grant stays
valid until it is bound or revoked, so check the AGE of open grants.

**Revoke (operator).** `DELETE /api/v1/onboarding/{id}/pending-admins/{grant_id}` withdraws an OPEN
grant (204) and scrubs its e-mail. A bound grant answers 409 `grant is not open`; to remove a bound
administrator use the tenant's own `DELETE /api/v1/identity/groups/{id}/members/{user_id}`. To correct
a wrong `admin_email`: revoke the grant, then use the realm-role path (map `TENANT_ADMIN` to the
intended user in the realm). There is no replace route.

**Tenant view.** The tenant's own administrator can READ the pending grants of its tenant with
`GET /api/v1/identity/pending-admin-grants` (no creator or operator id is shown).

**If a grant stays open although the person signed in** (state `open`, `age_seconds` growing):
the bind is fail-closed and silent. Check, in order: the realm is the one bound to the tenant; the
token carries `email_verified=true` (the `email_verified` mapper is in the `letflow-web` client
scope); the address in the token equals the stored one; no OTHER user of the tenant already holds
that address (a user who registered with the address first permanently blocks the automatic bind;
the remedy is the realm-role path); the person had no synced role claims at their first login. A
server-side fault logs one warning per tenant per hour (fixed text, tenant id only).

**The unverified-e-mail setting.** `LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` is an optional,
comma-separated list of realm names whose e-mail claim may bind a grant WITHOUT `email_verified=true`
(for a realm that cannot supply the flag). Default: unset, which means OFF for every realm. It is
set only in the server environment (restart to change); there is no API, tenant setting or request
field for it. Keep it empty for every realm with self-registration: anyone could register the
pending address and take the grant. A malformed name stops boot without echoing the value.

## If the tenant stays migrating

Provisioning runs before the onboarding record is written. If it fails, `POST /api/v1/onboarding`
answers 500 and the tenant for that slug stays `migrating` with no onboarding record, so there is no
onboarding id to bind against.

1. **Do not bind or edit the tenant row by hand.** A `migrating` tenant has a half-provisioned
   schema, and a hand-written status change would make it look ready when it is not.
2. **Recover provisioning.** An engineer runs `Letflow.TenantOnboarding.recover_provisioning/1`
   with the tenant id from a release console. There is no HTTP route for it. The call is
   idempotent: it re-runs the same provisioning steps and flips the tenant to `active` only on
   success.
3. **Bind again.** Once the tenant is `active` and an onboarding record exists, run R3 unchanged.
4. **If recovery fails, stop and escalate** to the platform owner with the slug, the time of the
   call and the error. Do not retry by changing the database.

If the onboarding call carried an `idp_realm_id` and provisioning failed, the realm is **not** bound:
the realm is bound only after provisioning and the onboarding record succeed. The realm therefore
stays free, and after recovery you bind it with step R3.

If the create call answers 409 `hostname already bound`, no tenant was created: the hostname is checked
before any write. Retry with a free hostname.

A 409 whose detail reads "hostname taken during the request; the tenant for this slug was created" means
the tenant **does** exist, and it may be `active` or still `migrating`: a hostname was taken in the instant between that check and the
insert. A retry with the **same** slug only confirms it: the answer is 409 "slug already exists" and
nothing is created. Do not retry with a new slug, which creates a second tenant. Escalate to the
platform owner. Nobody binds a realm by hand.

A 500 whose detail reads "an unexpected error occurred after the tenant for this slug was created", or a
422 "onboarding record rejected after the tenant was created", from `POST /api/v1/onboarding` means the
tenant for that slug **may** exist: `migrating` (provisioning failed) or `active` with no onboarding record
and no realm. Do not retry with a new slug. Escalate to the platform owner with the slug and the time of
the call.

If the create call answers **201** with `realm_request.status = "not_bound"` (the realm was claimed by
another tenant in a race, `reason = "taken"`, or the bind outcome is unknown, `reason =
"unavailable"`), the tenant exists (`active`, or still `migrating` if activation did not complete) and the
onboarding record exists (the body's `id`). The response
says `login.loginable` is `false`. For `reason = "unavailable"` the realm may in fact be bound (an error or an exit
around the commit leaves the outcome unknown): retry the bind with the same realm id first. The retry is safe: it
binds the same realm once and answers 200 with no second audit entry. A 200 means it is bound;
a 409 means another tenant or a different realm holds it, or the tenant is no longer `active`. Then retry the bind with
`POST /api/v1/onboarding/{id}/bind-realm` using the body's `id`. If `taken`, choose another realm
first. If the bind fails again, escalate to the platform owner; do not bind by hand.

## Realm checklist

One row per item; evidence is a reference, never a value.

| Item | Owner | Evidence | Date |
|------|-------|----------|------|
| `TENANT_ADMIN` exists as a plain realm role and is NOT in `default-roles-<realm>`, any default group, any client-scope role mapping or any composite | | | |
| "Duplicate emails" is OFF | | | |
| Self-registration is OFF | | | |
| No brokered identity provider with "Trust Email" | | | |
| The first user's e-mail is verified (`email_verified=true` in the token; required for a pending grant to bind) | | | |
| Pending administrator: the onboarding response said `pending`, or the first user carries the realm role `TENANT_ADMIN` | | | |
| `LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` does not name this realm (unless the realm has no self-registration and cannot supply `email_verified`) | | | |
| "Verify email" is ON in the realm | | | |
| Users cannot edit their own e-mail, or `email_verified` is reset whenever the e-mail changes (the realm's profile and "Update email" settings reviewed) | | | |
| The `email` and `email_verified` mappers are present in the `letflow-web` client scope | | | |
| The realm never issues `PLATFORM_ADMIN` | | | |
| Realm ownership confirmed by (named person at the operator who confirmed this realm belongs to this customer's tenant, and the date) | | | |

## The one line for the infra onboarding checklist

> Every new tenant realm: clone from bpm-default including the TENANT_ADMIN realm role; create
> the first user with a VERIFIED e-mail (email_verified=true in the token; the TENANT_ADMIN role
> is optional when the onboarding response says the administrator is pending for that exact
> e-mail); never map TENANT_ADMIN to default roles or groups; Duplicate emails OFF. A pending
> administrator that is not wanted is revoked with DELETE
> /api/v1/onboarding/{id}/pending-admins/{grant_id}.

This repository does not edit the infra repository; ORCH copies the line into
`ai-dala-infra`'s onboarding checklist as a task.

## What the wizard fields do and do not do

- `admin_email` is validated and, when valid, stored as a pending `TENANT_ADMIN` grant (see
  "Pending administrator"). `admin_username` and `admin_display_name` are **echoed, not stored and
  not acted on**. Nothing creates a realm user from any of them.
- `client_config` and `realm_config` are **ignored by name**: the wizard no longer sends them (REQ-468), and
  the API treats them like any other undeclared body key. They are listed in `ignored_fields` and nothing
  else is answered for them; their values (including any `redirect_uris` inside `client_config`) are not
  read, stored or echoed. The tenant's client and realm are set up by hand, as described above.
  Any other unknown body key is listed by name in `ignored_fields` only; its value is not read.
- A blank or null administrator field counts as not sent.
- **Resubmitting is not a replay.** The wizard sends no `Idempotency-Key` and the API reads none (ISS-1091).
  If the same slug or hostname is submitted again, the answer is 409 with the specific reason (for example
  "slug already exists") and nothing is created twice. If the first answer was lost, look the tenant up
  (`GET /api/v1/onboarding?hostname=...`) instead of retrying the create.

## Tenant type (REQ-469)

Every tenant has a `tenant_type`, `test` or `production`. A tenant created through onboarding is `test`, and so is every
tenant that existed before the column was added. After onboarding a real production tenant, a platform administrator
sets it with `PATCH /tenants/:slug` and `{"tenant_type": "production"}`; only a `PLATFORM_ADMIN` of the platform tenant
may change it, and each change is audited. The promotion classifier refuses a `production` tenant as a promotion source.
