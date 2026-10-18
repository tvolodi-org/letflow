defmodule Letflow.Modules.FixtureScoped do
  @moduledoc """
  Test-only entry module (REQ-518 / GH #2535, design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.8). Its pack
  (`priv/module_fixtures/scoped_foundation.json`) defines four entity types:

    * `scoped_item`, `scoped_child` (fk to `scoped_item`): scope column `scope_node`,
      declared `{:column, "scope_node"}`, UNMANAGED (tenant-writable), which is allowed only
      because this module id is on the test-only allowlist
      `config :letflow, :scope_declaration_unmanaged_modules` (`config/test.exs`; Catalog rule
      11, SEC ruling R-3);
    * `scoped_master`: declared `:tenant_wide`, unmanaged;
    * `scoped_managed_item`: managed (`manages_entity_types`), declared `{:column, "scope_node"}`.

  `on_install/3` activates and promotes all four (FK order). No router, no permissions, so no
  permission or route count changes. Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.EntityActivation

  @all_types ["scoped_item", "scoped_master", "scoped_managed_item", "scoped_child"]

  @impl true
  defmanifest(
    id: "fixture_scoped",
    version: "0.1.0",
    depends_on: [],
    pack: "module_fixtures/scoped_foundation.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["scoped_managed_item"],
    scope_declarations: %{
      "scoped_item" => {:column, "scope_node"},
      "scoped_child" => {:column, "scope_node"},
      "scoped_master" => :tenant_wide,
      "scoped_managed_item" => {:column, "scope_node"}
    }
  )

  @doc "Every entity type this fixture's pack defines, in FK-DAG order."
  @spec all_types() :: [String.t()]
  def all_types, do: @all_types

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @all_types)
  end
end
