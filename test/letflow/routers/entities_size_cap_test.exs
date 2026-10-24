defmodule Letflow.Routers.EntitiesSizeCapTest do
  @moduledoc """
  GH #2689 / REQ-514 -- the entity-side size cap through the generic HTTP routes and the import
  route: an explicit 422 with a constant detail (no field name, no size), and a per-entry
  `record_size_exceeded` reason on import. Full pipeline like `Letflow.Routers.EntitiesTest`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)
  defp str(bytes), do: String.duplicate("x", bytes - 2)

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2689-http")
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2689-user-#{Ecto.UUID.generate()}",
        display_name: "GH-2689 test user",
        email: "gh2689-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    ctx = %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }

    fields = [
      %{name: "title", type: :string, required: true},
      %{name: "blob", type: :string, required: false}
    ]

    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{name: "widget", display_name: "Widget", fields: fields},
          created_by: user.id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition("widget", user.id, "go-live", ctx.schema_name)
    {:ok, ctx: ctx}
  end

  defp post_record(ctx, fv),
    do: request(:post, "/api/v1/entities/records/widget", ctx, %{"field_values" => fv})

  test "G1 POST: a value at the cap is created, one byte over is 422 with a constant body", %{
    ctx: ctx
  } do
    assert post_record(ctx, %{"title" => "t", "blob" => str(65_536)}).status == 201

    conn = post_record(ctx, %{"title" => "t", "blob" => str(65_537)})
    assert conn.status == 422
    body = body_of(conn)
    assert body["detail"] == "an entity record field value exceeds the size limit"
    assert Map.get(body, "errors", []) == []
    refute conn.resp_body =~ "blob"
    refute conn.resp_body =~ "xxxx"
  end

  test "G1 POST: a record over the record cap is 422 (record detail)", %{ctx: ctx} do
    fv = %{"title" => str(65_536), "blob" => str(65_536)}
    assert post_record(ctx, fv).status == 201

    # two fields cannot exceed 256 KiB, so the record cap needs a wider definition: the whole map
    # of a single oversize value reports the record first
    conn = post_record(ctx, %{"title" => "t", "blob" => str(300_000)})
    assert conn.status == 422
    assert body_of(conn)["detail"] == "entity record exceeds the size limit"
  end

  test "G1 PUT: an update with an oversize value is 422", %{ctx: ctx} do
    created = post_record(ctx, %{"title" => "t"}) |> body_of()
    id = created["record_id"]

    conn =
      request(:put, "/api/v1/entities/records/widget/#{id}", ctx, %{
        "field_values" => %{"title" => "t", "blob" => str(65_537)}
      })

    assert conn.status == 422
    assert body_of(conn)["detail"] == "an entity record field value exceeds the size limit"

    ok =
      request(:put, "/api/v1/entities/records/widget/#{id}", ctx, %{
        "field_values" => %{"title" => "t", "blob" => str(65_536)}
      })

    assert ok.status == 200
  end

  test "G2 import: an oversize entry fails alone, the others commit", %{ctx: ctx} do
    conn =
      request(:post, "/api/v1/entities/records/widget/import", ctx, %{
        "record_export_schema_version" => "entities/record-export/v1",
        "entity_type" => "widget",
        "records" => [
          %{"record_id" => "src-1", "field_values" => %{"title" => "a"}},
          %{"record_id" => "src-2", "field_values" => %{"title" => "b", "blob" => str(65_537)}},
          %{"record_id" => "src-3", "field_values" => %{"title" => "c", "blob" => str(65_536)}}
        ]
      })

    assert conn.status == 200

    assert [
             %{"status" => "ok"},
             %{"status" => "error", "reason" => %{"type" => "record_size_exceeded"} = reason},
             %{"status" => "ok"}
           ] = body_of(conn)["results"]

    assert reason["limit"] == "value"
    refute conn.resp_body =~ "xxxx"
  end
end
