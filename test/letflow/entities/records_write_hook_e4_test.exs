defmodule Letflow.Entities.RecordsWriteHookE4Test do
  @moduledoc """
  REQ-618 / GH #3445 (decision 0065 D6 and D8 slice E-4): failure mapping and audit of the pre-write
  hook at the function level of `Records.create_record/3`, `update_record/3` and
  `upsert_record_by_external_ref/4`.

    * criterion 1: one test per D6 row and path (`D6-<row>-<path>`);
    * criterion 2: a real worker or watchdog killed mid-write (`C2a`, `C2b`), nothing raw leaks;
    * criterion 3: one audit row per hooked write (`A*`), its place in the Multi (`A9`);
    * criterion 4: the kill switch (`K*`);
    * criterion 6: tenant isolation of the rows and of the hook (`X*`).

  The route half (criteria 5 and 6) is in `routers/entities/record_writes_hook_codes_test.exs`.

  `async: false`: provisioning switches the sandbox to `:auto` and the stub runner is application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Letflow.Audit.Entry
  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Engine.ScriptInput
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Entities.WriteHookAudit
  alias Letflow.EntityTypeHooks, as: Hooks
  alias Letflow.EventStore.Event
  alias Letflow.NumberSequences
  alias Letflow.Scripts.EntityWrite
  alias Letflow.Scripts.HmacSecret
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @actor "00000000-0000-4000-8000-0000000000a1"
  @now ~U[2026-10-28 08:00:00.000000Z]
  @stats %{duration_us: 11, instructions_used: 22, heap_words_at_end: 33}
  @action "entity_write_hook.run"
  @paths [:create, :update, :upsert]

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> %{calls: 0, reply: nil} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    # a list is a sequence of replies (the last one repeats)
    def reply(value), do: Agent.update(__MODULE__, &%{&1 | reply: value})
    def calls, do: Agent.get(__MODULE__, & &1.calls)

    def run(source, input, opts) do
      reply =
        Agent.get_and_update(__MODULE__, fn state ->
          next =
            case state.reply do
              [only] -> {only, [only]}
              [head | rest] -> {head, rest}
              other -> {other, other}
            end

          {elem(next, 0), %{state | calls: state.calls + 1, reply: elem(next, 1)}}
        end)

      case reply do
        :real -> ScriptRunner.run(source, input, opts)
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
    tenant = F.tenant!("e4f")
    schema = tenant.schema_name
    assert {:ok, _} = EventTypes.seed!(schema)
    P.active_definition!(schema, "rd", ["name"])
    P.flag!(schema, "rd")

    _ = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:entity_write_script_runner, StubRunner)
    StubRunner.reply(:real)

    {:ok, schema: schema, tenant: tenant}
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

  defp ok_reply(total \\ "T:stub"), do: {:ok, %{output: %{"total" => total}, stats: @stats}}

  defp manifest(extra \\ %{}) do
    Map.merge(
      %{
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}, "note" => %{"type" => "string"}}
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

  defp reads_manifest,
    do:
      manifest(%{
        "reads" => [
          P.field_read("rows", "rd", "name")
          |> Map.put("match", %{"field" => "name", "value_from" => "name"})
        ]
      })

  defp pin(rule),
    do: %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

  # A type with a bound script; `source` is the real script (a stub ignores it).
  defp bound_type!(
         schema,
         type,
         manifest,
         source \\ ~s|return { total = "T:" .. ctx.input.name }|
       ) do
    P.active_definition!(schema, type, ["name", "note", "total"])
    rule = F.published!(schema, "k_" <> type, source, manifest, hook_kind: "entity_write")
    assert {:ok, _binding} = Hooks.bind(schema, type, pin(rule), P.actor())
    rule
  end

  defp attrs(extra),
    do: Map.merge(%{actor_id: @actor, idempotency_key: Ecto.UUID.generate()}, Map.new(extra))

  defp create(schema, type, values),
    do: Records.create_record(attrs(entity_type: type, field_values: values), schema)

  defp update(schema, type, record_id, values),
    do:
      Records.update_record(
        attrs(entity_type: type, record_id: record_id, field_values: values),
        schema
      )

  defp upsert(schema, type, values),
    do:
      Records.upsert_record_by_external_ref(
        attrs(
          entity_type: type,
          external_ref: %{"system" => "s", "id" => Ecto.UUID.generate()},
          field_values: values
        ),
        schema
      )

  # Writes made BEFORE the binding exist (an update needs a record); the hook runs on `path`.
  defp prepare(schema, type, :update) do
    {:ok, %{record: record}} = create(schema, type, %{"name" => "Ann"})
    record.record_id
  end

  defp prepare(_schema, _type, _path), do: nil

  defp write(schema, type, :create, _id, values), do: create(schema, type, values)
  defp write(schema, type, :update, id, values), do: update(schema, type, id, values)
  defp write(schema, type, :upsert, _id, values), do: upsert(schema, type, values)

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp latest_count(schema, type),
    do:
      Repo.aggregate(from(r in "entity_record_latest", where: r.entity_type == ^type), :count,
        prefix: schema
      )

  defp hook_rows(schema) do
    Repo.all(from(a in Entry, where: a.action == ^@action, order_by: a.timestamp), prefix: schema)
  end

  defp latest_name(schema, type) do
    Repo.one!(
      from(r in "entity_record_latest",
        where: r.entity_type == ^type,
        select: fragment("?->>'name'", r.field_values)
      ),
      prefix: schema
    )
  end

  # an update leaves the record as it was; create and upsert leave no record
  defp assert_unchanged(schema, type, :update), do: assert(latest_name(schema, type) == "Ann")
  defp assert_unchanged(_schema, _type, _path), do: :ok

  defp key_set(after_state), do: after_state |> Map.keys() |> Enum.sort()

  defp expected_keys,
    do: WriteHookAudit.after_state_keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

  defp class_of({:script_failed, _code}), do: "script_failed"
  defp class_of(:script_rejected), do: "script_rejected"
  defp class_of(code), do: Atom.to_string(code)

  # ── criterion 1: one test per D6 row and path ──────────────────────────────

  # id => the row's scenario; `started?`: the sandbox was reached (the HMAC was taken)
  defp row("r1"),
    do: %{
      expected: {:script_failed, "too_big"},
      started?: true,
      source: ~s|fail("too_big")|,
      reply: :real
    }

  defp row("r2"),
    do: %{expected: :script_error, started?: true, source: ~s|error("SECRET-ERR")|, reply: :real}

  defp row("r3"),
    do: %{
      expected: :budget_exceeded,
      started?: true,
      source: "while true do end",
      manifest: %{"limits" => %{"timeout_ms" => 5_000, "instructions" => 100_000}},
      reply: :real
    }

  defp row("r4"),
    do: %{
      expected: :memory_limit_exceeded,
      started?: true,
      source: "local t = {}\nfor i = 1, 1000000 do t[i] = { i } end\nreturn { total = 'x' }",
      manifest: %{"limits" => %{"timeout_ms" => 5_000, "heap_words" => 100_000}},
      reply: :real
    }

  defp row("r5"),
    do: %{
      expected: :timeout,
      started?: true,
      source: "while true do end",
      manifest: %{"limits" => %{"timeout_ms" => 200, "instructions" => 2_000_000_000}},
      reply: :real
    }

  defp row("r6a"),
    do: %{expected: :output_invalid, started?: true, reply: ok_reply(5), source: "return {}"}

  defp row("r6b"),
    do: %{
      expected: :output_invalid,
      started?: true,
      source: "return {}",
      reply: {:ok, %{output: %{"total" => "x", "extra" => "y"}, stats: @stats}}
    }

  # the widened restriction: a labelled input feeds an unrestricted derived field (D6 row 6)
  defp row("r6c"),
    do: %{
      expected: :output_invalid,
      started?: false,
      restrict: true,
      source: "return { total = 'x' }",
      manifest_fun: fn type ->
        %{
          "restricted_inputs" => [
            %{"name" => "note", "from" => [%{"entity_type" => type, "field" => "note"}]}
          ]
        }
      end,
      reply: :real
    }

  defp row("r7"),
    do: %{
      expected: :script_busy,
      started?: true,
      source: "return {}",
      reply: {:error, :script_busy, %{}}
    }

  defp row("r8"),
    do: %{
      expected: :script_error,
      started?: true,
      source: "return {}",
      reply: fn -> exit(:boom) end
    }

  defp row("r9"),
    do: %{
      expected: :script_rejected,
      started?: false,
      source: "return {}",
      reply: ok_reply(),
      pre: fn schema -> P.kill_switch!(schema, true) end
    }

  defp row("r10"),
    do: %{
      expected: :derived_value_conflict,
      started?: true,
      source: "return {}",
      manifest: reads_manifest(),
      injected: 3,
      reply: nil
    }

  for id <- ~w(r1 r2 r3 r4 r5 r6a r6b r6c r7 r8 r9 r10), path <- @paths do
    test "D6-#{id}-#{path} maps to its code, rolls back, writes one rejected row", %{
      schema: schema
    } do
      row = row(unquote(id))
      path = unquote(path)
      type = "t_" <> unquote(id)
      manifest_fun = row[:manifest_fun] || fn _type -> %{} end
      manifest = manifest(Map.merge(row[:manifest] || %{}, manifest_fun.(type)))

      # the injected writes of r10 commit a read type on every attempt
      reply =
        if unquote(id) == "r10" do
          fn ->
            {:ok, _} = create(schema, "rd", %{"name" => "moved"})
            ok_reply()
          end
        else
          row.reply
        end

      P.active_definition!(schema, type, ["name", "note", "total"])
      if row[:restrict], do: P.restrict_field!(schema, type, "note")
      record_id = prepare(schema, type, path)

      rule = F.published!(schema, "k_" <> type, row.source, manifest, hook_kind: "entity_write")
      assert {:ok, _} = Hooks.bind(schema, type, pin(rule), P.actor())
      StubRunner.reply(reply)
      if row[:pre], do: row.pre.(schema)

      events = event_count(schema)
      latest = latest_count(schema, type)

      result = write(schema, type, path, record_id, %{"name" => "Bob"})

      assert result == {:error, row.expected}
      refute Repo.in_transaction?()
      assert event_count(schema) == events + Map.get(row, :injected, 0)
      assert latest_count(schema, type) == latest
      assert_unchanged(schema, type, path)

      assert [%Entry{after_state: after_state, resource_type: ^type}] = hook_rows(schema)
      assert key_set(after_state) == expected_keys()
      assert after_state["outcome_class"] == class_of(row.expected)
      assert after_state["principal"] == "tenant_wide"
      assert is_integer(after_state["attempts"]) and after_state["attempts"] in 1..3

      assert (is_binary(after_state["hmac_hex"]) and row.started?) or
               (is_nil(after_state["hmac_hex"]) and not row.started?)

      refute inspect(after_state) =~ "SECRET"
    end
  end

  # ── criterion 2: a real worker or watchdog killed mid-write ────────────────

  describe "C2 crash of the sandbox" do
    setup %{schema: schema} do
      source = "while true do end"
      m = manifest(%{"limits" => %{"timeout_ms" => 5_000, "instructions" => 10_000_000}})
      bound_type!(schema, "tt", m, source)
      :ok
    end

    test "C2a the real watchdog killed is :script_error, never a memory limit", %{schema: schema} do
      before = event_count(schema)

      log =
        capture_log(fn ->
          task = Task.async(fn -> create(schema, "tt", %{"name" => "Ann"}) end)
          watchdog = find_child_called_by(task.pid)
          assert is_pid(watchdog)
          Process.exit(watchdog, :kill)
          result = Task.await(task, 10_000)

          assert result == {:error, :script_error}
          refute result == {:error, :memory_limit_exceeded}
          send(self(), {:result, result})
        end)

      assert_received {:result, result}
      assert_no_raw_text(result, log, schema)
      assert event_count(schema) == before
      assert latest_count(schema, "tt") == 0
    end

    test "C2b the real worker killed with another reason is :script_error", %{schema: schema} do
      log =
        capture_log(fn ->
          task = Task.async(fn -> create(schema, "tt", %{"name" => "Ann"}) end)
          watchdog = find_child_called_by(task.pid)
          worker = find_child_called_by(watchdog)
          assert is_pid(worker)
          Process.exit(worker, :boom)
          send(self(), {:result, Task.await(task, 10_000)})
        end)

      assert_received {:result, result}
      assert result == {:error, :script_error}
      assert_no_raw_text(result, log, schema)
    end

    test "C2c a runner that exits is :script_error and leaves no open transaction", %{
      schema: schema
    } do
      StubRunner.reply(fn -> exit({:shutdown, "SECRET-EXIT"}) end)

      log =
        capture_log(fn -> send(self(), {:result, create(schema, "tt", %{"name" => "Ann"})}) end)

      assert_received {:result, result}
      assert result == {:error, :script_error}
      refute Repo.in_transaction?()
      assert_no_raw_text(result, log, schema)
    end

    defp assert_no_raw_text(result, log, schema) do
      rows = hook_rows(schema)
      assert [%Entry{after_state: %{"outcome_class" => "script_error"}}] = rows
      everything = inspect(result) <> log <> inspect(Enum.map(rows, & &1.after_state))

      for marker <- ["Exception", "stacktrace", "SECRET", "boom", "while true", ":killed"] do
        refute everything =~ marker
      end
    end

    defp find_child_called_by(pid, tries \\ 300) do
      found =
        Letflow.Engine.Lua.TaskSupervisor
        |> Task.Supervisor.children()
        |> Enum.find(fn child ->
          case Process.info(child, :dictionary) do
            {:dictionary, dict} -> List.first(Keyword.get(dict, :"$callers", [])) == pid
            nil -> false
          end
        end)

      cond do
        found -> found
        tries == 0 -> nil
        true -> Process.sleep(10) && find_child_called_by(pid, tries - 1)
      end
    end
  end

  # ── criterion 3: the audit row ─────────────────────────────────────────────

  describe "A audit rows" do
    setup %{schema: schema} do
      rule = bound_type!(schema, "tt", manifest())
      StubRunner.reply(ok_reply())
      {:ok, rule: rule}
    end

    for path <- @paths do
      test "A-accepted-#{path} one accepted row with the pin, stats and attempts", %{
        schema: schema,
        rule: rule
      } do
        path = unquote(path)
        record_id = existing_record(schema, path)
        rows_before = length(hook_rows(schema))

        assert {:ok, %{record: record}} = write(schema, "tt", path, record_id, %{"name" => "Ann"})

        assert [%Entry{} = row] = Enum.drop(hook_rows(schema), rows_before)
        assert row.resource_type == "tt"
        assert row.resource_id == record.record_id
        assert row.actor_id == @actor
        assert row.before_state == nil
        assert key_set(row.after_state) == expected_keys()

        assert %{
                 "script_key" => key,
                 "script_version" => version,
                 "script_sha256" => sha,
                 "outcome_class" => "accepted",
                 "attempts" => 1,
                 "duration_us" => 11,
                 "instructions_used" => 22,
                 "heap_words_at_end" => 33,
                 "principal" => "tenant_wide",
                 "hmac_key_version" => key_version,
                 "hmac_hex" => hex
               } = row.after_state

        assert {key, version, sha} == {rule.key, rule.version, rule.sha256}
        assert is_integer(key_version) and is_binary(hex)
      end
    end

    # a record created BEFORE the script was bound is not possible here (the type is already
    # bound in the setup): write it through the stub with no row counted afterwards
    defp existing_record(schema, :update), do: prepare_unbound_then_bind(schema)
    defp existing_record(_schema, _path), do: nil

    defp prepare_unbound_then_bind(schema) do
      {:ok, %{record: record}} = create(schema, "tt", %{"name" => "Zed"})
      record.record_id
    end

    test "A-attempts a retried script_busy that then succeeds is one row with attempts 2", %{
      schema: schema
    } do
      StubRunner.reply([{:error, :script_busy, %{}}, ok_reply()])
      assert {:ok, _} = create(schema, "tt", %{"name" => "Ann"})

      assert [%Entry{after_state: %{"outcome_class" => "accepted", "attempts" => 2}}] =
               hook_rows(schema)
    end

    test "A-hmac the HMAC is the tenant hmac_fun of the canonical ctx and input", %{
      schema: schema,
      tenant: tenant
    } do
      parent = self()
      {:ok, real} = HmacSecret.hmac_fun(tenant.tenant_id)

      set_env(:script_task_hmac_fun_override, fn _tenant_id ->
        {:ok,
         fn bytes ->
           send(parent, {:hmac_bytes, bytes})
           real.(bytes)
         end}
      end)

      assert {:ok, _} = create(schema, "tt", %{"name" => "Ann"})
      assert_received {:hmac_bytes, bytes}

      assert [%Entry{after_state: %{"hmac_key_version" => version, "hmac_hex" => hex}}] =
               hook_rows(schema)

      assert real.(bytes) == {:ok, {version, hex}}

      # the captured bytes are exactly the canonical form of the expected ctx and input
      %{"ctx" => %{"now" => now} = ctx} = Jason.decode!(bytes)
      assert ctx["node_id"] == "tt" and ctx["token_id"] == "entity-write"

      {:ok, built, _taint} =
        EntityWrite.build_input("tt", %{"name" => "Ann"}, manifest(), MapSet.new(), false)

      assert ScriptInput.canonical(built, %{
               "instance_id" => ctx["instance_id"],
               "node_id" => "tt",
               "token_id" => "entity-write",
               "now" => now
             }) == bytes
    end

    test "A4 a failure of the record write rolls the accepted row back", %{schema: schema} do
      Repo.query!(
        ~s|CREATE FUNCTION "#{schema}".e4_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'e4 trigger'; END $$|
      )

      Repo.query!(
        ~s|CREATE TRIGGER e4_fail BEFORE INSERT OR UPDATE ON "#{schema}".entity_record_latest FOR EACH ROW EXECUTE FUNCTION "#{schema}".e4_fail()|
      )

      events = event_count(schema)

      outcome =
        try do
          create(schema, "tt", %{"name" => "Ann"})
        rescue
          _exception -> :raised
        end

      assert outcome == :raised or match?({:error, _}, outcome)
      assert hook_rows(schema) == []
      assert event_count(schema) == events
    end

    test "A6 a rejected row that cannot be written leaves the typed error", %{schema: schema} do
      StubRunner.reply({:error, :script_error, %{}})
      Repo.query!(~s|DROP TABLE "#{schema}".audit_entries CASCADE|)

      log =
        capture_log(fn -> send(self(), {:result, create(schema, "tt", %{"name" => "Ann"})}) end)

      assert_received {:result, {:error, :script_error}}
      assert log =~ "entity write hook audit row not written"
      assert latest_count(schema, "tt") == 0
    end

    test "A7 no derived, candidate or input value reaches the row", %{schema: schema} do
      StubRunner.reply(ok_reply("SECRET-DERIVED-VALUE"))
      assert {:ok, _} = create(schema, "tt", %{"name" => "CANDIDATE-NAME"})
      StubRunner.reply(ok_reply(5))
      assert {:error, :output_invalid} = create(schema, "tt", %{"name" => "CANDIDATE-NAME"})

      rows = hook_rows(schema)
      assert length(rows) == 2
      text = inspect(Enum.map(rows, &Map.take(&1, [:after_state, :before_state, :resource_id])))

      for secret <- ["SECRET-DERIVED-VALUE", "CANDIDATE-NAME", "return {"] do
        refute text =~ secret
      end
    end

    test "A8 an unbound type appends no hook row on any path", %{schema: schema} do
      P.active_definition!(schema, "free", ["name"])
      assert {:ok, %{record: record}} = create(schema, "free", %{"name" => "a"})
      assert {:ok, _} = update(schema, "free", record.record_id, %{"name" => "b"})
      assert {:ok, _} = upsert(schema, "free", %{"name" => "c"})
      assert hook_rows(schema) == []
      assert StubRunner.calls() == 0
    end

    test "A9 the number counter row is locked before the first audit statement", %{
      schema: schema,
      tenant: tenant
    } do
      Repo.insert!(
        %NumberSequences.Definition{
          tenant_id: tenant.tenant_id,
          key: "tt_no",
          entity_type: "tt",
          prefix: "TT",
          padding: 4,
          period: "none"
        },
        prefix: schema
      )

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          create(schema, "tt", %{"name" => "Ann"})
        end)

      assert {:ok, %{record: %{record_number: "TT-0001"}}} = result

      index = fn pred -> Enum.find_index(queries, pred) end

      counter_lock =
        index.(&(&1.query =~ "number_sequence_counters" and &1.query =~ "FOR UPDATE"))

      first_audit = index.(&(&1.query =~ "audit_chain_locks"))

      assert is_integer(counter_lock), "no counter row lock in the statement log"
      assert is_integer(first_audit), "no audit chain statement in the statement log"
      assert counter_lock < first_audit
    end
  end

  # ── criterion 4: the kill switch ───────────────────────────────────────────

  describe "K kill switch" do
    setup %{schema: schema} do
      bound_type!(schema, "tt", manifest())
      StubRunner.reply(ok_reply())
      :ok
    end

    latches = [
      {"K1-tenant", :tenant},
      {"K2-platform", :platform},
      {"K3-no-policy-row", :absent}
    ]

    for {label, latch} <- latches, path <- @paths do
      test "#{label}-#{path} rejects the write before the sandbox", %{schema: schema} do
        path = unquote(path)
        record_id = existing_record(schema, path)
        set_latch(schema, unquote(latch))
        StubRunner.reply(ok_reply())

        calls = StubRunner.calls()
        events = event_count(schema)
        rows = length(hook_rows(schema))

        assert write(schema, "tt", path, record_id, %{"name" => "Ann"}) ==
                 {:error, :script_rejected}

        assert StubRunner.calls() == calls
        assert event_count(schema) == events
        assert [%Entry{after_state: after_state}] = Enum.drop(hook_rows(schema), rows)
        assert after_state["outcome_class"] == "script_rejected"
        assert after_state["hmac_hex"] == nil
      end
    end

    defp set_latch(schema, :tenant), do: P.kill_switch!(schema, true)

    defp set_latch(schema, :platform) do
      {1, _} =
        Repo.update_all(
          from(p in "script_policy",
            where: p.id == 1,
            update: [set: [platform_kill_switch: true]]
          ),
          [],
          prefix: schema
        )
    end

    # the row is never deleted through the context (trigger LF001): switch the trigger off first
    defp set_latch(schema, :absent) do
      Repo.query!(~s|ALTER TABLE "#{schema}".script_policy DISABLE TRIGGER USER|)
      Repo.delete_all(from(p in "script_policy"), prefix: schema)
    end

    test "K4 a latch turned on after the read of attempt 1 does not touch that attempt", %{
      schema: schema
    } do
      rule = bound_type!(schema, "tr", reads_manifest())
      assert rule

      set_env(:entity_write_before_reads, fn -> P.kill_switch!(schema, true) end)

      assert {:ok, %{record: %{field_values: %{"total" => "T:stub"}}}} =
               create(schema, "tr", %{"name" => "Ann"})

      assert [%Entry{after_state: %{"outcome_class" => "accepted"}}] = hook_rows(schema)

      Application.delete_env(:letflow, :entity_write_before_reads)
      assert create(schema, "tr", %{"name" => "Bob"}) == {:error, :script_rejected}
      assert length(hook_rows(schema)) == 2
    end

    test "K5 turning the switch off lets the next write run again", %{schema: schema} do
      P.kill_switch!(schema, true)
      assert create(schema, "tt", %{"name" => "Ann"}) == {:error, :script_rejected}
      P.kill_switch!(schema, false)

      assert {:ok, %{record: %{field_values: %{"total" => "T:stub"}}}} =
               create(schema, "tt", %{"name" => "Ann"})
    end

    test "K6 a database error reading the switch is :script_error, never off", %{schema: schema} do
      Repo.query!(~s|DROP TABLE "#{schema}".script_policy CASCADE|)
      calls = StubRunner.calls()

      assert create(schema, "tt", %{"name" => "Ann"}) == {:error, :script_error}
      assert StubRunner.calls() == calls
      assert latest_count(schema, "tt") == 0
    end

    test "K7 an unbound type is written normally with the switch on", %{schema: schema} do
      P.kill_switch!(schema, true)
      assert {:ok, _} = create(schema, "rd", %{"name" => "free"})
      assert hook_rows(schema) == []
    end
  end

  # ── criterion 6: tenant isolation of the rows and of the hook ──────────────

  describe "X tenants" do
    test "X-rows a rejected row lives under A's prefix only; B's write runs no script", %{
      schema: a
    } do
      b_tenant = F.tenant!("e4g")
      b = b_tenant.schema_name
      assert {:ok, _} = EventTypes.seed!(b)

      bound_type!(a, "customer", manifest())
      P.active_definition!(b, "customer", ["name", "note", "total"])
      StubRunner.reply({:error, :script_error, %{}})

      assert create(a, "customer", %{"name" => "Ann"}) == {:error, :script_error}
      calls = StubRunner.calls()

      assert [%Entry{resource_type: "customer"}] = hook_rows(a)
      assert hook_rows(b) == []

      assert {:ok, _} = create(b, "customer", %{"name" => "Bea"})
      assert StubRunner.calls() == calls
      assert hook_rows(b) == []
    end

    test "X3-upsert B naming a type only A defines is the answer for an undefined type", %{
      schema: a
    } do
      b_tenant = F.tenant!("e4h")
      b = b_tenant.schema_name
      assert {:ok, _} = EventTypes.seed!(b)

      bound_type!(a, "invoice", manifest())
      StubRunner.reply(fn -> flunk("a script ran for the other tenant") end)

      masked = fn result, type -> result |> inspect() |> String.replace(type, "TYPE") end

      assert masked.(upsert(b, "invoice", %{"name" => "x"}), "invoice") ==
               masked.(upsert(b, "nowhere", %{"name" => "x"}), "nowhere")

      assert hook_rows(b) == []
      assert StubRunner.calls() == 0
    end
  end
end
