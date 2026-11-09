defmodule Letflow.Test.SignupHelpers do
  @moduledoc """
  T-1579 test helpers (test-only): drive the real `Letflow.Router` at `/api/signup`, configure the
  flag and settings, and wait for the off-request mail task.
  """

  import Plug.Conn
  import Plug.Test

  @router_opts Letflow.Router.init([])
  @supervisor Letflow.LoginDiscovery.TaskSupervisor
  @base "https://qa.example.test"

  def base_url, do: @base

  @doc "Turns the flag on with generous defaults; `overrides` win. Restores in on_exit."
  def enable!(overrides \\ []) do
    previous = Application.get_env(:letflow, Letflow.Signup)
    notifier = Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier)

    Application.put_env(
      :letflow,
      Letflow.Signup,
      Keyword.merge(
        [
          enabled: true,
          base_url: @base,
          pending_cap: 50,
          ip_hourly_cap: 100,
          resend_interval_seconds: 60,
          token_ttl_hours: 24,
          abandon_days: 7
        ],
        overrides
      )
    )

    Letflow.LoginDiscoveryNotifierDouble.set_owner(self())

    ExUnit.Callbacks.on_exit(fn ->
      Letflow.LoginDiscoveryNotifierDouble.reset()
      restore(Letflow.Signup, previous)
      restore(Letflow.LoginDiscovery.Notifier, notifier)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:letflow, key)
  defp restore(key, value), do: Application.put_env(:letflow, key, value)

  def request(method, path, body \\ nil, opts \\ []) do
    conn =
      case body do
        nil -> conn(method, path)
        raw when is_binary(raw) -> conn(method, path, raw)
        map -> conn(method, path, Jason.encode!(map))
      end

    conn =
      if body && Keyword.get(opts, :json, true),
        do: put_req_header(conn, "content-type", "application/json"),
        else: conn

    conn = %{conn | remote_ip: Keyword.get(opts, :ip, {203, 0, 113, 9})}
    Letflow.Router.call(conn, @router_opts)
  end

  def signup_body(overrides \\ %{}) do
    Map.merge(
      %{
        "company_name" => "Acme Ltd",
        "email" => "Owner@Example.test",
        "language" => "en",
        "terms_accepted" => true
      },
      overrides
    )
  end

  def post_signup(overrides \\ %{}, opts \\ []),
    do: request(:post, "/api/signup", signup_body(overrides), opts)

  def json(conn), do: Jason.decode!(conn.resp_body)

  @doc "Waits (bounded) until the mail task supervisor has no running child."
  def await_mail(deadline_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await(deadline)
  end

  defp do_await(deadline) do
    cond do
      Task.Supervisor.children(@supervisor) == [] -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> Process.sleep(10) && do_await(deadline)
    end
  end

  @doc "The token in a delivered message."
  def token_from(%{body: body}) do
    [_, token] = Regex.run(~r{/signup/verify\?token=([A-Za-z0-9_-]+)}, body)
    token
  end
end
