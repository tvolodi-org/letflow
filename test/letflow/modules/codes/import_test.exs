Code.require_file("codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.ImportTest do
  @moduledoc """
  G12 part 1 (GH #4569 / REQ-850): the import of `code_tag` through the real core import route
  (`POST /api/v1/entities/records/code_tag/import`, CSV, a real API-token bearer) on committed tenants
  with the real `codes` module installed. `async: false` (Sandbox `:auto`).

  I1 registration; I2 happy path and re-import; I3 refusals; I4 dry run and atomic; I5 access;
  I6 tenant isolation.
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

  @header "value,kind,external_ref_system,external_ref_id"

  defp tenant_ctx(prefix, roles \\ ["TENANT_ADMIN"]) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    token_ctx(tenant_id, schema, roles)
  end

  defp token_ctx(tenant_id, schema, roles) do
    slug = Repo.get!(Tenant, tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh4569-#{Ecto.UUID.generate()}",
        display_name: "GH-4569 test user",
        email: "gh4569-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema)

    %{tenant_id: tenant_id, schema: schema, slug: slug, plaintext: plaintext}
  end

  defp import_csv(ctx, lines, query \\ "") do
    csv = Enum.join([@header | lines], "\n") <> "\n"

    conn(:post, "/api/v1/entities/records/code_tag/import?upsert_by=external_ref" <> query, csv)
    |> put_req_header("content-type", "text/csv")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp results(conn), do: Jason.decode!(conn.resp_body)["results"]
  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))

  defp tag_count(schema),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == "code_tag"), :count,
        prefix: schema
      )

  defp audit_count(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".audit_entries WHERE action = 'code.received'|
      )

    n
  end

  @good [
    "4870001112223,barcode,s,R1",
    "QR-0001,qr,s,R2",
    "2000000000015,barcode,s,R3"
  ]

  describe "I1 registration" do
    test "code_tag and code_assignment have an import function, code_value_change has none, pack and floor unchanged" do
      assert Catalog.import_function("codes", "code_tag") == :ok
      assert Catalog.import_function("codes", "code_assignment") == :ok
      assert Catalog.import_function("codes", "code_value_change") == {:error, :not_found}
      assert Codes.manifest().version == "0.7.0"
      assert Codes.manifest().min_upgradable_from == "0.1.0"

      assert Codes.manifest().import_functions == [
               %{entity_type: "code_tag", function: :import_code_tag},
               %{entity_type: "code_assignment", function: :import_code_assignment}
             ]
    end
  end

  describe "I2 happy path" do
    test "three rows are created not_assigned with three audit entries; re-import is unchanged" do
      ctx = tenant_ctx("g12a")

      conn = import_csv(ctx, @good)
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["created", "created", "created"]

      for {v, k} <- [
            {"4870001112223", "barcode"},
            {"QR-0001", "qr"},
            {"2000000000015", "barcode"}
          ] do
        assert {:ok, %{"kind" => ^k, "status" => "not_assigned"}} = Codes.resolve(ctx.schema, v)
      end

      assert tag_count(ctx.schema) == 3
      assert audit_count(ctx.schema) == 3

      again = import_csv(ctx, @good)
      assert again.status == 200
      assert outcomes(again) == ["unchanged", "unchanged", "unchanged"]
      assert tag_count(ctx.schema) == 3
      assert audit_count(ctx.schema) == 3
    end
  end

  describe "I3 refusals" do
    test "value_taken, value_invalid, kind_invalid, field_not_allowed; nothing written, no echo" do
      ctx = tenant_ctx("g12b")
      assert import_csv(ctx, @good).status == 200
      before_tags = tag_count(ctx.schema)
      before_audit = audit_count(ctx.schema)

      csv = [
        "4870001112223,qr,s,X1",
        ",barcode,s,X2",
        "SECRET-KIND-9,ean13,s,X3"
      ]

      conn = import_csv(ctx, csv)
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["value_taken", "value_invalid", "kind_invalid"]
      refute conn.resp_body =~ "4870001112223"
      refute conn.resp_body =~ "SECRET-KIND-9"
      refute conn.resp_body =~ "ean13"

      status_csv =
        "value,kind,status,external_ref_system,external_ref_id\nST-1,barcode,assigned,s,X4\n"

      sconn =
        conn(:post, "/api/v1/entities/records/code_tag/import?upsert_by=external_ref", status_csv)
        |> put_req_header("content-type", "text/csv")
        |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
        |> put_req_header("x-tenant-slug", ctx.slug)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      assert sconn.status == 200, sconn.resp_body
      [%{"reason" => reason}] = results(sconn)
      assert reason == %{"type" => "field_not_allowed", "header" => "status"}
      refute sconn.resp_body =~ "ST-1"

      assert tag_count(ctx.schema) == before_tags
      assert audit_count(ctx.schema) == before_audit
    end
  end

  describe "I4 dry run and atomic" do
    test "dry run reports created and keeps nothing; atomic with a bad row writes nothing" do
      ctx = tenant_ctx("g12c")

      dry = import_csv(ctx, @good, "&dry_run=true")
      assert dry.status == 200, dry.resp_body
      assert outcomes(dry) == ["created", "created", "created"]
      assert tag_count(ctx.schema) == 0
      assert audit_count(ctx.schema) == 0

      atomic = import_csv(ctx, ["GOOD-1,barcode,s,A1", "BAD-1,ean13,s,A2"], "&atomic=true")
      assert atomic.status == 200, atomic.resp_body
      assert tag_count(ctx.schema) == 0
      assert audit_count(ctx.schema) == 0
    end
  end

  describe "I5 access" do
    test "a STOREKEEPER is refused and nothing is written" do
      ctx = tenant_ctx("g12d", ["STOREKEEPER"])
      conn = import_csv(ctx, @good)
      assert conn.status == 403
      assert conn.resp_body =~ "insufficient permissions"
      assert tag_count(ctx.schema) == 0
      assert audit_count(ctx.schema) == 0
    end
  end

  describe "I6 tenant isolation (INV-1)" do
    test "a value imported in A is a new code in B; A is unchanged by the import into B" do
      a = tenant_ctx("g12e")
      b = tenant_ctx("g12f")

      assert outcomes(import_csv(a, @good)) == ["created", "created", "created"]
      assert tag_count(a.schema) == 3

      conn = import_csv(b, @good)
      assert outcomes(conn) == ["created", "created", "created"]
      assert tag_count(b.schema) == 3
      assert tag_count(a.schema) == 3
      assert audit_count(a.schema) == 3
    end
  end
end
