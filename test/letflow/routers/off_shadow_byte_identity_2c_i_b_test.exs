defmodule Letflow.Routers.OffShadowByteIdentity2cIBTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-b, T-S4 (design `lib/letflow/design/req518-compiler-scope-filter.md`
  10.1, 4.x; spec `test/specs/REQ-518-2c-i-b.md`): the `off` and `shadow` responses of the six
  routes this slice reclassifies are byte-identical to the behavior of `main` BEFORE the slice.

  The committed fixture `test/fixtures/route_scope/off_shadow_responses_2c_i_b.json` (the style of
  the 517 fixture `off_shadow_responses.json`; its `_provenance` says how the rows were derived and
  why that equals a replay against main) holds fourteen requests: `GET /me/memberships` (M1),
  `GET /me/modules` (M2), `GET /help/resolved` (H1: missing screen id, unknown screen), and the
  three `:filter` routes (E8 query, E9 aggregate, E10 export: type-hidden 200 envelope, 404,
  422) for a scoped-only caller and a tenant-wide caller.

  The replay runs every request under `off` and under `shadow` and asserts:

    * both equal the fixture (status, content type, decoded body, with the tenant placeholders
      filled in);
    * `off` and `shadow` are byte-identical to EACH OTHER (raw body and every response header);
    * under `on` the same requests ALSO answer the recorded response: these shapes are decided
      before any scoped data is read, so the new gate and the before-send backstop change nothing
      (a regression that turned the 200 envelope or a 4xx into a 500 shows here);
    * not `on`: the node set is never read.

  `async: false`: committed writes.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @fixture_path "test/fixtures/route_scope/off_shadow_responses_2c_i_b.json"
  @routers %{
    "Me" => Letflow.Routers.Me,
    "Help" => Letflow.Routers.Help,
    "Entities" => Letflow.Routers.Entities
  }

  defp fixture, do: @fixture_path |> File.read!() |> Jason.decode!()

  defp callers(fx) do
    %{
      "scoped_worker" => {On.scoped_holder!(fx, "TASK_WORKER").id, ["TASK_WORKER"]},
      "scoped_admin" => {On.scoped_holder!(fx, "TENANT_ADMIN").id, ["TENANT_ADMIN"]},
      "tenant_wide_admin" => {fx.admin.id, ["TENANT_ADMIN"]}
    }
  end

  defp replay(request, fx, callers, mode) do
    {user_id, roles} = Map.fetch!(callers, request["caller"])
    router = Map.fetch!(@routers, request["router"])
    method = request["method"] |> String.downcase() |> String.to_existing_atom()

    On.call(router, method, request["path"], fx, user_id, roles, mode, request["request_body"])
  end

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> List.first()

  defp observed(conn), do: {conn.status, content_type(conn), Jason.decode!(conn.resp_body)}

  defp expected(request, fx) do
    response = request["response"]
    {response["status"], response["content_type"], fill(response["body"], fx)}
  end

  defp fill(%{} = map, fx), do: Map.new(map, fn {k, v} -> {k, fill(v, fx)} end)
  defp fill(list, fx) when is_list(list), do: Enum.map(list, &fill(&1, fx))
  defp fill("${tenant_id}", fx), do: fx.tenant.id
  defp fill("${tenant_slug}", fx), do: fx.tenant.slug
  defp fill("${tenant_display_name}", fx), do: fx.tenant.display_name
  defp fill(other, _fx), do: other

  # ===========================================================================================
  test "the fixture is well formed: fourteen distinct requests covering the six routes, each with a status, content type and body" do
    doc = fixture()
    requests = doc["requests"]

    assert length(requests) == 14
    assert requests |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 14
    assert doc["trace_id"] == S.trace()
    assert doc["_provenance"] =~ "NOT captured" or doc["_provenance"] =~ "not captured"

    for request <- requests do
      assert request["router"] in Map.keys(@routers), inspect(request)
      assert request["method"] in ~w(GET POST), inspect(request)
      assert String.starts_with?(request["path"], "/")
      assert request["caller"] in ~w(scoped_worker scoped_admin tenant_wide_admin)
      response = request["response"]
      assert is_integer(response["status"])
      assert is_binary(response["content_type"])
      assert is_map(response["body"])
    end

    covered =
      requests
      |> Enum.map(&{&1["router"], &1["method"], &1["path"] |> String.split("?") |> hd()})
      |> Enum.uniq()
      |> Enum.sort()

    assert covered == [
             {"Entities", "POST", "/query"},
             {"Entities", "POST", "/query/aggregate"},
             {"Entities", "POST", "/records/no_such_type_518/export"},
             {"Help", "GET", "/resolved"},
             {"Me", "GET", "/memberships"},
             {"Me", "GET", "/modules"}
           ]

    assert requests |> Enum.map(& &1["response"]["status"]) |> Enum.uniq() |> Enum.sort() ==
             [200, 400, 404, 422]

    assert Enum.any?(requests, &(&1["caller"] == "scoped_worker"))
    assert Enum.any?(requests, &(&1["caller"] == "tenant_wide_admin"))
  end

  test "T-S4 every fixture request answers the recorded response under off AND shadow, and off and shadow are byte-identical" do
    fx = S.tenant!("r518-s4")
    callers = callers(fx)
    requests = fixture()["requests"]

    off = Map.new(requests, &{&1["id"], replay(&1, fx, callers, :off)})
    shadow = Map.new(requests, &{&1["id"], replay(&1, fx, callers, :shadow)})

    for request <- requests do
      id = request["id"]

      assert observed(off[id]) == expected(request, fx),
             "#{id} under off differs from the fixture: " <>
               inspect({observed(off[id]), expected(request, fx)})

      assert observed(shadow[id]) == expected(request, fx),
             "#{id} under shadow differs from the fixture"

      assert shadow[id].resp_body == off[id].resp_body, "#{id}: raw bodies differ"
      assert shadow[id].resp_headers == off[id].resp_headers, "#{id}: headers differ"
      assert shadow[id].status == off[id].status
    end
  end

  test "under on the same requests answer the same recorded response: the gate and the backstop change nothing for these shapes" do
    fx = S.tenant!("r518-s4-on")
    callers = callers(fx)

    for request <- fixture()["requests"] do
      conn = replay(request, fx, callers, :on)

      assert observed(conn) == expected(request, fx),
             "#{request["id"]} under on: " <> inspect({observed(conn), expected(request, fx)})
    end
  end

  test "not on: replaying every row reads no scope_node_paths statement (the gate is neutral)" do
    fx = S.tenant!("r518-s4-q")
    callers = callers(fx)
    requests = fixture()["requests"]

    for mode <- [:off, :shadow] do
      {_conns, queries} =
        Fixture.capture_repo_queries(fn ->
          Enum.map(requests, &replay(&1, fx, callers, mode))
        end)

      refute Enum.any?(queries, &(&1.query =~ "scope_node_paths")), "#{mode}"
    end
  end
end
