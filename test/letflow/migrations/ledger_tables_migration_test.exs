defmodule Letflow.LedgerTablesMigrationTest do
  @moduledoc """
  REQ-620 / GH #3463 part A (criteria 1-4): the tenant migration that creates `ledger_counter`,
  `ledger_entry`, `ledger_leg` and `ledger_balance` with their CHECK set. `async: false` (tenant
  provisioning and DDL). Raw SQL on purpose: no `Letflow.Ledger` module exists yet (parts B and C).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo.Migrations.CreateLedgerTables
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_031_100_001
  @migration_path "priv/repo/migrations/20261031100001_create_ledger_tables.exs"
  @hash String.duplicate("a", 64)
  @entry_id "11111111-1111-1111-1111-111111111111"
  @t0 "2026-10-31T10:00:00Z"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r620a-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
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

  defp run(sql), do: Repo.query(sql)

  defp ok!(sql), do: assert({:ok, _} = run(sql), sql)

  defp refused(sql, code, constraint) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code, constraint: ^constraint}}} = run(sql)
  end

  defp entry(over) do
    Map.merge(
      %{
        id: @entry_id,
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
        entry_id: @entry_id,
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

  defp put_entry(schema, over), do: ok!(insert_sql(schema, "ledger_entry", entry(over)))

  defp put_leg(schema, over), do: ok!(insert_sql(schema, "ledger_leg", leg(over)))

  defp leg_sql(schema, over), do: insert_sql(schema, "ledger_leg", leg(over))
  defp entry_sql(schema, over), do: insert_sql(schema, "ledger_entry", entry(over))

  defp columns(schema, table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, data_type, is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = $2 ORDER BY column_name",
        [schema, table]
      )

    Map.new(rows, fn [n, t, nullable] -> {n, {t, nullable == "YES"}} end)
  end

  defp count(schema, table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{schema}\".#{table}")
    n
  end

  defp index_names(schema) do
    %{rows: rows} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE schemaname = $1", [schema])

    MapSet.new(rows, fn [n] -> n end)
  end

  # -- criterion 1 -----------------------------------------------------------------------------------

  test "A-1 counter columns, primary key, no tenant_id, empty and still empty after replay", %{
    schema: schema,
    tenant_id: tenant_id
  } do
    assert columns(schema, "ledger_counter") == %{
             "ledger_id" => {"text", false},
             "last_seq" => {"bigint", false},
             "last_chain_hash" => {"text", false}
           }

    %{rows: pk} =
      Repo.query!(
        "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid " <>
          "AND a.attnum = ANY(i.indkey) WHERE i.indrelid = $1::text::regclass AND i.indisprimary",
        ["#{schema}.ledger_counter"]
      )

    assert pk == [["ledger_id"]]
    assert count(schema, "ledger_counter") == 0

    # a second replay is a no-op and creates no counter row
    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert count(schema, "ledger_counter") == 0

    for table <- ~w(ledger_counter ledger_entry ledger_leg ledger_balance) do
      refute Map.has_key?(columns(schema, table), "tenant_id")
    end
  end

  test "A-2 counter refusals and accepted shapes", %{schema: schema} do
    row = %{ledger_id: "wh", last_seq: 0, last_chain_hash: ""}
    ok!(insert_sql(schema, "ledger_counter", row))

    ok!(
      insert_sql(schema, "ledger_counter", %{row | ledger_id: "wh:abc-1", last_chain_hash: @hash})
    )

    refused(
      insert_sql(schema, "ledger_counter", %{row | ledger_id: "w2", last_seq: -1}),
      :check_violation,
      "ledger_counter_last_seq_check"
    )

    for bad <- ["abc", String.duplicate("a", 63), String.duplicate("A", 64)] do
      refused(
        insert_sql(schema, "ledger_counter", %{row | ledger_id: "w3", last_chain_hash: bad}),
        :check_violation,
        "ledger_counter_last_chain_hash_check"
      )
    end

    for bad <- ["A", "", String.duplicate("a", 33), "a:", String.duplicate("a:b", 22)] do
      refused(
        insert_sql(schema, "ledger_counter", %{row | ledger_id: bad}),
        :check_violation,
        "ledger_counter_ledger_id_check"
      )
    end

    # 65 bytes: 32 + ":" + 32 is 65 octets
    refused(
      insert_sql(schema, "ledger_counter", %{
        row
        | ledger_id: String.duplicate("a", 32) <> ":" <> String.duplicate("b", 32)
      }),
      :check_violation,
      "ledger_counter_ledger_id_check"
    )
  end

  # -- criterion 2 -----------------------------------------------------------------------------------

  test "A-3 entry columns and nullability", %{schema: schema} do
    text = {"text", false}
    ntext = {"text", true}
    uuid = {"uuid", false}
    nuuid = {"uuid", true}
    ts = {"timestamp with time zone", false}

    assert columns(schema, "ledger_entry") == %{
             "id" => uuid,
             "ledger_id" => text,
             "posting_seq" => {"bigint", false},
             "cause" => text,
             "sign_rule" => text,
             "reverses_entry_id" => nuuid,
             "reason_code" => ntext,
             "document_type" => ntext,
             "document_id" => ntext,
             "related_document_id" => ntext,
             "actor_id" => uuid,
             "subject_id" => uuid,
             "correlation_id" => text,
             "bpm_instance_id" => nuuid,
             "bpm_task_id" => nuuid,
             "bpm_definition_id" => nuuid,
             "bpm_node_id" => ntext,
             "bpm_definition_version" => ntext,
             "event_time" => ts,
             "posting_time" => ts,
             "client_op_id" => text,
             "origin_key" => text,
             "payload_hash" => text,
             "entry_digest" => text,
             "chain_hash" => text,
             "registration_hash" => text,
             "device_id" => ntext,
             "client_seq" => {"bigint", true},
             "client_event_time" => {"timestamp with time zone", true},
             "scope_ref" => ntext,
             "leg_count" => {"smallint", false}
           }
  end

  test "A-4 entry refusals", %{schema: schema} do
    put_entry(schema, %{})

    dup = fn over -> entry_sql(schema, Map.merge(%{id: Ecto.UUID.generate()}, over)) end

    # unique keys
    refused(
      dup.(%{client_op_id: "op-2", origin_key: "origin-2"}),
      :unique_violation,
      "ledger_entry_ledger_seq_key"
    )

    refused(
      dup.(%{posting_seq: 2, origin_key: "origin-2"}),
      :unique_violation,
      "ledger_entry_subject_op_key"
    )

    refused(
      dup.(%{posting_seq: 2, client_op_id: "op-2"}),
      :unique_violation,
      "ledger_entry_origin_key_key"
    )

    fresh = %{posting_seq: 2, client_op_id: "op-2", origin_key: "origin-2"}

    for {over, name} <- [
          {%{sign_rule: "weird"}, "sign_rule"},
          {%{cause: "reversal", sign_rule: "reversal"}, "reversal"},
          {%{reverses_entry_id: @entry_id}, "reversal"},
          {%{leg_count: 0}, "leg_count"},
          {%{leg_count: 201}, "leg_count"},
          {%{payload_hash: "xyz"}, "payload_hash"},
          {%{entry_digest: "xyz"}, "entry_digest"},
          {%{chain_hash: "xyz"}, "chain_hash"},
          {%{registration_hash: "xyz"}, "registration_hash"},
          {%{posting_seq: 0}, "posting_seq"},
          {%{client_seq: 1}, "device_seq"},
          {%{client_event_time: @t0}, "client_event_time"},
          {%{device_id: "a b", client_seq: 1}, "device_id"},
          {%{cause: ""}, "cause"}
        ] do
      refused(dup.(Map.merge(fresh, over)), :check_violation, "ledger_entry_#{name}_check")
    end

    # a second reversal of one entry, and a repeated device sequence
    rev = %{cause: "reversal", sign_rule: "reversal", reverses_entry_id: @entry_id}
    ok!(dup.(Map.merge(fresh, rev)))

    refused(
      dup.(
        %{rev | cause: "reversal"}
        |> Map.merge(%{posting_seq: 3, client_op_id: "op-3", origin_key: "origin-3"})
      ),
      :unique_violation,
      "ledger_entry_reverses_unique_index"
    )

    dev = %{device_id: "dev-1", client_seq: 7}
    ok!(dup.(Map.merge(%{posting_seq: 4, client_op_id: "op-4", origin_key: "origin-4"}, dev)))

    refused(
      dup.(Map.merge(%{posting_seq: 5, client_op_id: "op-5", origin_key: "origin-5"}, dev)),
      :unique_violation,
      "ledger_entry_device_seq_unique_index"
    )
  end

  test "A-5 entry accepted shapes", %{schema: schema} do
    put_entry(schema, %{})

    ok!(
      entry_sql(schema, %{
        id: Ecto.UUID.generate(),
        posting_seq: 2,
        cause: "reversal",
        sign_rule: "reversal",
        reverses_entry_id: @entry_id,
        client_op_id: "op-2",
        origin_key: "origin-2"
      })
    )

    for n <- 3..4 do
      ok!(
        entry_sql(schema, %{
          id: Ecto.UUID.generate(),
          posting_seq: n,
          client_op_id: "op-#{n}",
          origin_key: "origin-#{n}"
        })
      )
    end

    assert count(schema, "ledger_entry") == 4
  end

  test "A-6 the foreign key set and the named indexes", %{schema: schema} do
    %{rows: rows} =
      Repo.query!(
        "SELECT conrelid::regclass::text, pg_get_constraintdef(oid) FROM pg_constraint " <>
          "WHERE contype = 'f' AND connamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1) " <>
          "AND conrelid::regclass::text LIKE '%ledger_%' ORDER BY 1",
        [schema]
      )

    assert [[entry_tbl, entry_def], [leg_tbl, leg_def]] = rows
    assert entry_tbl =~ "ledger_entry"
    assert entry_def =~ "FOREIGN KEY (reverses_entry_id) REFERENCES"
    assert entry_def =~ "ledger_entry(id)"
    assert leg_tbl =~ "ledger_leg"
    assert leg_def =~ "FOREIGN KEY (entry_id, ledger_id, posting_seq, event_time) REFERENCES"
    assert leg_def =~ "ledger_entry(id, ledger_id, posting_seq, event_time)"

    names = index_names(schema)

    for n <- ~w(ledger_entry_reverses_unique_index ledger_entry_device_seq_unique_index
                ledger_entry_ledger_event_index ledger_entry_document_index
                ledger_entry_bpm_task_index ledger_entry_correlation_index
                ledger_leg_k1_k2_index ledger_leg_k2_k1_index ledger_leg_k1_k2_event_index
                ledger_balance_k2_k1_index ledger_leg_entry_leg_no_key) do
      assert n in names, n
    end

    %{rows: [[def_]]} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND indexname = 'ledger_leg_k1_k2_index'",
        [
          schema
        ]
      )

    assert def_ =~ "INCLUDE (quantity)"
  end

  # -- criterion 3 -----------------------------------------------------------------------------------

  test "A-7 leg refusals", %{schema: schema} do
    put_entry(schema, %{})
    put_leg(schema, %{})
    n = fn over -> leg_sql(schema, Map.merge(%{id: Ecto.UUID.generate(), leg_no: 2}, over)) end
    q = fn s -> {:raw, s} end

    conv = %{
      quantity_original: q.("2.000000000"),
      original_unit_ref: "box",
      original_scale: 0,
      conversion_factor: q.("2.5"),
      conversion_basis: "registered",
      rounding_mode: "half_up"
    }

    tol = %{reference_quantity: q.("5"), tolerance_abs: q.("1"), tolerance_state: "within"}

    for {over, name} <- [
          {%{quantity: q.("0")}, "quantity"},
          {%{k1: ""}, "k1_present"},
          {%{k2: String.duplicate("a", 129)}, "k2"},
          {%{quantity_original: q.("2")}, "conversion_group"},
          {%{reference_quantity: q.("5")}, "tolerance_group"},
          {Map.merge(conv, %{quantity_original: q.("-2")}), "original_sign"},
          {%{quantity_scale: 10}, "quantity_scale"},
          {Map.merge(conv, %{original_unit_ref: "pcs"}), "original_unit_differs"},
          {Map.merge(tol, %{reference_quantity: q.("9")}), "within_tolerance"},
          {Map.merge(tol, %{tolerance_state: "excepted", exception_ref: "ex-1"}),
           "excepted_tolerance"},
          {Map.merge(tol, %{reference_quantity: q.("9"), tolerance_state: "excepted"}),
           "exception_state"},
          {%{exception_ref: "ex-1"}, "exception_state"},
          {%{quantity: q.("5.1234"), quantity_scale: 3}, "quantity_round"},
          {Map.merge(conv, %{conversion_factor: q.("9")}), "conversion_tripwire"},
          {%{unit_ref: "PCS"}, "unit_ref"}
        ] do
      refused(n.(over), :check_violation, "ledger_leg_#{name}_check")
    end

    refused(n.(%{posting_seq: 2}), :foreign_key_violation, "ledger_leg_entry_fk")
    refused(n.(%{leg_no: 1}), :unique_violation, "ledger_leg_entry_leg_no_key")
  end

  test "A-8 leg accepted shapes and the attrs bound", %{schema: schema} do
    put_entry(schema, %{})
    q = fn s -> {:raw, s} end

    put_leg(schema, %{
      quantity_original: q.("2.000000000"),
      original_unit_ref: "box",
      original_scale: 0,
      conversion_factor: q.("2.5"),
      conversion_basis: "command",
      rounding_mode: "half_even",
      quantity: q.("5.000000000")
    })

    base = %{reference_quantity: q.("5"), tolerance_abs: q.("1")}

    put_leg(
      schema,
      Map.merge(base, %{id: Ecto.UUID.generate(), leg_no: 2, tolerance_state: "within"})
    )

    put_leg(
      schema,
      Map.merge(base, %{
        id: Ecto.UUID.generate(),
        leg_no: 3,
        quantity: q.("7.000000000"),
        tolerance_state: "excepted",
        exception_ref: "ex-1"
      })
    )

    # json text `"` + a * n + `"` is n + 2 bytes: 4094 a's is exactly 4096
    at_limit = lit(String.duplicate("a", 4094) |> then(&~s("#{&1}"))) <> "::jsonb"
    over = lit(String.duplicate("a", 4095) |> then(&~s("#{&1}"))) <> "::jsonb"
    put_leg(schema, %{id: Ecto.UUID.generate(), leg_no: 4, attrs: q.(at_limit)})

    refused(
      leg_sql(schema, %{id: Ecto.UUID.generate(), leg_no: 5, attrs: q.(over)}),
      :check_violation,
      "ledger_leg_attrs_check"
    )
  end

  # -- criterion 4 -----------------------------------------------------------------------------------

  test "A-9 balance shape, refusals, and control characters", %{schema: schema} do
    %{rows: pk} =
      Repo.query!(
        "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid " <>
          "AND a.attnum = ANY(i.indkey) WHERE i.indrelid = $1::text::regclass AND i.indisprimary " <>
          "ORDER BY array_position(i.indkey::int2[], a.attnum)",
        ["#{schema}.ledger_balance"]
      )

    assert List.flatten(pk) == ["ledger_id" | Enum.map(1..8, &"k#{&1}")]
    assert "ledger_balance_k2_k1_index" in index_names(schema)

    bal = %{
      ledger_id: "wh",
      k1: "item-1",
      on_hand: {:raw, "5"},
      unit_ref: "pcs",
      last_posting_seq: 1
    }

    ok!(insert_sql(schema, "ledger_balance", bal))

    ok!(
      insert_sql(
        schema,
        "ledger_balance",
        %{bal | k1: "item-2"} |> Map.put(:max_on_hand, {:raw, "9"})
      )
    )

    refused(
      insert_sql(schema, "ledger_balance", %{bal | k1: "i3", on_hand: {:raw, "-1"}}),
      :check_violation,
      "ledger_balance_on_hand_check"
    )

    refused(
      insert_sql(schema, "ledger_balance", Map.merge(bal, %{k1: "i4", max_on_hand: {:raw, "4"}})),
      :check_violation,
      "ledger_balance_max_on_hand_check"
    )

    refused(
      insert_sql(schema, "ledger_balance", %{bal | k1: "a" <> <<1>>}),
      :check_violation,
      "ledger_balance_k1_check"
    )

    refused(
      insert_sql(schema, "ledger_balance", %{bal | k1: "i5", unit_ref: "p" <> <<1>>}),
      :check_violation,
      "ledger_balance_unit_ref_check"
    )

    put_entry(schema, %{})
    put_leg(schema, %{})

    refused(
      entry_sql(schema, %{id: Ecto.UUID.generate(), cause: "a" <> <<1>>}),
      :check_violation,
      "ledger_entry_cause_check"
    )

    refused(
      entry_sql(schema, %{id: Ecto.UUID.generate(), document_id: "a" <> <<1>>}),
      :check_violation,
      "ledger_entry_document_id_check"
    )

    refused(
      leg_sql(schema, %{id: Ecto.UUID.generate(), leg_no: 2, document_line_id: "a" <> <<1>>}),
      :check_violation,
      "ledger_leg_document_line_id_check"
    )
  end

  test "A-10 ledger functions never name the schema, are not SECURITY DEFINER, pin no search_path",
       %{
         schema: schema
       } do
    %{rows: rows} =
      Repo.query!(
        "SELECT p.proname, p.prosrc, p.prosecdef, p.proconfig FROM pg_proc p " <>
          "WHERE p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1) AND p.prosrc ~ 'ledger_(counter|entry|leg|balance)'",
        [schema]
      )

    # Part A creates no function, so this is empty here; part B adds triggers and keeps these checks.
    for [name, src, secdef, config] <- rows do
      refute src =~ schema, name
      refute secdef, name
      assert config in [nil, []], name
    end

    assert rows == []
  end

  # -- registration and the down guard ---------------------------------------------------------------

  test "A-11 registered last in the manifest and present in the tenant", %{schema: schema} do
    assert {@version, CreateLedgerTables} =
             List.last(TenantProvisioning.tenant_scoped_migrations())

    for t <- ~w(ledger_balance ledger_counter ledger_entry ledger_leg) do
      assert t in TenantFixture.expected_tenant_tables()
      assert Map.has_key?(columns(schema, t), "ledger_id")
    end
  end

  test "A-12 down refuses unless allowed", %{schema: schema} do
    previous = Application.fetch_env(:letflow, :allow_ledger_migration_down)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:letflow, :allow_ledger_migration_down, v)
        :error -> Application.delete_env(:letflow, :allow_ledger_migration_down)
      end
    end)

    for setter <- [
          fn -> Application.put_env(:letflow, :allow_ledger_migration_down, false) end,
          fn -> Application.delete_env(:letflow, :allow_ledger_migration_down) end
        ] do
      setter.()

      assert_raise RuntimeError,
                   ~r/ledger tables are append-only: CreateLedgerTables.down refused/,
                   fn ->
                     CreateLedgerTables.down()
                   end

      assert count(schema, "ledger_counter") == 0
    end

    assert File.read!("config/dev.exs") =~ ":allow_ledger_migration_down, true"
    assert File.read!("config/test.exs") =~ ":allow_ledger_migration_down, true"
    refute File.read!("config/runtime.exs") =~ "allow_ledger_migration_down"
    refute File.read!("config/prod.exs") =~ "allow_ledger_migration_down"
  end

  test "A-14 the only interpolations in the migration are the quoted schema and the fixed table list" do
    src = File.read!(@migration_path)

    interpolations =
      ~r/#\{([^}]*)\}/ |> Regex.scan(src) |> Enum.map(fn [_, inner] -> inner end) |> Enum.uniq()

    assert Enum.sort(interpolations) == ["schema", "table"]
  end
end
