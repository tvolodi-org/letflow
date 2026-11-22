defmodule Letflow.AllowZeroCountSetLegsTest do
  @moduledoc """
  T-2415: the tenant migration that lets the old Qoimeks empty-shelf count store its zero count_set
  leg. The core validator keeps zero refused for every other cause. Up and down run in a test schema.
  """
  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.AllowZeroCountSetLegs

  @version 20_261_121_100_001

  defp constraints(schema) do
    {:ok, %{rows: rows}} =
      Repo.query(
        "SELECT c.conname FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace " <>
          "WHERE n.nspname = $1 AND c.conname = 'ledger_leg_quantity_check' ORDER BY c.conname",
        [schema]
      )

    List.flatten(rows)
  end

  test "MG-1 registered in the manifest; down restores the check and up removes it from parent and partitions" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2415-mig")
    schema = fx.schema_name

    assert {@version, AllowZeroCountSetLegs} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -3)

    assert constraints(schema) == []

    original = Application.fetch_env(:letflow, :allow_ledger_migration_down)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:letflow, :allow_ledger_migration_down, value)
        :error -> Application.delete_env(:letflow, :allow_ledger_migration_down)
      end
    end)

    Application.put_env(:letflow, :allow_ledger_migration_down, true)
    opts = [prefix: schema, log: false]

    assert :ok = Ecto.Migrator.down(Repo, @version, AllowZeroCountSetLegs, opts)
    assert constraints(schema) != []

    assert :ok = Ecto.Migrator.up(Repo, @version, AllowZeroCountSetLegs, opts)
    assert constraints(schema) == []
  end
end
