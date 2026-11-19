Code.require_file("codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.ImportAssignmentTest do
  @moduledoc """
  G12 part 2 (GH #4568 / REQ-851): the import of `code_assignment` through the real core import route
  (`POST /api/v1/entities/records/code_assignment/import`, CSV, a real API-token bearer) on committed
  tenants with the real `codes`, `catalog_items`, `org` and `locations` modules installed.
  `async: false` (Sandbox `:auto`).

  A1 registration (criterion 1, with `import_test.exs` I1); A2 happy path and re-import; A3 refusals;
  A4 rule R4; A5 dry run and atomic; A6 access; A7 tenant isolation.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.CodesFixture, as: Fx
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Codes

  @header "code_id,target_type,target_id,external_ref_system,external_ref_id"

  defp tenant_ctx(prefix, roles \\ ["TENANT_ADMIN"], masters? \\ true) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh4568-#{Ecto.UUID.generate()}",
        display_name: "GH-4568 test user",
        email: "gh4568-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema)

    ctx = %{tenant_id: tenant_id, schema: schema, slug: slug, plaintext: plaintext}
    if masters?, do: masters!(ctx), else: ctx
  end

  defp tenant_ctx_token(ctx, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh4568-#{Ecto.UUID.generate()}",
        display_name: "GH-4568 test user",
        email: "gh4568-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema)

    %{ctx | plaintext: plaintext}
  end

  defp post_csv(ctx, type, csv, query) do
    conn(:post, "/api/v1/entities/records/#{type}/import?upsert_by=external_ref" <> query, csv)
    |> put_req_header("content-type", "text/csv")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp load!(ctx, type, header, lines) do
    conn = post_csv(ctx, type, Enum.join([header | lines], "\n") <> "\n", "")
    assert conn.status == 200, conn.resp_body
    assert Enum.all?(results(conn), &(&1["outcome"] == "created")), conn.resp_body
    results(conn)
  end

  # The masters of system "s": item ITEM-1 (active), INACT-1 (active false), place LOC-1, lot LOT-1.
  defp masters!(ctx) do
    Fx.install_module!(ctx.tenant_id, "catalog_items")
    Fx.install_module!(ctx.tenant_id, "org")
    Fx.install_module!(ctx.tenant_id, "locations")

    load!(ctx, "catalog_uom", "code,name,active,external_ref_system,external_ref_id", [
      "U1,Unit 1,true,s,U1"
    ])

    [%{"record_id" => i1}, _] =
      load!(
        ctx,
        "catalog_item",
        "code,name,base_uom_id,kind,active,external_ref_system,external_ref_id",
        [
          "ITEM-1,Item 1,U1,material,true,s,ITEM-1",
          "INACT-1,Inactive,U1,material,false,s,INACT-1"
        ]
      )

    load!(ctx, "location_node", "code,name,node_kind,external_ref_system,external_ref_id", [
      "LOC-1,Place 1,zone,s,LOC-1"
    ])

    load!(ctx, "catalog_lot", "item_id,code,external_ref_system,external_ref_id", [
      "ITEM-1,LOT-1,s,LOT-1"
    ])

    Map.put(ctx, :item_record_id, i1)
  end

  defp receive!(ctx, values) do
    lines = Enum.with_index(values, 1) |> Enum.map(fn {v, i} -> "#{v},barcode,s,C#{i}-#{v}" end)

    conn =
      post_csv(
        ctx,
        "code_tag",
        Enum.join(["value,kind,external_ref_system,external_ref_id" | lines], "\n") <> "\n",
        ""
      )

    assert conn.status == 200, conn.resp_body
  end

  defp import_csv(ctx, lines, query \\ "") do
    post_csv(ctx, "code_assignment", Enum.join([@header | lines], "\n") <> "\n", query)
  end

  defp results(conn), do: Jason.decode!(conn.resp_body)["results"]
  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))

  defp assignment_rows(schema),
    do: Repo.all(from(l in Latest, where: l.entity_type == "code_assignment"), prefix: schema)

  defp audit_count(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".audit_entries WHERE action = 'code.assigned'|
      )

    n
  end

  defp status(schema, v), do: Codes.resolve(schema, v)

  @good [
    "V1,catalog_item,ITEM-1,s,R1",
    "V2,location_node,LOC-1,s,R2",
    "V3,catalog_lot,LOT-1,s,R3"
  ]

  describe "A1 registration" do
    test "code_assignment has an import function; pack.json is the generated one" do
      assert Catalog.import_function("codes", "code_assignment") == :ok
      assert Codes.manifest().version == "0.7.0"

      assert {"codes", "code_assignment"} in Enum.map(
               Codes.manifest().import_functions,
               &{"codes", &1.entity_type}
             )
    end
  end

  describe "A2 happy path" do
    test "three rows assign three codes with three audit entries; re-import is unchanged" do
      ctx = tenant_ctx("g12g")
      receive!(ctx, ~w(V1 V2 V3))

      conn = import_csv(ctx, @good)
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["created", "created", "created"]

      lookup = fn type, ext ->
        {:ok, t} =
          Letflow.Modules.ReadApi.lookup_by_external_ref(ctx.schema, type, "s", ext, [type])

        t["record_id"]
      end

      assert {:ok, %{"status" => "assigned", "target_id" => t1}} = status(ctx.schema, "V1")
      assert {:ok, %{"status" => "assigned", "target_id" => t2}} = status(ctx.schema, "V2")
      assert {:ok, %{"status" => "assigned", "target_id" => t3}} = status(ctx.schema, "V3")
      assert t1 == lookup.("catalog_item", "ITEM-1")
      assert t2 == lookup.("location_node", "LOC-1")
      assert t3 == lookup.("catalog_lot", "LOT-1")
      assert length(assignment_rows(ctx.schema)) == 3
      assert audit_count(ctx.schema) == 3

      again = import_csv(ctx, @good)
      assert again.status == 200
      assert outcomes(again) == ["unchanged", "unchanged", "unchanged"]
      assert length(assignment_rows(ctx.schema)) == 3
      assert audit_count(ctx.schema) == 3
    end
  end

  describe "A3 refusals and A4 rule R4" do
    test "each refusal is its own row, nothing written, no cell echoed; at most one open row" do
      ctx = tenant_ctx("g12h")
      receive!(ctx, ~w(V1 V2 V3 V4 V5))
      assert outcomes(import_csv(ctx, @good)) == ["created", "created", "created"]
      {:ok, %{"code_id" => v5}} = status(ctx.schema, "V5")

      {:ok, _} =
        Codes.retire_code(ctx.schema, v5, %{
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        })

      rows_before = length(assignment_rows(ctx.schema))
      audit_before = audit_count(ctx.schema)

      csv = [
        "SECRET-NOCODE,catalog_item,ITEM-1,s,X1",
        "V4,catalog_item,SECRET-NOITEM,s,X2",
        "V4,catalog_item,#{ctx.item_record_id},s,X3",
        "V4,catalog_item,INACT-1,s,X4",
        "V4,org_unit,ITEM-1,s,X5",
        "V5,catalog_item,ITEM-1,s,X6",
        "V1,location_node,LOC-1,s,X7"
      ]

      conn = import_csv(ctx, csv)
      assert conn.status == 200, conn.resp_body

      assert [
               %{"reason" => %{"type" => "reference_not_found", "header" => "code_id"}},
               %{"reason" => %{"type" => "reference_not_found", "header" => "target_id"}},
               %{"reason" => %{"type" => "reference_not_found", "header" => "target_id"}},
               %{"reason" => %{"type" => "reference_inactive", "header" => "target_id"}},
               %{"reason" => %{"type" => "target_type_not_allowed"}},
               %{"reason" => %{"type" => "code_retired"}},
               %{"reason" => %{"type" => "code_assigned"}}
             ] = results(conn)

      refute conn.resp_body =~ "SECRET-NOCODE"
      refute conn.resp_body =~ "SECRET-NOITEM"
      refute conn.resp_body =~ ctx.item_record_id

      server_cell =
        post_csv(
          ctx,
          "code_assignment",
          "code_id,target_type,target_id,assigned_by,external_ref_system,external_ref_id\n" <>
            "V4,catalog_item,ITEM-1,SECRET-ACTOR,s,X8\n",
          ""
        )

      assert server_cell.status == 200, server_cell.resp_body
      [%{"reason" => reason}] = results(server_cell)
      assert reason == %{"type" => "field_not_allowed", "header" => "assigned_by"}
      refute server_cell.resp_body =~ "SECRET-ACTOR"

      assert length(assignment_rows(ctx.schema)) == rows_before
      assert audit_count(ctx.schema) == audit_before
      assert {:ok, %{"status" => "not_assigned"}} = status(ctx.schema, "V4")

      open =
        assignment_rows(ctx.schema)
        |> Enum.filter(&is_nil(&1.field_values["released_at"]))
        |> Enum.frequencies_by(& &1.field_values["code_id"])

      assert Enum.all?(open, fn {_code, n} -> n <= 1 end)
    end
  end

  describe "A5 dry run and atomic" do
    test "dry run reports created and keeps nothing; atomic with a bad row writes nothing" do
      ctx = tenant_ctx("g12i")
      receive!(ctx, ~w(V1 V2 V3))

      dry = import_csv(ctx, @good, "&dry_run=true")
      assert dry.status == 200, dry.resp_body
      assert outcomes(dry) == ["created", "created", "created"]
      assert assignment_rows(ctx.schema) == []
      assert audit_count(ctx.schema) == 0
      assert {:ok, %{"status" => "not_assigned"}} = status(ctx.schema, "V1")

      atomic =
        import_csv(
          ctx,
          ["V1,catalog_item,ITEM-1,s,A1", "NOPE,catalog_item,ITEM-1,s,A2"],
          "&atomic=true"
        )

      assert atomic.status == 200, atomic.resp_body
      assert assignment_rows(ctx.schema) == []
      assert audit_count(ctx.schema) == 0
      assert {:ok, %{"status" => "not_assigned"}} = status(ctx.schema, "V1")
    end
  end

  describe "A6 access" do
    test "a STOREKEEPER is refused and nothing is written" do
      ctx = tenant_ctx("g12j")
      receive!(ctx, ~w(V1 V2 V3))
      keeper = tenant_ctx_token(ctx, ["STOREKEEPER"])

      conn = import_csv(keeper, @good)
      assert conn.status == 403
      assert conn.resp_body =~ "insufficient permissions"
      assert assignment_rows(ctx.schema) == []
      assert audit_count(ctx.schema) == 0
    end
  end

  describe "A7 tenant isolation (INV-1)" do
    test "values and external ids that exist only in tenant A are unknown in B" do
      a = tenant_ctx("g12k")
      b = tenant_ctx("g12l", ["TENANT_ADMIN"], false)
      receive!(a, ~w(V1 V2 V3))

      conn = import_csv(b, @good)
      assert conn.status == 200, conn.resp_body

      assert Enum.all?(
               results(conn),
               &(&1["reason"] == %{"type" => "reference_not_found", "header" => "code_id"})
             )

      assert assignment_rows(a.schema) == []
      assert assignment_rows(b.schema) == []
      assert audit_count(a.schema) == 0
      assert audit_count(b.schema) == 0
    end
  end
end
