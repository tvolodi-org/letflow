defmodule Letflow.Test.ProvisionerStub do
  @moduledoc """
  T-1593 test-only stand-in for infra's tenant-provisioner: a Bandit plug on a random loopback port.
  Behaviour is a script in an Agent (a list of `{status, body}` per call, last entry repeats); every
  request is recorded (`calls/1`) with its method, path, authorization header and decoded body.
  """

  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def start!(script_post, script_get \\ [{404, %{}}]) do
    {:ok, agent} = Agent.start_link(fn -> %{post: script_post, get: script_get, calls: []} end)
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    {:ok, _} =
      Bandit.start_link(plug: {__MODULE__, agent}, port: port, ip: :loopback, startup_log: false)

    %{agent: agent, url: "http://127.0.0.1:#{port}"}
  end

  def set_script(%{agent: agent}, key, script) when key in [:post, :get],
    do: Agent.update(agent, &Map.put(&1, key, script))

  def calls(%{agent: agent}), do: agent |> Agent.get(& &1.calls) |> Enum.reverse()
  def posts(stub), do: stub |> calls() |> Enum.filter(&(&1.method == "POST"))

  def created(tenant_id, overrides \\ %{}) do
    label = Letflow.Signup.RealmProvisioner.label(tenant_id)

    Map.merge(
      %{
        "tenant_id" => tenant_id,
        "realm" => label,
        "issuer" => "http://127.0.0.1:8080/realms/" <> label,
        "client_id" => "letflow-web",
        "template_version" => "v2",
        "first_admin" => %{
          "username" => "admin",
          "email" => "owner@example.test",
          "initial_password" => "Tmp-Pa55-ONE-time",
          "password_temporary" => true
        }
      },
      overrides
    )
  end

  def call(conn, agent) do
    {:ok, raw, conn} = read_body(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)
    key = if conn.method == "POST", do: :post, else: :get

    {status, resp} =
      Agent.get_and_update(agent, fn state ->
        call = %{
          method: conn.method,
          path: conn.request_path,
          auth: List.first(get_req_header(conn, "authorization")),
          body: body
        }

        {first, rest} =
          case Map.fetch!(state, key) do
            [one] -> {one, [one]}
            [head | tail] -> {head, tail}
          end

        {first, state |> Map.put(key, rest) |> Map.update!(:calls, &[call | &1])}
      end)

    case resp do
      {:sleep, ms} ->
        Process.sleep(ms)
        send_resp(conn, 200, "{}")

      {:raw, binary} ->
        conn |> put_resp_content_type("application/json") |> send_resp(status, binary)

      map ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(map))
    end
  end
end
