defmodule Letflow.Routers.SignupHttpTest do
  @moduledoc """
  T-1579 H2: one end-to-end sign-up and verify over a real TCP socket (Bandit on a random port, `:httpc`),
  so the mount, body reading and headers are exercised the way a browser reaches them.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import Letflow.Test.SignupHelpers

  alias Letflow.Signup.Request

  setup do
    enable!()
    {:ok, _} = Application.ensure_all_started(:inets)
    port = free_port()
    start_supervised!({Bandit, plug: Letflow.Router, port: port, ip: :loopback})
    %{port: port}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp post(port, path, body) do
    url = String.to_charlist("http://127.0.0.1:#{port}#{path}")

    {:ok, {{_, status, _}, _headers, resp}} =
      :httpc.request(:post, {url, [], ~c"application/json", Jason.encode!(body)}, [], [])

    {status, Jason.decode!(List.to_string(resp))}
  end

  test "H2 sign-up then verify over a socket", %{port: port} do
    assert {202, %{"status" => "check_your_mail"}} = post(port, "/api/signup", signup_body())
    assert_receive {:deliver_message, message}, 2_000
    token = token_from(message)

    assert {200, %{"status" => "verified"}} =
             post(port, "/api/signup/verify", %{"token" => token})

    assert {400, _} = post(port, "/api/signup/verify", %{"token" => "nope"})
    assert Letflow.Repo.one!(Request).state == "verified"
  end
end
