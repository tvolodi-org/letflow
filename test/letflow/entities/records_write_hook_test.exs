defmodule Letflow.Entities.RecordsWriteHookTest do
  @moduledoc """
  REQ-607 / GH #3413 part A (decision 0065 D8 slice E-3): the pre-write hook in
  `Letflow.Entities.Records.create_record/3`, `update_record/3` and
  `upsert_record_by_external_ref/4` (`Letflow.Entities.WriteHook`).

  Criteria C1 (hook once per attempt, unbound type untouched), C7 (derived field in the payload),
  C8 (typed errors, no leak, no escape), the idempotent replay (D2) and the in-transaction guard (G).
  Scope and managed-type refusals are in `records_write_hook_scope_test.exs`, the 503 mapping in
  `routers/entities/record_writes_hook_503_test.exs`.

  `async: false`: provisioning switches the sandbox to `:auto` and the stub runner is application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.EntityTypeHooks, as: Hooks
  alias Letflow.EventStore.Event
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScopeWritesFixture, as: W
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @actor "00000000-0000-4000-8000-0000000000a1"
  @now ~U[2026-10-28 08:00:00.000000Z]

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> %{calls: 0, reply: nil} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def reply(value), do: Agent.update(__MODULE__, &%{&1 | reply: value})
    def calls, do: Agent.get(__MODULE__, & &1.calls)

    def run(source, input, opts) do
      Agent.update(__MODULE__, &%{&1 | calls: &1.calls + 1})

      case Agent.get(__MODULE__, & &1.reply) do
        :real -> Letflow.Engine.Lua.ScriptRunner.run(source, input, opts)
        fun when is_function(fun, 0) -> fun.()
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
    tenant = F.tenant!("e3a")
    schema = tenant.schema_name
    assert {:ok, _} = EventTypes.seed!(schema)
    P.active_definition!(schema, "tt", ["name", "tier", "total"])
    P.active_definition!(schema, "rd", ["name"])
    P.flag!(schema, "rd")

    _ = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:entity_write_script_runner, StubRunner)
    StubRunner.reply(:real)

    rule = publish!(schema, "derive_total", manifest())
    {:ok, schema: schema, rule: rule, tenant: tenant}
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

  defp manifest(extra \\ %{}) do
    Map.merge(
      %{
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"},
            "tier" => %{"type" => "string"}
          }
        },
        "output_schema" => %{
          "type" => "object",
          "properties" => %{"total" => %{"type" => "string"}},
          "additionalProperties" => false
        },
        "derived_fields" => ["total"],
        "fail_codes" => ["too_big"],
        "limits" => %{"timeout_ms" => 5_000}
      },
      extra
    )
  end

  defp reads_manifest, do: manifest(%{"reads" => [P.field_read("rows", "rd", "name")]})

  defp publish!(schema, key, manifest) do
    F.published!(schema, key, ~s|return { total = "T:" .. ctx.input.name }|, manifest,
      hook_kind: "entity_write"
    )
  end

  defp pin(rule),
    do: %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

  defp bind!(schema, rule, type \\ "tt") do
    assert {:ok, _binding} = Hooks.bind(schema, type, pin(rule), P.actor())
    :ok
  end

  defp ok_reply(total \\ "T:stub") do
    {:ok,
     %{
       output: %{"total" => total},
       stats: %{duration_us: 1, instructions_used: 1, heap_words_at_end: 1}
     }}
  end

  defp attrs(extra),
    do: Map.merge(%{actor_id: @actor, idempotency_key: Ecto.UUID.generate()}, Map.new(extra))

  defp create(schema, type, values, extra \\ []),
    do: Records.create_record(attrs([entity_type: type, field_values: values] ++ extra), schema)

  defp create!(schema, type, values) do
    assert {:ok, %{record: record}} = create(schema, type, values)
    record
  end

  defp update(schema, type, record_id, values, extra \\ []),
    do:
      Records.update_record(
        attrs([entity_type: type, record_id: record_id, field_values: values] ++ extra),
        schema
      )

  defp upsert(schema, type, id, values),
    do:
      Records.upsert_record_by_external_ref(
        attrs(
          entity_type: type,
          external_ref: %{"system" => "s", "id" => id},
          field_values: values
        ),
        schema
      )

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)
  defp calls, do: StubRunner.calls()

  # the payload of the latest appended event (the write just made), not the projection
  defp last_event_values(schema) do
    event =
      Repo.one!(
        from(e in Event,
          order_by: [desc: e.global_seq],
          limit: 1
        ),
        prefix: schema
      )

    event.payload["field_values"]
  end

  defp lock_statements(statements),
    do: Enum.filter(statements, &(&1 =~ "instance_sequence" and &1 =~ "FOR UPDATE"))

  # ── C1: a bound type runs the hook once per attempt ────────────────────────

  describe "C1 bound type" do
    test "C1-create stores the derived value, one run", %{schema: schema, rule: rule} do
      bind!(schema, rule)
      record = create!(schema, "tt", %{"name" => "Ann"})
      assert record.field_values == %{"name" => "Ann", "total" => "T:Ann"}
      assert calls() == 1
    end

    test "C1-update stores the derived value, one run", %{schema: schema, rule: rule} do
      before = create!(schema, "tt", %{"name" => "Ann"})
      assert before.field_values == %{"name" => "Ann"}
      bind!(schema, rule)

      assert {:ok, %{record: record}} = update(schema, "tt", before.record_id, %{"name" => "Bob"})
      assert record.field_values == %{"name" => "Bob", "total" => "T:Bob"}
      assert calls() == 1
    end

    test "C1-upsert-created and C1-upsert-updated run the hook once each", %{
      schema: schema,
      rule: rule
    } do
      bind!(schema, rule)

      assert {:ok, %{outcome: :created, record: created}} =
               upsert(schema, "tt", "1", %{"name" => "Ann"})

      assert created.field_values == %{"name" => "Ann", "total" => "T:Ann"}
      assert calls() == 1

      assert {:ok, %{outcome: :updated, record: updated}} =
               upsert(schema, "tt", "1", %{"name" => "Bob"})

      assert updated.field_values == %{"name" => "Bob", "total" => "T:Bob"}
      assert calls() == 2

      # a hooked upsert never reports :unchanged (the hook output is not compared)
      assert {:ok, %{outcome: :updated}} = upsert(schema, "tt", "1", %{"name" => "Bob"})
      assert calls() == 3
    end

    test "C1-lock-set the written type and the read type are locked, ascending", %{schema: schema} do
      rule = publish!(schema, "derive_reads", reads_manifest())
      bind!(schema, rule)

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          create(schema, "tt", %{"name" => "Ann", "tier" => "x"})
        end)

      assert {:ok, %{record: %{field_values: %{"total" => "T:Ann"}}}} = result

      locked =
        queries
        |> Enum.filter(&(&1.query =~ "instance_sequence" and &1.query =~ "FOR UPDATE"))
        |> Enum.map(fn %{params: [id | _]} ->
          if byte_size(id) == 16, do: Ecto.UUID.load!(id), else: id
        end)

      # the hook's lock set, ascending by type name: the read type "rd", then the written "tt"
      expected =
        for type <- ["rd", "tt"] do
          {:ok, id} = EntityTypeInstance.get_or_create(type, schema)
          id
        end

      # the hook locks come first; the write's own append lock of "tt" follows them
      assert Enum.take(locked, 2) == expected
    end
  end

  # ── C1: an unbound type is untouched ───────────────────────────────────────

  describe "C1 unbound type" do
    setup do
      set_env(:entity_write_before_reads, fn -> send(self(), :reads_ran) end)
      :ok
    end

    test "C1-unbound-create", %{schema: schema} do
      {result, statements} = W.statements(fn -> create(schema, "rd", %{"name" => "x"}) end)
      assert {:ok, %{record: record}} = result
      assert record.field_values == %{"name" => "x"}
      assert calls() == 0
      refute_received :reads_ran
      assert length(lock_statements(statements)) == 1
      assert last_event_values(schema) == %{"name" => "x"}
    end

    test "C1-unbound-update", %{schema: schema} do
      record = create!(schema, "rd", %{"name" => "x"})

      {result, statements} =
        W.statements(fn -> update(schema, "rd", record.record_id, %{"name" => "y"}) end)

      assert {:ok, %{record: updated}} = result
      assert updated.field_values == %{"name" => "y"}
      assert last_event_values(schema) == %{"name" => "y"}
      assert calls() == 0
      refute_received :reads_ran
      assert length(lock_statements(statements)) == 1
    end

    test "C1-unbound-upsert", %{schema: schema} do
      {created, created_sql} = W.statements(fn -> upsert(schema, "rd", "1", %{"name" => "x"}) end)
      assert {:ok, %{outcome: :created, record: record}} = created
      assert record.field_values == %{"name" => "x"}
      assert last_event_values(schema) == %{"name" => "x"}
      assert length(lock_statements(created_sql)) == 1

      assert {:ok, %{outcome: :unchanged}} = upsert(schema, "rd", "1", %{"name" => "x"})

      {updated, updated_sql} = W.statements(fn -> upsert(schema, "rd", "1", %{"name" => "y"}) end)
      assert {:ok, %{outcome: :updated, record: record}} = updated
      assert record.field_values == %{"name" => "y"}
      assert last_event_values(schema) == %{"name" => "y"}
      assert length(lock_statements(updated_sql)) == 1
      assert calls() == 0
      refute_received :reads_ran
    end

    test "C9-lite a tenant without the binding runs no script", %{rule: rule, schema: schema} do
      bind!(schema, rule)
      other = F.tenant!("e3b")
      assert {:ok, _} = EventTypes.seed!(other.schema_name)
      P.active_definition!(other.schema_name, "tt", ["name", "tier", "total"])
      record = create!(other.schema_name, "tt", %{"name" => "Zed"})
      assert record.field_values == %{"name" => "Zed"}
      assert calls() == 0
    end
  end

  # ── C7: the payload may not name a derived field ───────────────────────────

  test "C7-derived-in-payload is a validation error and the runner is not called", %{
    schema: schema,
    rule: rule
  } do
    bind!(schema, rule)
    before = event_count(schema)

    assert {:error, {:record_payload_invalid, [failure]}} =
             create(schema, "tt", %{"name" => "Ann", "total" => "forged"})

    assert failure.field_path == "/total"
    assert calls() == 0
    assert event_count(schema) == before
  end

  # ── C8: typed errors, nothing appended, nothing leaks ──────────────────────

  describe "C8 typed runner errors" do
    setup %{schema: schema, rule: rule} do
      bind!(schema, rule)
      {:ok, before: event_count(schema)}
    end

    for code <- [
          :script_error,
          :timeout,
          :output_invalid,
          :budget_exceeded,
          :memory_limit_exceeded
        ] do
      test "C8-#{code}", %{schema: schema, rule: rule, before: before} do
        StubRunner.reply({:error, unquote(code), %{}})
        result = create(schema, "tt", %{"name" => "Ann"})
        assert result == {:error, unquote(code)}
        assert_clean(result, schema, rule, before)
        assert calls() == 1
      end
    end

    test "C8-script_failed keeps the manifest code", %{schema: schema, rule: rule, before: before} do
      StubRunner.reply({:error, :script_failed, %{fail: %{code: "too_big"}}})
      result = create(schema, "tt", %{"name" => "Ann"})
      assert result == {:error, {:script_failed, "too_big"}}
      assert_clean(result, schema, rule, before)
    end

    test "C8-script_rejected after the pin is revoked", %{
      schema: schema,
      rule: rule,
      before: before
    } do
      F.revoke_raw!(schema, rule)
      result = create(schema, "tt", %{"name" => "Ann"})
      assert result == {:error, :script_rejected}
      assert_clean(result, schema, rule, before)
      assert calls() == 0
    end

    test "C8-script_busy shares the budget of three attempts", %{
      schema: schema,
      rule: rule,
      before: before
    } do
      StubRunner.reply({:error, :script_busy, %{}})
      result = create(schema, "tt", %{"name" => "Ann"})
      assert result == {:error, :script_busy}
      assert_clean(result, schema, rule, before)
      assert calls() == 3
    end

    test "C8-raise in the runner is a script_error and does not escape", %{
      schema: schema,
      rule: rule,
      before: before
    } do
      StubRunner.reply(fn -> raise "boom with secret text" end)
      result = create(schema, "tt", %{"name" => "Ann"})
      assert result == {:error, :script_error}
      assert_clean(result, schema, rule, before)
    end

    defp assert_clean(result, schema, rule, before) do
      assert event_count(schema) == before
      refute Repo.in_transaction?()
      text = inspect(result)

      for secret <- [rule.key, rule.sha256, rule.source, "secret text"] do
        refute text =~ secret
      end
    end
  end

  describe "C8 exceptions in the read phase" do
    setup %{schema: schema} do
      rule = publish!(schema, "derive_reads", reads_manifest())
      bind!(schema, rule)
      :ok
    end

    test "C8-classify a lock error is contention, any other raise a script_error", %{
      schema: schema
    } do
      set_env(:entity_write_before_reads, fn ->
        raise %Postgrex.Error{postgres: %{code: :lock_not_available, message: "x"}}
      end)

      assert create(schema, "tt", %{"name" => "Ann"}) == {:error, :entity_write_contention}

      set_env(:entity_write_before_reads, fn -> raise "plain" end)
      assert create(schema, "tt", %{"name" => "Ann"}) == {:error, :script_error}
      assert calls() == 0
    end
  end

  # ── A: fingerprint retry and contention ────────────────────────────────────

  describe "A fingerprint retry" do
    setup %{schema: schema} do
      rule = publish!(schema, "derive_reads", reads_manifest())
      bind!(schema, rule)
      :ok
    end

    test "A-retry a read type written during the run phase re-runs the hook once", %{
      schema: schema
    } do
      {:ok, flag} = Agent.start_link(fn -> 0 end)

      StubRunner.reply(fn ->
        if Agent.get_and_update(flag, &{&1, &1 + 1}) == 0,
          do: create!(schema, "rd", %{"name" => "moved"})

        ok_reply()
      end)

      assert {:ok, %{record: record}} = create(schema, "tt", %{"name" => "Ann"})
      assert record.field_values["total"] == "T:stub"
      assert calls() == 2
    end

    test "A-retry-conflict three mismatches are derived_value_conflict", %{schema: schema} do
      before = event_count(schema)

      StubRunner.reply(fn ->
        create!(schema, "rd", %{"name" => "moved"})
        ok_reply()
      end)

      tt_before =
        Repo.aggregate(from(r in "entity_record_latest", where: r.entity_type == "tt"), :count,
          prefix: schema
        )

      assert create(schema, "tt", %{"name" => "Ann"}) == {:error, :derived_value_conflict}
      assert calls() == 3
      # only the three "rd" records of the injected writes were appended
      assert event_count(schema) == before + 3

      assert Repo.aggregate(
               from(r in "entity_record_latest", where: r.entity_type == "tt"),
               :count,
               prefix: schema
             ) ==
               tt_before
    end
  end

  test "A-contention a held sequence lock is entity_write_contention after the lock timeout", %{
    schema: schema,
    rule: rule
  } do
    bind!(schema, rule)
    StubRunner.reply(ok_reply())
    {:ok, instance_id} = Letflow.Entities.EntityTypeInstance.get_or_create("tt", schema)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, :locked} = Letflow.EventStore.lock_instance_sequence(Repo, instance_id, schema)
          send(parent, :locked)

          receive do
            :release -> :ok
          after
            15_000 -> :ok
          end
        end)
      end)

    assert_receive :locked, 5_000
    before = event_count(schema)
    assert create(schema, "tt", %{"name" => "Ann"}) == {:error, :entity_write_contention}
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)
    assert event_count(schema) == before
  end

  # ── D2: idempotent replay ──────────────────────────────────────────────────

  describe "D2-replay" do
    setup %{rule: rule, schema: schema} do
      bind!(schema, rule)
      {:ok, counter: start_supervised!({Agent, fn -> 0 end})}
    end

    test "a replay with the same key returns the original even if the derived value moved", %{
      schema: schema,
      counter: counter
    } do
      StubRunner.reply(fn -> ok_reply("T:#{Agent.get_and_update(counter, &{&1, &1 + 1})}") end)
      key = Ecto.UUID.generate()

      assert {:ok, %{record: first, is_duplicate: false}} =
               create(schema, "tt", %{"name" => "Ann"}, idempotency_key: key)

      assert first.field_values["total"] == "T:0"

      assert {:ok, %{record: again, is_duplicate: true}} =
               create(schema, "tt", %{"name" => "Ann"}, idempotency_key: key)

      assert again.record_id == first.record_id
      assert again.field_values["total"] == "T:0"

      assert create(schema, "tt", %{"name" => "Other"}, idempotency_key: key) ==
               {:error, :idempotency_key_reuse}

      assert Repo.aggregate(
               from(e in Event, where: e.event_type == "ENTITY_RECORD_CREATED"),
               :count,
               prefix: schema
             ) ==
               1
    end

    test "update replay", %{schema: schema, counter: counter} do
      StubRunner.reply(fn -> ok_reply("T:#{Agent.get_and_update(counter, &{&1, &1 + 1})}") end)
      record = create!(schema, "tt", %{"name" => "Ann"})
      key = Ecto.UUID.generate()

      assert {:ok, %{is_duplicate: false}} =
               update(schema, "tt", record.record_id, %{"name" => "Bob"}, idempotency_key: key)

      assert {:ok, %{record: again, is_duplicate: true}} =
               update(schema, "tt", record.record_id, %{"name" => "Bob"}, idempotency_key: key)

      assert again.field_values["name"] == "Bob"
    end
  end

  # ── G: a caller inside a transaction ───────────────────────────────────────

  describe "G in-transaction guard" do
    for {label, reads?} <- [{"G-tx-noreads", false}, {"G-tx-reads", true}] do
      test label, %{schema: schema} do
        manifest = if unquote(reads?), do: reads_manifest(), else: manifest()
        rule = publish!(schema, "derive_tx", manifest)
        record = create!(schema, "tt", %{"name" => "Ann"})
        bind!(schema, rule)
        StubRunner.reply(ok_reply())
        before = event_count(schema)

        assert {:ok, {result, timeout_before, timeout_after}} =
                 Repo.transaction(fn ->
                   t0 = Repo.query!("SHOW lock_timeout").rows
                   result = update(schema, "tt", record.record_id, %{"name" => "Bob"})
                   {result, t0, Repo.query!("SHOW lock_timeout").rows}
                 end)

        assert result == {:error, :script_error}
        assert timeout_before == timeout_after
        assert calls() == 0
        assert event_count(schema) == before
      end
    end
  end
end
