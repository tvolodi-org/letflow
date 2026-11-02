defmodule Letflow.Plugs.ClientIpConfigTest do
  @moduledoc """
  REQ-439: tests of `Letflow.Plugs.ClientIp.call/2` reading the trust list from
  application config at call time (design s2, invariant 6). These tests mutate the
  global application env, so they live in their own `async: false` module; the pure
  tests stay async in `client_ip_test.exs`. Env is restored in `on_exit`.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import Plug.Conn
  import Plug.Test

  alias Letflow.Plugs.ClientIp

  @trusted {{10, 0, 0, 0}, 8}
  @peer {10, 0, 0, 7}

  setup do
    original = Application.fetch_env(:letflow, ClientIp)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:letflow, ClientIp, value)
        :error -> Application.delete_env(:letflow, ClientIp)
      end
    end)

    {:ok, original: original}
  end

  defp spoofed_conn do
    %{conn(:get, "/") | remote_ip: @peer} |> put_req_header("x-real-ip", "198.51.100.23")
  end

  test "config/test.exs default trusts nobody", %{original: original} do
    assert original == {:ok, trusted_proxies: []}
  end

  test "with no :trusted_proxies opt the plug reads application config at call time" do
    Application.put_env(:letflow, ClientIp, trusted_proxies: [@trusted])
    assert ClientIp.call(spoofed_conn(), []).assigns.client_ip == {198, 51, 100, 23}

    Application.put_env(:letflow, ClientIp, trusted_proxies: [])
    assert ClientIp.call(spoofed_conn(), []).assigns.client_ip == @peer
  end

  test "the whole config key deleted fails closed: client_ip == remote_ip despite a spoofed header" do
    Application.delete_env(:letflow, ClientIp)
    conn = ClientIp.call(spoofed_conn(), [])
    assert conn.assigns.client_ip == @peer
    assert conn.remote_ip == @peer
  end

  test ":trusted_proxies key missing from the module's config fails closed" do
    Application.put_env(:letflow, ClientIp, other: :x)
    assert ClientIp.call(spoofed_conn(), []).assigns.client_ip == @peer
  end

  test "a non-list :trusted_proxies opt falls through to config, not to trust" do
    Application.delete_env(:letflow, ClientIp)
    conn = ClientIp.call(spoofed_conn(), trusted_proxies: :all)
    assert conn.assigns.client_ip == @peer
  end
end
