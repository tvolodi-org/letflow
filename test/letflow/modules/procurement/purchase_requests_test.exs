Code.require_file("../org/org_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.Procurement.PurchaseRequestsTest do
  @moduledoc """
  GH #3162 / REQ-544 part 1, criteria 1, 2, 3, 4 and the requester half of 10 (spec:
  state/tasks/T-0745/design.md, tests T-C1..T-C4, T-D1..T-D4, T-O1, T-X1, T-I1): the operations of
  `Letflow.Modules.Procurement.PurchaseRequests` on real tenants with `org`, `catalog_items` and
  `procurement` installed.

  The department is created twice, as the real `org_unit` record and as a scope node, because
  `Letflow.Documents` checks the scope tree and nothing in the product writes a scope node for an
  org unit yet (reported as a core gap in the task summary).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.CatalogItemsFixture
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Documents
  alias Letflow.Documents.Canonical
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Procurement.PurchaseRequests
  alias Letflow.OrgFixture
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @install_opts Letflow.Routers.TenantModules.init([])

  setup do
    tenant = tenant!("gh3162")
    schema = tenant.schema_name
    {:ok, _} = Letflow.Entities.EventTypes.seed!(schema)

    for id <- ["org", "catalog_items", "procurement"], do: install!(tenant.tenant_id, id)

    dept = OrgFixture.create!(schema, "org_unit", OrgFixture.values("org_unit", "D1"))
    {:ok, _} = ScopeNodePaths.write({:insert, dept.record_id, nil}, schema)
    uom = CatalogItemsFixture.uom!(schema, "PCS")

    %{
      schema: schema,
      tenant_id: tenant.tenant_id,
      dept: dept.record_id,
      uom: uom.record_id,
      actor: Ecto.UUID.generate()
    }
  end

  # Module installs leave pack rows that reference the tenant; remove them before the tenant goes.
  defp tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    tenant
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

  defp line(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "material",
        "description" => "Bolts",
        "quantity" => "3",
        "unit_id" => ctx.uom,
        "estimated_unit_cost" => "0.10"
      },
      overrides
    )
  end

  defp params(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "department_id" => ctx.dept,
        "justification" => "Needed",
        "required_date" => "2027-03-01",
        "priority" => "high",
        "lines" => [line(ctx), line(ctx, %{"quantity" => 2, "estimated_unit_cost" => "19.99"})]
      },
      overrides
    )
  end

  defp counts(schema) do
    {Repo.aggregate(Document, :count, prefix: schema),
     Repo.aggregate(DocumentVersion, :count, prefix: schema),
     Repo.aggregate(from(e in Entry, select: e.id), :count, prefix: schema)}
  end

  defp version!(schema, document_id, version_no) do
    Repo.one!(
      from(v in DocumentVersion,
        where: v.document_id == ^document_id and v.version_no == ^version_no
      ),
      prefix: schema
    )
  end

  defp submitted!(ctx) do
    {:ok, %{document_id: id}} = PurchaseRequests.create(ctx.schema, ctx.actor, params(ctx))
    {:ok, _} = PurchaseRequests.submit(ctx.schema, ctx.actor, id)
    id
  end

  describe "create (criteria 1, 2, 3)" do
    test "T-C1: a valid request is saved as draft v1 with the actor as requester", ctx do
      assert {:ok, %{document_id: id, version_no: 1, status: :draft, content: content}} =
               PurchaseRequests.create(ctx.schema, ctx.actor, params(ctx))

      assert content["requester"] == ctx.actor
      assert content["department_id"] == ctx.dept

      document = Repo.get!(Document, id, prefix: ctx.schema)
      assert document.type_key == "purchase_request"
      assert document.issuing_org_unit_id == ctx.dept
      assert version!(ctx.schema, id, 1).status == :draft
    end

    test "T-C2: an invalid request saves nothing", ctx do
      before = counts(ctx.schema)

      assert {:error, {:validation, errors}} =
               PurchaseRequests.create(ctx.schema, ctx.actor, %{"lines" => []})

      assert Enum.map(errors, & &1.field) ==
               ~w(department_id justification lines priority required_date)

      assert counts(ctx.schema) == before
    end

    test "T-C3: the stored totals are exact", ctx do
      lines = [line(ctx), line(ctx, %{"quantity" => "2", "estimated_unit_cost" => "19.99"})]

      assert {:ok, %{document_id: id}} =
               PurchaseRequests.create(ctx.schema, ctx.actor, params(ctx, %{"lines" => lines}))

      stored = version!(ctx.schema, id, 1).content
      assert stored["total"] == "40.28"
      assert Enum.map(stored["lines"], & &1["line_total"]) == ["0.3", "39.98"]
    end

    test "T-C4: retired and unknown references are validation errors, nothing saved", ctx do
      retired_uom = CatalogItemsFixture.uom!(ctx.schema, "OLD", %{"active" => false})

      retired_dept =
        OrgFixture.create!(
          ctx.schema,
          "org_unit",
          OrgFixture.values("org_unit", "D2", %{"active" => false})
        )

      site = OrgFixture.create!(ctx.schema, "org_site", OrgFixture.values("org_site", "S1"))
      before = counts(ctx.schema)

      bad_lines = [
        line(ctx, %{"unit_id" => retired_uom.record_id}),
        line(ctx, %{"unit_id" => Ecto.UUID.generate()})
      ]

      assert {:error, {:validation, errors}} =
               PurchaseRequests.create(
                 ctx.schema,
                 ctx.actor,
                 params(ctx, %{"lines" => bad_lines, "department_id" => retired_dept.record_id})
               )

      assert Enum.map(errors, &{&1.field, &1.code}) == [
               {"department_id", "retired"},
               {"lines[1].unit_id", "retired"},
               {"lines[2].unit_id", "unknown"}
             ]

      assert {:error, {:validation, [%{field: "department_id", code: "unknown"}]}} =
               PurchaseRequests.create(
                 ctx.schema,
                 ctx.actor,
                 params(ctx, %{"department_id" => site.record_id})
               )

      assert counts(ctx.schema) == before
    end

    test "T-C4b: an org unit that is not a scope node is refused by Documents", ctx do
      unit = OrgFixture.create!(ctx.schema, "org_unit", OrgFixture.values("org_unit", "D3"))

      assert {:error, :org_unit_not_found} =
               PurchaseRequests.create(
                 ctx.schema,
                 ctx.actor,
                 params(ctx, %{"department_id" => unit.record_id})
               )
    end
  end

  describe "submit and revise (criterion 4)" do
    test "T-D1: submit issues a numbered, hashed version of the purchase_request type", ctx do
      {:ok, %{document_id: id}} = PurchaseRequests.create(ctx.schema, ctx.actor, params(ctx))

      assert {:ok, %{document_id: ^id, version_no: 1, content_hash: hash, number: number}} =
               PurchaseRequests.submit(ctx.schema, ctx.actor, id)

      assert is_binary(hash) and is_integer(number)
      assert Repo.get!(Document, id, prefix: ctx.schema).type_key == "purchase_request"
      assert version!(ctx.schema, id, 1).status == :issued
    end

    test "T-D2: a revision never edits the submitted version", ctx do
      id = submitted!(ctx)
      v1 = version!(ctx.schema, id, 1)
      {:ok, bytes} = Canonical.canonicalize(v1.content)

      lines = params(ctx)["lines"] ++ [line(ctx, %{"description" => "Nuts"})]

      assert {:ok, %{version_no: 2, content_hash: hash2}} =
               PurchaseRequests.revise(
                 ctx.schema,
                 ctx.actor,
                 id,
                 params(ctx, %{"lines" => lines})
               )

      after_v1 = version!(ctx.schema, id, 1)
      assert after_v1.status == :superseded
      assert after_v1.content == v1.content
      assert after_v1.content_hash == v1.content_hash
      assert {:ok, ^bytes} = Canonical.canonicalize(after_v1.content)
      assert hash2 != v1.content_hash
      assert length(version!(ctx.schema, id, 2).content["lines"]) == 3

      assert Repo.get!(Document, id, prefix: ctx.schema).current_version ==
               version!(ctx.schema, id, 2).id
    end

    test "T-D3: a failing revise leaves v1 current and no half-made draft", ctx do
      id = submitted!(ctx)
      before = counts(ctx.schema)

      # a validation failure writes nothing
      assert {:error, {:validation, _}} =
               PurchaseRequests.revise(ctx.schema, ctx.actor, id, params(ctx, %{"lines" => []}))

      assert counts(ctx.schema) == before

      # a failure inside the transaction (the scope node of the department retired after submit)
      {:ok, _} = ScopeNodePaths.write({:retire, ctx.dept}, ctx.schema)
      assert {:error, _reason} = PurchaseRequests.revise(ctx.schema, ctx.actor, id, params(ctx))

      assert counts(ctx.schema) == before
      assert version!(ctx.schema, id, 1).status == :issued

      refute Repo.exists?(from(v in DocumentVersion, where: v.version_no == 2),
               prefix: ctx.schema
             )
    end

    test "T-D4: a revision cannot change the department", ctx do
      id = submitted!(ctx)
      other = OrgFixture.create!(ctx.schema, "org_unit", OrgFixture.values("org_unit", "D4"))
      {:ok, _} = ScopeNodePaths.write({:insert, other.record_id, nil}, ctx.schema)
      before = counts(ctx.schema)

      assert {:error, {:validation, [%{field: "department_id", code: "immutable"}]}} =
               PurchaseRequests.revise(
                 ctx.schema,
                 ctx.actor,
                 id,
                 params(ctx, %{"department_id" => other.record_id})
               )

      assert counts(ctx.schema) == before
    end

    test "update_draft replaces the open draft before submission", ctx do
      {:ok, %{document_id: id}} = PurchaseRequests.create(ctx.schema, ctx.actor, params(ctx))

      assert {:ok, %{version_no: 1}} =
               PurchaseRequests.update_draft(
                 ctx.schema,
                 ctx.actor,
                 id,
                 params(ctx, %{"justification" => "Changed"})
               )

      assert version!(ctx.schema, id, 1).content["justification"] == "Changed"
    end
  end

  describe "ownership and tenant isolation (INV-1, INV-5)" do
    test "T-O1: another user gets the same answer as an absent or malformed id", ctx do
      id = submitted!(ctx)

      {:ok, %{document_id: draft_id}} =
        PurchaseRequests.create(ctx.schema, ctx.actor, params(ctx))

      before = counts(ctx.schema)
      other = Ecto.UUID.generate()

      for target <- [id, draft_id, Ecto.UUID.generate(), "not-a-uuid", nil] do
        assert {:error, :not_found} = PurchaseRequests.submit(ctx.schema, other, target)

        assert {:error, :not_found} =
                 PurchaseRequests.revise(ctx.schema, other, target, params(ctx))

        assert {:error, :not_found} =
                 PurchaseRequests.update_draft(ctx.schema, other, target, params(ctx))
      end

      assert {:error, :not_found} =
               PurchaseRequests.submit(ctx.schema, ctx.actor, Ecto.UUID.generate())

      assert counts(ctx.schema) == before
    end

    test "T-X1: another tenant's prefix does not see the document", ctx do
      id = submitted!(ctx)
      other_tenant = tenant!("gh3162b")
      before = counts(ctx.schema)

      assert {:error, :not_found} =
               PurchaseRequests.submit(other_tenant.schema_name, ctx.actor, id)

      assert {:error, :not_found} =
               PurchaseRequests.revise(other_tenant.schema_name, ctx.actor, id, params(ctx))

      assert {:error, :not_found} = PurchaseRequests.submit("tenant_nope", ctx.actor, id)
      assert counts(ctx.schema) == before
    end
  end

  describe "install (T-I1)" do
    test "the type is registered; reinstall and a missing dependency are refused", ctx do
      type = Repo.get!(Documents.DocumentType, "purchase_request", prefix: ctx.schema)
      assert type.owner_module == "procurement"

      assert {:error, _} =
               Installs.install("procurement", Ecto.UUID.generate(),
                 prefix: ctx.schema,
                 rationale: "again"
               )

      bare = tenant!("gh3162c")

      assert {:error, {:dependency_not_installed, _}} =
               Installs.install("procurement", Ecto.UUID.generate(),
                 prefix: bare.schema_name,
                 rationale: "x"
               )
    end

    test "a refused type registration rolls the install back", ctx do
      tenant = tenant!("gh3162d")
      {:ok, _} = Letflow.Entities.EventTypes.seed!(tenant.schema_name)
      for id <- ["org", "catalog_items"], do: install!(tenant.tenant_id, id)

      {:ok, _} =
        Documents.register_type(
          tenant.schema_name,
          %{
            key: "purchase_request",
            owner_module: "someone_else",
            numbering_scope: :year,
            number_prefix: "PR",
            number_pad: 4,
            legal_entity_required: false,
            declared_fields: %{}
          },
          %{actor_id: ctx.actor}
        )

      assert {:error, _} =
               Installs.install("procurement", Ecto.UUID.generate(),
                 prefix: tenant.schema_name,
                 rationale: "x"
               )

      refute Installs.installed?("procurement", prefix: tenant.schema_name)
    end
  end
end
