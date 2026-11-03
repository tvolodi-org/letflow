Code.require_file("org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Org.ImportTest do
  @moduledoc """
  GH #3599 / REQ-654: the import of org units, positions and employees through the real router (a
  real API-token bearer) on fresh tenants with the real `org` module installed. `async: false`:
  provisioning switches the sandbox to `:auto`.

  R1 registration; C1..C3 create; P1..P3 re-import; F1..F3 refusals; D1 dry run; S1 scope;
  X1 tenancy; M2 write path scan; Q1 scope declarations.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture, as: Fx
  alias Letflow.XlsxFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @unit_header ~w(code name legal_entity_id site_id parent external_ref_system external_ref_id)
  @pos_header ~w(code name org_unit_id external_ref_system external_ref_id)
  @emp_header ~w(code full_name org_unit_id position_id user_id external_ref_system external_ref_id)

  defp new_user(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh3599-user-#{Ecto.UUID.generate()}",
      display_name: "GH-3599 test user",
      email: "gh3599-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp opts(ctx), do: %{actor_id: ctx.actor, idempotency_key: Ecto.UUID.generate()}

  # A tenant with org installed, a TENANT_ADMIN token, one legal entity "LE1" and one site "S1"
  # created through their write functions with matching external refs (system "erp").
  defp tenant_ctx(prefix) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug
    user = new_user(schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    ctx = %{
      tenant_id: tenant_id,
      schema: schema,
      slug: slug,
      plaintext: plaintext,
      actor: user.id,
      user: user
    }

    {:ok, le} =
      Org.create_legal_entity(
        schema,
        %{
          "code" => "LE1",
          "name" => "Company",
          "bin" => "123456789012",
          "external_ref_system" => "erp",
          "external_ref_id" => "LE1"
        },
        opts(ctx)
      )

    {:ok, _} =
      Org.create_site(
        schema,
        %{
          "code" => "S1",
          "name" => "Site",
          "legal_entity_id" => le["record_id"],
          "external_ref_system" => "erp",
          "external_ref_id" => "S1"
        },
        opts(ctx)
      )

    ctx
  end

  defp authed(conn, ctx) do
    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp import_xlsx(ctx, type, header, rows, query \\ "") do
    bytes = XlsxFixture.build([[header | rows]])

    conn(
      :post,
      "/api/v1/entities/records/#{type}/import?upsert_by=external_ref" <> query,
      bytes
    )
    |> put_req_header("content-type", @xlsx)
    |> authed(ctx)
  end

  defp units(ctx, rows, query \\ ""), do: import_xlsx(ctx, "org_unit", @unit_header, rows, query)
  defp positions(ctx, rows), do: import_xlsx(ctx, "org_position", @pos_header, rows)
  defp employees(ctx, rows), do: import_xlsx(ctx, "org_employee", @emp_header, rows)

  # code, parent external id (nil = root), external id
  defp u(code, parent, id, name \\ nil),
    do: [code, name || "Unit #{code}", "LE1", "S1", parent, "erp", id]

  defp p(code, unit, id, name \\ nil), do: [code, name || "Pos #{code}", unit, "erp", id]

  defp e(code, unit, position, user, id, name \\ nil),
    do: [code, name || "Emp #{code}", unit, position, user, "erp", id]

  defp results(conn), do: Jason.decode!(conn.resp_body)["results"]
  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))
  defp shape(conn), do: Enum.map(results(conn), &Map.drop(&1, ["record_id"]))

  defp rec(ctx, type, id) do
    table = "entity_" <> type

    row =
      Repo.one(
        from(t in table,
          where: t.external_ref_system == "erp" and t.external_ref_id == ^id,
          select: type(t.record_id, Ecto.UUID)
        ),
        prefix: ctx.schema
      )

    row && elem(Org.lookup(ctx.schema, row), 1)
  end

  defp counts(schema) do
    {Repo.aggregate(from(e in "events", select: e.id), :count, prefix: schema),
     Repo.aggregate(Latest, :count, prefix: schema),
     Repo.one(from(s in "scope_node_paths", select: count()), prefix: schema)}
  end

  defp path(ctx, id) do
    Repo.one(
      from(s in "scope_node_paths",
        where: s.node_id == ^id,
        select: s.path
      ),
      prefix: ctx.schema
    )
  end

  defp unit_rows, do: [u("ROOT", nil, "ROOT"), u("A", "ROOT", "A"), u("B", "ROOT", "B")]

  # units + a position in A + an employee (with that position and a user)
  defp seeded(prefix) do
    ctx = tenant_ctx(prefix)
    assert units(ctx, unit_rows()).status == 200
    assert outcomes(positions(ctx, [p("P1", "A", "P1")])) == ["created"]

    assert outcomes(employees(ctx, [e("E1", "A", "P1", ctx.user.id, "E1")])) == ["created"]
    ctx
  end

  test "R1: both manifests register their types and validate" do
    names = fn m -> for %{entity_type: n} <- m.import_functions, do: n end
    assert names.(Org.manifest()) == ["org_unit", "org_position", "org_employee"]

    assert Enum.sort(names.(Letflow.Modules.CatalogItems.manifest())) ==
             ["catalog_counterparty", "catalog_item", "catalog_lot", "catalog_uom"]

    assert Catalog.validate(Org.manifest()) == :ok
    assert Catalog.validate(Letflow.Modules.CatalogItems.manifest()) == :ok

    for t <- ["org_unit", "org_position", "org_employee"],
        do: assert(Catalog.import_function("org", t) == :ok)

    assert Catalog.import_function("org", "org_site") == {:error, :not_found}
  end

  test "C1: a root and two children are created with parents by external id" do
    ctx = tenant_ctx("gh3599-c1")
    conn = units(ctx, unit_rows())
    assert conn.status == 200, conn.resp_body
    assert outcomes(conn) == ["created", "created", "created"]
    [%{"record_id" => root}, %{"record_id" => a}, _] = results(conn)
    assert {:ok, r} = Org.lookup(ctx.schema, root)
    refute Map.get(r, "parent")

    assert {:ok, %{"parent" => ^root, "code" => "A", "active" => true}} =
             Org.lookup(ctx.schema, a)
  end

  test "C2: positions and employees (with and without position or user) are created" do
    ctx = tenant_ctx("gh3599-c2")
    assert outcomes(units(ctx, unit_rows())) == ["created", "created", "created"]
    assert outcomes(positions(ctx, [p("P1", "A", "P1")])) == ["created"]

    rows = [
      e("E1", "A", "P1", ctx.user.id, "E1"),
      e("E2", "A", nil, nil, "E2"),
      e("E3", "B", nil, nil, "E3")
    ]

    conn = employees(ctx, rows)
    assert conn.status == 200, conn.resp_body
    assert outcomes(conn) == ["created", "created", "created"]
  end

  test "C3: stored references are record ids and the units have index rows" do
    ctx = seeded("gh3599-c3")
    le = rec(ctx, "org_legal_entity", "LE1")["record_id"]
    site = rec(ctx, "org_site", "S1")["record_id"]
    root = rec(ctx, "org_unit", "ROOT")
    a = rec(ctx, "org_unit", "A")
    assert %{"legal_entity_id" => ^le, "site_id" => ^site} = a
    pos = rec(ctx, "org_position", "P1")
    assert pos["org_unit_id"] == a["record_id"]
    emp = rec(ctx, "org_employee", "E1")

    assert %{"org_unit_id" => unit, "position_id" => position, "user_id" => user} = emp
    assert {unit, position, user} == {a["record_id"], pos["record_id"], ctx.user.id}
    assert path(ctx, root["record_id"]) == "/#{root["record_id"]}/"
    assert path(ctx, a["record_id"]) == "/#{root["record_id"]}/#{a["record_id"]}/"
  end

  test "P1: the same files again are unchanged and write no event or index row" do
    ctx = seeded("gh3599-p1")
    before = counts(ctx.schema)
    assert outcomes(units(ctx, unit_rows())) == ["unchanged", "unchanged", "unchanged"]
    assert outcomes(positions(ctx, [p("P1", "A", "P1")])) == ["unchanged"]

    assert outcomes(employees(ctx, [e("E1", "A", "P1", ctx.user.id, "E1")])) == ["unchanged"]
    assert counts(ctx.schema) == before
  end

  test "P2: a changed parent moves the unit and its subtree; active is refused" do
    ctx = seeded("gh3599-p2")
    assert outcomes(units(ctx, [u("A1", "A", "A1")])) == ["created"]
    conn = units(ctx, [u("A", "B", "A")])
    assert outcomes(conn) == ["updated"]
    b = rec(ctx, "org_unit", "B")["record_id"]
    a = rec(ctx, "org_unit", "A")
    assert a["parent"] == b
    a1 = rec(ctx, "org_unit", "A1")
    assert String.starts_with?(path(ctx, a1["record_id"]), path(ctx, b))
    assert path(ctx, a1["record_id"]) =~ a["record_id"]

    for {type, header, row} <- [
          {"org_unit", @unit_header, u("A", "B", "A")},
          {"org_position", @pos_header, p("P1", "A", "P1")},
          {"org_employee", @emp_header, e("E1", "A", "P1", ctx.user.id, "E1")}
        ] do
      conn = import_xlsx(ctx, type, header ++ ["active"], [row ++ [false]])

      assert [%{"reason" => %{"type" => "field_not_allowed", "header" => "active"}}] =
               results(conn)
    end
  end

  test "P3: changed names update; a changed unit or position transfers the employee" do
    ctx = seeded("gh3599-p3")
    assert outcomes(units(ctx, [u("A", "ROOT", "A", "Renamed")])) == ["updated"]
    assert %{"name" => "Renamed"} = rec(ctx, "org_unit", "A")
    assert outcomes(positions(ctx, [p("P1", "A", "P1", "Pos renamed")])) == ["updated"]
    assert %{"name" => "Pos renamed"} = rec(ctx, "org_position", "P1")

    conn = employees(ctx, [e("E1", "A", "P1", ctx.user.id, "E1", "Emp renamed")])
    assert outcomes(conn) == ["updated"]
    assert %{"full_name" => "Emp renamed"} = rec(ctx, "org_employee", "E1")

    conn = employees(ctx, [e("E1", "B", nil, ctx.user.id, "E1", "Emp renamed")])
    assert outcomes(conn) == ["updated"]
    emp = rec(ctx, "org_employee", "E1")
    assert emp["org_unit_id"] == rec(ctx, "org_unit", "B")["record_id"]
    refute Map.get(emp, "position_id")
  end

  test "F1: unknown references name their header and write nothing" do
    ctx = seeded("gh3599-f1")
    before = counts(ctx.schema)

    bad_le = ["Z", "Z", "NOPE", "S1", nil, "erp", "Z"]

    assert [%{"reason" => %{"type" => "reference_not_found", "header" => "legal_entity_id"}}] =
             results(units(ctx, [bad_le]))

    assert [%{"reason" => %{"type" => "reference_not_found", "header" => "position_id"}}] =
             results(employees(ctx, [e("E9", "A", "NOPE", nil, "E9")]))

    assert [%{"reason" => %{"type" => "reference_not_found", "header" => "org_unit_id"}}] =
             results(positions(ctx, [p("P9", "NOPE", "P9")]))

    assert counts(ctx.schema) == before
  end

  test "F2: write function refusals come back as constant reasons and write nothing" do
    ctx = seeded("gh3599-f2")
    assert outcomes(positions(ctx, [p("PB", "B", "PB")])) == ["created"]
    before = counts(ctx.schema)

    # position of another unit, user that is no user, a cycle, a changed code
    assert outcomes(employees(ctx, [e("E8", "A", "PB", nil, "E8")])) == ["position_not_in_unit"]

    assert outcomes(employees(ctx, [e("E8", "A", nil, Ecto.UUID.generate(), "E8")])) ==
             ["user_not_found"]

    assert outcomes(units(ctx, [u("ROOT", "A", "ROOT")])) == ["cycle"]

    conn = units(ctx, [u("A2", "ROOT", "A")])
    assert [%{"reason" => %{"type" => "field_not_allowed", "header" => "code"}}] = results(conn)

    conn = positions(ctx, [p("P1", "B", "P1")])

    assert [%{"reason" => %{"type" => "field_not_allowed", "header" => "org_unit_id"}}] =
             results(conn)

    assert counts(ctx.schema) == before
    assert %{"code" => "A"} = rec(ctx, "org_unit", "A")
  end

  test "F3: a retired-then-deleted target is reference_not_found" do
    ctx = seeded("gh3599-f3")
    a = rec(ctx, "org_unit", "A")

    Repo.update_all(
      from(l in Latest, where: l.record_id == ^a["record_id"]),
      [set: [deleted: true]],
      prefix: ctx.schema
    )

    assert [%{"reason" => %{"type" => "reference_not_found", "header" => "org_unit_id"}}] =
             results(positions(ctx, [p("P2", "A", "P2")]))
  end

  test "D1: a dry run answers as the real import and keeps nothing" do
    ctx = tenant_ctx("gh3599-d1")
    rows = [u("ROOT", nil, "ROOT"), u("X", "NOPE", "X"), u("A", "ROOT", "A")]
    before = counts(ctx.schema)
    dry = units(ctx, rows, "&dry_run=true")
    assert dry.status == 200, dry.resp_body
    assert Jason.decode!(dry.resp_body)["dry_run"] == true
    assert counts(ctx.schema) == before
    real = units(ctx, rows)
    assert outcomes(real) == ["created", "reference_not_found", "created"]
    assert shape(dry) == shape(real)
  end

  test "S1: an org-scoped caller is refused the upsert like an unmanaged type" do
    alias Letflow.Support.ScopeOnFixture, as: On

    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!("gh3599-s1")
    fx = %{tenant_id: tenant_id, schema_name: schema}
    :ok = On.store_mode!(fx, :on)
    user = On.scoped_holder!(fx, "TENANT_ADMIN")

    {:ok, _} =
      Letflow.Entities.Definitions.create_definition(
        %{
          definition: %{
            name: "plain_s",
            display_name: "plain_s",
            fields: [%{name: "title", type: :string, required: true}]
          },
          created_by: user.id
        },
        schema
      )

    {:ok, _} =
      Letflow.Entities.Definitions.activate_definition("plain_s", user.id, "gh3599", schema)

    call = fn type, row ->
      On.call(
        Letflow.Routers.Entities,
        :post,
        "/records/#{type}/import",
        fx,
        user.id,
        ["TENANT_ADMIN"],
        :on,
        %{
          "record_export_schema_version" => "entities/record-export/v1",
          "entity_type" => type,
          "upsert_by" => "external_ref",
          "records" => [row]
        }
      )
    end

    managed =
      call.("org_position", %{
        "external_ref" => %{"system" => "erp", "id" => "P1"},
        "field_values" => %{"code" => "P1", "name" => "P", "org_unit_id" => "A"}
      })

    plain =
      call.("plain_s", %{
        "external_ref" => %{"system" => "erp", "id" => "P1"},
        "field_values" => %{"title" => "t"}
      })

    assert managed.status == plain.status
    assert managed.status in 400..499
    assert Repo.aggregate(Latest, :count, prefix: schema) == 0
  end

  test "X1: ids that exist only in another tenant are reference_not_found" do
    a = seeded("gh3599-xa")
    b = tenant_ctx("gh3599-xb")
    before_a = counts(a.schema)
    before_b = counts(b.schema)
    assert outcomes(positions(b, [p("PX", "A", "PX")])) == ["reference_not_found"]
    assert outcomes(units(b, [u("Z", "ROOT", "Z")])) == ["reference_not_found"]
    assert counts(a.schema) == before_a
    assert counts(b.schema) == before_b
  end

  test "M2: the import files write only through the module's write functions" do
    root = Path.expand("../../../..", __DIR__)

    for file <- [
          "lib/letflow/modules/org/import.ex",
          "lib/letflow/modules/catalog_items/lot_import.ex"
        ] do
      src = File.read!(Path.join(root, file))

      for banned <-
            [
              "Records.",
              "Audit.",
              "ScopeNodePaths.",
              "owner_for!",
              "Repo.insert",
              "Repo.update",
              "Repo.delete"
            ],
          do: refute(src =~ banned, "#{file}: #{banned}")
    end

    src = File.read!(Path.join(root, "lib/letflow/modules/org/import.ex"))

    for fun <- [
          "create_unit(",
          "update_unit(",
          "move_unit(",
          "create_position(",
          "update_position(",
          "create_employee(",
          "update_employee(",
          "transfer_employee("
        ],
        do: assert(src =~ "Org." <> fun)
  end

  test "Q1: the scope declarations are unchanged" do
    assert Org.manifest().scope_declarations == %{
             "org_legal_entity" => :tenant_wide,
             "org_site" => :tenant_wide,
             "org_unit" => :tenant_wide,
             "org_position" => {:column, "org_unit_id"},
             "org_employee" => {:column, "org_unit_id"}
           }
  end
end
