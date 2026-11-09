Code.require_file("../modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.ModuleUpgrade.DataStepsHttpTest do
  @moduledoc """
  REQ-773 / T-1581 (D1..D11): declarative data steps through the REAL routes
  (`POST /api/v1/tenant/modules/:module_id/upgrade/plan` and `/upgrade`, full `Letflow.Router`,
  bearer tokens). The fixture module `fixture_data_step` is installed at its 1.2.0 shape, then the
  tenant row and the active `fds_item` definition are aged to 1.0.0 (only `name`) and the records
  lose `status`, so the plan is a Class B change covered by the manifest's two steps.
  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.ModuleUpgrade.StepExec
  alias Letflow.Modules.FixtureDataStep, as: Fixture
  alias Letflow.Modules.Installs
  alias Letflow.Modules.StepRecords
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Repo
  alias Letflow.StockPostingFixture, as: P

  @module "fixture_data_step"
  @old_hash String.duplicate("7", 64)

  setup do
    ctx = P.setup!([:a, :b])
    on_exit(fn -> Application.delete_env(:letflow, :module_upgrade_one_tx_max_records) end)
    ctx
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────

  defp post(path, tok, body \\ %{}) do
    Plug.Test.conn(:post, "/api/v1/tenant/modules/#{@module}/" <> path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp plan(tok), do: post("upgrade/plan", tok)

  defp plan!(tok), do: tok |> plan() |> P.status!(200)

  defp apply_upgrade(tok, report, ack \\ ["s1", "s2"]) do
    post("upgrade", tok, %{
      "plan_hash" => report["plan_hash"],
      "rationale" => "backfill",
      "ack_destructive" => ack
    })
  end

  defp sql!(sql, params \\ []), do: Repo.query!(sql, params)

  defp with_triggers_off(schema, table, fun) do
    sql!(~s|ALTER TABLE "#{schema}"."#{table}" DISABLE TRIGGER USER|)
    fun.()
    sql!(~s|ALTER TABLE "#{schema}"."#{table}" ENABLE TRIGGER USER|)
  end

  # Installs the module (1.2.0 shape), creates `names.length` records, then ages the tenant to 1.0.0:
  # the row, the active definition (name only) and the records (no status, no label).
  defp prepare!(schema, names) do
    {:ok, _} =
      Installs.install(@module, Ecto.UUID.generate(),
        prefix: schema,
        rationale: "fixture install"
      )

    ids =
      for name <- names do
        {:ok, result} = Fixture.create_record(%{"name" => name, "status" => "x"}, schema)
        result.record.record_id
      end

    with_triggers_off(schema, "entity_definitions", fn ->
      sql!(
        ~s|UPDATE "#{schema}".entity_definitions SET definition_json = $1 WHERE name = 'fds_item' AND status = 'active'|,
        [
          %{
            "name" => "fds_item",
            "display_name" => "Data Step Item",
            "description" =>
              "REQ-773 test fixture: a type whose 1.2.0 shape adds a required status and an optional label.",
            "fields" => [
              %{"name" => "name", "type" => "string", "queried" => true, "required" => true}
            ]
          }
        ]
      )
    end)

    with_triggers_off(schema, "entity_record_latest", fn ->
      sql!(~s|UPDATE "#{schema}".entity_record_latest SET field_values = field_values - 'status'|)
    end)

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == ^@module),
        [set: [version: "1.0.0", manifest_hash: @old_hash, accepted_manifest_hashes: []]],
        prefix: schema
      )

    ids
  end

  defp set_values!(schema, id, sql_expr) do
    with_triggers_off(schema, "entity_record_latest", fn ->
      sql!(
        ~s|UPDATE "#{schema}".entity_record_latest SET field_values = #{sql_expr} WHERE record_id = $1|,
        [Ecto.UUID.dump!(id)]
      )
    end)
  end

  defp values(schema, id) do
    {:ok, latest} = Latest.get(id, "fds_item", schema)
    latest.field_values
  end

  defp migrated_events(schema) do
    Repo.all(from(e in Event, where: e.event_type == "ENTITY_RECORD_MIGRATED"), prefix: schema)
  end

  defp count(schema, table),
    do: sql!(~s|SELECT count(*) FROM "#{schema}"."#{table}"|).rows |> hd() |> hd()

  defp audit_count(schema),
    do:
      sql!(~s|SELECT count(*) FROM "#{schema}".audit_entries WHERE action = 'module.upgrade'|).rows
      |> hd()
      |> hd()

  defp snapshot(schema, ids) do
    %{
      values: Map.new(ids, &{&1, values(schema, &1)}),
      events: length(migrated_events(schema)),
      versions: count(schema, "entity_definitions"),
      row:
        Repo.get_by!(TenantModule, [module_id: @module], prefix: schema)
        |> Map.take([:version, :manifest_hash]),
      audit: audit_count(schema)
    }
  end

  defp restrict_field!(schema, field) do
    sql!(
      ~s|INSERT INTO "#{schema}".entity_field_restrictions (id, entity_type, field_name, inserted_at, updated_at) VALUES (gen_random_uuid(), 'fds_item', $1, now(), now())|,
      [field]
    )
  end

  defp step(report, id), do: Enum.find(report["data_steps"], &(&1["id"] == id))

  # ── D1: the steps run ────────────────────────────────────────────────────────────────

  test "D1 plan and apply run both steps; counts, events, audit and body", ctx do
    ids = prepare!(ctx.schema, ["  one ", "two", " three"])

    report = plan!(ctx.tok_a)
    assert report["fits_one_transaction"] == true
    assert report["data_step_records"] == 6

    assert step(report, "s1") == %{
             "id" => "s1",
             "op" => "set_default",
             "type" => "fds_item",
             "records" => 3
           }

    assert step(report, "s2")["records"] == 3

    assert Enum.all?(
             report["entity_types"],
             &(&1["class"] != "B" or &1["covered_by_steps"] == true)
           )

    refute Map.has_key?(report, "data_step_bound")
    assert Enum.map(report["steps"], & &1["op"]) == ["set_default", "copy_field"]

    body = apply_upgrade(ctx.tok_a, report) |> P.status!(200)

    for {id, name} <- Enum.zip(ids, ["one", "two", "three"]) do
      assert %{"status" => "new", "label" => ^name} = values(ctx.schema, id)
    end

    events = migrated_events(ctx.schema)
    assert length(events) == 6
    assert Enum.all?(events, &(&1.payload["upgrade_id"] == report["plan_id"]))

    assert events |> Enum.map(& &1.payload["step_id"]) |> Enum.frequencies() == %{
             "s1" => 3,
             "s2" => 3
           }

    assert body["records_migrated"] == 6
    assert Enum.map(body["data_steps"], &{&1["id"], &1["records"]}) == [{"s1", 3}, {"s2", 3}]
    assert body["state"] == "done"

    # one module.upgrade audit entry, no per-record audit rows for the migrated records
    assert audit_count(ctx.schema) == 1

    %{rows: [[step_ids, counts]]} =
      sql!(
        ~s|SELECT after_state -> 'step_ids', after_state -> 'counts' FROM "#{ctx.schema}".audit_entries WHERE action = 'module.upgrade'|
      )

    assert step_ids == ["s1", "s2"]
    assert counts["records_migrated"] == 6 and counts["data_steps"] == 2

    row = Repo.get_by!(TenantModule, [module_id: @module], prefix: ctx.schema)
    assert row.version == "1.2.0"

    # a repeat answers the stored body and writes nothing
    assert apply_upgrade(ctx.tok_a, report) |> P.status!(200) == body
    assert length(migrated_events(ctx.schema)) == 6
  end

  # ── D2: only where unset ─────────────────────────────────────────────────────────────

  test "D2 a value, false and 0 are kept; null and absent receive the default", ctx do
    [absent, keep, jnull, falsy] = prepare!(ctx.schema, ["a", "b", "c", "d"])
    set_values!(ctx.schema, keep, ~s[field_values || '{"status":"keep","label":"mine"}'::jsonb])
    set_values!(ctx.schema, jnull, ~s[field_values || '{"status":null}'::jsonb])
    set_values!(ctx.schema, falsy, ~s[field_values || '{"status":false,"label":0}'::jsonb])

    report = plan!(ctx.tok_a)
    assert step(report, "s1")["records"] == 2
    assert step(report, "s2")["records"] == 2
    apply_upgrade(ctx.tok_a, report) |> P.status!(200)

    assert %{"status" => "new", "label" => "a"} = values(ctx.schema, absent)
    assert %{"status" => "keep", "label" => "mine"} = values(ctx.schema, keep)
    assert %{"status" => "new", "label" => "c"} = values(ctx.schema, jnull)
    assert %{"status" => false, "label" => 0} = values(ctx.schema, falsy)

    touched =
      migrated_events(ctx.schema) |> Enum.map(& &1.payload["record_id"]) |> Enum.frequencies()

    assert touched[absent] == 2 and touched[jnull] == 2
    assert touched[falsy] == nil and touched[keep] == nil
  end

  # ── D3 / D4: rollback ────────────────────────────────────────────────────────────────

  test "D3 a failing record rolls everything back (step_raised); a later fix succeeds", ctx do
    ids = prepare!(ctx.schema, ["a", "b", "c", "d", "e"])
    # the third record: a number cannot be written to the promoted string column of `name`
    set_values!(ctx.schema, Enum.at(ids, 2), ~s[field_values || '{"name":5}'::jsonb])
    before = snapshot(ctx.schema, ids)

    report = plan!(ctx.tok_a)
    conn = apply_upgrade(ctx.tok_a, report)
    assert conn.status == 409

    assert %{"code" => "upgrade_failed", "error_code" => "step_raised"} =
             Jason.decode!(conn.resp_body)

    assert snapshot(ctx.schema, ids) == before
    refute Enum.any?(Map.values(before.values), &Map.has_key?(&1, "status"))

    failed =
      Repo.all(from(u in TenantModuleUpgrade, where: u.state == :failed), prefix: ctx.schema)

    assert [%{error_code: "step_raised"}] = failed

    set_values!(ctx.schema, Enum.at(ids, 2), ~s[field_values || '{"name":"c"}'::jsonb])
    report = plan!(ctx.tok_a)
    apply_upgrade(ctx.tok_a, report) |> P.status!(200)
    assert %{"status" => "new", "label" => "c"} = values(ctx.schema, Enum.at(ids, 2))
  end

  test "D4 a raise inside the batch rolls everything back (step_raised)", ctx do
    ids = prepare!(ctx.schema, ["a", "b", "c"])

    sql!(
      ~s|CREATE OR REPLACE FUNCTION "#{ctx.schema}".fds_boom() RETURNS trigger AS $$ BEGIN IF NEW.field_values->>'label' = 'c' THEN RAISE EXCEPTION 'boom'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql|
    )

    sql!(
      ~s|CREATE TRIGGER fds_boom BEFORE UPDATE ON "#{ctx.schema}".entity_record_latest FOR EACH ROW EXECUTE FUNCTION "#{ctx.schema}".fds_boom()|
    )

    before = snapshot(ctx.schema, ids)
    report = plan!(ctx.tok_a)
    conn = apply_upgrade(ctx.tok_a, report)
    assert conn.status == 409
    assert %{"code" => "upgrade_failed", "error_code" => code} = Jason.decode!(conn.resp_body)
    assert code in ["step_raised", "step_error"]
    refute conn.resp_body =~ "boom"

    assert snapshot(ctx.schema, ids) == before

    assert [%{error_code: ^code}] =
             Repo.all(from(u in TenantModuleUpgrade, where: u.state == :failed),
               prefix: ctx.schema
             )
  end

  # ── D5: the cap ──────────────────────────────────────────────────────────────────────

  test "D5 more records than the cap: the plan says so, the apply answers 409 and writes nothing",
       ctx do
    ids = prepare!(ctx.schema, ["a", "b", "c"])
    Application.put_env(:letflow, :module_upgrade_one_tx_max_records, 2)
    before = snapshot(ctx.schema, ids)

    report = plan!(ctx.tok_a)
    assert report["fits_one_transaction"] == false
    refute Map.has_key?(report, "data_step_bound")

    conn = apply_upgrade(ctx.tok_a, report)
    assert conn.status == 409
    assert %{"code" => "upgrade_needs_runner"} = Jason.decode!(conn.resp_body)
    assert snapshot(ctx.schema, ids) == before

    Application.put_env(:letflow, :module_upgrade_one_tx_max_records, 6)
    report = plan!(ctx.tok_a)
    assert report["fits_one_transaction"] == true
    apply_upgrade(ctx.tok_a, report) |> P.status!(200)
  end

  # ── D8: cross tenant (INV-10) ────────────────────────────────────────────────────────

  test "D8 another tenant's plan_hash does not apply here; the module is not installed in A",
       ctx do
    ctx = Map.merge(ctx, P.tenant_b!(ctx))
    ids_b = prepare!(ctx.b.schema_name, ["x", "y"])
    report_b = plan!(ctx.tok_b)
    before_b = snapshot(ctx.b.schema_name, ids_b)

    # tenant A has not installed the module: same 404 as for an unknown module
    assert apply_upgrade(ctx.tok_a, report_b).status == 404
    assert plan(ctx.tok_a).status == 404

    # tenant A installs it too: B's hash is not A's plan
    ids_a = prepare!(ctx.schema, ["p", "q"])
    before_a = snapshot(ctx.schema, ids_a)
    conn = apply_upgrade(ctx.tok_a, report_b)
    assert conn.status == 409
    assert %{"code" => "plan_mismatch"} = Jason.decode!(conn.resp_body)

    assert snapshot(ctx.schema, ids_a) == before_a
    assert snapshot(ctx.b.schema_name, ids_b) == before_b
  end

  # ── D9 / D10 / D11: INV-2 ────────────────────────────────────────────────────────────

  test "D9 a restricted target field: no count anywhere, the cap still decides", ctx do
    ids = prepare!(ctx.schema, ["a", "b", "c"])
    restrict_field!(ctx.schema, "status")

    report = plan!(ctx.tok_a)

    assert step(report, "s1") == %{
             "id" => "s1",
             "op" => "set_default",
             "type" => "fds_item",
             "records" => nil
           }

    assert report["data_step_records"] == nil
    assert report["fits_one_transaction"] == true

    # the bound is the type's live total (3) + the unrestricted step's count (3) = 6: cap 5 refuses
    Application.put_env(:letflow, :module_upgrade_one_tx_max_records, 5)
    before = snapshot(ctx.schema, ids)
    report = plan!(ctx.tok_a)
    assert report["fits_one_transaction"] == false
    conn = apply_upgrade(ctx.tok_a, report)
    assert conn.status == 409
    assert %{"code" => "upgrade_needs_runner"} = Jason.decode!(conn.resp_body)
    assert snapshot(ctx.schema, ids) == before

    Application.put_env(:letflow, :module_upgrade_one_tx_max_records, 10)
    report = plan!(ctx.tok_a)
    body = apply_upgrade(ctx.tok_a, report) |> P.status!(200)

    assert body["records_migrated"] == nil
    assert Enum.all?(body["data_steps"], &(not Map.has_key?(&1, "records")))

    %{rows: [[counts]]} =
      sql!(
        ~s|SELECT after_state -> 'counts' FROM "#{ctx.schema}".audit_entries WHERE action = 'module.upgrade'|
      )

    refute Map.has_key?(counts, "records_migrated")
    assert %{"status" => "new"} = values(ctx.schema, hd(ids))
  end

  test "D10 a restricted copy source hides that step's count only", ctx do
    prepare!(ctx.schema, ["a", "b"])
    restrict_field!(ctx.schema, "name")

    report = plan!(ctx.tok_a)
    assert step(report, "s1")["records"] == 2
    assert step(report, "s2")["records"] == nil
    assert report["data_step_records"] == nil
  end

  test "D11 a type the actor is denied by TypeAccess shows no count", ctx do
    prepare!(ctx.schema, ["a", "b"])

    sql!(
      ~s|INSERT INTO "#{ctx.schema}".entity_type_restrictions (id, entity_type, inserted_at, updated_at) VALUES (gen_random_uuid(), 'fds_item', now(), now())|
    )

    report = plan!(ctx.tok_a)
    assert Enum.map(report["data_steps"], & &1["records"]) == [nil, nil]
    assert report["data_step_records"] == nil
    assert report["fits_one_transaction"] == true
  end

  # ── X: the executor itself (specs the fixture manifest does not carry) ──────────────

  @actor "00000000-0000-0000-0000-000000000000"

  defp run_steps(schema, steps, module \\ @module) do
    Repo.transaction(fn ->
      case StepExec.run_all(
             schema,
             Ecto.UUID.generate(),
             String.duplicate("a", 64),
             @actor,
             module,
             steps
           ) do
        {:ok, results} -> results
        {:error, code} -> Repo.rollback(code)
      end
    end)
  end

  defp spec(id, spec), do: %{id: id, spec: Map.put(spec, :type, "fds_item")}

  defp copy(transform), do: %{op: :copy_field, from: "name", to: "label", transform: transform}

  test "X3 copy_field with to_decimal", ctx do
    ids = prepare!(ctx.schema, ["12.50", " 7 ", "3"])

    assert {:ok, [%{"id" => "x1", "op" => "copy_field", "records" => 3}]} =
             run_steps(ctx.schema, [spec("x1", copy(:to_decimal))])

    assert Enum.map(ids, &values(ctx.schema, &1)["label"]) == ["12.50", "7", "3"]
  end

  test "X4 backfill_from_constant fills only the unset; a second run changes nothing", ctx do
    [a, b] = prepare!(ctx.schema, ["a", "b"])
    set_values!(ctx.schema, b, ~s[field_values || '{"label":"mine"}'::jsonb])
    step = spec("x2", %{op: :backfill_from_constant, field: "label", value: "zz"})

    assert {:ok, [%{"records" => 1}]} = run_steps(ctx.schema, [step])
    assert values(ctx.schema, a)["label"] == "zz"
    assert values(ctx.schema, b)["label"] == "mine"
    assert {:ok, [%{"records" => 0}]} = run_steps(ctx.schema, [step])
    assert length(migrated_events(ctx.schema)) == 1
  end

  test "X1 a failed transform is step_error and the transaction rolls back", ctx do
    ids = prepare!(ctx.schema, ["12.50", "abc", "7"])
    assert {:error, :step_error} = run_steps(ctx.schema, [spec("x1", copy(:to_decimal))])
    assert migrated_events(ctx.schema) == []
    assert Enum.all?(ids, &(not Map.has_key?(values(ctx.schema, &1), "label")))
  end

  test "X5 a type the module does not manage, an unrunnable op and an unknown prefix are step_error",
       ctx do
    prepare!(ctx.schema, ["a"])
    step = spec("x1", copy(:identity))
    assert {:error, :step_error} = run_steps(ctx.schema, [step], "fixture_fk_pack")

    assert {:error, :step_error} =
             run_steps(ctx.schema, [spec("x1", %{op: :rename_field, from: "a", to: "b"})])

    assert {:error, :step_error} =
             run_steps(ctx.schema, [
               %{id: "x1", spec: Map.put(copy(:identity), :type, "no_such_type")}
             ])

    assert StepExec.run_all("tenant_nope", "u", "p", @actor, @module, [step]) ==
             {:error, :step_error}
  end

  test "X6 run_batch is bounded and resumable by its cursor", ctx do
    ids = prepare!(ctx.schema, ["a", "b", "c", "d", "e"])

    {:ok, cap} =
      Letflow.ModuleUpgrade.Capability.new(
        Letflow.TenantProvisioning.tenant_id_for_schema_name(ctx.schema) |> elem(1),
        Ecto.UUID.generate(),
        String.duplicate("a", 64),
        @actor
      )

    step = spec("x1", copy(:identity))

    {:ok, {sizes, last}} =
      Repo.transaction(fn ->
        Enum.reduce_while(1..10, {[], nil}, fn _, {sizes, cursor} ->
          {:ok, %{processed: n, cursor: next}} = StepExec.run_batch(cap, @module, step, cursor, 2)

          if next == :done,
            do: {:halt, {sizes ++ [n], :done}},
            else: {:cont, {sizes ++ [n], next}}
        end)
      end)

    assert sizes == [2, 2, 1]
    assert last == :done
    assert Enum.all?(ids, &(values(ctx.schema, &1)["label"] != nil))
    assert length(migrated_events(ctx.schema)) == 5
  end

  # ── P: the shared predicate ────────────────────────────────────────────────────────

  test "P1 P2 count, candidates, restricted?, live_total, bound and reportable_count", ctx do
    [a, b, c] = prepare!(ctx.schema, ["a", "b", "c"])
    set_values!(ctx.schema, b, ~s[field_values || '{"status":"have"}'::jsonb])
    set_values!(ctx.schema, c, ~s[field_values || '{"status":null}'::jsonb])
    spec = %{op: :set_default, type: "fds_item", field: "status", value: "new"}
    copy = %{op: :copy_field, type: "fds_item", from: "label", to: "name", transform: :identity}

    assert StepRecords.count(spec, ctx.schema) == 2
    assert StepRecords.live_total("fds_item", ctx.schema) == 3
    assert StepRecords.live_total("other", ctx.schema) == 0
    # a copy needs a present source: nobody has a label yet
    assert StepRecords.count(copy, ctx.schema) == 0

    ids =
      spec
      |> StepRecords.candidates_query(nil, 10)
      |> Repo.all(prefix: ctx.schema)
      |> Enum.map(& &1.record_id)

    assert Enum.sort(ids) == Enum.sort([a, c])
    [first | _] = Enum.sort(ids)

    after_first =
      spec
      |> StepRecords.candidates_query(first, 10)
      |> Repo.all(prefix: ctx.schema)
      |> Enum.map(& &1.record_id)

    assert after_first == ids |> Enum.sort() |> tl()

    assert StepRecords.fields(copy) == ["label", "name"]
    refute StepRecords.restricted?(spec, ctx.schema)
    assert StepRecords.reportable_count(spec, ctx.schema, @actor) == 2
    assert StepRecords.reportable_count(spec, ctx.schema, nil) == nil
    assert StepRecords.bound(spec, ctx.schema) == 2

    restrict_field!(ctx.schema, "status")
    assert StepRecords.restricted?(spec, ctx.schema)
    assert StepRecords.reportable_count(spec, ctx.schema, @actor) == nil
    # field-independent: the live total, not the number of unset records
    assert StepRecords.bound(spec, ctx.schema) == 3
    # the copy reads `label` and writes `name`: not restricted
    refute StepRecords.restricted?(copy, ctx.schema)
  end
end
