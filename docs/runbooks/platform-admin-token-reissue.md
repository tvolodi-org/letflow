# Runbook: standing PLATFORM_ADMIN tokens with no expiry (GH #2579)

API tokens minted over HTTP have an expiry capped by `:platform_admin_token_max_ttl_days` (90
days by default, GH #2552). Tokens minted before that change can still have no expiry. A
PLATFORM_ADMIN token with no expiry is a full-platform credential that never ends, and it may
have no recorded issuer (a legacy row). This runbook finds those tokens and replaces each one
with an explicit, audited act.

There is **no automatic mass revoke**. Nothing here runs on a schedule, and no command acts on
more than one token. Each token is decided by a person, one at a time.

Run the commands with `bin/letflow eval`, as the other release operator wrappers do (see
`docs/runbooks/release-backfills.md`). Do not call them through `rpc`: the re-mint can
`System.halt(1)` on failure, and that would stop a live node.

## 1. Inventory (read-only)

    bin/letflow eval "Letflow.Release.platform_admin_token_inventory()"

The inventory lists each live (not revoked) PLATFORM_ADMIN token with no expiry, one line per
token, then one `TENANT` line per tenant and one `SUMMARY` line:

    PA_TOKEN_NO_EXPIRY tenant=<tenant_id> schema=<schema> token_id=<id> owner_user_id=<id> issuer_user_id=<id|legacy> created_at=<iso8601> last_used_at=<iso8601|never>
    TENANT tenant=<tenant_id> schema=<schema> non_expiring_platform_admin=<n> legacy_no_issuer=<m> errored=0
    SUMMARY tenants=<t> non_expiring_platform_admin=<n> legacy_no_issuer=<m> errored=<e>

It prints ids, timestamps and counts only. It never prints a token value, a hash or a token name.
A clean install prints `non_expiring_platform_admin=0` in the `SUMMARY` line.

Exit status 1 means at least one tenant could not be read (`errored` is greater than 0). The
other tenants were still inventoried. Fix the cause (a tenant schema that is missing or damaged)
and run the inventory again before deciding anything.

## 2. Decide, with the owner, for each `PA_TOKEN_NO_EXPIRY` line

For each token, the owner (`owner_user_id`) and the operator agree on one of two outcomes:

- **Replace** (keep the owner's access): run step 3 for this token.
- **Revoke only** (the owner no longer needs platform access): revoke it through the tenant API,
  `DELETE /identity/tokens/<token_id>` by a platform admin. This is the normal audited revoke.
  Use it for a token whose owner has left, and for any token that the act refuses (step 6).

Do not revoke a token because the inventory lists it, without the owner's decision.

## 3. Replace one token (explicit, per token)

Run the act for ONE token id, once. Do not script it over a list of ids.

    bin/letflow eval "Letflow.Release.reissue_platform_admin_token(\"<tenant_id>\", \"<token_id>\", \"<operator_user_id>\", cause: \"<reason>\", plaintext_file: \"<path>\")"

- `<operator_user_id>` is the admin who is accountable for the act. It must be an active
  PLATFORM_ADMIN of that tenant. It becomes the audit `actor_id`.
- `cause:` is the reason, free text of at most 200 bytes with no control characters. It is
  stored in the audit entries as `cause`. It must not contain a token value or any other
  credential.
- `plaintext_file:` is a NEW path that the act creates. It must not exist. The act never
  overwrites a file. The new token's value is written there and nowhere else.
- `days:` is optional. It defaults to the cap (90) and must be between 1 and the cap.

The act does the following, in this order:

1. Checks the tenant, the token, the operator and the inputs. Nothing is written in this step.
2. Creates `<path>` exclusively. If the file cannot be created, the act stops here.
3. Mints a replacement token for the SAME owner, with the same roles and an expiry inside the
   cap. It is recorded as `token.create`, with `issuer_user_id` = the owner, `actor_id` = the
   operator and `cause`.
4. Writes the new value into `<path>`.
5. Revokes the OLD token, recorded as `token.revoke`, with the same `actor_id`, the same `cause`
   and the same `trace_id` as step 3.

A successful run prints one line:

    REISSUE old_token_id=<id> new_token_id=<id> owner_user_id=<id> expires_at=<iso8601> cause_recorded=true plaintext_file=<path>

Then:

- Read `<path>` and deliver the value to the owner over a secure channel (not e-mail, not chat).
- Delete `<path>` once the owner has the value.

The value is never printed and never written to a log. If the file is lost before delivery, the
value is gone. Revoke the new token (`DELETE /identity/tokens/<new_token_id>`, using the id from
the `REISSUE` line) so that no unused credential stays live. The act cannot be run again: the old
token is already revoked (`:already_revoked`). The owner then needs a new token through the normal
issuance path.

## 4. Verify

1. Run step 1 again. The replaced token must no longer appear in `PA_TOKEN_NO_EXPIRY` lines.
2. Check the audit entries in the tenant schema (table `audit_entries`, schema
   `<schema>` from the `TENANT` line). Both entries for the act have the same `trace_id`:
   - `token.create` for `resource_id` = the new token id: `actor_id` = the operator,
     `after_state.issuer_user_id` = the owner, `after_state.cause` = the reason.
   - `token.revoke` for `resource_id` = the old token id: `actor_id` = the operator,
     `after_state.cause` = the reason.
   No audit entry contains a token value or a hash.
3. Confirm that the owner can sign in with the delivered value, then delete the local file.

## 5. Failure table

Every failure line is `ERROR <reason>`. The exit status is 1. Read the reason in this table.

| Reason | Meaning | What to do |
|---|---|---|
| `:unknown_tenant` | the tenant id is not a registered tenant | check the tenant id; re-run |
| `:not_found` | the token id does not exist in that tenant | check the token id; re-run |
| `:already_revoked` | the token is already revoked | nothing to do; the inventory will not list it |
| `:not_non_expiring_platform_admin` | the token has an expiry, or does not carry PLATFORM_ADMIN | the act acts only on a non-expiring PLATFORM_ADMIN token; nothing changed |
| `:operator_not_platform_admin` | the operator is not an active PLATFORM_ADMIN of the tenant | use an accountable admin's user id; nothing changed |
| `:invalid_cause` | the `cause:` text is empty, too long, or has a control character | fix the text; nothing changed |
| `:invalid_days` | `days:` is not an integer from 1 to the cap | fix the value; nothing changed |
| `:invalid_plaintext_file` | `plaintext_file:` is empty | give a path; nothing changed |
| `:plaintext_file_exists` | the path already exists (for example from an earlier run) | choose a new path. Do NOT delete a file you do not know: it may hold a live token. Nothing changed |
| `{:plaintext_file, <posix>}` | the file could not be created (for example a directory that does not exist) | fix the path or permissions; nothing changed |
| `:issuer_not_authorized`, `:user_inactive`, `:user_not_found`, `:invalid_role_set`, `:roles_not_held`, `:expires_at_in_past`, `:platform_admin_token_not_self` | the mint refused the replacement (the owner lost access, is inactive, or the expiry is out of range) | nothing changed (no token was minted, and the file was removed). Revoke the token with `DELETE /identity/tokens/<old_token_id>` if the owner should not have access |
| `{:plaintext_write_failed, <new_id>, <posix>}` | the new value could not be written to the file | the NEW token was revoked again automatically, and the OLD token still works. The file was removed. Fix the disk problem and run the act again |
| `{:plaintext_write_failed, <new_id>, <posix>, {:compensate_failed, _}}` | the write failed, and revoking the new token also failed | a live token nobody holds exists and expires by itself within the cap. Revoke it with `DELETE /identity/tokens/<new_id>`. Do not run the act again until this is done |
| `{:revoke_failed, <new_id>, _}` | the replacement was minted and written, but the old token could not be revoked | the file is KEPT and holds the live new token. Deliver the file to the owner, revoke the OLD token with `DELETE /identity/tokens/<old_token_id>`, then delete the file. Do NOT run the act again: a second run would mint a third token |
| any other error | an error from the database | nothing is known to have changed; read the logs, then check the inventory before any re-run |

A crash between the write (step 4) and the revoke (step 5) leaves the file on disk and both tokens
live. A re-run is refused with `:plaintext_file_exists`, so it cannot mint a third token. Handle it
as `{:revoke_failed, ...}` above.

## 6. Tokens outside the platform tenant

The act mints only in the platform tenant, because a PLATFORM_ADMIN token is refused elsewhere.
A PLATFORM_ADMIN token in another tenant that the inventory lists (or that the act refuses with
`:invalid_role_set`) is revoked with `DELETE /identity/tokens/<token_id>` only.

## 7. Windows note

On Windows the file mode of `plaintext_file` is not enforced. Use a path in a directory that only
the operator can read, and delete the file after delivery.
