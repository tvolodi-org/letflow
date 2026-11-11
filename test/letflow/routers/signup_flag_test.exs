defmodule Letflow.Routers.SignupFlagTest do
  @moduledoc "T-1579 F1: with the flag unset or false every sign-up route is the standard 404 and writes nothing."

  use Letflow.DataCase, async: false
  @moduletag :unit

  import Letflow.Test.SignupHelpers

  alias Letflow.Signup.Request

  setup do
    previous = Application.get_env(:letflow, Letflow.Signup)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:letflow, Letflow.Signup)
  defp restore(value), do: Application.put_env(:letflow, Letflow.Signup, value)

  for {label, config} <- [unset: nil, false: [enabled: false], truthy_string: [enabled: "true"]] do
    test "F1 #{label}: every route answers the standard 404 and no row is written" do
      case unquote(Macro.escape(config)) do
        nil -> Application.delete_env(:letflow, Letflow.Signup)
        config -> Application.put_env(:letflow, Letflow.Signup, config)
      end

      assert request(:get, "/api/signup/config").status == 404
      assert post_signup().status == 404

      assert request(:post, "/api/signup/verify", %{"token" => String.duplicate("a", 43)}).status ==
               404

      assert request(:get, "/api/signup/anything").status == 404
      assert request(:delete, "/api/signup").status == 404
      assert Letflow.Repo.aggregate(Request, :count) == 0
    end
  end

  test "SU-A05-1: the disabled answer carries the three security headers" do
    Application.put_env(:letflow, Letflow.Signup, enabled: false)
    assert_headers(request(:get, "/api/signup/config"))
  end

  test "SU-A05-1: the catch-all answer carries the three security headers" do
    Application.put_env(:letflow, Letflow.Signup, enabled: true)
    conn = request(:get, "/api/signup/anything")
    assert conn.status == 404
    assert_headers(conn)
  end

  defp assert_headers(conn) do
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert Plug.Conn.get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert Plug.Conn.get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end
end
