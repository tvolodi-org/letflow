Code.require_file("locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Locations.TreeAuditTest do
  @moduledoc """
  GH #3741 / REQ-705: one audit entry for every accepted write of the location tree
  (`location_node.created|updated|moved|retired`), imported rows included, on fresh tenants.

  E1..E4 entries per write (criterion 1); A1..A4 same transaction (2); N1..N3 no entry without a
  change (3); I1/I2 import (4); R1/R2 readable through GET /audit, cross-tenant (5).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test
  import Letflow.LocationsFixture

  alias Letflow.Audit.Entry
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Locations
  alias Letflow.XlsxFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @header ["code", "name", "node_kind", "parent_id", "external_ref_system", "external_ref_id"]

  setup do
    {:ok, installed_tenant!("gh3741-ta")}
  end

  defp opts(actor \\ Ecto.UUID.generate()),
    do: %{actor_id: actor, idempotency_key: Ecto.UUID.generate()}

  defp mk!(schema, code, parent \\ nil) do
    attrs = %{"code" => code, "name" => "N #{code}", "node_kind" => "zone"}
    attrs = if parent, do: Map.put(attrs, "parent_id", parent["record_id"]), else: attrs
    {:ok, node} = Locations.create_node(schema, attrs, opts())
    node
  end

  defp entries(schema) do
    Repo.all(
      from(a in Entry, where: like(a.action, "location_node.%"), order_by: a.timestamp),
      prefix: schema
    )
  end

  defp actions(schema), do: Enum.map(entries(schema), & &1.action)

  defp stored(schema, id) do
    {:ok, %Latest{field_values: fv}} = Latest.get(id, "location_node", schema)
    fv
  end

  describe "criterion 1: entries per write" do
    test "E1: create writes location_node.created with before nil", %{schema: schema} do
      actor = Ecto.UUID.generate()

      {:ok, node} =
        Locations.create_node(
          schema,
          %{"code" => "E1", "name" => "One", "node_kind" => "zone"},
          opts(actor)
        )

      assert [e] = entries(schema)
      assert e.action == "location_node.created"
      assert e.resource_type == "location_node"
      assert e.resource_id == node["record_id"]
      assert e.actor_id == actor
      assert e.before_state == nil
      assert e.after_state == stored(schema, node["record_id"])
      assert e.after_state["code"] == "E1"
    end

    test "E2: update writes location_node.updated with both states", %{schema: schema} do
      node = mk!(schema, "E2")
      before = stored(schema, node["record_id"])
      {:ok, _} = Locations.update_node(schema, node["record_id"], %{"name" => "Renamed"}, opts())

      assert [_, e] = entries(schema)
      assert e.action == "location_node.updated"
      assert e.resource_id == node["record_id"]
      assert e.before_state == before
      assert e.after_state["name"] == "Renamed"
      assert e.after_state == stored(schema, node["record_id"])
    end

    test "E3: move writes location_node.moved, states differ in parent_id", %{schema: schema} do
      a = mk!(schema, "E3A")
      b = mk!(schema, "E3B")
      {:ok, _} = Locations.move_node(schema, b["record_id"], a["record_id"], opts())

      e = List.last(entries(schema))
      assert e.action == "location_node.moved"
      assert e.resource_id == b["record_id"]
      refute e.before_state["parent_id"]
      assert e.after_state["parent_id"] == a["record_id"]
    end

    test "E4: retire writes location_node.retired with active false", %{schema: schema} do
      node = mk!(schema, "E4")
      {:ok, _} = Locations.retire_node(schema, node["record_id"], opts())

      e = List.last(entries(schema))
      assert e.action == "location_node.retired"
      assert e.before_state["active"] == true
      assert e.after_state["active"] == false
    end
  end

  describe "criterion 2: same transaction" do
    setup %{schema: schema} do
      node = mk!(schema, "A-BASE")
      other = mk!(schema, "A-OTHER")
      Repo.query!(~s(DROP TABLE "#{schema}".audit_entries))
      %{node: node, other: other}
    end

    test "A1: create is rolled back", %{schema: schema} do
      assert {:error, :audit_failed} =
               Locations.create_node(
                 schema,
                 %{"code" => "A1", "name" => "x", "node_kind" => "zone"},
                 opts()
               )

      refute Repo.exists?(
               from(t in "entity_location_node", where: t.code == "A1", select: 1),
               prefix: schema
             )
    end

    test "A2: update is rolled back", %{schema: schema, node: node} do
      assert {:error, :audit_failed} =
               Locations.update_node(schema, node["record_id"], %{"name" => "Changed"}, opts())

      assert stored(schema, node["record_id"])["name"] == node["name"]
    end

    test "A3: move is rolled back", %{schema: schema, node: node, other: other} do
      assert {:error, :audit_failed} =
               Locations.move_node(schema, node["record_id"], other["record_id"], opts())

      refute stored(schema, node["record_id"])["parent_id"]
    end

    test "A4: retire is rolled back", %{schema: schema, node: node} do
      assert {:error, :audit_failed} = Locations.retire_node(schema, node["record_id"], opts())
      assert stored(schema, node["record_id"])["active"] == true
    end
  end

  describe "criterion 3: no entry without a change" do
    test "N1: refused calls write no entry", %{schema: schema} do
      node = mk!(schema, "N1")
      n = length(entries(schema))
      missing = Ecto.UUID.generate()

      assert {:error, :parent_not_found} =
               Locations.create_node(
                 schema,
                 %{"code" => "N1X", "name" => "x", "node_kind" => "z", "parent_id" => missing},
                 opts()
               )

      assert {:error, {:field_not_allowed, "bogus"}} =
               Locations.create_node(
                 schema,
                 %{"code" => "N1Y", "name" => "x", "node_kind" => "z", "bogus" => 1},
                 opts()
               )

      assert {:error, :node_not_found} =
               Locations.update_node(schema, missing, %{"name" => "x"}, opts())

      assert {:error, :node_not_found} = Locations.move_node(schema, missing, nil, opts())
      assert {:error, :node_not_found} = Locations.retire_node(schema, missing, opts())

      child = mk!(schema, "N1C", node)
      n = n + 1

      assert {:error, :cycle} =
               Locations.move_node(schema, node["record_id"], child["record_id"], opts())

      assert length(entries(schema)) == n
    end

    test "N2: a no-op move or retire writes no entry", %{schema: schema} do
      parent = mk!(schema, "N2P")
      child = mk!(schema, "N2C", parent)
      n = length(entries(schema))

      assert {:ok, _} =
               Locations.move_node(schema, child["record_id"], parent["record_id"], opts())

      assert length(entries(schema)) == n

      {:ok, _} = Locations.retire_node(schema, child["record_id"], opts())
      assert length(entries(schema)) == n + 1
      assert {:ok, _} = Locations.retire_node(schema, child["record_id"], opts())
      assert length(entries(schema)) == n + 1
    end

    test "N3: a replay with the same key writes no second entry", %{schema: schema} do
      o = opts()
      attrs = %{"code" => "N3", "name" => "x", "node_kind" => "zone"}
      {:ok, first} = Locations.create_node(schema, attrs, o)
      n = length(entries(schema))
      assert {:ok, again} = Locations.create_node(schema, attrs, o)
      assert again["record_id"] == first["record_id"]
      assert length(entries(schema)) == n

      u = opts()
      {:ok, _} = Locations.update_node(schema, first["record_id"], %{"name" => "y"}, u)
      n = length(entries(schema))
      assert {:ok, _} = Locations.update_node(schema, first["record_id"], %{"name" => "y"}, u)
      assert length(entries(schema)) == n
    end
  end

  # ── import (criterion 4) and read (criterion 5) ────────────────────────────────

  defp tenant_ctx(prefix) do
    %{tenant_id: tenant_id, schema: schema} = installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3741-user-#{Ecto.UUID.generate()}",
        display_name: "GH-3741 test user",
        email: "gh3741-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    %{schema: schema, slug: slug, plaintext: plaintext, actor: user.id}
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

  defp r(code, name, parent, id), do: [code, name, "zone", parent, "erp", id]

  defp audit_items(ctx) do
    conn = conn(:get, "/api/v1/audit?resource_type=location_node&page_size=200") |> authed(ctx)
    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)["items"]
  end

  describe "criterion 4: imported rows" do
    test "I1: created, updated and moved rows are audited" do
      ctx = tenant_ctx("gh3741-i1")

      assert import_xlsx(ctx, [r("W", "Warehouse", "", "W"), r("A", "Aisle", "", "A")]).status ==
               200

      assert actions(ctx.schema) == ["location_node.created", "location_node.created"]

      conn =
        import_xlsx(ctx, [
          r("W", "Warehouse", "", "W"),
          r("A", "Aisle renamed", "W", "A"),
          r("B", "Bay", "", "B"),
          r("C", "Cage", "", "C")
        ])

      assert conn.status == 200, conn.resp_body
      acts = actions(ctx.schema)
      assert Enum.count(acts, &(&1 == "location_node.created")) == 4
      assert Enum.count(acts, &(&1 == "location_node.updated")) == 1
      assert Enum.count(acts, &(&1 == "location_node.moved")) == 1
      assert length(acts) == 6
      assert Enum.all?(entries(ctx.schema), &(&1.actor_id == ctx.actor))
    end

    test "I2: an unchanged row and a dry run write no entry" do
      ctx = tenant_ctx("gh3741-i2")
      rows = [r("W", "Warehouse", "", "W")]
      assert import_xlsx(ctx, rows).status == 200
      n = length(entries(ctx.schema))
      assert import_xlsx(ctx, rows).status == 200
      assert length(entries(ctx.schema)) == n

      dry = import_xlsx(ctx, rows ++ [r("Z", "Zone", "", "Z")], "&dry_run=true")
      assert dry.status == 200
      assert length(entries(ctx.schema)) == n
    end
  end

  describe "criterion 5: readable" do
    test "R1/R2: GET /audit shows the entries to the tenant, none to another tenant" do
      a = tenant_ctx("gh3741-ra")
      b = tenant_ctx("gh3741-rb")
      assert import_xlsx(a, [r("W", "Warehouse", "", "W")]).status == 200

      assert [item] = audit_items(a)
      assert item["action"] == "location_node.created"
      assert item["resource_type"] == "location_node"
      assert audit_items(b) == []
    end
  end
end
