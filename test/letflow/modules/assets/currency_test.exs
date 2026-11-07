Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CurrencyTest do
  @moduledoc """
  GH #3894 / REQ-748 criterion 4 (tests A-CUR-1..3): the tenant currency is the `currency` setting
  of the module, `KZT` when absent; invalid settings are refused and leave the stored value alone.

  `async: false`: real provisioned tenants, DDL.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule

  setup do
    fx = Fx.installed_tenant!("gh3894-cur")
    {:ok, fx: fx, schema: fx.schema_name}
  end

  defp stored(schema),
    do: Repo.get_by!(TenantModule, [module_id: "assets"], prefix: schema).settings

  test "A-CUR-1: KZT without the key; the stored value after put_settings", %{schema: schema} do
    assert Assets.currency(schema) == "KZT"
    assert {:ok, _} = Installs.put_settings("assets", %{"currency" => "USD"}, prefix: schema)
    assert Assets.currency(schema) == "USD"
    assert stored(schema) == %{"currency" => "USD"}
  end

  test "A-CUR-2: bad settings are refused and the stored settings are unchanged", %{
    schema: schema
  } do
    {:ok, _} = Installs.put_settings("assets", %{"currency" => "EUR"}, prefix: schema)
    before = stored(schema)

    for bad <- [
          %{"currency" => "US"},
          %{"currency" => "USDX"},
          %{"currency" => 7},
          %{"other" => "x"},
          %{"currency" => "USD", "x" => 1}
        ] do
      assert {:error, {:settings_validation_failed, _}} =
               Installs.put_settings("assets", bad, prefix: schema),
             inspect(bad)

      assert stored(schema) == before
    end

    assert Assets.currency(schema) == "EUR"
  end

  test "A-CUR-3: a provisioned tenant without the module answers KZT and does not raise" do
    fx = Fx.provisioned_tenant!("gh3894-cur0")
    assert Assets.currency(fx.schema_name) == "KZT"
  end
end
