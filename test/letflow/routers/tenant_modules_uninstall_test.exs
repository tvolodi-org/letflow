defmodule Letflow.Routers.TenantModulesUninstallTest do
  @moduledoc """
  REQ-578 / GH #3267 (decision 0066 D8), slice 1 part 2, criteria 8 and 10: the routes
  `POST /api/v1/tenant/modules/:module_id/uninstall` and `/reactivate`, behind the
  `:modules_uninstall_enabled` flag.

    R1  200 for TENANT_ADMIN, 403 for roles without :ModulesManage (table over both routes)
    R2  422 for a missing, non-string or blank rationale
    R3  404 for an unknown module and for a double uninstall
    R4  409 codes (dependents_installed, upgrade_required) and 422 for an inactive dependency
    R5  flag off (default): identical to an unknown path of the same router, per caller
    R6  INV-10: a tenant identifier in the body or headers has no effect
    R7  the flag defaults to false in config/config.exs
    E2  the audit trail of the route calls

  Dispatch: real `Letflow.Routers.TenantModules.call/2`. `async: false`: tenant provisioning
  needs `Sandbox.mode(:auto)` and the flag is VM-global.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.TenantFixture

  @opts Letflow.Routers.TenantModules.init([])
  @why "test: REQ-578 route"
  @trace "req578-routes-trace-id"

  setup do
    previous = Application.fetch_env(:letflow, :modules_uninstall_enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :modules_uninstall_enabled, value)
        :error -> Application.delete_env(:letflow, :modules_uninstall_enabled)
      end
    end)

    :ok
  end

  defp enable!, do: Application.put_env(:letflow, :modules_uninstall_enabled, true)

  defp tenant!(slug), do: TenantFixture.provisioned_tenant!(slug_prefix: slug)

  defp install!(prefix, id) do
    {:ok, tm} = Installs.install(id, Ecto.UUID.generate(), prefix: prefix, rationale: @why)
    tm
  end

  defp row!(prefix, id), do: Repo.get_by!(TenantModule, [module_id: id], prefix: prefix)
  defp audit_count(prefix), do: Repo.aggregate(Entry, :count, prefix: prefix)

  defp call(tenant_id, roles, path, body, headers \\ []) do
    base =
      conn(:post, path)
      |> Map.put(:body_params, body)
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        roles: roles
      })
      |> assign(:trace_id, @trace)

    headers
    |> Enum.reduce(base, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> Letflow.Routers.TenantModules.call(@opts)
  end

  defp transition(tenant_id, roles, action, module_id, body \\ %{"rationale" => @why}),
    do: call(tenant_id, roles, "/#{module_id}/#{action}", body)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  describe "R1 -- roles (criterion 8)" do
    test "R1: TENANT_ADMIN 200 with module_id and status; other roles 403, status unchanged" do
      enable!()
      %{tenant_id: tid, schema_name: prefix} = tenant!("req578-r1")
      install!(prefix, "fixture")

      conn = transition(tid, ["TENANT_ADMIN"], "uninstall", "fixture")
      assert conn.status == 200
      assert json(conn) == %{"module_id" => "fixture", "status" => "uninstalled"}
      assert row!(prefix, "fixture").status == :uninstalled

      for role <- ["TENANT_USER", "TENANT_AUDITOR", "TASK_WORKER", "PLATFORM_ADMIN"],
          action <- ["uninstall", "reactivate"] do
        denied = transition(tid, [role], action, "fixture")
        assert denied.status == 403, "#{role} #{action}"
        assert row!(prefix, "fixture").status == :uninstalled
      end

      conn = transition(tid, ["TENANT_ADMIN"], "reactivate", "fixture")
      assert conn.status == 200
      assert json(conn) == %{"module_id" => "fixture", "status" => "active"}
      assert row!(prefix, "fixture").status == :active
    end

    test "E2: each route success writes one audit entry, a refusal none" do
      enable!()
      %{tenant_id: tid, schema_name: prefix} = tenant!("req578-e2")
      install!(prefix, "fixture")
      before = audit_count(prefix)

      assert transition(tid, ["TENANT_ADMIN"], "reactivate", "fixture").status == 404
      assert audit_count(prefix) == before
      assert transition(tid, ["TENANT_ADMIN"], "uninstall", "fixture").status == 200
      assert audit_count(prefix) == before + 1
    end
  end

  describe "R2 -- rationale (criterion 8)" do
    test "R2: missing, non-string, blank or non-object body is 422, status unchanged" do
      enable!()
      %{tenant_id: tid, schema_name: prefix} = tenant!("req578-r2")
      install!(prefix, "fixture")

      for body <- [
            %{},
            %{"rationale" => 123},
            %{"rationale" => ""},
            %{"rationale" => "   "},
            %{"x" => 1}
          ],
          action <- ["uninstall", "reactivate"] do
        conn = transition(tid, ["TENANT_ADMIN"], action, "fixture", body)
        assert conn.status == 422, "#{action} #{inspect(body)}"
        assert json(conn)["detail"] == "rationale is required"
        assert row!(prefix, "fixture").status == :active
      end

      # a body that is not a JSON object
      conn =
        transition(tid, ["TENANT_ADMIN"], "uninstall", "fixture", %Plug.Conn.Unfetched{
          aspect: :body_params
        })

      assert conn.status == 422
      assert row!(prefix, "fixture").status == :active
    end
  end

  describe "R3 -- not installed (criterion 8)" do
    test "R3: unknown module and a double uninstall are 404" do
      enable!()
      %{tenant_id: tid, schema_name: prefix} = tenant!("req578-r3")
      install!(prefix, "fixture")

      assert transition(tid, ["TENANT_ADMIN"], "uninstall", "no_such_module").status == 404
      assert transition(tid, ["TENANT_ADMIN"], "reactivate", "no_such_module").status == 404
      assert transition(tid, ["TENANT_ADMIN"], "uninstall", "fixture").status == 200
      assert transition(tid, ["TENANT_ADMIN"], "uninstall", "fixture").status == 404
    end
  end

  describe "R4 -- 409 codes (criterion 10)" do
    test "R4: dependents_installed, upgrade_required and an inactive dependency" do
      enable!()
      %{tenant_id: tid, schema_name: prefix} = tenant!("req578-r4")
      install!(prefix, "fixture")
      install!(prefix, "fixture_dependent")

      conn = transition(tid, ["TENANT_ADMIN"], "uninstall", "fixture")
      assert conn.status == 409
      body = json(conn)
      assert body["code"] == "dependents_installed"
      assert body["dependents"] == ["fixture_dependent"]
      assert row!(prefix, "fixture").status == :active

      assert transition(tid, ["TENANT_ADMIN"], "uninstall", "fixture_dependent").status == 200
      assert transition(tid, ["TENANT_ADMIN"], "uninstall", "fixture").status == 200

      conn = transition(tid, ["TENANT_ADMIN"], "reactivate", "fixture_dependent")
      assert conn.status == 422
      assert json(conn)["detail"] == "missing dependency: fixture"

      row!(prefix, "fixture")
      |> Ecto.Changeset.change(%{manifest_hash: String.duplicate("0", 64)})
      |> Repo.update!(prefix: prefix)

      conn = transition(tid, ["TENANT_ADMIN"], "reactivate", "fixture")
      assert conn.status == 409
      assert json(conn)["code"] == "upgrade_required"
      assert row!(prefix, "fixture").status == :uninstalled
    end
  end

  describe "R5 -- flag off (criterion 10)" do
    test "R5: each caller gets what the same caller gets on an unknown path" do
      assert Application.get_env(:letflow, :modules_uninstall_enabled) == false
      refute Installs.uninstall_enabled?()

      %{p: p, a: a} = PlatformTenantFixture.three_tenants!()
      PlatformTenantFixture.pin!(p.tenant_id)
      install!(p.schema_name, "fixture")
      install!(a.schema_name, "fixture")

      callers = [
        {p, ["PLATFORM_ADMIN"], 404},
        {a, ["TENANT_ADMIN"], 403},
        {a, ["TENANT_USER"], 403}
      ]

      for {t, roles, expected} <- callers do
        unknown = call(t.tenant_id, roles, "/no-such-route", %{"rationale" => @why})
        assert unknown.status == expected

        before = audit_count(t.schema_name)

        for action <- ["uninstall", "reactivate"] do
          conn = transition(t.tenant_id, roles, action, "fixture")
          assert conn.status == unknown.status, "#{inspect(roles)} #{action}"
          assert norm(conn.resp_body) == norm(unknown.resp_body)
          assert row!(t.schema_name, "fixture").status == :active
          assert audit_count(t.schema_name) == before
        end
      end
    end
  end

  defp norm(body), do: body |> Jason.decode!() |> Map.delete("trace_id")

  describe "R6 -- INV-10 cross-tenant (criterion 10)" do
    test "R6: tenant identifiers in body and headers have no effect" do
      enable!()
      %{a: a, b: b} = PlatformTenantFixture.two_tenants!()
      install!(a.schema_name, "fixture")
      install!(b.schema_name, "fixture")
      b_before = audit_count(b.schema_name)

      body = %{
        "rationale" => @why,
        "tenant_id" => b.tenant_id,
        "tenant" => b.schema_name,
        "prefix" => b.schema_name
      }

      conn =
        call(a.tenant_id, ["TENANT_ADMIN"], "/fixture/uninstall?tenant_id=#{b.tenant_id}", body, [
          {"x-tenant-id", b.tenant_id}
        ])

      assert conn.status == 200
      assert row!(a.schema_name, "fixture").status == :uninstalled
      assert row!(b.schema_name, "fixture").status == :active
      assert [%{module_id: "fixture"}] = Installs.list_installed(prefix: b.schema_name)
      assert audit_count(b.schema_name) == b_before
    end

    test "R6: a module installed only in another tenant is the never-installed 404" do
      enable!()
      %{a: a, b: b} = PlatformTenantFixture.two_tenants!()
      install!(b.schema_name, "fixture")

      other = transition(a.tenant_id, ["TENANT_ADMIN"], "uninstall", "fixture")
      never = transition(a.tenant_id, ["TENANT_ADMIN"], "uninstall", "no_such_module")
      assert other.status == 404
      assert norm(other.resp_body) == norm(never.resp_body)
      assert row!(b.schema_name, "fixture").status == :active
    end
  end

  describe "R7 -- flag default (criterion 10)" do
    test "R7: config/config.exs declares the flag false" do
      assert File.read!("config/config.exs") =~
               ~r/config :letflow, :modules_uninstall_enabled, false/
    end
  end
end
