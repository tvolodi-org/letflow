defmodule Letflow.Modules.Org.InstallTest do
  @moduledoc """
  GH #2661 / REQ-473 AC3..AC6 and tenant isolation (spec `test/specs/GH-2661.md`, tests
  I-01..I-03, N-01, N-02, X-01..X-06, M-01, M-02, T-01).

  Everything runs against a real provisioned tenant on real Postgres: the install goes through
  the real `Letflow.Routers.TenantModules` (`POST /`), the owner writes go through
  `Letflow.Entities.Records.create_record/3` with `ManagedTypes.owner_for!(Letflow.Modules.Org)`
  (the module ships no write functions in this slice, those are REQ-495), and the managed-lock
  checks go through the real `Letflow.Routers.Entities`.

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

  @types ~w(org_legal_entity org_site org_unit org_unit_membership)
  @masters ~w(org_legal_entity org_site org_unit)
  @trace "gh2661-org-install-fixed-trace"

  @install_opts Letflow.Routers.TenantModules.init([])
  @entities_opts Letflow.Routers.Entities.init([])

  setup do
    tenant = fresh_tenant!("gh2661-org")
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

  defp install_org!(ctx) do
    conn =
      post_install(ctx.tenant_id, %{"module_id" => "org", "rationale" => "GH-2661 install test"})

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
    Repo.exists?(from(m in TenantModule, where: m.module_id == "org"), prefix: schema)
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

  defp owner, do: ManagedTypes.owner_for!(Letflow.Modules.Org)

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
  defp values("org_legal_entity", code, extra) do
    Map.merge(
      %{"code" => code, "name" => "LE #{code}", "bin" => "123456789012", "active" => true},
      extra
    )
  end

  defp values("org_site", code, extra) do
    Map.merge(
      %{"code" => code, "name" => "Site #{code}", "legal_entity_id" => "le-1", "active" => true},
      extra
    )
  end

  defp values("org_unit", code, extra) do
    Map.merge(
      %{
        "code" => code,
        "name" => "Unit #{code}",
        "legal_entity_id" => "le-1",
        "site_id" => "site-1",
        "active" => true
      },
      extra
    )
  end

  defp values("org_unit_membership", _code, extra) do
    Map.merge(%{"user_id" => "user-1", "org_unit_id" => "unit-1", "active" => true}, extra)
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
            %{"module_id" => "org"},
            %{"module_id" => "org", "rationale" => nil},
            %{"module_id" => "org", "rationale" => ""},
            %{"module_id" => "org", "rationale" => "   "},
            %{"module_id" => "org", "rationale" => 7}
          ] do
        conn = post_install(ctx.tenant_id, body)
        assert conn.status == 422, "#{inspect(body)}: #{conn.status} #{conn.resp_body}"
        assert Jason.decode!(conn.resp_body)["detail"] == "rationale is required"
      end

      refute module_installed?(ctx.schema)
      assert rows(ctx.schema) == []
      assert promotions(ctx.tenant_id) == []

      conn = install_org!(ctx)
      body = Jason.decode!(conn.resp_body)
      assert body["module_id"] == "org"
      assert body["version"] == Letflow.Modules.Org.manifest().version
      assert module_installed?(ctx.schema)
    end

    test "I-02: afterwards exactly the four types exist, all active, each managed_by org", ctx do
      install_org!(ctx)

      assert rows(ctx.schema) == Enum.map(@types, &{&1, "org", :active})
    end

    test "I-03: exactly one promotion row per promoted column, external_ref columns included",
         ctx do
      install_org!(ctx)

      expected = expected_promotions(ctx.schema)

      # Sorted-list equality: no missing column, no extra row, no duplicate row.
      assert promotions(ctx.tenant_id) == expected

      # The expectation is not vacuous: it names the promoted fields of the issue.
      for type <- @masters,
          column <- ["code", "active", "external_ref_system", "external_ref_id"] do
        assert {type, column} in expected, "#{type}.#{column} should be promoted"
      end

      assert {"org_site", "legal_entity_id"} in expected
      assert {"org_unit_membership", "user_id"} in expected
      assert {"org_unit_membership", "org_unit_id"} in expected
      # The deliberately unqueried references have no column.
      refute {"org_unit", "legal_entity_id"} in expected
      refute {"org_unit", "site_id"} in expected
      refute {"org_unit", "parent"} in expected
    end
  end

  # ── AC4: name conflict and rollback ─────────────────────────────────────────────────────────

  describe "AC4: a tenant's own org_site blocks the install and everything rolls back" do
    setup ctx do
      # GH #2581: the tenant path refuses this name now; plant a pre-existing legacy squat.
      own =
        Letflow.ManagedTypesSupport.plant_legacy_squat!(ctx.schema, "org_site", [
          %{name: "address", type: :string}
        ])

      {:ok, own_id: own.id}
    end

    test "N-01: Installs.install/3 refuses with managed_name_taken and leaves no trace", ctx do
      assert Installs.install("org", Ecto.UUID.generate(),
               prefix: ctx.schema,
               rationale: "GH-2661 conflict test"
             ) == {:error, {:pack_install_failed, {:managed_name_taken, "org_site"}}}

      # Only the tenant's own row remains, unstamped and untouched.
      assert rows(ctx.schema) == [{"org_site", nil, :inactive}]
      assert Repo.get!(EntityDefinition, ctx.own_id, prefix: ctx.schema).managed_by == nil
      refute module_installed?(ctx.schema)
      assert promotions(ctx.tenant_id) == []

      for type <- @types do
        assert ManagedTypes.owner_of(type, ctx.schema) == :unmanaged
      end

      refute Repo.exists?(
               from(i in SolutionPackInstall,
                 where: i.tenant_id == ^ctx.tenant_id and i.pack_id == "letflow-org"
               )
             )
    end

    test "N-02: through the route the same refusal is a 422 and also installs nothing", ctx do
      conn =
        post_install(ctx.tenant_id, %{
          "module_id" => "org",
          "rationale" => "GH-2661 route conflict"
        })

      assert conn.status == 422, conn.resp_body
      assert Jason.decode!(conn.resp_body)["detail"] == "module installation failed"
      assert rows(ctx.schema) == [{"org_site", nil, :inactive}]
      refute module_installed?(ctx.schema)
      assert promotions(ctx.tenant_id) == []
    end
  end

  # ── AC5: uniqueness through the owner path ──────────────────────────────────────────────────

  describe "AC5: external_ref and code uniqueness (owner path, real unique indexes)" do
    setup ctx do
      install_org!(ctx)
      :ok
    end

    test "X-01: two rows with both external_ref fields NULL are accepted, per master", ctx do
      for type <- @masters do
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "null-a"))
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "null-b"))
        assert record_count(ctx.schema, type) == 2
      end
    end

    test "X-02: two rows with the same non-NULL external_ref pair: the second is refused, per master",
         ctx do
      for type <- @masters do
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
      for type <- @masters do
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "p-1", ref("1c", "42")))
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "p-2", ref("sap", "42")))
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "p-3", ref("1c", "43")))
        assert record_count(ctx.schema, type) == 3
      end
    end

    test "X-04: a duplicate code is refused with a unique violation on [code], per master", ctx do
      for type <- @masters do
        assert {:ok, _} = owner_create(ctx.schema, type, values(type, "same"))

        assert {:error, {:record_payload_invalid, [violation]}} =
                 owner_create(ctx.schema, type, values(type, "same"))

        assert %Violation{rule: :unique, path: ["code"]} = violation
        assert record_count(ctx.schema, type) == 1
      end
    end

    test "X-05: the membership pair is unique; the same user in another unit is accepted", ctx do
      type = "org_unit_membership"
      assert {:ok, _} = owner_create(ctx.schema, type, values(type, nil))

      assert {:error, {:record_payload_invalid, [violation]}} =
               owner_create(ctx.schema, type, values(type, nil))

      assert %Violation{rule: :unique, path: ["user_id", "org_unit_id"]} = violation

      other_unit = values(type, nil, %{"org_unit_id" => "unit-2"})
      other_user = values(type, nil, %{"user_id" => "user-2"})
      assert {:ok, _} = owner_create(ctx.schema, type, other_unit)
      assert {:ok, _} = owner_create(ctx.schema, type, other_user)
      assert record_count(ctx.schema, type) == 3
    end

    test "X-06: org_unit accepts a root (no parent) and a child (parent id string)", ctx do
      assert {:ok, _} = owner_create(ctx.schema, "org_unit", values("org_unit", "root"))

      child = values("org_unit", "child", %{"parent" => Ecto.UUID.generate()})
      assert {:ok, _} = owner_create(ctx.schema, "org_unit", child)
      assert record_count(ctx.schema, "org_unit") == 2
    end
  end

  # ── AC6: managed lock ───────────────────────────────────────────────────────────────────────

  describe "AC6: the generic routes refuse every org type" do
    setup ctx do
      install_org!(ctx)
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
      assert {:ok, _} = owner_create(ctx.schema, "org_site", values("org_site", "owner-ok"))
      assert record_count(ctx.schema, "org_site") == 1

      assert {:error, :entity_type_managed} =
               Records.create_record(
                 %{
                   entity_type: "org_site",
                   field_values: values("org_site", "tenant-no"),
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 ctx.schema
               )

      assert record_count(ctx.schema, "org_site") == 1
    end
  end

  # ── tenant isolation ────────────────────────────────────────────────────────────────────────

  describe "tenant isolation" do
    test "T-01: installing in tenant A leaves tenant B without the org types", ctx do
      other = fresh_tenant!("gh2661-org-b")

      install_org!(ctx)
      assert length(rows(ctx.schema)) == 4

      assert rows(other.schema_name) == []
      refute module_installed?(other.schema_name)
      assert promotions(other.tenant_id) == []

      for type <- @types do
        assert ManagedTypes.owner_of(type, other.schema_name) == :unmanaged
      end

      refute Installs.installed?("org", prefix: other.schema_name)

      # GH #2581: B's creation is refused by the reserved-name rule (module not installed in B),
      # not by anything of A's lock leaking into it.
      assert {:error, :entity_type_managed} =
               Definitions.create_definition(
                 %{
                   definition: %{
                     name: "org_site",
                     display_name: "B own site",
                     fields: [%{name: "address", type: :string}]
                   },
                   created_by: Ecto.UUID.generate()
                 },
                 other.schema_name
               )
    end
  end
end
