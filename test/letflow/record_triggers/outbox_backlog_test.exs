defmodule Letflow.RecordTriggers.OutboxBacklogTest do
  @moduledoc """
  REQ-606 / GH #3411 part 2 (decision 0067 D6, slice T-2): the per-tenant backlog cap on
  `record_trigger_outbox`, the `trigger_backlog_full` refusal and its mappings through `Records`,
  `StepWrites` and `Response`.

  Test ids follow the design: B (cap), M (mappings), H (response unit), T (tenant). The cap is set
  to 2 through application env. `async: false`: tenant provisioning switches the sandbox to `:auto`
  and the flag and cap are application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Letflow.Api.Response
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Entities.StepSource
  alias Letflow.Entities.StepWrites
  alias Letflow.RecordTriggers.Outbox
  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.RecordTriggersFixture, as: RF
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @actor "00000000-0000-4000-8000-0000000000a7"
  @type_name "r606b_item"
  @other_type "r606b_other"

  setup do
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, true)
    Application.put_env(:letflow, :record_trigger_backlog_cap, 2)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end

      Application.delete_env(:letflow, :record_trigger_backlog_cap)
    end)

    tenant = Letflow.Support.ScriptTaskFixture.tenant!("r606b")
    schema = tenant.schema_name
    {:ok, _} = EventTypes.seed!(schema)
    for type <- [@type_name, @other_type], do: define!(schema, type)
    {:ok, schema: schema}
  end

  defp define!(schema, name) do
    fields = [%{name: "label", type: :string, required: true}]

    {:ok, row} =
      Definitions.create_definition(
        %{definition: %{name: name, display_name: name, fields: fields}, created_by: @actor},
        schema
      )

    {:ok, _} = Definitions.activate_definition(row.name, @actor, "r606b", schema)
  end

  defp create(schema, type \\ @type_name) do
    Records.create_record(
      %{
        entity_type: type,
        field_values: %{"label" => "a"},
        actor_id: @actor,
        idempotency_key: Ecto.UUID.generate()
      },
      schema,
      :tenant
    )
  end

  defp latest_count(schema), do: Repo.aggregate(Latest, :count, prefix: schema)

  defp set_all_status(schema, status),
    do: Repo.update_all(OutboxRow, [set: [status: status]], prefix: schema)

  defp step_command(type, line_key) do
    %{
      kind: :create,
      entity_type: type,
      field_values: %{"label" => "line"},
      actor_id: @actor,
      source: %StepSource{
        kind: "process_step",
        instance_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        node_id: "n",
        definition_id: Ecto.UUID.generate(),
        definition_version: "1",
        line_index: line_key,
        activator_id: Ecto.UUID.generate()
      }
    }
  end

  defp collect_queries(fun) do
    ref = make_ref()
    id = {__MODULE__, ref}
    parent = self()

    :telemetry.attach(
      id,
      [:letflow, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:query, ref, metadata.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(ref, acc) do
    receive do
      {:query, ^ref, query} -> drain(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "B backlog cap" do
    test "B0 no matching binding: no row and the count is not read", %{schema: schema} do
      RF.bind!(schema, @other_type, "created")
      {{:ok, _}, queries} = collect_queries(fn -> create(schema) end)
      assert RF.outbox_rows(schema) == []

      refute Enum.any?(queries, &(&1 =~ "record_trigger_outbox"))
    end

    test "B1 accepted at count 0 and 1, refused at 2, nothing changes", %{schema: schema} do
      RF.bind!(schema, @type_name, "created")
      assert {:ok, _} = create(schema)
      assert {:ok, _} = create(schema)
      assert length(RF.outbox_rows(schema)) == 2
      before_rows = RF.outbox_rows(schema)

      assert {:error, :trigger_backlog_full} = create(schema)
      assert latest_count(schema) == 2
      assert RF.outbox_rows(schema) == before_rows
    end

    test "B1a running rows count too", %{schema: schema} do
      RF.bind!(schema, @type_name, "created")
      {:ok, _} = create(schema)
      {:ok, _} = create(schema)
      set_all_status(schema, :running)
      assert {:error, :trigger_backlog_full} = create(schema)
    end

    test "B1b done and dead rows do not count; an unbound type succeeds at a full backlog", %{
      schema: schema
    } do
      RF.bind!(schema, @type_name, "created")
      {:ok, _} = create(schema)
      {:ok, _} = create(schema)
      assert {:error, :trigger_backlog_full} = create(schema)

      assert {2, _} = set_all_status(schema, :done)
      assert {:ok, _} = create(schema)
      [first | _] = RF.outbox_rows(schema)

      Repo.update_all(from(r in OutboxRow, where: r.id == ^first.id), [set: [status: :dead]],
        prefix: schema
      )

      assert {:ok, _} = create(schema)
      assert {:error, :trigger_backlog_full} = create(schema)

      assert {:ok, _} = create(schema, @other_type)
    end

    test "B1c the count is bounded, on the partial index's predicate, and takes no lock", %{
      schema: schema
    } do
      RF.bind!(schema, @type_name, "created")
      {:ok, _} = create(schema)
      {_, queries} = collect_queries(fn -> create(schema) end)

      count_sql = Enum.find(queries, &(&1 =~ "count(" and &1 =~ "record_trigger_outbox"))
      IO.puts("B1c count SQL: #{count_sql}")
      assert count_sql =~ "IN ('pending', 'running')"
      assert count_sql =~ "LIMIT"
      refute count_sql =~ "FOR "
      refute Enum.any?(queries, &(&1 =~ "pg_advisory"))
    end

    test "B2 a forced fault of the insert is trigger_enqueue_failed, not a refusal", %{
      schema: schema
    } do
      RF.bind!(schema, @type_name, "created")
      Repo.query!(~s(ALTER TABLE "#{schema}".record_trigger_outbox RENAME TO outbox_moved))

      try do
        ExUnit.CaptureLog.capture_log(fn -> send(self(), {:r, create(schema)}) end)
        assert_received {:r, {:error, :trigger_enqueue_failed}}
        assert latest_count(schema) == 0

        {:ok, _} = EntityTypeInstance.get_or_create(@type_name, schema)
        {:ok, multi} = Records.command_multi(step_command(@type_name, 0), schema, :tenant)
        ExUnit.CaptureLog.capture_log(fn -> send(self(), {:m, Repo.transaction(multi)}) end)

        assert_received {:m,
                         {:error, {:line, 0, :enqueue_trigger}, :trigger_enqueue_failed, _} = f}

        assert {:entity_write_failed, 0, :enqueue_trigger} = Records.interpret_in_multi(f)

        assert {:failed, 0, :enqueue_trigger} =
                 StepWrites.interpret_failure(
                   {:line, 0, :enqueue_trigger},
                   :trigger_enqueue_failed
                 )
      after
        Repo.query!(~s(ALTER TABLE "#{schema}".outbox_moved RENAME TO record_trigger_outbox))
      end
    end

    test "B3 update, delete and upsert are refused too; a suppressed-only write commits", %{
      schema: schema
    } do
      RF.bind!(schema, @type_name, "created")
      RF.bind!(schema, @type_name, "updated")
      RF.bind!(schema, @type_name, "deleted")
      {:ok, %{record: record}} = create(schema)
      {:ok, _} = create(schema)
      assert {:error, :trigger_backlog_full} = create(schema)

      base = %{entity_type: @type_name, record_id: record.record_id, actor_id: @actor}
      key = fn -> %{idempotency_key: Ecto.UUID.generate()} end

      assert {:error, :trigger_backlog_full} =
               Records.update_record(
                 Map.merge(base, Map.merge(key.(), %{field_values: %{"label" => "b"}})),
                 schema,
                 :tenant
               )

      assert {:error, :trigger_backlog_full} =
               Records.delete_record(Map.merge(base, key.()), schema, :tenant)

      assert {:error, :trigger_backlog_full} =
               Records.upsert_record_by_external_ref(
                 %{
                   entity_type: @type_name,
                   external_ref: %{"system" => "s", "id" => "1"},
                   field_values: %{"label" => "u"},
                   actor_id: @actor,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema,
                 :tenant,
                 []
               )

      # Suppressed-only (binding already in the chain): the write commits, no count is read.
      [b | _] =
        Repo.all(from(b in Letflow.RecordTriggers.Binding, where: b.event == :created),
          prefix: schema
        )

      assert {:ok, _} =
               Records.create_record(
                 %{
                   entity_type: @type_name,
                   field_values: %{"label" => "s"},
                   actor_id: @actor,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema,
                 :tenant,
                 trigger_lineage: %{depth: 0, chain: [b.id]}
               )
    end

    test "B4 the cap default is 10000 and a bad value falls back", %{schema: _} do
      Application.delete_env(:letflow, :record_trigger_backlog_cap)
      assert Outbox.backlog_cap() == 10_000
      Application.put_env(:letflow, :record_trigger_backlog_cap, 0)
      assert Outbox.backlog_cap() == 10_000
    end
  end

  describe "M mappings" do
    test "M1 Records.interpret_in_multi/1", %{schema: _} do
      f = fn reason -> {:error, {:line, 3, :enqueue_trigger}, reason, %{}} end

      assert {:entity_write_refused, 3, :trigger_backlog_full} =
               Records.interpret_in_multi(f.(:trigger_backlog_full))

      assert {:entity_write_failed, 3, :enqueue_trigger} =
               Records.interpret_in_multi(f.(:trigger_enqueue_failed))

      assert {:entity_write_failed, 3, :enqueue_trigger} = Records.interpret_in_multi(f.(:other))
    end

    test "M2 StepWrites.interpret_failure/2 for a declarative and a handler-range key", %{
      schema: _
    } do
      for key <- [3, 20 + 1 * 50 + 1] do
        i = StepSource.declared_line_index(key)
        i = if i == :declarative, do: key, else: i
        name = {:line, key, :enqueue_trigger}

        assert {:refused, ^i, :trigger_backlog_full, :step} =
                 StepWrites.interpret_failure(name, :trigger_backlog_full)

        assert {:failed, ^i, :enqueue_trigger} =
                 StepWrites.interpret_failure(name, :trigger_enqueue_failed)

        assert {:failed, ^i, :enqueue_trigger} = StepWrites.interpret_failure(name, :other)
      end
    end

    test "M3 a step write with a full backlog is refused and commits nothing", %{schema: schema} do
      RF.bind!(schema, @type_name, "created")
      {:ok, _} = create(schema)
      {:ok, _} = create(schema)
      {:ok, _} = EntityTypeInstance.get_or_create(@type_name, schema)
      {:ok, multi} = Records.command_multi(step_command(@type_name, 0), schema, :tenant)
      rows_before = RF.outbox_rows(schema)

      assert {:error, {:line, 0, :enqueue_trigger} = name, :trigger_backlog_full, _} =
               Repo.transaction(multi)

      assert {:refused, 0, :trigger_backlog_full, :step} =
               StepWrites.interpret_failure(name, :trigger_backlog_full)

      assert latest_count(schema) == 2
      assert RF.outbox_rows(schema) == rows_before
    end

    test "M4 a multi with a later step still rolls back", %{schema: schema} do
      RF.bind!(schema, @type_name, "created")
      {:ok, _} = create(schema)
      {:ok, _} = create(schema)
      {:ok, _} = EntityTypeInstance.get_or_create(@type_name, schema)
      {:ok, multi} = Records.command_multi(step_command(@type_name, 1), schema, :tenant)
      multi = Multi.run(multi, :after, fn _r, _c -> {:ok, :never} end)

      assert {:error, {:line, 1, :enqueue_trigger}, :trigger_backlog_full, changes} =
               Repo.transaction(multi)

      refute Map.has_key?(changes, :after)
      assert latest_count(schema) == 2
    end
  end

  describe "H response" do
    test "H7 only trigger_backlog_full gets 503 + retry-after", %{schema: _} do
      conn = Response.entity_write_refused(Plug.Test.conn(:post, "/"), :trigger_backlog_full, nil)
      assert conn.status == 503

      assert Plug.Conn.get_resp_header(conn, "retry-after") == [
               Integer.to_string(Response.backlog_retry_after_seconds())
             ]

      assert Jason.decode!(conn.resp_body)["error"] == "trigger_backlog_full"

      for {code, status} <- [
            validation_failed: 422,
            write_not_permitted: 403,
            record_version_conflict: 409,
            entity_write_contention: 503
          ] do
        conn = Response.entity_write_refused(Plug.Test.conn(:post, "/"), code, 0)
        assert conn.status == status
        assert Plug.Conn.get_resp_header(conn, "retry-after") == []
      end
    end
  end

  describe "T tenant isolation" do
    test "T-B1 A's full backlog does not refuse B, and B's count is unaffected", %{schema: a} do
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "r606bb")
      b = tenant_b.schema_name
      {:ok, _} = EventTypes.seed!(b)
      define!(b, @type_name)
      RF.bind!(a, @type_name, "created")
      RF.bind!(b, @type_name, "created")

      {:ok, _} = create(a)
      {:ok, _} = create(a)
      assert {:error, :trigger_backlog_full} = create(a)

      assert {:ok, _} = create(b)
      assert length(RF.outbox_rows(b)) == 1
      assert {:ok, _} = create(b)
      assert {:error, :trigger_backlog_full} = create(b)
      assert length(RF.outbox_rows(a)) == 2
      assert length(RF.outbox_rows(b)) == 2
    end
  end
end
