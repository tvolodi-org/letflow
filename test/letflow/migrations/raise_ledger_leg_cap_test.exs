defmodule Letflow.RaisePostingLegCapTest do
  @moduledoc """
  REQ-774 (MG-1): the tenant migration that moves the two leg-count CHECK constraints from 200 to 2000.
  A partition that existed BEFORE the migration (built from the 200 constraints) and one created AFTER it
  both accept 2000 and refuse 2001, for `leg_count` and for `leg_no`. Registration, replay and down.
  `async: false` (tenant provisioning and DDL, real commits).
  """

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture
  alias Letflow.Repo.Migrations.RaisePostingLegCap
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_106_200_001
  @hash String.duplicate("a", 64)
  @t0 "2026-11-04T10:00:00Z"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r774-mig")
    previous = Application.fetch_env(:letflow, :allow_ledger_migration_down)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:letflow, :allow_ledger_migration_down, v)
        :error -> Application.delete_env(:letflow, :allow_ledger_migration_down)
      end
    end)

    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp q!(sql, params \\ []), do: Repo.query!(sql, params)

  defp run(schema, dir),
    do:
      Ecto.Migrator.run(Repo, [{@version, RaisePostingLegCap}], dir,
        all: true,
        prefix: schema,
        log: false
      )

  # every CHECK definition named `name` on the parent and on all its partitions
  defp defs(schema, parent, name) do
    %{rows: rows} =
      q!(
        """
        SELECT c.relname, pg_get_constraintdef(k.oid)
          FROM pg_constraint k
          JOIN pg_class c ON c.oid = k.conrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $1 AND k.conname = $3
           AND (c.relname = $2 OR c.oid IN (
                 SELECT i.inhrelid FROM pg_inherits i
                  WHERE i.inhparent = format('%I.%I', $1::text, $2::text)::regclass))
         ORDER BY 1
        """,
        [schema, parent, name]
      )

    rows
  end

  defp entry_sql(schema, ledger, id, seq, legs) do
    ~s|INSERT INTO "#{schema}".ledger_entry (id, ledger_id, posting_seq, cause, sign_rule, actor_id, subject_id, correlation_id, event_time, posting_time, client_op_id, origin_key, payload_hash, entry_digest, chain_hash, registration_hash, leg_count) VALUES ('#{id}', '#{ledger}', #{seq}, 'receipt', 'positive', '#{Ecto.UUID.generate()}', '#{Ecto.UUID.generate()}', 'c1', '#{@t0}', '#{@t0}', 'op-#{seq}', 'origin-#{seq}', '#{@hash}', '#{@hash}', '#{@hash}', '#{@hash}', #{legs})|
  end

  defp leg_sql(schema, ledger, entry_id, leg_no) do
    ~s|INSERT INTO "#{schema}".ledger_leg (id, entry_id, ledger_id, posting_seq, event_time, leg_no, k1, quantity, unit_ref, quantity_scale) VALUES ('#{Ecto.UUID.generate()}', '#{entry_id}', '#{ledger}', 1, '#{@t0}', #{leg_no}, 'a', 1, 'u1', 0)|
  end

  # each probe runs in its own transaction that is always rolled back
  defp probe(sql) do
    {:error, result} =
      Repo.transaction(fn ->
        result =
          try do
            q!(sql)
            :ok
          rescue
            e in Postgrex.Error -> {:error, e.postgres}
          end

        Repo.rollback(result)
      end)

    result
  end

  defp accepted?(sql), do: probe(sql) == :ok

  defp refused?(sql, constraint) do
    match?({:error, %{code: :check_violation, constraint: c}} when is_binary(c), probe(sql)) and
      probe(sql) |> elem(1) |> Map.get(:constraint) |> String.contains?(constraint)
  end

  test "MG-1 an old and a new partition both accept 2000 and refuse 2001; replay is a no-op", %{
    schema: schema
  } do
    Application.put_env(:letflow, :allow_ledger_migration_down, true)

    # the state before the migration: 200, and a partition built from it
    assert [@version] = run(schema, :down)
    LedgerFixture.ensure_storage!(schema, "oldl")

    for {parent, name} <- [
          {"ledger_entry", "ledger_entry_leg_count_check"},
          {"ledger_leg", "ledger_leg_leg_no_check"}
        ] do
      defs = defs(schema, parent, name)
      assert length(defs) >= 2
      assert Enum.all?(defs, fn [_, d] -> d =~ "200" end), inspect(defs)
    end

    assert [@version] = run(schema, :up)
    LedgerFixture.ensure_storage!(schema, "newl")

    for {parent, name} <- [
          {"ledger_entry", "ledger_entry_leg_count_check"},
          {"ledger_leg", "ledger_leg_leg_no_check"}
        ] do
      defs = defs(schema, parent, name)
      assert length(defs) >= 3, "parent and two partitions: #{inspect(defs)}"

      assert Enum.all?(defs, fn [_, d] -> d =~ "2000" and not (d =~ "200)") end),
             inspect(defs)
    end

    LedgerFixture.disable_guards!(schema, "ledger_entry")
    LedgerFixture.disable_guards!(schema, "ledger_leg")

    for ledger <- ["oldl", "newl"] do
      id = Ecto.UUID.generate()
      assert accepted?(entry_sql(schema, ledger, id, 1, 2000))
      assert refused?(entry_sql(schema, ledger, id, 1, 2001), "leg_count")
      assert refused?(entry_sql(schema, ledger, id, 1, 0), "leg_count")

      q!(entry_sql(schema, ledger, id, 1, 2000))
      assert accepted?(leg_sql(schema, ledger, id, 2000))
      assert refused?(leg_sql(schema, ledger, id, 2001), "leg_no")
      assert refused?(leg_sql(schema, ledger, id, 0), "leg_no")
    end

    # replay: the registered migration run again changes nothing
    q!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = $1|, [@version])
    before = defs(schema, "ledger_leg", "ledger_leg_leg_no_check")
    assert [@version] = run(schema, :up)
    assert defs(schema, "ledger_leg", "ledger_leg_leg_no_check") == before
  end

  test "MG-2 registered second to last; down refuses without the flag" do
    assert {@version, RaisePostingLegCap} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -3)

    Application.put_env(:letflow, :allow_ledger_migration_down, false)

    assert_raise RuntimeError, ~r/RaisePostingLegCap.down refused/, fn ->
      RaisePostingLegCap.down()
    end
  end

  test "MG-3 the only interpolated values are the schema and the cap" do
    src = File.read!("priv/repo/migrations/20261106200001_raise_posting_leg_cap.exs")

    names =
      ~r/#\{([^}]*)\}/
      |> Regex.scan(src)
      |> Enum.map(fn [_, n] -> n end)
      |> Enum.uniq()
      |> Enum.sort()

    assert names == ["cap", "schema"]
    assert src =~ "if prefix() do"
  end
end
