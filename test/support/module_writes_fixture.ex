defmodule Letflow.ModuleWritesFixture do
  @moduledoc """
  GH #2590 / REQ-501 R3 test fixture: a tenant with the `fixture_ledger` module INSTALLED, the
  module-STAMPED process definition its pack shipped (`priv/module_fixtures/ledger_foundation.json`:
  `fxl_post_module`, `fxl_post_mixed`, `fxl_task_plain`; each a HUMAN_TASK `ht`) ACTIVATED, and a
  started instance with its pending task.

  The stamped version exists only because the install created it (no `create_owned/3` call, no
  Owner here: the static caller scans cover `test/support`). Builds on
  `Letflow.EntityWritesFixture` (users, entity types, observation helpers). Activation uses a
  `TENANT_ADMIN` activator, so the R3 activation checks run for real. R4b: the engine now executes the
  handlers of these definitions on completion.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Modules.TenantModule
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.ColumnPromotion

  @variants %{
    module: "fxl_post_module",
    mixed: "fxl_post_mixed",
    plain: "fxl_task_plain",
    mixed_first: "fxl_post_mixed_first",
    twenty: "fxl_post_twenty",
    svc_module: "fxl_svc_module",
    svc_mixed: "fxl_svc_mixed",
    svc_mixed_first: "fxl_svc_mixed_first",
    svc_two_handlers: "fxl_svc_two_handlers"
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
    base = tenant_with_cleanup!(slug_prefix)
    Fx.define_type!(base.schema, "stock_move", %{})
    Fx.define_type!(base.schema, "aaa_move", %{})
    install_ledger!(base.schema)
    base
  end

  defp tenant_with_cleanup!(slug_prefix) do
    base = Fx.tenant_case!(slug_prefix)
    tenant_id = base.tenant.tenant_id

    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
    end)

    base
  end

  @doc """
  GH #2590 R4b: like `tenant!/1` for a module that runs in Sandbox `:auto` mode (real commits and
  parallel connections). The caller enters auto mode first; the committed tenant and the rows an
  install writes to the global tables are removed on exit.
  """
  @spec committed_tenant!(String.t()) :: map()
  def committed_tenant!(slug_prefix) do
    base = Fx.committed_tenant_case!(slug_prefix)
    tenant_id = base.tenant.tenant_id

    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
      Fx.drop_committed_tenant!(tenant_id)
    end)

    Fx.define_type!(base.schema, "stock_move", %{})
    Fx.define_type!(base.schema, "aaa_move", %{})
    install_ledger!(base.schema)
    base
  end

  @doc """
  GH #2590 R4b: a case for the MISBEHAVING `fixture_ledger_rogue` module (its pack ships one
  stamped definition `fxr_<handler>` per rogue handler): tenant, the module installed, the
  definition activated, an instance started. `ctx.user` is activator and completer.
  """
  @spec rogue_case!(String.t(), String.t()) :: map()
  def rogue_case!(slug_prefix, handler) do
    base = tenant_with_cleanup!(slug_prefix)

    {:ok, _tenant_module} =
      Installs.install("fixture_ledger_rogue", Ecto.UUID.generate(),
        prefix: base.schema,
        rationale: "GH 2590 R4b fixture"
      )

    definition = activate_installed!(base.schema, base.user, "fxr_" <> handler)
    {instance_id, task} = Fx.start!(base.schema, definition)
    Map.merge(base, %{definition: definition, instance_id: instance_id, task: task})
  end

  @doc """
  The full case for `variant` (`:module`, `:mixed` or `:plain`): tenant, installed module, an
  ACTIVE stamped definition, a started instance and its pending task. `ctx.user` is both
  activator and completer.
  """
  @spec case!(String.t(), :module | :mixed | :plain | :mixed_first | :twenty) :: map()
  def case!(slug_prefix, variant) do
    base = tenant!(slug_prefix)
    definition = activate_installed!(base.schema, base.user, Map.fetch!(@variants, variant))
    {instance_id, task} = Fx.start!(base.schema, definition)
    Map.merge(base, %{definition: definition, instance_id: instance_id, task: task})
  end

  @doc """
  GH #2590 R5 (T-10): the full SERVICE_TASK case for `variant` (`:svc_module`, `:svc_mixed`,
  `:svc_mixed_first` or `:svc_two_handlers`): tenant, installed module, an ACTIVE stamped
  definition (activated through the real activation path, so the SERVICE_TASK fence is exercised),
  a started instance and its one dispatch row marked `"advanced"` (the state `attempt_dispatch/2`
  leaves, no HTTP). `ctx.user` is the activator; `ctx.dispatch` the row. Apply it with
  `Letflow.EntityWritesFixture.apply_http/2`.
  """
  @spec service_case!(String.t(), atom()) :: map()
  def service_case!(slug_prefix, variant) do
    base = tenant!(slug_prefix)
    definition = activate_installed!(base.schema, base.user, Map.fetch!(@variants, variant))
    advanced!(base, definition)
  end

  @doc "`service_case!/2` for the MISBEHAVING module's SERVICE_TASK definition `fxr_svc_<handler>`."
  @spec rogue_service_case!(String.t(), String.t()) :: map()
  def rogue_service_case!(slug_prefix, handler) do
    base = tenant_with_cleanup!(slug_prefix)

    {:ok, _tenant_module} =
      Installs.install("fixture_ledger_rogue", Ecto.UUID.generate(),
        prefix: base.schema,
        rationale: "GH 2590 R5 fixture"
      )

    definition = activate_installed!(base.schema, base.user, "fxr_svc_" <> handler)
    advanced!(base, definition)
  end

  @doc """
  GH #2590 R5 (#2695 lock order): a sub-process CHILD whose last node is the handler-calling
  SERVICE_TASK. The stamped child `fxl_svc_child` (HUMAN `ct`, then service `svc`) is started by
  a tenant parent's SUB_PROCESS node; the child's `ct` task is completed and its dispatch row is
  marked `"advanced"`. `ctx.instance_id` is the CHILD, `ctx.parent_id` the parent.
  """
  @spec subprocess_service_case!(String.t()) :: map()
  def subprocess_service_case!(slug_prefix) do
    base = tenant!(slug_prefix)
    schema = base.schema
    _child_def = activate_installed!(schema, base.user, "fxl_svc_child")

    parent_graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => "fxl_svc_child"}
        },
        %{"id" => "after", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => "after"},
        %{"id" => "p2", "source" => "after", "target" => "end"}
      ]
    }

    {:ok, parent_row} =
      Definitions.create(
        %{
          name: Fx.unique("gh2590-r5-parent"),
          version: "1.0",
          graph: parent_graph,
          created_by: base.user.id
        },
        prefix: schema
      )

    {:ok, %{definition: parent}} = Definitions.activate(parent_row.id, prefix: schema)

    {:ok, %{instance_id: parent_id}} =
      Letflow.Engine.create(
        %{
          definition_id: parent.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("gh2590-r5-parent-start")
        },
        prefix: schema
      )

    child_id =
      Repo.one!(
        from(p in Letflow.EventStore.InstanceProjection,
          where: p.parent_instance_id == ^parent_id,
          select: p.instance_id
        ),
        prefix: schema
      )

    child_task = Fx.pending_task!(schema, child_id)

    {:ok, _} =
      Letflow.Engine.complete_task(
        child_task.id,
        %{
          output_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("gh2590-r5-child-complete")
        },
        prefix: schema
      )

    row =
      Repo.one!(
        from(d in Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch,
          where: d.instance_id == ^child_id
        ),
        prefix: schema
      )

    dispatch =
      row |> Ecto.Changeset.change(%{status: "advanced"}) |> Repo.update!(prefix: schema)

    Map.merge(base, %{instance_id: child_id, parent_id: parent_id, dispatch: dispatch})
  end

  defp advanced!(base, definition) do
    pending = Fx.start_service_instance!(base, definition)

    dispatch =
      pending.dispatch
      |> Ecto.Changeset.change(%{status: "advanced"})
      |> Repo.update!(prefix: base.schema)

    %{pending | dispatch: dispatch}
  end

  @doc "Replaces the pinned snapshot graph of the case's instance with `fun.(graph)` (a hand edit)."
  @spec tamper_snapshot!(map(), (map() -> map())) :: :ok
  def tamper_snapshot!(ctx, fun) do
    snapshot = Repo.get!(InstanceDefinitionSnapshot, ctx.instance_id, prefix: ctx.schema)

    snapshot
    |> Ecto.Changeset.change(graph: fun.(snapshot.graph))
    |> Repo.update!(prefix: ctx.schema)

    :ok
  end

  @doc """
  Overwrites the manifest hash STAMPED on the case's definition row. The row is immutable to the
  application and guarded by a trigger, so the trigger is disabled inside the throwaway tenant
  schema (rolled back with the test's transaction; not for `:auto` mode cases).
  """
  @spec set_stamp_hash!(map(), String.t()) :: :ok
  def set_stamp_hash!(ctx, hash) do
    Repo.query!(~s(ALTER TABLE "#{ctx.schema}"."process_definitions" DISABLE TRIGGER USER))

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^ctx.definition.id),
        [set: [owner_manifest_hash: hash]],
        prefix: ctx.schema
      )

    :ok
  end

  @doc "Overwrites the install-time manifest hash of `module_id` in the tenant (a tampered or stale row)."
  @spec set_installed_hash!(String.t(), String.t(), String.t() | nil) :: :ok
  def set_installed_hash!(schema, module_id, hash) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == ^module_id),
        [set: [manifest_hash: hash]],
        prefix: schema
      )

    :ok
  end
end
