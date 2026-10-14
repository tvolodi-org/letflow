defmodule Letflow.Entities.ScriptReadsTest do
  @moduledoc """
  GH 2534 PR 7c-2, design `lib/letflow/design/gh2534-7c-script-handler.md` sections 11.1-11.3,
  ACs AC23, AC24, AC25, AC26, AC28 (and the 7b-2a section 8 read contract, SEC N1).

  Every run goes through the REAL path: a published version bound by an active definition, a
  real instance, `ScriptTaskDispatcher.claim_next/1` + `run_claimed/2` in the test process, the
  real `Letflow.Scripts.Runtime.prepare_run/3`, the configured port
  (`Letflow.Entities.ScriptReads`) and the real Lua runner. Record queries are counted with Ecto
  telemetry scoped to the test pid: a "record query" is one whose SQL reads
  `entity_record_latest` or the type's own per-type table.

  `async: false`: provisioning switches the sandbox to `:auto`; tests flip application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.Records
  alias Letflow.Entities.ScriptReads
  alias Letflow.Support.PlatformTenantFixture, as: QueryCapture
  alias Letflow.Support.ScriptPolicyFixture, as: SP
  alias Letflow.Support.ScriptTaskFixture, as: F

  @type_name "customer"

  # The script hands back what it was given: the rows of read `r` and their count.
  @source "local rows = ctx.input.reads.r\nreturn { n = #rows, rows = rows }"

  setup do
    t = F.tenant!("gh2534-7c2-reads")
    assert {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)
    SP.active_definition!(t.schema_name, @type_name)
    SP.flag!(t.schema_name, @type_name)
    %{t: t, schema: t.schema_name}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp manifest(reads) do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"cid" => %{"type" => "string"}, "tier" => %{"type" => "string"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"n" => %{"type" => "integer"}, "rows" => %{}},
        "required" => ["n"],
        "additionalProperties" => false
      },
      "fail_codes" => [],
      "limits" => %{"instructions" => 200_000, "timeout_ms" => 1_000},
      "reads" => reads
    }
  end

  defp id_read(fields \\ ["name"]), do: SP.id_read("r", @type_name, fields)

  defp tier_read(limit, fields \\ ["name"]),
    do: SP.field_read("r", @type_name, "tier", %{"limit" => limit, "fields" => fields})

  defp record!(schema, values) do
    assert {:ok, %{record: record}} =
             Records.create_record(
               %{
                 entity_type: @type_name,
                 field_values: values,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    record.record_id
  end

  defp delete!(schema, record_id) do
    assert {:ok, _} =
             Records.delete_record(
               %{
                 entity_type: @type_name,
                 record_id: record_id,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )
  end

  # Binds a fresh published version with `reads` and starts one instance with `variables`.
  defp bound!(t, reads, variables) do
    manifest = manifest(reads)
    assert Letflow.Scripts.Validation.manifest(manifest) == :ok
    F.bound!(t, @source, manifest, variables)
  end

  # Claims and runs the next due row in THIS process, capturing its queries.
  defp run_capturing(schema) do
    {{row, result}, queries} = QueryCapture.capture_repo_queries(fn -> F.run_next!(schema) end)
    {F.reload(schema, row), result, queries}
  end

  defp record_queries(queries) do
    {:ok, table} = Letflow.TenantProvisioning.table_name_for_entity_type(@type_name)

    Enum.filter(queries, fn metadata ->
      sql = Map.get(metadata, :query) || ""
      String.contains?(sql, ~s("entity_record_latest")) or String.contains?(sql, ~s("#{table}"))
    end)
  end

  defp output(schema, instance_id) do
    variables = F.projection(schema, instance_id).variables
    {variables["n"], variables["rows"]}
  end

  defp assert_rejected_before_any_record_query(t, b) do
    {row, result, queries} = run_capturing(t.schema_name)
    assert result == {:ok, :failed}
    assert row.status == "failed"
    assert row.outcome == "script_rejected"
    assert row.outcome_detail == "reads_not_allowed"
    assert record_queries(queries) == []
    refute_received {:script_runner_called, _pid, _in_tx}
    assert F.projection(t.schema_name, b.instance_id).status == :error
  end

  # ── AC23 ────────────────────────────────────────────────────────────────────

  describe "AC23" do
    test "rows shape: id plus the declared fields, through the real dispatcher", %{t: t} = ctx do
      cid = record!(ctx.schema, %{"name" => "Ann", "tier" => "gold", "ssn" => "111"})
      F.record_read_port_calls!()
      b = bound!(t, [id_read(["name", "tier"])], %{"cid" => cid, "tier" => "gold"})

      {row, result, queries} = run_capturing(ctx.schema)
      assert result == {:ok, :applied}, inspect(row)
      assert row.outcome == "ok"
      assert length(record_queries(queries)) == 1

      assert {1, [%{"id" => ^cid, "name" => "Ann", "tier" => "gold"} = delivered]} =
               output(ctx.schema, b.instance_id)

      assert Map.keys(delivered) |> Enum.sort() == ["id", "name", "tier"]

      # the port got the run's own prefix and only the script's declared input variables
      schema = ctx.schema
      assert_received {:script_read_port_called, ^schema, [_read], vars}
      assert vars == %{"cid" => cid, "tier" => "gold"}
    end

    test "miss equivalence one query: hit, miss, deleted, malformed and unknown id", ctx do
      hit = record!(ctx.schema, %{"name" => "Hit", "tier" => "gold"})
      gone = record!(ctx.schema, %{"name" => "Gone", "tier" => "gold"})
      delete!(ctx.schema, gone)

      cases = [
        {:hit, %{"cid" => hit}, 1},
        {:miss_absent_variable, %{}, 0},
        {:deleted, %{"cid" => gone}, 0},
        {:malformed, %{"cid" => "not-a-uuid"}, 0},
        {:unknown, %{"cid" => Ecto.UUID.generate()}, 0}
      ]

      shapes =
        for {label, variables, expected_n} <- cases do
          b = bound!(ctx.t, [id_read()], variables)
          {row, result, queries} = run_capturing(ctx.schema)
          assert result == {:ok, :applied}, "#{label}: #{inspect(row)}"
          assert [record_query] = record_queries(queries), "#{label}: exactly one record query"
          assert {^expected_n, _rows} = output(ctx.schema, b.instance_id)
          record_query.query
        end

      # the same statement text for every case: the round trip is the same for hit and miss
      assert length(Enum.uniq(shapes)) == 1
    end

    test "limit cap: a field match returns at most `limit` rows, ordered by record id", ctx do
      ids = for i <- 1..4, do: record!(ctx.schema, %{"name" => "G#{i}", "tier" => "gold"})
      _other = record!(ctx.schema, %{"name" => "S", "tier" => "silver"})

      b = bound!(ctx.t, [tier_read(2)], %{"tier" => "gold"})
      {_row, {:ok, :applied}, queries} = run_capturing(ctx.schema)
      assert length(record_queries(queries)) == 1

      assert {2, rows} = output(ctx.schema, b.instance_id)
      assert Enum.map(rows, & &1["id"]) == ids |> Enum.sort() |> Enum.take(2)
    end

    test "a match value of the wrong type issues the same single query and matches nothing",
         ctx do
      record!(ctx.schema, %{"name" => "G", "tier" => "gold"})

      for value <- [nil, 5, true, ["gold"], %{"a" => "gold"}] do
        {result, queries} =
          QueryCapture.capture_repo_queries(fn ->
            ScriptReads.prefetch(ctx.schema, [tier_read(5)], %{"tier" => value})
          end)

        assert result == {:ok, %{"r" => []}}, inspect(value)
        assert length(record_queries(queries)) == 1
      end

      assert {:ok, %{"r" => [%{"name" => "G"}]}} =
               ScriptReads.prefetch(ctx.schema, [tier_read(5)], %{"tier" => "gold"})
    end
  end

  # ── AC24 ────────────────────────────────────────────────────────────────────

  describe "AC24: run-time causes x4 fail closed before any record query" do
    setup ctx do
      F.count_runner_calls!()
      %{cid: record!(ctx.schema, %{"name" => "Ann", "tier" => "gold"})}
    end

    test "flag cleared after activation", ctx do
      b = bound!(ctx.t, [id_read()], %{"cid" => ctx.cid})

      Repo.delete_all(
        from(m in "script_readable_masters", where: m.entity_type == ^@type_name),
        prefix: ctx.schema
      )

      assert_rejected_before_any_record_query(ctx.t, b)
    end

    test "definition inactive (a flagged type with no active definition)", ctx do
      SP.inactive_definition!(ctx.schema, "ghost")
      SP.flag_raw!(ctx.schema, "ghost")
      b = bound!(ctx.t, [SP.id_read("r", "ghost")], %{"cid" => ctx.cid})
      assert_rejected_before_any_record_query(ctx.t, b)
    end

    test "type restricted after activation", ctx do
      b = bound!(ctx.t, [id_read()], %{"cid" => ctx.cid})
      SP.restrict_type!(ctx.schema, @type_name)
      assert_rejected_before_any_record_query(ctx.t, b)
    end

    test "a declared field no longer on the active definition", ctx do
      b = bound!(ctx.t, [id_read(["name", "nickname"])], %{"cid" => ctx.cid})
      assert_rejected_before_any_record_query(ctx.t, b)
    end
  end

  # ── AC25 ────────────────────────────────────────────────────────────────────

  describe "AC25" do
    test "restriction re-redacts next run, and its removal restores the field", ctx do
      cid = record!(ctx.schema, %{"name" => "Ann", "tier" => "gold", "ssn" => "111"})
      reads = [id_read(["name", "ssn"])]

      run = fn ->
        b = bound!(ctx.t, reads, %{"cid" => cid})
        {_row, {:ok, :applied}, _queries} = run_capturing(ctx.schema)
        {1, [delivered]} = output(ctx.schema, b.instance_id)
        delivered
      end

      assert run.() == %{"id" => cid, "name" => "Ann", "ssn" => "111"}

      SP.restrict_field!(ctx.schema, @type_name, "ssn")
      # omitted, not a sentinel: absent is the same as never set
      assert run.() == %{"id" => cid, "name" => "Ann"}

      Repo.delete_all(
        from(r in "entity_field_restrictions",
          where: r.entity_type == ^@type_name and r.field_name == "ssn"
        ),
        prefix: ctx.schema
      )

      assert run.() == %{"id" => cid, "name" => "Ann", "ssn" => "111"}
    end
  end

  # ── AC26 (SEC N1) ───────────────────────────────────────────────────────────

  describe "AC26 (N1)" do
    test "T-N1-after-publish: a match.field restricted after activation is refused before any record query",
         ctx do
      F.count_runner_calls!()
      record!(ctx.schema, %{"name" => "Ann", "tier" => "gold"})
      b = bound!(ctx.t, [tier_read(5)], %{"tier" => "gold"})

      # added AFTER publish and activation; nothing opted in (no opt-in exists for hook 1)
      SP.restrict_field!(ctx.schema, @type_name, "tier")
      assert_rejected_before_any_record_query(ctx.t, b)
    end

    test "the port's phase 1 refuses the same read when called directly", ctx do
      record!(ctx.schema, %{"name" => "Ann", "tier" => "gold"})
      SP.restrict_field!(ctx.schema, @type_name, "tier")

      {result, queries} =
        QueryCapture.capture_repo_queries(fn ->
          ScriptReads.prefetch(ctx.schema, [tier_read(5)], %{"tier" => "gold"})
        end)

      assert result == {:error, :reads_not_allowed}
      assert record_queries(queries) == []
    end

    test "phase 1 covers EVERY read before the first record query", ctx do
      cid = record!(ctx.schema, %{"name" => "Ann", "tier" => "gold"})
      SP.restrict_field!(ctx.schema, @type_name, "tier")
      reads = [Map.put(id_read(), "name", "first"), tier_read(5)]

      {result, queries} =
        QueryCapture.capture_repo_queries(fn ->
          ScriptReads.prefetch(ctx.schema, reads, %{"cid" => cid, "tier" => "gold"})
        end)

      assert result == {:error, :reads_not_allowed}
      assert record_queries(queries) == []
    end

    test "a restricted field listed in fields is redacted, not refused (port)", ctx do
      cid = record!(ctx.schema, %{"name" => "Ann", "tier" => "gold", "ssn" => "1"})
      SP.restrict_field!(ctx.schema, @type_name, "ssn")

      assert {:ok, %{"r" => [row]}} =
               ScriptReads.prefetch(ctx.schema, [id_read(["name", "ssn"])], %{"cid" => cid})

      assert row == %{"id" => cid, "name" => "Ann"}
    end

    test "a non-empty restricted_fields is refused by the port itself (no opt-in, C10)", ctx do
      cid = record!(ctx.schema, %{"name" => "Ann"})
      read = Map.put(id_read(), "restricted_fields", ["name"])

      assert ScriptReads.prefetch(ctx.schema, [read], %{"cid" => cid}) ==
               {:error, :reads_not_allowed}
    end
  end

  # ── AC28 ────────────────────────────────────────────────────────────────────

  describe "AC28" do
    test "prefix only from run context: another tenant's type is unknown here", ctx do
      other = F.tenant!("gh2534-7c2-other")
      F.count_runner_calls!()
      cid = record!(ctx.schema, %{"name" => "Ann", "tier" => "gold"})

      # tenant B has no `customer` type at all: the manifest behaves as an unknown type
      b = bound!(other, [id_read()], %{"cid" => cid})
      assert_rejected_before_any_record_query(other, b)

      assert ScriptReads.prefetch(other.schema_name, [id_read()], %{"cid" => cid}) ==
               {:error, :reads_not_allowed}
    end

    test "a record id of another tenant is a miss, and the one query names only the run's schema",
         ctx do
      other = F.tenant!("gh2534-7c2-other2")
      SP.active_definition!(other.schema_name, @type_name)
      SP.flag!(other.schema_name, @type_name)
      foreign = record!(ctx.schema, %{"name" => "Ann", "tier" => "gold"})

      b = bound!(other, [id_read()], %{"cid" => foreign})
      {_row, {:ok, :applied}, queries} = run_capturing(other.schema_name)
      assert {0, _} = output(other.schema_name, b.instance_id)

      assert [record_query] = record_queries(queries)
      assert record_query.query =~ other.schema_name
      refute record_query.query =~ ctx.schema
    end
  end

  # ── no caching (design 11.2) ────────────────────────────────────────────────

  test "no caching: a record changed between runs is read fresh", ctx do
    cid = record!(ctx.schema, %{"name" => "Ann", "tier" => "gold"})

    assert {:ok, %{"r" => [%{"name" => "Ann"}]}} =
             ScriptReads.prefetch(ctx.schema, [id_read()], %{"cid" => cid})

    delete!(ctx.schema, cid)
    assert ScriptReads.prefetch(ctx.schema, [id_read()], %{"cid" => cid}) == {:ok, %{"r" => []}}
  end
end
