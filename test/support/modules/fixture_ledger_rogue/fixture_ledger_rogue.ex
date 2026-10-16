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
      },
      %{
        name: "forge_prefix",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :forge_prefix},
        targets: ["fxr_thing"],
        args: %{"prefix" => %{required: true}}
      },
      %{
        name: "forge_handler",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :forge_handler},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "run_full",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :run_full},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "run_aliased",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :run_aliased},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "run_imported",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :run_imported},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "insert_all_op",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :insert_all_op},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "throws",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :throws},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "exits",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :exits},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "drop_policy",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :drop_policy},
        targets: ["fxr_thing"],
        args: %{}
      },
      %{
        name: "run_after_create",
        function: {Letflow.Modules.FixtureLedgerRogue.Handlers, :run_after_create},
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

  alias Ecto.Multi, as: AliasedMulti
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

  # S1: a forged context. Map.merge on the struct keeps it a HandlerContext with a changed field.
  def forge_prefix(multi, ctx, %{"prefix" => prefix}) do
    forged = Map.merge(ctx, %{prefix: prefix})
    write_thing(multi, forged)
  end

  def forge_handler(multi, ctx, _args) do
    forged =
      Map.merge(ctx, %{
        handler: %{
          module_id: "fixture_ledger",
          name: "post_entry",
          targets: ["fxl_ledger", "fxl_balance"]
        }
      })

    case HandlerWrites.create(multi, forged, %{
           entity_type: "fxl_ledger",
           field_values: %{"item" => "x"}
         }) do
      {:ok, multi} -> {:ok, multi}
      {:error, _} -> {:error, :not_permitted}
    end
  end

  # S2: a step with a live repo, through each way of naming Ecto.Multi.
  def run_full(multi, _ctx, _args),
    do:
      {:ok,
       Ecto.Multi.run(multi, {:line, 21, :x}, fn repo, _ -> {:ok, repo.query!("select 1")} end)}

  def run_aliased(multi, _ctx, _args),
    do:
      {:ok,
       AliasedMulti.run(multi, {:line, 21, :x}, fn repo, _ -> {:ok, repo.query!("select 1")} end)}

  def run_imported(multi, _ctx, _args) do
    import Ecto.Multi, only: [run: 3]
    {:ok, run(multi, {:line, 21, :x}, fn repo, _ -> {:ok, repo.query!("select 1")} end)}
  end

  def insert_all_op(multi, _ctx, _args),
    do: {:ok, Ecto.Multi.insert_all(multi, {:line, 21, :x}, "entity_record_latest", [])}

  # a legitimate create/3 followed by a smuggled step
  def run_after_create(multi, ctx, _args) do
    with {:ok, multi} <-
           HandlerWrites.create(multi, ctx, %{
             entity_type: "fxr_thing",
             field_values: %{"item" => "x"}
           }) do
      {:ok,
       Ecto.Multi.run(multi, {:line, 22, :x}, fn repo, _ -> {:ok, repo.query!("select 1")} end)}
    else
      {:error, _} -> {:error, :not_permitted}
    end
  end

  # throw / exit instead of a raise (SECURITY re-review of R4a: safe_call caught only raises)
  def throws(_multi, _ctx, _args), do: throw(:escape)

  def exits(_multi, _ctx, _args), do: exit(:gone)

  # a legitimate create/3 whose `:policy` step is then dropped from the returned Multi (the
  # managed-by / scope re-read): the executor requires ALL the steps create/3 produced per key
  def drop_policy(multi, ctx, _args) do
    with {:ok, multi} <-
           HandlerWrites.create(multi, ctx, %{
             entity_type: "fxr_thing",
             field_values: %{"item" => "x"}
           }) do
      {:ok,
       %{multi | operations: Enum.reject(multi.operations, &match?({{:line, _, :policy}, _}, &1))}}
    else
      {:error, _} -> {:error, :not_permitted}
    end
  end

  defp write_thing(multi, ctx) do
    case HandlerWrites.create(multi, ctx, %{
           entity_type: "fxr_thing",
           field_values: %{"item" => "x"}
         }) do
      {:ok, multi} -> {:ok, multi}
      {:error, _} -> {:error, :not_permitted}
    end
  end
end
