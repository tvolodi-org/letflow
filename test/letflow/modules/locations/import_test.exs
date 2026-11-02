Code.require_file("locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.ImportTest do
  @moduledoc """
  GH #3601 / REQ-652: the import of the location tree through the real router (a real API-token
  bearer) on fresh tenants with the real `locations` module installed. `async: false`:
  provisioning switches the sandbox to `:auto`.

  R1 registration; C1 create; P1..P6 re-import; T1..T4 tree refusals; D1/D2 dry run; X1 tenancy;
  M2 write path scan; Q1 scope declarations.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.LocationsFixture, as: Fx
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Locations
  alias Letflow.XlsxFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @header ["code", "name", "node_kind", "parent_id", "external_ref_system", "external_ref_id"]

  defp tenant_ctx(prefix) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3601-user-#{Ecto.UUID.generate()}",
        display_name: "GH-3601 test user",
        email: "gh3601-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    %{tenant_id: tenant_id, schema: schema, slug: slug, plaintext: plaintext, actor: user.id}
  end

  defp authed(conn, ctx) do
    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp import_xlsx(ctx, rows, query \\ "") do
    bytes = XlsxFixture.build([[@header | rows]])

    conn(
      :post,
      "/api/v1/entities/records/location_node/import?upsert_by=external_ref" <> query,
      bytes
    )
    |> put_req_header("content-type", @xlsx)
    |> authed(ctx)
  end

  # code, name, kind, parent external id ("" = none), external id
  defp r(code, name, parent, id, kind \\ "zone"),
    do: [code, name, kind, parent, "erp", id]

  defp results(conn), do: Jason.decode!(conn.resp_body)["results"]
  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))
  defp shape(conn), do: Enum.map(results(conn), &Map.drop(&1, ["record_id"]))

  defp node(ctx, id) do
    row =
      Repo.one(
        from(t in "entity_location_node",
          where: t.external_ref_system == "erp" and t.external_ref_id == ^id,
          select: type(t.record_id, Ecto.UUID)
        ),
        prefix: ctx.schema
      )

    row && elem(Locations.lookup(ctx.schema, row), 1)
  end

  defp counts(schema) do
    {Repo.aggregate(from(e in "events", select: e.id), :count, prefix: schema),
     Repo.aggregate(Latest, :count, prefix: schema)}
  end

  defp tree_rows,
    do: [r("W", "Warehouse", "", "W"), r("A", "Aisle", "W", "A"), r("S", "Shelf", "A", "S")]

  defp seeded(prefix) do
    ctx = tenant_ctx(prefix)
    assert import_xlsx(ctx, tree_rows()).status == 200
    ctx
  end

  test "R1: the manifest registers location_node and validates" do
    assert Locations.manifest().import_functions == [
             %{entity_type: "location_node", function: :import_row}
           ]

    assert Catalog.validate(Locations.manifest()) == :ok
    assert Catalog.import_function("locations", "location_node") == :ok
  end

  test "C1: a root, a child and a grandchild are created with parents by external id" do
    ctx = tenant_ctx("gh3601-c1")
    conn = import_xlsx(ctx, tree_rows())
    assert conn.status == 200, conn.resp_body
    assert outcomes(conn) == ["created", "created", "created"]
    [%{"record_id" => w}, %{"record_id" => a}, %{"record_id" => s}] = results(conn)
    assert {:ok, root} = Locations.lookup(ctx.schema, w)
    refute Map.get(root, "parent_id")
    assert {:ok, %{"parent_id" => ^w}} = Locations.lookup(ctx.schema, a)
    assert {:ok, %{"parent_id" => ^a, "code" => "S"}} = Locations.lookup(ctx.schema, s)
  end

  test "C2: a numeric-looking code stays text" do
    ctx = tenant_ctx("gh3601-c2")
    conn = import_xlsx(ctx, [r(101, "Numeric", "", "N1")])
    assert conn.status == 200, conn.resp_body
    assert outcomes(conn) == ["created"]
    assert %{"code" => code} = node(ctx, "N1")
    assert is_binary(code)
  end

  test "P1: the same file again is unchanged and writes no event" do
    ctx = seeded("gh3601-p1")
    before = counts(ctx.schema)
    conn = import_xlsx(ctx, tree_rows())
    assert outcomes(conn) == ["unchanged", "unchanged", "unchanged"]
    assert counts(ctx.schema) == before
  end

  test "P2: a changed parent moves the node" do
    ctx = seeded("gh3601-p2")
    assert outcomes(import_xlsx(ctx, [r("B", "Aisle B", "W", "B")])) == ["created"]
    conn = import_xlsx(ctx, [r("S", "Shelf", "B", "S")])
    assert outcomes(conn) == ["updated"]
    b = node(ctx, "B")["record_id"]
    assert %{"parent_id" => ^b} = node(ctx, "S")
    assert Locations.descendant_ids(ctx.schema, b) == [node(ctx, "S")["record_id"]]
  end

  test "P3: a changed name updates the node" do
    ctx = seeded("gh3601-p3")
    assert outcomes(import_xlsx(ctx, [r("A", "Aisle renamed", "W", "A")])) == ["updated"]
    assert %{"name" => "Aisle renamed"} = node(ctx, "A")
  end

  test "P4: a changed code is field_not_allowed with header code" do
    ctx = seeded("gh3601-p4")
    conn = import_xlsx(ctx, [r("A2", "Aisle", "W", "A")])
    assert [%{"reason" => %{"type" => "field_not_allowed", "header" => "code"}}] = results(conn)
    assert %{"code" => "A"} = node(ctx, "A")
  end

  test "P5: an active column is refused with header active" do
    ctx = seeded("gh3601-p5")
    bytes = XlsxFixture.build([[@header ++ ["active"], r("A", "Aisle", "W", "A") ++ [false]]])

    conn =
      conn(:post, "/api/v1/entities/records/location_node/import?upsert_by=external_ref", bytes)
      |> put_req_header("content-type", @xlsx)
      |> authed(ctx)

    assert [%{"reason" => %{"type" => "field_not_allowed", "header" => "active"}}] = results(conn)
    assert %{"active" => true} = node(ctx, "A")
  end

  test "P6: a row changing name and code changes nothing" do
    ctx = seeded("gh3601-p6")
    conn = import_xlsx(ctx, [r("A2", "Changed", "W", "A")])
    assert outcomes(conn) == ["field_not_allowed"]
    assert %{"code" => "A", "name" => "Aisle"} = node(ctx, "A")
  end

  test "T1: moving a node under its descendant is cycle and changes nothing" do
    ctx = seeded("gh3601-t1")
    w = node(ctx, "W")["record_id"]
    conn = import_xlsx(ctx, [r("W", "Warehouse", "S", "W")])
    assert outcomes(conn) == ["cycle"]
    assert %{"record_id" => ^w} = root = node(ctx, "W")
    refute Map.get(root, "parent_id")
  end

  test "T2: an unknown parent is reference_not_found with header parent_id" do
    ctx = tenant_ctx("gh3601-t2")
    before = counts(ctx.schema)
    conn = import_xlsx(ctx, [r("X", "X", "NOPE", "X")])

    assert [%{"reason" => %{"type" => "reference_not_found", "header" => "parent_id"}}] =
             results(conn)

    assert counts(ctx.schema) == before
  end

  test "T3: a parent later in the file is reference_not_found" do
    ctx = tenant_ctx("gh3601-t3")
    conn = import_xlsx(ctx, [r("A", "Aisle", "W", "A"), r("W", "Warehouse", "", "W")])
    assert outcomes(conn) == ["reference_not_found", "created"]
  end

  test "T4: a retired parent is parent_inactive for create and for move" do
    ctx = seeded("gh3601-t4")
    {:ok, _} = Locations.retire_node(ctx.schema, node(ctx, "S")["record_id"], opts(ctx))
    {:ok, _} = Locations.retire_node(ctx.schema, node(ctx, "A")["record_id"], opts(ctx))
    assert outcomes(import_xlsx(ctx, [r("N", "New", "A", "N")])) == ["parent_inactive"]
    assert node(ctx, "N") == nil
    assert outcomes(import_xlsx(ctx, [r("W", "Warehouse", "A", "W")])) == ["parent_inactive"]
    refute Map.get(node(ctx, "W"), "parent_id")
  end

  defp opts(ctx), do: %{actor_id: ctx.actor, idempotency_key: Ecto.UUID.generate()}

  test "D1: a dry run answers as the real import and keeps nothing" do
    ctx = tenant_ctx("gh3601-d1")
    before = counts(ctx.schema)
    dry = import_xlsx(ctx, tree_rows(), "&dry_run=true")
    assert Jason.decode!(dry.resp_body)["dry_run"] == true
    assert counts(ctx.schema) == before
    real = import_xlsx(ctx, tree_rows())
    assert shape(dry) == shape(real)
  end

  test "D2: a dry run with a cycle row answers as the real run" do
    ctx = seeded("gh3601-d2")

    rows = [
      r("W", "Warehouse", "S", "W"),
      r("B", "Aisle B", "W", "B"),
      r("C", "Aisle C", "W", "C")
    ]

    before = counts(ctx.schema)
    dry = import_xlsx(ctx, rows, "&dry_run=true")
    assert dry.status == 200, dry.resp_body
    assert counts(ctx.schema) == before
    real = import_xlsx(ctx, rows)
    assert shape(dry) == shape(real)
    assert outcomes(real) == ["cycle", "created", "created"]
  end

  test "X1: a parent that exists only in another tenant is reference_not_found" do
    a = seeded("gh3601-xa")
    b = tenant_ctx("gh3601-xb")
    before_a = counts(a.schema)
    before_b = counts(b.schema)
    conn = import_xlsx(b, [r("Z", "Z", "W", "Z")])
    assert outcomes(conn) == ["reference_not_found"]
    assert counts(a.schema) == before_a
    assert counts(b.schema) == before_b
  end

  test "M2: the import file writes only through the three Tree functions" do
    src = File.read!(Path.expand("../../../../lib/letflow/modules/locations/import.ex", __DIR__))

    for banned <- ["Records.", "owner_for!", "Repo.insert", "Repo.update", "Repo.delete"],
        do: refute(src =~ banned, banned)

    for fun <- ["Locations.create_node(", "Locations.move_node(", "Locations.update_node("],
        do: assert(src =~ fun)
  end

  test "Q1: the scope declaration is unchanged" do
    assert Locations.manifest().scope_declarations == %{
             "location_node" => :tenant_wide,
             "location_org_unit_link" => {:column, "org_unit_id"}
           }
  end
end
