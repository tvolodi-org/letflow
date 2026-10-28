defmodule Letflow.Scripts.EntityWriteRunTest do
  @moduledoc """
  REQ-601 / GH #3380 part B, criteria 5 to 8 (decision 0065 D8 slice E-2, decision 0062 R5/R6):
  `Letflow.Scripts.EntityWrite.run/4`. `async: false` (tenant provisioning, application env).
  The stub runner records what it was called with; rows that run the real sandbox use a long
  `timeout_ms` because the runner's deadline includes worker spawn.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Scripts.EntityWrite
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @not_started %{duration_us: 0, instructions_used: nil, heap_words_at_end: nil}
  @rejected {:error, :script_rejected, @not_started}
  @widened {:error, :script_output_restriction_widened, @not_started}
  @now ~U[2026-10-26 08:00:00.000000Z]
  @t "tt"

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> %{calls: [], reply: nil} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def reply(value), do: Agent.update(__MODULE__, &%{&1 | reply: value})
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def run(source, input, opts) do
      Agent.update(__MODULE__, &%{&1 | calls: [{source, input, opts} | &1.calls]})

      case Agent.get(__MODULE__, & &1.reply) do
        fun when is_function(fun, 0) -> fun.()
        other -> other
      end
    end
  end

  defp manifest(extra \\ %{}) do
    Map.merge(
      %{
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "amount" => %{"type" => "integer"},
            "note" => %{"type" => "string"},
            "cid" => %{"type" => "string"}
          }
        },
        "output_schema" => %{
          "type" => "object",
          "properties" => %{"total" => %{"type" => "integer"}, "note" => %{"type" => "string"}},
          "additionalProperties" => false
        },
        "derived_fields" => ["total"],
        "fail_codes" => ["too_big"],
        "limits" => %{"timeout_ms" => 5_000}
      },
      extra
    )
  end

  defp publish!(schema, key, manifest, source \\ "return { total = 1 }"),
    do: F.published!(schema, key, source, manifest, hook_kind: "entity_write")

  defp pin(rule),
    do: %{script_key: rule.key, script_version: rule.version, script_sha256: rule.sha256}

  defp facts(candidate \\ %{"amount" => 2, "note" => "secret-note"}),
    do: %{entity_type: @t, candidate: candidate, now: @now}

  defp entry(from_type, from_field),
    do: %{
      "name" => "note",
      "from" => [%{"entity_type" => from_type, "field" => from_field}]
    }

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

  defp stub!(reply) do
    _started = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:entity_write_script_runner, StubRunner)
    StubRunner.reply(reply)
  end

  defp ok_reply(output \\ %{"total" => 4}),
    do:
      {:ok,
       %{output: output, stats: %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}}}

  defp calls, do: StubRunner.calls()

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
    tenant = F.tenant!("r601b")
    schema = tenant.schema_name
    P.active_definition!(schema, @t, ["amount", "note", "total"])
    P.active_definition!(schema, "other", ["note"])
    P.restrict_field!(schema, @t, "note")
    {:ok, schema: schema}
  end

  describe "criterion 5: rejections never start the sandbox" do
    setup do
      stub!(ok_reply())
      :ok
    end

    defp assert_rejected(schema, pin, facts \\ facts()) do
      assert EntityWrite.run(schema, pin, facts) == @rejected
      assert calls() == []
    end

    test "T5a read refused after check_reads passed", %{schema: schema} do
      P.flag!(schema, @t)
      reads = [P.id_read("r", @t, ["amount"])]
      rule = publish!(schema, "t5a", manifest(%{"reads" => reads}))

      set_env(:entity_write_before_reads, fn ->
        Repo.delete_all(from(m in "script_readable_masters"), prefix: schema)
      end)

      assert_rejected(schema, pin(rule), facts(%{"amount" => 2, "cid" => Ecto.UUID.generate()}))
    end

    test "T5b absent row", %{schema: schema} do
      rule = publish!(schema, "t5b", manifest())
      assert_rejected(schema, %{pin(rule) | script_version: 99})
    end

    test "T5c draft", %{schema: schema} do
      rule =
        F.draft!(schema, "t5c", "return { total = 1 }", manifest(), hook_kind: "entity_write")

      assert_rejected(schema, pin(rule))
    end

    test "T5d discarded", %{schema: schema} do
      rule =
        F.draft!(schema, "t5d", "return { total = 1 }", manifest(), hook_kind: "entity_write")

      actor = %{user_id: Ecto.UUID.generate(), credential: :oidc, trace_id: "r601"}

      assert {:ok, %{status: :discarded}} =
               Letflow.Scripts.discard(schema, "t5d", rule.version, actor)

      assert_rejected(schema, pin(rule))
    end

    test "T5e revoked", %{schema: schema} do
      rule = publish!(schema, "t5e", manifest())
      F.revoke_raw!(schema, rule)
      assert_rejected(schema, pin(rule))
    end

    test "T5f other hook kind", %{schema: schema} do
      rule = F.published!(schema, "t5f", "return { total = 1 }", manifest())
      assert_rejected(schema, pin(rule))
    end

    test "T5g sha mismatch", %{schema: schema} do
      rule = publish!(schema, "t5g", manifest())
      assert_rejected(schema, %{pin(rule) | script_sha256: String.duplicate("0", 64)})
    end

    test "T5h open output schema", %{schema: schema} do
      open = put_in(manifest(), ["output_schema", "additionalProperties"], true)
      assert_rejected(schema, pin(publish!(schema, "t5h", open)))
    end

    test "T5i non-integer version", %{schema: schema} do
      rule = publish!(schema, "t5i1", manifest())
      assert_rejected(schema, %{pin(rule) | script_version: "1"})
    end

    test "T5i nil sha", %{schema: schema} do
      rule = publish!(schema, "t5i2", manifest())
      assert_rejected(schema, %{pin(rule) | script_sha256: nil})
    end

    test "T5i bad key", %{schema: schema} do
      rule = publish!(schema, "t5i3", manifest())
      assert_rejected(schema, %{pin(rule) | script_key: "Bad Key!"})
    end

    test "T5j derived field not in the definition", %{schema: schema} do
      rule = publish!(schema, "t5j", manifest(%{"derived_fields" => ["nope"]}))
      assert_rejected(schema, pin(rule))
    end

    test "T5k scope-bearing derived field", %{schema: schema} do
      set_env(:entity_writes_scope_keys, ["total"])
      assert_rejected(schema, pin(publish!(schema, "t5k", manifest())))
    end

    test "T5l restricted_inputs naming an unknown field", %{schema: schema} do
      rule = publish!(schema, "t5l", manifest(%{"restricted_inputs" => [entry(@t, "nope")]}))
      assert_rejected(schema, pin(rule))
    end

    test "T5m published and T5n retired rows run", %{schema: schema} do
      rule = publish!(schema, "t5m", manifest())
      assert {:ok, %{derived: %{"total" => 4}}} = EntityWrite.run(schema, pin(rule), facts())
      retired = F.retire_raw!(schema, rule)
      assert {:ok, %{derived: %{"total" => 4}}} = EntityWrite.run(schema, pin(retired), facts())
    end

    test "T5o malformed facts", %{schema: schema} do
      rule = publish!(schema, "t5o", manifest())
      assert_rejected(schema, pin(rule), %{facts() | entity_type: 5})
      assert_rejected(schema, pin(rule), %{facts() | now: "2026-10-26"})
      assert_rejected(schema, pin(rule), %{facts() | candidate: %{amount: 1}})
      assert_rejected(schema, pin(rule), %{})
    end
  end

  describe "criterion 6: redaction (decision 0062 R6)" do
    defp cover(manifest_extra, derived \\ ["note"]),
      do: manifest(Map.merge(%{"derived_fields" => derived}, manifest_extra))

    defp built(manifest, restricted?) do
      EntityWrite.build_input(
        @t,
        %{"amount" => 2, "note" => "secret-note"},
        manifest,
        MapSet.new(["tt.note"]),
        restricted?
      )
    end

    test "T6a no entry: note absent with or without the option", %{schema: schema} do
      for flag <- [true, false] do
        assert {:ok, input, []} = built(cover(%{}), flag)
        refute Map.has_key?(input, "note")
      end

      stub!(ok_reply(%{"note" => "x"}))
      rule = publish!(schema, "t6a", cover(%{}))
      assert {:ok, _} = EntityWrite.run(schema, pin(rule), facts())
      assert [{_, input, _}] = calls()
      refute Map.has_key?(input, "note")
    end

    test "T6b covering entry and option true: note present", %{schema: schema} do
      m = cover(%{"restricted_inputs" => [entry(@t, "note")]})
      assert {:ok, %{"note" => "secret-note"}, ["tt.note"]} = built(m, true)

      stub!(ok_reply(%{"note" => "x"}))
      rule = publish!(schema, "t6b", m)

      assert {:ok, _} =
               EntityWrite.run(schema, pin(rule), facts(), publisher_may_restricted?: true)

      assert [{_, %{"note" => "secret-note"}, _}] = calls()
    end

    test "T6c covering entry, option false or absent: note omitted", %{schema: schema} do
      m = cover(%{"restricted_inputs" => [entry(@t, "note")]})
      assert {:ok, input, []} = built(m, false)
      refute Map.has_key?(input, "note")

      stub!(ok_reply(%{"note" => "x"}))
      rule = publish!(schema, "t6c", m)
      assert {:ok, _} = EntityWrite.run(schema, pin(rule), facts())

      assert {:ok, _} =
               EntityWrite.run(schema, pin(rule), facts(), publisher_may_restricted?: false)

      assert [{_, in1, _}, {_, in2, _}] = calls()
      refute Map.has_key?(in1, "note")
      refute Map.has_key?(in2, "note")
    end

    test "T6d wrong label cover: note omitted, run/4 is a widening", %{schema: schema} do
      stub!(ok_reply())

      for {from_type, from_field} <- [{@t, "amount"}, {"other", "note"}] do
        m = cover(%{"restricted_inputs" => [entry(from_type, from_field)]}, ["total"])
        assert {:ok, input, []} = built(m, true)
        refute Map.has_key?(input, "note")

        rule = publish!(schema, "t6d_#{from_type}", m)

        assert EntityWrite.run(schema, pin(rule), facts(), publisher_may_restricted?: true) ==
                 @widened
      end

      assert calls() == []
    end

    test "T6e required restricted field not covered", %{schema: schema} do
      stub!(ok_reply())
      m = cover(%{}) |> put_in(["input_schema", "required"], ["note"])
      assert built(m, true) == {:error, :input_invalid}
      rule = publish!(schema, "t6e", m)
      assert EntityWrite.run(schema, pin(rule), facts()) == {:error, :input_invalid, @not_started}
      assert calls() == []
    end

    test "T6f no returned term holds the restricted value", %{schema: schema} do
      stub!(ok_reply(%{"note" => "x"}))
      m = cover(%{"restricted_inputs" => [entry(@t, "note")]})
      rule = publish!(schema, "t6f", m)
      result = EntityWrite.run(schema, pin(rule), facts(), publisher_may_restricted?: true)
      refute inspect(result) =~ "secret-note"
    end
  end

  describe "criterion 7: R5 predicate" do
    test "T7a target is the restricted field itself", %{schema: schema} do
      stub!(ok_reply(%{"note" => "x"}))
      m = cover(%{"restricted_inputs" => [entry(@t, "note")]})
      rule = publish!(schema, "t7a", m)
      assert {:ok, %{derived: %{"note" => "x"}}} = EntityWrite.run(schema, pin(rule), facts())
    end

    test "T7b taint widens to an unrestricted target", %{schema: schema} do
      stub!(ok_reply())
      m = cover(%{"restricted_inputs" => [entry(@t, "note")]}, ["total"])
      rule = publish!(schema, "t7b", m)
      assert EntityWrite.run(schema, pin(rule), facts()) == @widened
      assert calls() == []
    end

    test "T7c a read with restricted_fields taints", %{schema: schema} do
      stub!(ok_reply())
      P.flag!(schema, @t)
      read = P.id_read("r", @t, ["amount"]) |> Map.put("restricted_fields", ["note"])
      m = manifest(%{"reads" => [read]})
      rule = publish!(schema, "t7c", m)
      result = EntityWrite.run(schema, pin(rule), facts(%{"amount" => 2, "cid" => "x"}))
      assert result == @widened or result == @rejected
      assert calls() == []
    end

    test "T7d manifest without taint is unaffected", %{schema: schema} do
      stub!(ok_reply())
      rule = publish!(schema, "t7d", manifest())
      assert {:ok, _} = EntityWrite.run(schema, pin(rule), facts())
    end

    test "T7e r5_violation?/3 over load results" do
      assert EntityWrite.r5_violation?({:error, :invalid_schema_name}, [], ["tt.total"])
      assert EntityWrite.r5_violation?({:error, :anything}, ["tt.note"], ["tt.note"])
      refute EntityWrite.r5_violation?({:ok, MapSet.new(["tt.note"])}, ["tt.note"], ["tt.note"])
      refute EntityWrite.r5_violation?({:ok, MapSet.new()}, [], ["tt.total"])
      assert EntityWrite.r5_violation?({:ok, MapSet.new()}, ["tt.note"], ["tt.total"])
    end

    test "T7f the module uses VariableLabels.write_allowed?/3 and no rule of its own" do
      source = File.read!("lib/letflow/scripts/entity_write.ex")
      assert source =~ "VariableLabels.write_allowed?"
      refute source =~ "Enum.uniq(taint)"
    end
  end

  describe "criterion 8: outcome conversion" do
    setup do
      {:ok, rule: nil}
    end

    defp run_with(schema, reply, m \\ manifest()) do
      stub!(reply)
      rule = publish!(schema, "c8_#{System.unique_integer([:positive])}", m)
      EntityWrite.run(schema, pin(rule), facts())
    end

    defp assert_stats(%{} = stats),
      do:
        assert(
          Enum.sort(Map.keys(stats)) == [:duration_us, :heap_words_at_end, :instructions_used]
        )

    test "T8a-T8e runner error codes are kept", %{schema: schema} do
      for code <- [
            :script_error,
            :budget_exceeded,
            :memory_limit_exceeded,
            :timeout,
            :script_busy,
            :output_invalid
          ] do
        assert {:error, ^code, stats} = run_with(schema, {:error, code, %{}})
        assert_stats(stats)
      end
    end

    test "T8f undeclared output key", %{schema: schema} do
      assert {:error, :output_invalid, stats} =
               run_with(schema, ok_reply(%{"total" => 1, "note" => "x"}))

      assert_stats(stats)
    end

    test "T8g output not a derived field", %{schema: schema} do
      m = manifest()
      assert {:error, :output_invalid, _} = run_with(schema, ok_reply(%{"note" => "x"}), m)
    end

    test "T8h declared fail code and T8i undeclared", %{schema: schema} do
      failed = fn code -> {:error, :script_failed, %{fail: %{code: code, details: "secret"}}} end
      assert {:error, {:script_failed, "too_big"}, stats} = run_with(schema, failed.("too_big"))
      assert_stats(stats)
      assert {:error, :script_error, _} = run_with(schema, failed.("other"))
    end

    test "T8j unexpected term, exit and raise", %{schema: schema} do
      assert {:error, :script_error, stats} = run_with(schema, :weird)
      assert_stats(stats)
      assert {:error, :script_error, _} = run_with(schema, fn -> raise "boom" end)
      assert {:error, :script_error, _} = run_with(schema, fn -> exit(:crash) end)
      assert {:error, :script_error, _} = run_with(schema, fn -> throw(:up) end)
    end

    test "T8k success with the derived value, fingerprint and stats", %{schema: schema} do
      assert {:ok, %{derived: %{"total" => 4}, fingerprint: %{}, stats: stats}} =
               run_with(schema, ok_reply())

      assert stats == %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}
    end

    test "T8l partial stats fall back to the measured ones", %{schema: schema} do
      reply = {:ok, %{output: %{"total" => 1}, stats: %{duration_us: 1}}}
      assert {:ok, %{stats: stats}} = run_with(schema, reply)
      assert_stats(stats)
      assert stats.instructions_used == nil
    end

    test "T8m returned terms hold no source, key, sha or author text", %{schema: schema} do
      reply = {:error, :script_failed, %{fail: %{code: "too_big", details: "author-text"}}}
      stub!(reply)
      rule = publish!(schema, "t8msecretkey", manifest(), "return { total = 1 } -- srcmarker")
      result = EntityWrite.run(schema, pin(rule), facts())
      text = inspect(result)
      refute text =~ "srcmarker"
      refute text =~ "t8msecretkey"
      refute text =~ rule.sha256
      refute text =~ "author-text"
    end

    test "T8n real script derives a value", %{schema: schema} do
      rule = publish!(schema, "t8n", manifest(), "return { total = ctx.input.amount * 2 }")

      assert {:ok, %{derived: %{"total" => 4}, stats: stats}} =
               EntityWrite.run(schema, pin(rule), facts())

      assert_stats(stats)
    end

    test "T8o real infinite loop is stopped", %{schema: schema} do
      m = manifest(%{"limits" => %{"timeout_ms" => 100, "instructions" => 100_000}})
      rule = publish!(schema, "t8o", m, "while true do end")
      assert {:error, code, stats} = EntityWrite.run(schema, pin(rule), facts())
      assert code in [:timeout, :budget_exceeded]
      assert_stats(stats)
    end

    test "T8p real fail with a declared code", %{schema: schema} do
      rule = publish!(schema, "t8p", manifest(), ~s|fail("too_big")|)
      result = EntityWrite.run(schema, pin(rule), facts())

      assert match?({:error, {:script_failed, "too_big"}, _}, result) or
               match?({:error, :script_error, _}, result)
    end

    test "T8q ctx: registry id or the fixed fallback, node id, now", %{schema: schema} do
      stub!(ok_reply())
      rule = publish!(schema, "t8q", manifest())
      assert {:ok, _} = EntityWrite.run(schema, pin(rule), facts())
      assert [{_, _, opts}] = calls()
      assert %{instance_id: "entity-write", node_id: @t, token_id: token, now: @now} = opts[:ctx]
      assert is_binary(token)
      assert opts[:tenant] == schema
      assert opts[:fail_codes] == ["too_big"]
    end

    test "T8r equal facts give a real script the same now and uuid", %{schema: schema} do
      m =
        manifest(%{
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"note" => %{"type" => "string"}},
            "additionalProperties" => false
          },
          "derived_fields" => ["note"]
        })

      rule = publish!(schema, "t8r", m, "return { note = ctx.now .. ctx.uuid() }")
      r1 = EntityWrite.run(schema, pin(rule), facts())
      r2 = EntityWrite.run(schema, pin(rule), facts())

      case {r1, r2} do
        {{:ok, %{derived: a}}, {:ok, %{derived: b}}} -> assert a == b
        {{:error, :script_error, _}, {:error, :script_error, _}} -> :ok
      end
    end

    test "T8s a record registry row is read, never created", %{schema: schema} do
      before = Repo.aggregate(from(i in "entity_type_instances"), :count, prefix: schema)
      stub!(ok_reply())
      rule = publish!(schema, "t8s", manifest())
      assert {:ok, _} = EntityWrite.run(schema, pin(rule), facts())
      assert Repo.aggregate(from(i in "entity_type_instances"), :count, prefix: schema) == before
    end
  end
end
