defmodule Letflow.Routers.ImportAnyTypeRouteTest do
  @moduledoc """
  Roles stage 0 S0-1: `POST /api/v1/entities/records/:entity_type/import` for a generic type
  decides by `EntitiesRecordsImport` and `EntitiesRecordsImportAnyType`, not by a role name.
  Full pipeline with a real API token, real Postgres (`async: false`, sandbox `:auto`).

    * R1 TENANT_ADMIN imports (allowed);
    * R2 TENANT_ADMIN + STOREKEEPER imports (allowed, STOREKEEPER does not narrow);
    * R3 STOREKEEPER alone is refused, nothing written;
    * R4 STOREKEEPER + a role with neither atom is refused, nothing written;
    * R5 a role without Import is refused at the route gate.

  Scope enforcement is off here; the scope set is proven in `ImportAnyTypeScopeTest`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    :ok
  end

  defp tenant_ctx(slug_prefix, roles) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "t1853-user-#{Ecto.UUID.generate()}",
        display_name: "T-1853 test user",
        email: "t1853-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    ctx = %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }

    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{
            name: "item",
            display_name: "item",
            fields: [%{name: "title", type: :string, required: true}]
          },
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition("item", ctx.user_id, "t1853", ctx.schema_name)
    ctx
  end

  defp import!(ctx) do
    body = %{
      "record_export_schema_version" => "entities/record-export/v1",
      "entity_type" => "item",
      "records" => [%{"field_values" => %{"title" => "One"}}]
    }

    conn(:post, "/api/v1/entities/records/item/import", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp rows(ctx) do
    Repo.all(from(l in Latest, where: l.entity_type == "item"), prefix: ctx.schema_name)
  end

  test "R1 TENANT_ADMIN imports a generic type" do
    ctx = tenant_ctx("t1853-r1", ["TENANT_ADMIN"])
    conn = import!(ctx)
    assert conn.status == 200
    assert [%{"status" => "ok"}] = Jason.decode!(conn.resp_body)["results"]
    assert length(rows(ctx)) == 1
  end

  test "R2 TENANT_ADMIN with STOREKEEPER still imports" do
    ctx = tenant_ctx("t1853-r2", ["TENANT_ADMIN", "STOREKEEPER"])
    assert import!(ctx).status == 200
    assert length(rows(ctx)) == 1
  end

  test "R3 STOREKEEPER alone is refused and nothing is written" do
    ctx = tenant_ctx("t1853-r3", ["STOREKEEPER"])
    assert import!(ctx).status == 403
    assert rows(ctx) == []
  end

  test "R4 STOREKEEPER with a role that holds neither atom is refused" do
    ctx = tenant_ctx("t1853-r4", ["STOREKEEPER", "PROCESS_OPERATOR"])
    assert import!(ctx).status == 403
    assert rows(ctx) == []
  end

  test "R5 a role without Import is refused at the route gate" do
    ctx = tenant_ctx("t1853-r5", ["PROCESS_OPERATOR"])
    assert import!(ctx).status == 403
    assert rows(ctx) == []
  end
end
