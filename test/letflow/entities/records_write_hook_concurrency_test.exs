defmodule Letflow.Entities.RecordsWriteHookConcurrencyTest do
  @moduledoc """
  REQ-607 / GH #3413 part B (decision 0065 D8 slice E-3): the pre-write hook under real
  concurrency. Criteria C2 (lock set and order), C3 (the worked example of 0065 D2, two
  connections), C4 (a commit between the counter read and the row read), C5 (retry cap),
  C6 (forced overlap, FIFO, lock timeout) and the locked-window measurement of C10.

  Concurrent writers are `Task`s that pin one connection (`WriteHookProbe.pinned_writer/2`), so a
  backend pid proves WHO waits on a lock. Pauses and the commit-between-reads injection are Ecto
  telemetry handlers in the writer's own process: no production seam. The cross-tenant criterion
  C9 is in `records_write_hook_tenant_test.exs`.

  `async: false`: provisioning switches the sandbox to `:auto` (commits are real), and the stub
  runner is application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.EntityTypeHooks, as: Hooks
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F
  alias Letflow.Support.WriteHookProbe, as: Probe

  @actor "00000000-0000-4000-8000-0000000000a1"
  @now ~U[2026-10-28 08:00:00.000000Z]

  defmodule StubRunner do
    @moduledoc false
    # Replies: `:real` (the Lua runner), a value, a 0-arity or 3-arity function, or a LIST of these
    # consumed one per call (the last stays when the list runs out). `outputs/0` are the real results.
    def start,
      do: Agent.start_link(fn -> %{calls: 0, reply: :real, outputs: []} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def reply(value), do: Agent.update(__MODULE__, &%{&1 | reply: value})
    def calls, do: Agent.get(__MODULE__, & &1.calls)
    def outputs, do: Agent.get(__MODULE__, &Enum.reverse(&1.outputs))

    def real(source, input, opts) do
      result = Letflow.Engine.Lua.ScriptRunner.run(source, input, opts)

      with {:ok, %{output: output}} <- result,
           do: Agent.update(__MODULE__, &%{&1 | outputs: [output | &1.outputs]})

      result
    end

    def run(source, input, opts) do
      reply =
        Agent.get_and_update(__MODULE__, fn %{reply: reply} = state ->
          {head, rest} =
            case reply do
              [head] -> {head, [head]}
              [head | tail] -> {head, tail}
              other -> {other, other}
            end

          {head, %{state | calls: state.calls + 1, reply: rest}}
        end)

      case reply do
        :real -> real(source, input, opts)
        fun when is_function(fun, 0) -> fun.()
        fun when is_function(fun, 3) -> fun.(source, input, opts)
        other -> other
      end
    end
  end

  setup_all do
    opts = [
      tenant: "tenant_warmup",
      timeout_ms: 5_000,
      ctx: %{instance_id: "i", node_id: "n", token_id: "t", now: @now}
    ]

    {:ok, _} = ScriptRunner.run("return { ok = true }", %{}, opts)
    :ok
  end

  setup do
    tenant = F.tenant!("e3c")
    schema = tenant.schema_name
    assert {:ok, _} = EventTypes.seed!(schema)
    P.active_definition!(schema, "invoice", ["ref", "total"])
    P.active_definition!(schema, "invoice_line", ["invoice_ref", "amount"])
    P.flag!(schema, "invoice_line")

    _ = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:entity_write_script_runner, StubRunner)
    StubRunner.reply(:real)

    invoice = create!(schema, "invoice", %{"ref" => "I-1"})
    create_line!(schema, "10")
    create_line!(schema, "20")
    {:ok, schema: schema, tenant: tenant, invoice: invoice}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp set_env(key, value) do
    previous = Application.fetch_env(:letflow, key)
    Application.put_env(:letflow, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, key, old)
        :error -> Application.delete_env(:letflow, key)
      end
    end)
  end

  defp lines_read,
    do: %{
      "name" => "lines",
      "entity_type" => "invoice_line",
      "match" => %{"field" => "invoice_ref", "value_from" => "ref"},
      "fields" => ["amount"],
      "limit" => 50
    }

  defp reads_of(type, name, field),
    do: %{
      "name" => name,
      "entity_type" => type,
      "match" => %{"field" => field, "value_from" => "ref"},
      "fields" => [field],
      "limit" => 50
    }

  defp manifest(reads) do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"ref" => %{"type" => "string"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"total" => %{"type" => "string"}},
        "additionalProperties" => false
      },
      "derived_fields" => ["total"],
      "fail_codes" => [],
      "limits" => %{"timeout_ms" => 5_000},
      "reads" => reads
    }
  end

  # total = the sum of the amounts of the invoice's lines, as an integer string
  @sum_source """
  local sum = 0
  for _, row in ipairs(ctx.input.reads.lines) do
    sum = sum + tonumber(row.amount)
  end
  return { total = string.format("%d", sum) }
  """

  defp bind_script!(schema, type, source, reads) do
    rule = F.published!(schema, "d_#{type}", source, manifest(reads), hook_kind: "entity_write")

    pin = %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

    assert {:ok, _binding} = Hooks.bind(schema, type, pin, P.actor())
    rule
  end

  defp bind_total!(schema), do: bind_script!(schema, "invoice", @sum_source, [lines_read()])

  defp attrs(extra),
    do: Map.merge(%{actor_id: @actor, idempotency_key: Ecto.UUID.generate()}, Map.new(extra))

  defp create(schema, type, values, extra \\ []),
    do: Records.create_record(attrs([entity_type: type, field_values: values] ++ extra), schema)

  defp create!(schema, type, values) do
    assert {:ok, %{record: record}} = create(schema, type, values)
    record
  end

  defp create_line!(schema, amount),
    do: create!(schema, "invoice_line", %{"invoice_ref" => "I-1", "amount" => amount})

  defp update_invoice(schema, invoice, extra \\ []),
    do:
      Records.update_record(
        attrs(
          [entity_type: "invoice", record_id: invoice.record_id, field_values: %{"ref" => "I-1"}] ++
            extra
        ),
        schema
      )

  # a line committed by a third connection, from inside a running writer
  defp commit_line_elsewhere(schema, amount) do
    Task.async(fn -> create_line!(schema, amount) end) |> Task.await(15_000)
  end

  defp events(schema),
    do: Repo.all(from(e in Event, order_by: [asc: e.global_seq]), prefix: schema)

  defp invoice_events(schema, type \\ "ENTITY_RECORD_UPDATED"),
    do:
      Enum.filter(
        events(schema),
        &(&1.event_type == type and &1.payload["entity_type"] == "invoice")
      )

  defp latest_total(schema),
    do: schema |> invoice_events() |> List.last() |> then(& &1.payload["field_values"]["total"])

  # "no interleaving stores a total omitting a committed line": every stored invoice total equals
  # the sum of the lines whose events precede it
  defp refute_stale_total(schema) do
    events = events(schema)

    for event <- events,
        event.payload["entity_type"] == "invoice",
        total = event.payload["field_values"]["total"],
        total != nil do
      expected =
        events
        |> Enum.filter(
          &(&1.payload["entity_type"] == "invoice_line" and &1.global_seq < event.global_seq)
        )
        |> Enum.map(&String.to_integer(&1.payload["field_values"]["amount"]))
        |> Enum.sum()

      assert total == Integer.to_string(expected),
             "invoice event #{event.global_seq} stored #{total}, committed lines sum to #{expected}"
    end

    :ok
  end

  defp start_writer(fun) do
    writer = Probe.pinned_writer(self(), fun)
    pid = writer.pid
    assert_receive {:backend, ^pid, backend}, 5_000
    {writer, backend}
  end

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)
  defp calls, do: StubRunner.calls()

  defp hold_sequence(schema, type, parent) do
    {:ok, id} = EntityTypeInstance.get_or_create(type, schema)

    Task.async(fn ->
      Repo.transaction(fn ->
        {:ok, :locked} = Letflow.EventStore.lock_instance_sequence(Repo, id, schema)
        send(parent, {:held, type})

        receive do
          :release -> :ok
        after
          8_000 -> :ok
        end
      end)
    end)
  end

  # ── C2: lock set and order ─────────────────────────────────────────────────

  describe "C2 lock set" do
    test "C2-order locks invoice then invoice_line, both before the event insert", %{
      schema: schema,
      invoice: invoice
    } do
      bind_total!(schema)

      {result, all} = Probe.capture_all(fn -> update_invoice(schema, invoice) end)
      mine = Probe.by_pid(all, self())

      assert {:ok, %{record: %{field_values: %{"total" => "30"}}}} = result

      assert [phase] = Probe.hook_phases(mine)

      assert Probe.lock_types(Probe.locks(phase), schema, ["invoice", "invoice_line"]) ==
               ["invoice", "invoice_line"]

      insert_at = Enum.find_index(mine, &Probe.event_insert?/1)
      assert insert_at
      last_hook_lock = Enum.find_index(mine, &(&1 == List.last(phase)))
      assert last_hook_lock < insert_at

      # decision 0061 items 1-4 (instance, tasks, projection, tokens): no other locking read
      # happens before the first event insert than the instance_sequence rows
      other_locks =
        mine
        |> Enum.take(insert_at)
        |> Enum.filter(fn e ->
          is_binary(e.query) and e.query =~ ~r/FOR (NO KEY )?UPDATE|FOR (KEY )?SHARE/ and
            not (e.query =~ "instance_sequence")
        end)

      assert other_locks == []
    end

    test "C2-once the written type is locked once in the hook phase", %{
      schema: schema,
      invoice: invoice
    } do
      P.flag!(schema, "invoice")

      bind_script!(
        schema,
        "invoice",
        "return { total = string.format(\"%d\", #ctx.input.reads.self + #ctx.input.reads.lines) }",
        [reads_of("invoice", "self", "ref"), lines_read()]
      )

      {result, all} = Probe.capture_all(fn -> update_invoice(schema, invoice) end)
      mine = Probe.by_pid(all, self())
      assert {:ok, %{record: %{field_values: %{"total" => total}}}} = result
      assert total == "3"

      assert [phase] = Probe.hook_phases(mine)
      types = Probe.lock_types(Probe.locks(phase), schema, ["invoice", "invoice_line"])
      assert types == ["invoice", "invoice_line"]
      assert Enum.count(types, &(&1 == "invoice")) == 1

      # the append-time lock of EventStore.append_multi (assign_sequence) is after compare and
      # before the event insert: the written type is locked 2 times up to the insert, 1 per phase
      insert_at = Enum.find_index(mine, &Probe.event_insert?/1)

      before_insert =
        mine |> Enum.take(insert_at) |> Probe.locks() |> Probe.lock_types(schema, ["invoice"])

      assert Enum.count(before_insert, &(&1 == "invoice")) == 2
    end

    test "C2-first-write a never-written read type gets its row and the write passes first try",
         %{schema: schema, invoice: invoice} do
      P.active_definition!(schema, "invoice_note", ["invoice_ref"])
      P.flag!(schema, "invoice_note")

      bind_script!(
        schema,
        "invoice",
        "return { total = string.format(\"%d\", #ctx.input.reads.notes) }",
        [reads_of("invoice_note", "notes", "invoice_ref")]
      )

      refute match?({:ok, _}, EntityTypeInstance.fetch_instance_id("invoice_note", schema))

      {result, all} = Probe.capture_all(fn -> update_invoice(schema, invoice) end)
      mine = Probe.by_pid(all, self())

      assert {:ok, %{record: %{field_values: %{"total" => "0"}}}} = result
      assert calls() == 1

      {:ok, note_id} = EntityTypeInstance.get_or_create("invoice_note", schema)
      {:ok, dumped} = Ecto.UUID.dump(note_id)

      assert Enum.any?(mine, fn e ->
               Probe.sequence_insert?(e) and Enum.any?(e.params, &(&1 in [note_id, dumped]))
             end)

      assert Repo.get(Letflow.EventStore.InstanceSequence, note_id, prefix: schema)
    end

    test "C2-first-write-race a first write committed in between needs exactly one retry", %{
      schema: schema,
      invoice: invoice
    } do
      P.active_definition!(schema, "invoice_note", ["invoice_ref"])
      P.flag!(schema, "invoice_note")

      bind_script!(
        schema,
        "invoice",
        "return { total = string.format(\"%d\", #ctx.input.reads.notes) }",
        [reads_of("invoice_note", "notes", "invoice_ref")]
      )

      {:ok, flag} = Agent.start_link(fn -> 0 end)

      StubRunner.reply(fn source, input, opts ->
        if Agent.get_and_update(flag, &{&1, &1 + 1}) == 0,
          do:
            Task.await(
              Task.async(fn -> create!(schema, "invoice_note", %{"invoice_ref" => "I-1"}) end)
            )

        StubRunner.real(source, input, opts)
      end)

      {result, all} = Probe.capture_all(fn -> update_invoice(schema, invoice) end)
      assert {:ok, %{record: %{field_values: %{"total" => "1"}}}} = result
      assert calls() == 2
      assert length(Probe.hook_phases(Probe.by_pid(all, self()))) == 2
    end
  end

  # ── C3: the worked example of 0065 D2 ──────────────────────────────────────

  describe "C3 worked example" do
    test "C3-case-A W2 commits before W1 takes its locks: W1 retries and includes the line", %{
      schema: schema,
      invoice: invoice
    } do
      bind_total!(schema)

      StubRunner.reply([
        fn source, input, opts ->
          commit_line_elsewhere(schema, "5")
          StubRunner.real(source, input, opts)
        end,
        :real
      ])

      assert {:ok, %{record: %{field_values: %{"total" => "35"}}}} =
               update_invoice(schema, invoice)

      assert calls() == 2
      assert StubRunner.outputs() == [%{"total" => "30"}, %{"total" => "35"}]
      # the stale 30 was computed, but never stored
      assert latest_total(schema) == "35"
      assert Enum.all?(invoice_events(schema), &(&1.payload["field_values"]["total"] != "30"))
      refute_stale_total(schema)
    end

    test "C3-case-B W1 holds both locks first: W2 waits and commits after W1", %{
      schema: schema,
      invoice: invoice
    } do
      bind_total!(schema)
      test_pid = self()

      {w1, _b1} = start_writer(fn -> update_invoice(schema, invoice) end)
      detach = Probe.pause_after_nth_lock(w1.pid, 2, test_pid)
      on_exit(detach)
      send(w1.pid, :start)

      w1_pid = w1.pid
      assert_receive {:paused, ^w1_pid}, 10_000

      {w2, b2} = start_writer(fn -> create_line!(schema, "5") end)
      send(w2.pid, :start)
      Probe.wait_blocked(b2)

      # W2 waits on the invoice_line sequence row and has committed nothing
      assert Task.yield(w2, 0) == nil
      refute Enum.any?(events(schema), &(&1.payload["field_values"]["amount"] == "5"))

      send(w1.pid, :go)
      assert {:ok, %{record: %{field_values: %{"total" => "30"}}}} = Task.await(w1, 15_000)
      assert %{record_id: _} = Task.await(w2, 15_000)
      detach.()

      assert calls() == 1
      assert latest_total(schema) == "30"

      events = events(schema)
      w1_event = List.last(invoice_events(schema))
      l3 = Enum.find(events, &(&1.payload["field_values"]["amount"] == "5"))
      assert l3.global_seq > w1_event.global_seq
      refute_stale_total(schema)
    end
  end

  # ── C4: a commit between the counter read and the row read ─────────────────

  test "C4-injected-commit the rows are newer than the counter: retry with the newer rows", %{
    schema: schema,
    invoice: invoice
  } do
    bind_total!(schema)

    {w1, _backend} = start_writer(fn -> update_invoice(schema, invoice) end)
    detach = Probe.after_counter_query(w1.pid, fn -> commit_line_elsewhere(schema, "5") end)
    on_exit(detach)
    send(w1.pid, :start)

    assert {:ok, %{record: %{field_values: %{"total" => "35"}}}} = Task.await(w1, 20_000)
    detach.()

    # attempt 1 read the newer row (35) with the older counter and was rejected; attempt 2 stored 35
    assert calls() == 2
    assert StubRunner.outputs() == [%{"total" => "35"}, %{"total" => "35"}]
    assert latest_total(schema) == "35"
    refute_stale_total(schema)
  end

  # ── C5: the retry cap ──────────────────────────────────────────────────────

  describe "C5 retry cap" do
    test "C5-cap three mismatches end the write with nothing stored, a retry succeeds", %{
      schema: schema,
      invoice: invoice
    } do
      bind_total!(schema)

      StubRunner.reply(fn source, input, opts ->
        commit_line_elsewhere(schema, "1")
        StubRunner.real(source, input, opts)
      end)

      key = Ecto.UUID.generate()
      before_updates = length(invoice_events(schema))
      before_events = event_count(schema)
      before_claims = Repo.aggregate(IdempotencyRecord, :count, prefix: schema)
      before_audit = Repo.aggregate(Entry, :count, prefix: schema)

      assert update_invoice(schema, invoice, idempotency_key: key) ==
               {:error, :derived_value_conflict}

      assert calls() == 3
      assert length(invoice_events(schema)) == before_updates
      # only the three injected line events were appended; and their three claims
      assert event_count(schema) == before_events + 3
      assert Repo.aggregate(IdempotencyRecord, :count, prefix: schema) == before_claims + 3

      assert Repo.aggregate(
               from(i in IdempotencyRecord, where: i.idempotency_key == ^key),
               :count,
               prefix: schema
             ) == 0

      assert Repo.aggregate(from(e in Event, where: e.idempotency_key == ^key), :count,
               prefix: schema
             ) == 0

      assert Repo.aggregate(Entry, :count, prefix: schema) == before_audit

      # the same key succeeds once contention stops
      StubRunner.reply(:real)

      assert {:ok, %{is_duplicate: false, record: %{field_values: %{"total" => "33"}}}} =
               update_invoice(schema, invoice, idempotency_key: key)

      assert Repo.aggregate(from(e in Event, where: e.idempotency_key == ^key), :count,
               prefix: schema
             ) == 1

      assert Repo.aggregate(
               from(i in IdempotencyRecord, where: i.idempotency_key == ^key),
               :count,
               prefix: schema
             ) == 1
    end

    test "C5-busy-then-ok script_busy on attempt 1 then success uses 2 of 3 attempts", %{
      schema: schema,
      invoice: invoice
    } do
      bind_total!(schema)
      StubRunner.reply([{:error, :script_busy, %{}}, :real])

      assert {:ok, %{record: %{field_values: %{"total" => "30"}}}} =
               update_invoice(schema, invoice)

      assert calls() == 2
    end

    test "C5-busy-x3 three script_busy end as script_busy", %{schema: schema, invoice: invoice} do
      bind_total!(schema)
      StubRunner.reply({:error, :script_busy, %{}})
      before = event_count(schema)
      assert update_invoice(schema, invoice) == {:error, :script_busy}
      assert calls() == 3
      assert event_count(schema) == before
    end
  end

  # ── C6: forced overlap and bounds ──────────────────────────────────────────

  describe "C6 overlap" do
    test "C6-fifo-order sets {A,B} and {B,A} both lock A then B, FIFO, no deadlock", %{
      schema: schema
    } do
      for type <- ["ta", "tb"], do: P.active_definition!(schema, type, ["ref", "total"])
      for type <- ["ta", "tb"], do: P.flag!(schema, type)
      ra = create!(schema, "ta", %{"ref" => "x"})
      rb = create!(schema, "tb", %{"ref" => "x"})

      src = ~s|return { total = "t" }|
      bind_script!(schema, "ta", src, [reads_of("tb", "other", "ref")])
      bind_script!(schema, "tb", src, [reads_of("ta", "other", "ref")])
      parent = self()

      {result, all} =
        Probe.capture_all(fn ->
          holder = hold_sequence(schema, "ta", parent)
          assert_receive {:held, "ta"}, 5_000

          {w1, b1} = start_writer(fn -> update_typed(schema, "ta", ra) end)
          send(w1.pid, :start)
          Probe.wait_blocked(b1)

          {w2, b2} = start_writer(fn -> update_typed(schema, "tb", rb) end)
          send(w2.pid, :start)
          Probe.wait_blocked(b2)

          send(holder.pid, :release)
          {:ok, :ok} = Task.await(holder, 10_000)
          {w1, w2, Task.await(w1, 20_000), Task.await(w2, 20_000)}
        end)

      {w1, w2, r1, r2} = result
      assert {:ok, %{record: _}} = r1
      assert {:ok, %{record: _}} = r2

      phases1 = Probe.hook_phases(Probe.by_pid(all, w1.pid))
      phases2 = Probe.hook_phases(Probe.by_pid(all, w2.pid))

      for phase <- phases1 ++ phases2 do
        assert Probe.lock_types(Probe.locks(phase), schema, ["ta", "tb"]) == ["ta", "tb"]
      end

      # W1 once; W2 retries once (W1 committed a ta event while W2 waited): 3 runner calls
      assert length(phases1) == 1
      assert length(phases2) == 2
      assert calls() == 3

      # FIFO: W1 asked first and got the ta row first
      first_ta = fn phases -> phases |> hd() |> hd() end
      assert first_ta.(phases1).at < first_ta.(phases2).at

      assert :deadlock_detected not in Probe.errors(Probe.by_pid(all, [w1.pid, w2.pid]))
    end

    test "C6-lock-timeout a held row beyond the 2 s lock_timeout is entity_write_contention", %{
      schema: schema,
      invoice: invoice
    } do
      bind_total!(schema)
      parent = self()
      before = event_count(schema)
      before_total = latest_total_or_nil(schema)

      holder = hold_sequence(schema, "invoice", parent)
      assert_receive {:held, "invoice"}, 5_000

      t0 = System.monotonic_time(:millisecond)

      {result, all} = Probe.capture_all(fn -> update_invoice(schema, invoice) end)

      elapsed = System.monotonic_time(:millisecond) - t0
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 10_000)

      assert result == {:error, :entity_write_contention}
      assert elapsed >= 1_500 and elapsed < 4_000
      assert event_count(schema) == before
      assert latest_total_or_nil(schema) == before_total
      assert Probe.errors(Probe.by_pid(all, self())) == [:lock_not_available]
    end

    test "C6-set-local the timeouts are set before the first lock", %{
      schema: schema,
      invoice: invoice
    } do
      bind_total!(schema)
      {_result, all} = Probe.capture_all(fn -> update_invoice(schema, invoice) end)
      mine = Probe.by_pid(all, self())

      set_local =
        for e <- mine, is_binary(e.query), e.query =~ "SET LOCAL", do: e.query

      assert set_local == ["SET LOCAL lock_timeout = '2s'", "SET LOCAL statement_timeout = '5s'"]

      first_lock = Enum.find_index(mine, &Probe.lock?/1)
      idx = fn text -> Enum.find_index(mine, &(is_binary(&1.query) and &1.query =~ text)) end
      assert idx.("lock_timeout") < first_lock
      assert idx.("statement_timeout") < first_lock
    end
  end

  defp update_typed(schema, type, record),
    do:
      Records.update_record(
        attrs(entity_type: type, record_id: record.record_id, field_values: %{"ref" => "x"}),
        schema
      )

  defp latest_total_or_nil(schema) do
    case invoice_events(schema) do
      [] -> nil
      list -> List.last(list).payload["field_values"]["total"]
    end
  end

  # ── C10: the locked window, a figure and not an assertion ──────────────────

  @tag :measure
  test "C10-window measured duration of the locked window of the worked example", %{
    schema: schema,
    invoice: invoice
  } do
    bind_total!(schema)

    windows =
      for _ <- 1..5 do
        {{:ok, _}, all} = Probe.capture_all(fn -> update_invoice(schema, invoice) end)
        mine = Probe.by_pid(all, self())
        first_lock = mine |> Probe.locks() |> hd()
        commit = Enum.find(mine, &(&1.at >= first_lock.at and &1.query == "commit"))
        # a commit that emits no telemetry event falls back to the last statement of the write
        (commit || List.last(mine)).at - first_lock.at
      end

    median = windows |> Enum.sort() |> Enum.at(2)
    IO.puts("LOCKED_WINDOW_US=#{median} (samples #{inspect(windows)})")
    assert is_integer(median) and median >= 0
  end
end
