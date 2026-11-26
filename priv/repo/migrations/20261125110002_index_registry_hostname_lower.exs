# Letflow.Repo.Migrations.IndexRegistryHostnameLower
#
# T-2748 -- the live slug check looks a host up with `lower(btrim(hostname))` (`TenantHosts.taken?/2`); the plain
# unique index on `hostname` cannot serve that expression, so every availability check scanned the registry.
# Global table, additive, no data change.
defmodule Letflow.Repo.Migrations.IndexRegistryHostnameLower do
  use Ecto.Migration

  def change do
    create index(:onboarding_registry, ["lower(btrim(hostname))"],
             name: :onboarding_registry_hostname_norm_index
           )
  end
end
