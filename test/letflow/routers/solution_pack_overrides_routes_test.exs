defmodule Letflow.Routers.SolutionPackOverridesRoutesTest do
  @moduledoc """
  REQ-596 / GH #3353 part B: the four `/solution-packs/:pack_id/overrides` routes and the
  `:SolutionOverridesManage` permission (design state/tasks/T-0808/design.md, ids R1..R4, H1..H5,
  C1..C3, P1, P2). Every request goes through the full `Letflow.Router` pipeline with a real API
  token.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the platform-tenant pin is
  VM-global (same reasoning as `solution_packs_update_test.exs`).

  H5 patches a node label (`"Tier 987654.321"`), not a `settings.*` value: the settings lookup of
  part A needs a module wrapping the pack, which the router cannot be given (`modules:` is a test
  seam of the writer only). The label is a stored patch value all the same.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Authorization
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Definitions.SolutionPackOverrides, as: Overrides
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @admin "TENANT_ADMIN"
  @label %{"nodes.n1.label" => "Approve"}

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)

    ids = for t <- [tenants.a, tenants.b, tenants.p], do: t.tenant_id

    on_exit(fn ->
      Repo.delete_all(from(r in PackUpdateResolution, where: r.tenant_id in ^ids))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id in ^ids))
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id in ^ids))
    end)

    {:ok, tenants}
  end

  # -- helpers ------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp install!(fx, pack_id, artefact_id \\ "a1") do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    %SolutionPackInstall{}
    |> SolutionPackInstall.insert_changeset(%{
      tenant_id: fx.tenant_id,
      pack_id: pack_id,
      installed_version: "1.0.0",
      installed_at: now
    })
    |> Repo.insert!()

    %SolutionPackArtefactBase{}
    |> SolutionPackArtefactBase.upsert_changeset(%{
      tenant_id: fx.tenant_id,
      pack_id: pack_id,
      artefact_type: "process_definition",
      artefact_id: artefact_id,
      base_version: "1.0.0",
      base_content: "base-#{artefact_id}",
      captured_at: now
    })
    |> Repo.insert!()

    :ok
  end

  defp base_path(pack_id), do: "/api/v1/solution-packs/#{pack_id}/overrides"

  defp call(method, path, token, fx, body \\ nil) do
    method |> Fixture.api_conn(path, token, fx.tenant.slug, body) |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # the problem body carries a per-request trace_id; everything else must be identical
  defp no_trace(body), do: body |> Jason.decode!() |> Map.delete("trace_id")

  defp create_body(extra \\ %{}) do
    Map.merge(
      %{
        "artefact_type" => "process_definition",
        "artefact_id" => "a1",
        "patch" => @label,
        "reason" => "local wording"
      },
      extra
    )
  end

  defp create!(fx, token, pack_id, extra \\ %{}) do
    conn = call(:post, base_path(pack_id), token, fx, create_body(extra))
    assert conn.status == 201, conn.resp_body
    json(conn)
  end

  defp count(fx) do
    %{rows: [[n]]} =
      Repo.query!(~s|SELECT count(*) FROM "#{fx.schema_name}".solution_pack_overrides|)

    n
  end

  defp audit_count(fx) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{fx.schema_name}".audit_entries WHERE resource_type = 'solution_pack_override'|
      )

    n
  end

  # one admin token and one pack with an install and a base for tenant A
  defp world(ctx) do
    pack_id = unique("s2routes")
    install!(ctx.a, pack_id)
    {Fixture.mint_token!(ctx.a, [@admin]), pack_id}
  end

  # -- R: the routes ------------------------------------------------------------------------

  describe "R routes" do
    test "R1: create v1, write v2, retire; the list shows the latest version per override", ctx do
      {token, pack_id} = world(ctx)
      v1 = create!(ctx.a, token, pack_id)

      assert %{"override_version" => 1, "status" => "active", "pack_id" => ^pack_id} = v1
      assert v1["patch"] == @label
      assert v1["made_against"] == "1.0.0"

      id = v1["override_id"]
      path = base_path(pack_id) <> "/#{id}"

      conn =
        call(:post, path <> "/versions", token, ctx.a, %{
          "patch" => %{"nodes.n1.label" => "Review"},
          "reason" => "second wording"
        })

      assert conn.status == 200
      assert %{"override_version" => 2, "status" => "active"} = json(conn)

      assert [%{"override_version" => 2, "patch" => %{"nodes.n1.label" => "Review"}}] =
               call(:get, base_path(pack_id), token, ctx.a) |> json() |> Map.fetch!("overrides")

      conn = call(:post, path <> "/retire", token, ctx.a, %{"reason" => "no longer needed"})
      assert conn.status == 200
      assert %{"override_version" => 3, "status" => "retired", "patch" => patch} = json(conn)
      assert patch == %{}

      list = call(:get, base_path(pack_id), token, ctx.a)
      assert list.status == 200

      assert [%{"override_id" => ^id, "override_version" => 3, "status" => "retired"}] =
               json(list)["overrides"]

      assert count(ctx.a) == 3
      assert audit_count(ctx.a) == 3

      conn = call(:post, path <> "/versions", token, ctx.a, %{"patch" => @label, "reason" => "x"})
      assert conn.status == 422 and conn.resp_body =~ "override_retired"
    end

    test "R2: unknown or foreign override, other pack, pack without install: one not-found",
         ctx do
      {token, pack_id} = world(ctx)
      other_pack = unique("s2routes-other")
      install!(ctx.a, other_pack, "a9")
      v1 = create!(ctx.a, token, pack_id)
      absent = Ecto.UUID.generate()
      no_install = unique("s2routes-none")
      body = %{"patch" => @label, "reason" => "x"}

      requests = [
        {:get, base_path(no_install), nil},
        {:post, base_path(no_install), create_body()},
        {:post, base_path(no_install) <> "/#{v1["override_id"]}/versions", body},
        {:post, base_path(pack_id) <> "/#{absent}/versions", body},
        {:post, base_path(pack_id) <> "/not-a-uuid/versions", body},
        {:post, base_path(pack_id) <> "/#{absent}/retire", %{"reason" => "x"}},
        # an override of pack_id addressed under another pack of the same tenant
        {:post, base_path(other_pack) <> "/#{v1["override_id"]}/versions", body},
        {:post, base_path(other_pack) <> "/#{v1["override_id"]}/retire", %{"reason" => "x"}}
      ]

      replies =
        for {method, path, req_body} <- requests do
          conn = call(method, path, token, ctx.a, req_body)
          assert conn.status == 404, "#{method} #{path}: #{conn.status} #{conn.resp_body}"
          {conn.status, no_trace(conn.resp_body)}
        end

      assert replies |> Enum.uniq() |> length() == 1, inspect(replies)
      assert count(ctx.a) == 1
    end

    test "R3: PATCH, PUT and DELETE are not routed", ctx do
      {token, pack_id} = world(ctx)
      v1 = create!(ctx.a, token, pack_id)

      for method <- [:patch, :put, :delete],
          path <- [
            base_path(pack_id),
            base_path(pack_id) <> "/#{v1["override_id"]}",
            base_path(pack_id) <> "/#{v1["override_id"]}/versions",
            base_path(pack_id) <> "/#{v1["override_id"]}/retire"
          ] do
        conn = call(method, path, token, ctx.a, %{"reason" => "x"})
        assert conn.status in [403, 404, 405], "#{method} #{path}: #{conn.status}"
      end

      assert count(ctx.a) == 1
    end

    test "R4: a second non-retired override on the same artefact is override_exists", ctx do
      {token, pack_id} = world(ctx)
      v1 = create!(ctx.a, token, pack_id)

      conn = call(:post, base_path(pack_id), token, ctx.a, create_body())
      assert conn.status == 422 and conn.resp_body =~ "override_exists"
      assert count(ctx.a) == 1

      # after a retire the artefact is free again
      call(:post, base_path(pack_id) <> "/#{v1["override_id"]}/retire", token, ctx.a, %{
        "reason" => "free it"
      })

      assert create!(ctx.a, token, pack_id)["override_version"] == 1
    end

    test "R5: a wrong base_version type is 422 invalid_input, a body that is no object is 400",
         ctx do
      {token, pack_id} = world(ctx)
      v1 = create!(ctx.a, token, pack_id)
      path = base_path(pack_id) <> "/#{v1["override_id"]}/versions"

      for bad <- ["1", 1.5, 0, -1, true] do
        conn =
          call(:post, path, token, ctx.a, %{
            "patch" => @label,
            "reason" => "x",
            "base_version" => bad
          })

        assert conn.status == 422 and conn.resp_body =~ "invalid_input", inspect(bad)
      end

      conn = call(:post, base_path(pack_id), token, ctx.a, [1, 2])
      assert conn.status in [400, 422]
      assert count(ctx.a) == 1
    end
  end

  # -- H: the HTTP side of the writer's criteria ----------------------------------------------

  describe "H http mapping" do
    test "H1: every closed-list refusal is 422 property_not_overridable and writes nothing",
         ctx do
      {token, pack_id} = world(ctx)

      patches = [
        %{"nodes.n1.type" => "service"},
        %{"edges.e1.target" => "n2"},
        %{"nodes.n1.id" => "z"},
        %{"nodes.g1.condition" => "x == 1"},
        %{"variables.v1.name" => "renamed"},
        %{"variables.v1.type" => "string"},
        %{"nodes.n1.script" => "1 + 1"},
        %{"unlisted.path" => "v"},
        # settings.<key>: (a) no module wraps this pack, (b) key not in a schema, (c) not a key
        %{"settings.threshold" => 5},
        %{"settings.no_such_key" => 5},
        %{"settings." => 5},
        # mixed: one listed and one unlisted path is refused whole
        %{"nodes.n1.label" => "ok", "nodes.n1.script" => "1"}
      ]

      for patch <- patches do
        conn = call(:post, base_path(pack_id), token, ctx.a, create_body(%{"patch" => patch}))

        assert conn.status == 422 and conn.resp_body =~ "property_not_overridable",
               "#{inspect(patch)}: #{conn.status} #{conn.resp_body}"
      end

      conn =
        call(
          :post,
          base_path(pack_id),
          token,
          ctx.a,
          create_body(%{"artefact_type" => "variable_schema"})
        )

      assert conn.status == 422 and conn.resp_body =~ "property_not_overridable"

      # the same refusal on a new version, where a row already exists
      v1 = create!(ctx.a, token, pack_id)
      path = base_path(pack_id) <> "/#{v1["override_id"]}/versions"

      conn =
        call(:post, path, token, ctx.a, %{
          "patch" => %{"nodes.n1.script" => "1"},
          "reason" => "x"
        })

      assert conn.status == 422 and conn.resp_body =~ "property_not_overridable"
      assert count(ctx.a) == 1
      assert audit_count(ctx.a) == 1
    end

    test "H2: two concurrent version requests leave one winner, one 422, one new row", ctx do
      {token, pack_id} = world(ctx)
      v1 = create!(ctx.a, token, pack_id)
      path = base_path(pack_id) <> "/#{v1["override_id"]}/versions"

      write = fn label ->
        call(:post, path, token, ctx.a, %{
          "patch" => %{"nodes.n1.label" => label},
          "reason" => "race",
          "base_version" => 1
        })
      end

      replies =
        ["A", "B"]
        |> Enum.map(fn l -> Task.async(fn -> write.(l) end) end)
        |> Task.await_many(30_000)
        # On a loaded runner the loser can wait past the 2s lock_timeout and answer 503 busy
        # (it wrote nothing); resending the same body makes it meet the committed version 2.
        |> Enum.zip(["A", "B"])
        |> Enum.map(fn
          {%{status: 503}, l} -> write.(l)
          {reply, _} -> reply
        end)

      assert replies |> Enum.map(& &1.status) |> Enum.sort() == [200, 422]
      assert Enum.any?(replies, &(&1.status == 422 and &1.resp_body =~ "override_version_taken"))
      assert count(ctx.a) == 2
    end

    test "H2b: a stale base_version is refused, an omitted one is accepted (last writer wins)",
         ctx do
      {token, pack_id} = world(ctx)
      v1 = create!(ctx.a, token, pack_id)
      path = base_path(pack_id) <> "/#{v1["override_id"]}/versions"

      ok =
        call(:post, path, token, ctx.a, %{
          "patch" => @label,
          "reason" => "v2",
          "base_version" => 1
        })

      assert ok.status == 200

      stale =
        call(:post, path, token, ctx.a, %{
          "patch" => @label,
          "reason" => "late",
          "base_version" => 1
        })

      assert stale.status == 422 and stale.resp_body =~ "override_version_taken"
      assert count(ctx.a) == 2

      omitted = call(:post, path, token, ctx.a, %{"patch" => @label, "reason" => "v3"})
      assert omitted.status == 200
      assert json(omitted)["override_version"] == 3
    end

    test "H3: no reason (missing, blank, not a string) is 422 and writes neither row nor audit",
         ctx do
      {token, pack_id} = world(ctx)
      v1 = create!(ctx.a, token, pack_id)
      rows = {count(ctx.a), audit_count(ctx.a)}
      base = base_path(pack_id)

      for reason <- [:missing, "", "   ", 5, nil] do
        with_reason = fn m ->
          if reason == :missing, do: Map.delete(m, "reason"), else: Map.put(m, "reason", reason)
        end

        id = v1["override_id"]

        for {path, body} <- [
              {base, create_body()},
              {base <> "/#{id}/versions", %{"patch" => @label}},
              {base <> "/#{id}/retire", %{}}
            ] do
          conn = call(:post, path, token, ctx.a, with_reason.(body))
          assert conn.status == 422 and conn.resp_body =~ "reason_required", inspect(reason)
        end
      end

      assert rows == {count(ctx.a), audit_count(ctx.a)}
    end

    test "H4: with audit_entries dropped the request answers a non-500 error and leaves no row",
         ctx do
      {token, pack_id} = world(ctx)
      Repo.query!(~s|DROP TABLE "#{ctx.a.schema_name}".audit_entries|)

      conn = call(:post, base_path(pack_id), token, ctx.a, create_body())

      assert conn.status != 500
      assert conn.status >= 400
      assert count(ctx.a) == 0
    end

    test "H5: the distinctive value is in no log line at :info and not in the audit entries",
         ctx do
      {token, pack_id} = world(ctx)
      value = "Tier 987654.321"

      log =
        capture_log([level: :info], fn ->
          v1 = create!(ctx.a, token, pack_id, %{"patch" => %{"nodes.n1.label" => value}})
          path = base_path(pack_id) <> "/#{v1["override_id"]}"

          conn =
            call(:post, path <> "/versions", token, ctx.a, %{
              "patch" => %{"nodes.n1.label" => value <> "1"},
              "reason" => "new version"
            })

          assert conn.status == 200
          assert call(:post, path <> "/retire", token, ctx.a, %{"reason" => "done"}).status == 200
        end)

      refute log =~ "987654.321"
      assert count(ctx.a) == 3

      %{rows: rows} =
        Repo.query!(
          ~s|SELECT before_state::text, after_state::text FROM "#{ctx.a.schema_name}".audit_entries WHERE resource_type = 'solution_pack_override'|
        )

      assert length(rows) == 3
      refute inspect(rows) =~ "987654"
    end
  end

  # -- C: tenant isolation --------------------------------------------------------------------

  describe "C tenant isolation" do
    test "C1: tenant B's admin gets the absent-id reply for A's override on every route", ctx do
      {token_a, pack_id} = world(ctx)
      install!(ctx.b, pack_id)
      token_b = Fixture.mint_token!(ctx.b, [@admin])
      v1 = create!(ctx.a, token_a, pack_id)
      absent = Ecto.UUID.generate()
      body = %{"patch" => @label, "reason" => "x"}

      view = fn conn ->
        headers =
          conn.resp_headers
          |> Enum.reject(fn {k, _} -> k =~ ~r/request-id|trace|date/i end)
          |> Enum.sort()

        {conn.status, headers, no_trace(conn.resp_body)}
      end

      for {suffix, req_body} <- [{"versions", body}, {"retire", %{"reason" => "x"}}] do
        foreign =
          call(
            :post,
            base_path(pack_id) <> "/#{v1["override_id"]}/#{suffix}",
            token_b,
            ctx.b,
            req_body
          )

        missing =
          call(:post, base_path(pack_id) <> "/#{absent}/#{suffix}", token_b, ctx.b, req_body)

        assert foreign.status == 404
        assert view.(foreign) == view.(missing), inspect({view.(foreign), view.(missing)})
      end

      # B lists its own (empty) data, never A's
      assert [] =
               call(:get, base_path(pack_id), token_b, ctx.b) |> json() |> Map.fetch!("overrides")

      assert count(ctx.a) == 1
      assert count(ctx.b) == 0
    end

    test "C2: a tenant id in the path, query or body is ignored", ctx do
      {token_a, pack_id} = world(ctx)
      install!(ctx.b, pack_id)
      token_b = Fixture.mint_token!(ctx.b, [@admin])
      v1 = create!(ctx.a, token_a, pack_id)

      forged = %{"tenant_id" => ctx.a.tenant_id, "schema_name" => ctx.a.schema_name}

      # B's token with A's id in the query and the body still reads and writes B's schema
      list = call(:get, base_path(pack_id) <> "?tenant_id=#{ctx.a.tenant_id}", token_b, ctx.b)
      assert json(list)["overrides"] == []

      created = call(:post, base_path(pack_id), token_b, ctx.b, create_body(forged))
      assert created.status == 201
      assert count(ctx.b) == 1
      assert count(ctx.a) == 1

      # A's override id under B's token is still not found
      conn =
        call(
          :post,
          base_path(pack_id) <> "/#{v1["override_id"]}/retire?tenant_id=#{ctx.a.tenant_id}",
          token_b,
          ctx.b,
          Map.put(forged, "reason", "x")
        )

      assert conn.status == 404
      assert count(ctx.a) == 1
    end

    test "C3: a PLATFORM_ADMIN token gets its own tenant's data only", ctx do
      {token_a, pack_id} = world(ctx)
      install!(ctx.p, pack_id)
      token_p = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])
      create!(ctx.a, token_a, pack_id)

      assert [] =
               call(:get, base_path(pack_id), token_p, ctx.p) |> json() |> Map.fetch!("overrides")

      mine = create!(ctx.p, token_p, pack_id)

      assert [%{"override_id" => id}] =
               call(:get, base_path(pack_id), token_p, ctx.p) |> json() |> Map.fetch!("overrides")

      assert id == mine["override_id"]
      assert count(ctx.p) == 1
      assert count(ctx.a) == 1
    end
  end

  # -- P: permission --------------------------------------------------------------------------

  describe "P permission" do
    test "P1: only TENANT_ADMIN writes; every other tenant role gets 403; GET needs DefinitionsRead",
         ctx do
      {token, pack_id} = world(ctx)
      v1 = create!(ctx.a, token, pack_id)
      before = {count(ctx.a), audit_count(ctx.a)}
      id = v1["override_id"]

      others =
        ~w(PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER AGENT_RUNNER CANDIDATE TENANT_AUDITOR)

      for role <- others do
        t = Fixture.mint_token!(ctx.a, [role])

        for {path, body} <- [
              {base_path(pack_id), create_body()},
              {base_path(pack_id) <> "/#{id}/versions", %{"patch" => @label, "reason" => "x"}},
              {base_path(pack_id) <> "/#{id}/retire", %{"reason" => "x"}}
            ] do
          conn = call(:post, path, t, ctx.a, body)
          assert conn.status == 403, "#{role} #{path}: #{conn.status}"
        end
      end

      assert before == {count(ctx.a), audit_count(ctx.a)}

      for role <- others do
        expected =
          if Authorization.role_allows?(String.to_atom(role), :DefinitionsRead),
            do: 200,
            else: 403

        t = Fixture.mint_token!(ctx.a, [role])
        assert call(:get, base_path(pack_id), t, ctx.a).status == expected, role
      end

      assert call(:get, base_path(pack_id), Fixture.mint_token!(ctx.a, ["TASK_WORKER"]), ctx.a).status ==
               200

      assert call(:get, base_path(pack_id), Fixture.mint_token!(ctx.a, ["CANDIDATE"]), ctx.a).status ==
               403
    end

    test "P2: tenant scope, TENANT_ADMIN only, and the policy keys of the four routes" do
      assert Authorization.permission_scope(:SolutionOverridesManage) == :tenant

      assert Authorization.required_permission(:SolutionOverridesManage) ==
               :SolutionOverridesManage

      assert :SolutionOverridesManage in Authorization.core_permissions()

      holders =
        Enum.filter(
          Authorization.roles(),
          &Authorization.role_allows?(&1, :SolutionOverridesManage)
        )

      assert Enum.sort(holders) == [:PLATFORM_ADMIN, :TENANT_ADMIN]

      assert Authorization.endpoint_policy_key("GET", "/solution-packs/:pack_id/overrides") ==
               :DefinitionsRead

      for path <- [
            "/solution-packs/:pack_id/overrides",
            "/solution-packs/:pack_id/overrides/:override_id/versions",
            "/solution-packs/:pack_id/overrides/:override_id/retire"
          ] do
        assert Authorization.endpoint_policy_key("POST", path) == :SolutionOverridesManage
      end
    end

    test "P3: list/3 and fetch/4 give not_found for a wrong pack or a pack without install",
         ctx do
      {token, pack_id} = world(ctx)
      v1 = create!(ctx.a, token, pack_id)
      schema = ctx.a.schema_name
      tenant = ctx.a.tenant_id

      assert {:ok, [row]} = Overrides.list(schema, tenant, pack_id)
      assert row.override_id == v1["override_id"]
      assert {:ok, ^row} = Overrides.fetch(schema, tenant, pack_id, v1["override_id"])

      assert {:error, :not_found} =
               Overrides.fetch(schema, tenant, "other-pack", v1["override_id"])

      assert {:error, :not_found} = Overrides.list(schema, tenant, "other-pack")
      assert {:error, :not_found} = Overrides.list(schema, ctx.b.tenant_id, pack_id)
    end
  end
end
