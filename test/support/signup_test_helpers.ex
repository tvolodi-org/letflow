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

  @doc """
  T-1679: the settings the in-process tenant create needs (platform tenant pinned, hostname suffix,
  public base URL). Restored in on_exit. Returns the platform tenant.
  """
  def tenant_create_env!(suffix \\ "qa.example.test") do
    platform = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "t1679-plat")
    Letflow.Support.PlatformTenantFixture.pin!(platform.tenant_id)

    prov = Application.get_env(:letflow, Letflow.TenantProvisioner)
    url = Application.get_env(:letflow, :provisioner_public_base_url)

    Application.put_env(:letflow, Letflow.TenantProvisioner,
      allowed_hostname_suffixes: [suffix],
      demo_lifetime_days: 14,
      default_modules: []
    )

    Application.put_env(:letflow, :provisioner_public_base_url, "https://letflow.qa.example")

    ExUnit.Callbacks.on_exit(fn ->
      restore(Letflow.TenantProvisioner, prov)
      restore(:provisioner_public_base_url, url)
    end)

    platform
  end

  @doc "Removes a tenant the saga created (lifecycle row before the tenant row); idempotent."
  def drop_tenant!(tenant_id) do
    import Ecto.Query, only: [from: 2]
    alias Letflow.Repo

    Letflow.Test.SandboxAutoMode.enter_auto_mode!(Repo)

    case Letflow.TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
      _invalid -> :ok
    end

    # Module installs add global rows that reference the tenant: delete from every public table with
    # a tenant foreign key before the lifecycle and tenant rows.
    %{rows: tables} =
      Repo.query!("""
      SELECT DISTINCT c.conrelid::regclass::text, a.attname FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
      WHERE c.contype = 'f' AND c.confrelid = 'public.tenants'::regclass
        AND c.conrelid::regclass::text NOT IN ('tenant_lifecycles', 'onboarding_registry', 'tenant_schemas')
      """)

    for [table, column] <- tables do
      Repo.query!("DELETE FROM #{table} WHERE #{column} = $1", [Ecto.UUID.dump!(tenant_id)])
    end

    for mod <- [
          Letflow.TenantProvisioner.Lifecycle,
          Letflow.Identity.OnboardingRecord,
          Letflow.TenantProvisioning.Registration
        ] do
      Repo.delete_all(from(x in mod, where: x.tenant_id == ^tenant_id))
    end

    Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^tenant_id))
    Repo.delete_all(from(r in Letflow.Signup.Request, where: r.tenant_id == ^tenant_id))
    :ok
  end

  @doc "Registers the on_exit cleanup of a tenant the test may create."
  def track_tenant(tenant_id), do: ExUnit.Callbacks.on_exit(fn -> drop_tenant!(tenant_id) end)
end
