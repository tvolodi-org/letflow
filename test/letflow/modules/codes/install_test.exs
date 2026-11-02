Code.require_file("codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.InstallTest do
  @moduledoc """
  GH #3588 / REQ-648 criteria 1, 3, 10 and 13 (IN-01..IN-04, SD-03, TI-02): install through the real
  `Letflow.Routers.TenantModules` on a fresh provisioned tenant, the foreign keys from `pg_constraint`,
  the managed lock on the generic routes. `async: false`: install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.TenantFixture

  @types ["code_tag", "code_assignment", "code_value_change"]
  @entities_opts Letflow.Routers.Entities.init([])

  defp post_install(tenant_id, body) do
    Plug.Test.conn(:post, "/")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "gh3588-codes-install-trace")
    |> Letflow.Routers.TenantModules.call(Letflow.Routers.TenantModules.init([]))
  end

  defp fk_rows(schema, table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.attname, c.confdeltype::text, rt.relname
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_class rt ON rt.oid = c.confrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
        WHERE n.nspname = $1 AND t.relname = $2 AND c.contype = 'f'
        """,
        [schema, table]
      )

    rows
  end

  defp column_type(schema, table, column) do
    %{rows: rows} =
      Repo.query!(
        "SELECT data_type FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 AND column_name = $3",
        [schema, table, column]
      )

    rows
  end

  describe "install" do
    test "IN-03: a missing, blank or non-string rationale is 422 and installs nothing" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh3588-in3")

      for body <- [
            %{"module_id" => "codes"},
            %{"module_id" => "codes", "rationale" => ""},
            %{"module_id" => "codes", "rationale" => "   "},
            %{"module_id" => "codes", "rationale" => 7}
          ] do
        assert post_install(tenant.tenant_id, body).status == 422
      end

      assert Repo.all(from(d in EntityDefinition, select: d.name), prefix: tenant.schema_name) ==
               []
    end

    test "IN-02, IN-01: 201, three active managed definitions, history FKs are uuid ON DELETE RESTRICT" do
      ctx = Letflow.CodesFixture.installed_tenant!("gh3588-in2")

      rows =
        Repo.all(
          from(d in EntityDefinition,
            select: {d.name, d.managed_by, d.status},
            order_by: d.name
          ),
          prefix: ctx.schema
        )

      assert rows == Enum.map(Enum.sort(@types), &{&1, "codes", :active})

      for table <- ["entity_code_assignment", "entity_code_value_change"] do
        assert column_type(ctx.schema, table, "code_id") == [["uuid"]]
        assert [["code_id", "r", "entity_code_tag"]] = fk_rows(ctx.schema, table)
      end

      assert fk_rows(ctx.schema, "entity_code_tag") == []
      assert column_type(ctx.schema, "entity_code_assignment", "target_id") == [["text"]]

      # target_id carries no foreign key (the only FK on the table is code_id).
      assert length(fk_rows(ctx.schema, "entity_code_assignment")) == 1
    end

    test "IN-04: generic POST /records/<type> answers 403 entity_type_managed and writes nothing" do
      ctx = Letflow.CodesFixture.installed_tenant!("gh3588-in4")

      for type <- @types do
        conn =
          Plug.Test.conn(:post, "/records/#{type}")
          |> Map.put(:body_params, %{"field_values" => %{"value" => "x"}})
          |> put_req_header("content-type", "application/json")
          |> assign(:auth_context, %{
            user_id: Ecto.UUID.generate(),
            tenant_id: ctx.tenant_id,
            roles: ["TENANT_ADMIN"]
          })
          |> assign(:trace_id, "gh3588-codes-install-trace")
          |> Letflow.Routers.Entities.call(@entities_opts)

        assert conn.status == 403, conn.resp_body
        assert conn.resp_body =~ "entity_type_managed"

        assert Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count,
                 prefix: ctx.schema
               ) == 0
      end
    end

    test "SD-03: after install ScopeDeclaration.for_type/2 is :tenant_wide for each type" do
      ctx = Letflow.CodesFixture.installed_tenant!("gh3588-sd3")

      for type <- @types do
        assert ScopeDeclaration.for_type(type, ctx.schema) == :tenant_wide
      end
    end

    test "TI-02: the three tables have no tenant_id column (decision 0006 D2)" do
      ctx = Letflow.CodesFixture.installed_tenant!("gh3588-ti2")

      for table <- ["entity_code_tag", "entity_code_assignment", "entity_code_value_change"] do
        assert column_type(ctx.schema, table, "tenant_id") == []
        assert column_type(ctx.schema, table, "record_id") == [["uuid"]]
      end
    end

    test "TI-03: the manifest declares no permission, role grant or route policy" do
      m = Letflow.Modules.Codes.manifest()
      assert m.permissions == []
      assert m.role_grants == %{}
      assert m.route_policies == []
    end
  end
end
