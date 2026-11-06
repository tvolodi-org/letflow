Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CardExportTest do
  @moduledoc """
  REQ-763 / GH #3898 criterion 1 (C18-CARD-*): the existing record export
  `POST /entities/records/assets_card/export?format=xlsx` answers for the module-managed type, with
  no code change in `Letflow.Routers.Entities`. Scope, the 200-row page, headers and tenant
  isolation. Cards are created through the owner path (`Letflow.AssetsFixture.card!/3`); C18 adds no
  write path (D-098).

  `async: false`: real committed tenants.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.TokenMintFixture

  @router Letflow.Routers.Entities
  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  setup do
    fx = Fx.installed_tenant!("gh3898-card")
    schema = fx.schema_name
    u1 = Ecto.UUID.generate()
    u2 = Ecto.UUID.generate()
    for id <- [u1, u2], do: {:ok, _} = ScopeNodePaths.write({:insert, id, nil}, schema)
    Fx.card!(schema, "INV-1", %{"org_unit_id" => u1, "name" => "=Laptop"})
    Fx.card!(schema, "INV-2", %{"org_unit_id" => u2})
    {:ok, fx: fx, schema: schema, u1: u1, u2: u2}
  end

  defp export(fx, user, roles, mode, query, body) do
    On.call(
      @router,
      :post,
      "/records/assets_card/export" <> query,
      fx,
      user.id,
      roles,
      mode,
      Map.put(body, "entity_type", "assets_card")
    )
  end

  defp admin_export(fx, query \\ "?format=xlsx", body \\ %{}),
    do: export(fx, fx.admin, ["TENANT_ADMIN"], :off, query, body)

  defp sheets(binary) do
    {:ok, pkg} = XlsxReader.open(binary, source: :binary)

    Map.new(XlsxReader.sheet_names(pkg), fn name ->
      {:ok, rows} = XlsxReader.sheet(pkg, name)
      {name, rows}
    end)
  end

  defp numbers(conn) do
    assert conn.status == 200, conn.resp_body
    [header | rows] = sheets(conn.resp_body)["records"]
    col = Enum.find_index(header, &(&1 == "inventory_number"))
    rows |> Enum.map(&Enum.at(&1, col)) |> Enum.sort()
  end

  test "C18-CARD-1: the file holds the definition columns and one row per card", %{
    fx: fx,
    schema: schema,
    u1: u1
  } do
    conn = admin_export(fx)
    assert conn.status == 200, conn.resp_body
    sheets = sheets(conn.resp_body)

    {:ok, definition} =
      Letflow.Entities.Definitions.get_active_definition_by_name("assets_card", schema)

    fields = for %{"name" => name} <- definition.definition_json["fields"], do: name

    [header | rows] = sheets["records"]
    assert header == fields
    assert length(rows) == 2

    row =
      Enum.find(
        rows,
        &(Enum.at(&1, Enum.find_index(header, fn h -> h == "inventory_number" end)) == "INV-1")
      )

    assert Enum.at(row, Enum.find_index(header, &(&1 == "org_unit_id"))) == u1
    # a name starting with "=" is shown, not evaluated
    assert Enum.at(row, Enum.find_index(header, &(&1 == "name"))) == "=Laptop"

    export_rows = Map.new(sheets["export"], fn [k | v] -> {k, List.first(v)} end)
    assert export_rows["entity_type"] == "assets_card"
    assert is_binary(export_rows["exported_at"])
    assert Map.has_key?(export_rows, "next_cursor")
  end

  test "C18-CARD-2: headers; an unknown format is 422", %{fx: fx} do
    conn = admin_export(fx)
    assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ @xlsx

    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="assets_card.xlsx")]

    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert admin_export(fx, "?format=csv").status == 422
  end

  @tag timeout: 120_000
  test "C18-CARD-3: a page is 200 rows and next_cursor carries on", %{fx: fx, schema: schema} do
    for n <- 3..201, do: Fx.card!(schema, "INV-#{n}")

    conn = admin_export(fx)
    assert conn.status == 200, conn.resp_body
    sheets = sheets(conn.resp_body)
    assert length(sheets["records"]) == 201

    cursor =
      Enum.find_value(sheets["export"], fn
        [k, v] when k == "next_cursor" -> v
        _ -> nil
      end)

    assert is_binary(cursor) and cursor != ""

    next = admin_export(fx, "?format=xlsx", %{"cursor" => cursor})
    assert length(numbers(next)) == 1
  end

  test "C18-CARD-4: a reader scoped to U1 gets the U1 cards only", %{
    fx: fx,
    schema: schema,
    u1: u1
  } do
    role = "TENANT_ADMIN"
    group = RSG.group_of!(schema, role)
    _ = RSG.raw_delete_rows!(schema, group, role)
    user = TokenMintFixture.role_holder!(schema, [role])
    :ok = RSG.raw_user_row!(schema, user.id, role, u1)

    assert numbers(export(fx, user, [role], :on, "?format=xlsx", %{})) == ["INV-1"]

    wide = TokenMintFixture.role_holder!(schema, [role])
    :ok = RSG.raw_user_row!(schema, wide.id, role, nil)
    assert numbers(export(fx, wide, [role], :on, "?format=xlsx", %{})) == ["INV-1", "INV-2"]
  end

  test "C18-CARD-5: the admin of another tenant gets none of these cards (INV-10)" do
    other = Fx.installed_tenant!("gh3898-oth")
    Fx.card!(other.schema_name, "OTHER-1")

    assert numbers(admin_export(other)) == ["OTHER-1"]

    filtered =
      admin_export(other, "?format=xlsx", %{
        "filters" => [%{"field" => "inventory_number", "op" => "eq", "value" => "INV-1"}]
      })

    assert numbers(filtered) == []
  end
end
