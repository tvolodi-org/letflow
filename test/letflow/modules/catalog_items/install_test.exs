defmodule Letflow.Modules.CatalogItems.InstallTest do
  @moduledoc """
  GH #2663 / REQ-474 AC3..AC5 and tenant isolation (spec `test/specs/GH-2663.md`, tests
  I-01..I-03, N-01, N-02, X-01..X-06, M-01, M-02, T-01).

  Everything runs against a real provisioned tenant on real Postgres: the install goes through
  the real `Letflow.Routers.TenantModules` (`POST /`), the owner writes go through
  `Letflow.Entities.Records.create_record/3` with
  `ManagedTypes.owner_for!(Letflow.Modules.CatalogItems)` (the skeleton ships no write
  functions), and the managed-lock checks go through the real `Letflow.Routers.Entities`.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @types ~w(catalog_item catalog_uom)
  @trace "gh2663-catalog-items-install-fixed-trace"

  @install_opts Letflow.Routers.TenantModules.init([])
  @entities_opts Letflow.Routers.Entities.init([])

  setup do
    tenant = fresh_tenant!("gh2663-cat")
    {:ok, tenant_id: tenant.tenant_id, schema: tenant.schema_name}
  end

  # A provisioned tenant plus the cleanup of the GLOBAL rows an install writes with an FK onto
  # `tenants` (registered after the fixture's own on_exit, so it runs first).
  defp fresh_tenant!(prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    tenant
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp post_install(tenant_id, body) do
    Plug.Test.conn(:post, "/")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.TenantModules.call(@install_opts)
  end

  defp install_catalog!(ctx) do
    conn =
      post_install(ctx.tenant_id, %{
        "module_id" => "catalog_items",
        "rationale" => "GH-2663 install test"
      })

    assert conn.status == 201, conn.resp_body
    conn
  end

  defp rows(schema) do
    Repo.all(
      from(d in EntityDefinition,
        select: {d.name, d.managed_by, d.status},
        order_by: [d.name, d.inserted_at]
      ),
      prefix: schema
    )
  end

  defp module_installed?(schema) do
    Repo.exists?(from(m in TenantModule, where: m.module_id == "catalog_items"), prefix: schema)
  end

  defp promotions(tenant_id) do
    Repo.all(
      from(p in ColumnPromotion,
        where: p.tenant_id == ^tenant_id,
        select: {p.entity_type, p.column_name},
        order_by: [p.entity_type, p.column_name]
      )
    )
  end

  # The promoted columns the activation must have registered, computed from the persisted
  # definition by the same function the DDL uses, never hard-coded.
  defp expected_promotions(schema) do
    @types
    |> Enum.flat_map(fn type ->
      {:ok, definition} = Definitions.get_active_definition_by_name(type, schema)

      definition
      |> TenantProvisioning.document_from_persisted()
      |> DDL.promoted_columns()
      |> Enum.map(&{type, &1.name})
    end)
    |> Enum.sort()
  end

  defp owner, do: ManagedTypes.owner_for!(Letflow.Modules.CatalogItems)

  defp owner_create(schema, type, field_values) do
    Records.create_record(
      %{
        entity_type: type,
        field_values: field_values,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      },
      schema,
      owner()
    )
  end

  defp record_count(schema, type) do
    Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count, prefix: schema)
  end

  # Minimal valid field_values per type; `extra` overrides or adds.
  defp values("catalog_uom", code, extra) do
    Map.merge(%{"code" => code, "name" => "UoM #{code}", "active" => true}, extra)
  end

  defp values("catalog_item", code, extra) do
    Map.merge(
      %{
        "code" => code,
        "name" => "Item #{code}",
        "base_uom_id" => "uom-1",
        "kind" => "material",
        "active" => true
      },
      extra
    )
  end

  defp values(type, code), do: values(type, code, %{})

  defp ref(system, id), do: %{"external_ref_system" => system, "external_ref_id" => id}

  defp call_entities(ctx, method, path, body) do
    Plug.Test.conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: ctx.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Entities.call(@entities_opts)
  end

  # ── AC3: install and activation ─────────────────────────────────────────────────────────────

  describe "AC3: POST /tenant/modules as TENANT_ADMIN" do
    test "I-01: a missing, blank or non-string rationale is 422 and installs nothing; a real one is 201",
         ctx do
      for body <- [
            %{"module_id" => "catalog_items"},
            %{"module_id" => "catalog_items", "rationale" => nil},
            %{"module_id" => "catalog_items", "rationale" => ""},
            %{"module_id" => "catalog_items", "rationale" => "   "},
            %{"module_id" => "catalog_items", "rationale" => 7}
          ] do
        conn = post_install(ctx.tenant_id, body)
        assert conn.status == 422, "#{inspect(body)}: #{conn.status} #{conn.resp_body}"
        assert Jason.decode!(conn.resp_body)["detail"] == "rationale is required"
      end

      refute module_installed?(ctx.schema)
      assert rows(ctx.schema) == []
      assert promotions(ctx.tenant_id) == []

      conn = install_catalog!(ctx)
      body = Jason.decode!(conn.resp_body)
      assert body["module_id"] == "catalog_items"
      assert body["version"] == Letflow.Modules.CatalogItems.manifest().version
      assert module_installed?(ctx.schema)
    end

    test "I-02: afterwards exactly the two types exist, both active, each managed_by catalog_items",
         ctx do
      install_catalog!(ctx)

      assert rows(ctx.schema) == Enum.map(@types, &{&1, "catalog_items", :active})
    end

    test "I-03: exactly one promotion row per promoted column, external_ref columns included",
         ctx do
      install_catalog!(ctx)

      expected = expected_promotions(ctx.schema)

      # Sorted-list equality: no missing column, no extra row, no duplicate row.
      assert promotions(ctx.tenant_id) == expected

      # The expectation is not vacuous: it names the promoted fields of the issue.
      for type <- @types,
          column <- ["code", "active", "external_ref_system", "external_ref_id"] do
        assert {type, column} in expected, "#{type}.#{column} should be promoted"
      end

      assert {"catalog_item", "base_uom_id"} in expected
      assert {"catalog_item", "kind"} in expected
      # `name` is not queried, so it has no column.
      refute {"catalog_item", "name"} in expected
      refute {"catalog_uom", "name"} in expected
    end
  end

  # ── AC4: name conflict and rollback ─────────────────────────────────────────────────────────

  describe "AC4: a tenant-created catalog_item blocks the install and everything rolls back" do
    setup ctx do
      {:ok, own} =
        Definitions.create_definition(
          %{
            definition: %{
              name: "catalog_item",
              display_name: "Tenant own item",
              fields: [%{name: "address", type: :string}]
            },
            created_by: Ecto.UUID.generate()
          },
          ctx.schema
        )

      {:ok, own_id: own.id}
    end

    test "N-01: Installs.install/3 refuses with managed_name_taken and leaves no trace", ctx do
      assert Installs.install("catalog_items", Ecto.UUID.generate(),
               prefix: ctx.schema,
               rationale: "GH-2663 conflict test"
             ) == {:error, {:pack_install_failed, {:managed_name_taken, "catalog_item"}}}

      # Only the tenant row remains, unstamped and untouched.
      assert rows(ctx.schema) == [{"catalog_item", nil, :inactive}]
      assert Repo.get!(EntityDefinition, ctx.own_id, prefix: ctx.schema).managed_by == nil
      refute module_installed?(ctx.schema)
      assert promotions(ctx.tenant_id) == []

      for type <- @types do
        assert ManagedTypes.owner_of(type, ctx.schema) == :unmanaged
      end

      refute Repo.exists?(
               from(i in SolutionPackInstall,
                 where: i.tenant_id == ^ctx.tenant_id and i.pack_id == "letflow-catalog_items"
               )
             )
    end

    test "N-02: through the route the same refusal is a 422 and also installs nothing", ctx do
      conn =
        post_install(ctx.tenant_id, %{
          "module_id" => "catalog_items",
          "rationale" => "GH-2663 route conflict"
        })

      assert conn.status == 422, conn.resp_body
      assert Jason.decode!(conn.resp_body)["detail"] == "module installation failed"
      assert rows(ctx.schema) == [{"catalog_item", nil, :inactive}]
      refute module_installed?(ctx.schema)
      assert promotions(ctx.tenant_id) == []
    end
  end

  # ── uniqueness through the owner path ───────────────────────────────────────────────────────

  describe "uniqueness: external_ref and code (owner path, real unique indexes)" do
    setup ctx do
      install_catalog!(ctx)
      :ok
    end

    test "X-01: two rows with both external_ref fields NULL are accepted, per type", ctx do
      for type <- @types do
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "null-a"))
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "null-b"))
        assert record_count(ctx.schema, type) == 2
      end
    end

    test "X-02: two rows with the same non-NULL external_ref pair: the second is refused, per type",
         ctx do
      for type <- @types do
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "ref-a", ref("1c", "42")))

        assert {:error, {:record_payload_invalid, [violation]}} =
                 owner_create(ctx.schema, type, values(type, "ref-b", ref("1c", "42")))

        assert %Violation{rule: :unique, path: ["external_ref_system", "external_ref_id"]} =
                 violation

        assert record_count(ctx.schema, type) == 1
      end
    end

    test "X-03: the constraint is on the pair: a different system or a different id is accepted",
         ctx do
      for type <- @types do
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "p-1", ref("1c", "42")))
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "p-2", ref("sap", "42")))
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "p-3", ref("1c", "43")))
        assert record_count(ctx.schema, type) == 3
      end
    end

    test "X-04: a duplicate code is refused with a unique violation on [code], per type", ctx do
      for type <- @types do
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "same"))

        assert {:error, {:record_payload_invalid, [violation]}} =
                 owner_create(ctx.schema, type, values(type, "same"))

        assert %Violation{rule: :unique, path: ["code"]} = violation
        assert record_count(ctx.schema, type) == 1
      end
    end

    test "X-05: the same code is accepted across the two types (constraints are per type)", ctx do
      assert {:ok, _} = owner_create(ctx.schema, "catalog_uom", values("catalog_uom", "kg"))
      assert {:ok, _} = owner_create(ctx.schema, "catalog_item", values("catalog_item", "kg"))
    end

    test "X-06: kind accepts material and service and refuses any other value", ctx do
      assert {:ok, _} = owner_create(ctx.schema, "catalog_item", values("catalog_item", "m"))

      assert {:ok, _} =
               owner_create(
                 ctx.schema,
                 "catalog_item",
                 values("catalog_item", "s", %{"kind" => "service"})
               )

      assert {:error, _} =
               owner_create(
                 ctx.schema,
                 "catalog_item",
                 values("catalog_item", "x", %{"kind" => "bogus"})
               )

      assert record_count(ctx.schema, "catalog_item") == 2
    end
  end

  # ── managed lock ────────────────────────────────────────────────────────────────────────────

  describe "managed lock: the generic routes refuse both catalog types" do
    setup ctx do
      install_catalog!(ctx)
      :ok
    end

    test "M-01: POST /records/:type is the uniform 403 entity_type_managed and writes nothing",
         ctx do
      expected = Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})

      for type <- @types do
        conn =
          call_entities(ctx, :post, "/records/#{type}", %{"field_values" => values(type, "x")})

        assert conn.status == 403, "#{type}: #{conn.status} #{conn.resp_body}"
        assert conn.resp_body == expected
        assert record_count(ctx.schema, type) == 0
      end
    end

    test "M-02: the lock does not stop the owner, and Records itself refuses the tenant authority",
         ctx do
      assert {:ok, _} =
               owner_create(ctx.schema, "catalog_item", values("catalog_item", "owner-ok"))

      assert record_count(ctx.schema, "catalog_item") == 1

      assert {:error, :entity_type_managed} =
               Records.create_record(
                 %{
                   entity_type: "catalog_item",
                   field_values: values("catalog_item", "tenant-no"),
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 ctx.schema
               )

      assert record_count(ctx.schema, "catalog_item") == 1
    end
  end

  # ── tenant isolation ────────────────────────────────────────────────────────────────────────

  describe "tenant isolation" do
    test "T-01: installing in tenant A leaves tenant B without the catalog types", ctx do
      other = fresh_tenant!("gh2663-cat-b")

      install_catalog!(ctx)
      assert length(rows(ctx.schema)) == 2

      assert rows(other.schema_name) == []
      refute module_installed?(other.schema_name)
      assert promotions(other.tenant_id) == []

      for type <- @types do
        assert ManagedTypes.owner_of(type, other.schema_name) == :unmanaged
      end

      # Tenant B can still create its own catalog_item: nothing of A's lock leaked into it.
      assert {:ok, _} =
               Definitions.create_definition(
                 %{
                   definition: %{
                     name: "catalog_item",
                     display_name: "B own item",
                     fields: [%{name: "address", type: :string}]
                   },
                   created_by: Ecto.UUID.generate()
                 },
                 other.schema_name
               )
    end
  end
end
