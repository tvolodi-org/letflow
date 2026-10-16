defmodule Letflow.Modules.FixtureLedgerRogue do
  @moduledoc """
  Test-only entry module (GH #2590 / REQ-501 R4a): a module whose handlers MISBEHAVE on purpose,
  so the platform's defences have something to catch: a handler returning a non-Multi, raising,
  adding a Multi step outside its call's range or with a loose name, denying, and one trying
  to write ANOTHER module's managed type (`fxl_ledger`) through `HandlerWrites.create/3`.

  This file deliberately VIOLATES the handler-purity scan H4
  (`test/letflow/entities/handler_writes_callers_test.exs`), which lists it as the negative
  control (the scan must flag it; every other handler file must be clean). Never copy it.
  Registered only in `config/test.exs`; its pack defines the one managed type `fxr_thing`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.EntityActivation

  @impl true
  defmanifest(
    id: "fixture_ledger_rogue",
    version: "0.1.0",
    depends_on: [],
    pack: "module_fixtures/ledger_rogue.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["fxr_thing"],
    write_handlers: [
      %{
        name: "bad_return",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :bad_return},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "raises",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :raises},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "out_of_range_step",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :out_of_range_step},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "loose_step",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :loose_step},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "denies",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :denies},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "invalid",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :invalid},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "writes_foreign_type",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :writes_foreign_type},
        targets: ["fxr_thing"],
        args: %{}
      }
    ]
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, ["fxr_thing"])
  end
end

defmodule Letflow.Modules.FixtureLedgerRogue.Handlers do
  @moduledoc "Misbehaving handlers of `Letflow.Modules.FixtureLedgerRogue` (negative controls)."

  alias Letflow.Entities.HandlerWrites

  def bad_return(_multi, _ctx, _args), do: :oops

  def raises(_multi, _ctx, _args), do: raise("boom with a secret detail")

  # a step name outside the call's own {:line, key, _} range
  def out_of_range_step(multi, _ctx, _args),
    do: {:ok, Ecto.Multi.put(multi, {:line, 9999, :x}, 1)}

  # a loose (non-{:line, _, _}) step name
  def loose_step(multi, _ctx, _args), do: {:ok, Ecto.Multi.put(multi, :loose, 1)}

  def denies(_multi, _ctx, _args), do: {:error, :not_permitted}

  def invalid(_multi, _ctx, _args), do: {:error, :invalid_arguments}

  # another module's managed type: the platform refuses it (:target_not_registered)
  def writes_foreign_type(multi, ctx, _args) do
    case HandlerWrites.create(multi, ctx, %{
           entity_type: "fxl_ledger",
           field_values: %{"item" => "x"}
         }) do
      {:ok, multi} -> {:ok, multi}
      {:error, _} -> {:error, :not_permitted}
    end
  end
end
