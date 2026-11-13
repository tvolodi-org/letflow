defmodule Letflow.CurrenciesTest do
  @moduledoc """
  REQ-823 / GH #4394 criteria 2 to 5: the tenant switches of the currency directory
  (`Letflow.Currencies`). `async: false` (committed tenants, audit chain).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Currencies
  alias Letflow.Currencies.Catalog
  alias Letflow.TenantFixture

  setup do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "r823")
    {:ok, t: t, prefix: t.schema_name}
  end

  defp audit_count(prefix) do
    from(e in Entry, where: e.action == "currencies.switched", select: count(e.id))
    |> Repo.one(prefix: prefix)
  end

  defp rows(prefix) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT code, active, tenant_currency FROM "#{prefix}".tenant_currencies ORDER BY code|
      )

    rows
  end

  test "K1 an untouched tenant reads KZT as active and as the tenant currency", %{prefix: p} do
    assert Currencies.tenant_currency(p) == "KZT"
    assert Currencies.active?(p, "KZT")
    refute Currencies.active?(p, "USD")
    refute Currencies.active?(p, "ABC")

    list = Currencies.list(p)
    assert Enum.map(list, & &1.code) == Catalog.codes()
    assert for(%{code: c, active: true} <- list, do: c) == ["KZT"]
    assert rows(p) == []
  end

  test "K2 switching USD on makes it active", %{prefix: p} do
    assert {:ok, %{code: "USD", active: true, tenant_currency: "KZT"}} =
             Currencies.switch(p, "USD", %{"active" => true}, nil)

    assert Currencies.active?(p, "USD")
    assert Currencies.tenant_currency(p) == "KZT"
    assert audit_count(p) == 1
  end

  test "K3 tenant_currency true on USD makes it the tenant currency and keeps KZT active", %{
    prefix: p
  } do
    assert {:ok, %{tenant_currency: "USD"}} =
             Currencies.switch(p, "USD", %{"active" => true, "tenant_currency" => true}, nil)

    assert Currencies.tenant_currency(p) == "USD"
    assert Currencies.active?(p, "USD")
    assert Currencies.active?(p, "KZT")

    # moving it again clears the previous flag; a second true row is impossible
    assert {:ok, %{tenant_currency: "EUR"}} =
             Currencies.switch(p, "EUR", %{active: true, tenant_currency: true}, nil)

    assert Enum.count(rows(p), fn [_, _, flag] -> flag end) == 1
    assert Currencies.tenant_currency(p) == "EUR"
    assert audit_count(p) == 2

    # back to KZT (no row yet): flag moves to a KZT row
    assert {:ok, %{tenant_currency: "KZT"}} =
             Currencies.switch(p, "KZT", %{"active" => true, "tenant_currency" => true}, nil)

    assert Currencies.tenant_currency(p) == "KZT"
  end

  test "K4 refusals write nothing", %{prefix: p} do
    before_rows = rows(p)

    assert {:error, :currency_is_tenant_currency} =
             Currencies.switch(p, "KZT", %{"active" => false}, nil)

    assert {:error, :currency_unknown} = Currencies.switch(p, "ABC", %{"active" => true}, nil)
    assert {:error, :currency_unknown} = Currencies.switch(p, "usd", %{"active" => true}, nil)

    assert {:error, :invalid_body} =
             Currencies.switch(p, "USD", %{"active" => true, "x" => 1}, nil)

    assert {:error, :invalid_body} =
             Currencies.switch(p, "USD", %{"tenant_currency" => true}, nil)

    assert {:error, :invalid_body} = Currencies.switch(p, "USD", %{"active" => "true"}, nil)

    assert {:error, :invalid_body} =
             Currencies.switch(p, "USD", %{"active" => true, "tenant_currency" => false}, nil)

    assert {:error, :invalid_body} =
             Currencies.switch(p, "USD", %{"active" => false, "tenant_currency" => true}, nil)

    assert {:error, :invalid_body} = Currencies.switch(p, "USD", nil, nil)

    assert rows(p) == before_rows
    assert audit_count(p) == 0
  end

  test "K5 the tenant currency cannot be switched off, other codes can", %{prefix: p} do
    {:ok, _} = Currencies.switch(p, "USD", %{"active" => true, "tenant_currency" => true}, nil)

    assert {:error, :currency_is_tenant_currency} =
             Currencies.switch(p, "USD", %{"active" => false}, nil)

    # KZT is no longer the tenant currency: it may be switched off, and then reads inactive
    assert {:ok, _} = Currencies.switch(p, "KZT", %{"active" => false}, nil)
    refute Currencies.active?(p, "KZT")
    assert audit_count(p) == 2
  end

  test "K6 a switch in tenant A changes neither list nor tenant currency of tenant B (INV-1)", %{
    prefix: a
  } do
    b = TenantFixture.provisioned_tenant!(slug_prefix: "r823b")
    before_b = Currencies.list(b.schema_name)

    {:ok, _} = Currencies.switch(a, "USD", %{"active" => true, "tenant_currency" => true}, nil)

    assert Currencies.list(b.schema_name) == before_b
    assert Currencies.tenant_currency(b.schema_name) == "KZT"
    assert rows(b.schema_name) == []
    assert audit_count(b.schema_name) == 0
  end

  test "K7 the migration is registered and the table is in the fixture list" do
    assert {20_261_113_100_001, Letflow.Repo.Migrations.CreateTenantCurrencies} =
             List.keyfind(
               Letflow.TenantProvisioning.tenant_scoped_migrations(),
               20_261_113_100_001,
               0
             )

    assert "tenant_currencies" in TenantFixture.expected_tenant_tables()
  end

  test "N1 normalize/1 maps codes and aliases, anything else is unknown" do
    for text <- ["kzt", " Тенге ", "теңге", "тг", "₸", "TENGE", "KZT"] do
      assert Currencies.normalize(text) == {:ok, "KZT"}, text
    end

    assert Currencies.normalize("usd") == {:ok, "USD"}
    assert Currencies.normalize(" Eur ") == {:ok, "EUR"}

    for text <- ["XYZ", "", "   ", "USDX", "dollar", nil, 5] do
      assert Currencies.normalize(text) == :unknown, inspect(text)
    end
  end
end
