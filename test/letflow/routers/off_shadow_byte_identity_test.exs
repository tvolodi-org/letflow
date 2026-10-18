defmodule Letflow.Routers.OffShadowByteIdentityTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 19, T-G1 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 6.2; spec
  `test/specs/REQ-517-2b.md`): `off` and `shadow` HTTP responses (status, headers, body) are
  byte-identical to the behavior of `main` BEFORE 2b. The committed fixture
  `test/fixtures/route_scope/off_shadow_responses.json` holds eleven requests (a tenant-wide and a
  scoped-only administrator, the admin plane, default routes, the `AllowWithRowFilter` task list,
  the attachment-link routes, an unmatched route, a coarse deny) with the status, content type and
  body `main` answered. The fixture's own `_provenance` says how it was derived (read from main's
  code, not captured from a running main; the machine could not run it).

  The replay runs every request under `off` and under `shadow` and asserts:

    * both equal the fixture (status, content type, decoded body);
    * `off` and `shadow` are byte-identical to EACH OTHER (raw body and every response header);
    * the shadow observer genuinely ran (it emitted would-deny events for the scoped-only caller
      under `shadow` and none under `off`), so the identity is not vacuous;
    * as a negative control, `on` DOES change the scoped-only caller's responses on the tenant-wide
      routes (403), so the replay is able to see an enforcement difference.

  `async: false`: committed writes and VM-global telemetry handlers.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @fixture_path "test/fixtures/route_scope/off_shadow_responses.json"
  @routers %{
    "Instances" => Letflow.Routers.Instances,
    "Tasks" => Letflow.Routers.Tasks,
    "Identity" => Letflow.Routers.Identity
  }
  @would_deny [:letflow, :scope, :shadow, :would_deny]
  # the fixture requests that a scoped-only administrator sees as 403 under `on`
  @changed_under_on ~w(R02 R04 R08)

  @doc false
  def handle_event(_event, _measurements, metadata, {pid, ref}) do
    send(pid, {:would_deny, ref, metadata})
    :ok
  end

  defp fixture, do: @fixture_path |> File.read!() |> Jason.decode!()

  defp callers(fx) do
    worker = TokenMintFixture.role_holder!(fx.schema_name, ["TASK_WORKER"])

    %{
      "tenant_wide_admin" => {fx.admin.id, ["TENANT_ADMIN"]},
      "scoped_admin" => {On.scoped_holder!(fx, "TENANT_ADMIN").id, ["TENANT_ADMIN"]},
      "no_role" => {Ecto.UUID.generate(), []},
      "tenant_wide_worker" => {worker.id, ["TASK_WORKER"]},
      "task_worker_claim" => {Ecto.UUID.generate(), ["TASK_WORKER"]}
    }
  end

  defp replay(request, fx, callers, mode) do
    {user_id, roles} = Map.fetch!(callers, request["caller"])
    router = Map.fetch!(@routers, request["router"])
    method = request["method"] |> String.downcase() |> String.to_existing_atom()

    {conn, _log} =
      with_log(fn ->
        On.call(router, method, request["path"], fx, user_id, roles, mode, nil)
      end)

    conn
  end

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> List.first()

  defp observed(conn), do: {conn.status, content_type(conn), Jason.decode!(conn.resp_body)}

  defp expected(request) do
    response = request["response"]
    {response["status"], response["content_type"], response["body"]}
  end

  defp attach_would_deny! do
    ref = make_ref()
    :telemetry.attach({__MODULE__, ref}, @would_deny, &__MODULE__.handle_event/4, {self(), ref})
    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp drain(ref, acc) do
    receive do
      {:would_deny, ^ref, metadata} -> drain(ref, [metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ===========================================================================================
  test "the fixture is well formed: eleven distinct requests, each with a status, content type and body" do
    doc = fixture()
    requests = doc["requests"]

    assert length(requests) == 11
    assert requests |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 11
    assert doc["trace_id"] == S.trace()
    assert is_binary(doc["_provenance"]) and doc["_provenance"] =~ "NOT captured"

    for request <- requests do
      assert request["router"] in Map.keys(@routers), inspect(request)
      assert request["method"] in ~w(GET POST), inspect(request)
      assert String.starts_with?(request["path"], "/")
      response = request["response"]
      assert is_integer(response["status"])
      assert is_binary(response["content_type"])
      assert is_map(response["body"])
    end

    # it covers the shapes the design lists
    statuses = requests |> Enum.map(& &1["response"]["status"]) |> Enum.uniq() |> Enum.sort()
    assert statuses == [200, 400, 403, 404, 422]
    assert Enum.any?(requests, &(&1["router"] == "Tasks"))
    assert Enum.any?(requests, &(&1["caller"] == "scoped_admin"))
  end

  test "T-G1 every fixture request answers the recorded response under off AND shadow, off and shadow are byte-identical, and the shadow observer really ran" do
    fx = S.tenant!("r517-g1")
    callers = callers(fx)
    requests = fixture()["requests"]
    ref = attach_would_deny!()

    off = Map.new(requests, &{&1["id"], replay(&1, fx, callers, :off)})
    assert drain(ref, []) == [], "the shadow observer ran under off"

    shadow = Map.new(requests, &{&1["id"], replay(&1, fx, callers, :shadow)})
    shadow_events = drain(ref, [])

    for request <- requests do
      id = request["id"]

      assert observed(off[id]) == expected(request),
             "#{id} under off differs from the fixture: " <>
               inspect({observed(off[id]), expected(request)})

      assert observed(shadow[id]) == expected(request),
             "#{id} under shadow differs from the fixture"

      # byte-identical to each other: raw body and every header
      assert shadow[id].resp_body == off[id].resp_body, "#{id}: raw bodies differ"
      assert shadow[id].resp_headers == off[id].resp_headers, "#{id}: headers differ"
      assert shadow[id].status == off[id].status
    end

    # the observer saw the scoped-only administrator on tenant-wide routes (non-vacuous identity)
    assert shadow_events != []
    assert Enum.all?(shadow_events, &(&1.reason == :not_tenant_wide))
    assert :InstancesRead in Enum.map(shadow_events, & &1.policy)
  end

  test "negative control: under on the scoped-only administrator's tenant-wide requests change to 403, every other request is unchanged" do
    fx = S.tenant!("r517-g1-on")
    callers = callers(fx)
    requests = fixture()["requests"]

    for request <- requests do
      id = request["id"]
      conn = replay(request, fx, callers, :on)

      if id in @changed_under_on do
        assert conn.status == 403, "#{id} should be refused under on"
        refute observed(conn) == expected(request)
        assert Jason.decode!(conn.resp_body)["detail"] == "insufficient permissions"
      else
        assert observed(conn) == expected(request), "#{id} must not change under on"
      end
    end
  end
end
