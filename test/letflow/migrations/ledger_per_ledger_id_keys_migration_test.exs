defmodule Letflow.LedgerPerLedgerIdKeysMigrationTest do
  @moduledoc """
  REQ-692 / GH #3726 criterion 1: KEY-1..KEY-6. The tenant migration that gives the four
  `ledger_entry` keys `ledger_id` as their first column. `async: false` (tenant provisioning and
  DDL). Raw rows on purpose, with the ledger triggers off per table, as in
  `ledger_tables_migration_test.exs`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo.Migrations.CreateLedgerPerLedgerIdKeys
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_104_100_001
  @migration_path "priv/repo/migrations/20261104100001_create_ledger_per_ledger_id_keys.exs"
  @hash String.duplicate("a", 64)
  @t0 "2026-11-04T10:00:00Z"
  @subject "33333333-3333-3333-3333-333333333333"

  @new_defs %{
    "ledger_entry_subject_op_key" => "UNIQUE (ledger_id, subject_id, client_op_id)",
    "ledger_entry_origin_key_key" => "UNIQUE (ledger_id, origin_key)"
  }

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r692-mig")

    # REQ-710: the entry, leg and balance tables are partitioned by ledger id
    for id <- ~w(ledger_a ledger_b ledger_c),
        do: Letflow.LedgerFixture.ensure_storage!(tenant.schema_name, id)

    for t <- ~w(ledger_counter ledger_entry ledger_leg ledger_balance) do
      Repo.query!(~s(ALTER TABLE "#{tenant.schema_name}".#{t} DISABLE TRIGGER USER))
    end

    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp lit(nil), do: "NULL"
  defp lit(n) when is_integer(n), do: Integer.to_string(n)
  defp lit(s) when is_binary(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  defp row(over) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        ledger_id: "ledger_a",
        posting_seq: 1,
        cause: "receipt",
        sign_rule: "positive",
        actor_id: "22222222-2222-2222-2222-222222222222",
        subject_id: @subject,
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

  defp insert(schema, over) do
    r = row(over)
    cols = r |> Map.keys() |> Enum.sort()

    Repo.query(
      "INSERT INTO \"#{schema}\".ledger_entry (#{Enum.join(cols, ", ")}) VALUES " <>
        "(#{Enum.map_join(cols, ", ", &lit(r[&1]))})"
    )
  end

  defp ok!(result), do: assert({:ok, _} = result)

  # REQ-710: a violation raised inside a partition names the partition's renamed index
  # (`<parent name>_<16 hex>`).
  defp refused(result, constraint) do
    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: found}}} =
             result

    assert found =~ ~r/\A#{Regex.escape(constraint)}(_[0-9a-f]{16})?\z/
  end

  defp constraint_defs(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT c.conname, pg_get_constraintdef(c.oid) FROM pg_constraint c " <>
          "JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace " <>
          "WHERE n.nspname = $1 AND t.relname = 'ledger_entry' AND c.conparentid = 0 ORDER BY c.conname",
        [schema]
      )

    Map.new(rows, fn [name, def] -> {name, strip_schema(def, schema)} end)
  end

  defp strip_schema(text, schema), do: String.replace(text, schema <> ".", "")

  defp index_def(schema, name) do
    %{rows: [[def]]} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND indexname = $2", [
        schema,
        name
      ])

    strip_schema(def, schema)
  end

  test "KEY-1 the four definitions are the ones of the criterion", %{schema: schema} do
    defs = constraint_defs(schema)

    for {name, text} <- @new_defs, do: assert(defs[name] == text)

    assert index_def(schema, "ledger_entry_device_seq_unique_index") ==
             "CREATE UNIQUE INDEX ledger_entry_device_seq_unique_index ON ONLY ledger_entry " <>
               "USING btree (ledger_id, subject_id, device_id, client_seq) WHERE (device_id IS NOT NULL)"

    assert index_def(schema, "ledger_entry_reverses_unique_index") ==
             "CREATE UNIQUE INDEX ledger_entry_reverses_unique_index ON ONLY ledger_entry " <>
               "USING btree (ledger_id, reverses_entry_id) WHERE (reverses_entry_id IS NOT NULL)"
  end

  test "KEY-2 the same pair on two ledger ids is accepted", %{schema: schema} do
    ok!(insert(schema, %{}))

    # same subject and client_op_id
    ok!(insert(schema, %{ledger_id: "ledger_b", origin_key: "origin-2"}))
    # same origin_key
    ok!(insert(schema, %{ledger_id: "ledger_c", client_op_id: "op-3"}))

    # same (subject, device_id, client_seq)
    dev = %{device_id: "dev-1", client_seq: 7}

    ok!(
      insert(
        schema,
        Map.merge(%{posting_seq: 2, client_op_id: "op-4", origin_key: "origin-4"}, dev)
      )
    )

    ok!(
      insert(
        schema,
        Map.merge(
          %{ledger_id: "ledger_b", posting_seq: 2, client_op_id: "op-5", origin_key: "origin-5"},
          dev
        )
      )
    )
  end

  test "KEY-3 the same pair on ONE ledger id is refused with the old constraint name", %{
    schema: schema
  } do
    ok!(insert(schema, %{}))

    fresh = %{id: Ecto.UUID.generate(), posting_seq: 2}

    refused(
      insert(schema, Map.merge(fresh, %{origin_key: "origin-2"})),
      "ledger_entry_subject_op_key"
    )

    refused(
      insert(schema, Map.merge(fresh, %{client_op_id: "op-2"})),
      "ledger_entry_origin_key_key"
    )

    dev = %{device_id: "dev-1", client_seq: 7}

    ok!(
      insert(schema, Map.merge(%{posting_seq: 3, client_op_id: "op-3", origin_key: "o-3"}, dev))
    )

    refused(
      insert(
        schema,
        Map.merge(%{posting_seq: 4, client_op_id: "op-4", origin_key: "o-4"}, dev)
      ),
      "ledger_entry_device_seq_unique_index"
    )

    # a second reversal of one entry; the same entry id reversed on another ledger id is allowed
    first = Ecto.UUID.generate()
    ok!(insert(schema, %{id: first, posting_seq: 5, client_op_id: "op-5", origin_key: "o-5"}))
    rev = %{cause: "reversal", sign_rule: "reversal", reverses_entry_id: first}

    ok!(
      insert(schema, Map.merge(rev, %{posting_seq: 6, client_op_id: "op-6", origin_key: "o-6"}))
    )

    refused(
      insert(schema, Map.merge(rev, %{posting_seq: 7, client_op_id: "op-7", origin_key: "o-7"})),
      "ledger_entry_reverses_unique_index"
    )
  end

  test "KEY-4 primary key, other uniques, CHECKs and foreign keys are unchanged", %{
    schema: schema
  } do
    defs = constraint_defs(schema)

    assert defs["ledger_entry_pkey"] == "PRIMARY KEY (id, ledger_id)"
    assert defs["ledger_entry_ledger_seq_key"] == "UNIQUE (ledger_id, posting_seq)"

    assert defs["ledger_entry_reverses_entry_id_fkey"] ==
             "FOREIGN KEY (reverses_entry_id, ledger_id) REFERENCES ledger_entry(id, ledger_id)"

    # two of our keys, ledger_seq and one more unique, pkey, one FK, and the CHECK set (>= 15) are all present
    kinds = defs |> Map.values() |> Enum.map(&hd(String.split(&1, " ")))
    assert Enum.count(kinds, &(&1 == "UNIQUE")) == 4
    assert Enum.count(kinds, &(&1 == "PRIMARY")) == 1
    assert Enum.count(kinds, &(&1 == "FOREIGN")) == 1
    assert Enum.count(kinds, &(&1 == "CHECK")) >= 15
  end

  test "KEY-5 registered last; replay restores the keys of a tenant that lacks them", %{
    schema: schema,
    tenant_id: tenant_id
  } do
    # REQ-710 registers CreateLedgerPartitionedTables after this migration
    assert {@version, CreateLedgerPerLedgerIdKeys} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -2)

    old = ~s(ALTER TABLE "#{schema}".ledger_entry)
    Repo.query!("#{old} DROP CONSTRAINT ledger_entry_subject_op_key")
    Repo.query!("#{old} DROP CONSTRAINT ledger_entry_origin_key_key")
    Repo.query!(~s(DROP INDEX "#{schema}".ledger_entry_device_seq_unique_index))
    Repo.query!(~s(DROP INDEX "#{schema}".ledger_entry_reverses_unique_index))

    Repo.query!(~s(DELETE FROM "#{schema}".schema_migrations WHERE version = $1), [@version])

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)

    defs = constraint_defs(schema)
    for {name, text} <- @new_defs, do: assert(defs[name] == text)
    assert index_def(schema, "ledger_entry_device_seq_unique_index") =~ "(ledger_id, subject_id,"
    assert index_def(schema, "ledger_entry_reverses_unique_index") =~ "(ledger_id, reverses_"
  end

  test "KEY-6 down refuses unless allowed; allowed, it restores the old lists", %{schema: schema} do
    previous = Application.fetch_env(:letflow, :allow_ledger_migration_down)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:letflow, :allow_ledger_migration_down, v)
        :error -> Application.delete_env(:letflow, :allow_ledger_migration_down)
      end
    end)

    Application.put_env(:letflow, :allow_ledger_migration_down, false)

    assert_raise RuntimeError, ~r/CreateLedgerPerLedgerIdKeys.down refused/, fn ->
      CreateLedgerPerLedgerIdKeys.down()
    end

    assert constraint_defs(schema)["ledger_entry_origin_key_key"] ==
             "UNIQUE (ledger_id, origin_key)"

    Application.put_env(:letflow, :allow_ledger_migration_down, true)

    run = fn dir ->
      Ecto.Migrator.run(Repo, [{@version, CreateLedgerPerLedgerIdKeys}], dir,
        all: true,
        prefix: schema,
        log: false
      )
    end

    # REQ-710: the partitioned shape refuses key lists without ledger_id, so the replacing
    # migration goes down first (it restores the earlier plain tables with this migration's keys)
    replacing = {20_261_104_200_001, Letflow.Repo.Migrations.CreateLedgerPartitionedTables}

    assert [20_261_104_200_001] =
             Ecto.Migrator.run(Repo, [replacing], :down, all: true, prefix: schema, log: false)

    assert [@version] = run.(:down)
    defs = constraint_defs(schema)
    assert defs["ledger_entry_subject_op_key"] == "UNIQUE (subject_id, client_op_id)"
    assert defs["ledger_entry_origin_key_key"] == "UNIQUE (origin_key)"
    assert index_def(schema, "ledger_entry_device_seq_unique_index") =~ "(subject_id, device_id,"
    assert index_def(schema, "ledger_entry_reverses_unique_index") =~ "(reverses_entry_id)"

    assert [@version] = run.(:up)

    assert constraint_defs(schema)["ledger_entry_origin_key_key"] ==
             "UNIQUE (ledger_id, origin_key)"

    assert [20_261_104_200_001] =
             Ecto.Migrator.run(Repo, [replacing], :up, all: true, prefix: schema, log: false)
  end

  test "KEY-7 the only interpolation is the quoted schema and no value is interpolated" do
    src = File.read!(@migration_path)

    interpolations =
      ~r/#\{([^}]*)\}/ |> Regex.scan(src) |> Enum.map(fn [_, inner] -> inner end) |> Enum.uniq()

    assert Enum.sort(interpolations) == [
             "cols.device_seq",
             "cols.origin",
             "cols.reverses",
             "cols.subject_op",
             "schema",
             "t"
           ]

    assert src =~ "if prefix() do"
  end
end
