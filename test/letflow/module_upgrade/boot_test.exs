Code.require_file("../modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.ModuleUpgrade.BootTest do
  @moduledoc """
  REQ-772 / T-1398 (B1..B6, BX, BY, BZ): `Letflow.ModuleUpgrade.Boot` upgrade on deploy behind a flag
  that defaults off. Stock tenants made older as in `upgrade_http_test.exs`, then the boot child is
  started by hand and the receipt task is claimed and completed through the real router with a real
  bearer token (D-098). Committed tenants, Sandbox `:auto`, `async: false`. Outcomes are always
  filtered by the test's own tenant ids (the cluster may hold tenants of other tests).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.EntityDefinition
  alias Letflow.ModuleUpgrade.Boot
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Plugs.ClientIp
  alias Letflow.Repo
  alias Letflow.StockPostingFixture, as: P

  @old_hash String.duplicate("7", 64)
  @system "00000000-0000-0000-0000-000000000000"

  setup do
    ctx = P.setup!([:a, :b])
    {:ok, entry} = Catalog.fetch("stock")
    {:ok, hash} = Catalog.manifest_hash("stock")
    on_exit(fn -> Application.delete_env(:letflow, :module_upgrade_on_boot) end)
    Map.merge(ctx, %{compiled_version: entry.manifest().version, compiled_hash: hash})
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────

  defp flag!(value), do: Application.put_env(:letflow, :module_upgrade_on_boot, value)

  defp post_json(path, tok, body) do
    Plug.Test.conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp age!(schema, version \\ "0.10.0", hash \\ @old_hash) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [version: version, manifest_hash: hash, accepted_manifest_hashes: []]],
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

  # An older stock_receipt: the active definition without its optional "note" field (a real class A change).
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
  end

  # A class C row: a managed type renamed away.
  defp class_c!(schema) do
    row =
      Repo.get_by!(EntityDefinition, [name: "stock_receipt_line", status: :active],
        prefix: schema
      )

    with_triggers_off(schema, "entity_definitions", fn ->
      {1, _} =
        Repo.update_all(
          from(d in EntityDefinition, where: d.id == ^row.id),
          [set: [name: "stock_gone"]],
          prefix: schema
        )
    end)
  end

  defp complete_status(ctx, task) do
    assert post_json("/api/v1/tasks/#{task.id}/claim", ctx.tok_a, %{}).status == 200

    post_json("/api/v1/tasks/#{task.id}/complete", ctx.tok_a, %{"output_variables" => %{}}).status
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

  defp snapshot(schema) do
    %{
      row: row(schema),
      journal: count(schema, "tenant_module_upgrades"),
      audit: audit_count(schema),
      entity_defs: count(schema, "entity_definitions"),
      defs: count(schema, "process_definitions")
    }
  end

  defp outcomes(tenant_ids) do
    Enum.filter(Boot.list_outcomes(), &(&1.tenant_id in tenant_ids))
  end

  defp older_receipt!(ctx) do
    doc = P.issue!(ctx)
    task = P.pending_task(ctx, doc["id"], "post")
    age!(ctx.schema)
    {doc, task}
  end

  # ── B1: the flag ─────────────────────────────────────────────────────────────────────

  describe "flag off (the default)" do
    test "B1 start_link changes no row and writes no journal row; the receipt still refuses",
         ctx do
      {_doc, task} = older_receipt!(ctx)
      before = snapshot(ctx.schema)

      assert Boot.start_link(nil) == :ignore

      assert snapshot(ctx.schema) == before
      assert before.row.version == "0.10.0"
      refute complete_status(ctx, task) == 200
    end

    test "B1b the flag key and the env var are documented in the runbook" do
      doc = File.read!("docs/runbooks/module-write-handlers-manifest-hash.md")
      assert doc =~ "module_upgrade_on_boot"
      assert doc =~ "LETFLOW_MODULE_UPGRADE_ON_BOOT"
    end

    test "B1c only the value true turns the flag on; the env parser takes exactly true or false" do
      refute Boot.flag_on?()

      for off <- [false, nil, "true", 1, :true_ish] do
        flag!(off)
        refute Boot.flag_on?(), inspect(off)
      end

      flag!(true)
      assert Boot.flag_on?()

      assert ClientIp.parse_enabled(nil, false) == {:ok, false}
      assert ClientIp.parse_enabled("true", false) == {:ok, true}
      assert ClientIp.parse_enabled("false", false) == {:ok, false}
      assert ClientIp.parse_enabled("yes", false) == {:error, :invalid_boolean}
    end
  end

  # ── B2, B5: Class A, idempotent ──────────────────────────────────────────────────────

  describe "flag on, class A only" do
    test "B2 B5 the older tenant is upgraded, the receipt posts over HTTP, a second boot changes nothing",
         ctx do
      flag!(true)
      {doc, task} = older_receipt!(ctx)

      assert Boot.start_link(nil) == :ignore

      upgraded = row(ctx.schema)
      assert upgraded.version == ctx.compiled_version
      assert upgraded.manifest_hash == ctx.compiled_hash
      assert @old_hash in upgraded.accepted_manifest_hashes

      assert [done] = journal(ctx.schema, :done)
      assert done.actor_id == @system
      assert done.rationale == "upgrade on deploy to " <> ctx.compiled_version
      assert audit_count(ctx.schema) == 1

      assert %{rows: [[@system, rationale]]} =
               Repo.query!(
                 ~s|SELECT actor_id::text, after_state->>'rationale' FROM "#{ctx.schema}".audit_entries WHERE action = 'module.upgrade'|
               )
               |> Map.take([:rows])

      assert rationale == done.rationale

      assert [%{outcome: :upgraded, module_id: "stock", error_code: nil}] =
               outcomes([ctx.a.tenant_id])

      assert complete_status(ctx, task) == 200
      assert P.counts(ctx, doc["id"]).entries != %{}

      # B5: a second boot
      after_first = snapshot(ctx.schema)
      listed = outcomes([ctx.a.tenant_id])
      assert Boot.start_link(nil) == :ignore
      assert snapshot(ctx.schema) == after_first
      assert outcomes([ctx.a.tenant_id]) == listed
    end

    test "B2b a real class A entity change is created and activated, then the receipt posts",
         ctx do
      flag!(true)
      doc = P.issue!(ctx)
      task = P.pending_task(ctx, doc["id"], "post")
      trim_receipt!(ctx.schema)
      age!(ctx.schema)
      before = count(ctx.schema, "entity_definitions")

      assert Boot.start_link(nil) == :ignore

      assert count(ctx.schema, "entity_definitions") > before

      active =
        Repo.one!(
          from(d in EntityDefinition, where: d.name == "stock_receipt" and d.status == :active),
          prefix: ctx.schema
        )

      assert Enum.any?(active.definition_json["fields"], &(&1["name"] == "note"))
      assert complete_status(ctx, task) == 200
    end
  end

  # ── B3: left for the admin ───────────────────────────────────────────────────────────

  describe "not applicable on boot" do
    test "B3 BZ a class C plan is left for the admin; a re-plan with another hash drops it",
         ctx do
      flag!(true)
      age!(ctx.schema)
      class_c!(ctx.schema)
      before = row(ctx.schema)

      assert Boot.start_link(nil) == :ignore

      assert row(ctx.schema) == before
      assert journal(ctx.schema, :done) == []

      assert [%{outcome: :left_for_admin, module_id: "stock", error_code: nil}] =
               outcomes([ctx.a.tenant_id])

      # BZ: the admin plans again after the tenant changed: the older planned row is abandoned
      class_c_again =
        Repo.get_by!(EntityDefinition, [name: "stock_receipt", status: :active],
          prefix: ctx.schema
        )

      with_triggers_off(ctx.schema, "entity_definitions", fn ->
        {1, _} =
          Repo.update_all(
            from(d in EntityDefinition, where: d.id == ^class_c_again.id),
            [set: [name: "stock_gone_two"]],
            prefix: ctx.schema
          )
      end)

      assert post_json("/api/v1/tenant/modules/stock/upgrade/plan", ctx.tok_a, %{}).status == 200
      assert outcomes([ctx.a.tenant_id]) == []
    end

    test "B3b a tenant below min_upgradable_from changes nothing and is not an upgraded outcome",
         ctx do
      flag!(true)
      age!(ctx.schema, "0.1.0")
      before = row(ctx.schema)

      assert Boot.start_link(nil) == :ignore

      assert row(ctx.schema) == before
      assert journal(ctx.schema, :done) == []
      refute Enum.any?(outcomes([ctx.a.tenant_id]), &(&1.outcome == :upgraded))
    end
  end

  # ── B4: never fails boot ─────────────────────────────────────────────────────────────

  describe "failures" do
    test "B4 a raising apply is listed as failed, the next tenant is upgraded, metadata carries the ids",
         ctx do
      flag!(true)
      b = P.tenant_b!(ctx)
      age!(ctx.schema)
      age!(b.b.schema_name)
      before_a = row(ctx.schema)

      Repo.query!("""
      CREATE FUNCTION "#{ctx.schema}".t1398_fail() RETURNS trigger LANGUAGE plpgsql AS
      $$ BEGIN RAISE EXCEPTION 'boom'; END $$
      """)

      Repo.query!("""
      CREATE TRIGGER t1398_fail BEFORE UPDATE ON "#{ctx.schema}".tenant_modules
      FOR EACH ROW EXECUTE FUNCTION "#{ctx.schema}".t1398_fail()
      """)

      log =
        capture_log([format: "$message $metadata", metadata: :all], fn ->
          assert Boot.start_link(nil) == :ignore
        end)

      assert row(ctx.schema) == before_a
      assert row(b.b.schema_name).version == ctx.compiled_version

      assert [%{outcome: :failed, error_code: "internal_error"}] = outcomes([ctx.a.tenant_id])
      assert [%{outcome: :upgraded}] = outcomes([b.b.tenant_id])

      assert log =~ "tenant_id=#{ctx.a.tenant_id}"
      assert log =~ "module_id=stock"
      assert log =~ "code=internal_error"
      refute log =~ "boom"
      assert log =~ "module upgrade on boot: upgrade failed"
    end

    test "B4b an unreadable tenant is logged and the others proceed", ctx do
      flag!(true)
      b = P.tenant_b!(ctx)
      age!(b.b.schema_name)
      Repo.query!(~s|DROP TABLE "#{ctx.schema}".tenant_modules CASCADE|)

      log =
        capture_log([format: "$message $metadata", metadata: :all], fn ->
          assert Boot.start_link(nil) == :ignore
        end)

      assert log =~ "tenant unreadable"
      assert log =~ "tenant_id=#{ctx.a.tenant_id}"
      assert row(b.b.schema_name).version == ctx.compiled_version
    end
  end

  # ── BX, BY ───────────────────────────────────────────────────────────────────────────

  describe "boundary and shape" do
    test "BX two older tenants are upgraded each in its own schema", ctx do
      flag!(true)
      b = P.tenant_b!(ctx)
      age!(ctx.schema)
      age!(b.b.schema_name)

      assert Boot.start_link(nil) == :ignore

      assert row(ctx.schema).version == ctx.compiled_version
      assert row(b.b.schema_name).version == ctx.compiled_version
      assert [_one] = journal(ctx.schema, :done)
      assert [_one] = journal(b.b.schema_name, :done)
      assert audit_count(ctx.schema) == 1
      assert audit_count(b.b.schema_name) == 1

      mine = outcomes([ctx.a.tenant_id, b.b.tenant_id])

      assert Enum.sort(Enum.map(mine, & &1.tenant_id)) ==
               Enum.sort([ctx.a.tenant_id, b.b.tenant_id])
    end

    test "BY list_outcomes rows carry exactly the allow-listed keys", ctx do
      flag!(true)
      age!(ctx.schema)

      assert Boot.start_link(nil) == :ignore

      assert [outcome] = outcomes([ctx.a.tenant_id])

      assert outcome |> Map.keys() |> Enum.sort() ==
               ~w(at error_code module_id outcome tenant_id)a

      assert %DateTime{} = outcome.at
    end
  end
end
