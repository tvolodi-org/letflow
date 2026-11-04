defmodule Letflow.LedgerReplayTest do
  @moduledoc """
  REQ-620 / GH #3463 part C, criteria 7, 8 and 12: replay of the two ledger migrations into a tenant
  at the previous version, the table-set oracle, the down guard, two-tenant isolation and the scans
  that show no `lib/` module and no runtime interpolation touches the ledger tables. `async: false`
  (tenant provisioning, DDL, real commits). Raw SQL on purpose: no `Letflow.Ledger` module exists.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo.Migrations.CreateLedgerTables
  alias Letflow.Repo.Migrations.CreateLedgerTriggers
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  # REQ-692, REQ-710 and REQ-711 later versions of the ledger tables are part of "the previous version" too
  @versions [
    20_261_031_100_001,
    20_261_031_200_001,
    20_261_104_100_001,
    20_261_104_200_001,
    20_261_104_300_001
  ]
  @ledger_tables ~w(ledger_balance ledger_counter ledger_entry ledger_leg)
  @t0 "2026-10-31T10:00:00Z"
  @append_only "ledger data is append-only: this statement is refused"
  @migration_paths [
    "priv/repo/migrations/20261031100001_create_ledger_tables.exs",
    "priv/repo/migrations/20261031200001_create_ledger_triggers.exs"
  ]

  # -- helpers ---------------------------------------------------------------------------------------

  defp q!(sql, params \\ []), do: Repo.query!(sql, params)

  defp count(schema, table),
    do: q!(~s|SELECT count(*) FROM "#{schema}"."#{table}"|).rows |> hd() |> hd()

  defp hex(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp lit(nil), do: "NULL"
  defp lit({:raw, sql}), do: sql
  defp lit(n) when is_integer(n), do: Integer.to_string(n)
  defp lit(s) when is_binary(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  defp insert_sql(schema, table, row) do
    cols = row |> Map.keys() |> Enum.sort()

    ~s|INSERT INTO "#{schema}".#{table} (#{Enum.join(cols, ", ")}) VALUES | <>
      "(#{Enum.map_join(cols, ", ", &lit(row[&1]))})"
  end

  # One committed posting, seq 1 of ledger "wh": one leg (k1 "a", +5), balance on_hand 5.
  defp post_one(schema) do
    id = Ecto.UUID.generate()
    Letflow.LedgerFixture.ensure_storage!(schema, "wh")

    {:ok, _} =
      Repo.transaction(fn ->
        q!(
          insert_sql(schema, "ledger_counter", %{
            ledger_id: "wh",
            last_seq: 0,
            last_chain_hash: ""
          })
        )

        q!(~s|SELECT 1 FROM "#{schema}".ledger_counter WHERE ledger_id = 'wh' FOR UPDATE|)

        q!(
          ~s|UPDATE "#{schema}".ledger_counter SET last_seq = 1, last_chain_hash = #{lit(hex(1))} | <>
            "WHERE ledger_id = 'wh'"
        )

        q!(
          insert_sql(schema, "ledger_entry", %{
            id: id,
            ledger_id: "wh",
            posting_seq: 1,
            cause: "receipt",
            sign_rule: "any",
            actor_id: "22222222-2222-2222-2222-222222222222",
            subject_id: "33333333-3333-3333-3333-333333333333",
            correlation_id: "corr-1",
            event_time: @t0,
            posting_time: @t0,
            client_op_id: "op-1",
            origin_key: "origin-" <> id,
            payload_hash: hex(1),
            entry_digest: hex(1),
            chain_hash: hex(1),
            registration_hash: hex(1),
            leg_count: 1
          })
        )

        q!(
          insert_sql(schema, "ledger_leg", %{
            id: Ecto.UUID.generate(),
            entry_id: id,
            ledger_id: "wh",
            posting_seq: 1,
            event_time: @t0,
            leg_no: 1,
            k1: "a",
            quantity: {:raw, "5"},
            unit_ref: "pcs",
            quantity_scale: 0
          })
        )

        q!(
          insert_sql(schema, "ledger_balance", %{
            ledger_id: "wh",
            k1: "a",
            on_hand: 0,
            unit_ref: "pcs",
            last_posting_seq: 0
          })
        )

        q!(
          ~s|UPDATE "#{schema}".ledger_balance SET on_hand = 5, last_posting_seq = 1 | <>
            "WHERE ledger_id = 'wh' AND k1 = 'a'"
        )
      end)

    id
  end

  defp physical_tables(schema) do
    q!(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE'",
      [schema]
    ).rows
    |> List.flatten()
  end

  # Row count and a checksum of the text form of every row, for each pre-existing table.
  defp snapshot_others(schema) do
    for table <- Enum.sort(physical_tables(schema)),
        table not in @ledger_tables,
        table != "schema_migrations",
        into: %{} do
      %{rows: [[n, h]]} =
        q!(
          "SELECT count(*), coalesce(md5(string_agg(t::text, ',' ORDER BY t::text)), '') " <>
            ~s|FROM "#{schema}"."#{table}" t|
        )

      {table, {n, h}}
    end
  end

  defp assert_unchanged(before, after_) do
    changed = for {t, v} <- before, Map.get(after_, t) != v, do: {t, v, Map.get(after_, t)}
    assert changed == []
  end

  # The tenant at the previous version: the four tables, the ledger functions and the two
  # schema_migrations rows are gone (what a tenant looks like before this release is deployed).
  defp downgrade_to_previous!(schema) do
    for t <- @ledger_tables, do: q!(~s|DROP TABLE IF EXISTS "#{schema}"."#{t}" CASCADE|)

    %{rows: fns} =
      q!(
        "SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " <>
          "WHERE n.nspname = $1 AND p.proname LIKE 'ledger\\_%'",
        [schema]
      )

    for [f] <- fns, do: q!("DROP FUNCTION " <> f <> " CASCADE")
    q!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = ANY($1)|, [@versions])
  end

  defp restore_env_on_exit do
    previous = Application.fetch_env(:letflow, :allow_ledger_migration_down)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:letflow, :allow_ledger_migration_down, v)
        :error -> Application.delete_env(:letflow, :allow_ledger_migration_down)
      end
    end)
  end

  # -- criteria 7 and 8 ------------------------------------------------------------------------------

  test "T-C7a/T-C7b/T-C8 replay into a tenant at the previous version" do
    %{tenant_id: tid, schema_name: s} =
      TenantFixture.provisioned_tenant!(slug_prefix: "r620c-rep")

    # A clone-provisioned tenant has not had replay's own event-type seeding yet (3 rows, unrelated
    # to the ledger); one warm-up replay settles that so the later comparison sees ledger effects only.
    assert {:ok, []} = TenantProvisioning.replay_migrations(tid)

    downgrade_to_previous!(s)
    refute Enum.any?(@ledger_tables, &(&1 in physical_tables(s)))

    before = snapshot_others(s)
    assert Enum.any?(before, fn {_, {n, _}} -> n > 0 end)

    assert {:ok, applied} = TenantProvisioning.replay_migrations(tid)
    assert applied == @versions

    for t <- @ledger_tables, do: assert(count(s, t) == 0, t)
    assert_unchanged(before, snapshot_others(s))

    # T-C8: the replayed tenant's table set is the oracle's
    present = physical_tables(s)
    expected = TenantFixture.expected_tenant_tables()
    assert Enum.sort(expected -- present) == []
    assert Enum.all?(@ledger_tables, &(&1 in expected and &1 in present))

    triggers = fn ->
      q!(
        "SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n " <>
          "ON n.oid = c.relnamespace WHERE n.nspname = $1 AND NOT t.tgisinternal AND c.relname LIKE 'ledger\\_%'",
        [s]
      ).rows
      |> hd()
      |> hd()
    end

    assert triggers.() == 17

    # a second replay_all_pending/0 returns the same ok list for this tenant and creates nothing.
    # Sibling tenants of the shared cluster may sit in the list too, so only this tenant is compared.
    first = TenantProvisioning.replay_all_pending()
    second = TenantProvisioning.replay_all_pending()
    assert tid in first.ok and tid in second.ok
    refute Enum.any?(first.error ++ second.error, fn {id, _} -> id == tid end)
    for t <- @ledger_tables, do: assert(count(s, t) == 0, t)
    assert triggers.() == 17
    assert_unchanged(before, snapshot_others(s))
  end

  test "T-C7d the down functions refuse unless the flag is exactly true" do
    restore_env_on_exit()

    for value <- [:unset, false, "true", 1] do
      if value == :unset,
        do: Application.delete_env(:letflow, :allow_ledger_migration_down),
        else: Application.put_env(:letflow, :allow_ledger_migration_down, value)

      assert_raise RuntimeError, fn -> CreateLedgerTables.down() end
      assert_raise RuntimeError, fn -> CreateLedgerTriggers.down() end
    end

    # the prod and runtime configs never set the flag
    for f <- ["config/runtime.exs", "config/prod.exs"] do
      refute File.read!(f) =~ "allow_ledger_migration_down", f
    end
  end

  # -- criterion 12 ----------------------------------------------------------------------------------

  test "T-SEC-1 two tenants: the tables exist in both, a row is invisible to the other, errors name one schema" do
    a = TenantFixture.provisioned_tenant!(slug_prefix: "r620c-sa").schema_name
    b = TenantFixture.provisioned_tenant!(slug_prefix: "r620c-sb").schema_name
    refute a == b

    for s <- [a, b], t <- @ledger_tables, do: assert(t in physical_tables(s))

    entry_id = post_one(a)

    for t <- @ledger_tables do
      assert count(a, t) == 1, t
      assert count(b, t) == 0, t
    end

    assert %{rows: [[0]]} =
             q!(~s|SELECT count(*) FROM "#{b}".ledger_entry WHERE id = $1|, [
               Ecto.UUID.dump!(entry_id)
             ])

    for {sql, schema, other, table} <- [
          {~s|UPDATE "#{a}".ledger_entry SET cause = 'x'|, a, b, "ledger_entry"},
          {~s|DELETE FROM "#{a}".ledger_leg|, a, b, "ledger_leg"},
          {~s|TRUNCATE "#{b}".ledger_balance|, b, a, "ledger_balance"}
        ] do
      # REQ-710: a row trigger cloned onto a partition names the partition (`<table>_p<16 hex>`)
      assert {:error,
              %Postgrex.Error{
                postgres: %{message: @append_only, schema: ^schema, table: found}
              }} = Repo.query(sql)

      assert found =~ ~r/\A#{table}(_p[0-9a-f]{16})?\z/

      refute @append_only =~ other
    end

    for t <- @ledger_tables do
      assert count(a, t) == 1, t
      assert count(b, t) == 0, t
    end
  end

  test "T-SEC-2 the only interpolated values in both migrations are schema, table and name" do
    names =
      for path <- @migration_paths,
          [_, n] <- Regex.scan(~r/#\{([a-z_]+)\}/, File.read!(path)),
          uniq: true,
          do: n

    assert Enum.all?(names, &(&1 in ["schema", "table", "name"])), inspect(names)

    for path <- @migration_paths,
        line <- String.split(File.read!(path), "\n"),
        line =~ ~r/CREATE|ALTER TABLE|EXECUTE|FUNCTION/ do
      interps = ~r/#\{([a-z_]+)\}/ |> Regex.scan(line) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()
      assert interps -- ["schema", "table", "name"] == [], line
    end
  end

  test "T-SEC-3 no module under lib/ names a ledger table" do
    pattern = ~r/ledger_(entry|leg|counter|balance)/

    # REQ-621 criterion 10: the single writer (Letflow.Ledger and its directory) must name the
    # tables; every other file under lib/ stays scanned
    # REQ-711: the DDL of the partitions (ledger/storage/ddl.ex) names the two tables whose keys it adds
    writer =
      ["lib/letflow/ledger.ex" | Path.wildcard("lib/letflow/ledger/*.ex")] ++
        Path.wildcard("lib/letflow/ledger/storage/*.ex")

    hits =
      for file <- Path.wildcard("lib/**/*.ex") -- writer, File.read!(file) =~ pattern, do: file

    assert hits == [],
           "REQ-620 criterion 12: no lib module but lib/letflow/ledger.ex and lib/letflow/ledger/*.ex " <>
             "may name a ledger table, found in #{inspect(hits)}"
  end
end
