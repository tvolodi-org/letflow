defmodule Letflow.Modules.FixtureDataStep do
  @moduledoc """
  Test-only entry module (REQ-773 / T-1581). Its pack (`priv/module_fixtures/data_step.json`) holds
  one managed type, `fds_item` (`name`, a required `status`, an optional `label`), at the 1.2.0
  shape. The manifest is at 1.2.0 with two declarative steps from 1.0.0: `s1` (1.0.0 to 1.1.0,
  `set_default` of `status`) and `s2` (1.1.0 to 1.2.0, `copy_field` of `name` into `label`). A test
  installs the module (the 1.2.0 shape), then ages the tenant row and the active definition to
  1.0.0 (`name` only) and upgrades it through the real routes. No router, no permissions.
  Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.Step

  @impl true
  defmanifest(
    id: "fixture_data_step",
    version: "1.2.0",
    min_upgradable_from: "1.0.0",
    depends_on: [],
    pack: "module_fixtures/data_step.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["fds_item"],
    migrations: [
      %Step{
        id: "s1",
        from: "1.0.0",
        to: "1.1.0",
        kind: :declarative,
        up: %{op: :set_default, type: "fds_item", field: "status", value: "new"},
        down: :irreversible,
        lossy: false
      },
      %Step{
        id: "s2",
        from: "1.1.0",
        to: "1.2.0",
        kind: :declarative,
        up: %{
          op: :copy_field,
          type: "fds_item",
          from: "name",
          to: "label",
          transform: :trim
        },
        down: :irreversible,
        lossy: false
      }
    ]
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, ["fds_item"])
  end

  @actor_id "00000000-0000-0000-0000-000000000000"

  @doc "Creates a record of `fds_item` through the owner's own path (the managed-type authority)."
  @spec create_record(map(), String.t()) :: {:ok, term()} | {:error, term()}
  def create_record(field_values, prefix) do
    Records.create_record(
      %{
        entity_type: "fds_item",
        field_values: field_values,
        actor_id: @actor_id,
        idempotency_key: Ecto.UUID.generate()
      },
      prefix,
      ManagedTypes.owner_for!(__MODULE__)
    )
  end
end
