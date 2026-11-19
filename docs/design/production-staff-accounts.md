# Accounts for the staff of a production company: product flow or operator procedure (Client 1)

Design note, task T-2194 (PM, 2026-11-19). It decides nothing. It changes no code and no setting: the flag
`LETFLOW_REALM_USERS_ENABLED` stays OFF everywhere. The owner decides under O-015 (the production go); the one
decision is in the section "The owner's decision (O-015)". Production is not approved (D-086; D-019 item 9).

Facts were read on origin/main `de6107d6a` on 2026-11-19, and in infra's working copy where this note says so.
Sizes and minutes are estimates, not measurements. Nothing here names a real person, and nothing here is a secret:
every person, address, realm and login is a placeholder in angle brackets.

## The problem

Client 1 (the first Qoimeks customer company, about 20 staff) needs a sign-in for each person before the
production go. A sign-in is a Keycloak account in the company's own realm (one realm per tenant, D-016;
decision 0035: Letflow has no password login of its own). Letflow can create such an account only through
infra's provisioner (decision 0072 section 8b), and that path is OFF: `POST /api/v1/identity/users/:id/sign-in`
answers 409 `sign_in_creation_off` while `Letflow.Signup.RealmUsers.configured?/0` is false
(`handle_create_sign_in/3` in `lib/letflow/routers/identity.ex`). Today a Keycloak operator makes each account
by hand (`docs/runbooks/onboarding-new-tenant-realm.md`, section "Sign-in for users created later";
`docs/runbooks/pilot-first-month.md`, "Interim sign-in path for created users").

Two ways forward: (A) turn the product flow on in production, or (B) write the operator procedure for
production so that 20 accounts are made the same way every time.

## What both options need first (not part of either option)

The production tenant of Client 1 exists, its realm is made from `priv/keycloak/provisioner/v2/tenant-realm.json`
and bound (`docs/runbooks/onboarding-new-tenant-realm.md`, steps R1 to R3), its first administrator has signed in
(R4, R5), and the realm checklist of that runbook is filled. Production DNS, certificates and the production
Keycloak are infra's and wait for the owner's go (O-015, O-016). This note starts after that point.

## Facts this note relies on

| Fact | Where it was read |
|---|---|
| The flag is on only for exactly `true`; the three settings `LETFLOW_REALM_USERS_ENABLED`, `LETFLOW_REALM_USERS_PROVISIONER_URL`, `LETFLOW_REALM_USERS_PROVISIONER_TOKEN` are set together or boot stops; the URL must be `http://` to a loopback or private address with a port and no path | `config/runtime.exs` (the `users_enabled` block); `Letflow.Signup.RealmProvisioner.valid_base_url?/1` |
| The sign-in route needs `UsersManage`, takes the tenant from the authenticated context, refuses a user who is inactive, already bound, a service principal or without e-mail, and refuses a tenant whose `idp_realm_id` is not `RealmProvisioner.label/1` of its tenant id (`t-` and 20 hex digits) | `Letflow.Identity.SignIn` (`check_row/1`, `check_realm/1`); `authz_post "/users/:id/sign-in", :UsersManage` in `lib/letflow/routers/identity.ex` |
| On success the row is bound (`auth_source` oidc, `external_realm`, `external_id`), one audit entry `user.sign_in_created` is written, and the temporary password is returned once in the 201 body with `cache-control: no-store`; it is in no audit entry, log or refusal | `Letflow.Identity.SignIn.bind/4`, `append_audit/3`; `do_create_sign_in/3` |
| The xlsx import creates the sign-in of each new row in the same answer when the flag is on (REQ-808); the web shows the password once (REQ-809) | `lib/letflow/routers/identity/users_import.ex` moduledoc; `web/src/components/admin/users/TemporaryPasswordPanel.tsx` |
| The client calls `POST {base}/v1/realms/{tenant_id}/users`; its path and field names are an assumption, "whoever turns the flag on must first check them against infra's published contract"; no retries | `Letflow.Signup.RealmUsers` moduledoc |
| Infra's provisioner has no user-creation call today: its routes are `/healthz`, `/v1/realms`, `/v1/realms/{tenant_id}`, `/v1/status` | infra working copy, `services/tenant-provisioner/internal/api/api.go` (read 2026-11-19) |
| Infra's production plan keeps the tenant provisioner QA-only and gives production its own Keycloak; the production Keycloak serves only `/realms/` and `/resources/` publicly (`/admin` and `/realms/master` answer 404 from outside) | infra working copy, `runs/2026-11-16-letflow-prod-on-bizdala-host-plan-001/step-04-solution-designer.md` (section 1 "Stack separation"; the external checks; Phase 4 lists "tenant provisioner (QA instance)" among what stays QA-only) |
| Decision 0072 section 8b is QA only; "Not decided here: ... production" | `docs/migration/decisions/0072-tenant-provisioner-realm-per-tenant-on-qa.md`, section 8b |
| The security review of the chain (T-1772, PR #4290) was PASS_WITH_FINDINGS; its remainder: "TLS verify_peer for RealmUsers/RealmProvisioner before the flag goes on; no Letflow-side rate limit on POST /users/:id/sign-in, held by infra's provisioner per 0072 8b item v" | PR #4290 body |
| At every sign-in the auth pipeline refuses an inactive Letflow user with 403 "account is inactive", before any role is read | `verify_local_account_state/2` in `lib/letflow/plugs/auth_pipeline.ex` |
| A first sign-in with no matching row creates an active row with no roles (JIT is on for every realm by default) | `Letflow.Oidc.JitProvisioningConfig.default/1` (`enabled: true`, `default_status: :active`, `default_roles: []`) |
| A first sign-in whose username equals an existing row is refused with 403 `username_in_use`; an equal e-mail with a different username makes a second row, and the old row keeps its roles | `lib/letflow/plugs/auth_pipeline.ex` (`{:provision, :username_in_use}`); `docs/design/REQ-801-sign-in-for-created-users.md`, "What happens at first sign-in to an existing row" |
| Realm roles in the token become Letflow group memberships at sign-in until at least one membership has been written; after that never again. The sync only adds, never removes, and honours an explicit removal | `Letflow.Identity.sync_role_claims_from_token/3` moduledoc and the ISS-0773 comment above the `role_claims_synced_at` stamp |
| Letflow writes no audit entry when the first sign-in creates a row; it audits group membership changes (`group_member.added`, `group_member.removed`) and status changes (`user.update_status`) | `grep -n 'action: "user\.' lib/letflow/identity.ex` finds only `user.create` (in `create_user/2`); `"group_member.added"` in `lib/letflow/identity.ex`; `user.update_status` in `update_user_status/3` |
| The tenant realm template has self-registration OFF, duplicate e-mails OFF, login with e-mail ON, editing the username OFF, verify e-mail ON, brute-force protection ON (5 failures), password policy `length(12) and upperCase(1) and lowerCase(1) and digits(1) and notUsername()`, and no Keycloak groups; it does not switch on admin events | `priv/keycloak/provisioner/v2/tenant-realm.json` |
| "Send password reset instructions" (REQ-788) sends a Letflow mail only to a user with an identity-provider login; production mail sending is a separate owner decision (infra plan, Phase 4) | `do_reset_password/3` in `lib/letflow/routers/identity.ex` |

## Option A: the product flow turned on

### What the flag and the provisioner do

The tenant administrator first creates the person in Letflow (Admin > Users, or the xlsx import) with a real
e-mail, then presses "Create sign-in" (or the import does it). Letflow calls infra's provisioner once; the
provisioner creates an enabled Keycloak account in the company's realm with the e-mail marked verified, a
temporary password and the required action UPDATE_PASSWORD, and answers with the Keycloak user id and the
password. Letflow binds its row to that account in one transaction and shows the password once. At the first
sign-in Letflow finds the bound row, so no second row is made, and Keycloak forces a new password.

### What has to be configured before it works in production

1. Infra builds the user-creation call of 0072 section 8b items (i) to (v) (not built on QA either, see the facts
   table), publishes its contract, and Letflow's client is checked against it (the `RealmUsers` moduledoc says so).
2. Infra runs a production provisioner. Today's plan keeps the provisioner QA-only, and D-019 item 9 approves it
   for QA only: both change.
3. The provisioner's Keycloak credential on the production Keycloak may create users only in realms it made and
   nothing else (8b item (iii), a change of D-018).
4. The company's realm must be one the provisioner made (`idp_realm_id` equal to `RealmProvisioner.label/1` of
   the tenant id, and the provisioner answers not-found for any other realm, 8b item (ii)). A hand-made realm never
   qualifies, and the realm binding of a tenant is permanent (runbook step R3). So option A also changes how
   Client 1's realm is made.
5. A decision record (an addendum to 0072 section 8b) lifts "QA only" for this call.
6. The T-1772 remainder is closed: TLS with peer verification on the provisioner call before the flag goes on.
   Today `valid_base_url?/1` accepts only `http://` to a private address, so the bearer token crosses that private
   network unencrypted.
7. The three settings are put in the production app's environment file (never in git), the app restarts.

### Where the one-time password goes

Only into the 201 answer to the administrator who pressed the button (or the import answer), with
`cache-control: no-store`, shown once in the temporary-password panel. The administrator hands it to the
person (the channel is the same question as in option B). It dies at first use (UPDATE_PASSWORD). If the answer
is lost after the provisioner's 201, the account exists without a bound row and the password is lost; a
Keycloak operator must remove that account by hand before a retry (`Letflow.Identity.SignIn` moduledoc).

### How roles are assigned

In Letflow, on the row, before or after the sign-in is created (group membership on the Users screen, audited
`group_member.added`). The provisioner maps no realm role, so the first-sign-in claim sync adds nothing.

### How a leaver is disabled

The administrator sets the person inactive in Letflow (Admin > Users, `POST /users/:id/status`); the next request
with that person's token is refused (403 "account is inactive"). 0072 section 8b has no disable or delete call, so
the Keycloak account stays enabled until a Keycloak operator disables it: option A still needs the operator for
leavers, or accepts an enabled Keycloak account that Letflow refuses.

### Audit

Letflow: `user.sign_in_created` (actor: the administrator), the membership and status entries. Infra: the
provisioner's own audit log and rate limit (8b item (v)).

### What an attack on the provisioner token would allow

The token is one caller token for Letflow's users step, held in the app's environment. Whoever holds it and can
reach the provisioner's private address can, in every realm the provisioner made (every provisioner-made tenant
served by that provisioner):

- create enabled accounts with any username and a verified e-mail of their choosing, and receive the temporary
  password; at the first sign-in Letflow makes an active row with no roles;
- **take an open pending administrator grant**: an account with the pending address and a verified e-mail binds
  the grant at its first sign-in and becomes `TENANT_ADMIN` (decision 0048; runbook "Pending administrator");
- create an account with the e-mail of an existing staff member and a different username, which makes a second
  row that people may mistake for the real one (case (ii) above);
- exhaust the provisioner's rate limit, so legitimate sign-ins cannot be created.

It cannot read, change, disable or delete an existing account or map a realm role, if infra scopes the
credential as 8b item (iii) asks. Limits: a separate production provisioner and token (never the QA ones), the
token only in the app's environment file, the provisioner reachable only from the app's network, the
provisioner's rate limit and audit log watched, no pending administrator grant left open after the go
(`GET /api/v1/onboarding/{id}/pending-admins`), the token rotated on any suspicion, and TLS (item 6 above).

### What the security gate says

The built chain passed its security review with findings (T-1772, PR #4290): the password is in the one 201
answer only, cross-tenant calls answer 404, the flag-off refusal holds. Two items stay open before the flag goes
on: TLS with peer verification on the provisioner call, and no rate limit on Letflow's side (left to the
provisioner). The review covered QA; production needs the decision of item 5 and a new security review of the
production provisioner and credential, which are infra's.

### Steps, who does what, cost

| Step | Who | One-off or per person | Estimate |
|---|---|---|---|
| Build the user-creation call, the production provisioner, the scoped credential, audit and rate limit | infra | one-off | days to weeks; not planned today |
| Decision-record addendum for production; close the TLS remainder; check the client against the contract | Letflow team | one-off | one design task and one change task |
| Make Client 1's realm through the provisioner | infra | one-off | part of the production provisioner work |
| Create the person in Letflow, assign the group, press "Create sign-in", hand over the password | tenant administrator | per person | about 3 minutes |
| Disable a leaver in Keycloak | Keycloak operator | per leaver | about 2 minutes, batched |

### Risks

Not available for the production go (items 1 to 5 do not exist); a new standing credential with power over
every provisioner-made realm (above); the lost-answer residual; leavers still need the operator.

## Option B: a documented operator procedure

### Who does what

- **Tenant administrator** (Client 1's own `TENANT_ADMIN`): sends the operator the list, hands each temporary
  password to its person, watches the first sign-in, gives roles in Letflow, retires leavers in Letflow.
- **Keycloak operator** (infra; a named person, never a Letflow tenant user): creates and disables the Keycloak
  accounts. Nobody is on call (D-116): the operator works in batches.
- Letflow changes nothing: no code, no flag.

### What the operator needs once

1. A personal operator login in the production Keycloak's `master` realm, never a shared one and never an account
   inside the company's realm (an account in the company realm could sign in to Letflow and would get a row). It
   holds only the roles `manage-users`, `view-users` and `query-users` of the master client `<realm>-realm` for the
   company's realm: not the master `admin` role, no rights in any other realm. One-time password (OTP) is required
   for that login.
2. Access to the admin console or `kcadm.sh` only through the production host (the public name serves no
   `/admin`, infra plan).
3. In the company's realm: "Admin events" saved ON, "Include representation" OFF (the record names the actor and the
   user id; the representation is not needed). The template does not switch this on.
4. One rehearsal of the commands below on a QA realm with one placeholder person, then that QA account deleted.

### The list the administrator sends

One row per person: e-mail address, first name, last name, language (`ru`, `kk` or `en`). No role, no
password, no other data. Every person has an address of their own (a shared mailbox breaks the sign-in
directory and the "duplicate e-mails OFF" rule). The list holds personal data: it is never put in a ticket, a
public chat or any repository, is kept with file mode 600 while in use, and is deleted after the batch.

**Do not create these people in Letflow first.** The Letflow row is made by each person's first sign-in. A row
made before on the Users screen or by the import collides with the account: an equal username is refused (403
`username_in_use`), a different username makes a second row (facts table). If rows already exist (for example
from a data import), follow step 6 of `docs/runbooks/pilot-first-month.md` ("Interim sign-in path for created
users") for each of them.

### Steps per person (Keycloak 26 admin console)

1. **Look up.** Users > search by the e-mail. A hit means stop for this person and report it (duplicate e-mails are
   OFF; never reuse or rename an existing account).
2. **Create.** Users > Add user: Username = the e-mail address; Email = the same address; Email verified = ON;
   First name, Last name; Required user actions = Update Password. Create.
3. **Language.** Attributes: `locale` = `ru`, `kk` or `en` (the realm has internationalization ON with these
   three languages).
4. **Temporary password.** Credentials > Set password: a new random password that meets the realm policy
   (at least 12 characters, one upper-case letter, one lower-case letter, one digit, not the username);
   Temporary = ON. Save. The operator gives it to the administrator through the owner's channel; it is never
   written in a ticket, chat, mail that also names the person, file, runbook or git.
5. **Realm roles and groups.** Assign nothing. Role mapping shows only `default-roles-<realm>`, which holds no
   Letflow role (realm checklist). The realm has no Keycloak groups; Letflow's groups live in Letflow.
6. **Run log.** One line in the operator's run log kept by infra, outside every repository: date, operator login,
   realm, the row number of the list, the Keycloak user id, done or stopped. No password, no name.

Then, the tenant administrator:

7. **Hand over.** The administrator gives the person the temporary password in person or by phone.
8. **First sign-in.** The person opens `<company production address>` (the product runbook onboarding-new-tenant-realm.md R1 and infra's production plan name different domains; the host name is O-016's to settle), signs in with the e-mail and the
   temporary password, and Keycloak makes them choose their own (UPDATE_PASSWORD). The first sign-in makes the
   person's Letflow row: active, with no roles. The claim sync adds nothing, because no realm role was mapped.
9. **Roles.** Admin > Users: the person appears once; the administrator adds them to the group of their role
   (for example the storekeepers' group), which writes `group_member.added`. The person's next request carries the
   role. `GET /api/v1/me` shows the role names.

Why roles are given in Letflow and not as realm roles: the claim sync copies realm roles into Letflow only until
the first membership is written and never removes one, so a realm role changed later in Keycloak does nothing and
Keycloak would show a role Letflow no longer grants. One place for roles (Letflow) keeps them audited with the
administrator as actor. The exception is the first administrator, made by steps R2 and R5 of the onboarding
runbook (pending grant or the realm role `TENANT_ADMIN`). Mapping a realm role for a staff member works too
(the first sign-in then gives the group at once), but it is not the default of this procedure.

### The same steps for a batch of about 20 (command form)

A draft for infra, who owns the production Keycloak host; it belongs in infra's repository, and the rehearsal of
"What the operator needs once", item 4, checks every command (including `kcadm.sh <command> --help` on the running
version) before the first production batch. Placeholders: `<kc>` is the Keycloak container, `<realm>` the company
realm id, `<operator>` the operator's own login, `<run>` a run id.

```
# Once per batch: log in. The password is prompted, never given as an argument. kcadm has no OTP prompt:
# how the OTP-protected operator signs in with kcadm is decided in the QA rehearsal, or this step is done in the
# console. OTP is never removed from the operator login to make the script work.
docker exec -it <kc> /opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm-<run>.config \
  --server http://localhost:8080 --realm master --user <operator>

KC="docker exec -i <kc> /opt/keycloak/bin/kcadm.sh"
CFG="--config /tmp/kcadm-<run>.config"

# Per row of the list (<email>, <first>, <last>, <lang>):
# 1. Look up: the answer must be [] or the row is stopped.
$KC get users $CFG -r <realm> -q email=<email> -q exact=true --fields id,username,enabled

# 2 and 3. Create; -i prints the new user id.
$KC create users $CFG -r <realm> -s username=<email> -s email=<email> -s emailVerified=true \
  -s enabled=true -s firstName=<first> -s lastName=<last> -s 'attributes.locale=["<lang>"]' \
  -s 'requiredActions=["UPDATE_PASSWORD"]' -i

# 4. Temporary password: generated into a shell variable, shown once on the operator's screen,
#    sent on standard input (printf is a shell builtin: the value is in no argument list and no history).
PW=$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 16)
#    repeat the line above until the value has an upper-case letter, a lower-case letter and a digit
printf '%s\n' "$PW"
printf '{"type":"password","temporary":true,"value":"%s"}' "$PW" | \
  $KC update users/<id>/reset-password $CFG -r <realm> -f - -n
unset PW

# 5. Check: only default-roles-<realm>.
$KC get-roles $CFG -r <realm> --uusername <email>

# After the batch: remove the session file.
docker exec <kc> rm -f /tmp/kcadm-<run>.config
```

### A leaver

1. **Letflow first (takes effect at once).** The administrator sets the person inactive (Admin > Users > the person
   > status Inactive, `POST /api/v1/identity/users/:id/status`, audited `user.update_status`). The next request with
   the person's token is refused. Letflow refuses to make the last tenant-wide administrator inactive (409
   `last_tenant_wide_admin`).
2. **Keycloak, in the next batch.** The operator disables the account (Users > the person > Enabled = OFF;
   command form `$KC update users/<id> $CFG -r <realm> -s enabled=false`) and signs out its sessions (Sessions >
   Sign out; REST `POST /admin/realms/<realm>/users/<id>/logout`). The account is disabled, not deleted, so a
   person who comes back is enabled again with a new temporary password and keeps their Letflow row. When an
   account is deleted is not decided here.

### Forgotten password

Until production mail is on, the operator sets a new temporary password (step 4) and the administrator hands it
over. Once mail is on, "Send password reset instructions" (REQ-788) works for every person who has signed in.

### Checklist for one batch

| # | Item | Done (initials, date) |
|---|---|---|
| 1 | The company realm is the tenant's bound `idp_realm_id` (`GET /api/v1/onboarding/{id}`) and its realm checklist is filled | |
| 2 | Operator login is personal, master realm, `manage-users`/`view-users`/`query-users` of `<realm>-realm` only, OTP on | |
| 3 | Admin events ON, representation OFF in the company realm | |
| 4 | QA rehearsal of the commands done, QA placeholder account deleted | |
| 5 | List received: e-mail, first name, last name, language per row; no person already exists in Letflow, or step 6 of the pilot runbook is planned for each who does | |
| 6 | Each row: looked up, created, locale set, temporary password set, no realm role, run-log line written | |
| 7 | Each temporary password handed over through the owner's channel; none written down | |
| 8 | Each person signed in once, appears once on the Users screen, has their group | |
| 9 | List file deleted; `kcadm` session file removed | |

### Audit

Keycloak admin events (who created, reset or disabled which account) and infra's run log. Letflow: the row
appears at first sign-in (no audit entry for that, facts table), roles and leavers are audited by the existing
membership and status entries with the administrator as actor.

### Risks and limits

- The operator login can create, reset and disable every account in the company realm, the administrator's
  included: someone holding it could reset the administrator's password and sign in as them. Limits: a personal
  login, OTP, no public admin console, admin events, rights in that one realm only.
- Human error: the wrong realm (checklist item 1), e-mail not marked verified (the person can still sign in,
  Keycloak asks to verify, which needs mail), a realm role mapped by mistake (step 5 check). A mistake is
  corrected by the operator; no Letflow data is touched.
- The temporary password passes through two people (operator, administrator). It lives until the first sign-in;
  hand it over the same day.
- One operator step per person and per leaver; with nobody on call, new staff wait for the next batch.
- Pre-made Letflow rows collide (above).

### Cost

| Step | Who | One-off or per person | Estimate |
|---|---|---|---|
| Operator login, OTP, admin events, QA rehearsal | infra | one-off | 1 to 2 hours |
| Steps 1 to 6 | Keycloak operator | per person | about 5 minutes in the console, about 2 with the command form; about 1 hour for 20 people in one session |
| Steps 7 to 9 | tenant administrator | per person | about 5 minutes |
| A leaver | administrator, then operator | per leaver | 1 minute, then about 2 minutes in the next batch |
| Letflow code or settings | none | none | none |

## Comparison

| | A: product flow | B: operator procedure |
|---|---|---|
| Ready for the production go | No: needs the provisioner's user call (not built), a production provisioner (QA-only today), a scoped credential, a provisioner-made realm, a decision addendum, the TLS remainder | Yes: needs only an operator login and one rehearsal |
| Letflow change | None to the code; a decision-record addendum and the TLS fix | None |
| Who makes an account | the tenant administrator, by a button | the Keycloak operator |
| Per person, 20 people | about 3 minutes of the administrator; no operator | about 2 to 5 minutes of the operator plus about 5 of the administrator |
| Duplicate rows | none: the row is made first and bound | none if no row is made first; otherwise the pilot runbook's step 6 |
| Leaver | Letflow at once; Keycloak still by the operator | Letflow at once; Keycloak by the operator |
| Standing credential | a provisioner token that can create accounts in every provisioner-made realm, including taking an open pending administrator grant | a personal, OTP-protected operator login with rights in one realm |
| Audit | Letflow `user.sign_in_created` plus the provisioner's log | Keycloak admin events plus infra's run log |

## Recommendation

**Option B for Client 1's production go.** Option A cannot be ready for the go: none of its items 1 to 5 exists,
and its main benefit (no operator step) is small for 20 people in one batch, while leavers need the operator under
both options. Option B needs no code and no new standing credential. Keep option A for QA as decided (0072
section 8b). Look at option A for production again when infra's user call has been walked end to end on QA and a
production provisioner is approved, or when hires and leavers across production companies make the operator
batches a real load. If that is likely, infra may name Client 1's realm by `RealmProvisioner.label/1` of its tenant
id, so the realm itself need not change later; the provisioner would still have to accept a realm it did not
make.

## The owner's decision (O-015)

Under O-015 the owner decides one thing: whether, at the production go, the accounts of Client 1's staff (about 20
people) are made by the operator procedure (option B of this note), with `LETFLOW_REALM_USERS_ENABLED`,
`LETFLOW_REALM_USERS_PROVISIONER_URL` and `LETFLOW_REALM_USERS_PROVISIONER_TOKEN` left unset in production; the
decision names the two parts of that procedure only the owner can fix, the person at infra who holds the
production Keycloak operator login and the channel by which each temporary password reaches the company's
administrator (recommended: read out by phone or given in person, never by mail, chat or ticket). Choosing option A
instead means approving a production provisioner and its user-creation credential (changes to D-019 item 9, D-018
and decision 0072 section 8b) and moving the go until infra has built them.

## Not decided here

Production itself, DNS, certificates and the production Keycloak (O-015, O-016); production mail and the e-mail
set-password link of D-118 item 1; when a disabled Keycloak account is deleted; the first administrator's Keycloak
rights in production (`docs/runbooks/production-readiness.md`, open owner questions); option A's contract and
security review. Turning option B into a runbook and infra's script is a follow-up after the owner's decision.

## Sources

- `lib/letflow/identity/sign_in.ex`, `lib/letflow/signup/realm_users.ex`, `lib/letflow/signup/realm_provisioner.ex`
- `lib/letflow/routers/identity.ex`, `lib/letflow/routers/identity/users_import.ex`
- `lib/letflow/plugs/auth_pipeline.ex`, `lib/letflow/identity.ex`, `lib/letflow/oidc/jit_provisioning_config.ex`
- `config/runtime.exs`, `config/prod.exs`, `priv/keycloak/provisioner/v2/tenant-realm.json`
- `docs/runbooks/onboarding-new-tenant-realm.md`, `docs/runbooks/pilot-first-month.md`, `docs/runbooks/production-readiness.md`
- `docs/design/REQ-801-sign-in-for-created-users.md`
- `docs/migration/decisions/0035-frontend-login-delegated-to-keycloak.md`, `0048-pending-tenant-admin-grant.md`,
  `0072-tenant-provisioner-realm-per-tenant-on-qa.md` (section 8b), `0085-signup-realm-provisioner-client.md`
- PR #4290 (security review T-1772)
- infra working copy: `services/tenant-provisioner/internal/api/api.go`;
  `runs/2026-11-16-letflow-prod-on-bizdala-host-plan-001/step-04-solution-designer.md`
