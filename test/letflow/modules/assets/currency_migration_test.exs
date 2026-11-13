Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CurrencyMigrationTest do
  @moduledoc """
  REQ-825 / GH #4392 (slice C3), criteria 1..5: the release task `Letflow.Release.Currencies`
  moves the legacy assets `currency` setting into the directory and rewrites card texts to ISO
  codes (unknown kept and reported, dry run, idempotent).

  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Currencies
  alias Letflow.Currencies.Switch
  alias Letflow.EventStore.Event
  alias Letflow.Modules.Installs
  alias Letflow.Modules.ReadApi
  alias Letflow.Release.Currencies, as: Release

  @action "assets.card_currency_migrated"

  setup do
    fx = Fx.installed_tenant!("req825")
    {:ok, fx: fx, schema: fx.schema_name}
  end

  defp seed!(schema, setting) do
    if setting,
      do: {:ok, _} = Installs.put_settings("assets", %{"currency" => setting}, prefix: schema)

    for {n, cur} <- [
          {"C-1", "kzt"},
          {"C-2", " Тенге "},
          {"C-3", "KZT"},
          {"C-4", nil},
          {"C-5", "XYZ"}
        ],
        into: %{} do
      extra = if cur, do: %{"currency" => cur}, else: %{}
      {n, Fx.card!(schema, n, extra).record_id}
    end
  end

  defp currency_of(schema, id) do
    {:ok, card} = ReadApi.lookup(schema, id, ["assets_card"])
    Map.get(card, "currency")
  end

  defp mine(report, schema), do: Enum.find(report.tenants, &(&1.schema_name == schema))

  # Record events live on the entity type's own instance; pick the ones that name the record.
  defp events(schema, id),
    do: Enum.filter(Repo.all(Event, prefix: schema), &(inspect(&1.payload) =~ id))

  defp event_count(schema, id), do: length(events(schema, id))

  defp audit_count(schema),
    do: Repo.aggregate(from(a in Entry, where: a.action == @action), :count, prefix: schema)

  defp rows(schema),
    do: Repo.all(from(s in Switch, select: {s.code, s.tenant_currency}), prefix: schema)

  test "C1 setting kzt and mixed card texts: counts, rewrites, unknown kept", %{schema: schema} do
    ids = seed!(schema, "kzt")
    assert rows(schema) == []

    report = Release.normalize(dry_run: false)
    t = mine(report, schema)

    assert Currencies.tenant_currency(schema) == "KZT"
    assert rows(schema) == [{"KZT", true}]
    assert currency_of(schema, ids["C-1"]) == "KZT"
    assert currency_of(schema, ids["C-2"]) == "KZT"
    assert currency_of(schema, ids["C-3"]) == "KZT"
    assert currency_of(schema, ids["C-4"]) == nil
    assert currency_of(schema, ids["C-5"]) == "XYZ"

    assert %{settings_set: 1, cards_rewritten: 2, cards_unknown: 1, already_ok: 1, failed: 0} = t
    assert t.unknown_card_ids == [ids["C-5"]]
    # No currency text anywhere in the report (INV-4 spirit).
    refute inspect(report) =~ "XYZ"
  end

  test "C2 each rewritten card has one new event holding the old text and one audit entry", %{
    schema: schema
  } do
    ids = seed!(schema, "kzt")
    before = Map.new(ids, fn {n, id} -> {n, event_count(schema, id)} end)
    assert audit_count(schema) == 0

    Release.normalize(dry_run: false)

    for n <- ["C-1", "C-2"] do
      assert event_count(schema, ids[n]) == before[n] + 1, n
    end

    for n <- ["C-3", "C-4", "C-5"] do
      assert event_count(schema, ids[n]) == before[n], n
    end

    # The old text stays in the history: the earlier event of the card still holds it.
    assert Enum.any?(events(schema, ids["C-2"]), &(inspect(&1.payload) =~ "Тенге"))

    assert audit_count(schema) == 2
  end

  test "C3 a second run changes nothing; a dry run writes nothing and reports the same counts", %{
    schema: schema
  } do
    ids = seed!(schema, "kzt")

    dry = mine(Release.normalize(dry_run: true), schema)
    assert %{settings_set: 1, cards_rewritten: 2, cards_unknown: 1, failed: 0} = dry
    assert rows(schema) == []
    assert currency_of(schema, ids["C-2"]) == " Тенге "
    assert audit_count(schema) == 0

    Release.normalize(dry_run: false)
    events = Map.new(ids, fn {n, id} -> {n, event_count(schema, id)} end)
    audits = audit_count(schema)

    again = mine(Release.normalize(dry_run: false), schema)
    assert %{settings_set: 0, cards_rewritten: 0, cards_unknown: 1, failed: 0} = again
    assert Map.new(ids, fn {n, id} -> {n, event_count(schema, id)} end) == events
    assert audit_count(schema) == audits
    assert rows(schema) == [{"KZT", true}]
  end

  test "C4 an unknown setting writes no row; an existing tenant currency is kept", %{
    schema: schema,
    fx: fx
  } do
    {:ok, _} = Installs.put_settings("assets", %{"currency" => "TNG"}, prefix: schema)
    t = mine(Release.normalize(dry_run: false), schema)
    assert %{settings_set: 0, unknown_setting: 1} = t
    assert rows(schema) == []

    other = Fx.installed_tenant!("req825b")
    {:ok, _} = Installs.put_settings("assets", %{"currency" => "EUR"}, prefix: other.schema_name)

    {:ok, _} =
      Currencies.switch(
        other.schema_name,
        "USD",
        %{"active" => true, "tenant_currency" => true},
        nil
      )

    t2 = mine(Release.normalize(dry_run: false), other.schema_name)
    assert t2.settings_set == 0
    assert Currencies.tenant_currency(other.schema_name) == "USD"
    assert fx.schema_name != other.schema_name
  end

  test "C5 a tenant is never touched through another tenant's schema", %{schema: schema} do
    ids = seed!(schema, "kzt")
    other = Fx.installed_tenant!("req825c")
    {:ok, other_card} = {:ok, Fx.card!(other.schema_name, "O-1", %{"currency" => "tenge"})}

    Release.normalize(dry_run: false)

    assert currency_of(schema, ids["C-1"]) == "KZT"
    assert currency_of(other.schema_name, other_card.record_id) == "KZT"
    assert rows(other.schema_name) == []
  end
end
