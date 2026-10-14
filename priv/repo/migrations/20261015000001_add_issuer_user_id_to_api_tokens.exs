# Letflow.Repo.Migrations.AddIssuerUserIdToApiTokens
#
# GH 2552 (decision 0051 M2) -- see lib/letflow/design/gh2552-api-token-issuer-and-roles.md
# section 2 for the design.
#
# Adds `api_tokens.issuer_user_id`, the principal that minted the token over HTTP
# (`Letflow.Identity.mint_token/4`). Nullable, no default, and NO backfill: every existing
# row stays NULL, which means "legacy, issuer not recorded" (no invented issuer and no
# separate flag column, which would only duplicate NULL). Rows from the trusted non-HTTP
# path `Letflow.Identity.create_token/3` are NULL too. The FK uses the default `on_delete`,
# like `user_id`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
# Existing tenants receive the column through the boot-time replay.
#
# Reversible: `change/0` with `alter ... add` and `create index` only.
defmodule Letflow.Repo.Migrations.AddIssuerUserIdToApiTokens do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:api_tokens, prefix: prefix()) do
        add :issuer_user_id, references(:users, type: :binary_id)
      end

      create index(:api_tokens, [:issuer_user_id], prefix: prefix())
    end
  end
end
