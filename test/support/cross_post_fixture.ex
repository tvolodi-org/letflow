defmodule Letflow.CrossPostFixture do
  @moduledoc """
  REQ-758 test fixture: a throwaway tenant with BOTH test-only modules INSTALLED (`fixture_ledger_post`
  = N first, then `fixture_xpost_owner` = M, which depends on it), their bookkeeping types managed,
  ledger storage for both ledger ids, and a process definition STAMPED BY M (a HUMAN_TASK `ht` with
  the `module_writes` lines given) activated through the real activation path, one instance started.

  Same stamp technique as `Letflow.LedgerPostFixture` (the module ships a pack without definitions,
  so the stamp is written by hand on the draft row inside the throwaway schema). The existing
  `LedgerPostFixture.case!/3` is not changed; the lines and postings of N come from that module.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.LedgerPostFixture, as: LPF
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.FixtureXpostOwner
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @own "fixture_xpost_owner"

  def own_ledger, do: @own

  @doc "A `module_writes` line calling `post_own` of M."
  @spec own_line(map()) :: map()
  def own_line(args \\ %{}) do
    %{
      "module" => @own,
      "handler" => "post_own",
      "args" =>
        Map.new(Map.merge(%{"note" => "n"}, args), fn {name, value} ->
          {name, %{"const" => value}}
        end)
    }
  end

  @doc "M's posting line (writes no bookkeeping row beyond the note) for `posting`."
  @spec own_post_line(map()) :: map()
  def own_post_line(posting), do: own_line(%{"posting" => posting})

  @doc """
  The case for a node with `lines`. Options: `:holder_roles` (default `["TENANT_ADMIN"]`), `:committed`
  (Sandbox `:auto` mode, a really committed tenant dropped on exit).
  """
  @spec case!(String.t(), [map()], keyword()) :: map()
  def case!(slug_prefix, lines, opts \\ []) do
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

    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
    end)

    for module <- ["fixture_ledger_post", @own] do
      {:ok, _} =
        Installs.install(module, Ecto.UUID.generate(),
          prefix: schema,
          rationale: "REQ-758 fixture"
        )
    end

    for ledger_id <- ["fixture_ledger_post", @own] do
      Letflow.LedgerFixture.ensure_storage!(schema, ledger_id)
    end

    for type <- ["fxlp_note", "fxxp_note"] do
      {:ok, _active} =
        Letflow.Entities.Definitions.activate_definition(
          type,
          Ecto.UUID.generate(),
          "REQ-758 fixture",
          schema
        )
    end

    holder =
      TokenMintFixture.role_holder!(schema, Keyword.get(opts, :holder_roles, ["TENANT_ADMIN"]))

    definition = activate!(schema, base.user, Fx.graph([]) |> put_lines(lines))
    {instance_id, task} = Fx.start!(schema, definition)

    Map.merge(base, %{
      completer: holder,
      definition: definition,
      instance_id: instance_id,
      task: task
    })
  end

  @doc """
  Activates a stamped draft with `lines` WITHOUT raising: returns `Definitions.activate/2`'s result
  (`{:ok, _}` or `{:error, ...}`) in the tenant of `ctx`. Options: `:stamp` (`:owner`, the default,
  `:none` for a draft that carries no stamp), `:tamper` (edit the graph after
  the stamp hash is taken), `:node` (`:human`, the default, or `:service`) and `:consent`.
  """
  @spec try_activate(map(), [map()], keyword()) :: term()
  def try_activate(ctx, lines, opts \\ []) do
    graph =
      case Keyword.get(opts, :node, :human) do
        :human ->
          Fx.graph([]) |> put_lines(lines)

        :service ->
          attrs =
            if Keyword.get(opts, :consent, true), do: %{"ledger_post_consent" => true}, else: %{}

          Fx.service_graph([], Map.put(attrs, "module_writes", lines))
      end

    stamp_and_activate(ctx.schema, ctx.user, graph, opts)
  end

  defp tampered(graph) do
    update_in(graph, ["nodes"], fn nodes ->
      Enum.map(nodes, fn
        %{"id" => "end"} = node -> Map.put(node, "label", "edited after the stamp")
        node -> node
      end)
    end)
  end

  defp put_lines(graph, lines) do
    update_in(graph, ["nodes"], fn nodes ->
      Enum.map(nodes, fn
        %{"id" => "ht", "attributes" => attrs} = node ->
          %{
            node
            | "attributes" =>
                attrs |> Map.delete("entity_writes") |> Map.put("module_writes", lines)
          }

        node ->
          node
      end)
    end)
  end

  defp activate!(schema, user, graph) do
    {:ok, %{definition: activated}} = stamp_and_activate(schema, user, graph, [])
    activated
  end

  defp stamp_and_activate(schema, user, graph, opts) do
    {:ok, draft} =
      Definitions.create(
        %{name: Fx.unique("req758"), version: "1.0", graph: graph, created_by: user.id},
        prefix: schema
      )

    {:ok, manifest_hash} = Catalog.manifest_hash(FixtureXpostOwner)

    Repo.query!(~s(ALTER TABLE "#{schema}"."process_definitions" DISABLE TRIGGER USER))

    stamp_set =
      case Keyword.get(opts, :stamp, :owner) do
        :none ->
          []

        :owner ->
          [
            owner_module: @own,
            owner_module_version: FixtureXpostOwner.manifest().version,
            owner_manifest_hash: manifest_hash,
            owner_body_hash: OwnerStamp.graph_hash(draft.graph)
          ]
      end

    set =
      if Keyword.get(opts, :tamper, false),
        do: [graph: tampered(draft.graph)] ++ stamp_set,
        else: stamp_set

    if set != [] do
      {1, _} =
        Repo.update_all(from(d in ProcessDefinition, where: d.id == ^draft.id), [set: set],
          prefix: schema
        )
    end

    Repo.query!(~s(ALTER TABLE "#{schema}"."process_definitions" ENABLE TRIGGER USER))

    activator =
      Activator.from_auth_context(
        %{user_id: user.id, roles: ["TENANT_ADMIN"], credential: :oidc},
        false
      )

    Definitions.activate(draft.id, prefix: schema, activator: activator)
  end

  @doc "Completes the case's task as the holder (see `LedgerPostFixture.complete/2`)."
  defdelegate complete(ctx, opts \\ []), to: LPF

  @doc "Row counts of the ledger tables: `{entries, legs, balances, counters}`."
  defdelegate ledger_counts(schema), to: LPF

  @doc "N's `post_alpha` line posting `posting` and writing no bookkeeping row."
  def n_line(posting), do: LPF.post_line("post_alpha", posting)

  @doc "A posting (string keys) of `cause` for `item`, ledger id of the registration fixed by the handler."
  defdelegate posting(cause, item, quantity, extra \\ %{}), to: LPF
end
