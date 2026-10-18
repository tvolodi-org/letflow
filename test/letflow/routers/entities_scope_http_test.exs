defmodule Letflow.Routers.EntitiesScopeHttpTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-b, T-C13 over real HTTP and the end-to-end half of T-C11 (design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.3, 3.5, 10.1; spec
  `test/specs/REQ-518-2c-i-b.md`; SEC code-gate step-12 condition): the three `:filter` routes
  through the FULL `Letflow.Router` (real `AuthPipeline` with an OIDC credential, the stored
  tenant mode read per request, `Authorize`, `Enforce`, the router, `ApiPipeline.handle_errors/2`),
  with a user whose `TENANT_ADMIN` role is held ONLY at the subtree `a` of the `fixture_scoped`
  tenant.

    * `on`: each route answers 200 with exactly the in-scope data; `off` / `shadow`: the full
      data, with the node set never read (the table is renamed away and the request still works);
    * T-C13: when the node read fails (the tenant's `scope_node_paths` table is renamed away, a
      committed DDL fault, restored in an `after`), each route answers the detail-free 500 that is
      the same body as every other fail-closed path, logs exactly ONE `scope_set_failed` line
      naming no id or schema, never a 200 with data or with an empty page, and the exception that
      propagates is `ScopeSetError`; after the repair the same request answers 200 again.

  `async: false`: dedicated provisioned OIDC tenant (sandbox `:auto`), DDL, the VM-global `:oidc`
  config swap.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.Response
  alias Letflow.Api.Scope.ScopeSetError
  alias Letflow.Identity.ApiToken
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.TokenMintFixture

  @role "TENANT_ADMIN"
  @in_a [:a, :a1, :a2x]
  @all_keys [:root, :a, :a1, :a2, :a2x, :a3, :b, :b1, :none]

  @routes [
    {:query, "/api/v1/entities/query", %{"entity_type" => "scoped_item"}, "items"},
    {:aggregate, "/api/v1/entities/query/aggregate",
     %{"entity_type" => "scoped_item", "aggregates" => [%{"fn" => "count"}]}, "results"},
    {:export, "/api/v1/entities/records/scoped_item/export", %{"entity_type" => "scoped_item"},
     "records"}
  ]

  setup do
    original = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)

    realm = Letflow.TenantSlugFixture.unique_realm("r518-http")
    fx = F.provision!("r518-http", oidc_mode: :enabled, idp_realm_id: realm)
    fx = Map.put(fx, :realm, realm)
    schema = fx.schema_name
    _items = F.seed_items!(fx)

    # the first request JIT-provisions the OIDC user; then the role is held ONLY at node a
    first = request(fx, :get, "/api/v1/instances", nil)
    assert first.status in [200, 403]
    user_id = first.assigns.auth_context.user_id
    TokenMintFixture.grant_roles!(schema, user_id, [@role])
    group = RSG.group_of!(schema, @role)
    _removed = RSG.raw_delete_rows!(schema, group, @role)
    :ok = RSG.raw_user_row!(schema, user_id, @role, F.nodes().a)

    {:ok, fx: fx}
  end

  defp build(fx, method, path, body) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    put_req_header(conn, "authorization", "Bearer realm-token:" <> fx.realm)
  end

  defp request(fx, method, path, body),
    do: fx |> build(method, path, body) |> Letflow.Router.call(Letflow.Router.init([]))

  defp store!(fx, mode), do: ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, mode)

  defp names(items), do: items |> Enum.map(&get_in(&1, ["field_values", "name"])) |> Enum.sort()
  defp item_names(keys), do: keys |> Enum.map(&"item-#{&1}") |> Enum.sort()

  defp with_renamed_node_paths(fx, fun) do
    schema = fx.schema_name
    Repo.query!(~s|ALTER TABLE "#{schema}".scope_node_paths RENAME TO scope_node_paths_fault|)

    try do
      fun.()
    after
      Repo.query!(~s|ALTER TABLE "#{schema}".scope_node_paths_fault RENAME TO scope_node_paths|)
    end
  end

  # Dispatches the request and returns `{sent, raised, log}`: the response the adapter was
  # handed (read from the test adapter's mailbox message, which survives a re-raise), the
  # exception that propagated out of the pipeline (nil when none), and the captured log.
  defp dispatch_capturing(fx, path, body) do
    conn = build(fx, :post, path, body)
    {Plug.Adapters.Test.Conn, %{ref: ref}} = conn.adapter

    {result, log} =
      with_log(fn ->
        try do
          {:returned, Letflow.Router.call(conn, Letflow.Router.init([]))}
        rescue
          e -> {:raised, e}
        end
      end)

    case result do
      {:returned, returned} ->
        {{returned.status, returned.resp_body}, nil, log}

      {:raised, e} ->
        assert_received {^ref, {status, _headers, resp_body}}
        {{status, resp_body}, unwrap(e), log}
    end
  end

  defp unwrap(%Plug.Conn.WrapperError{reason: reason}), do: reason
  defp unwrap(other), do: other

  # only the scope_set_failed line(s): the debug-level Ecto QUERY lines of the same log name
  # schemas and ids legitimately
  defp failed_lines(log),
    do: log |> String.split("
") |> Enum.filter(&(&1 =~ "scope_set_failed")) |> Enum.join("
")

  defp count(log, needle), do: length(String.split(log, needle)) - 1

  # ===========================================================================================
  describe "T-C11 end to end through the full router" do
    test "under on each route answers only the in-scope data to the scoped OIDC user", %{fx: fx} do
      store!(fx, :on)

      for {route, path, body, key} <- @routes do
        conn = request(fx, :post, path, body)
        assert conn.status == 200, "#{route}: #{conn.resp_body}"
        decoded = Jason.decode!(conn.resp_body)

        case route do
          :aggregate ->
            assert [%{"values" => %{"count_none" => 3}}] = decoded[key]

          _rows ->
            assert names(decoded[key]) == item_names(@in_a), "#{route}"
        end
      end
    end

    test "under off and shadow the same user gets the full data, even while the node table is unreadable (the set is never read)",
         %{fx: fx} do
      for mode <- [:off, :shadow] do
        store!(fx, mode)

        with_renamed_node_paths(fx, fn ->
          for {route, path, body, key} <- @routes do
            {{status, resp_body}, raised, log} = dispatch_capturing(fx, path, body)

            assert status == 200, "#{route} under #{mode}: #{resp_body}"
            assert raised == nil
            assert count(log, "scope_set_failed") == 0

            decoded = Jason.decode!(resp_body)

            case route do
              :aggregate ->
                assert [%{"values" => %{"count_none" => 9}}] = decoded[key]

              _rows ->
                assert names(decoded[key]) == item_names(@all_keys), "#{route} under #{mode}"
            end
          end
        end)
      end
    end
  end

  describe "AC 5 statement counts over the full pipeline" do
    test "an OIDC request reads the grants exactly once whatever the mode, and reads the node set only under on",
         %{fx: fx} do
      path = "/api/v1/entities/query"
      body = %{"entity_type" => "scoped_item"}

      counts =
        for mode <- [:off, :shadow, :on, :off, :on], into: [] do
          store!(fx, mode)
          {conn, queries} = Fixture.capture_repo_queries(fn -> request(fx, :post, path, body) end)
          assert conn.status == 200, "#{mode}"

          {mode, Enum.count(queries, &(&1.query =~ "role_scope_grants")),
           Enum.count(queries, &(&1.query =~ "scope_node_paths"))}
        end

      for {mode, grants, nodes} <- counts do
        assert grants >= 1, "#{mode}: the pipeline loads the grants"

        assert grants == elem(hd(counts), 1),
               "#{mode}: the grants are read once per request, not again by the gate"

        if mode == :on, do: assert(nodes >= 1), else: assert(nodes == 0, "#{mode}")
      end

      on_nodes = for {:on, _g, n} <- counts, do: n
      assert on_nodes |> Enum.uniq() |> length() == 1
    end

    test "the API-token shape is unchanged by the gate: the same statements under on as under off, and no scope statement",
         %{fx: fx} do
      admin = Fixture.mint_token!(fx, ["TENANT_ADMIN"])

      token_request = fn ->
        :post
        |> conn("/api/v1/entities/query", Jason.encode!(%{"entity_type" => "scoped_item"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> admin)
        |> put_req_header("x-tenant-slug", fx.tenant.slug)
        |> Letflow.Router.call(Letflow.Router.init([]))
      end

      # `last_used_at` is written only when the truncated-to-the-second clock differs from the
      # stored value (GH #2729, a second-boundary flake): reset it before EVERY measured request
      # so each one performs exactly one such write, whatever second it lands in.
      reset_last_used = fn ->
        Repo.update_all(ApiToken, [set: [last_used_at: nil]], prefix: fx.schema_name)
      end

      store!(fx, :off)
      assert token_request.().status == 200

      measured =
        for mode <- [:off, :on, :off, :on] do
          store!(fx, mode)
          reset_last_used.()
          {conn, queries} = Fixture.capture_repo_queries(token_request)
          assert conn.status == 200, "#{mode}"
          refute Enum.any?(queries, &(&1.query =~ "scope_node_paths")), "#{mode}"
          refute Enum.any?(queries, &(&1.query =~ "role_scope_grants")), "#{mode}"
          {mode, length(queries)}
        end

      assert measured |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1, inspect(measured)
    end
  end

  # ===========================================================================================
  describe "T-C13 a failing node read is the detail-free 500 over real HTTP" do
    test "each route answers 500 with the shared detail-free body, exactly one scope_set_failed line, ScopeSetError propagating, and no data of any kind",
         %{fx: fx} do
      store!(fx, :on)
      expected = Response.internal_error(Plug.Test.conn(:get, "/"))
      expected_body = expected.resp_body |> Jason.decode!() |> Map.delete("trace_id")

      with_renamed_node_paths(fx, fn ->
        for {route, path, body, key} <- @routes do
          {{status, resp_body}, raised, log} = dispatch_capturing(fx, path, body)

          assert status == 500, "#{route}"
          assert %ScopeSetError{} = raised, "#{route}: #{inspect(raised)}"

          decoded = Jason.decode!(resp_body)
          assert Map.delete(decoded, "trace_id") == expected_body, "#{route}"
          refute Map.has_key?(decoded, key), "#{route}: a page of any kind"
          refute resp_body =~ fx.schema_name, "#{route}"
          refute resp_body =~ "scope_node_paths", "#{route}"
          refute resp_body =~ "item-", "#{route}"

          assert count(log, "scope_set_failed") == 1, "#{route}: #{log}"
          failed_lines = failed_lines(log)
          refute failed_lines =~ "sf-a", "#{route}: a node id in the line"
          refute failed_lines =~ "scoped_item", "#{route}"
          refute failed_lines =~ fx.schema_name, "#{route}"
        end
      end)
    end

    test "after the repair the same requests answer 200 again (no failure state is kept)", %{
      fx: fx
    } do
      store!(fx, :on)

      capture_log(fn ->
        with_renamed_node_paths(fx, fn ->
          {{status, _body}, _raised, _log} =
            dispatch_capturing(fx, "/api/v1/entities/query", %{"entity_type" => "scoped_item"})

          assert status == 500
        end)
      end)

      conn = request(fx, :post, "/api/v1/entities/query", %{"entity_type" => "scoped_item"})
      assert conn.status == 200

      assert conn.resp_body |> Jason.decode!() |> Map.fetch!("items") |> names() ==
               item_names(@in_a)
    end

    test "the fault is only a fault of the scoped read: a request the tenant-wide shape would answer needs no node read (a token caller is unaffected)",
         %{fx: fx} do
      store!(fx, :on)
      admin = Fixture.mint_token!(fx, ["TENANT_ADMIN"])

      with_renamed_node_paths(fx, fn ->
        conn =
          :post
          |> conn("/api/v1/entities/query", Jason.encode!(%{"entity_type" => "scoped_item"}))
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> admin)
          |> put_req_header("x-tenant-slug", fx.tenant.slug)
          |> Letflow.Router.call(Letflow.Router.init([]))

        assert conn.status == 200
      end)
    end
  end
end
