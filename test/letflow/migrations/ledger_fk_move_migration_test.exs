defmodule Letflow.LedgerFkMoveMigrationTest do
  @moduledoc """
  REQ-711 / GH #3751: `MoveLedgerFksToPartitions` moves the reversal key and the leg-to-entry key
  from the partitioned parents to the partitions (MG-1..MG-3), and the database still refuses a leg
  or a reversal across ledger ids (ST-9, decision 0073 A5). Fresh tenants only, `async: false`.
  Raw SQL with the user triggers off, as `ledger_tables_migration_test.exs` does.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger.Storage
  alias Letflow.LedgerFixture
  alias Letflow.Repo.Migrations.MoveLedgerFksToPartitions
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_104_300_001
  @hash String.duplicate("a", 64)
  @t0 "2026-10-31T10:00:00Z"
  @entry_a "11111111-1111-1111-1111-111111111111"

  setup do
    previous = Application.fetch_env(:letflow, :allow_ledger_migration_down)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:letflow, :allow_ledger_migration_down, v)
        :error -> Application.delete_env(:letflow, :allow_ledger_migration_down)
      end
    end)

    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r711-fk")
    %{schema: tenant.schema_name}
  end

  defp q!(sql, params \\ []), do: Repo.query!(sql, params)

  # {table, constraint name, parent constraint oid <> 0?, definition} of every foreign key of the ledger tables
  defp fks(schema) do
    q!(
      "SELECT t.relname, c.conname, c.conparentid <> 0, pg_get_constraintdef(c.oid) FROM pg_constraint c " <>
        "JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace " <>
        "WHERE n.nspname = $1 AND c.contype = 'f' AND t.relname LIKE 'ledger_%' ORDER BY 1, 2",
      [schema]
    ).rows
    |> Enum.map(fn [t, n, cloned, d] -> {t, n, cloned, String.replace(d, schema <> ".", "")} end)
  end

  defp run_migration(schema, direction) do
    Application.put_env(:letflow, :allow_ledger_migration_down, true)

    Ecto.Migrator.run(Repo, [{@version, MoveLedgerFksToPartitions}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  test "MG-1 a fresh tenant's parents carry no foreign key; ensure/2 puts one on each partition",
       %{schema: schema} do
    assert fks(schema) == []

    LedgerFixture.ensure_storage!(schema, "mg")
    names = Storage.partition_names("mg")
    h = String.replace_prefix(names["ledger_entry"], "ledger_entry_p", "")
    entry = names["ledger_entry"]
    leg = names["ledger_leg"]

    assert fks(schema) == [
             {entry, "ledger_entry_reverses_entry_id_fkey_" <> h, false,
              "FOREIGN KEY (reverses_entry_id, ledger_id) REFERENCES #{entry}(id, ledger_id)"},
             {leg, "ledger_leg_entry_fk_" <> h, false,
              "FOREIGN KEY (entry_id, ledger_id, posting_seq, event_time) REFERENCES " <>
                "#{entry}(id, ledger_id, posting_seq, event_time)"}
           ]
  end

  test "MG-2 up moves the keys of existing partitions, replay is a no-op, down restores the parents",
       %{schema: schema} do
    LedgerFixture.ensure_storage!(schema, "mg")
    LedgerFixture.ensure_storage!(schema, "mg2")
    moved = fks(schema)
    assert length(moved) == 4

    # old shape: parent keys, cloned onto the partitions
    assert [@version] = run_migration(schema, :down)
    old = fks(schema)
    assert {"ledger_entry", "ledger_entry_reverses_entry_id_fkey", false, _} = hd(old)
    assert Enum.any?(old, &match?({"ledger_leg", "ledger_leg_entry_fk", false, _}, &1))
    assert Enum.any?(old, fn {_, _, cloned, _} -> cloned end)

    assert [@version] = run_migration(schema, :up)
    assert fks(schema) == moved

    # replay: the version row removed, up runs again and changes nothing
    q!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = $1|, [@version])
    assert [@version] = run_migration(schema, :up)
    assert fks(schema) == moved
  end

  test "MG-2b down refuses unless the dev flag is set", %{schema: schema} do
    Application.put_env(:letflow, :allow_ledger_migration_down, false)

    assert_raise RuntimeError, ~r/MoveLedgerFksToPartitions.down refused/, fn ->
      Ecto.Migrator.run(Repo, [{@version, MoveLedgerFksToPartitions}], :down,
        all: true,
        prefix: schema,
        log: false
      )
    end
  end

  test "MG-3 registered last in the tenant manifest" do
    assert {@version, MoveLedgerFksToPartitions} =
             List.last(TenantProvisioning.tenant_scoped_migrations())
  end

  # -- ST-9: the keys still hold across ledger ids ---------------------------------------------------

  defp lit(nil), do: "NULL"
  defp lit({:raw, sql}), do: sql
  defp lit(n) when is_integer(n), do: Integer.to_string(n)
  defp lit(s) when is_binary(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  defp insert(schema, table, row) do
    cols = row |> Map.keys() |> Enum.sort()

    Repo.query(
      "INSERT INTO \"#{schema}\".#{table} (#{Enum.join(cols, ", ")}) VALUES " <>
        "(#{Enum.map_join(cols, ", ", &lit(row[&1]))})"
    )
  end

  defp entry(over) do
    Map.merge(
      %{
        id: @entry_a,
        ledger_id: "wh",
        posting_seq: 1,
        cause: "receipt",
        sign_rule: "positive",
        actor_id: "22222222-2222-2222-2222-222222222222",
        subject_id: "33333333-3333-3333-3333-333333333333",
        correlation_id: "corr-1",
        event_time: @t0,
        posting_time: @t0,
        client_op_id: "op-1",
        origin_key: "origin-1",
        payload_hash: @hash,
        entry_digest: @hash,
        chain_hash: @hash,
        registration_hash: @hash,
        leg_count: 1
      },
      over
    )
  end

  defp leg(over) do
    Map.merge(
      %{
        id: "44444444-4444-4444-4444-444444444444",
        entry_id: @entry_a,
        ledger_id: "wh",
        posting_seq: 1,
        event_time: @t0,
        leg_no: 1,
        k1: "item-1",
        quantity: {:raw, "5.000000000"},
        unit_ref: "pcs",
        quantity_scale: 3
      },
      over
    )
  end

  defp refused_fk(result, table) do
    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation, constraint: name}}} =
             result

    assert name =~ ~r/\A#{table}_[a-z_]*fk(ey)?_[0-9a-f]{16}\z/
  end

  test "ST-9 a leg or a reversal across ledger ids, and a delete of a referenced entry, are refused",
       %{schema: schema} do
    for id <- ~w(wh w2), do: LedgerFixture.ensure_storage!(schema, id)

    for t <- ~w(ledger_counter ledger_entry ledger_leg ledger_balance) do
      q!(~s|ALTER TABLE "#{schema}".#{t} DISABLE TRIGGER USER|)
    end

    assert {:ok, _} = insert(schema, "ledger_entry", entry(%{}))

    # a leg of ledger w2 pointing at an entry of ledger wh
    refused_fk(insert(schema, "ledger_leg", leg(%{ledger_id: "w2"})), "ledger_leg")

    # a same-ledger leg is accepted
    assert {:ok, _} = insert(schema, "ledger_leg", leg(%{}))

    # a reversal in ledger w2 of an entry in ledger wh
    reversal =
      entry(%{
        id: "55555555-5555-5555-5555-555555555555",
        ledger_id: "w2",
        cause: "reversal",
        sign_rule: "reversal",
        reverses_entry_id: @entry_a,
        client_op_id: "op-2",
        origin_key: "origin-2"
      })

    refused_fk(insert(schema, "ledger_entry", reversal), "ledger_entry")

    # a same-ledger reversal is accepted
    assert {:ok, _} =
             insert(
               schema,
               "ledger_entry",
               %{reversal | ledger_id: "wh"} |> Map.merge(%{posting_seq: 2})
             )

    # deleting an entry that a leg references is refused
    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               ~s|DELETE FROM "#{schema}".ledger_entry WHERE id = '#{@entry_a}' AND ledger_id = 'wh'|
             )
  end
end
