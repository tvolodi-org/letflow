defmodule Letflow.Routers.ScheduledJobsTest do
  @moduledoc """
  REQ-561 part 2 (GH #3194): the `/scheduled-jobs` routes. P: the permission; R: statuses and
  shapes; S: the create/enable start checks; X: INV-10 cross-tenant negative tests and INV-5
  not-found parity; F: the route half of the feature flag; C: the concealed key; M: the router is
  mounted in the full pipeline.

  `async: false`: the platform tenant pin and the flag are VM-global and tenants are provisioned.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Api.Authorization
  alias Letflow.Audit.Entry
  alias Letflow.Repo
  alias Letflow.Routers.ScheduledJobs, as: Router
  alias Letflow.ScheduledJobs
  alias Letflow.ScheduledJobs.Job
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: Rsg
  alias Letflow.TestSupport.ScheduledJobFixture, as: Fx

  @admin ["TENANT_ADMIN"]
  @denied [["TASK_WORKER"], ["PROCESS_DESIGNER"], ["TENANT_AUDITOR"]]
  @anchor "2026-01-01T00:00:00.000000Z"
  @compiled_default Application.compile_env(:letflow, :scheduled_jobs)

  setup do
    original = Application.get_env(:letflow, :scheduled_jobs)
    Application.put_env(:letflow, :scheduled_jobs, enabled: true)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:letflow, :scheduled_jobs)
        val -> Application.put_env(:letflow, :scheduled_jobs, val)
      end
    end)

    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    name_a = Fx.definition!(tenants.a.schema_name)
    name_b = Fx.definition!(tenants.b.schema_name)
    {:ok, Map.merge(tenants, %{name_a: name_a, name_b: name_b})}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp call(method, path, fixture, roles, body \\ nil, opts \\ []) do
    conn =
      Fixture.router_conn(method, path, fixture, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
        tenant_id: fixture.tenant_id,
        roles: roles,
        credential: Keyword.get(opts, :credential, :oidc)
      })

    Router.call(conn, Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # The problem body minus its per-request trace id.
  defp untraced(conn), do: conn |> json() |> Map.delete("trace_id")

  defp body(name, overrides \\ %{}) do
    %{
      "key" => "job-" <> to_string(System.unique_integer([:positive])),
      "title" => "A job",
      "definition_name" => name,
      "variables" => %{"batch" => "nightly"},
      "interval_minutes" => 60,
      "anchor_at" => @anchor
    }
    |> Map.merge(overrides)
  end

  defp create(fixture, name, overrides \\ %{}, roles \\ @admin, opts \\ []),
    do: call(:post, "/", fixture, roles, body(name, overrides), opts)

  defp job!(fixture, name) do
    conn = create(fixture, name)
    assert conn.status == 201
    json(conn)
  end

  defp job_count(fixture), do: Repo.aggregate(Job, :count, :id, prefix: fixture.schema_name)

  defp audit_count(fixture), do: Repo.aggregate(Entry, :count, :id, prefix: fixture.schema_name)

  defp rows(fixture), do: Repo.all(from(j in Job, order_by: j.id), prefix: fixture.schema_name)

  defp six_requests(id) do
    [
      {:get, "/", nil},
      {:post, "/", %{}},
      {:get, "/#{id}", nil},
      {:patch, "/#{id}", %{"title" => "x"}},
      {:post, "/#{id}/enable", %{}},
      {:post, "/#{id}/disable", %{}}
    ]
  end

  # ── P: permission ──────────────────────────────────────────────────────────

  describe "P permission" do
    test "P1 tenant scope, last of the core permissions, identity required_permission" do
      assert Authorization.permission_scope(:ScheduledJobsManage) == :tenant
      assert Authorization.core_permissions() |> Enum.take(-2) |> hd() == :ScheduledJobsManage
      assert Authorization.required_permission(:ScheduledJobsManage) == :ScheduledJobsManage
    end

    test "P2 only TENANT_ADMIN holds it in a tenant; PLATFORM_ADMIN only in the platform tenant" do
      holders =
        for role <- Authorization.roles(),
            Authorization.has_permission_in_scope?([role], :ScheduledJobsManage, false),
            do: role

      assert holders == [:TENANT_ADMIN]

      assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], :ScheduledJobsManage, true)

      refute Authorization.has_permission_in_scope?(
               [:PLATFORM_ADMIN],
               :ScheduledJobsManage,
               false
             )
    end

    test "P3 the six routes map to the one policy key" do
      for {method, path} <- [
            {"GET", "/scheduled-jobs"},
            {"GET", "/scheduled-jobs/:id"},
            {"POST", "/scheduled-jobs"},
            {"PATCH", "/scheduled-jobs/:id"},
            {"POST", "/scheduled-jobs/:id/enable"},
            {"POST", "/scheduled-jobs/:id/disable"}
          ] do
        assert Authorization.endpoint_policy_key(method, path) == :ScheduledJobsManage
      end
    end
  end

  # ── R: statuses and shapes ─────────────────────────────────────────────────

  describe "R routes" do
    test "R1 create 201 with the allowlist, first slot, one audit entry", %{a: a, name_a: name} do
      conn = create(a, name)
      assert conn.status == 201
      job = json(conn)

      refute Map.has_key?(job, "tenant_id")
      assert job["enabled"] == true
      assert job["interval_minutes"] == 60
      assert job["variables"] == %{"batch" => "nightly"}
      assert is_binary(job["next_run_at"])
      assert job_count(a) == 1

      assert Repo.aggregate(
               from(e in Entry, where: e.action == "scheduled_job.created"),
               :count,
               :id,
               prefix: a.schema_name
             ) == 1
    end

    test "R2 list and read; an absent id is 404", %{a: a, name_a: name} do
      job = job!(a, name)

      list = call(:get, "/", a, @admin)
      assert list.status == 200
      assert [%{"id" => id}] = json(list)["items"]
      assert id == job["id"]

      assert call(:get, "/#{job["id"]}", a, @admin).status == 200
      assert call(:get, "/#{Ecto.UUID.generate()}", a, @admin).status == 404
      assert call(:get, "/not-a-uuid", a, @admin).status == 404
    end

    test "R3 update, enable and disable; validation errors and duplicate key are 422",
         %{a: a, name_a: name} do
      job = job!(a, name)
      id = job["id"]

      upd = call(:patch, "/#{id}", a, @admin, %{"title" => "Renamed", "interval_minutes" => 120})
      assert upd.status == 200
      assert json(upd)["title"] == "Renamed"

      assert json(call(:post, "/#{id}/disable", a, @admin, %{}))["enabled"] == false
      assert call(:post, "/#{id}/disable", a, @admin, %{}).status == 200
      assert json(call(:post, "/#{id}/enable", a, @admin, %{}))["enabled"] == true

      bad = call(:patch, "/#{id}", a, @admin, %{"interval_minutes" => 1})
      assert bad.status == 422
      assert [%{"field" => "interval_minutes", "constraint" => "invalid"}] = json(bad)["errors"]

      before = job_count(a)
      dup = create(a, name, %{"key" => job["key"]})
      assert dup.status == 422
      assert [%{"field" => "key", "constraint" => "taken"}] = json(dup)["errors"]
      assert job_count(a) == before

      missing = create(a, name, %{"title" => ""})
      assert missing.status == 422
      assert Enum.any?(json(missing)["errors"], &(&1["constraint"] == "required"))

      assert call(:post, "/", a, @admin, %{"x" => 1}).status == 422
    end

    test "R4 a secret-looking variable is refused through the route", %{a: a, name_a: name} do
      conn = create(a, name, %{"variables" => %{"password" => "hunter2"}})
      assert conn.status == 422
      assert [%{"field" => "variables", "constraint" => "secret_like"}] = json(conn)["errors"]
      assert job_count(a) == 0
      refute conn.resp_body =~ "hunter2"
    end
  end

  # ── S: create and enable start checks ──────────────────────────────────────

  describe "S start checks" do
    test "S1 a scope node outside the caller's grants: create and enable are 422",
         %{a: a, name_a: name} do
      schema = a.schema_name
      scoped = Fx.actor!(schema)
      Fx.drop_roles!(schema, scoped.id)
      group = Rsg.fresh_group!(schema)
      Rsg.member!(schema, group.id, scoped)
      Rsg.raw_binding!(schema, "PROCESS_OPERATOR", :platform_role, group.id)
      Rsg.raw_scoped_row!(schema, group.id, "PROCESS_OPERATOR", Rsg.node!(schema))

      other_node = Rsg.node!(schema)
      before_audit = audit_count(a)

      conn = create(a, name, %{"scope_node_id" => other_node}, @admin, user_id: scoped.id)
      assert conn.status == 422
      assert json(conn)["detail"] == "invalid_scope_node"
      assert job_count(a) == 0
      assert audit_count(a) == before_audit

      job = Fx.job!(schema, scoped.id, name, %{scope_node_id: other_node})

      {1, _} =
        Repo.update_all(from(j in Job, where: j.id == ^job.id), [set: [enabled: false]],
          prefix: schema
        )

      before_rows = rows(a)

      conn = call(:post, "/#{job.id}/enable", a, @admin, %{}, user_id: scoped.id)
      assert conn.status == 422
      assert rows(a) == before_rows

      # A tenant-wide administrator may start in that node.
      admin = Fx.actor!(schema)
      Rsg.raw_user_row!(schema, admin.id, "TENANT_ADMIN", nil)
      ok = create(a, name, %{"scope_node_id" => other_node}, @admin, user_id: admin.id)
      assert ok.status == 201
    end

    test "S3 an API-token credential cannot create or enable", %{a: a, name_a: name} do
      job = job!(a, name)
      before = job_count(a)

      conn = create(a, name, %{}, @admin, credential: :api_token)
      assert conn.status == 403
      assert conn.resp_body =~ "api_token_not_allowed"
      assert job_count(a) == before

      conn = call(:post, "/#{job["id"]}/enable", a, @admin, %{}, credential: :api_token)
      assert conn.status == 403
    end
  end

  # ── X: INV-10 ──────────────────────────────────────────────────────────────

  describe "X cross-tenant" do
    setup %{a: a, b: b, name_a: name_a} do
      job_a = job!(a, name_a)
      %{job_a: job_a, absent: call(:get, "/#{Ecto.UUID.generate()}", b, @admin), b: b}
    end

    test "X1/X2 tenant B on A's job id gets the absent-id answer, and A's rows stay unchanged",
         %{a: a, b: b, job_a: job_a, absent: absent} do
      before_rows = rows(a)
      before_audit = audit_count(a)
      id = job_a["id"]

      for {method, path, req_body} <- [
            {:get, "/#{id}", nil},
            {:patch, "/#{id}", %{"title" => "hijack"}},
            {:post, "/#{id}/enable", %{}},
            {:post, "/#{id}/disable", %{}}
          ] do
        conn = call(method, path, b, @admin, req_body)

        assert {conn.status, conn.resp_body} == {absent.status, absent.resp_body},
               "#{method} #{path}"
      end

      assert rows(a) == before_rows
      assert audit_count(a) == before_audit
    end

    test "X3 a tenant id in path, query or body never reaches another schema",
         %{a: a, b: b, job_a: job_a, name_b: name_b} do
      a_id = a.tenant_id

      listed = call(:get, "/?tenant_id=#{a_id}", b, @admin)
      assert listed.status == 200
      assert json(listed)["items"] == []

      assert call(:get, "/#{a_id}", b, @admin).status == 404

      before_a = job_count(a)
      conn = create(b, name_b, %{"tenant_id" => a_id})
      assert conn.status == 422
      assert [%{"field" => "tenant_id", "constraint" => "not_accepted"}] = json(conn)["errors"]
      assert job_count(a) == before_a
      assert job_count(b) == 0
      assert job_a["id"]
    end

    test "X4 B's list never holds A's job and keys are per tenant",
         %{a: a, b: b, job_a: job_a, name_b: name_b} do
      assert json(call(:get, "/", b, @admin))["items"] == []
      assert create(b, name_b, %{"key" => job_a["key"]}).status == 201
      assert job_count(a) == 1
    end

    test "X5 the tenant comes from the auth context, not from headers or params",
         %{a: a, b: b, job_a: job_a, name_b: name_b} do
      conn =
        Fixture.router_conn(:post, "/?tenant=#{a.tenant.slug}", b, @admin, body(name_b))
        |> Plug.Conn.put_req_header("x-tenant-id", a.tenant_id)
        |> Plug.Conn.put_req_header("x-tenant-slug", a.tenant.slug)
        |> Plug.Conn.assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: b.tenant_id,
          roles: @admin,
          credential: :oidc
        })

      assert Router.call(conn, Router.init([])).status == 201
      assert job_count(b) == 1
      assert job_count(a) == 1
      assert job_a["id"]
    end

    test "X6 a caller without the permission gets the plain 404 on every route, identical to an absent id",
         %{a: a, b: b, job_a: job_a, absent: absent} do
      before_rows = rows(a)
      before_audit = audit_count(a)
      own = job!(b, Fx.definition!(b.schema_name))

      for roles <- @denied,
          id <- [own["id"], Ecto.UUID.generate(), job_a["id"]],
          {method, path, req_body} <- six_requests(id) do
        conn = call(method, path, b, roles, req_body)

        assert {conn.status, conn.resp_body} == {absent.status, absent.resp_body},
               "#{inspect(roles)} #{method} #{path}"
      end

      assert rows(a) == before_rows
      assert audit_count(a) == before_audit
      assert json(call(:get, "/#{own["id"]}", b, @admin))["enabled"] == true
      assert job_count(b) == 1
    end

    test "X7 through the full pipeline, B's admin on A's job id gets 404 on every id route",
         %{a: a, b: b, job_a: job_a} do
      token = Fixture.mint_token!(b, @admin)
      before_rows = rows(a)

      for {method, path, req_body} <- six_requests(job_a["id"]),
          String.contains?(path, "/") and path != "/" do
        conn =
          Fixture.api_conn(
            method,
            "/api/v1/scheduled-jobs" <> path,
            token,
            b.tenant.slug,
            req_body
          )
          |> Fixture.dispatch_api()

        assert conn.status == 404, "#{method} #{path}: #{conn.status}"
      end

      assert rows(a) == before_rows
    end
  end

  # ── C: concealed key ───────────────────────────────────────────────────────

  describe "C concealed key" do
    test "C1 the scheduled-jobs key is concealed, a non-concealed key still answers 403",
         %{a: a} do
      conn = call(:get, "/", a, ["TASK_WORKER"])
      assert conn.status == 404
      assert json(conn)["title"] == "Not Found"
    end
  end

  # ── F: flag ────────────────────────────────────────────────────────────────

  describe "F flag" do
    test "F1 flag off: every route answers the unregistered-path 404, create writes nothing",
         %{a: a, name_a: name} do
      Application.put_env(:letflow, :scheduled_jobs, enabled: false)
      admin_token = Fixture.mint_token!(a, @admin)
      worker_token = Fixture.mint_token!(a, ["TASK_WORKER"])

      unregistered =
        Fixture.api_conn(:get, "/api/v1/scheduled-jobs-nope", admin_token, a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert unregistered.status == 404

      for token <- [admin_token, worker_token],
          {method, path, req_body} <- six_requests(Ecto.UUID.generate()) do
        conn =
          Fixture.api_conn(
            method,
            "/api/v1/scheduled-jobs" <> path,
            token,
            a.tenant.slug,
            req_body
          )
          |> Fixture.dispatch_api()

        assert {conn.status, untraced(conn)} == {404, untraced(unregistered)}, "#{method} #{path}"
      end

      assert create(a, name).status == 404
      assert job_count(a) == 0
    end

    test "F2/F3 the flag defaults off and the routes read the context's flag" do
      assert @compiled_default == [enabled: false]
      assert ScheduledJobs.enabled?()
      Application.put_env(:letflow, :scheduled_jobs, enabled: false)
      refute ScheduledJobs.enabled?()
    end
  end

  # ── M: mounted ─────────────────────────────────────────────────────────────

  describe "M mounted" do
    test "M1 six routes, one key, reachable through the full pipeline", %{a: a} do
      routes = Router.__authz_routes__()
      assert length(routes) == 6
      assert Enum.all?(routes, fn {_m, _p, key} -> key == :ScheduledJobsManage end)

      token = Fixture.mint_token!(a, @admin)

      conn =
        Fixture.api_conn(:get, "/api/v1/scheduled-jobs", token, a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert conn.status == 200
      assert json(conn)["items"] == []
    end
  end
end
