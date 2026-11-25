# Letflow.Repo.Migrations.AddSlugToSignupRequests
#
# T-2748 (PILOT G22) -- the sign-up form lets the visitor choose the tenant's host label (slug) and
# a user name. Two nullable columns on the GLOBAL `signup_requests` table (no tenant schema). A row
# without a slug keeps the derived `t-<hex>` label. The partial unique index makes a chosen slug
# unique among the rows that still hold it (a failed or expired row releases it).
defmodule Letflow.Repo.Migrations.AddSlugToSignupRequests do
  use Ecto.Migration

  def change do
    alter table(:signup_requests) do
      add :slug, :string
      add :user_name, :string
    end

    create unique_index(:signup_requests, [:slug],
             where: "slug IS NOT NULL AND state NOT IN ('failed', 'expired')",
             name: :signup_requests_slug_open_index
           )
  end
end
