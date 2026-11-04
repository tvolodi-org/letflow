defmodule Letflow.Ledger.TenancyTest do
  @moduledoc """
  REQ-621 / GH #3469 part C, criterion 8: TN-1..TN-5. The schema prefix comes only from the
  capability (two committed tenants, an INV-10 style negative), a source scan proves no SQL
  string interpolation, a single mapping `rescue` and no `Logger` call in the ledger modules, and
  refusals leak no values into the log or the result.
  Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx

  @tables ~w(ledger_entry ledger_leg ledger_counter ledger_balance)

  setup do
    Fx.setup_auto_mode!()
    %{a: Fx.tenant!(), b: Fx.tenant!()}
  end

  defp counts(schema), do: Map.new(@tables, &{&1, Fx.count(schema, &1)})

  test "TN-1 a posting under A writes only A", %{a: a, b: b} do
    Fx.post!(Fx.capability(a, "receipt", [Fx.leg(["a"], 1)]))

    assert %{"ledger_entry" => 1, "ledger_leg" => 1, "ledger_counter" => 1, "ledger_balance" => 1} =
             counts(a)

    assert counts(b) == Map.new(@tables, &{&1, 0})
  end

  test "TN-2 the same op id and subject under B is a new posting, nothing of A in the result",
       %{a: a, b: b} do
    subject = Ecto.UUID.generate()
    cmd = %{client_op_id: "shared-op"}

    first =
      Fx.post!(Fx.capability(a, "receipt", [Fx.leg(["a"], 1)], command: cmd, subject_id: subject))

    second =
      Fx.post!(
        Fx.capability(b, "receipt", [Fx.leg(["a"], 1)],
          command: cmd,
          subject_id: subject,
          origin_key: "other-origin"
        )
      )

    assert second.duplicate == false
    assert second.posting_seq == 1
    assert second.entry_id != first.entry_id
    refute inspect(second) =~ first.entry_id
    assert Fx.count(a, "ledger_entry") == 1
    assert Fx.count(b, "ledger_entry") == 1
  end

  test "TN-3 a prefix in the command or posting is ignored; a malformed prefix is refused",
       %{a: a, b: b} do
    cap =
      Fx.capability(a, "receipt", [Fx.leg(["a"], 1)],
        command: %{prefix: b},
        posting: %{prefix: b}
      )

    assert {:ok, _} = Fx.post_tx(cap)
    assert Fx.count(a, "ledger_entry") == 1
    assert counts(b) == Map.new(@tables, &{&1, 0})

    for bad <- [
          ~s|tenant_x"; DROP TABLE a; --|,
          "public",
          "",
          nil,
          :tenant_x,
          "TENANT_" <> String.duplicate("0", 32)
        ] do
      {result, statements} =
        Fx.record(fn -> Ledger.post(%{cap | prefix: bad}) end)

      assert result == {:error, {:ledger_contract, :invalid_capability}}
      assert statements == []
    end

    assert Fx.count(a, "ledger_entry") == 1
  end

  describe "TN-4 source scan" do
    @sql ~r/\b(select|insert|update|delete|from|where|drop|alter|create|lock|truncate|set)\b/i

    test "the scan finds a synthetic offender (it is not vacuous)" do
      source = """
      defmodule X do
        def a(t), do: Repo.query!("SELECT * FROM \#{t}")
        def b(q), do: Repo.query!(q)
        def c, do: Logger.info("x")
        def d(t), do: fragment("lock \#{t}")
        def e do
          Repo.all(x)
        rescue
          e -> e
        end
        def f do
          Repo.all(x)
        rescue
          e -> e
        end
      end
      """

      found = scan(source)
      assert :interpolated_sql in found
      assert :query_not_literal in found
      assert :logger in found
      assert :fragment_interpolation in found
      assert Enum.count(found, &(&1 == :rescue)) == 2
    end

    test "the ledger modules interpolate no SQL, rescue only two named cases, never log" do
      files = Path.wildcard("lib/letflow/ledger.ex") ++ Path.wildcard("lib/letflow/ledger/*.ex")
      assert length(files) >= 4

      findings = for file <- files, f <- scan(File.read!(file)), do: {file, f}
      assert Enum.reject(findings, &(elem(&1, 1) == :rescue)) == []

      # REQ-637 part A: the entry insert's unique-index backstop of the reversal target.
      # REQ-637 part B: authorize/3 catching ScopeSetError (fail closed). Both in ledger.ex.
      assert for({file, :rescue} <- findings, do: file) == [
               "lib/letflow/ledger.ex",
               "lib/letflow/ledger.ex"
             ]
    end

    defp scan(source) do
      {:ok, ast} = Code.string_to_quoted(source)

      {_ast, acc} =
        Macro.prewalk(ast, [], fn
          {:@, _, [{attr, _, _}]} = node, acc when attr in [:moduledoc, :doc] ->
            {skip(node), acc}

          {:<<>>, _, parts} = node, acc ->
            literal = for p <- parts, is_binary(p), into: "", do: p

            if Enum.any?(parts, &(not is_binary(&1))) and Regex.match?(@sql, literal),
              do: {node, [:interpolated_sql | acc]},
              else: {node, acc}

          {{:., _, [{:__aliases__, _, aliases}, fun]}, _, [first | _]} = node, acc
          when fun in [:query, :query!] ->
            if List.last(aliases) == :Repo and not is_binary(first),
              do: {node, [:query_not_literal | acc]},
              else: {node, acc}

          {:fragment, _, [{:<<>>, _, parts} | _]} = node, acc ->
            if Enum.any?(parts, &(not is_binary(&1))),
              do: {node, [:fragment_interpolation | acc]},
              else: {node, acc}

          {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} = node, acc ->
            {node, [:logger | acc]}

          {:rescue, _clauses} = node, acc ->
            {node, [:rescue | acc]}

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(acc)
    end

    defp skip({:@, meta, [{attr, m2, _}]}), do: {:@, meta, [{attr, m2, [nil]}]}
  end

  test "TN-5 refusals leak no values into the log or the result", %{a: a} do
    marker = "mk-#{System.unique_integer([:positive])}"
    bounded = Fx.registration(key_bounds: [%{when_slot_nonempty: "k_third", max_on_hand: "3"}])

    Fx.seed_on_hand!(a, [marker, "l"], "3.5")

    log =
      capture_log([level: :warning], fn ->
        # insufficient_balance
        issue = Fx.capability(a, "issue", [Fx.leg([marker, "l"], "-7.25")])

        assert {:error, {:ledger_refused, :insufficient_balance, _, _} = refusal} =
                 Fx.post_tx(issue)

        no_balance_leak(refusal)

        # balance_bound_exceeded
        big =
          Fx.capability(a, "receipt", [Fx.leg([marker, "l", "s"], "7.25")], registration: bounded)

        assert {:error, {:ledger_refused, :balance_bound_exceeded, _, _}} = Fx.post_tx(big)

        # idempotency_key_reuse
        first = Fx.capability(a, "receipt", [Fx.leg([marker, "m"], 1)])
        assert {:ok, _} = Fx.post_tx(first)
        changed = %{first | command: Map.put(first.command, :note, marker)}
        assert {:error, {:ledger_refused, :idempotency_key_reuse, _, _}} = Fx.post_tx(changed)

        # client_seq_conflict
        subject = Ecto.UUID.generate()
        cmd = %{device_id: "dev-tn", client_seq: 1}

        one =
          Fx.capability(a, "receipt", [Fx.leg([marker, "n"], 1)],
            command: cmd,
            subject_id: subject
          )

        two =
          Fx.capability(a, "receipt", [Fx.leg([marker, "n"], 1)],
            command: cmd,
            subject_id: subject
          )

        assert {:ok, _} = Fx.post_tx(one)
        assert {:error, {:ledger_refused, :client_seq_conflict, _, _}} = Fx.post_tx(two)

        # event_time_in_future / event_time_too_old
        now = DateTime.utc_now()

        for {seq, secs, code} <- [
              {2, 3600, :event_time_in_future},
              {3, -(97 * 3600), :event_time_too_old}
            ] do
          time = now |> DateTime.add(secs, :second) |> DateTime.to_iso8601()
          cmd = %{device_id: "dev-tn", client_seq: seq, client_event_time: time}
          cap = Fx.capability(a, "receipt", [Fx.leg([marker, "o"], "7.25")], command: cmd)
          assert {:error, {:ledger_refused, ^code, _, _}} = Fx.post_tx(cap)
        end
      end)

    refute log =~ marker
    refute log =~ "7.25"
    refute log =~ "3.5"
  end

  defp no_balance_leak(refusal) do
    text = inspect(refusal, limit: :infinity)
    refute text =~ "3.5"
    refute text =~ "available"
    refute text =~ "on_hand"
  end
end
