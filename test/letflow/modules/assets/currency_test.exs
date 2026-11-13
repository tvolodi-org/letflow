Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CurrencyTest do
  @moduledoc """
  GH #3894 / REQ-748 criterion 4 (tests A-CUR-1..3): the tenant currency is the `currency` setting
  of the module, `KZT` when absent; invalid settings are refused and leave the stored value alone.

  GH #4391 / REQ-826 criterion 1 (tests A-CUR-4..7): `currency/1` reads the directory tenant
  currency first, then falls back to `Currencies.normalize/1` on the legacy setting, then the
  setting as-stored when three characters, then `KZT`.

  `async: false`: real provisioned tenants, DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Currencies
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

  # REQ-826 criterion 1: directory-first with legacy fallback

  test "A-CUR-4: directory tenant currency takes priority over assets setting", %{schema: schema} do
    # Setting says EUR; directory says USD
    {:ok, _} = Installs.put_settings("assets", %{"currency" => "EUR"}, prefix: schema)
    actor = Ecto.UUID.generate()

    {:ok, _} =
      Currencies.switch(schema, "USD", %{"active" => true, "tenant_currency" => true}, actor)

    assert Assets.currency(schema) == "USD"
  end

  test "A-CUR-5: no directory row, setting kzt normalizes to KZT", %{schema: schema} do
    # No switch row; setting is lowercase
    {:ok, _} = Installs.put_settings("assets", %{"currency" => "kzt"}, prefix: schema)

    assert Assets.currency(schema) == "KZT"
  end

  test "A-CUR-6: no directory row, three-char legacy setting TNG is returned as-is", %{
    schema: schema
  } do
    # TNG is not in the platform list; it must be returned as-is (three characters, legacy)
    Repo.update_all(
      from(t in TenantModule, where: t.module_id == "assets"),
      [set: [settings: %{"currency" => "TNG"}]],
      prefix: schema
    )

    assert Assets.currency(schema) == "TNG"
  end

  test "A-CUR-7: no directory row, no assets setting returns KZT", %{schema: schema} do
    # No switch row, no setting key — the D-097 default
    assert Assets.currency(schema) == "KZT"
  end
end
