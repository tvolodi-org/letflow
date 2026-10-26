defmodule Letflow.Scripts.FormValidationRunTest do
  @moduledoc """
  REQ-581 / GH #3298 criteria 2 to 8 (decision 0067 D9, slice F-2): `Letflow.Scripts.FormValidation.run/4`.
  `async: false` (tenant provisioning, application env). Rows that run the real sandbox set
  `limits.timeout_ms` to the 50 ms cap, because the runner's deadline includes worker spawn;
  the stub runner records what it was called with.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Scripts
  alias Letflow.Scripts.FormValidation
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @not_started %{duration_us: 0, instructions_used: nil, heap_words_at_end: nil}
  @rejected {:error, :script_rejected, @not_started}
  @now ~U[2026-10-26 08:00:00.000000Z]

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

  defp fv_manifest(extra \\ %{}, limits \\ %{}) do
    Map.merge(
      %{
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"note" => %{"type" => "string"}, "n" => %{"type" => "integer"}}
        },
        "output_schema" => %{
          "type" => "object",
          "properties" => %{
            "ok" => %{"type" => "boolean"},
            "code" => %{"type" => "string"},
            "fields" => %{"type" => "array"}
          },
          "additionalProperties" => false
        },
        "fail_codes" => [],
        "refusal_codes" => ["too_short", "bad"],
        "fields" => ["note", "n"],
        "limits" => Map.merge(%{"timeout_ms" => 50}, limits)
      },
      extra
    )
  end

  defp publish!(schema, key, source, manifest \\ fv_manifest()),
    do: F.published!(schema, key, source, manifest, hook_kind: "form_validation")

  defp pin(rule),
    do: %{script_key: rule.key, script_version: rule.version, script_sha256: rule.sha256}

  defp facts(variables \\ %{"note" => "hello"}, labels \\ %{}) do
    %{
      variables: variables,
      variable_labels: labels,
      instance_id: Ecto.UUID.generate(),
      token_id: Ecto.UUID.generate(),
      form: %{
        definition_id: Ecto.UUID.generate(),
        definition_version: 1,
        node_id: "form1",
        schema_version_hash: "abc"
      },
      task: %{id: Ecto.UUID.generate(), node_id: "form1", assignee_kind: "user", now: @now}
    }
  end

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

  defp stub! do
    {:ok, _pid} = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:form_validation_script_runner, StubRunner)
  end

  defp ok_reply(output \\ %{"ok" => true}),
    do:
      {:ok,
       %{output: output, stats: %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}}}

  # The first call in a fresh VM loads code and takes about 60 ms, above the 50 ms cap: warm the
  # runner once so the real-sandbox rows measure the steady state.
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
    tenant = F.tenant!("r581")
    set_env(:form_validation_hook_enabled, true)
    {:ok, tenant: tenant, schema: tenant.schema_name}
  end

  describe "criterion 2: flag and kind gate" do
    test "G1 the shipped default is off and run/4 starts nothing", %{schema: schema} do
      config = Config.Reader.read!("config/config.exs", env: :test)
      assert config[:letflow][:form_validation_hook_enabled] == false
      rule = publish!(schema, "g1", "return { ok = true }")
      stub!()
      set_env(:form_validation_hook_enabled, false)

      assert FormValidation.run(schema, pin(rule), facts()) == @rejected
      assert StubRunner.calls() == []
    end

    test "G2 a service_task row is rejected", %{schema: schema} do
      stub!()
      rule = F.published!(schema, "g2", "return { total = 1 }", F.closed_manifest())
      assert FormValidation.run(schema, pin(rule), facts()) == @rejected
      assert StubRunner.calls() == []
    end

    test "G3 an absent row, G7 a sha mismatch, G10 a malformed pin", %{schema: schema} do
      stub!()
      rule = publish!(schema, "g3", "return { ok = true }")
      assert FormValidation.run(schema, %{pin(rule) | script_key: "nope"}, facts()) == @rejected
      assert FormValidation.run(schema, %{pin(rule) | script_version: 99}, facts()) == @rejected
      assert FormValidation.run(schema, %{pin(rule) | script_sha256: "0"}, facts()) == @rejected
      assert FormValidation.run(schema, %{pin(rule) | script_version: "1"}, facts()) == @rejected

      assert FormValidation.run(schema, %{pin(rule) | script_key: "Bad Key"}, facts()) ==
               @rejected

      assert FormValidation.run(schema, %{}, facts()) == @rejected
      assert StubRunner.calls() == []
    end

    test "G4 draft, G5 discarded, G6 revoked", %{schema: schema} do
      stub!()

      draft =
        F.draft!(schema, "g4", "return { ok = true }", fv_manifest(),
          hook_kind: "form_validation"
        )

      assert FormValidation.run(schema, pin(draft), facts()) == @rejected

      to_discard =
        F.draft!(schema, "g5", "return { ok = true }", fv_manifest(),
          hook_kind: "form_validation"
        )

      actor = %{user_id: Ecto.UUID.generate(), credential: :oidc, trace_id: "r581"}

      assert {:ok, %{status: :discarded}} =
               Scripts.discard(schema, "g5", to_discard.version, actor)

      assert FormValidation.run(schema, pin(to_discard), facts()) == @rejected

      revoked =
        schema |> publish!("g6", "return { ok = true }") |> then(&F.revoke_raw!(schema, &1))

      assert FormValidation.run(schema, pin(revoked), facts()) == @rejected
      assert StubRunner.calls() == []
    end

    test "G8 an open output schema is rejected", %{schema: schema} do
      stub!()
      open = put_in(fv_manifest(), ["output_schema", "additionalProperties"], true)
      rule = publish!(schema, "g8", "return { ok = true }", open)
      assert FormValidation.run(schema, pin(rule), facts()) == @rejected
      assert StubRunner.calls() == []
    end

    test "G9 a retired row with a matching sha runs", %{schema: schema} do
      rule = schema |> publish!("g9", "return { ok = true }") |> then(&F.retire_raw!(schema, &1))
      assert {:ok, :accepted} = FormValidation.run(schema, pin(rule), facts())
    end

    test "G11 only config.exs and test.exs mention the flag" do
      hits =
        Path.wildcard("config/*.exs")
        |> Enum.filter(&(File.read!(&1) =~ "form_validation_hook_enabled"))
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()

      assert hits -- ["config.exs", "test.exs"] == []
      assert "config.exs" in hits
    end
  end

  describe "criterion 3: verdicts" do
    test "V1 accepted", %{schema: schema} do
      rule = publish!(schema, "v1", "return { ok = true }")
      assert FormValidation.run(schema, pin(rule), facts()) == {:ok, :accepted}
    end

    test "V2 a refusal with declared codes", %{schema: schema} do
      source = """
      return { ok = false, code = "too_short",
               fields = { { field = "note", code = "too_short" }, { field = "n", code = "bad" } } }
      """

      rule = publish!(schema, "v2", source)

      assert FormValidation.run(schema, pin(rule), facts()) ==
               {:ok,
                {:refused,
                 %{
                   code: "too_short",
                   fields: [%{field: "note", code: "too_short"}, %{field: "n", code: "bad"}]
                 }}}
    end

    test "V3 the result leaks nothing of the script or the submitted value", %{schema: schema} do
      value = "SECRET-SUBMITTED-VALUE-581"

      source =
        "local seen = ctx.input.output.note\nreturn { ok = false, code = \"bad\", fields = {} }"

      rule = publish!(schema, "v3key", source)

      result = FormValidation.run(schema, pin(rule), facts(%{"note" => value}))
      assert {:ok, {:refused, %{code: "bad", fields: []}}} = result
      text = inspect(result)

      for secret <- [value, rule.sha256, "v3key", "local seen", rule.source] do
        refute text =~ secret
      end
    end
  end

  describe "criterion 4: verdict validation" do
    # The decoded form of what each script would return (a Lua table decodes to string keys),
    # fed through the stub so the cases are deterministic; O16, O17 and V1..V3 run the real sandbox.
    @bad_outputs [
      {"O1 an extra key", %{"ok" => true, "extra" => 1}},
      {"O2 ok true plus code", %{"ok" => true, "code" => "bad"}},
      {"O3 ok true plus fields", %{"ok" => true, "fields" => []}},
      {"O4 ok not a boolean", %{"ok" => "yes"}},
      {"O5 ok missing", %{"code" => "bad"}},
      {"O6 an undeclared refusal code", %{"ok" => false, "code" => "zzz", "fields" => []}},
      {"O7 a refusal without a code", %{"ok" => false, "fields" => []}},
      {"O7b a refusal without fields", %{"ok" => false, "code" => "bad"}},
      {"O8 a non-string code", %{"ok" => false, "code" => 5, "fields" => []}},
      {"O9 an undeclared field",
       %{"ok" => false, "code" => "bad", "fields" => [%{"field" => "zz", "code" => "bad"}]}},
      {"O10 an undeclared field code",
       %{"ok" => false, "code" => "bad", "fields" => [%{"field" => "note", "code" => "zz"}]}},
      {"O11 an extra key in a field entry",
       %{
         "ok" => false,
         "code" => "bad",
         "fields" => [%{"field" => "note", "code" => "bad", "more" => 1}]
       }},
      {"O12 fields not a list", %{"ok" => false, "code" => "bad", "fields" => "note"}},
      {"O13 an output that is not an object", [1, 2]},
      {"O14 a $ key", %{"ok" => true, "$writes" => %{}}}
    ]

    for {name, output} <- @bad_outputs do
      test name, %{schema: schema} do
        stub!()
        rule = publish!(schema, "o_case", "return { ok = true }")
        StubRunner.reply(ok_reply(unquote(Macro.escape(output))))
        assert {:error, :output_invalid, stats} = FormValidation.run(schema, pin(rule), facts())

        assert Map.keys(stats) |> Enum.sort() == [
                 :duration_us,
                 :heap_words_at_end,
                 :instructions_used
               ]
      end
    end

    test "O15 an output above 64 KiB", %{schema: schema} do
      stub!()
      rule = publish!(schema, "o15", "return { ok = true }")

      big = %{
        "ok" => false,
        "code" => "bad",
        "fields" => [%{"field" => "note", "code" => String.duplicate("a", 70_000)}]
      }

      StubRunner.reply(ok_reply(big))
      assert {:error, :output_invalid, _} = FormValidation.run(schema, pin(rule), facts())
    end

    test "O16 an empty fields list with a declared code is a refusal", %{schema: schema} do
      rule = publish!(schema, "o16", "return { ok = false, code = \"bad\", fields = {} }")

      assert FormValidation.run(schema, pin(rule), facts()) ==
               {:ok, {:refused, %{code: "bad", fields: []}}}
    end

    test "O17 the script cannot change what it was given", %{schema: schema} do
      source = "ctx.input.output.note = \"changed\"\nreturn { ok = true }"
      rule = publish!(schema, "o17", source)
      f = facts()
      before = f
      assert {:ok, :accepted} = FormValidation.run(schema, pin(rule), f)
      assert f == before
      assert f.variables == %{"note" => "hello"}
    end
  end

  describe "criterion 5: executor outcomes" do
    setup %{schema: schema} do
      stub!()
      {:ok, rule: publish!(schema, "x", "return { ok = true }")}
    end

    defp expect_error(schema, rule, reply, code) do
      StubRunner.reply(reply)
      assert {:error, ^code, stats} = FormValidation.run(schema, pin(rule), facts())

      assert Map.keys(stats) |> Enum.sort() == [
               :duration_us,
               :heap_words_at_end,
               :instructions_used
             ]

      assert is_integer(stats.duration_us)
      stats
    end

    test("X1 script_error", %{schema: s, rule: r},
      do: expect_error(s, r, {:error, :script_error, %{}}, :script_error)
    )

    test "X2 script_failed maps to script_error", %{schema: s, rule: r} do
      detail = %{fail: %{code: "secret_code", details: %{}}}
      stats = expect_error(s, r, {:error, :script_failed, detail}, :script_error)
      refute inspect(stats) =~ "secret_code"
    end

    test("X3 an unexpected term", %{schema: s, rule: r},
      do: expect_error(s, r, :weird, :script_error)
    )

    test("X4 a raise", %{schema: s, rule: r},
      do: expect_error(s, r, fn -> raise "boom" end, :script_error)
    )

    test("X5 an exit", %{schema: s, rule: r},
      do: expect_error(s, r, fn -> exit(:gone) end, :script_error)
    )

    test("X6 a throw", %{schema: s, rule: r},
      do: expect_error(s, r, fn -> throw(:out) end, :script_error)
    )

    test("X7 an unknown error code", %{schema: s, rule: r},
      do: expect_error(s, r, {:error, :script_rejected, %{}}, :script_error)
    )

    test("X9 budget", %{schema: s, rule: r},
      do: expect_error(s, r, {:error, :budget_exceeded, %{}}, :budget_exceeded)
    )

    test("X10 memory", %{schema: s, rule: r},
      do: expect_error(s, r, {:error, :memory_limit_exceeded, %{}}, :memory_limit_exceeded)
    )

    test("X11 timeout", %{schema: s, rule: r},
      do: expect_error(s, r, {:error, :timeout, %{}}, :timeout)
    )

    test "X12 busy, X17 and no retry", %{schema: s, rule: r} do
      expect_error(s, r, {:error, :script_busy, %{}}, :script_busy)
      assert length(StubRunner.calls()) == 1
    end

    test("X13 output_invalid from the runner", %{schema: s, rule: r},
      do: expect_error(s, r, {:error, :output_invalid, %{}}, :output_invalid)
    )

    test "X14 stats: three keys, from the runner on success", %{schema: s, rule: r} do
      StubRunner.reply(
        {:ok,
         %{
           output: %{"ok" => true},
           stats: %{
             duration_us: 7,
             instructions_used: 3,
             instructions_budget: 5,
             heap_words_at_end: 9,
             heap_words_limit: 1,
             input_dropped: 0
           }
         }}
      )

      assert {:ok, :accepted} = FormValidation.run(s, pin(r), facts())

      StubRunner.reply(
        {:ok,
         %{
           output: %{"ok" => "no"},
           stats: %{
             duration_us: 7,
             instructions_used: 3,
             instructions_budget: 5,
             heap_words_at_end: 9
           }
         }}
      )

      assert {:error, :output_invalid,
              %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9} = stats} =
               FormValidation.run(s, pin(r), facts())

      assert map_size(stats) == 3
    end

    test "X14b stats: not started is 0, nil, nil", %{schema: s, rule: r} do
      set_env(:form_validation_hook_enabled, false)
      assert FormValidation.run(s, pin(r), facts()) == {:error, :script_rejected, @not_started}
    end

    test "X14c a malformed fact is input_invalid and starts nothing", %{schema: s, rule: r} do
      bad = %{facts() | instance_id: 5}
      assert FormValidation.run(s, pin(r), bad) == {:error, :input_invalid, @not_started}
      assert StubRunner.calls() == []
    end
  end

  describe "criterion 5: the real sandbox" do
    @describetag :lua_wallclock_race

    test "X15 a looping script ends as timeout or budget", %{schema: schema} do
      rule = publish!(schema, "x15", "while true do end")
      assert {:error, code, _} = FormValidation.run(schema, pin(rule), facts())
      assert code in [:timeout, :budget_exceeded]
    end

    test "X16 an allocating script ends as memory limit", %{schema: schema} do
      source = "local t = {}\nfor i = 1, 1000000 do t[i] = { i } end\nreturn { ok = true }"
      rule = publish!(schema, "x16", source, fv_manifest(%{}, %{"heap_words" => 100_000}))
      assert {:error, :memory_limit_exceeded, _} = FormValidation.run(schema, pin(rule), facts())
    end
  end

  describe "criterion 6: restriction filter" do
    # `restricted_a` of the criterion stands for a label "<entity_type>.<field>"; the labels here
    # are "customer.name" and "customer.email".
    defp pair(field), do: %{"entity_type" => "customer", "field" => field}

    defp restricted_manifest(from) do
      fv_manifest(%{"restricted_inputs" => [%{"name" => "note", "from" => from}]})
    end

    defp received_input do
      [{_source, input, _opts}] = StubRunner.calls()
      input["output"]
    end

    setup %{schema: schema} do
      stub!()
      P.active_definition!(schema, "customer", ["name", "email"])
      StubRunner.reply(ok_reply())
      :ok
    end

    @labels %{"note" => ["customer.name", "customer.email"]}

    test "R1 (a) no entry: a labelled variable is absent", %{schema: schema} do
      rule = publish!(schema, "r1", "return { ok = true }")
      f = facts(%{"n" => 1, "note" => "x"}, @labels)

      assert {:ok, :accepted} =
               FormValidation.run(schema, pin(rule), f, publisher_may_restricted?: true)

      assert received_input() == %{"n" => 1}
    end

    test "R1b (a) the same without the opt-in", %{schema: schema} do
      rule = publish!(schema, "r1b", "return { ok = true }")
      f = facts(%{"n" => 1, "note" => "x"}, @labels)
      assert {:ok, :accepted} = FormValidation.run(schema, pin(rule), f)
      assert received_input() == %{"n" => 1}
    end

    test "R2 (b) entry covering both labels and the opt-in: present", %{schema: schema} do
      rule =
        publish!(
          schema,
          "r2",
          "return { ok = true }",
          restricted_manifest([pair("name"), pair("email")])
        )

      f = facts(%{"note" => "x"}, @labels)

      assert {:ok, :accepted} =
               FormValidation.run(schema, pin(rule), f, publisher_may_restricted?: true)

      assert received_input() == %{"note" => "x"}
    end

    test "R3 (c) the same without the opt-in: absent", %{schema: schema} do
      rule =
        publish!(
          schema,
          "r3",
          "return { ok = true }",
          restricted_manifest([pair("name"), pair("email")])
        )

      f = facts(%{"note" => "x"}, @labels)
      assert {:ok, :accepted} = FormValidation.run(schema, pin(rule), f)
      assert received_input() == %{}
    end

    test "R4 (d) an entry lacking one of the two labels: absent", %{schema: schema} do
      rule = publish!(schema, "r4", "return { ok = true }", restricted_manifest([pair("name")]))
      f = facts(%{"note" => "x"}, @labels)

      assert {:ok, :accepted} =
               FormValidation.run(schema, pin(rule), f, publisher_may_restricted?: true)

      assert received_input() == %{}
    end

    test "R5 (e) an entry naming an inactive definition is rejected", %{schema: schema} do
      P.inactive_definition!(schema, "ghost")
      from = [%{"entity_type" => "ghost", "field" => "name"}]
      rule = publish!(schema, "r5", "return { ok = true }", restricted_manifest(from))
      f = facts(%{"note" => "x"}, %{"note" => ["ghost.name"]})

      assert FormValidation.run(schema, pin(rule), f, publisher_may_restricted?: true) ==
               @rejected

      assert StubRunner.calls() == []
    end

    test "R6 a required but omitted variable is input_invalid and leaks nothing", %{
      schema: schema
    } do
      manifest = put_in(fv_manifest(), ["input_schema", "required"], ["note"])
      rule = publish!(schema, "r6", "return { ok = true }", manifest)
      f = facts(%{"note" => "RESTRICTED-VALUE-581"}, @labels)
      result = FormValidation.run(schema, pin(rule), f)

      assert result == {:error, :input_invalid, @not_started}
      refute inspect(result) =~ "RESTRICTED-VALUE-581"
      assert StubRunner.calls() == []
    end
  end

  describe "criterion 7: wall clock" do
    setup do
      stub!()
      StubRunner.reply(ok_reply())
      :ok
    end

    test "W1 the default and the cap" do
      assert FormValidation.default_timeout_ms() <= 50
      assert FormValidation.max_timeout_ms() <= 50
      assert FormValidation.default_timeout_ms() <= FormValidation.max_timeout_ms()
    end

    test "W2 the runner is called with min(manifest, 50)", %{schema: schema} do
      cases = [{10, 10}, {50, 50}, {51, 50}, {1000, 50}, {5000, 50}]

      for {{limit, expected}, i} <- Enum.with_index(cases) do
        rule =
          publish!(
            schema,
            "w2_#{i}",
            "return { ok = true }",
            fv_manifest(%{}, %{"timeout_ms" => limit})
          )

        assert {:ok, :accepted} = FormValidation.run(schema, pin(rule), facts())
        {_source, _input, opts} = List.last(StubRunner.calls())
        assert opts[:timeout_ms] == expected
      end

      manifest = update_in(fv_manifest(), ["limits"], &Map.delete(&1, "timeout_ms"))
      rule = publish!(schema, "w2_none", "return { ok = true }", manifest)
      assert {:ok, :accepted} = FormValidation.run(schema, pin(rule), facts())
      {_source, _input, opts} = List.last(StubRunner.calls())
      assert opts[:timeout_ms] == FormValidation.default_timeout_ms()
      assert opts[:fail_codes] == []
    end

    test "W3 the runner's own limits are unchanged" do
      limits = ScriptRunner.limits()
      assert limits.default_timeout_ms == 1_000
      assert limits.max_timeout_ms == 5_000
    end
  end

  describe "criterion 8: tenant isolation" do
    test "T1 a version published only in A is invisible through B's prefix", %{schema: a} do
      stub!()
      b = F.tenant!("r581b").schema_name
      rule = publish!(a, "only_a", "return { ok = true }")

      foreign = FormValidation.run(b, pin(rule), facts())
      nowhere = FormValidation.run(b, %{pin(rule) | script_key: "nowhere_at_all"}, facts())

      assert foreign == @rejected
      assert foreign == nowhere
      assert StubRunner.calls() == []
    end

    test "T2 the owning prefix runs it", %{schema: a} do
      rule = publish!(a, "t2", "return { ok = true }")
      assert {:ok, :accepted} = FormValidation.run(a, pin(rule), facts())
    end

    test "T3 foreign tenant strings in the facts do not select a tenant", %{schema: a} do
      b = F.tenant!("r581c").schema_name
      rule = publish!(a, "t3", "return { ok = true }")

      f =
        facts(%{"note" => a})
        |> Map.merge(%{tenant: a, prefix: a, instance_id: a, token_id: a})
        |> put_in([:form, :definition_id], a)

      assert FormValidation.run(b, pin(rule), f) == @rejected
      assert {:ok, :accepted} = FormValidation.run(a, pin(rule), f)
    end

    test "T5 every Repo call in the module carries a prefix" do
      lines =
        "lib/letflow/scripts/form_validation.ex"
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/\bRepo\.[a-z_!]+\(/))

      assert lines != []
      assert Enum.all?(lines, &(&1 =~ "prefix: prefix"))
    end
  end
end
