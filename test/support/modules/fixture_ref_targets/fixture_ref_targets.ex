defmodule Letflow.Modules.FixtureRefTargets do
  @moduledoc """
  Test-only entry module (REQ-636, decision 0070 slice C). Manages two types, `frt_target` and
  `frt_other`, each with `name :: string` and `active :: boolean`; only `frt_target` is opted in
  as a reference target (`reference_targets`). `lookup/2` and `active?/2` read through
  `Letflow.Modules.ReadApi`, as the production modules do. `create_record/3` and `update_record/4`
  are the owner's own path (the `FixtureManaged` pattern). No router, no permissions. Registered
  only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.ReadApi

  @actor_id "00000000-0000-0000-0000-000000000000"
  @types ["frt_target", "frt_other"]

  @impl true
  defmanifest(
    id: "fixture_ref_targets",
    version: "0.1.0",
    depends_on: [],
    pack: "module_fixtures/reference_targets.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["frt_target", "frt_other"],
    reference_targets: ["frt_target"]
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @types)
  end

  @doc "The live record `id` of either type, or `{:error, :not_found}`."
  @spec lookup(String.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def lookup(prefix, id), do: ReadApi.lookup(prefix, id, @types)

  @doc "True only for a live record of either type whose `active` field is `true`."
  @spec active?(String.t(), term()) :: boolean()
  def active?(prefix, id), do: ReadApi.active?(prefix, id, @types)

  @doc "Creates a record through the owner's own path."
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
  @spec update_record(String.t(), Ecto.UUID.t(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def update_record(entity_type, record_id, prefix, field_values) do
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
end
