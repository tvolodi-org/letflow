Code.require_file("../modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.Routers.TenantModulesUpgradePlanTest do
  @moduledoc """
  REQ-768 / T-1395: `POST /api/v1/tenant/modules/:module_id/upgrade/plan` through the full
  `Letflow.Router` with bearer tokens. Committed tenants, Sandbox `:auto`, `async: false`.
  Tests: P1..P4c, C-A, C-B, C-C, R1..R3, H1 (route half), X1, X2, L1 (route half), M1, V1.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ModuleWrites
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.EntityDefinition
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  @old_hash String.duplicate("7", 64)
  @other_hash String.duplicate("9", 64)

  setup do
    ctx = P.setup!([:a, :b])
    Map.put(ctx, :compiled_version, stock_manifest().version)
  end

  defp stock_manifest do
    {:ok, entry} = Catalog.fetch("stock")
    entry.manifest()
  end

  defp compiled_hash do
    {:ok, hash} = Catalog.manifest_hash("stock")
    hash
  end

  defp plan(tok, module \\ "stock", body \\ "{}") do
    Plug.Test.conn(:post, "/api/v1/tenant/modules/#{module}/upgrade/plan", body)
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp plan!(tok), do: plan(tok) |> P.status!(200)

  defp age!(schema, version, hash) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [version: version, manifest_hash: hash]],
        prefix: schema
      )
  end

  defp with_triggers_off(schema, table, fun) do
    Repo.query!(~s(ALTER TABLE "#{schema}"."#{table}" DISABLE TRIGGER USER))

    try do
      fun.()
    after
      Repo.query!(~s(ALTER TABLE "#{schema}"."#{table}" ENABLE TRIGGER USER))
    end
  end

  defp restamp!(schema, hash) do
    with_triggers_off(schema, "process_definitions", fn ->
      {n, _} =
        Repo.update_all(
          from(d in ProcessDefinition, where: not is_nil(d.owner_manifest_hash)),
          [set: [owner_manifest_hash: hash]],
          prefix: schema
        )

      assert n >= 1
    end)
  end

  defp active_def(schema, name),
    do:
      Repo.one!(from(d in EntityDefinition, where: d.name == ^name and d.status == :active),
        prefix: schema
      )

  defp set_json!(schema, name, fun) do
    row = active_def(schema, name)

    with_triggers_off(schema, "entity_definitions", fn ->
      {1, _} =
        Repo.update_all(
          from(d in EntityDefinition, where: d.id == ^row.id),
          [set: [definition_json: fun.(row.definition_json)]],
          prefix: schema
        )
    end)
  end

  defp drop_field(json, name),
    do: Map.update!(json, "fields", fn fs -> Enum.reject(fs, &(&1["name"] == name)) end)

  defp count(schema, table) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}"."#{table}"|)
    n
  end

  defp untraced(conn), do: conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")

  defp journal_count(schema), do: Repo.aggregate(TenantModuleUpgrade, :count, prefix: schema)

  defp entity(report, name), do: Enum.find(report["entity_types"], &(&1["name"] == name))

  describe "authorisation and lookup" do
    test "P1 a TENANT_ADMIN gets 200", ctx do
      age!(ctx.schema, "0.10.0", @old_hash)
      assert %{"module_id" => "stock"} = plan!(ctx.tok_a)
    end

    test "P2 a caller without ModulesManage gets 403", ctx do
      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-up")
      assert plan(worker).status == 403
      assert journal_count(ctx.schema) == 0
    end

    test "P3 unknown, not installed and uninstalled answer the same 404", ctx do
      unknown = plan(ctx.tok_a, "no_such_module")
      assert unknown.status == 404

      {1, _} =
        Repo.update_all(
          from(m in TenantModule, where: m.module_id == "stock"),
          [set: [status: :uninstalled]],
          prefix: ctx.schema
        )

      gone = plan(ctx.tok_a)
      assert gone.status == 404
      assert untraced(gone) == untraced(unknown)
      assert untraced(plan(ctx.tok_a, "fixture_ledger")) == untraced(unknown)
    end
  end

  describe "report" do
    test "P4 the aged 0.10.0 install: stamps pass, boot-applicable, hash set, no path marker",
         ctx do
      age!(ctx.schema, "0.10.0", @old_hash)
      report = plan!(ctx.tok_a)

      assert report["from_version"] == "0.10.0"
      assert report["to_version"] == ctx.compiled_version
      assert report["stamped_definitions"] != []
      assert Enum.all?(report["stamped_definitions"], & &1["passes_activation"])
      assert report["applicable_on_boot"] == true
      assert report["plan_hash"] =~ ~r/^[0-9a-f]{64}$/
      # stock declares no min_upgradable_from: a 0.10.0 install has no path, still a 200
      assert report["upgrade_path_available"] == false
      assert report["path_error"] == "no_upgrade_path"
      assert report["steps"] == []
      refute report["up_to_date"]
    end

    test "P4c the marker follows the path and moves the hash; neither case is a 409", ctx do
      age!(ctx.schema, "0.10.0", @old_hash)
      without = plan(ctx.tok_a) |> P.status!(200)

      age!(ctx.schema, ctx.compiled_version, @old_hash)
      with_path = plan(ctx.tok_a) |> P.status!(200)

      assert without["upgrade_path_available"] == false
      assert with_path["upgrade_path_available"] == true
      assert with_path["path_error"] == nil
      assert with_path["plan_hash"] != without["plan_hash"]
    end

    test "P4b a stamp that is neither installed nor accepted fails with the mismatch code",
         ctx do
      P.issue!(ctx)
      age!(ctx.schema, "0.10.0", @old_hash)
      restamp!(ctx.schema, @other_hash)
      report = plan!(ctx.tok_a)

      failing = Enum.reject(report["stamped_definitions"], & &1["passes_activation"])
      assert failing != []
      assert Enum.all?(failing, &("module_write_hash_mismatch" in &1["violation_codes"]))
      assert report["applicable_on_boot"] == false
    end

    test "C-A an optional field added is class A", ctx do
      age!(ctx.schema, "0.10.0", @old_hash)
      set_json!(ctx.schema, "stock_receipt", &drop_field(&1, "note"))
      row = plan!(ctx.tok_a) |> entity("stock_receipt")

      assert %{"change" => "new_version", "class" => "A", "reason" => "optional_field_added"} =
               row
    end

    test "C-B a required field added is class B, not covered by steps", ctx do
      age!(ctx.schema, "0.10.0", @old_hash)
      set_json!(ctx.schema, "stock_receipt", &drop_field(&1, "location_id"))
      report = plan!(ctx.tok_a)

      assert %{"class" => "B", "reason" => "required_field_added", "covered_by_steps" => false} =
               entity(report, "stock_receipt")

      assert report["applicable_on_boot"] == false
    end

    test "C-C a managed type missing from the pack is class C and the pack type is new", ctx do
      age!(ctx.schema, "0.10.0", @old_hash)
      row = active_def(ctx.schema, "stock_receipt_line")

      with_triggers_off(ctx.schema, "entity_definitions", fn ->
        Repo.update_all(
          from(d in EntityDefinition, where: d.id == ^row.id),
          [set: [name: "stock_gone"]],
          prefix: ctx.schema
        )
      end)

      report = plan!(ctx.tok_a)

      assert %{"change" => "removed", "class" => "C", "reason" => "type_removed_or_renamed"} =
               entity(report, "stock_gone")

      assert %{"change" => "new_type", "class" => "A"} = entity(report, "stock_receipt_line")
      assert report["applicable_on_boot"] == false
    end

    test "the report lists the pack process definitions as unchanged", ctx do
      age!(ctx.schema, "0.10.0", @old_hash)
      report = plan!(ctx.tok_a)
      assert report["process_definitions"] != []
      assert Enum.all?(report["process_definitions"], &(&1["change"] == "unchanged"))
    end
  end

  describe "journal" do
    test "R1 R2 one planned row, no other write, a repeat reuses it, a new state supersedes",
         ctx do
      age!(ctx.schema, "0.10.0", @old_hash)
      # the first OIDC request of a tenant binds its administrator (a group_member audit row)
      assert plan(ctx.tok_a, "no_such_module").status == 404

      tables = ~w(tenant_modules entity_definitions process_definitions events audit_entries)
      before = Map.new(tables, &{&1, count(ctx.schema, &1)})

      report = plan!(ctx.tok_a)
      assert Map.new(tables, &{&1, count(ctx.schema, &1)}) == before
      assert journal_count(ctx.schema) == 1

      row = Repo.one!(TenantModuleUpgrade, prefix: ctx.schema)
      assert row.state == :planned
      assert row.plan_hash == report["plan_hash"]
      assert row.id == report["plan_id"]
      assert {row.from_version, row.to_version} == {"0.10.0", ctx.compiled_version}

      again = plan!(ctx.tok_a)
      assert again["plan_hash"] == report["plan_hash"]
      assert again["plan_id"] == report["plan_id"]
      assert journal_count(ctx.schema) == 1

      # H1 (route half): applied version and settings change the hash and supersede the row
      age!(ctx.schema, "0.9.0", @old_hash)
      moved = plan!(ctx.tok_a)
      assert moved["plan_hash"] != report["plan_hash"]

      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [settings: %{"x" => 1}]],
        prefix: ctx.schema
      )

      settings = plan!(ctx.tok_a)
      assert settings["plan_hash"] not in [report["plan_hash"], moved["plan_hash"]]

      states =
        Repo.all(from(u in TenantModuleUpgrade, select: {u.plan_hash, u.state}),
          prefix: ctx.schema
        )

      assert length(states) == 3
      assert {settings["plan_hash"], :planned} in states
      assert {moved["plan_hash"], :abandoned} in states
      assert {report["plan_hash"], :abandoned} in states
    end

    test "R3 an up-to-date tenant gets an empty report and no row", ctx do
      report = plan!(ctx.tok_a)
      assert report["up_to_date"] == true
      assert report["plan_hash"] == nil
      assert report["entity_types"] == []
      assert report["stamped_definitions"] == []
      assert report["steps"] == []
      assert journal_count(ctx.schema) == 0
    end
  end

  describe "tenant isolation and leaks" do
    test "X1 X2 a plan reads and writes only the caller's schema; the body is ignored", ctx do
      b = P.tenant_b!(ctx)
      age!(ctx.schema, "0.10.0", @old_hash)
      age!(b.b.schema_name, "0.10.0", @old_hash)
      b_before = {count(b.b.schema_name, "tenant_modules"), journal_count(b.b.schema_name)}

      body = Jason.encode!(%{"tenant_id" => b.b.tenant_id, "prefix" => b.b.schema_name})
      report = plan(ctx.tok_a, "stock", body) |> P.status!(200)

      assert journal_count(ctx.schema) == 1
      assert report["plan_id"] == Repo.one!(TenantModuleUpgrade, prefix: ctx.schema).id

      assert {count(b.b.schema_name, "tenant_modules"), journal_count(b.b.schema_name)} ==
               b_before

      assert journal_count(b.b.schema_name) == 0

      # a module that is not installed in the caller's tenant: 404 and nothing written anywhere
      {1, _} =
        Repo.update_all(
          from(m in TenantModule, where: m.module_id == "stock"),
          [set: [status: :uninstalled]],
          prefix: ctx.schema
        )

      assert plan(ctx.tok_a).status == 404
      assert journal_count(ctx.schema) == 1
      assert journal_count(b.b.schema_name) == 0
    end

    test "L1 no document id, stamp or hash value is in the body", ctx do
      doc = P.issue!(ctx)
      age!(ctx.schema, "0.10.0", @old_hash)
      conn = plan(ctx.tok_a)
      assert conn.status == 200
      refute conn.resp_body =~ doc["id"]
      refute conn.resp_body =~ @old_hash
      refute conn.resp_body =~ compiled_hash()
    end
  end

  describe "V1 the injected-hash check" do
    test "equals the activation check when the hashes are the stored ones", ctx do
      doc = P.issue!(ctx)
      assert doc["id"]
      hashes = %{installed: compiled_hash(), accepted: []}

      definitions =
        Repo.all(from(d in ProcessDefinition, where: not is_nil(d.owner_manifest_hash)),
          prefix: ctx.schema
        )

      checked =
        for definition <- definitions,
            {:ok, %Graph{nodes: nodes}} = Graph.from_map(definition.graph),
            {node, writes} <- ModuleWrites.declared_nodes(nodes) do
          count =
            case node.attributes do
              %{"entity_writes" => lines} when is_list(lines) -> length(lines)
              _ -> 0
            end

          assert ModuleWrites.node_violations_with_hashes(
                   node,
                   writes,
                   definition,
                   count,
                   ctx.schema,
                   hashes
                 ) ==
                   ModuleWrites.violations(node, writes, definition, count, [], ctx.schema)

          # stale injected hashes are refused where the DB state would refuse
          stale = %{installed: @other_hash, accepted: []}

          assert Enum.any?(
                   ModuleWrites.node_violations_with_hashes(
                     node,
                     writes,
                     definition,
                     count,
                     ctx.schema,
                     stale
                   ),
                   &(&1.code == :module_write_hash_mismatch)
                 )
        end

      assert checked != []
    end
  end

  describe "M1 the plan agrees with the engine's verdict (real HTTP)" do
    defp task_route(tok, task, action, body) do
      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/#{action}", body)
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Letflow.Router.call(Letflow.Router.init([]))
    end

    defp aged_receipt!(ctx, stamp_hash) do
      doc = P.issue!(ctx)
      task = P.pending_task(ctx, doc["id"], "post")
      age!(ctx.schema, "0.10.0", @old_hash)
      restamp!(ctx.schema, stamp_hash)
      {doc, task}
    end

    # What REQ-770 will write: installed := compiled, accepted := accepted ++ [old installed].
    defp simulate_apply!(ctx, accepted) do
      Mw.set_installed_hash!(ctx.schema, "stock", compiled_hash())
      Mw.set_accepted_hashes!(ctx.schema, "stock", accepted)
    end

    test "plan says passes, and after the simulated apply the completion is 200", ctx do
      {doc, task} = aged_receipt!(ctx, @old_hash)

      report = plan!(ctx.tok_a)
      assert Enum.all?(report["stamped_definitions"], & &1["passes_activation"])

      simulate_apply!(ctx, [@old_hash])
      assert task_route(ctx.tok_a, task, "claim", "{}").status == 200
      conn = task_route(ctx.tok_a, task, "complete", ~s({"output_variables":{}}))
      assert conn.status == 200, conn.resp_body
      assert P.get!(ctx, doc["id"])["state"] == "posted"
    end

    test "plan says fails, and the completion is refused 403", ctx do
      {doc, task} = aged_receipt!(ctx, @other_hash)

      report = plan!(ctx.tok_a)
      assert Enum.any?(report["stamped_definitions"], &(not &1["passes_activation"]))

      simulate_apply!(ctx, [@old_hash])
      assert task_route(ctx.tok_a, task, "claim", "{}").status == 200
      conn = task_route(ctx.tok_a, task, "complete", ~s({"output_variables":{}}))
      assert conn.status == 403, conn.resp_body
      assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    end
  end
end
