defmodule Letflow.Modules.FixtureManaged do
  @moduledoc """
  Test-only entry module (REQ-496, decision 0050 D7; design
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §2.8). Its pack
  (`priv/module_fixtures/managed_foundation.json`) holds eight entity definitions,
  each with one `name :: string` field and no FKs; its manifest declares the first
  seven in `manages_entity_types`, so installing it stamps `managed_by:
  "fixture_managed"` on them. `fxm_ledger` is also `append_only`; `fxm_free` is NOT
  managed (the control). `on_install/3` activates and promotes all eight.

  The public `create_record/3`, `update_record/4` and `delete_record/3` helpers are
  the "owning module's own path": direct `Letflow.Entities.Records` calls, which
  the router-level managed check never sees. Each passes
  `ManagedTypes.owner_for!(__MODULE__)` as the `Records` `/3` authority (GH #2583),
  so `Records` lets them write the seven managed types. No router and no permissions, so no
  permission or role counts change. Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Modules.EntityActivation

  # Same fixed system actor `Letflow.Scheduler.RecordDeadlineSweep` uses.
  @actor_id "00000000-0000-0000-0000-000000000000"

  @all_types [
    "fxm_legal_entity",
    "fxm_site",
    "fxm_unit",
    "fxm_unit_membership",
    "fxm_item",
    "fxm_uom",
    "fxm_ledger",
    "fxm_free"
  ]

  @impl true
  defmanifest(
    id: "fixture_managed",
    version: "0.1.0",
    depends_on: [],
    pack: "module_fixtures/managed_foundation.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: [
      "fxm_legal_entity",
      "fxm_site",
      "fxm_unit",
      "fxm_unit_membership",
      "fxm_item",
      "fxm_uom",
      "fxm_ledger"
    ]
  )

  @doc "Every entity type this fixture's pack defines, managed or not."
  @spec all_types() :: [String.t()]
  def all_types, do: @all_types

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @all_types)
  end

  @doc "Creates a record of `entity_type` through the owner's own path."
  @spec create_record(String.t(), map(), String.t()) :: {:ok, term()} | {:error, term()}
  def create_record(entity_type, field_values, prefix) do
    Records.create_record(
      %{
        entity_type: entity_type,
        field_values: field_values,
        actor_id: @actor_id,
        idempotency_key: Ecto.UUID.generate()
      },
      prefix,
      ManagedTypes.owner_for!(__MODULE__)
    )
  end

  @doc "Replaces a record's `field_values` through the owner's own path."
  @spec update_record(String.t(), Ecto.UUID.t(), map(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def update_record(entity_type, record_id, field_values, prefix) do
    Records.update_record(
      %{
        entity_type: entity_type,
        record_id: record_id,
        field_values: field_values,
        actor_id: @actor_id,
        idempotency_key: Ecto.UUID.generate()
      },
      prefix,
      ManagedTypes.owner_for!(__MODULE__)
    )
  end

  @doc "Deletes a record through the owner's own path."
  @spec delete_record(String.t(), Ecto.UUID.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def delete_record(entity_type, record_id, prefix) do
    Records.delete_record(
      %{
        entity_type: entity_type,
        record_id: record_id,
        actor_id: @actor_id,
        idempotency_key: Ecto.UUID.generate()
      },
      prefix,
      ManagedTypes.owner_for!(__MODULE__)
    )
  end
end

defmodule Letflow.Modules.FixtureManagedNoPack do
  @moduledoc """
  Test-only entry module (REQ-496 design §2.7, test T-19): declares a managed entity
  type but ships NO pack, so `Letflow.Modules.Installs.install/3` must fail with
  `{:error, {:pack_install_failed, {:managed_type_not_in_pack, "fxm_missing_type"}}}`
  and roll back. No router, no permissions, no `on_install`. Registered only in
  `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_managed_no_pack",
    version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["fxm_missing_type"]
  )
end
