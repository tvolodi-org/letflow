defmodule Letflow.Routers.TenantInstallDdlFailureTest do
  @moduledoc """
  GH #2540 (INV-8): a real DDL error raised inside the install transaction answers the
  typed `module_install_ddl_failed` problem+json on BOTH `POST /tenant/modules` and
  `POST /tenant/solutions`, instead of an HTTP 500. `Letflow.Modules.FixtureDdlFailing`
  activates and promotes its pack and then runs an `ALTER TABLE` Postgres rejects.

  Both routes reach `Letflow.Modules.Installs.install/3` (the solution route through
  `Solutions.install/3`), which is the one place that translates the error, so the same
  assertions run against each route.

  `async: false`: tenant provisioning and DDL (same reasoning as `install_activation_test.exs`).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @trace_id "gh2540-install-ddl-failure-trace-id"
  @names ["fkp_parent", "fkp_child"]

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2540")

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    Logger.metadata(trace_id: @trace_id)
    {:ok, tenant: tenant}
  end

  defp post(router, tenant_id, body) do
    conn(:post, "/")
    |> Map.put(:body_params, Map.put(body, "rationale", "gh2540 forced DDL failure"))
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, @trace_id)
    |> router.call(router.init([]))
  end

  defp assert_typed_ddl_error(conn) do
    assert conn.status == 422, conn.resp_body
    assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")

    body = Jason.decode!(conn.resp_body)
    assert body["code"] == "module_install_ddl_failed"
    assert body["status"] == 422
    assert body["title"] == "Module Install DDL Failed"
    assert body["trace_id"] == @trace_id

    # INV-8: nothing from the database or the host reaches the body.
    refute conn.resp_body =~ "no_such_table_gh2540"
    refute conn.resp_body =~ "ALTER TABLE"
    refute conn.resp_body =~ "Postgrex"
    refute conn.resp_body =~ "undefined_table"
    refute conn.resp_body =~ "fixture_ddl_failing"
    refute conn.resp_body =~ "entity_fkp"
    refute conn.resp_body =~ "stacktrace"
    refute conn.resp_body =~ ".ex:"
  end

  defp assert_rolled_back(%{schema_name: schema, tenant_id: tenant_id}) do
    assert Repo.all(TenantModule, prefix: schema) == []

    assert Repo.all(from(d in EntityDefinition, where: d.name in ^@names), prefix: schema) == []

    assert Repo.all(
             from(p in ColumnPromotion,
               where: p.tenant_id == ^tenant_id and p.entity_type in ^@names
             )
           ) == []

    %{rows: [[tables]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = $1 AND table_name LIKE 'entity_fkp_%'",
        [schema]
      )

    assert tables == 0
  end

  for {label, router, body} <- [
        {"POST /tenant/modules", Letflow.Routers.TenantModules,
         %{"module_id" => "fixture_ddl_failing"}},
        {"POST /tenant/solutions", Letflow.Routers.TenantSolutions,
         %{"solution_id" => "fixture-ddl-failing"}}
      ] do
    test "#{label}: a DDL error answers the typed 422, rolls everything back and is logged once",
         %{tenant: tenant} do
      log =
        capture_log(fn ->
          assert_typed_ddl_error(
            post(unquote(router), tenant.tenant_id, unquote(Macro.escape(body)))
          )
        end)

      assert_rolled_back(tenant)

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "module install failed"))
      assert length(lines) == 1, log
      [line] = lines
      assert line =~ "trace_id=#{@trace_id}"
      assert line =~ "module_id=fixture_ddl_failing"
      assert line =~ "sqlstate=undefined_table"
      refute line =~ "no_such_table_gh2540"
      refute line =~ "ALTER TABLE"
    end
  end
end
