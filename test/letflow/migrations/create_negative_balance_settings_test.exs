defmodule Letflow.CreateNegativeBalanceSettingsTest do
  @moduledoc """
  REQ-834 / GH #4547 criteria 6 and 8: the tenant migration that creates `ledger_balance_settings`
  and drops CHECK `ledger_balance_on_hand_check`. Up and down run in a test schema.
  """
  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.CreateNegativeBalanceSettings

  @version 20_261_117_100_001

  defp q(schema, sql, params \\ []),
    do: Repo.query(String.replace(sql, "S.", ~s("#{schema}".)), params)

  defp check_exists?(schema) do
    {:ok, %{rows: [[n]]}} =
      Repo.query(
        "SELECT count(*)::int FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace " <>
          "WHERE n.nspname = $1 AND c.conname LIKE 'ledger_balance_on_hand_check%'",
        [schema]
      )

    n > 0
  end

  defp insert_setting(schema, name) do
    q(
      schema,
      "INSERT INTO S.ledger_balance_settings (id, registration_name, allow_negative, changed_by, changed_at, reason, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, true, gen_random_uuid(), now(), 'r', now(), now())",
      [name]
    )
  end

  test "MG-1 registered last; down restores the check and drops the table; up drops it again" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "r834-mig")
    schema = fx.schema_name

    assert {@version, CreateNegativeBalanceSettings} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -1)

    refute check_exists?(schema)

    assert {:ok, %{rows: [[0]]}} =
             q(schema, "SELECT count(*)::int FROM S.ledger_balance_settings")

    opts = [prefix: schema, log: false]
    assert :ok = Ecto.Migrator.down(Repo, @version, CreateNegativeBalanceSettings, opts)
    assert check_exists?(schema)
    assert {:error, _} = q(schema, "SELECT 1 FROM S.ledger_balance_settings")

    assert :ok = Ecto.Migrator.up(Repo, @version, CreateNegativeBalanceSettings, opts)
    refute check_exists?(schema)
    assert {:ok, _} = q(schema, "SELECT 1 FROM S.ledger_balance_settings")
  end

  test "MG-2 one row per registration name, blank name refused, no tenant_id column" do
    schema = TenantFixture.provisioned_tenant!(slug_prefix: "r834-uq").schema_name

    assert {:ok, _} = insert_setting(schema, "stock")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             insert_setting(schema, "stock")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             insert_setting(schema, "")

    assert {:ok, %{rows: []}} =
             Repo.query(
               "SELECT 1 FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'ledger_balance_settings' AND column_name = 'tenant_id'",
               [schema]
             )
  end
end
