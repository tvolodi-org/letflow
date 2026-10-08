# Runbook: giving a newly onboarded tenant a realm and a first administrator

ISS-1030 / Q-1012 / GH #2312. Design: `lib/letflow/design/iss1030-onboarding-administrator.md`
(sections 3 and 9).

A tenant created through the onboarding wizard or `POST /api/v1/onboarding` is **not yet
loginable** until an identity-provider realm is bound to it: a login reaches a tenant only through
the realm named in the token, and a tenant with no `idp_realm_id` cannot be reached by any token.
The onboarding response says so (`login.status` is `not_yet_loginable`, with `login.next_steps`),
and it says plainly that the administrator details typed into the wizard were **not used**
(`administrator.state`, `administrator.not_provisioned`). Nothing in Letflow creates a realm or a
realm user today; this runbook is the manual procedure.

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
   the `realm-roles` mapper), including the realm role `TENANT_ADMIN`.
2. **R2 Create the first administrator.** Create the user with the e-mail set and the e-mail
   marked verified, and map the realm role `TENANT_ADMIN` to that user.
3. **R3 Bind the realm.** Either give `idp_realm_id` when onboarding (the realm must already
   exist), or bind it afterwards with `POST /api/v1/onboarding/{id}/bind-realm` and the body
   `{"idp_realm_id": "<realm>"}` (operator, `TenantsManage`). The realm id is 1 to 64 letters,
   digits, `_` or `-`, starting with a letter or digit; `master` is refused. The server checks
   that the realm exists on the configured Keycloak before binding. **The binding is permanent:**
   it can be set only while the tenant has no realm, and only for an `active` tenant (a
   `migrating` or deactivated tenant answers 409). It cannot be changed or cleared afterwards, so
   confirm the realm belongs to this customer before you bind it (checklist item "realm ownership
   confirmed by").
4. **R4 First sign-in.** The administrator signs in once. Verify `GET /api/v1/me` shows
   `TENANT_ADMIN` (role names only). Re-read `GET /api/v1/onboarding/{id}`: `login.status` is
   `realm_bound`.

## Realm checklist

One row per item; evidence is a reference, never a value.

| Item | Owner | Evidence | Date |
|------|-------|----------|------|
| `TENANT_ADMIN` exists as a plain realm role and is NOT in `default-roles-<realm>`, any default group, any client-scope role mapping or any composite | | | |
| "Duplicate emails" is OFF | | | |
| Self-registration is OFF | | | |
| No brokered identity provider with "Trust Email" | | | |
| The first user's e-mail is verified | | | |
| "Verify email" is ON in the realm | | | |
| Users cannot edit their own e-mail, or `email_verified` is reset whenever the e-mail changes (the realm's profile and "Update email" settings reviewed) | | | |
| The `email` and `email_verified` mappers are present in the `letflow-web` client scope | | | |
| The realm never issues `PLATFORM_ADMIN` | | | |
| Realm ownership confirmed by (named person at the operator who confirmed this realm belongs to this customer's tenant, and the date) | | | |

## The one line for the infra onboarding checklist

> Every new tenant realm: clone from bpm-default including the TENANT_ADMIN realm role; create
> the first user with a VERIFIED e-mail and the TENANT_ADMIN role; never map TENANT_ADMIN to
> default roles or groups; Duplicate emails OFF.

This repository does not edit the infra repository; ORCH copies the line into
`ai-dala-infra`'s onboarding checklist as a task.

## What the wizard fields do and do not do

- `admin_email`, `admin_username` and `admin_display_name` are **echoed, not stored and not
  acted on**. Nothing creates a realm user or a role grant from them.
- `client_config`, `realm_config`, `redirect_uris` and any other unknown body key are listed by
  name in `ignored_fields` of the response; their values are not read.
- A blank or null administrator field counts as not sent.
