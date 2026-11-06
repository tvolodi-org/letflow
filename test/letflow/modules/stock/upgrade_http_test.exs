Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.UpgradeHttpTest do
  @moduledoc """
  REQ-770 / T-1396 (E1..E4, A1..A3, F1..F3, I1..I4, C1, T1, T2): `POST /api/v1/tenant/modules/stock/upgrade`
  through the real router with bearer tokens, on a stock install that looks older than the compiled
  manifest (version and hash aged, stamps set to an earlier hash), then a receipt posts through claim and
  complete of its human task. Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Ledger.Storage
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Repo
  alias Letflow.StockPostingFixture, as: P

  @old_hash String.duplicate("7", 64)
  @why "REQ-770 test: apply the stock upgrade"

  setup do
    ctx = P.setup!([:a, :b])
    {:ok, entry} = Catalog.fetch("stock")
    {:ok, hash} = Catalog.manifest_hash("stock")
    Map.merge(ctx, %{compiled_version: entry.manifest().version, compiled_hash: hash})
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────

  defp post_json(path, tok, body) do
    Plug.Test.conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp plan(tok), do: post_json("/api/v1/tenant/modules/stock/upgrade/plan", tok, %{})

  defp upgrade(tok, plan_hash, extra \\ %{}) do
    body = Map.merge(%{"plan_hash" => plan_hash, "rationale" => @why}, extra)
    post_json("/api/v1/tenant/modules/stock/upgrade", tok, body)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp age!(schema, version \\ "0.10.0", hash \\ @old_hash) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [version: version, manifest_hash: hash]],
        prefix: schema
      )

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

  defp with_triggers_off(schema, table, fun) do
    Repo.query!(~s(ALTER TABLE "#{schema}"."#{table}" DISABLE TRIGGER USER))

    try do
      fun.()
    after
      Repo.query!(~s(ALTER TABLE "#{schema}"."#{table}" ENABLE TRIGGER USER))
    end
  end

  # An older stock_receipt: the active definition without its optional "note" field, and a content hash
  # of its own (as a tenant installed from an earlier pack would have it), so the plan reports a real
  # class A change and the pack's current shape is not already stored for the tenant.
  defp trim_receipt!(ctx) do
    active =
      Repo.one!(
        from(d in EntityDefinition, where: d.name == "stock_receipt" and d.status == :active),
        prefix: ctx.schema
      )

    trimmed =
      Map.update!(active.definition_json, "fields", fn fs ->
        Enum.reject(fs, &(&1["name"] == "note"))
      end)

    with_triggers_off(ctx.schema, "entity_definitions", fn ->
      {1, _} =
        Repo.update_all(
          from(d in EntityDefinition, where: d.id == ^active.id),
          [
            set: [
              definition_json: trimmed,
              content_hash: :crypto.hash(:sha256, "older-receipt"),
              logical_shape_version: :crypto.hash(:sha256, "older-receipt-shape")
            ]
          ],
          prefix: ctx.schema
        )
    end)

    :ok
  end

  defp task_route(tok, task, action, body) do
    post_json("/api/v1/tasks/#{task.id}/#{action}", tok, body)
  end

  defp complete_status(ctx, task) do
    assert task_route(ctx.tok_a, task, "claim", %{}).status == 200
    task_route(ctx.tok_a, task, "complete", %{"output_variables" => %{}}).status
  end

  defp row(schema), do: Repo.get_by!(TenantModule, [module_id: "stock"], prefix: schema)

  defp count(schema, table) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}"."#{table}"|)
    n
  end

  defp audit_count(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".audit_entries WHERE action = 'module.upgrade'|
      )

    n
  end

  defp journal(schema, state),
    do: Repo.all(from(u in TenantModuleUpgrade, where: u.state == ^state), prefix: schema)

  defp active_ids(schema) do
    Repo.all(
      from(d in EntityDefinition,
        where: d.status == :active,
        select: {d.name, d.id},
        order_by: d.name
      ),
      prefix: schema
    )
  end

  defp snapshot(schema) do
    %{
      row: row(schema),
      active: active_ids(schema),
      defs: count(schema, "process_definitions"),
      entity_defs: count(schema, "entity_definitions"),
      audit: audit_count(schema)
    }
  end

  defp entity_row(report, name), do: Enum.find(report["entity_types"], &(&1["name"] == name))

  defp planned!(ctx) do
    report = plan(ctx.tok_a) |> P.status!(200)
    assert report["upgrade_path_available"] == true, inspect(report["path_error"])
    assert report["path_error"] == nil
    assert report["steps"] == []
    report
  end

  # ── E: the upgrade of an older tenant, through the real HTTP path ─────────────────────

  describe "an older stock tenant" do
    test "E1 before the upgrade the receipt cannot be completed, nothing is posted", ctx do
      doc = P.issue!(ctx)
      task = P.pending_task(ctx, doc["id"], "post")
      age!(ctx.schema)

      refute complete_status(ctx, task) == 200
      assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    end

    test "E2 E3 A1 A2 A3 plan, apply, then the same task completes and the row, journal and audit agree",
         ctx do
      doc = P.issue!(ctx)
      task = P.pending_task(ctx, doc["id"], "post")
      age!(ctx.schema)

      report = planned!(ctx)
      applied = upgrade(ctx.tok_a, report["plan_hash"]) |> P.status!(200)

      assert %{"state" => "done", "module_id" => "stock", "from_version" => "0.10.0"} = applied
      assert applied["to_version"] == ctx.compiled_version
      assert applied["accepted_hash_appended"] == true
      assert applied["plan_hash"] == report["plan_hash"]

      # A1 the row
      row = row(ctx.schema)
      assert row.version == ctx.compiled_version
      assert row.manifest_hash == ctx.compiled_hash
      assert row.accepted_manifest_hashes == [@old_hash]

      # A2 the journal
      assert [done] = journal(ctx.schema, :done)
      assert done.kind == :upgrade
      assert {done.from_version, done.to_version} == {"0.10.0", ctx.compiled_version}
      assert done.plan_hash == report["plan_hash"]
      assert done.rationale == @why
      assert is_binary(done.actor_id)
      assert done.touches["result"]["state"] == "done"

      # A3 the audit entry
      %{rows: [[after_state]]} =
        Repo.query!(
          ~s|SELECT after_state FROM "#{ctx.schema}".audit_entries WHERE action = 'module.upgrade'|
        )

      assert after_state["rationale"] == @why

      assert Enum.sort(Map.keys(after_state)) ==
               ~w(ack_destructive counts module_id plan_hash rationale step_ids version)

      refute inspect(after_state) =~ doc["id"]

      # E3 the same task now completes
      assert complete_status(ctx, task) == 200
      assert P.get!(ctx, doc["id"])["state"] == "posted"
      assert P.counts(ctx, doc["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
    end

    test "E4 a real entity change is applied (the gate-b2 shape) and the receipt posts", ctx do
      doc = P.issue!(ctx)
      task = P.pending_task(ctx, doc["id"], "post")
      trim_receipt!(ctx)
      age!(ctx.schema, "0.11.0")

      report = planned!(ctx)
      change = Enum.find(report["entity_types"], &(&1["name"] == "stock_receipt"))
      assert %{"change" => "new_version", "class" => "A"} = change

      applied = upgrade(ctx.tok_a, report["plan_hash"]) |> P.status!(200)
      assert applied["entity_versions_created"] >= 1

      assert plan(ctx.tok_a) |> P.status!(200) |> Map.fetch!("up_to_date") == true
      assert complete_status(ctx, task) == 200
      assert P.counts(ctx, doc["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
    end
  end

  describe "metadata-only change" do
    test "M1 a changed description is applied without a new version and the tenant upgrades",
         ctx do
      doc = P.issue!(ctx)
      task = P.pending_task(ctx, doc["id"], "post")
      age!(ctx.schema, "0.11.0")

      active =
        Repo.one!(
          from(d in EntityDefinition, where: d.name == "stock_receipt" and d.status == :active),
          prefix: ctx.schema
        )

      with_triggers_off(ctx.schema, "entity_definitions", fn ->
        {1, _} =
          Repo.update_all(
            from(d in EntityDefinition, where: d.id == ^active.id),
            [
              set: [definition_json: Map.put(active.definition_json, "description", "older text")]
            ],
            prefix: ctx.schema
          )
      end)

      report = planned!(ctx)

      assert %{"class" => "A", "reason" => "metadata_changed"} =
               entity_row(report, "stock_receipt")

      applied = upgrade(ctx.tok_a, report["plan_hash"]) |> P.status!(200)
      assert applied["entity_versions_created"] == 0
      assert row(ctx.schema).version == ctx.compiled_version
      assert complete_status(ctx, task) == 200
    end
  end

  # ── F: failures roll everything back ──────────────────────────────────────────────────

  describe "failures" do
    defp detach_leg!(schema) do
      {:ok, entry} = Catalog.fetch("stock")

      for %{ledger_ids: {:fixed, ids}} <- Map.values(entry.manifest().ledger), id <- ids do
        leg = Storage.partition_names(id)["ledger_leg"]
        Repo.query!(~s|ALTER TABLE "#{schema}".ledger_leg DETACH PARTITION "#{schema}"."#{leg}"|)
      end
    end

    defp repair_ledger!(schema) do
      {:ok, entry} = Catalog.fetch("stock")

      for %{ledger_ids: {:fixed, ids}} <- Map.values(entry.manifest().ledger), id <- ids do
        names = Storage.partition_names(id)

        for parent <- ["ledger_leg", "ledger_balance", "ledger_entry"] do
          Repo.query!(~s|DROP TABLE IF EXISTS "#{schema}"."#{names[parent]}"|)
        end
      end
    end

    test "F1 F2 a ledger storage refusal after an activation rolls everything back, a later apply works",
         ctx do
      trim_receipt!(ctx)
      age!(ctx.schema, "0.11.0")
      report = planned!(ctx)
      before = snapshot(ctx.schema)
      detach_leg!(ctx.schema)

      conn = upgrade(ctx.tok_a, report["plan_hash"])
      assert conn.status == 409
      assert %{"code" => "upgrade_failed", "error_code" => "storage_refused"} = body(conn)

      after_failure = snapshot(ctx.schema)
      assert after_failure == before
      assert [failed] = journal(ctx.schema, :failed)
      assert failed.error_code == "storage_refused"
      assert failed.plan_hash == report["plan_hash"]

      # F2 repair the partition set, plan again, apply: the failed row is abandoned
      repair_ledger!(ctx.schema)
      again = planned!(ctx)
      assert again["plan_hash"] == report["plan_hash"]
      assert %{"state" => "done"} = upgrade(ctx.tok_a, again["plan_hash"]) |> P.status!(200)
      assert journal(ctx.schema, :failed) == []
      assert [_] = journal(ctx.schema, :abandoned)
    end

    test "F3 an audit failure rolls back and answers 500, journal failed", ctx do
      age!(ctx.schema)
      report = planned!(ctx)
      before = row(ctx.schema)
      Repo.query!(~s|DROP TABLE "#{ctx.schema}".audit_entries CASCADE|)

      conn = upgrade(ctx.tok_a, report["plan_hash"])
      assert conn.status == 500
      refute conn.resp_body =~ "audit_entries"
      assert row(ctx.schema) == before
      assert [%{error_code: "internal_error"}] = journal(ctx.schema, :failed)
    end
  end

  # ── I: idempotency, stale plans, exclusion ────────────────────────────────────────────

  describe "repeat, stale and concurrent" do
    test "I1 a repeat answers the same body and writes nothing", ctx do
      age!(ctx.schema)
      report = planned!(ctx)
      first = upgrade(ctx.tok_a, report["plan_hash"]) |> P.status!(200)
      before = snapshot(ctx.schema)
      journal_rows = count(ctx.schema, "tenant_module_upgrades")

      assert upgrade(ctx.tok_a, report["plan_hash"]) |> P.status!(200) == first
      assert snapshot(ctx.schema) == before
      assert count(ctx.schema, "tenant_module_upgrades") == journal_rows
    end

    test "I2 a stale or unknown hash is a 409 plan_mismatch and writes nothing", ctx do
      age!(ctx.schema)
      report = planned!(ctx)
      upgrade(ctx.tok_a, report["plan_hash"]) |> P.status!(200)
      before = snapshot(ctx.schema)
      journal_rows = count(ctx.schema, "tenant_module_upgrades")

      for hash <- [String.duplicate("a", 64), String.duplicate("b", 64)] do
        conn = upgrade(ctx.tok_a, hash)
        assert conn.status == 409
        assert %{"code" => "plan_mismatch"} = body(conn)
      end

      assert snapshot(ctx.schema) == before
      assert count(ctx.schema, "tenant_module_upgrades") == journal_rows
    end

    test "I3 a held lock answers 409 upgrade_running, nothing is written, then the apply works",
         ctx do
      age!(ctx.schema)
      report = planned!(ctx)
      before = snapshot(ctx.schema)

      {:ok, conn} =
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            ctx.schema <> ":stock"
          ])

          Task.async(fn -> upgrade(ctx.tok_a, report["plan_hash"]) end) |> Task.await(60_000)
        end)

      assert conn.status == 409
      assert %{"code" => "upgrade_running"} = body(conn)
      assert snapshot(ctx.schema) == before
      assert upgrade(ctx.tok_a, report["plan_hash"]).status == 200
    end

    test "I4 two concurrent applies: one done row and one audit entry", ctx do
      age!(ctx.schema)
      report = planned!(ctx)

      statuses =
        [1, 2]
        |> Enum.map(fn _ ->
          Task.async(fn -> upgrade(ctx.tok_a, report["plan_hash"]).status end)
        end)
        |> Enum.map(&Task.await(&1, 120_000))

      # 503 is the per-tenant admission cap answering the second concurrent request
      assert Enum.all?(statuses, &(&1 in [200, 409, 503]))
      assert 200 in statuses
      assert [_one] = journal(ctx.schema, :done)
      assert audit_count(ctx.schema) == 1
    end
  end

  # ── C and T ───────────────────────────────────────────────────────────────────────────

  describe "refusals and tenancy" do
    test "C1 a class C row is a 409 upgrade_forbidden and nothing is written", ctx do
      age!(ctx.schema)

      row =
        Repo.get_by!(EntityDefinition, [name: "stock_receipt_line", status: :active],
          prefix: ctx.schema
        )

      with_triggers_off(ctx.schema, "entity_definitions", fn ->
        {1, _} =
          Repo.update_all(
            from(d in EntityDefinition, where: d.id == ^row.id),
            [set: [name: "stock_gone"]],
            prefix: ctx.schema
          )
      end)

      report = plan(ctx.tok_a) |> P.status!(200)
      before = snapshot(ctx.schema)

      conn = upgrade(ctx.tok_a, report["plan_hash"])
      assert conn.status == 409
      assert %{"code" => "upgrade_forbidden", "reasons" => [_ | _]} = body(conn)
      assert snapshot(ctx.schema) == before
    end

    test "T1 the plan hash of tenant B against a module A does not have is a 404", ctx do
      b = P.tenant_b!(ctx)
      age!(b.b.schema_name)
      report = plan(b.tok_b) |> P.status!(200)

      {1, _} =
        Repo.update_all(
          from(m in TenantModule, where: m.module_id == "stock"),
          [set: [status: :uninstalled]],
          prefix: ctx.schema
        )

      before_b = snapshot(b.b.schema_name)
      assert upgrade(ctx.tok_a, report["plan_hash"]).status == 404
      assert snapshot(b.b.schema_name) == before_b
    end

    test "T2 the plan hash of tenant B against A's own stock is a 409 plan_mismatch", ctx do
      b = P.tenant_b!(ctx)
      age!(b.b.schema_name)
      age!(ctx.schema)
      report = plan(b.tok_b) |> P.status!(200)

      before_a = snapshot(ctx.schema)
      before_b = snapshot(b.b.schema_name)
      conn = upgrade(ctx.tok_a, report["plan_hash"])

      assert conn.status == 409
      assert %{"code" => "plan_mismatch"} = body(conn)
      refute conn.resp_body =~ b.b.schema_name
      assert snapshot(ctx.schema) == before_a
      assert snapshot(b.b.schema_name) == before_b
    end
  end
end
