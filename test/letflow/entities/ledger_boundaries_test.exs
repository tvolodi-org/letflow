defmodule Letflow.LedgerBoundariesTest do
  @moduledoc """
  REQ-620 / GH #3463 part C, criterion 10: `mix letflow.check_boundaries` Rules 7 (neutral
  vocabulary) and 7b (no module reference but the registration module). Pure, no database.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Letflow.CheckBoundaries, as: CB

  defp scan(source), do: CB.ledger_rule_violations([{"x.ex", source}])
  defp words(source), do: for({_, :rule_7, d} <- scan(source), do: d)

  test "T-SC-1a the real ledger files are clean and both migrations are scanned" do
    paths = CB.ledger_scan_paths()
    assert "priv/repo/migrations/20261031100001_create_ledger_tables.exs" in paths
    assert "priv/repo/migrations/20261031200001_create_ledger_triggers.exs" in paths
    assert CB.ledger_rule_violations(Enum.map(paths, &{&1, File.read!(&1)})) == []
  end

  test "T-SC-1b denylisted words are flagged, neutral look-alikes pass" do
    assert [_] = words("def stock_movement, do: 1")
    assert [_] = words("def insufficient_stock, do: 1")
    assert [_] = words("x = Letflow.StockPost")
    assert [_] = words(~s|x = "items"|)
    assert [_] = words(~s|x = "warehouse_id"|)
    assert [_] = words("x = :Locations")

    assert scan("def insufficient_balance, do: :binary") == []
    assert scan(~s|x = "website lottery"|) == []
  end

  test "T-SC-1b2 the lib/letflow/ledger.ex path is in scope: code is flagged, prose is not" do
    path = "lib/letflow/ledger.ex"
    assert path in CB.ledger_scan_paths()

    code = "defmodule Letflow.Ledger do\n  def stock_total, do: 1\nend"
    assert [{^path, :rule_7, _}] = CB.ledger_rule_violations([{path, code}])

    prose = ~S'''
    defmodule Letflow.Ledger do
      @moduledoc "stock"
      def total, do: 1
    end
    '''

    assert CB.ledger_rule_violations([{path, prose}]) == []
  end

  test "T-SC-1c prose is not scanned, code string literals are" do
    prose = ~S'''
    defmodule M do
      @moduledoc "stock item warehouse"
      @doc "lot serial sku"
      @typedoc "pallet"
      # inventory material bin
      def f, do: 1
    end
    '''

    assert scan(prose) == []
    assert [_] = words(~s|defmodule M do\n  def f, do: "stock"\nend|)
  end

  test "T-SC-1d Rule 7b flags module references except the registration module" do
    assert [{_, :rule_7b, _}] = scan("x = Letflow.Modules.Exam.Foo")
    assert [{_, :rule_7b, _}] = scan("alias Letflow.Modules.Catalog")
    assert [{_, :rule_7b, _}] = scan("alias Letflow.Modules")
    assert [{_, :rule_7b, _}] = scan(~s|x = "Elixir.Letflow.Modules.Exam"|)
    assert scan("x = Letflow.Modules.LedgerRegistration") == []
  end

  test "T-SC-1e a syntax error is a violation, not a raise" do
    assert [{"x.ex", :parse_error, _}] = scan("def f(, do: ")
  end

  test "T-SC-1g the allowlist starts empty (a new pair is a reviewed diff)" do
    src = File.read!("lib/mix/tasks/letflow.check_boundaries.ex")
    assert src =~ "@neutral_vocabulary_allowlist []"
  end

  # ── REQ-684: Rule 8 (T-SC-4) and the policy allowlist (T-PL-1 scan part) ──────────────────

  defp r8(source, path \\ "lib/letflow/modules/demo/x.ex"),
    do: for({^path, :rule_8, form} <- CB.rule_8_violations([{path, source}]), do: form)

  defp pol(source),
    do: for({"p.ex", :policy_allowlist, d} <- CB.policy_violations([{"p.ex", source}]), do: d)

  describe "T-SC-4 Rule 8" do
    test "T-SC-4a post and mint, also through an alias" do
      assert r8("def f(c), do: Letflow.Ledger.post(c)") == [{:a, "Letflow.Ledger.post"}]

      assert r8("def f(c), do: Letflow.Ledger.Capability.mint(a, b, c, d)")
             |> Enum.member?({:a, "Letflow.Ledger.Capability.mint"})

      assert r8("alias Letflow.Ledger, as: L\ndef f(c), do: L.post(c)") == [
               {:a, "Letflow.Ledger.post"}
             ]

      assert r8("alias Letflow.Ledger\ndef f(c), do: Ledger.post(c)") == [
               {:a, "Letflow.Ledger.post"}
             ]

      assert r8("alias Letflow.{Ledger, Other}\ndef f(c), do: Ledger.post(c)") == [
               {:a, "Letflow.Ledger.post"}
             ]

      assert r8("def f, do: &Letflow.Ledger.post/1") == [{:a, "Letflow.Ledger.post"}]
    end

    test "T-SC-4b any other Letflow.Ledger function, other submodules, import and use" do
      assert r8("def f, do: Letflow.Ledger.fetch_by_client_op_id(1)") == [
               {:b, "Letflow.Ledger.fetch_by_client_op_id"}
             ]

      assert r8("def f, do: Letflow.Ledger.Digest.registration_hash(1)") == [
               {:b, "Letflow.Ledger.Digest.registration_hash"}
             ]

      assert r8("def f, do: Letflow.Ledger.Validate.posting(1, 2, 3)") == [
               {:b, "Letflow.Ledger.Validate.posting"}
             ]

      assert r8("import Letflow.Ledger") == [{:b, "import Letflow.Ledger"}]
      assert r8("use Letflow.Ledger.Digest") == [{:b, "use Letflow.Ledger.Digest"}]
      assert r8("require Letflow.Ledger") == [{:b, "require Letflow.Ledger"}]
    end

    test "T-SC-4c struct literal, pattern, map with __struct__, alias and atom spelling" do
      for name <- [
            "Letflow.Ledger.Capability",
            "Letflow.Ledger.Authorized",
            "Letflow.Api.Scope.Principal"
          ] do
        short = name |> String.split(".") |> List.last()
        assert {:c, name} in r8("def f, do: %#{name}{}")
        assert {:c, name} in r8("def f(%#{name}{}), do: 1")
        assert {:c, name} in r8("alias #{name}\ndef f, do: %#{short}{}")
        assert {:c, name} in r8("alias #{name}, as: Z\ndef f(%Z{}), do: 1")

        assert {:c, name} in r8(
                 "alias #{name |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")}.{#{short}}\ndef f, do: %#{short}{}"
               )

        assert {:c, name} in r8(~s|def f, do: :"Elixir.#{name}"|)
      end

      assert {:c, "%{__struct__: ...}"} in r8("def f, do: %{__struct__: Foo, a: 1}")
      assert {:c, "%{__struct__: ...}"} in r8("def f(x), do: %{__struct__: :\"Elixir.Foo\"}")
      # a bare variable only binds a module in a pattern (exception tagging in the real tree)
      assert r8("defp tag(%{__exception__: true, __struct__: module}), do: module") == []
    end

    test "T-SC-4d dynamic dispatch that could build a ledger name" do
      assert r8("def f(m), do: apply(m, :x, [])") == [{:d, "apply"}]
      assert r8("def f(m), do: apply(fn -> 1 end, [])") == [{:d, "apply"}]
      assert r8("def f(m), do: Kernel.apply(m, :x, [])") == [{:d, "Kernel.apply"}]
      assert r8("def f(m), do: :erlang.apply(m, :x, [])") == [{:d, ":erlang.apply"}]
      assert r8("def f(m), do: Module.concat(m, X)") == [{:d, "Module.concat"}]
      assert r8("def f(m), do: Module.safe_concat([m])") == [{:d, "Module.safe_concat"}]
      assert r8("def f(m), do: String.to_existing_atom(m)") == [{:d, "String.to_existing_atom"}]

      assert r8("alias String, as: S\ndef f(m), do: S.to_existing_atom(m)") == [
               {:d, "String.to_existing_atom"}
             ]
    end

    test "T-SC-4e a policy file names no Letflow module but Letflow.Ledger.Policy and its own" do
      path = "lib/letflow/modules/demo/ledger_policy/p.ex"

      assert r8("def f, do: Letflow.Modules.Demo.Other.go()", path) == [
               {:e, "Letflow.Modules.Demo.Other"}
             ]

      assert r8("def f, do: Letflow.Repo.all(1)", path) == [{:e, "Letflow.Repo"}]
      assert r8("alias Letflow.Ledger.Policy\ndef f, do: Policy.decimal(\"1\", 0)", path) == []
      assert r8("def f, do: Enum.map([], & &1)", path) == []

      own = "defmodule Letflow.Modules.Demo.LedgerPolicy.Helper do\n  def g, do: 1\nend"

      files = [
        {path, "def f, do: Letflow.Modules.Demo.LedgerPolicy.Helper.g()"},
        {"lib/letflow/modules/demo/ledger_policy/h.ex", own}
      ]

      assert CB.rule_8_violations(files) == []
      # the same reference outside a policy directory is not clause e
      assert r8("def f, do: Letflow.Modules.Demo.Other.go()") == []
    end

    test "T-SC-4f reads and the policy helper are not flagged" do
      for read <- [
            "authorize(a, b, c)",
            "balances(a, b, c, d)",
            "entries(a, b, c, d)",
            "reconcile(a, b, c)"
          ] do
        assert r8("def f(a, b, c, d), do: Letflow.Ledger.#{read}") == [], read
      end

      assert r8(~s|def f, do: Letflow.Ledger.Policy.decimal("1", 0)|) == []
      assert r8("def f, do: Letflow.Engine.Wasm.CapabilityGate.ok()") == []

      assert r8("# Letflow.Ledger.post(1)\n@moduledoc \"Letflow.Ledger.post\"\ndef f, do: 1") ==
               []
    end

    test "T-SC-4g the ledger namespace and the registration module are exempt by construction" do
      src = "def f(c), do: Letflow.Ledger.post(c)"
      assert r8(src, "lib/letflow/ledger/x.ex") == []
      assert r8(src, "lib/letflow/ledger/deep/y.ex") == []
      assert r8(src, "lib/letflow/modules/ledger_registration.ex") == []
      assert r8(src) == [{:a, "Letflow.Ledger.post"}]
    end

    test "T-SC-4h the real tree has no violation once the reviewed exemptions apply" do
      paths = CB.rule_8_paths()
      assert paths != []
      assert "lib/letflow/modules/procurement/router.ex" in paths
      assert Enum.any?(paths, &String.starts_with?(&1, "lib/letflow/scripts/"))
      assert Enum.any?(paths, &String.starts_with?(&1, "lib/letflow/engine/wasm/"))
      refute "lib/letflow/modules/catalog.ex" in paths
      refute "lib/letflow/modules/ledger_registration.ex" in paths

      raw = CB.rule_8_violations(Enum.map(paths, &{&1, File.read!(&1)}))
      assert CB.apply_rule_8_exemptions(raw) == []
    end

    test "T-SC-4i the exemption list is pinned and every pair still violates" do
      assert CB.rule_8_exemptions() == [
               {"lib/letflow/modules/procurement/decisions.ex", {:d, "String.to_existing_atom"}},
               {"lib/letflow/modules/procurement/router.ex", {:d, "apply"}},
               {"lib/letflow/scripts/policy.ex", {:d, "String.to_existing_atom"}}
             ]

      for {path, form} <- CB.rule_8_exemptions() do
        assert {path, :rule_8, form} in CB.rule_8_violations([{path, File.read!(path)}]), path
      end

      assert CB.apply_rule_8_exemptions([{"other.ex", :rule_8, {:d, "apply"}}]) ==
               [{"other.ex", :rule_8, {:d, "apply"}}]
    end

    test "T-SC-4j the moduledoc describes Rule 8 instead of saying it is not built" do
      src = File.read!("lib/mix/tasks/letflow.check_boundaries.ex")
      refute src =~ "Rule 8 is not built"
      assert src =~ "**Rule 8"
    end

    test "a syntax error is a violation, not a raise" do
      assert [{"x.ex", :parse_error, _}] = CB.rule_8_violations([{"x.ex", "def f(, do: "}])
      assert [{"x.ex", :parse_error, _}] = CB.policy_violations([{"x.ex", "def f(, do: "}])
    end
  end

  describe "T-PL-1c the policy allowlist" do
    @banned [
      {"Repo.all(q)", {:module, "Repo"}},
      {"Letflow.Repo.all(q)", {:module, "Letflow.Repo"}},
      {"Ecto.Query.from(x)", {:module, "Ecto.Query"}},
      {"Process.get(:x)", {:module, "Process"}},
      {":ets.new(:t, [])", {:erlang, :ets}},
      {":persistent_term.get(:x)", {:erlang, :persistent_term}},
      {"Agent.start(fn -> 1 end)", {:module, "Agent"}},
      {"GenServer.call(a, b)", {:module, "GenServer"}},
      {"Task.async(fn -> 1 end)", {:module, "Task"}},
      {"Application.get_env(:a, :b)", {:module, "Application"}},
      {"System.get_env(\"A\")", {:module, "System"}},
      {"File.read(\"x\")", {:module, "File"}},
      {":rand.uniform(3)", {:erlang, :rand}},
      {"DateTime.utc_now()", {:module, "DateTime"}},
      {":os.cmd('ls')", {:erlang, :os}},
      {":erlang.system_time()", {:erlang, :erlang}},
      {"Regex.match?(~r/a/, \"a\")", {:module, "Regex"}},
      {"String.to_atom(x)", {:call, "String.to_atom"}},
      {"String.to_existing_atom(x)", {:call, "String.to_existing_atom"}},
      {"List.to_atom(x)", {:call, "List.to_atom"}},
      {"List.to_existing_atom(x)", {:call, "List.to_existing_atom"}},
      {"Module.concat(a, b)", {:module, "Module"}},
      {"Kernel.send(self, 1)", {:module, "Kernel"}},
      {"Kernel.apply(a, :b, [])", {:module, "Kernel"}},
      {"send(pid, 1)", {:local, :send}},
      {"spawn(fn -> 1 end)", {:local, :spawn}},
      {"spawn_link(fn -> 1 end)", {:local, :spawn_link}},
      {"self()", {:local, :self}},
      {"make_ref()", {:local, :make_ref}},
      {"node()", {:local, :node}},
      {"apply(mod, :f, [])", {:local, :apply}},
      {"apply(Enum, :map, [[], & &1])", {:local, :apply}},
      {"receive do\n x -> x\n end", {:local, :receive}},
      {"mod.go(1)", :dynamic_call},
      {"Enum.map(x, &send(&1, 1))", {:local, :send}},
      {"Enum.map(x, &apply/3)", {:local, :apply}},
      {"import Logger", {:module, "Logger"}},
      {"use GenServer", {:module, "GenServer"}},
      {"alias Ecto.Changeset", {:module, "Ecto.Changeset"}}
    ]

    for {{code, expected}, index} <- Enum.with_index(@banned) do
      test "T-PL-1c-#{index} #{code} is refused" do
        source = "defmodule P do\n  def f(x, mod, pid, q) do\n    #{unquote(code)}\n  end\nend\n"
        assert unquote(Macro.escape(expected)) in pol(source)
      end
    end

    test "a source that uses only the allowed set is clean" do
      source = """
      defmodule P do
        @behaviour Letflow.Ledger.Policy
        alias Letflow.Ledger.Policy

        def declare(%{legs: legs} = cmd, _registration) when is_list(legs) do
          legs
          |> Enum.map(&Policy.leg/1)
          |> Enum.reduce(%{}, fn leg, acc -> Map.put(acc, length(legs), leg) end)
          |> Map.merge(%{a: Keyword.get([a: 1], :a), b: Integer.to_string(1), c: List.first([1])})
          |> then(&{:ok, &1})
          |> elem(1)
          |> Map.put(:t, Tuple.to_list({1}))
          |> Map.put(:s, MapSet.new([min(1, 2)]))
          |> Map.put(:d, Decimal.add(Decimal.new(1), 1))
          |> Map.put(:x, String.upcase("a") <> to_string(abs(-1)) <> to_string(byte_size("a")))
          |> Map.put(:y, cmd[:a])
          |> Map.put(:z, cmd.legs)
          |> Map.put(:h, P.Helper.go(1))
        end
      end

      defmodule P.Helper do
        def go(x), do: Access.get(%{a: x}, :a)
      end
      """

      assert pol(source) == []
    end

    test "T-PL-1d the fixture policy files are clean" do
      file = "test/support/modules/fixture_ledger_post/ledger_policy/ledger_policy.ex"
      assert CB.policy_violations([{file, File.read!(file)}]) == []

      assert CB.rule_8_violations([
               {"lib/letflow/modules/fixture_ledger_post/ledger_policy/ledger_policy.ex",
                File.read!(file)}
             ]) == []
    end

    test "T-PL-1e the scan reads exactly the policy directories and sees the fixture when pointed at it" do
      for path <- CB.policy_paths() do
        assert [_, _, _, _, "ledger_policy" | _] = Path.split(path)
      end

      assert CB.policy_violations(Enum.map(CB.policy_paths(), &{&1, File.read!(&1)})) == []

      assert [{"p.ex", :policy_allowlist, {:module, "Repo"}}] =
               CB.policy_violations([{"p.ex", "Repo.all(1)"}])
    end
  end
end
