defmodule Letflow.Support.MockOidcProviderTest do
  @moduledoc """
  The mock OIDC provider keeps serving after an idle spell longer than its accept timeout.

  The acceptor used to end its loop on the first `{:error, :timeout}` from
  `:gen_tcp.accept/2` (15 s). A test whose setup takes longer than that before the first
  token check (three tenants with six module installs each, `register_router_test.exs`
  A8-R-XT in CI) then found no server: the realm's oidcc worker failed its first metadata
  load, backed off, and the request answered 401. These tests shorten the accept timeout so
  the idle spell is a fraction of a second.
  """

  use ExUnit.Case, async: true

  alias Letflow.Support.MockOidcProvider

  @realm "mock-idle"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    :ok
  end

  defp discovery(base_url) do
    url = String.to_charlist("#{base_url}/realms/#{@realm}/.well-known/openid-configuration")
    :httpc.request(:get, {url, []}, [timeout: 2_000, connect_timeout: 2_000], [])
  end

  test "M1 serves the discovery document right after start" do
    %{base_url: base_url} = MockOidcProvider.start([@realm], accept_timeout: 50)
    assert {:ok, {{_, 200, _}, _headers, body}} = discovery(base_url)
    assert %{"issuer" => issuer} = Jason.decode!(to_string(body))
    assert issuer == "#{base_url}/realms/#{@realm}"
  end

  test "M2 still serves after an idle spell longer than the accept timeout" do
    %{base_url: base_url} = MockOidcProvider.start([@realm], accept_timeout: 50)

    # Idle for several accept timeouts before the first request.
    Process.sleep(300)
    assert {:ok, {{_, 200, _}, _headers, _body}} = discovery(base_url)

    # And again after a second idle spell between requests.
    Process.sleep(300)
    assert {:ok, {{_, 200, _}, _headers, _body}} = discovery(base_url)
  end
end
