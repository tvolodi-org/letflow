defmodule Letflow.ModuleWritesFixture do
  @moduledoc """
  GH #2590 / REQ-501 R3 test fixture: a tenant with the `fixture_ledger` module INSTALLED, the
  module-STAMPED process definition its pack shipped (`priv/module_fixtures/ledger_foundation.json`:
  `fxl_post_module`, `fxl_post_mixed`, `fxl_task_plain`; each a HUMAN_TASK `ht`) ACTIVATED, and a
  started instance with its pending task.

  The stamped version exists only because the install created it (no `create_owned/3` call, no
  Owner here: the static caller scans cover `test/support`). Builds on
  `Letflow.EntityWritesFixture` (users, entity types, observation helpers). Activation uses a
  `TENANT_ADMIN` activator, so the R3 activation checks run for real. Nothing here executes a
  handler.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.ColumnPromotion

  @variants %{
    module: "fxl_post_module",
    mixed: "fxl_post_mixed",
    plain: "fxl_task_plain"
  }

  @doc "A valid `post_entry` line (both required arguments), as the pack declares it."
  @spec line() :: map()
  def line do
    %{
      "module" => "fixture_ledger",
      "handler" => "post_entry",
      "args" => %{"item" => %{"var" => "label"}, "quantity" => %{"const" => 1}}
    }
  end

  @doc "START -> HUMAN_TASK `ht` declaring `module_writes` (and `entity_writes` when given) -> END."
  @spec graph([map()], [map()] | nil) :: map()
  def graph(module_lines, entity_lines \\ nil) do
    attributes =
      %{"role" => "REVIEWER", "module_writes" => module_lines}
      |> then(fn attrs ->
        if entity_lines, do: Map.put(attrs, "entity_writes", entity_lines), else: attrs
      end)

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => attributes},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "end"}
      ]
    }
  end

  @doc "Installs the `fixture_ledger` module in `schema`."
  @spec install_ledger!(String.t()) :: struct()
  def install_ledger!(schema) do
    {:ok, tenant_module} =
      Installs.install("fixture_ledger", Ecto.UUID.generate(),
        prefix: schema,
        rationale: "GH 2590 R3 fixture"
      )

    tenant_module
  end

  @doc """
  Activates the pack's stamped draft named `process_key` as `activator_user` (`TENANT_ADMIN`)
  and returns the activated row.
  """
  @spec activate_installed!(String.t(), struct(), String.t()) :: struct()
  def activate_installed!(schema, activator_user, process_key) do
    draft = Repo.one!(from(d in ProcessDefinition, where: d.name == ^process_key), prefix: schema)

    activator =
      Activator.from_auth_context(%{user_id: activator_user.id, roles: ["TENANT_ADMIN"]}, false)

    {:ok, %{definition: activated}} =
      Definitions.activate(draft.id, prefix: schema, activator: activator)

    activated
  end

  @doc """
  The tenant of a case, with the module installed and a `stock_move` entity type, before any
  definition is activated. Registers the cleanup of the committed rows an install writes.
  """
  @spec tenant!(String.t()) :: map()
  def tenant!(slug_prefix) do
    base = Fx.tenant_case!(slug_prefix)
    tenant_id = base.tenant.tenant_id

    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
    end)

    Fx.define_type!(base.schema, "stock_move", %{})
    install_ledger!(base.schema)
    base
  end

  @doc """
  The full case for `variant` (`:module`, `:mixed` or `:plain`): tenant, installed module, an
  ACTIVE stamped definition, a started instance and its pending task. `ctx.user` is both
  activator and completer.
  """
  @spec case!(String.t(), :module | :mixed | :plain) :: map()
  def case!(slug_prefix, variant) do
    base = tenant!(slug_prefix)
    definition = activate_installed!(base.schema, base.user, Map.fetch!(@variants, variant))
    {instance_id, task} = Fx.start!(base.schema, definition)
    Map.merge(base, %{definition: definition, instance_id: instance_id, task: task})
  end
end
