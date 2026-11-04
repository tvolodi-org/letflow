defmodule Letflow.LedgerPostFixture do
  @moduledoc """
  REQ-685 (slice L3b) test fixture: a throwaway tenant with the test-only module
  `fixture_ledger_post` INSTALLED, its bookkeeping type `fxlp_note` managed by it, a module-STAMPED
  process definition (a HUMAN_TASK `ht` with the `module_writes` lines given) ACTIVATED through the
  real activation path, a started instance and its pending task.

  The module ships no pack, so the stamp is written by hand on the draft row (the row guard trigger
  is disabled inside the throwaway schema, rolled back with the test's transaction), exactly the
  values an install would have written: module id, version, compiled manifest hash and the graph
  hash. Builds on `Letflow.EntityWritesFixture`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Engine
  alias Letflow.Entities.HandlerWrites
  alias Letflow.Ledger.HandlerPost
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Identity.GroupMember
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.FixtureLedgerPost
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.Support.TokenMintFixture

  @alpha "fixture_ledger_post"
  @beta "fixture_ledger_post:beta"

  def alpha, do: @alpha
  def beta, do: @beta

  @doc "A `module_writes` line calling `handler` (`post_alpha`, `post_beta`, `plain`) with `args`."
  @spec line(String.t(), map()) :: map()
  def line(handler, args \\ %{}) do
    %{
      "module" => "fixture_ledger_post",
      "handler" => handler,
      "args" =>
        Map.new(Map.merge(%{"note" => "n"}, args), fn {name, value} ->
          {name, %{"const" => value}}
        end)
    }
  end

  @doc "A posting map (string keys) for `ledger_id` with one leg."
  @spec posting(String.t(), String.t(), String.t(), map()) :: map()
  def posting(cause, item, quantity, extra \\ %{}) do
    Map.merge(
      %{
        "cause" => cause,
        "document_type" => "doc",
        "document_id" => "d1",
        "legs" => [%{"k" => [item, ""], "quantity" => quantity, "unit_ref" => "u1"}]
      },
      extra
    )
  end

  @doc """
  The case for a node with `module_lines`. Options: `:holder_roles` (default `["TENANT_ADMIN"]`)
  are the roles of the completing user, granted through group membership. `committed: true` (REQ-686,
  for tests in Sandbox `:auto` mode) provisions a tenant that is really committed and dropped on exit.
  """
  @spec case!(String.t(), [map()], keyword()) :: map()
  def case!(slug_prefix, module_lines, opts \\ []) do
    base =
      if Keyword.get(opts, :committed, false) do
        committed = Fx.committed_tenant_case!(slug_prefix)
        ExUnit.Callbacks.on_exit(fn -> Fx.drop_committed_tenant!(committed.tenant.tenant_id) end)
        committed
      else
        Fx.tenant_case!(slug_prefix)
      end

    schema = base.schema
    tenant_id = base.tenant.tenant_id

    # An install writes rows to global tables that the sandbox rollback does not own.
    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
    end)

    {:ok, _tenant_module} =
      Installs.install("fixture_ledger_post", Ecto.UUID.generate(),
        prefix: schema,
        rationale: "REQ-685 fixture"
      )

    # REQ-710: the posting path never makes partitions.
    for ledger_id <- ["fixture_ledger_post", "fixture_ledger_post:beta"] do
      Letflow.LedgerFixture.ensure_storage!(schema, ledger_id)
    end

    {:ok, _active} =
      Letflow.Entities.Definitions.activate_definition(
        "fxlp_note",
        Ecto.UUID.generate(),
        "REQ-685 fixture",
        schema
      )

    holder =
      TokenMintFixture.role_holder!(schema, Keyword.get(opts, :holder_roles, ["TENANT_ADMIN"]))

    definition = activate!(schema, base.user, Fx.graph([]) |> put_lines(module_lines))
    {instance_id, task} = Fx.start!(schema, definition)

    Map.merge(base, %{
      completer: holder,
      definition: definition,
      instance_id: instance_id,
      task: task
    })
  end

  @doc """
  REQ-686: another stamped definition with `module_lines` in the case's tenant, one instance of
  it started; returns the case with that definition, instance and task (the completer is kept).
  """
  @spec more_task!(map(), [map()]) :: map()
  def more_task!(ctx, module_lines) do
    definition = activate!(ctx.schema, ctx.user, Fx.graph([]) |> put_lines(module_lines))
    {instance_id, task} = Fx.start!(ctx.schema, definition)
    %{ctx | definition: definition, instance_id: instance_id, task: task}
  end

  defp put_lines(graph, lines) do
    update_in(graph, ["nodes"], fn nodes ->
      Enum.map(nodes, fn
        %{"id" => "ht"} = node -> put_in(node, ["attributes", "module_writes"], lines)
        node -> node
      end)
    end)
    |> then(fn graph ->
      update_in(graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "ht", "attributes" => attrs} = node ->
            %{node | "attributes" => Map.delete(attrs, "entity_writes")}

          node ->
            node
        end)
      end)
    end)
  end

  @doc """
  REQ-688: the SERVICE_TASK case. A stamped definition START -> SERVICE_TASK `svc` (HTTP-bound,
  holding `module_lines`; `ledger_post_consent: true` unless `consent: false`) -> END, activated
  through the real activation path by the role holder (`ctx.completer`, whose roles the run-time
  authority step re-reads) with the activator's credential `:credential` (default
  `:oidc`), an instance started and its dispatch row marked `"advanced"`. Apply it with
  `Letflow.EntityWritesFixture.apply_http/2`. Options: `:committed`, `:holder_roles`.
  """
  @spec service_case!(String.t(), [map()], keyword()) :: map()
  def service_case!(slug_prefix, module_lines, opts \\ []) do
    base = case!(slug_prefix, [], opts)
    more_service!(base, module_lines, opts)
  end

  @doc "REQ-688: another SERVICE_TASK definition and instance in the tenant of `ctx` (see `service_case!/3`)."
  @spec more_service!(map(), [map()], keyword()) :: map()
  def more_service!(base, module_lines, opts \\ []) do
    attrs = if Keyword.get(opts, :consent, true), do: %{"ledger_post_consent" => true}, else: %{}

    graph = Fx.service_graph([], Map.put(attrs, "module_writes", module_lines))

    definition =
      activate!(base.schema, base.completer, graph, Keyword.get(opts, :credential, :oidc))

    pending = Fx.start_service_instance!(base, definition)

    dispatch =
      pending.dispatch
      |> Ecto.Changeset.change(%{status: :advanced})
      |> Repo.update!(prefix: base.schema)

    %{pending | dispatch: dispatch}
  end

  defp activate!(schema, activator_user, graph, credential \\ :oidc) do
    {:ok, draft} =
      Definitions.create(
        %{
          name: Fx.unique("req685"),
          version: "1.0",
          graph: graph,
          created_by: activator_user.id
        },
        prefix: schema
      )

    {:ok, manifest_hash} = Catalog.manifest_hash(FixtureLedgerPost)

    Repo.query!(~s(ALTER TABLE "#{schema}"."process_definitions" DISABLE TRIGGER USER))

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^draft.id),
        [
          set: [
            owner_module: "fixture_ledger_post",
            owner_module_version: FixtureLedgerPost.manifest().version,
            owner_manifest_hash: manifest_hash,
            owner_body_hash: OwnerStamp.graph_hash(draft.graph)
          ]
        ],
        prefix: schema
      )

    Repo.query!(~s(ALTER TABLE "#{schema}"."process_definitions" ENABLE TRIGGER USER))

    activator =
      Activator.from_auth_context(
        %{user_id: activator_user.id, roles: ["TENANT_ADMIN"], credential: credential},
        false
      )

    {:ok, %{definition: activated}} =
      Definitions.activate(draft.id, prefix: schema, activator: activator)

    activated
  end

  @doc """
  Builds the handler calls of `lines` the way `StepWrites` does (`HandlerWrites.build_call/4` per
  line, then the one `HandlerPost.lock_steps/2`) and runs them in ONE transaction. Returns the
  `Repo.transaction/1` result, so a refusal is seen at the Multi level as
  `{:error, step, reason, changes}`. Options: `:credential` (default `:oidc`), `:subject` (the
  user, default the completer), `:origin` (default `{:task, task_id}`).
  """
  @spec run_lines(map(), [map()], keyword()) :: term()
  def run_lines(ctx, lines, opts \\ []) do
    ctx
    |> build_lines(lines, opts)
    |> HandlerPost.lock_steps(lines, Keyword.get(opts, :prelocked))
    |> Repo.transaction()
  end

  @doc "The handler-call Multi of `lines` WITHOUT the lock step (see `run_lines/3`)."
  @spec build_lines(map(), [map()], keyword()) :: Ecto.Multi.t()
  def build_lines(ctx, lines, opts \\ []) do
    base = base_attrs(ctx, opts)

    lines
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {line, index}, acc ->
      HandlerWrites.build_call(acc, Map.put(base, :line_index, index), line, %{})
    end)
  end

  @doc """
  REQ-688: runs the ledger pre-step (`HandlerPost.prelock/2`) for `lines` in one transaction and
  returns its result (`%{ledger_ids:, keys:}`). Options as `build_lines/3` (use `origin:
  {:dispatch, id}` and `consent: true` for the service origin).
  """
  @spec prelock_set(map(), [map()], keyword()) :: map()
  def prelock_set(ctx, lines, opts \\ []) do
    base = base_attrs(ctx, opts)

    entries =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} -> {Map.put(base, :line_index, index), line} end)

    {:ok, set} = Repo.transaction(fn -> elem(HandlerPost.prelock(entries, %{}), 1) end)
    set
  end

  defp base_attrs(ctx, opts) do
    {:ok, manifest_hash} = Catalog.manifest_hash(FixtureLedgerPost)
    subject = Keyword.get(opts, :subject, ctx.completer)

    %{
      prefix: ctx.schema,
      instance_id: ctx.instance_id,
      origin: Keyword.get(opts, :origin, {:task, ctx.task.id}),
      node_id: "ht",
      definition_id: ctx.definition.id,
      definition_version: ctx.definition.version,
      actor_id: subject.id,
      subject_id: subject.id,
      credential: Keyword.get(opts, :credential, :oidc),
      activator_id: subject.id,
      manifest_hash: manifest_hash,
      ledger_consent: Keyword.get(opts, :consent, false),
      ledger_prelock: Keyword.get(opts, :prelocked)
    }
  end

  @doc "A `post_alpha`/`post_beta` line that posts `posting` and writes no bookkeeping row."
  @spec post_line(String.t(), map(), map()) :: map()
  def post_line(handler, posting, extra \\ %{}),
    do: line(handler, Map.merge(%{"posting" => posting, "skip_note" => true}, extra))

  @doc "Completes the case's task as the holder; `opts` are merged over `prefix:` and `credential: :oidc`."
  @spec complete(map(), keyword()) :: term()
  def complete(ctx, opts \\ []) do
    {key, opts} = Keyword.pop(opts, :idempotency_key, Fx.unique("req685-complete"))

    Engine.complete_task(
      ctx.task.id,
      %{output_variables: %{}, actor_id: ctx.completer.id, idempotency_key: key},
      Keyword.merge([prefix: ctx.schema, credential: :oidc], opts)
    )
  end

  @doc "Removes the completer's group memberships (a role revoked after the task was claimed)."
  @spec revoke_roles!(map()) :: :ok
  def revoke_roles!(ctx) do
    Repo.delete_all(from(m in GroupMember, where: m.user_id == ^ctx.completer.id),
      prefix: ctx.schema
    )

    :ok
  end

  @doc "Row counts of the ledger tables of the tenant: `{entries, legs, balances, counters}`."
  @spec ledger_counts(String.t()) :: {integer(), integer(), integer(), integer()}
  def ledger_counts(schema) do
    [e, l, b, c] =
      for table <- ~w(ledger_entry ledger_leg ledger_balance ledger_counter) do
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{schema}\".\"#{table}\"")
        n
      end

    {e, l, b, c}
  end
end
