Code.require_file("../org/org_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.ProcurementFixture do
  @moduledoc """
  GH #3162 / REQ-544 part 2 test fixture: a provisioned tenant with `org`, `catalog_items` and
  `procurement` installed, one department (also a scope node) and one unit, plus helpers to make
  an issued purchase request and a tenant user with a real bearer token.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.CatalogItemsFixture
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Procurement.PurchaseRequests
  alias Letflow.OrgFixture
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @install_opts Letflow.Routers.TenantModules.init([])

  @doc "Provisions the tenant and registers the cleanup of its module install rows (call from `setup`)."
  def tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    schema = tenant.schema_name
    {:ok, _} = Letflow.Entities.EventTypes.seed!(schema)

    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    for id <- ["org", "catalog_items", "procurement"], do: install!(tenant.tenant_id, id)

    dept = OrgFixture.create!(schema, "org_unit", OrgFixture.values("org_unit", "D1"))
    {:ok, _} = ScopeNodePaths.write({:insert, dept.record_id, nil}, schema)
    uom = CatalogItemsFixture.uom!(schema, "PCS")

    %{
      schema: schema,
      tenant_id: tenant.tenant_id,
      slug: Repo.get!(Tenant, tenant.tenant_id).slug,
      dept: dept.record_id,
      uom: uom.record_id
    }
  end

  defp install!(tenant_id, module_id) do
    conn =
      Plug.Test.conn(:post, "/")
      |> Map.put(:body_params, %{"module_id" => module_id, "rationale" => "GH-3162 test install"})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> Plug.Conn.assign(:trace_id, "gh3162-procurement-trace")
      |> Letflow.Routers.TenantModules.call(@install_opts)

    if conn.status != 201,
      do: raise("#{module_id} install failed: #{conn.status} #{conn.resp_body}")
  end

  def params(ctx, overrides \\ %{}) do
    line = %{
      "kind" => "material",
      "description" => "Bolts",
      "quantity" => "3",
      "unit_id" => ctx.uom,
      "estimated_unit_cost" => "0.10"
    }

    Map.merge(
      %{
        "department_id" => ctx.dept,
        "justification" => "Needed",
        "required_date" => "2027-03-01",
        "priority" => "high",
        "lines" => [line]
      },
      overrides
    )
  end

  @doc "Creates and submits a request for `requester`; returns `%{id, version_no, hash}`."
  def issued!(ctx, requester) do
    {:ok, %{document_id: id}} = PurchaseRequests.create(ctx.schema, requester, params(ctx))

    {:ok, %{version_no: n, content_hash: hash}} =
      PurchaseRequests.submit_for_bpm(ctx.schema, requester, %{
        document_id: id,
        version_no: 1,
        content_hash: nil,
        idempotency_key: "submit-" <> Ecto.UUID.generate()
      })

    %{id: id, version_no: n, hash: hash}
  end

  @doc "A tenant user with a real token for `roles`: `%{user_id, plaintext, slug}`."
  def user!(ctx, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3162-user-#{Ecto.UUID.generate()}",
        display_name: "Procurement Test User",
        email: "gh3162-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema)

    %{user_id: user.id, plaintext: plaintext, slug: ctx.slug}
  end
end
