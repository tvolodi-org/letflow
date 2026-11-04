defmodule Letflow.LedgerPartitionedTablesMigrationTest do
  @moduledoc """
  REQ-710 criteria 1 to 3 and 8 (decision 0073 A5, A6, A8): the migration that replaces the four
  ledger tables with the partitioned shape (b). PM-1 catalog, PM-2 refuse-if-rows, PM-3 source
  scan, PM-4 registration and replay, PM-5 function bodies, PM-6 partition triggers, PM-8 down,
  DOC-1 the decision text. The cross-ledger reversal (PM-7) is B-11 in
  `ledger_triggers_migration_test.exs`. `async: false` (tenant provisioning and DDL, real commits).
  """

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture
  alias Letflow.Repo.Migrations.CreateLedgerPartitionedTables
  alias Letflow.Repo.Migrations.CreateLedgerTriggers
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_104_200_001
  @migration_path "priv/repo/migrations/20261104200001_create_ledger_partitioned_tables.exs"
  @tables ~w(ledger_counter ledger_entry ledger_leg ledger_balance)
  @parents ~w(ledger_entry ledger_leg ledger_balance)
  @hash String.duplicate("a", 64)
  @t0 "2026-11-04T10:00:00Z"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r710-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp q!(sql, params \\ []), do: Repo.query!(sql, params)

  defp restore_down_flag_on_exit do
    previous = Application.fetch_env(:letflow, :allow_ledger_migration_down)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:letflow, :allow_ledger_migration_down, v)
        :error -> Application.delete_env(:letflow, :allow_ledger_migration_down)
      end
    end)
  end

  defp strip(text, schema), do: String.replace(text, schema <> ".", "")

  defp relkind(schema, table) do
    %{rows: [[kind]]} =
      q!(
        "SELECT c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = $1 AND c.relname = $2",
        [schema, table]
      )

    kind
  end

  defp count(schema, table),
    do: q!(~s|SELECT count(*) FROM "#{schema}".#{table}|).rows |> hd() |> hd()

  # name => definition of the constraints of the four tables (top-level ones, no partition clones)
  defp constraint_defs(schema) do
    %{rows: rows} =
      q!(
        "SELECT t.relname, c.conname, pg_get_constraintdef(c.oid) FROM pg_constraint c " <>
          "JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace " <>
          "WHERE n.nspname = $1 AND t.relname = ANY($2) AND c.conparentid = 0 " <>
          "AND c.contype IN ('p', 'u', 'f') ORDER BY 1, 2",
        [schema, @tables]
      )

    Map.new(rows, fn [table, name, def] -> {{table, name}, strip(def, schema)} end)
  end

  defp index_defs(schema) do
    %{rows: rows} =
      q!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = ANY($2) ORDER BY 1",
        [schema, @tables]
      )

    Map.new(rows, fn [name, def] -> {name, strip(def, schema)} end)
  end

  defp trigger_rows(schema, only_parents?) do
    extra = if only_parents?, do: " AND NOT c.relispartition", else: ""

    q!(
      "SELECT c.relname, t.tgname, t.tgenabled::text FROM pg_trigger t " <>
        "JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace " <>
        "WHERE n.nspname = $1 AND NOT t.tgisinternal AND c.relname LIKE 'ledger\\_%'" <>
        extra <> " ORDER BY 1, 2",
      [schema]
    ).rows
  end

  test "PM-1 parents are LIST partitioned on ledger_id with the A5 keys; the counter is plain",
       %{schema: schema} do
    for t <- @parents do
      assert relkind(schema, t) == "p", t

      assert [["LIST (ledger_id)"]] ==
               q!(
                 "SELECT pg_get_partkeydef(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
                   "WHERE n.nspname = $1 AND c.relname = $2",
                 [schema, t]
               ).rows
    end

    assert relkind(schema, "ledger_counter") == "r"

    defs = constraint_defs(schema)

    expected = %{
      {"ledger_entry", "ledger_entry_pkey"} => "PRIMARY KEY (id, ledger_id)",
      {"ledger_entry", "ledger_entry_ledger_seq_key"} => "UNIQUE (ledger_id, posting_seq)",
      {"ledger_entry", "ledger_entry_subject_op_key"} =>
        "UNIQUE (ledger_id, subject_id, client_op_id)",
      {"ledger_entry", "ledger_entry_origin_key_key"} => "UNIQUE (ledger_id, origin_key)",
      {"ledger_entry", "ledger_entry_leg_target_key"} =>
        "UNIQUE (id, ledger_id, posting_seq, event_time)",
      # REQ-711: the reversal key and the leg-to-entry key are declared on the partitions, not on the
      # parents (ledger_fk_move_migration_test.exs MG-1).
      {"ledger_leg", "ledger_leg_pkey"} => "PRIMARY KEY (id, ledger_id)",
      {"ledger_leg", "ledger_leg_entry_leg_no_key"} => "UNIQUE (ledger_id, entry_id, leg_no)",
      {"ledger_balance", "ledger_balance_pkey"} =>
        "PRIMARY KEY (ledger_id, k1, k2, k3, k4, k5, k6, k7, k8)",
      {"ledger_counter", "ledger_counter_pkey"} => "PRIMARY KEY (ledger_id)"
    }

    assert defs == expected

    idx = index_defs(schema)

    assert idx["ledger_entry_reverses_unique_index"] =~
             "(ledger_id, reverses_entry_id) WHERE (reverses_entry_id IS NOT NULL)"

    assert idx["ledger_entry_device_seq_unique_index"] =~
             "(ledger_id, subject_id, device_id, client_seq) WHERE (device_id IS NOT NULL)"

    for {name, cols} <- [
          {"ledger_entry_ledger_event_index", "(ledger_id, event_time, posting_seq)"},
          {"ledger_entry_document_index", "(document_type, document_id)"},
          {"ledger_entry_bpm_task_index", "(bpm_task_id)"},
          {"ledger_entry_correlation_index", "(correlation_id)"},
          {"ledger_leg_k1_k2_index", "(ledger_id, k1, k2, posting_seq) INCLUDE (quantity)"},
          {"ledger_leg_k2_k1_index", "(ledger_id, k2, k1, posting_seq)"},
          {"ledger_leg_k1_k2_event_index", "(ledger_id, k1, k2, event_time, posting_seq)"},
          {"ledger_balance_k2_k1_index", "(ledger_id, k2, k1)"}
        ] do
      assert idx[name] =~ cols, name
    end

    # no DEFAULT partition and, in a fresh tenant, no partition at all
    assert [[0]] =
             q!(
               "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
                 "WHERE n.nspname = $1 AND c.relispartition AND c.relname LIKE 'ledger\\_%'",
               [schema]
             ).rows
  end

  test "PM-2 it refuses to run when any ledger table has a row, and changes nothing" do
    migration = {@version, CreateLedgerPartitionedTables}

    for table <- @tables do
      schema = TenantFixture.provisioned_tenant!(slug_prefix: "r710-rows").schema_name
      LedgerFixture.ensure_storage!(schema, "rowtest")
      entry_id = Ecto.UUID.generate()

      # the rows are raw: the ledger triggers would refuse them, so they are off for the insert
      for t <- @tables, do: q!(~s|ALTER TABLE "#{schema}".#{t} DISABLE TRIGGER USER|)

      if table == "ledger_leg", do: q!(entry_sql(schema, entry_id))

      q!(
        case table do
          "ledger_counter" ->
            ~s|INSERT INTO "#{schema}".ledger_counter (ledger_id, last_seq, last_chain_hash) VALUES ('rowtest', 0, '')|

          "ledger_balance" ->
            ~s|INSERT INTO "#{schema}".ledger_balance (ledger_id, k1, on_hand, unit_ref, last_posting_seq) VALUES ('rowtest', 'a', 0, 'u1', 0)|

          "ledger_entry" ->
            entry_sql(schema, entry_id)

          "ledger_leg" ->
            leg_sql(schema, entry_id)
        end
      )

      q!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = $1|, [@version])

      error =
        assert_raise RuntimeError, fn ->
          Ecto.Migrator.run(Repo, [migration], :up, all: true, prefix: schema, log: false)
        end

      assert error.message =~ "ledger tables hold rows"
      refute error.message =~ "rowtest"
      refute error.message =~ schema

      for t <- @parents, do: assert(relkind(schema, t) == "p", "#{table} #{t}")
      assert relkind(schema, "ledger_counter") == "r"
      assert count(schema, table) == 1, table
    end
  end

  defp entry_sql(schema, id) do
    ~s|INSERT INTO "#{schema}".ledger_entry (id, ledger_id, posting_seq, cause, sign_rule, actor_id, subject_id, correlation_id, event_time, posting_time, client_op_id, origin_key, payload_hash, entry_digest, chain_hash, registration_hash, leg_count) VALUES ('#{id}', 'rowtest', 1, 'receipt', 'positive', '#{Ecto.UUID.generate()}', '#{Ecto.UUID.generate()}', 'c1', '#{@t0}', '#{@t0}', 'op-1', 'origin-1', '#{@hash}', '#{@hash}', '#{@hash}', '#{@hash}', 1)|
  end

  defp leg_sql(schema, entry_id) do
    ~s|INSERT INTO "#{schema}".ledger_leg (id, entry_id, ledger_id, posting_seq, event_time, leg_no, k1, quantity, unit_ref, quantity_scale) VALUES ('#{Ecto.UUID.generate()}', '#{entry_id}', 'rowtest', 1, '#{@t0}', 1, 'a', 1, 'u1', 0)|
  end

  test "PM-3 the only interpolated values are the quoted schema and a fixed table name" do
    src = File.read!(@migration_path)

    names =
      ~r/#\{([^}]*)\}/
      |> Regex.scan(src)
      |> Enum.map(fn [_, n] -> n end)
      |> Enum.uniq()
      |> Enum.sort()

    assert names == ["schema", "table"]
    assert src =~ "if prefix() do"
    refute src =~ "CASCADE"
    refute src =~ "DEFAULT PARTITION"
    refute src =~ ~r/PARTITION OF/
  end

  test "PM-4 registered last; a replay on an empty tenant restores the partitioned shape",
       %{schema: schema, tenant_id: tenant_id} do
    # REQ-711 registers MoveLedgerFksToPartitions after it
    assert {@version, CreateLedgerPartitionedTables} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -2)

    q!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = $1|, [@version])
    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)

    for t <- @parents, do: assert(relkind(schema, t) == "p")
    assert length(trigger_rows(schema, true)) == 17

    assert [[@version]] =
             q!(~s|SELECT version FROM "#{schema}".schema_migrations WHERE version = $1|, [
               @version
             ]).rows
  end

  test "TS-1 a tenant with partitions still passes the schema completeness check",
       %{schema: schema, tenant_id: tenant_id} do
    assert :ok = TenantFixture.assert_schema_complete!(tenant_id)
    LedgerFixture.ensure_storage!(schema, "ts1")
    assert :ok = TenantFixture.assert_schema_complete!(tenant_id)
  end

  test "PM-5 every leg and reversal lookup of the commit check filters by ledger id",
       %{schema: schema} do
    %{rows: [[check]]} =
      q!(
        "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " <>
          "WHERE n.nspname = $1 AND p.proname = 'ledger_check_entry'",
        [schema]
      )

    # leg count, positive, negative, zero-sum, and both sides of the reversal mirror
    assert length(Regex.scan(~r/ledger_leg WHERE entry_id = \$\d AND ledger_id = \$\d/, check)) ==
             6

    %{rows: [[guard]]} =
      q!(
        "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " <>
          "WHERE n.nspname = $1 AND p.proname = 'ledger_guard_entry_insert'",
        [schema]
      )

    assert guard =~ "WHERE id = $1 AND ledger_id = $2"

    %{rows: bodies} =
      q!(
        "SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " <>
          "WHERE n.nspname = $1 AND p.proname LIKE 'ledger\\_%'",
        [schema]
      )

    assert length(bodies) == 6
    for [body] <- bodies, do: refute(body =~ schema)
    assert CreateLedgerPartitionedTables.trigger_specs() == CreateLedgerTriggers.trigger_specs()
  end

  test "PM-6 a created partition carries the cloned row triggers and its own TRUNCATE guard, all ALWAYS",
       %{schema: schema} do
    parents = trigger_rows(schema, true)
    assert length(parents) == 17
    assert Enum.all?(parents, fn [_, _, enabled] -> enabled == "A" end)

    LedgerFixture.ensure_storage!(schema, "pm6")
    on_parents = Map.new(parents, fn [rel, name, _] -> {{rel, name}, true} end)

    %{rows: parts} =
      q!(
        "SELECT c.relname, p.relname FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid " <>
          "JOIN pg_class p ON p.oid = i.inhparent JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = $1 AND c.relispartition AND c.relkind = 'r' ORDER BY 2",
        [schema]
      )

    assert Enum.map(parts, &List.last/1) == Enum.sort(@parents)

    for [part, parent] <- parts do
      rows =
        for [rel, name, enabled] <- trigger_rows(schema, false), rel == part, do: {name, enabled}

      assert rows != []
      assert Enum.all?(rows, fn {_, enabled} -> enabled == "A" end), part

      # every trigger of the parent that is a row trigger (and the TRUNCATE guard) is on the partition
      expected =
        for {{rel, name}, _} <- on_parents,
            rel == parent,
            row_or_truncate?(schema, rel, name),
            do: name

      assert Enum.sort(expected) == Enum.sort(Enum.map(rows, &elem(&1, 0))), part
    end
  end

  defp row_or_truncate?(schema, table, name) do
    # tgtype bit 1 = ROW, 32 = TRUNCATE
    %{rows: [[type]]} =
      q!(
        "SELECT t.tgtype::int FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname = $2 AND t.tgname = $3",
        [schema, table, name]
      )

    Bitwise.band(type, 1) == 1 or Bitwise.band(type, 32) == 32
  end

  test "PM-8 down refuses without the flag and with a row; allowed it restores the plain shape, and up again",
       %{schema: schema} do
    restore_down_flag_on_exit()

    Application.put_env(:letflow, :allow_ledger_migration_down, false)

    assert_raise RuntimeError, ~r/CreateLedgerPartitionedTables.down refused/, fn ->
      CreateLedgerPartitionedTables.down()
    end

    Application.put_env(:letflow, :allow_ledger_migration_down, true)
    migration = {@version, CreateLedgerPartitionedTables}

    run = fn dir ->
      Ecto.Migrator.run(Repo, [migration], dir, all: true, prefix: schema, log: false)
    end

    # down with a row refuses
    LedgerFixture.ensure_storage!(schema, "pm8")

    q!(
      ~s|INSERT INTO "#{schema}".ledger_counter (ledger_id, last_seq, last_chain_hash) VALUES ('pm8', 0, '')|
    )

    error = assert_raise RuntimeError, fn -> run.(:down) end
    assert error.message =~ "ledger tables hold rows"
    refute error.message =~ "pm8"
    assert relkind(schema, "ledger_entry") == "p"

    # the trigger refuses a delete of the counter row, so the row goes with the tables of a fresh tenant
    fresh = TenantFixture.provisioned_tenant!(slug_prefix: "r710-down").schema_name

    run_fresh = fn dir ->
      Ecto.Migrator.run(Repo, [migration], dir, all: true, prefix: fresh, log: false)
    end

    assert [@version] = run_fresh.(:down)
    for t <- @tables, do: assert(relkind(fresh, t) == "r", t)

    defs = constraint_defs(fresh)
    assert defs[{"ledger_entry", "ledger_entry_pkey"}] == "PRIMARY KEY (id)"

    assert defs[{"ledger_entry", "ledger_entry_origin_key_key"}] ==
             "UNIQUE (ledger_id, origin_key)"

    assert defs[{"ledger_entry", "ledger_entry_reverses_entry_id_fkey"}] ==
             "FOREIGN KEY (reverses_entry_id) REFERENCES ledger_entry(id)"

    assert length(trigger_rows(fresh, true)) == 17
    assert Enum.all?(trigger_rows(fresh, true), fn [_, _, enabled] -> enabled == "A" end)

    %{rows: [[old_check]]} =
      q!(
        "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " <>
          "WHERE n.nspname = $1 AND p.proname = 'ledger_check_entry'",
        [fresh]
      )

    refute old_check =~ "AND ledger_id ="

    assert [@version] = run_fresh.(:up)
    for t <- @parents, do: assert(relkind(fresh, t) == "p", t)
    assert length(trigger_rows(fresh, true)) == 17
  end

  test "DOC-1 decision 0073 records the picked shape and the marked assumptions; no caller of ensure/2 outside tests, the storage module and the module installer (REQ-711)" do
    text = File.read!("docs/migration/decisions/0073-domain-neutral-ledger-primitive.md")
    assert text =~ "### Speed test result (REQ-710)"
    assert text =~ "assumption, owner may change at GATE B"
    assert text =~ "not built"

    callers =
      for file <- Path.wildcard("lib/**/*.ex"),
          file not in ["lib/letflow/ledger/storage.ex", "lib/letflow/modules/installs.ex"],
          File.read!(file) =~ ~r/Storage\.ensure\(/,
          do: file

    assert callers == []
  end
end
