defmodule Letflow.LedgerTriggersMigrationTest do
  @moduledoc """
  REQ-620 / GH #3463 part B (criteria 5 and 6): the triggers and functions that make `ledger_entry` and
  `ledger_leg` append-only and enforce the gap-free `posting_seq` and the counter / chain consistency.
  `async: false` (tenant provisioning, DDL, real commits: `provisioned_tenant!` sets Sandbox `:auto`, so
  the deferred constraint triggers fire at COMMIT). Raw SQL on purpose: no `Letflow.Ledger` module exists
  yet (part C). Test IDs B-1..B-19 follow state/tasks/T-0889/design.md section 4.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo.Migrations.CreateLedgerTriggers
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  import Bitwise

  @migration_path "priv/repo/migrations/20261031200001_create_ledger_triggers.exs"
  @t0 "2026-10-31T10:00:00Z"
  @append_only "ledger data is append-only: this statement is refused"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r620b-trg")
    schema = tenant.schema_name
    # one committed posting: ledger "wh", seq 1, one leg (k1 "a", +5), balance on_hand 5
    e1 = post(schema, "wh", 1, legs: [%{k1: "a", q: 5}], balance: {"a", 5})
    {:ok, schema: schema, tenant_id: tenant.tenant_id, e1: e1}
  end

  # -- helpers ---------------------------------------------------------------------------------------

  defp lit(nil), do: "NULL"
  defp lit({:raw, sql}), do: sql
  defp lit(n) when is_integer(n), do: Integer.to_string(n)
  defp lit(s) when is_binary(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  defp insert_sql(schema, table, row) do
    cols = row |> Map.keys() |> Enum.sort()

    "INSERT INTO \"#{schema}\".#{table} (#{Enum.join(cols, ", ")}) VALUES " <>
      "(#{Enum.map_join(cols, ", ", &lit(row[&1]))})"
  end

  # A fixed 64-hex string per number: no digest is computed by this slice.
  defp hex(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp attempt(fun) do
    Repo.transaction(fun)
  rescue
    e in Postgrex.Error -> {:raised, e}
  end

  defp msg({:raised, %Postgrex.Error{postgres: %{message: m}}}), do: m

  defp entry_row(schema, id, ledger, seq, opts) do
    reverses = Keyword.get(opts, :reverses)

    insert_sql(schema, "ledger_entry", %{
      id: id,
      ledger_id: ledger,
      posting_seq: seq,
      cause: if(reverses, do: "reversal", else: "receipt"),
      sign_rule: Keyword.get(opts, :sign_rule, if(reverses, do: "reversal", else: "any")),
      reverses_entry_id: reverses,
      actor_id: "22222222-2222-2222-2222-222222222222",
      subject_id: "33333333-3333-3333-3333-333333333333",
      correlation_id: "corr-1",
      event_time: @t0,
      posting_time: @t0,
      client_op_id: "op-" <> id,
      origin_key: "origin-" <> id,
      payload_hash: hex(seq),
      entry_digest: hex(seq),
      chain_hash: hex(seq),
      registration_hash: hex(seq),
      leg_count: Keyword.get(opts, :leg_count, length(Keyword.fetch!(opts, :legs)))
    })
  end

  defp leg_row(schema, entry_id, ledger, seq, no, leg) do
    insert_sql(schema, "ledger_leg", %{
      id: Ecto.UUID.generate(),
      entry_id: entry_id,
      ledger_id: ledger,
      posting_seq: seq,
      event_time: @t0,
      leg_no: no,
      k1: leg.k1,
      k2: Map.get(leg, :k2, ""),
      quantity: {:raw, to_string(leg.q)},
      unit_ref: "pcs",
      quantity_scale: 0
    })
  end

  # One poster, one transaction: counter row, bump, entry, legs, balance. Raises on any refusal.
  defp post(schema, ledger, seq, opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    legs = Keyword.fetch!(opts, :legs)

    {:ok, _} =
      Repo.transaction(fn -> post_in_tx(schema, ledger, seq, id, legs, opts) end)

    id
  end

  defp post_in_tx(schema, ledger, seq, id, legs, opts) do
    q = fn sql -> Repo.query!(sql) end

    q.(
      insert_sql(schema, "ledger_counter", %{ledger_id: ledger, last_seq: 0, last_chain_hash: ""}) <>
        " ON CONFLICT DO NOTHING"
    )

    q.("SELECT 1 FROM \"#{schema}\".ledger_counter WHERE ledger_id = #{lit(ledger)} FOR UPDATE")

    q.(
      "UPDATE \"#{schema}\".ledger_counter SET last_seq = #{seq}, " <>
        "last_chain_hash = #{lit(Keyword.get(opts, :counter_hash, hex(seq)))} WHERE ledger_id = #{lit(ledger)}"
    )

    q.(entry_row(schema, id, ledger, seq, opts ++ [legs: legs]))

    legs
    |> Enum.with_index(1)
    |> Enum.each(fn {leg, no} -> q.(leg_row(schema, id, ledger, seq, no, leg)) end)

    case Keyword.get(opts, :balance) do
      {k1, on_hand} ->
        q.(
          insert_sql(schema, "ledger_balance", %{
            ledger_id: ledger,
            k1: k1,
            on_hand: 0,
            unit_ref: "pcs",
            last_posting_seq: 0
          }) <> " ON CONFLICT DO NOTHING"
        )

        q.(
          "UPDATE \"#{schema}\".ledger_balance SET on_hand = #{on_hand}, last_posting_seq = #{seq} " <>
            "WHERE ledger_id = #{lit(ledger)} AND k1 = #{lit(k1)}"
        )

      nil ->
        :ok
    end
  end

  defp refused(sql, text, schema, table) do
    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :restrict_violation,
                message: ^text,
                schema: ^schema,
                table: ^table
              }
            }} = Repo.query(sql)
  end

  defp snapshot(schema, table) do
    %{rows: [[n, h]]} =
      Repo.query!(
        "SELECT count(*), coalesce(md5(string_agg(t::text, '|' ORDER BY t::text)), '') FROM \"#{schema}\".#{table} t"
      )

    {n, h}
  end

  defp rev_ledger(n), do: "l" <> Integer.to_string(n)

  # -- B-1 .. B-6: criterion 5 -----------------------------------------------------------------------

  test "B-1 entry and leg refuse UPDATE, DELETE and TRUNCATE with the one fixed text", %{
    schema: s
  } do
    before = {snapshot(s, "ledger_entry"), snapshot(s, "ledger_leg")}

    for {table, set} <- [{"ledger_entry", "cause = 'x'"}, {"ledger_leg", "unit_ref = 'kg'"}] do
      refused("UPDATE \"#{s}\".#{table} SET #{set}", @append_only, s, table)
      refused("DELETE FROM \"#{s}\".#{table}", @append_only, s, table)
    end

    # a plain TRUNCATE of the entry is stopped by the FK from ledger_leg before any trigger runs
    refused("TRUNCATE \"#{s}\".ledger_entry CASCADE", @append_only, s, "ledger_entry")
    refused("TRUNCATE \"#{s}\".ledger_leg", @append_only, s, "ledger_leg")
    refute @append_only =~ s
    assert before == {snapshot(s, "ledger_entry"), snapshot(s, "ledger_leg")}
  end

  test "B-2 counter: DELETE, TRUNCATE, INSERT and UPDATE rules", %{schema: s} do
    before = snapshot(s, "ledger_counter")
    refused("DELETE FROM \"#{s}\".ledger_counter", @append_only, s, "ledger_counter")
    refused("TRUNCATE \"#{s}\".ledger_counter", @append_only, s, "ledger_counter")

    upd = "ledger counter update rule violated"
    ins = "ledger counter insert rule violated"
    t = "ledger_counter"

    refused("UPDATE \"#{s}\".#{t} SET ledger_id = 'zz'", upd, s, t)
    refused("UPDATE \"#{s}\".#{t} SET last_seq = last_seq + 2", upd, s, t)
    refused("UPDATE \"#{s}\".#{t} SET last_seq = last_seq", upd, s, t)
    refused("UPDATE \"#{s}\".#{t} SET last_seq = last_seq - 1", upd, s, t)
    refused("UPDATE \"#{s}\".#{t} SET last_chain_hash = '#{hex(9)}'", upd, s, t)

    refused(insert_sql(s, t, %{ledger_id: "n1", last_seq: 1, last_chain_hash: ""}), ins, s, t)
    refused(insert_sql(s, t, %{ledger_id: "n1", last_seq: 0, last_chain_hash: hex(1)}), ins, s, t)
    assert before == snapshot(s, t)

    assert {:ok, _} =
             Repo.query(insert_sql(s, t, %{ledger_id: "n1", last_seq: 0, last_chain_hash: ""}))
  end

  test "B-3 balance: DELETE, TRUNCATE, INSERT and UPDATE rules", %{schema: s} do
    t = "ledger_balance"
    before = snapshot(s, t)
    refused("DELETE FROM \"#{s}\".#{t}", @append_only, s, t)
    refused("TRUNCATE \"#{s}\".#{t}", @append_only, s, t)

    ins = "ledger balance insert rule violated"
    upd = "ledger balance update rule violated"
    base = %{ledger_id: "wh", k1: "b", on_hand: 0, unit_ref: "pcs", last_posting_seq: 0}
    refused(insert_sql(s, t, %{base | on_hand: 3}), ins, s, t)
    refused(insert_sql(s, t, %{base | last_posting_seq: 1}), ins, s, t)

    for set <- ["k1 = 'q'", "unit_ref = 'kg'", "max_on_hand = 100", "ledger_id = 'wh2'"] do
      refused("UPDATE \"#{s}\".#{t} SET #{set}", upd, s, t)
    end

    refused("UPDATE \"#{s}\".#{t} SET on_hand = 9, last_posting_seq = 0", upd, s, t)
    refused("UPDATE \"#{s}\".#{t} SET on_hand = 9, last_posting_seq = 2", upd, s, t)
    assert before == snapshot(s, t)

    assert {:ok, _} = Repo.query("UPDATE \"#{s}\".#{t} SET on_hand = 9, last_posting_seq = 1")
  end

  test "B-4 the entry triggers also fire under session_replication_role = replica", %{schema: s} do
    for sql <- [
          "UPDATE \"#{s}\".ledger_entry SET cause = 'x'",
          "DELETE FROM \"#{s}\".ledger_entry",
          "TRUNCATE \"#{s}\".ledger_entry CASCADE"
        ] do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")
        refused(sql, @append_only, s, "ledger_entry")
        Repo.rollback(:done)
      end)
    end
  end

  test "B-5 catalog: 17 triggers, all ENABLE ALWAYS, right timing, constraint triggers deferred",
       %{
         schema: s
       } do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname, t.tgname, t.tgenabled, t.tgtype::int, t.tgdeferrable, t.tginitdeferred
          FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $1 AND NOT t.tgisinternal AND c.relname LIKE 'ledger\\_%'
         ORDER BY t.tgname
        """,
        [s]
      )

    assert Enum.map(rows, fn [rel, name | _] -> {rel, name} end) ==
             Enum.sort_by(CreateLedgerTriggers.trigger_specs(), &elem(&1, 1))

    assert length(rows) == 17
    assert Enum.all?(rows, fn [_, _, enabled | _] -> enabled == "A" end)

    by_name = Map.new(rows, fn [_, name, _, type, def, init] -> {name, {type, def, init}} end)
    {row, before, insert, delete, update, truncate} = {1, 2, 4, 8, 16, 32}

    [upd_t, del_t, ins_t, trunc_t] = [
      row ||| before ||| update,
      row ||| before ||| delete,
      row ||| before ||| insert,
      before ||| truncate
    ]

    for t <- ["ledger_entry", "ledger_leg"] do
      assert {upd_t, false, false} == by_name[t <> "_guard_update"]
      assert {del_t, false, false} == by_name[t <> "_guard_delete"]
      assert {trunc_t, false, false} == by_name[t <> "_guard_truncate"]
    end

    assert {ins_t, false, false} == by_name["ledger_entry_guard_insert"]
    assert {5, true, true} == by_name["ledger_entry_check_commit"]
    assert {17, true, true} == by_name["ledger_counter_check_commit"]
  end

  test "B-6 functions never name the schema, are not SECURITY DEFINER, pin no search_path", %{
    schema: s
  } do
    %{rows: rows} =
      Repo.query!(
        "SELECT p.proname, p.prosrc, p.prosecdef, p.proconfig FROM pg_proc p " <>
          "WHERE p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1) AND p.proname LIKE 'ledger\\_%'",
        [s]
      )

    assert rows |> Enum.map(&hd/1) |> Enum.sort() ==
             ~w(ledger_check_counter ledger_check_entry ledger_guard_balance ledger_guard_counter ledger_guard_entry_insert ledger_refuse)

    for [name, src, secdef, config] <- rows do
      refute src =~ s, name
      refute secdef, name
      assert config in [nil, []], name

      if src =~ ~r/%I\./, do: assert(src =~ "TG_TABLE_SCHEMA", name)
      assert src =~ "SCHEMA = TG_TABLE_SCHEMA, TABLE = TG_TABLE_NAME", name

      for [_, text] <- Regex.scan(~r/RAISE EXCEPTION '([^']*)'/, src) do
        refute text =~ "%", name
        refute text =~ "||", name
      end
    end
  end

  # -- B-7 .. B-17: criterion 6 ----------------------------------------------------------------------

  test "B-7 a made-up posting_seq is refused, with or without a counter row", %{schema: s} do
    t = "ledger_entry"
    text = "ledger entry posting sequence rule violated"

    assert {:ok, _} =
             Repo.query(
               insert_sql(s, "ledger_counter", %{
                 ledger_id: "m1",
                 last_seq: 0,
                 last_chain_hash: ""
               })
             )

    refused(entry_row(s, Ecto.UUID.generate(), "m1", 5, legs: [%{k1: "a", q: 1}]), text, s, t)
    refused(entry_row(s, Ecto.UUID.generate(), "m2", 1, legs: [%{k1: "a", q: 1}]), text, s, t)
  end

  test "B-8 a counter bump by 2 is refused", %{schema: s} do
    assert {:raised, _} =
             attempt(fn ->
               Repo.query!(
                 "UPDATE \"#{s}\".ledger_counter SET last_seq = 3, last_chain_hash = '#{hex(3)}'"
               )
             end)

    %{rows: [[1]]} = Repo.query!("SELECT last_seq FROM \"#{s}\".ledger_counter")
  end

  test "B-9 and B-17 a counter bump with no matching entry fails at COMMIT, or at the statement when immediate",
       %{schema: s} do
    text = "ledger counter has no matching entry"
    bump = "UPDATE \"#{s}\".ledger_counter SET last_seq = 2, last_chain_hash = '#{hex(2)}'"

    assert {:raised, %Postgrex.Error{}} = res = attempt(fn -> Repo.query!(bump) end)
    assert msg(res) == text
    %{rows: [[1]]} = Repo.query!("SELECT last_seq FROM \"#{s}\".ledger_counter")

    res =
      attempt(fn ->
        Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
        Repo.query!(bump)
      end)

    assert msg(res) == text
  end

  test "B-10 a counter chain hash that differs from the entry's chain_hash is refused at commit",
       %{
         schema: s
       } do
    res =
      attempt(fn ->
        post_in_tx(s, "wh", 2, Ecto.UUID.generate(), [%{k1: "a", q: 1}], counter_hash: hex(99))
      end)

    assert msg(res) == "ledger counter has no matching entry"
  end

  test "B-11 reversal rules", %{schema: s, e1: e1} do
    text = "ledger entry reversal rule violated"
    rev = post(s, "wh", 2, reverses: e1, legs: [%{k1: "a", q: -5}])

    post_ledger = fn l, seq, o ->
      post_in_tx(s, l, seq, Ecto.UUID.generate(), [%{k1: "a", q: -5}], o)
    end

    # a reversal of a reversal
    assert text == msg(attempt(fn -> post_ledger.("wh", 3, reverses: rev) end))

    # a second reversal of one entry: the partial unique index of part A
    assert {:raised, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: c}}} =
             attempt(fn -> post_ledger.("wh", 3, reverses: e1) end)

    assert c == "ledger_entry_reverses_unique_index"

    # a target in another ledger
    other = post(s, "other", 1, legs: [%{k1: "a", q: 5}])
    assert text == msg(attempt(fn -> post_ledger.("wh", 3, reverses: other) end))

    # a target that does not exist: the BEFORE INSERT trigger fires before the FK check
    assert text == msg(attempt(fn -> post_ledger.("wh", 3, reverses: Ecto.UUID.generate()) end))
  end

  test "B-12 sign rules are checked at commit", %{schema: s} do
    text = "ledger entry sign rule violated"

    run = fn n, rule, legs ->
      attempt(fn ->
        post_in_tx(s, rev_ledger(n), 1, Ecto.UUID.generate(), legs, sign_rule: rule)
      end)
    end

    assert msg(run.(1, "zero_sum_by_slot_1", [%{k1: "a", q: 5}, %{k1: "b", q: -3}])) == text
    assert msg(run.(2, "positive", [%{k1: "a", q: 5}, %{k1: "b", q: -3}])) == text
    assert msg(run.(3, "negative", [%{k1: "a", q: -5}, %{k1: "b", q: 3}])) == text

    assert {:ok, _} =
             run.(4, "zero_sum_by_slot_1", [
               %{k1: "a", q: 5},
               %{k1: "a", q: -5},
               %{k1: "b", q: 2},
               %{k1: "b", q: -2}
             ])

    assert {:ok, _} = run.(5, "any", [%{k1: "a", q: 5}, %{k1: "b", q: -3}])
    assert {:ok, _} = run.(6, "positive", [%{k1: "a", q: 5}])
    assert {:ok, _} = run.(7, "negative", [%{k1: "a", q: -5}])
  end

  test "B-13 a leg count that differs from leg_count is refused both ways", %{schema: s} do
    text = "ledger entry leg count rule violated"
    one = [%{k1: "a", q: 1}]
    two = [%{k1: "a", q: 1}, %{k1: "b", q: 1}]

    fewer = attempt(fn -> post_in_tx(s, "c1", 1, Ecto.UUID.generate(), one, leg_count: 2) end)
    more = attempt(fn -> post_in_tx(s, "c2", 1, Ecto.UUID.generate(), two, leg_count: 1) end)
    assert msg(fewer) == text
    assert msg(more) == text
  end

  test "B-14 a reversal must net the original to zero per key", %{schema: s} do
    original = post(s, "r1", 1, legs: [%{k1: "a", k2: "x", q: 5}, %{k1: "a", k2: "y", q: 3}])

    try_rev = fn legs ->
      attempt(fn -> post_in_tx(s, "r1", 2, Ecto.UUID.generate(), legs, reverses: original) end)
    end

    text = "ledger entry reversal sum rule violated"
    assert msg(try_rev.([%{k1: "a", k2: "x", q: -5}, %{k1: "a", k2: "z", q: -3}])) == text
    assert msg(try_rev.([%{k1: "a", k2: "x", q: -5}, %{k1: "a", k2: "y", q: -2}])) == text
    assert msg(try_rev.([%{k1: "a", k2: "x", q: -5}])) == text
    assert {:ok, _} = try_rev.([%{k1: "a", k2: "x", q: -5}, %{k1: "a", k2: "y", q: -3}])
  end

  test "B-15 correct sequence: posting_seq values are exactly 1, 2 and each ledger numbers from 1",
       %{schema: s} do
    post(s, "wh", 2, legs: [%{k1: "a", q: 1}])
    post(s, "second", 1, legs: [%{k1: "a", q: 1}])

    seqs = fn l ->
      %{rows: rows} =
        Repo.query!(
          "SELECT posting_seq FROM \"#{s}\".ledger_entry WHERE ledger_id = $1 ORDER BY 1",
          [l]
        )

      List.flatten(rows)
    end

    assert seqs.("wh") == [1, 2]
    assert seqs.("second") == [1]
  end

  test "B-16 first-poster race: a counter insert blocks on an uncommitted one, and ends with seq 1",
       %{
         schema: s
       } do
    parent = self()
    ledger = "race"

    first =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            insert_sql(s, "ledger_counter", %{ledger_id: ledger, last_seq: 0, last_chain_hash: ""})
          )

          send(parent, :inserted)

          receive do
            :rollback -> Repo.rollback(:first_gives_up)
          after
            20_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :inserted, 20_000

    second =
      Task.async(fn ->
        post(s, ledger, 1, legs: [%{k1: "a", q: 1}])
      end)

    assert wait_blocked(s, 200)
    send(first.pid, :rollback)

    assert {:error, :first_gives_up} = Task.await(first, 20_000)
    assert is_binary(Task.await(second, 20_000))

    assert %{rows: [[1]]} =
             Repo.query!("SELECT last_seq FROM \"#{s}\".ledger_counter WHERE ledger_id = $1", [
               ledger
             ])

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM \"#{s}\".ledger_entry WHERE ledger_id = $1 AND posting_seq = 1",
               [ledger]
             )
  end

  defp wait_blocked(_s, 0), do: false

  defp wait_blocked(s, n) do
    %{rows: [[c]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE $1",
        ["%" <> s <> "%ledger_counter%"]
      )

    if c > 0 do
      true
    else
      Process.sleep(50)
      wait_blocked(s, n - 1)
    end
  end

  # -- B-18, B-19 -------------------------------------------------------------------------------------

  test "B-18 migration source, down guard, registration and replay", %{schema: s, tenant_id: tid} do
    src = File.read!(@migration_path)

    names =
      ~r/#\{([a-z_]+)\}/
      |> Regex.scan(src)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()
      |> Enum.sort()

    assert names == ["name", "schema", "table"]

    for line <- String.split(src, "\n"), line =~ ~r/CREATE|ALTER TABLE/ do
      interps = ~r/#\{([a-z_]+)\}/ |> Regex.scan(line) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()
      assert interps in [[], ["schema"]], line
    end

    previous = Application.fetch_env(:letflow, :allow_ledger_migration_down)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:letflow, :allow_ledger_migration_down, v)
        :error -> Application.delete_env(:letflow, :allow_ledger_migration_down)
      end
    end)

    Application.put_env(:letflow, :allow_ledger_migration_down, false)
    assert_raise RuntimeError, ~r/tamper protection/, fn -> CreateLedgerTriggers.down() end
    Application.delete_env(:letflow, :allow_ledger_migration_down)
    assert_raise RuntimeError, ~r/tamper protection/, fn -> CreateLedgerTriggers.down() end

    assert {20_261_031_200_001, CreateLedgerTriggers} ==
             List.last(TenantProvisioning.tenant_scoped_migrations())

    count = fn ->
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace " <>
            "WHERE n.nspname = $1 AND NOT t.tgisinternal AND c.relname LIKE 'ledger\\_%'",
          [s]
        )

      n
    end

    assert count.() == 17
    assert {:ok, _} = TenantProvisioning.replay_migrations(tid)
    assert count.() == 17
  end

  test "B-19 a refusal reports its own tenant schema only; a counter row is invisible to another tenant",
       %{schema: a} do
    b = TenantFixture.provisioned_tenant!(slug_prefix: "r620b-two").schema_name
    refute a == b

    refused("TRUNCATE \"#{b}\".ledger_counter", @append_only, b, "ledger_counter")
    refused("DELETE FROM \"#{a}\".ledger_counter", @append_only, a, "ledger_counter")

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM \"#{a}\".ledger_counter")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM \"#{b}\".ledger_counter")

    # b's first posting is seq 1 although a's "wh" is already at 1: counters are per schema
    post(b, "wh", 1, legs: [%{k1: "a", q: 1}])
    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM \"#{b}\".ledger_counter")
  end
end
