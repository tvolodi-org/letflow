defmodule Letflow.Routers.EntityScopeDeclarationsTest do
  @moduledoc """
  REQ-635 / GH #3549: the `/entity-scope-declarations` routes and the third source of
  `Letflow.Entities.ScopeDeclaration`. Test IDs follow the design (U = undeclared/declared,
  M = managed, C = column, R = refusals, X = cross-tenant, A = authorisation, T = reader).

  Dispatch: real `Letflow.Routers.EntityScopeDeclarations.call/2`. Sandbox `:auto` mode with
  committed tenants, as `NumberSequencesTest` (the audit-failure case needs a committed schema).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Audit
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Entities.ScopeDeclarations
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Repo
  alias Letflow.Routers.EntityScopeDeclarations, as: Router
  alias Letflow.Test.SandboxAutoMode

  @opts Router.init([])
  @admin ["TENANT_ADMIN"]

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    base = Fx.committed_tenant_case!("gh3549")

    on_exit(fn ->
      Fx.drop_committed_tenant!(base.tenant.tenant_id)
      SandboxAutoMode.exit_auto_mode!(Repo)
    end)

    constraint = %{name: "sd_item_uq", type: :unique, fields: ["label", "note"]}
    Fx.define_type!(base.schema, "sd_item", %{append_only: false, constraints: [constraint]})
    Fx.define_type!(base.schema, "sd_plain", %{append_only: false})
    %{base: base}
  end

  defp call(base, method, path, roles, body \\ %{}) do
    conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: base.tenant.tenant_id,
      roles: roles
    })
    |> assign(:scoped_opts, prefix: base.schema)
    |> assign(:trace_id, "req635-trace")
    |> Router.call(@opts)
  end

  defp put(base, type, body, roles \\ @admin), do: call(base, :put, "/" <> type, roles, body)
  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp items(base), do: base |> call(:get, "/", @admin) |> json() |> Map.fetch!("items")

  defp audit_count(base) do
    {:ok, %{items: items}} =
      Audit.list_entries(%{
        prefix: base.schema,
        page_size: 100,
        resource_type: "entity_scope_declaration"
      })

    length(items)
  end

  test "U1 no row is :undeclared; U2 tenant_wide and U3 column resolve after a PUT", %{base: base} do
    s = base.schema
    assert ScopeDeclaration.for_type("sd_item", s) == :undeclared

    conn = put(base, "sd_item", %{"kind" => "tenant_wide"})
    assert conn.status == 200
    assert %{"entity_type" => "sd_item", "kind" => "tenant_wide", "field" => nil} = json(conn)
    assert ScopeDeclaration.for_type("sd_item", s) == :tenant_wide

    assert put(base, "sd_item", %{"kind" => "column", "field" => "note"}).status == 200
    assert ScopeDeclaration.for_type("sd_item", s) == {:column, "note"}
    assert [%{"kind" => "column", "field" => "note"}] = items(base)
    assert ScopeDeclaration.for_type("sd_plain", s) == :undeclared
  end

  test "M1 a module-managed type answers 403 and stores nothing", %{base: base} do
    :ok = Fx.install_managed_fixture!(base.schema)
    before_decl = ScopeDeclaration.for_type("fxm_ledger", base.schema)

    conn = put(base, "fxm_ledger", %{"kind" => "tenant_wide"})
    assert conn.status == 403
    assert conn.resp_body =~ "entity_type_managed"
    assert items(base) == []
    assert ScopeDeclaration.for_type("fxm_ledger", base.schema) == before_decl
  end

  test "M2 a manifest-named type answers 403 even with no definition", %{base: base} do
    assert ScopeDeclaration.manifest_named?("scoped_item")
    conn = put(base, "scoped_item", %{"kind" => "tenant_wide"})
    assert conn.status == 403
    assert conn.resp_body =~ "entity_type_managed"
    assert items(base) == []
  end

  test "C1 a column field in no constraint is 422; C2 a composite member is 200", %{base: base} do
    for field <- ["other", "zzz_nope"] do
      conn = put(base, "sd_item", %{"kind" => "column", "field" => field})
      assert conn.status == 422
      refute conn.resp_body =~ field
    end

    assert items(base) == []
    assert put(base, "sd_item", %{"kind" => "column", "field" => "label"}).status == 200
    assert [%{"field" => "label"}] = items(base)
    assert put(base, "sd_plain", %{"kind" => "column", "field" => "label"}).status == 422
  end

  test "C3 a type with no active definition is 404", %{base: base} do
    conn = put(base, "sd_missing", %{"kind" => "tenant_wide"})
    assert conn.status == 404
    assert items(base) == []
  end

  test "R1..R5 shape refusals are 422 and store nothing", %{base: base} do
    cases = [
      {"sd_item", %{"kind" => "other"}},
      {"sd_item", %{}},
      {"Bad_Type", %{"kind" => "tenant_wide"}},
      {"sd_item", %{"kind" => "column", "field" => "Bad Field"}},
      {"sd_item", %{"kind" => "tenant_wide", "field" => "label"}},
      {"sd_item", %{"kind" => "column"}}
    ]

    for {type, body} <- cases do
      conn = put(base, type, body)
      assert conn.status == 422, "#{type} #{inspect(body)}: #{conn.resp_body}"
    end

    assert items(base) == []
    assert audit_count(base) == 0
  end

  test "R6 a replace keeps one row and audits old and new", %{base: base} do
    assert put(base, "sd_item", %{"kind" => "tenant_wide"}).status == 200
    assert put(base, "sd_item", %{"kind" => "column", "field" => "label"}).status == 200
    assert [%{"kind" => "column"}] = items(base)
    assert audit_count(base) == 2
  end

  test "R7 a failed audit rolls the write back and answers a detail-free 500", %{base: base} do
    assert put(base, "sd_item", %{"kind" => "tenant_wide"}).status == 200
    Repo.query!(~s(DROP TABLE "#{base.schema}".audit_entries))

    conn = put(base, "sd_item", %{"kind" => "column", "field" => "label"})
    assert conn.status == 500
    refute conn.resp_body =~ "audit_entries"
    assert [%{"kind" => "tenant_wide"}] = items(base)
  end

  test "X1 a row of tenant A is not read for tenant B, X2 tenant_id is ignored", %{base: base} do
    other = Fx.committed_tenant_case!("gh3549b")
    on_exit(fn -> Fx.drop_committed_tenant!(other.tenant.tenant_id) end)
    Fx.define_type!(other.schema, "sd_item", %{append_only: false})

    foreign = other.tenant.tenant_id
    conn = put(base, "sd_item", %{"kind" => "tenant_wide", "tenant_id" => foreign})
    assert conn.status == 200
    refute conn.resp_body =~ foreign

    assert ScopeDeclaration.for_type("sd_item", base.schema) == :tenant_wide
    assert ScopeDeclaration.for_type("sd_item", other.schema) == :undeclared
    assert items(%{base | schema: other.schema, tenant: other.tenant}) == []
    assert ScopeDeclarations.list(other.schema) == []
  end

  test "X1b a type of another tenant answers 404 like an unknown one", %{base: base} do
    other = Fx.committed_tenant_case!("gh3549c")
    on_exit(fn -> Fx.drop_committed_tenant!(other.tenant.tenant_id) end)
    Fx.define_type!(other.schema, "sd_only_other", %{append_only: false})

    conn = put(base, "sd_only_other", %{"kind" => "tenant_wide"})
    assert conn.status == 404
    assert conn.resp_body == put(base, "sd_nobody", %{"kind" => "tenant_wide"}).resp_body
  end

  test "A1 roles without the permission get 403 on both routes, A3 TENANT_ADMIN 200", %{
    base: base
  } do
    for roles <- [["PROCESS_DESIGNER"], ["TENANT_AUDITOR"]] do
      assert put(base, "sd_item", %{"kind" => "tenant_wide"}, roles).status == 403
      assert call(base, :get, "/", roles).status == 403
      # the same refusal for an invalid body: the permission is checked first (INV-5)
      assert put(base, "sd_item", %{"kind" => "bad"}, roles).status == 403
    end

    assert items(base) == []
    assert call(base, :get, "/", @admin).status == 200
  end

  test "T3 a row inserted directly for a managed type name is ignored", %{base: base} do
    :ok = Fx.install_managed_fixture!(base.schema)

    Repo.query!(
      ~s|INSERT INTO "#{base.schema}".entity_scope_declarations| <>
        ~s| (id, entity_type, kind, field, set_by, inserted_at, updated_at)| <>
        ~s| VALUES (gen_random_uuid(), 'fxm_ledger', 'tenant_wide', NULL, gen_random_uuid(), now(), now())|
    )

    assert ScopeDeclaration.for_type("fxm_ledger", base.schema) !== :tenant_wide
  end

  test "T4 one table read for a batch of non-manifest names, no tenant_modules read", %{
    base: base
  } do
    assert put(base, "sd_item", %{"kind" => "tenant_wide"}).status == 200

    {result, queries} =
      Letflow.Support.PlatformTenantFixture.capture_repo_queries(fn ->
        ScopeDeclaration.for_types(["sd_item", "sd_plain", "Bad"], base.schema)
      end)

    assert %{"sd_item" => :tenant_wide, "sd_plain" => :undeclared, "Bad" => :undeclared} = result
    assert Enum.count(queries, &(&1.query =~ "entity_scope_declarations")) == 1
    refute Enum.any?(queries, &(&1.query =~ "tenant_modules"))
  end
end
