defmodule Letflow.Definitions.ModuleCallsTest do
  @moduledoc """
  T-3045 (D-204 task P2a, `docs/design-module-process-conversion.md` section 6.1): the step kind
  `module_call` on a SERVICE_TASK -- parse, graph checks and the activation fence. The run time of
  the step is P2b, so a step that passes every check is refused at activation with
  `:module_call_runtime_unavailable` (nothing may be switched on that the engine cannot run).

  The FAKED module entry of P1 is `fixture_ledger_post.post_alpha` (the one converted handler of
  the test-only fixture module `Letflow.Modules.FixtureLedgerPost`; permission `:FxlpPost`).

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ModuleCalls
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Definitions.StartPermission
  alias Letflow.Engine.ServiceTask
  alias Letflow.Engine.WriteTargets
  alias Letflow.Identity.User
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @function "fixture_ledger_post.post_alpha"

  # ── helpers ───────────────────────────────────────────────────────────────────────────────

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp tenant!(slug_prefix, install?) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    if install? do
      {:ok, _tenant_module} =
        Installs.install("fixture_ledger_post", Ecto.UUID.generate(),
          prefix: tenant.schema_name,
          rationale: "T-3045 module_call fence"
        )
    end

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "t3045-#{Ecto.UUID.generate()}",
        display_name: "T-3045 Test User",
        email: "t3045-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    Map.merge(tenant, %{schema: tenant.schema_name, user: user})
  end

  # An activator the way `Letflow.Definitions.Activator.from_auth_context/2` builds it, holding
  # the entry's permission (no role of the fixture module grants `:FxlpPost`).
  defp activator(user, catalogue_permissions) do
    %{
      user_id: user.id,
      roles: ["TENANT_ADMIN"],
      entities_records_write?: false,
      permissions: [],
      catalogue_permissions: catalogue_permissions,
      credential: "none"
    }
  end

  defp call(args \\ %{"note" => %{"var" => "note"}}, function \\ @function),
    do: %{"function" => function, "args" => args}

  defp graph(call, extra_nodes \\ [], attributes \\ %{}) do
    nodes =
      [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => Map.put(attributes, "module_call", call)
        }
      ] ++ extra_nodes ++ [%{"id" => "end", "node_type" => "END"}]

    ids = Enum.map(nodes, & &1["id"])

    edges =
      ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(1)
      |> Enum.map(fn {[a, b], i} -> %{"id" => "e#{i}", "source" => a, "target" => b} end)

    %{"nodes" => nodes, "edges" => edges}
  end

  defp draft!(ctx, graph) do
    {:ok, definition} =
      Definitions.create(
        %{name: unique("t3045"), version: "1", graph: graph, created_by: Ecto.UUID.generate()},
        prefix: ctx.schema
      )

    definition
  end

  defp activate(ctx, graph, activator) do
    draft = draft!(ctx, graph)
    {draft, Definitions.activate(draft.id, prefix: ctx.schema, activator: activator)}
  end

  defp codes({:error, {:platform_calls_invalid, violations}}),
    do: violations |> Enum.map(& &1.code) |> Enum.sort()

  defp parsed_nodes(graph_map) do
    {:ok, %Graph{nodes: nodes}} = Graph.from_map(graph_map)
    nodes
  end

  defp service_node(attributes),
    do: %Graph.Node{id: "n", node_type: :SERVICE_TASK, attributes: attributes}

  # ── the parse (ServiceTask) ─────────────────────────────────────────────────────────────────

  describe "route parse: one route per node" do
    test "P2a-1 a module_call node is route :module_call and keeps the declaration" do
      node = service_node(%{"module_call" => call()})

      assert {:ok, %ServiceTask.Config{route_kind: :module_call, module_call: declared}} =
               ServiceTask.parse_config_from_node_attributes(node)

      assert declared == call()
    end

    test "P2a-2 a second route beside it is refused as conflicting, whichever attribute it is" do
      for {key, value} <- [
            {"endpoint", "https://example.test/x"},
            {"service_id", "svc"},
            {"script_key", "a_script"},
            {"platform_call", %{"function" => "tenant.create", "args" => %{}}},
            {"notify", %{"template" => "t"}},
            {"entity_writes", [%{"entity_type" => "x"}]},
            {"module_writes", [%{"module" => "m"}]}
          ] do
        node = service_node(%{"module_call" => call(), key => value})

        assert {:error, :conflicting_routes} =
                 ServiceTask.parse_config_from_node_attributes(node),
               "#{key} beside a module_call must be refused"
      end
    end

    test "P2a-3 a malformed module_call never falls through to another route" do
      for bad <- ["tenant.create", 7, ["x"], true] do
        node = service_node(%{"module_call" => bad, "endpoint" => "https://example.test/x"})

        assert {:error, :conflicting_routes} =
                 ServiceTask.parse_config_from_node_attributes(node)
      end
    end

    test "P2a-4 a node with no module_call parses as before" do
      node = service_node(%{"endpoint" => "https://example.test/x"})

      assert {:ok, %ServiceTask.Config{route_kind: :inline_url, module_call: nil}} =
               ServiceTask.parse_config_from_node_attributes(node)
    end
  end

  # ── the graph checks ──────────────────────────────────────────────────────────────────────────

  describe "graph checks" do
    defp graph_codes(graph_map) do
      {:ok, graph} = Graph.from_map(graph_map)
      Graph.validate_node_attributes(graph).violations |> Enum.map(& &1.code) |> Enum.sort()
    end

    test "P2a-5 a module_call node needs no endpoint and no timeout check" do
      assert graph_codes(graph(call(), [], %{"timeout_ms" => "not a number"})) == []
    end

    test "P2a-6 a module_call node with another route attribute is refused" do
      for {key, value} <- [
            {"endpoint", "https://example.test/x"},
            {"service_id", "svc"},
            {"script_key", "a_script"},
            {"platform_call", %{"function" => "tenant.create", "args" => %{}}},
            {"notify", %{"template" => "t"}},
            {"entity_writes", [%{"entity_type" => "x"}]},
            {"module_writes", [%{"module" => "m"}]}
          ] do
        assert :conflicting_module_call_routes in graph_codes(graph(call(), [], %{key => value})),
               "#{key} beside a module_call must be a graph violation"
      end
    end

    test "P2a-7 the write path of a draft refuses the conflicting node" do
      ctx = tenant!("t3045-g", true)

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.create(
                 %{
                   name: unique("t3045"),
                   version: "1",
                   graph: graph(call(), [], %{"endpoint" => "https://example.test/x"}),
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: ctx.schema
               )

      assert Enum.any?(violations, &(&1.code == :conflicting_module_call_routes))
    end
  end

  # ── the node rules (pure) ─────────────────────────────────────────────────────────────────────

  describe "ModuleCalls.violations/4 (shape and node type)" do
    defp node_codes(node, nodes \\ nil, activator \\ nil),
      do:
        node
        |> ModuleCalls.violations(nodes || [node], "tenant_x", activator)
        |> Enum.map(& &1.code)

    test "P2a-8 a conflicting route is the first and only answer" do
      node = service_node(%{"module_call" => call(), "endpoint" => "https://example.test/x"})
      assert node_codes(node) == [:conflicting_module_call_routes]
    end

    test "P2a-9 a node type other than SERVICE_TASK is refused" do
      node = %Graph.Node{
        id: "h",
        node_type: :HUMAN_TASK,
        attributes: %{"module_call" => call(), "role" => "R"}
      }

      assert node_codes(node) == [:module_call_node_type_not_supported]
    end

    test "P2a-10 a malformed attribute is refused, never guessed" do
      assert node_codes(service_node(%{"module_call" => "x"})) == [:module_call_malformed]

      assert node_codes(service_node(%{"module_call" => %{"args" => %{}}})) == [
               :module_call_malformed
             ]

      assert node_codes(service_node(%{"module_call" => %{"function" => " ", "args" => %{}}})) ==
               [:module_call_malformed]

      assert node_codes(service_node(%{"module_call" => %{"function" => @function, "args" => 1}})) ==
               [:module_call_malformed]

      assert node_codes(
               service_node(%{"module_call" => %{"function" => @function, "extra" => 1}})
             ) == [:module_call_unknown_key]
    end

    test "P2a-11 a node with no module_call has no violation" do
      assert node_codes(service_node(%{"endpoint" => "https://example.test/x"})) == []
    end
  end

  # ── the activation fence ──────────────────────────────────────────────────────────────────────

  describe "activation" do
    setup do
      %{ctx: tenant!("t3045-a", true)}
    end

    test "P2a-12 a fully valid module_call is refused only because the run time is P2b", %{
      ctx: ctx
    } do
      {draft, result} = activate(ctx, graph(call()), activator(ctx.user, ["FxlpPost"]))

      assert codes(result) == [:module_call_runtime_unavailable]
      row = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.schema)
      assert row.status == :draft
      assert row.activated_by == nil
    end

    test "P2a-13 no activator at all is refused", %{ctx: ctx} do
      {_draft, result} = activate(ctx, graph(call()), nil)
      assert codes(result) == [:module_call_activator_required]
    end

    test "P2a-14 an activator without the entry's permission is refused", %{ctx: ctx} do
      {_draft, result} = activate(ctx, graph(call()), activator(ctx.user, ["TenantsManage"]))
      assert codes(result) == [:module_call_permission_required]
    end

    test "P2a-15 an unknown function and a PLATFORM entry give the same fixed code", %{ctx: ctx} do
      both = activator(ctx.user, ["FxlpPost", "TenantsManage"])

      for function <- ["fixture_ledger_post.nope", "tenant.create"] do
        {_draft, result} = activate(ctx, graph(call(%{}, function)), both)
        assert codes(result) == [:module_call_function_unknown], function
      end
    end

    test "P2a-16 a module that is not installed in the tenant is refused" do
      bare = tenant!("t3045-b", false)
      {_draft, result} = activate(bare, graph(call()), activator(bare.user, ["FxlpPost"]))
      assert codes(result) == [:module_call_module_not_installed]
    end

    test "P2a-17 arguments: missing, unknown and invalid sources are refused", %{ctx: ctx} do
      a = activator(ctx.user, ["FxlpPost"])

      {_d, missing} = activate(ctx, graph(call(%{})), a)
      assert codes(missing) == [:module_call_arg_missing]

      {_d, unknown} =
        activate(ctx, graph(call(%{"note" => %{"var" => "n"}, "bogus" => %{"const" => 1}})), a)

      assert codes(unknown) == [:module_call_arg_unknown]

      {_d, dotted} = activate(ctx, graph(call(%{"note" => %{"var" => "a.b"}})), a)
      assert codes(dotted) == [:module_call_arg_source_invalid]

      {_d, shapeless} = activate(ctx, graph(call(%{"note" => %{"x" => 1}})), a)
      assert codes(shapeless) == [:module_call_arg_source_invalid]

      {_d, reserved} = activate(ctx, graph(call(%{"note" => %{"var" => "_sys"}})), a)
      assert codes(reserved) == [:module_call_arg_sys_reference]
    end

    test "P2a-18 a variable a human task may write cannot feed the call", %{ctx: ctx} do
      human = %{
        "id" => "approve",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "R", "completer_inputs" => ["note"]}
      }

      {_d, result} =
        activate(ctx, graph(call(), [human]), activator(ctx.user, ["FxlpPost"]))

      assert codes(result) == [:module_call_input_source_refused]
    end

    test "P2a-19 a foreign source (an inline HTTP node) in the graph is refused", %{ctx: ctx} do
      http = %{
        "id" => "http",
        "node_type" => "SERVICE_TASK",
        "attributes" => %{"endpoint" => "https://example.test/x", "timeout_ms" => 1000}
      }

      {_d, result} = activate(ctx, graph(call(), [http]), activator(ctx.user, ["FxlpPost"]))
      assert :module_call_foreign_source_refused in codes(result)
    end

    test "P2a-20 two module_call steps are both checked", %{ctx: ctx} do
      second = %{
        "id" => "call2",
        "node_type" => "SERVICE_TASK",
        "attributes" => %{"module_call" => call(%{})}
      }

      {_d, result} = activate(ctx, graph(call(), [second]), activator(ctx.user, ["FxlpPost"]))
      assert codes(result) == [:module_call_arg_missing, :module_call_runtime_unavailable]
    end

    test "P2a-21 the pre-check of a transaction answers like the activation", %{ctx: ctx} do
      draft = draft!(ctx, graph(call()))

      assert {:error, {:platform_calls_invalid, [%{code: :module_call_permission_required}]}} =
               Definitions.precheck_activation(draft, ctx.schema, activator(ctx.user, []))
    end
  end

  # ── what the signed document and the start read ──────────────────────────────────────────────

  describe "permissions, names and read keys" do
    test "P2a-22 the entry's permission and name come from the module entry only" do
      nodes = parsed_nodes(graph(call()))

      assert ModuleCalls.required_permissions(nodes) == [:FxlpPost]
      assert ModuleCalls.function_names(ModuleCalls.declared_nodes(nodes)) == [@function]

      platform = parsed_nodes(graph(call(%{}, "tenant.create")))
      assert ModuleCalls.required_permissions(platform) == []
      assert ModuleCalls.function_names(ModuleCalls.declared_nodes(platform)) == []
    end

    test "P2a-23 the start permission of the definition includes the entry's permission" do
      {:ok, graph} = Graph.from_map(graph(call()))
      assert StartPermission.required(graph) == [:FxlpPost]
    end

    test "P2a-24 the variables the call reads are refused in a task completion body" do
      {:ok, graph} = Graph.from_map(graph(call(%{"note" => %{"var" => "note_id"}})))
      assert MapSet.member?(WriteTargets.write_read_keys(graph), "note_id")
      assert ModuleCalls.read_keys(graph.nodes) == ["note_id"]
    end
  end
end
