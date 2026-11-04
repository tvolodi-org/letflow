defmodule Letflow.Test.TenantTemplateLedgerTest do
  @moduledoc """
  REQ-620 / GH #3463 part C, criterion 9: the ledger tables in the test tenant template.
  A clone where a ledger table holds a row is unprovable (the tables refuse TRUNCATE), so the
  pool rebuilds it; the triggers and foreign keys survive the clone; the sandbox fixture loader
  does not accept a ledger table. `async: false` (template and DDL), Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.SandboxPool.FixtureLoader
  alias Letflow.SandboxPool.FixtureLoader.FixtureRow
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.Test.TenantTemplate

  @append_only "ledger data is append-only: this statement is refused"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    :ok = TenantTemplate.ensure_template!()

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("ledger-tt"),
          display_name: "Ledger template test (throwaway)"
        },
        :disabled
      )
      |> Repo.insert!()

    {:ok, schema} = TenantTemplate.clone_tenant_schema!(tenant.id)

    on_exit(fn ->
      {:ok, name} = Letflow.TenantProvisioning.schema_name_for_tenant(tenant.id)
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{name}" CASCADE))

      Repo.delete_all(
        from(r in Letflow.TenantProvisioning.Registration, where: r.tenant_id == ^tenant.id)
      )

      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    {:ok, tenant: tenant, schema: schema}
  end

  test "T-TT-1 a dirty ledger table is unprovable and the rebuild is clean", %{
    tenant: tenant,
    schema: s
  } do
    # REQ-710: the balance row below needs the partitions of its ledger id; they are part of the
    # baseline here (a partition made after the baseline is definition drift, see the clone test
    # in tenant_template_test.exs)
    Letflow.LedgerFixture.ensure_storage!(s, "wh")
    baseline = TenantTemplate.capture_clone_baseline!(s)
    assert {:ok, _} = TenantTemplate.reset_clone_schema!(s, baseline)

    Repo.query!(
      ~s|INSERT INTO "#{s}".ledger_counter (ledger_id, last_seq, last_chain_hash) VALUES ('wh', 0, '')|
    )

    assert {:error, {:unprovable, ["append_only_table_dirty ledger_counter"]}} =
             TenantTemplate.reset_clone_schema!(s, baseline)

    # nothing was truncated by the refused reset
    assert %{rows: [[1]]} = Repo.query!(~s|SELECT count(*)::int FROM "#{s}".ledger_counter|)

    # two dirty tables: one reason per table
    Repo.query!(
      ~s|INSERT INTO "#{s}".ledger_balance (ledger_id, k1, on_hand, unit_ref, last_posting_seq) | <>
        ~s|VALUES ('wh', 'a', 0, 'pcs', 0)|
    )

    assert {:error, {:unprovable, reasons}} = TenantTemplate.reset_clone_schema!(s, baseline)

    assert Enum.sort(reasons) == [
             "append_only_table_dirty ledger_balance",
             "append_only_table_dirty ledger_counter"
           ]

    assert {:ok, s2} = TenantTemplate.rebuild_clone_schema!(tenant.id)
    baseline2 = TenantTemplate.capture_clone_baseline!(s2)
    assert {:ok, _} = TenantTemplate.reset_clone_schema!(s2, baseline2)
    assert %{rows: [[0]]} = Repo.query!(~s|SELECT count(*)::int FROM "#{s2}".ledger_counter|)
  end

  test "T-TT-2 the clone has the 17 triggers, always enabled, refusing with the clone schema", %{
    schema: s
  } do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT t.tgenabled FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $1 AND NOT t.tgisinternal AND c.relname LIKE 'ledger\\_%'
        """,
        [s]
      )

    assert length(rows) == 17
    assert Enum.all?(rows, &(&1 == ["A"]))

    Repo.query!(
      ~s|INSERT INTO "#{s}".ledger_counter (ledger_id, last_seq, last_chain_hash) VALUES ('wh', 0, '')|
    )

    for sql <- [
          ~s|DELETE FROM "#{s}".ledger_counter|,
          ~s|TRUNCATE "#{s}".ledger_entry CASCADE|,
          ~s|TRUNCATE "#{s}".ledger_leg|
        ] do
      assert {:error, %Postgrex.Error{postgres: %{message: @append_only, schema: ^s}}} =
               Repo.query(sql)
    end
  end

  test "T-TT-3 the ledger foreign keys stay inside the ledger set", %{schema: s} do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT cl.relname, cf.relname FROM pg_constraint k
          JOIN pg_class cl ON cl.oid = k.conrelid
          JOIN pg_class cf ON cf.oid = k.confrelid
          JOIN pg_namespace n ON n.oid = cl.relnamespace
         WHERE n.nspname = $1 AND k.contype = 'f'
           AND (cl.relname LIKE 'ledger\\_%' OR cf.relname LIKE 'ledger\\_%')
         ORDER BY 1, 2
        """,
        [s]
      )

    # REQ-711: the entry and leg keys live on the per-ledger-id partitions (created by
    # Storage.ensure/2), so a template with no ledger partition has none on the parents;
    # whatever exists stays inside the ledger set.
    assert Enum.all?(rows, fn [from, to] ->
             String.starts_with?(from, "ledger_") and String.starts_with?(to, "ledger_entry")
           end)
  end

  test "T-TT-4 the sandbox fixture loader refuses a ledger table", %{schema: s} do
    # the loader checks the schema name shape, then the table allowlist, before any SQL
    sandbox = "sandbox_" <> String.duplicate("0", 32)

    assert {:error, :invalid_table_name} =
             FixtureLoader.load_fixtures_only(sandbox, [
               %FixtureRow{table_name: "ledger_entry", row_json: "{}"}
             ])

    assert %{rows: [[0]]} = Repo.query!(~s|SELECT count(*)::int FROM "#{s}".ledger_entry|)
  end
end
