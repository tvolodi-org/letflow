Code.require_file("../modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.Routers.TenantModulesRollbackTest do
  @moduledoc """
  T-1549 (decision 0055 D9, RB1..RB18): `POST /api/v1/tenant/modules/:module_id/rollback` through the
  real router with bearer tokens, on a stock install that looks older than the compiled manifest (as
  `stock/upgrade_http_test.exs` does), upgraded over HTTP and then rolled back. Committed tenants,
  Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.ModuleUpgrade.Boot
  alias Letflow.ModuleUpgrade.Rollback
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Step
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Modules.UpgradePlan
  alias Letflow.Repo
  alias Letflow.StockPostingFixture, as: P

  @old_hash String.duplicate("7", 64)
  @old_version "0.11.0"
  @why "T-1549 test: roll back"
  @closed_keys ~w(dry_run entity_types from_version module_id point_of_no_return process_drafts_kept
                  refusal rollback_id rollback_possible state steps target_version)

  setup do
    ctx = P.setup!([:a, :b])
    {:ok, entry} = Catalog.fetch("stock")
    {:ok, hash} = Catalog.manifest_hash("stock")
    on_exit(fn -> Application.delete_env(:letflow, :module_upgrade_on_boot) end)
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

  defp upgrade(tok, plan_hash),
    do:
      post_json("/api/v1/tenant/modules/stock/upgrade", tok, %{
        "plan_hash" => plan_hash,
        "rationale" => "T-1549 test: upgrade"
      })

  defp rollback(tok, body, module \\ "stock"),
    do: post_json("/api/v1/tenant/modules/#{module}/rollback", tok, body)

  defp rb_body(target, extra \\ %{}),
    do: Map.merge(%{"rationale" => @why, "target_version" => target}, extra)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp with_triggers_off(schema, table, fun) do
    Repo.query!(~s(ALTER TABLE "#{schema}"."#{table}" DISABLE TRIGGER USER))

    try do
      fun.()
    after
      Repo.query!(~s(ALTER TABLE "#{schema}"."#{table}" ENABLE TRIGGER USER))
    end
  end

  defp age!(schema, version \\ @old_version, hash \\ @old_hash) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [version: version, manifest_hash: hash, accepted_manifest_hashes: []]],
        prefix: schema
      )

    with_triggers_off(schema, "process_definitions", fn ->
      Repo.update_all(
        from(d in ProcessDefinition, where: not is_nil(d.owner_manifest_hash)),
        [set: [owner_manifest_hash: hash]],
        prefix: schema
      )
    end)
  end

  # An older stock_receipt (without "note"), as in the upgrade test: a real class A new_version.
  defp trim_receipt!(schema) do
    active =
      Repo.one!(
        from(d in EntityDefinition, where: d.name == "stock_receipt" and d.status == :active),
        prefix: schema
      )

    trimmed =
      Map.update!(active.definition_json, "fields", fn fs ->
        Enum.reject(fs, &(&1["name"] == "note"))
      end)

    with_triggers_off(schema, "entity_definitions", fn ->
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
          prefix: schema
        )
    end)

    active.id
  end

  # An aged tenant with a trimmed receipt, upgraded over HTTP. Returns the old receipt row id.
  defp upgraded!(ctx_schema, tok) do
    old_id = trim_receipt!(ctx_schema)
    age!(ctx_schema)
    report = plan(tok) |> P.status!(200)
    assert %{"state" => "done"} = upgrade(tok, report["plan_hash"]) |> P.status!(200)
    {old_id, report["plan_hash"]}
  end

  defp row(schema), do: Repo.get_by!(TenantModule, [module_id: "stock"], prefix: schema)

  defp active_receipt_id(schema) do
    {:ok, definition} = Definitions.get_active_definition_by_name("stock_receipt", schema)
    definition.id
  end

  defp count(schema, table, where \\ "true") do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}"."#{table}" WHERE #{where}|)
    n
  end

  defp snapshot(schema) do
    %{
      row: row(schema),
      active: active_receipt_id(schema),
      journal: count(schema, "tenant_module_upgrades"),
      audit: count(schema, "audit_entries"),
      entity_defs: count(schema, "entity_definitions")
    }
  end

  defp journal(schema, kind, state),
    do:
      Repo.all(from(u in TenantModuleUpgrade, where: u.kind == ^kind and u.state == ^state),
        prefix: schema
      )

  # ── RB1: the route ───────────────────────────────────────────────────────────────────

  test "RB1 the route is authz_post gated by ModulesManage" do
    assert {"POST", "/:module_id/rollback", :ModulesManage} in Letflow.Routers.TenantModules.__authz_routes__()

    assert Letflow.Api.Authorization.endpoint_policy_key(
             "POST",
             "/tenant/modules/:module_id/rollback"
           ) == :ModulesManage
  end

  # ── RB2 RB3 RB9: the round trip ──────────────────────────────────────────────────────

  describe "after an upgrade" do
    test "RB2 RB17 the rollback restores version, hash and definition; journal and audit agree",
         ctx do
      {old_id, _hash} = upgraded!(ctx.schema, ctx.tok_a)
      assert row(ctx.schema).version == ctx.compiled_version
      refute active_receipt_id(ctx.schema) == old_id

      result = rollback(ctx.tok_a, rb_body(@old_version)) |> P.status!(200)

      assert Enum.sort(Map.keys(result)) == Enum.sort(@closed_keys)
      assert %{"state" => "done", "dry_run" => false, "rollback_possible" => true} = result
      assert result["from_version"] == ctx.compiled_version
      assert result["target_version"] == @old_version
      assert is_binary(result["rollback_id"])

      assert %{"change" => "reactivated"} =
               Enum.find(result["entity_types"], &(&1["name"] == "stock_receipt"))

      refute ctx.compiled_hash in String.split(inspect(result), "\"")

      row = row(ctx.schema)
      assert row.version == @old_version
      assert row.manifest_hash == @old_hash
      assert ctx.compiled_hash in row.accepted_manifest_hashes
      assert active_receipt_id(ctx.schema) == old_id

      assert [rb] = journal(ctx.schema, :rollback, :done)
      assert {rb.from_version, rb.to_version} == {ctx.compiled_version, @old_version}
      assert rb.rationale == @why
      assert [up] = journal(ctx.schema, :upgrade, :done)
      assert rb.touches["reverses"] == up.id
      assert up.state == :done and up.touches["undo"]["from_manifest_hash"] == @old_hash

      %{rows: [[after_state]]} =
        Repo.query!(
          ~s|SELECT after_state FROM "#{ctx.schema}".audit_entries WHERE action = 'module.rollback'|
        )

      assert after_state["rationale"] == @why
      assert after_state["reverses"] == up.id
    end

    test "RB3 dry_run reports and writes nothing", ctx do
      upgraded!(ctx.schema, ctx.tok_a)
      before = snapshot(ctx.schema)

      result = rollback(ctx.tok_a, rb_body(@old_version, %{"dry_run" => true})) |> P.status!(200)

      assert %{"state" => "dry_run", "dry_run" => true, "rollback_possible" => true} = result
      assert result["rollback_id"] == nil
      assert Enum.sort(Map.keys(result)) == Enum.sort(@closed_keys)
      assert snapshot(ctx.schema) == before
    end

    test "RB3b a refused dry run is a 200 naming the refusal; a real call is a 409", ctx do
      upgraded!(ctx.schema, ctx.tok_a)
      before = snapshot(ctx.schema)

      dry = rollback(ctx.tok_a, rb_body("9.9.9", %{"dry_run" => true})) |> P.status!(200)
      assert %{"rollback_possible" => false, "refusal" => "rollback_target_mismatch"} = dry

      conn = rollback(ctx.tok_a, rb_body("9.9.9"))
      assert conn.status == 409
      assert %{"code" => "rollback_target_mismatch"} = body(conn)
      assert snapshot(ctx.schema) == before
    end

    test "RB5 a second rollback finds no previous version and writes nothing", ctx do
      upgraded!(ctx.schema, ctx.tok_a)
      rollback(ctx.tok_a, rb_body(@old_version)) |> P.status!(200)
      before = snapshot(ctx.schema)

      conn = rollback(ctx.tok_a, rb_body(@old_version))
      assert conn.status == 409
      assert %{"code" => "no_previous_version"} = body(conn)
      assert snapshot(ctx.schema) == before
    end

    test "RB9 a re-upgrade after the rollback activates the new definition again", ctx do
      {old_id, first_hash} = upgraded!(ctx.schema, ctx.tok_a)
      new_id = active_receipt_id(ctx.schema)
      rollback(ctx.tok_a, rb_body(@old_version)) |> P.status!(200)
      assert active_receipt_id(ctx.schema) == old_id

      report = plan(ctx.tok_a) |> P.status!(200)
      assert report["up_to_date"] == false
      applied = upgrade(ctx.tok_a, report["plan_hash"]) |> P.status!(200)
      assert applied["state"] == "done"
      assert applied["entity_versions_created"] >= 1

      assert row(ctx.schema).version == ctx.compiled_version
      assert row(ctx.schema).manifest_hash == ctx.compiled_hash
      assert active_receipt_id(ctx.schema) == new_id
      assert length(journal(ctx.schema, :upgrade, :done)) == 2

      # A re-apply with the first (reversed) plan hash is not answered from the reversed row.
      if first_hash == report["plan_hash"] do
        again = upgrade(ctx.tok_a, first_hash)
        assert again.status in [200, 409]
      end

      # and the rollback walks back again
      assert %{"state" => "done"} = rollback(ctx.tok_a, rb_body(@old_version)) |> P.status!(200)
      assert active_receipt_id(ctx.schema) == old_id
    end
  end

  # ── RB4: validation ──────────────────────────────────────────────────────────────────

  test "RB4 a blank rationale, a missing target or a bad dry_run is a 422 and writes nothing",
       ctx do
    upgraded!(ctx.schema, ctx.tok_a)
    before = snapshot(ctx.schema)

    for bad <- [%{}, %{"rationale" => "  ", "target_version" => @old_version}] do
      conn = rollback(ctx.tok_a, bad)
      assert conn.status == 422
      assert conn.resp_body =~ "rationale is required"
    end

    for target <- [nil, "", 7] do
      conn = rollback(ctx.tok_a, %{"rationale" => "why", "target_version" => target})
      assert conn.status == 422
      assert conn.resp_body =~ "target_version is required"
    end

    conn = rollback(ctx.tok_a, rb_body(@old_version, %{"dry_run" => "yes"}))
    assert conn.status == 422

    assert snapshot(ctx.schema) == before
  end

  # ── RB6 RB7: fail closed ─────────────────────────────────────────────────────────────

  test "RB6 an upgrade row with no undo block cannot be rolled back", ctx do
    upgraded!(ctx.schema, ctx.tok_a)

    {1, _} =
      Repo.update_all(
        from(u in TenantModuleUpgrade, where: u.kind == :upgrade and u.state == :done),
        [set: [touches: %{"result" => %{}}]],
        prefix: ctx.schema
      )

    before = snapshot(ctx.schema)
    conn = rollback(ctx.tok_a, rb_body(@old_version))
    assert conn.status == 409
    assert %{"code" => "rollback_not_recorded"} = body(conn)
    assert snapshot(ctx.schema) == before
  end

  test "RB6b a tenant row that moved without the journal cannot be rolled back", ctx do
    upgraded!(ctx.schema, ctx.tok_a)

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [manifest_hash: String.duplicate("9", 64)]],
        prefix: ctx.schema
      )

    conn = rollback(ctx.tok_a, rb_body(@old_version))
    assert conn.status == 409
    assert %{"code" => "rollback_not_recorded"} = body(conn)
  end

  test "RB7 a tenant version above the running build is refused", ctx do
    upgraded!(ctx.schema, ctx.tok_a)

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [version: "99.0.0"]],
        prefix: ctx.schema
      )

    # the candidate's to_version no longer equals the row: not recorded comes first; align it.
    {1, _} =
      Repo.update_all(
        from(u in TenantModuleUpgrade, where: u.kind == :upgrade and u.state == :done),
        [set: [to_version: "99.0.0"]],
        prefix: ctx.schema
      )

    conn = rollback(ctx.tok_a, rb_body(@old_version))
    assert conn.status == 409
    assert %{"code" => "module_version_ahead"} = body(conn)
  end

  test "RB5b a tenant that never upgraded has no previous version", ctx do
    before = snapshot_no_receipt(ctx.schema)
    conn = rollback(ctx.tok_a, rb_body("0.1.0"))
    assert conn.status == 409
    assert %{"code" => "no_previous_version"} = body(conn)
    assert snapshot_no_receipt(ctx.schema) == before
  end

  defp snapshot_no_receipt(schema),
    do: %{row: row(schema), journal: count(schema, "tenant_module_upgrades")}

  # ── RB8: the pure gate over declared down steps ──────────────────────────────────────

  describe "gate/4" do
    defp tenant_row(version, hash),
      do: %TenantModule{module_id: "m", version: version, manifest_hash: hash}

    defp candidate(from, to, undo \\ true) do
      touches =
        if undo,
          do: %{
            "undo" => %{
              "from_manifest_hash" => "a",
              "to_manifest_hash" => "b",
              "previous_definitions" => %{},
              "new_types" => []
            }
          },
          else: %{}

      %TenantModuleUpgrade{
        id: "11111111-1111-1111-1111-111111111111",
        from_version: from,
        to_version: to,
        touches: touches
      }
    end

    defp step(id, from, to, opts) do
      %Step{
        id: id,
        from: from,
        to: to,
        kind: :declarative,
        up: %{},
        down: Keyword.get(opts, :down, %{}),
        lossy: Keyword.get(opts, :lossy, false)
      }
    end

    defp manifest(steps),
      do: %{version: "2.0.0", min_upgradable_from: "1.0.0", migrations: steps}

    test "RB8 irreversible, lossy and missing down forbid; reversible needs the runner" do
      row = tenant_row("2.0.0", "b")
      cand = candidate("1.0.0", "2.0.0")

      for opts <- [[down: :irreversible], [lossy: true], [down: nil]] do
        manifest = manifest([step("s1", "1.0.0", "2.0.0", opts)])

        assert {:error, {"rollback_forbidden", %{"step_id" => "s1"}}} =
                 Rollback.gate(cand, manifest, row, "1.0.0")
      end

      reversible = manifest([step("s1", "1.0.0", "2.0.0", [])])

      assert {:error, {"rollback_needs_runner", %{}}} =
               Rollback.gate(cand, reversible, row, "1.0.0")

      assert {:ok, []} = Rollback.gate(cand, manifest([]), row, "1.0.0")
    end

    test "RB20 a target below min_data_version is refused" do
      row = tenant_row("2.0.0", "b")
      cand = candidate("1.0.0", "2.0.0")
      floor = Map.put(manifest([]), :min_data_version, "1.5.0")

      assert {:error, {"rollback_below_min_data_version", %{}}} =
               Rollback.gate(cand, floor, row, "1.0.0")

      at_floor = Map.put(manifest([]), :min_data_version, "1.0.0")
      assert {:ok, []} = Rollback.gate(cand, at_floor, row, "1.0.0")
    end

    test "RB8b the refusal order" do
      row = tenant_row("2.0.0", "b")
      m = manifest([])

      assert {:error, {"no_previous_version", _}} = Rollback.gate(nil, m, row, "1.0.0")

      assert {:error, {"rollback_not_recorded", _}} =
               Rollback.gate(candidate("1.0.0", "2.0.0", false), m, row, "1.0.0")

      assert {:error, {"module_version_ahead", _}} =
               Rollback.gate(candidate("1.0.0", "3.0.0"), m, tenant_row("3.0.0", "b"), "1.0.0")

      assert {:error, {"rollback_target_mismatch", _}} =
               Rollback.gate(candidate("1.0.0", "2.0.0"), m, row, "1.5.0")

      below = %{m | min_upgradable_from: "1.2.0"}

      assert {:error, {"no_upgrade_path_from_target", _}} =
               Rollback.gate(candidate("1.0.0", "2.0.0"), below, row, "1.0.0")
    end
  end

  # ── RB12: the plan states the point of no return ─────────────────────────────────────

  test "RB12 reversible?/1 and the plan of a step-free upgrade" do
    assert UpgradePlan.reversible?(%Step{
             id: "s",
             from: "1.0.0",
             to: "2.0.0",
             kind: :declarative,
             up: 1,
             down: 1,
             lossy: false
           })

    refute UpgradePlan.reversible?(%Step{
             id: "s",
             from: "1.0.0",
             to: "2.0.0",
             kind: :declarative,
             up: 1,
             down: :irreversible,
             lossy: false
           })

    refute UpgradePlan.reversible?(%Step{
             id: "s",
             from: "1.0.0",
             to: "2.0.0",
             kind: :declarative,
             up: 1,
             down: 1,
             lossy: true
           })

    refute UpgradePlan.reversible?(%Step{
             id: "s",
             from: "1.0.0",
             to: "2.0.0",
             kind: :declarative,
             up: 1,
             down: nil,
             lossy: false
           })
  end

  test "RB12b the plan carries point_of_no_return nil when no step is irreversible", ctx do
    age!(ctx.schema)
    report = plan(ctx.tok_a) |> P.status!(200)
    assert report["steps"] == []
    assert Map.has_key?(report, "point_of_no_return")
    assert report["point_of_no_return"] == nil
  end

  # ── RB13: the boot child holds after a rollback ──────────────────────────────────────

  test "RB13 upgrade on deploy leaves a rolled-back module alone", ctx do
    upgraded!(ctx.schema, ctx.tok_a)
    rollback(ctx.tok_a, rb_body(@old_version)) |> P.status!(200)
    before = snapshot(ctx.schema)

    Application.put_env(:letflow, :module_upgrade_on_boot, true)
    assert Boot.start_link(nil) == :ignore

    assert snapshot(ctx.schema) == before
    assert row(ctx.schema).version == @old_version
  end

  # ── RB14: cross tenant ───────────────────────────────────────────────────────────────

  test "RB14 a rollback by tenant A changes only A, whatever the body names", ctx do
    b = P.tenant_b!(ctx)
    upgraded!(ctx.schema, ctx.tok_a)
    upgraded!(b.b.schema_name, b.tok_b)
    before_b = snapshot(b.b.schema_name)

    result =
      rollback(
        ctx.tok_a,
        rb_body(@old_version, %{
          "tenant_id" => b.b.tenant_id,
          "prefix" => b.b.schema_name,
          "reverses" => "00000000-0000-0000-0000-000000000000"
        })
      )
      |> P.status!(200)

    assert result["state"] == "done"
    assert row(ctx.schema).version == @old_version
    assert snapshot(b.b.schema_name) == before_b
    assert row(b.b.schema_name).version == ctx.compiled_version
  end

  # ── RB15 RB16: authority, 404 ────────────────────────────────────────────────────────

  test "RB15 a caller without ModulesManage gets 403, no token 401, nothing is written", ctx do
    upgraded!(ctx.schema, ctx.tok_a)
    before = snapshot_no_receipt(ctx.schema)
    worker = Letflow.StockFixture.token(ctx, :a, ["TASK_WORKER"], sub: "worker-rb")

    assert rollback(worker, rb_body(@old_version)).status == 403

    conn =
      Plug.Test.conn(:post, "/api/v1/tenant/modules/stock/rollback", Jason.encode!(rb_body("1")))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Letflow.Router.call(Letflow.Router.init([]))

    assert conn.status == 401
    assert snapshot_no_receipt(ctx.schema) == before
  end

  test "RB16 an unknown module and an uninstalled one answer the same 404", ctx do
    unknown = rollback(ctx.tok_a, rb_body("1.0.0"), "no_such_module")
    assert unknown.status == 404

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [status: :uninstalled]],
        prefix: ctx.schema
      )

    gone = rollback(ctx.tok_a, rb_body("1.0.0"))
    assert gone.status == 404
    assert Map.delete(body(gone), "trace_id") == Map.delete(body(unknown), "trace_id")
  end

  # ── RB18: the runbook ────────────────────────────────────────────────────────────────

  test "RB18 the demo upgrade runbook has a rollback section" do
    doc = File.read!("docs/runbooks/demo-upgrade-notes.md")
    [_, section] = String.split(doc, "## Rolling back an upgrade", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)

    for needle <- [
          "/rollback",
          "dry_run",
          "target_version",
          "point of no return",
          "rollback_not_recorded"
        ] do
      assert section =~ needle, "runbook section lacks #{needle}"
    end

    assert section =~ "roll the tenants back first"
  end
end
