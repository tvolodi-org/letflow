defmodule Letflow.Routers.AdminServicesReservedEndpointTest do
  @moduledoc """
  GH #2623: `POST /` (register) and `POST /:service_id/versions` (publish) answer 422
  `{"error": "endpoint_url_reserved_variable", "field": "endpoint_url"}` for a reserved
  `_sys` reference in `endpoint_url`, echoing neither the URL nor the name. `async: false`:
  `service_catalog` is a global table.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version
  alias Letflow.Support.PlatformTenantFixture

  @opts Letflow.Routers.AdminServices.init([])
  @reserved_url "https://example.test/{{variables._sys.secretname}}"

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  defp dispatch(method, path, body) do
    conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(
      :auth_context,
      PlatformTenantFixture.operator_auth_context(
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        ["PLATFORM_ADMIN"]
      )
    )
    |> assign(:trace_id, "fixed-test-trace-id")
    |> Letflow.Routers.AdminServices.call(@opts)
  end

  defp unique_service_id,
    do: "gh2623-router-svc-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register_body(service_id, url) do
    %{
      "service_id" => service_id,
      "endpoint_url" => url,
      "scope" => "global",
      "auth_method" => "NONE",
      "timeout_ms" => 5000
    }
  end

  defp assert_reserved_422(resp) do
    assert resp.status == 422
    body = Jason.decode!(resp.resp_body)
    assert body["error"] == "endpoint_url_reserved_variable"
    assert body["field"] == "endpoint_url"
    refute resp.resp_body =~ "secretname"
    refute resp.resp_body =~ "example.test"
    refute resp.resp_body =~ "_sys"
  end

  test "POST / with a reserved endpoint_url -> 422 with the code, no echo, nothing inserted" do
    sid = unique_service_id()
    on_exit(fn -> cleanup_entry!(sid) end)

    assert_reserved_422(dispatch(:post, "/", register_body(sid, @reserved_url)))
    assert Repo.get(Entry, sid) == nil
  end

  test "POST / with a clean URL -> 201; a scheme failure keeps the generic 422" do
    ok_id = unique_service_id()
    bad_id = unique_service_id()
    on_exit(fn -> cleanup_entry!(ok_id) end)
    on_exit(fn -> cleanup_entry!(bad_id) end)

    assert dispatch(:post, "/", register_body(ok_id, "https://example.test/svc")).status ==
             201

    resp = dispatch(:post, "/", register_body(bad_id, "http://example.test/svc"))
    assert resp.status == 422
    refute Jason.decode!(resp.resp_body)["error"] == "endpoint_url_reserved_variable"
  end

  test "POST /:service_id/versions with a reserved endpoint_url -> 422 with the code" do
    sid = unique_service_id()
    on_exit(fn -> cleanup_entry!(sid) end)

    assert {:ok, _} =
             ServiceCatalog.register(%{
               service_id: sid,
               endpoint_url: "https://example.test/svc",
               required_auth: :NONE,
               timeout_ms: 5_000,
               scope: :global
             })

    resp =
      dispatch(:post, "/#{sid}/versions", %{
        "version" => "2",
        "endpoint_url" => @reserved_url,
        "timeout_ms" => 6000
      })

    assert_reserved_422(resp)
    assert Repo.get!(Entry, sid).version == "1"
  end

  test "POST /:service_id/versions with a scheme failure keeps the generic 422" do
    sid = unique_service_id()
    on_exit(fn -> cleanup_entry!(sid) end)
    {:ok, _} = ServiceCatalog.register(good_attrs(sid))

    resp =
      dispatch(:post, "/#{sid}/versions", %{
        "version" => "2",
        "endpoint_url" => "http://example.test/svc",
        "timeout_ms" => 6000
      })

    assert resp.status == 422
    refute Jason.decode!(resp.resp_body)["error"] == "endpoint_url_reserved_variable"
  end

  test "POST /:service_id/versions inheriting a reserved live URL -> reserved 422" do
    sid = unique_service_id()
    on_exit(fn -> cleanup_entry!(sid) end)
    {:ok, _} = ServiceCatalog.register(good_attrs(sid))

    {1, _} =
      Repo.update_all(from(e in Entry, where: e.service_id == ^sid),
        set: [endpoint_url: @reserved_url]
      )

    resp = dispatch(:post, "/#{sid}/versions", %{"version" => "2", "timeout_ms" => 6000})

    assert_reserved_422(resp)
    assert Repo.get!(Entry, sid).version == "1"
  end

  defp good_attrs(sid) do
    %{
      service_id: sid,
      endpoint_url: "https://example.test/svc",
      required_auth: :NONE,
      timeout_ms: 5_000,
      scope: :global
    }
  end
end
