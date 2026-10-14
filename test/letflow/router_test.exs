defmodule Letflow.RouterTest do
  @moduledoc """
  Tests for `Letflow.Router` (REQ-046, `test/specs/REQ-046.md`).

  Router-level end-to-end tests via `Plug.Test`, per
  `docs/guides/test_developer_guide.md` §2 ("test/letflow/*_test.exs exercising
  Letflow.Router end to end ... coverage target: every documented HTTP endpoint") and
  the `Plug.Test` convention already established in
  `test/letflow/plugs/tenant_status_test.exs`. No database dependency: every route this
  module currently exposes (`GET /health`, the 404 catch-all) is DB-free by design (the
  health check's own inline comment states this explicitly), so plain `ExUnit.Case` is
  used rather than `Letflow.DataCase`.

  REQ-046 removed three routes (`POST /instances`, `POST /instances/:id/actions`,
  `GET /instances/:id`) that used to call `Letflow.InstanceSupervisor.start_instance/1`
  and `Letflow.ProcessInstance.*` — both now deleted. Cases 2-4 below are regression
  coverage for that deletion: run against the pre-REQ-046 router they would not have
  seen a clean 404 at all, they would have hit a runtime `UndefinedFunctionError`
  (wrapped as a 500 by Plug's error handling), since the routes existed but called
  functions that no longer compiled. Passing here proves the routes were cleanly
  removed, not left dangling.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @opts Letflow.Router.init([])
  @identity_opts Letflow.Routers.Identity.init([])

  # The exact RFC 9457 Problem Details body `Letflow.Api.Error.not_found/0`
  # produces (REQ-066). Spelled out literally rather than derived from the
  # constructor, so a change to the wire contract has to be made deliberately
  # here too. `type` uses the compile-time default for
  # `config :letflow, :problems_base_uri`, which nothing currently overrides.
  @not_found_body %{
    "type" => "https://bpm.example.com/problems/not-found",
    "title" => "Not Found",
    "status" => 404,
    "detail" => "the requested resource was not found",
    "trace_id" => ""
  }

  defp call(conn), do: Letflow.Router.call(conn, @opts)

  test "GET /health returns 200 and status ok" do
    conn = conn(:get, "/health") |> call()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok", "sha" => Letflow.BuildInfo.sha()}
  end

  test "POST /instances now falls through to 404" do
    conn =
      conn(:post, "/instances", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == @not_found_body
  end

  test "POST /instances/:id/actions now falls through to 404" do
    id = Ecto.UUID.generate()

    conn =
      conn(:post, "/instances/#{id}/actions", Jason.encode!(%{action: "approve"}))
      |> put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == @not_found_body
  end

  test "GET /instances/:id now falls through to 404" do
    id = Ecto.UUID.generate()

    conn = conn(:get, "/instances/#{id}") |> call()

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == @not_found_body
  end

  test "an arbitrary unknown route still 404s" do
    conn = conn(:get, "/definitely/not/a/route") |> call()

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == @not_found_body
  end

  # ── REQ-070 tests ─────────────────────────────────────────────────────────

  describe "REQ-070 AC1: /health requires no database sandbox" do
    # This module uses `use ExUnit.Case, async: true` — no DataCase, no
    # `Ecto.Adapters.SQL.Sandbox.checkout/1`. Passing proves no DB dependency.
    test "GET /health returns 200 without Ecto.Sandbox checkout" do
      conn = conn(:get, "/health") |> call()
      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "status" => "ok",
               "sha" => Letflow.BuildInfo.sha()
             }
    end
  end

  describe "REQ-070 AC2: sub-router isolation" do
    # As of REQ-131, Letflow.Routers.Identity's own pipeline (use
    # Letflow.Api.AuthorizedRouter) runs Letflow.Plugs.Authorize
    # unconditionally between :match and :dispatch, for every request
    # including one matching the `match _` catch-all -- and that plug's
    # FIRST step is Letflow.Api.Context.scoped_repo_opts/1, which requires
    # conn.assigns[:auth_context] to already be populated (normally
    # Letflow.Plugs.AuthPipeline's job, upstream of this router in the real
    # /api/v1 pipeline). This test deliberately dispatches straight to
    # Letflow.Routers.Identity.call/2 with no auth_context at all, to prove
    # sub-router isolation (this module compiles and runs its own full
    # match/Authorize/dispatch pipeline independently of Letflow.Router) --
    # so the correct, expected result is 500 (Letflow.Api.Response.internal_error/1,
    # `{:error, :missing_auth_context}`), not a database-touching 404. This
    # module is deliberately DB-free (see its own moduledoc); populating a
    # real auth_context/tenant_id here would require a genuine tenant lookup
    # and break that constraint -- see test/letflow/routers/identity_test.exs
    # for the DB-backed tests that dispatch to this same router WITH a real
    # auth_context and exercise its actual routes/authorization end to end.
    test "Letflow.Routers.Identity compiles and handles requests independently of the top-level router" do
      conn =
        conn(:get, "/some-path")
        |> Letflow.Routers.Identity.call(@identity_opts)

      assert conn.status == 500
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/problem+json"
    end
  end

  describe "REQ-070 AC3: unrouted path returns RFC 9457 404 via top-level router" do
    test "Content-Type is application/problem+json" do
      conn = conn(:get, "/nonexistent-path-xyz") |> call()
      assert conn.status == 404
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/problem+json"
    end

    test "body contains all four RFC 9457 required members" do
      conn = conn(:get, "/nonexistent-path-xyz") |> call()
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "type")
      assert Map.has_key?(body, "title")
      assert Map.has_key?(body, "status")
      assert Map.has_key?(body, "detail")
    end
  end

  describe "REQ-070 AC4: single middleware declaration site" do
    test "Plug.Parsers invoked in exactly one lib/ file" do
      files = Path.wildcard("lib/**/*.ex")
      # Search for the plug invocation — not references in module docs/comments.
      matches =
        Enum.filter(files, fn f -> String.contains?(File.read!(f), "plug(Plug.Parsers,") end)

      assert length(matches) == 1
      assert hd(matches) =~ "api_pipeline"
    end

    test "AuthPipeline plug registered in exactly one lib/ file" do
      files = Path.wildcard("lib/**/*.ex")

      matches =
        Enum.filter(files, fn f ->
          String.contains?(File.read!(f), "plug(Letflow.Plugs.AuthPipeline)")
        end)

      assert length(matches) == 1
      assert hd(matches) =~ "api_pipeline"
    end
  end

  # REQ-070 AC5 originally pinned 11 deferred module names. The number is 9 as of
  # REQ-310 (commit f6e0ae64), and the drop is not arbitrary: REQ-310 built the entity
  # HTTP surface and deleted BOTH the `Letflow.Routers.Entities` and the
  # `Letflow.Routers.EntityQuery` rows from router.ex's deferred table, per
  # lib/letflow/design/req308-entity-http-surface.md §8, which specifies clean removal
  # rather than annotation ("a table documenting 'not yet mounted' routes has nothing
  # left to say once the corresponding module exists and is forwarded"). Two rows went,
  # but only ONE module was built: design §2 ruled the two names an R-Co-filename
  # artefact rather than two URL prefixes, and merged both into the single
  # `Letflow.Routers.Entities`, mounted by `forward("/entities", ...)` in
  # lib/letflow/plugs/api_pipeline.ex. `Letflow.Routers.EntityQuery` was therefore
  # retired without ever existing — its query surface lands as POST /entities/query on
  # the merged module (REQ-311), not as a module of its own.
  #
  # The number dropped again, from 9 to 5, by commit 65312cd9 (ISS-0822's dead-route
  # removal): `Letflow.Routers.Dlq`, `.Services`, `.PlatformMigrations`, and `.Webhooks`
  # were removed from router.ex's deferred table because they are now mounted in
  # api_pipeline.ex (S6 complete) -- see router.ex's own moduledoc note under
  # "## Deferred routes" for the same history. This test file was not updated in that
  # commit (ISS-0827/ISS-0830), which is what this pass fixes: the hardcoded list and
  # row count below are brought back in sync with the current, 5-row table.
  #
  # AC5's property is unchanged: the table names exactly the routes that are genuinely
  # still unmounted. The expected list below stays an explicit literal (never derived
  # from router.ex itself, which would make it a tautology that always passes), and the
  # retirement assertion below it is what keeps the count honest in the other direction.
  describe "REQ-070 AC5: router.ex names all 5 deferred routes and states readiness not-ported" do
    # The five module names router.ex's deferred table carries, spelled out literally.
    @deferred [
      "Letflow.Routers.SimulationTest",
      "Letflow.Routers.ProcessModules",
      "Letflow.Routers.AgentRequests",
      "Letflow.Routers.AgentResponses",
      "Letflow.Routers.AgentEvents"
    ]

    # The two names REQ-310 retired. Named specifically rather than as a catch-all, so
    # this asserts the retirement actually happened and catches an accidental
    # re-addition of either row by a future edit.
    @retired ["Letflow.Routers.Entities", "Letflow.Routers.EntityQuery"]

    test "all 5 deferred sub-router module names are listed" do
      source = File.read!("lib/letflow/router.ex")

      for name <- @deferred do
        assert String.contains?(source, name), "router.ex missing deferred route: #{name}"
      end
    end

    test "the deferred table holds exactly 5 rows, no more" do
      # Guards the other direction from the membership test above: that one would still
      # pass if a tenth row were added. Counts rows in the deferred table only — the
      # region between its header and the end of the moduledoc — so the mounted
      # forwards in the route table above it are not miscounted as deferred.
      source = File.read!("lib/letflow/router.ex")

      [_, deferred_section] = String.split(source, "## Deferred routes", parts: 2)
      [table, _] = String.split(deferred_section, ~s("""), parts: 2)

      rows =
        table
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "| `Letflow.Routers."))

      assert length(rows) == length(@deferred),
             "expected #{length(@deferred)} deferred rows, found #{length(rows)}:\n" <>
               Enum.join(rows, "\n")
    end

    test "REQ-310's two retired rows are gone from the deferred table" do
      # Letflow.Routers.Entities is now BUILT and MOUNTED (api_pipeline.ex forwards
      # /entities to it), and Letflow.Routers.EntityQuery was merged into it and never
      # built. Neither belongs in a table of not-yet-mounted routes. Asserted against
      # the deferred table specifically, not the whole file: router.ex is free to
      # mention either name elsewhere in prose later, and that would not be a defect.
      source = File.read!("lib/letflow/router.ex")

      [_, deferred_section] = String.split(source, "## Deferred routes", parts: 2)
      [table, _] = String.split(deferred_section, ~s("""), parts: 2)

      for name <- @retired do
        refute String.contains?(table, name),
               "#{name} was retired from router.ex's deferred table by REQ-310, but is " <>
                 "listed there again — it is mounted/merged, not deferred"
      end
    end

    test "Letflow.Routers.Entities is genuinely mounted, which is why it left the table" do
      # The justification for the row's removal, asserted rather than assumed: the
      # module exists and Letflow.Plugs.ApiPipeline forwards to it. If a future change
      # unmounted it, the row would have to come back, and this test is what says so.
      assert Code.ensure_loaded?(Letflow.Routers.Entities)

      pipeline_source = File.read!("lib/letflow/plugs/api_pipeline.ex")

      assert String.contains?(
               pipeline_source,
               ~s|forward("/entities", to: Letflow.Routers.Entities)|
             )
    end

    test "readiness endpoint is documented as not ported" do
      source = File.read!("lib/letflow/router.ex")
      assert String.contains?(source, "not ported")
    end
  end

  describe "REQ-070 AC6: router.ex references decision record and amendment date" do
    test "router.ex references 0001-web-framework.md" do
      source = File.read!("lib/letflow/router.ex")
      assert String.contains?(source, "0001-web-framework.md")
    end

    test "router.ex references the 2026-08-20 amendment date" do
      source = File.read!("lib/letflow/router.ex")
      assert String.contains?(source, "2026-08-20")
    end
  end

  # ── REQ-071 tests ─────────────────────────────────────────────────────────
  #
  # Named (not anonymous) telemetry handler function, matching
  # test/letflow/plugs/tenant_status_test.exs's own ISS-0031 (GH#90) precedent —
  # [:letflow, :repo, :query] is a single node-global event name, so the handler
  # must filter to only this test's own process (self() == test_pid) rather than
  # trusting an unfiltered send/2, or a concurrently running async test's real
  # query would flake the `refute_received` assertion below.
  def handle_query_telemetry(_event, _measurements, _metadata, test_pid) do
    if self() == test_pid do
      send(test_pid, :query_fired)
    end
  end

  describe "REQ-071 AC1: no Authorization header returns 401, zero Repo queries" do
    test "POST /api/v1/identity/anything with no Authorization header returns 401" do
      test_pid = self()
      handler_id = {:router_test, :req071_ac1_telemetry, make_ref()}

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        &__MODULE__.handle_query_telemetry/4,
        test_pid
      )

      conn =
        try do
          conn(:post, "/api/v1/identity/anything", Jason.encode!(%{}))
          |> put_req_header("content-type", "application/json")
          |> call()
        after
          :telemetry.detach(handler_id)
        end

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "unauthorized"

      refute_received :query_fired,
                      "expected zero Repo queries for a request rejected at AuthPipeline"
    end
  end

  describe "REQ-071 AC3: /health survives the OIDC provider worker being down" do
    # REQ-370 (design req370-multi-issuer-oidc-verification.md §4) replaced the
    # single, always-running, config-registered Letflow.Oidc.DefaultProvider static
    # worker with Letflow.Oidc.ProviderRegistry -- a DynamicSupervisor that starts
    # per-realm workers lazily. Letflow.Oidc.DefaultProvider no longer exists at all
    # (Process.whereis/1 for it now always returns nil), so this test's equivalent
    # "the OIDC provider layer being down" target is ProviderRegistry itself -- the
    # one process REQ-071 AC3's own point (an unrelated dependency being dead must
    # not take /health down with it) still has a real, always-running analog for.
    test "GET /health returns 200 while Letflow.Oidc.ProviderRegistry is dead" do
      pid = Process.whereis(Letflow.Oidc.ProviderRegistry)
      assert is_pid(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      refute Process.alive?(pid)

      conn = conn(:get, "/health") |> call()

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "status" => "ok",
               "sha" => Letflow.BuildInfo.sha()
             }

      # Letflow.Supervisor.Infrastructure's :one_for_one strategy restarts the killed
      # ProviderRegistry automatically — a new DynamicSupervisor process gets
      # registered under the same Letflow.Oidc.ProviderRegistry name (start_link/1
      # hardcodes name: __MODULE__, not config-dependent), so a later test resolving
      # this name again does not observe a permanently-dead provider. Any per-realm
      # worker ProviderRegistry had started dies with it and is simply re-started
      # lazily again on the next verification attempt against that realm
      # (ensure_started/1's own idempotent behavior, design §4.1) — confirmed by
      # reading provider_registry.ex/infrastructure.ex directly rather than asserted
      # here (asserting on the exact restart timing would itself be flaky).
    end
  end
end
