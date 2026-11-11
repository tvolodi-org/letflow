# Sign-in for users made by the Users screen or the xlsx import (REQ-801, GH #4185)

This note decides nothing. The choice is the owner's; anything that touches a realm is also infra's. Production is not covered.

Read on the T-1667 worktree (cut from origin/main, head 723f95a90) on 2026-11-11. Sizes are the analyst's estimate, not measured.

## Today

| Fact | Where it was read | What the code says |
|---|---|---|
| `create_changeset/2` sets `auth_source` to `:internal` and `password_hash` to the sentinel `"__NO_PASSWORD_SET__"`; neither is accepted from the caller. | `lib/letflow/identity/user.ex`, `Letflow.Identity.User.create_changeset/2` | Casts only username, display_name, email, status. The row has no `external_realm` / `external_id`. |
| The xlsx users import creates its users through `Letflow.Identity.create_user/2`. | `lib/letflow/identity/user_import.ex` (`grep -n "create_user"` finds the call); `lib/letflow/identity.ex`, `create_user/2` | Same path as the Users screen. |
| The reset-password route refuses a user whose `auth_source` is not `:oidc`, with reason text `no_identity_provider_login` (HTTP 409). | `lib/letflow/routers/identity.ex`, `do_reset_password/3` | Order of checks: `user_inactive`, then `no_identity_provider_login`, then `no_email`. |
| `create_user/2` does write a login-directory entry for the new user. | `lib/letflow/identity.ex`, `create_user/2` and `directory_step/4`; `lib/letflow/login_directory.ex`, `plan_user_change/2` and `upsert_entry/2` | An active user with a valid e-mail gets `{:upsert, email}`; the write is in the same transaction. With `login_directory: :skip` in opts nothing is written. So the e-mail-first screen can already find the tenant for such a person. |
| No code path on origin/main creates a Keycloak account for such a user. | grep below | See below. |

The grep (run in the worktree):

```
grep -rniE "admin/realms|createUser|create_realm_user|kc_admin|keycloak_admin" lib config priv/keycloak | grep -v "lib/letflow/design"
```

Output: only `lib/letflow/identity.ex:241` (the word `createUser` in the `@doc` of `create_user/2`, a port reference), `lib/letflow/routers/identity.ex:8` (the same word in a moduledoc), and several `CreateUser...` migration module names in `lib/letflow/tenant_provisioning.ex`. None of them calls Keycloak. No file under `config/` or `priv/keycloak/` matched. `Letflow.Signup.RealmProvisioner` (decision 0085 D1) calls the provisioner's realm-creation route, which creates the first administrator inside that call; it has no call that adds a user to an existing realm.

Where the code differs from the entry's description: nothing found. The entry's claim holds: a user made by the Users screen or the import has no path to a login.

Related fact: `docs/runbooks/onboarding-new-tenant-realm.md` says "Nothing in Letflow creates a realm or a realm user today" and gives step R2 (the operator creates the first administrator by hand, e-mail marked verified).

## Options

| Option | How the person signs in | Source | Already allowed by a decision record | Needs a new decision record |
|---|---|---|---|---|
| (a) A Keycloak operator creates the account by hand in the tenant realm | Normal Keycloak login after the operator sets e-mail (verified) and a password or the required action UPDATE_PASSWORD | `docs/runbooks/onboarding-new-tenant-realm.md` step R2 (done today for the first administrator) | Partly: 0072 D1 keeps Letflow out of the realm and leaves realm users to people with realm rights; nothing says an operator does this for every created user | Probably only to say who does it and how often; no code change |
| (b) Infra's provisioner gains a call that creates a realm user | Keycloak login with a temporary password and UPDATE_PASSWORD, like the first administrator in 0085 | 0072 D1 (the scoped creator gets 403 for users on a realm it made); 0085 D1 (`Letflow.Signup.RealmProvisioner` is Letflow's client of the provisioner) | No: 0072 D1 and section 10 ("`manage-users` ... decided later") say the current credential cannot do it | Yes: it widens infra's credential and adds a Letflow client call |
| (c) An invitation mail with a link that lets the person register in the tenant realm | The person registers themselves from the link, then signs in | 0044 (invitation options in section 2.1 to 2.3; Phase 4) | No: 0072 D2 sets `registrationAllowed` false in the realm template (`priv/keycloak/provisioner/v1/`) | Yes: realm template change (v2), who sends the mail (0072 section 10), invitation token rules |
| (d) First-login binding by verified e-mail to the row Letflow already holds | Not a way to get an account: it links the Keycloak login to the existing row. Needs (a), (b) or (c) first | Modelled on 0048 section 1 (rules 2 and 4: normalised e-mail key, `email_verified` true, no other user holds the address) | Partly: 0048 allows this only for a pending tenant-administrator grant; nothing allows it for ordinary users | Yes: rules for ordinary users, and a change to `provision_oidc_user/4` |
| (e) A password login inside Letflow | Letflow checks a password itself | 0035, "Keycloak-hosted-only login is the correct, working, intended production architecture ... No in-app token-paste login screen exists, and none is planned." | Excluded by 0035 | Would need a decision that reverses 0035 |

## What happens at first sign-in to an existing row

Path read: `Letflow.Plugs.AuthPipeline` step 4b calls `Letflow.Identity.provision_oidc_user/4`; when JIT is enabled it runs `upsert_by_external_identity/4`, which first calls `get_by_external_identity/3` (keyed on the pair `external_realm`, `external_id`) and, finding nothing, `insert_or_fetch/4` and the private `insert_or_fetch_in_tx/4` (all in `lib/letflow/identity.ex`). An internal row has both external fields null, so the first lookup never finds it.

| Case | Outcome | Read at |
|---|---|---|
| (i) The Keycloak `preferred_username` equals the internal row's `username` | A refused sign-in. The insert hits the unique index on `username`; `username_unique_conflict?/1` is true; `get_by_username/2` returns the internal row; `identity_matches?/2` is false (realm and external id differ), so `insert_or_fetch_in_tx/4` calls `Repo.rollback(changeset)`. `provision_oidc_user/4` returns `{:error, %Ecto.Changeset{}}`. `auth_pipeline.ex` maps `{:error, {:provision, reason}}` to HTTP 500 `internal_error`, "user provisioning failed", and logs the reason. No second row, no link. | `identity.ex` `insert_or_fetch_in_tx/4`, the `{:error, %Ecto.Changeset{}}` branch; `plugs/auth_pipeline.ex` clause `{:error, {:provision, reason}}` |
| (ii) Only the e-mail is equal (usernames differ) | A second row. The insert succeeds as a new `:oidc` row. There is no unique index on e-mail in the users table (indexes: `username`; `external_realm`+`external_id`; `tenant_id`, `status`, `inserted_at`; migration `20260819000003_create_users_tenant_scoped.exs`). The login-directory write for the new row does `on_conflict: :nothing` on `[:email_key, :tenant_id]`, so it is not an error. Result: two rows with one e-mail, and the internal row keeps its memberships and role grants. | `identity.ex` `insert_or_fetch_in_tx/4` (`{:ok, %User{}}` branch, `write_jit_directory_entry/3`); `login_directory.ex` `upsert_entry/2` |

Not traced: how the web app shows the 500 of case (i) to the person; whether the realm's `preferred_username` claim can be made to equal the internal username (that is a realm mapper question for infra). The behaviour above applies to a person whose Keycloak account came from option (a), (b) or (c); option (d) would change it.

## What each option needs

| Option | Letflow change | Infra change | Owner decision | Security review needed | Rough size (analyst's estimate) |
|---|---|---|---|---|---|
| (a) | None for the sign-in itself. The first-sign-in outcome of the section above still applies | None to code; an operator does a manual step per person (runbook R2 pattern) | Who does it for 30 people; whether this is acceptable beyond QA | No new code; the manual step needs a realm-admin right held by a person (0072 D1) | S (a runbook line); effort per person is the cost |
| (b) | A new client function next to `Letflow.Signup.RealmProvisioner`, a route or a step in the Users screen / import, a mail (`lib/letflow/signup/realm_provisioner.ex`, `lib/letflow/identity.ex`, `lib/letflow/identity/user_import.ex`) | Provisioner gains a user-creation call; its credential is re-scoped (today create-realm-only, 403 for users) | Yes: widening the credential; who sends the first mail | Yes: credential, realm, INV-1 (tenant bound to its own realm), INV-4 (secret handling), INV-10 | L |
| (c) | Invitation table and routes, token rules, mail, UI; realm template v2 | Realm template v2 with registration or an invite flow; mail relay | Yes: registration posture, mail sender, link life | Yes: realm settings, token handling, INV-1, INV-4 | L |
| (d) | Binding rules for ordinary users in `provision_oidc_user/4`; handling of the username collision of case (i); tests | Realm must supply a verified e-mail (0072 D2: `verifyEmail` true) | Yes: whether an e-mail may take over an existing row; what happens to the rows the import already made | Yes: account takeover risk, INV-1, INV-5 | M |
| (e) | excluded by 0035 | excluded by 0035 | excluded by 0035 | excluded by 0035 | excluded by 0035 |

## Owner and infra questions

None is answered here.

1. Which option, or combination, is wanted for QA? Choices: (a) alone; (b); (c); (a) now and (b) or (c) later; with or without (d).
2. Who sends the person's first-sign-in mail? Choices: Letflow (existing mail adapter), the front door, or nobody (the operator tells the person). 0072 section 10 leaves the welcome mail to the owner and says never Keycloak.
3. Are the internal rows already made by the import kept, linked to their Keycloak account (needs (d)), or replaced?
4. For (b): will infra widen the provisioner's credential to users on realms it made, or provide a separate user-creation service? For (c): will infra ship a realm template v2 and mail relay settings?
5. May case (i) (username equal, refused with a 500) stay as it is, or must it become a link or a clear message?

The reset-password button (REQ-789) and the pilot runbook line "imported users being able to sign in" (`docs/runbooks/pilot-first-month.md`) wait on the answer. This note changes neither.

## Sources

- `lib/letflow/identity/user.ex`
- `lib/letflow/identity.ex`
- `lib/letflow/identity/user_import.ex`
- `lib/letflow/routers/identity.ex`
- `lib/letflow/login_directory.ex`
- `lib/letflow/plugs/auth_pipeline.ex`
- `lib/letflow/signup/realm_provisioner.ex`
- `priv/repo/migrations/20260819000003_create_users_tenant_scoped.exs`
- `priv/keycloak/provisioner/v1/`
- `docs/runbooks/onboarding-new-tenant-realm.md`
- `docs/runbooks/pilot-first-month.md`
- `docs/migration/decisions/0035-frontend-login-delegated-to-keycloak.md`
- `docs/migration/decisions/0042-email-first-login-tenant-directory.md`
- `docs/migration/decisions/0044-hybrid-identity-model.md`
- `docs/migration/decisions/0048-pending-tenant-admin-grant.md`
- `docs/migration/decisions/0072-tenant-provisioner-realm-per-tenant-on-qa.md`
- `docs/migration/decisions/0085-signup-realm-provisioner-client.md`
- `docs/uat/ba-decisions/T-1665.md` (item 1)
