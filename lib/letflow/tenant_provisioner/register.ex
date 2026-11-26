defmodule Letflow.TenantProvisioner.Register do
  @moduledoc """
  T-2728 (pilot gap G17d; `docs/platform-register-tenant-v2.md` sections 5, 8 and 9): a create of route 3
  (`POST /admin/v1/tenants`) and of route 4 (the self-service sign-up) that runs through the
  `platform.register_tenant` PROCESS instead of writing the tenant itself.

  The ONE switch is `Letflow.TenantProvisioner.Config.create_via_process?/0` (default `false`: the old
  synchronous path, byte for byte). It also needs the platform step runner; with the runner off the
  old path is used and one warning is logged, because an instance would otherwise wait for a runner
  that is not there.

  ## The front gate (`admit/3`, under the per-tenant lock of `TenantProvisioner.create/2`)

    1. an admission exists for the tenant id -- a REPLAY: the request fingerprint is compared. Equal:
       start again (the engine answers the first instance, `replayed`); different: `{:error, :conflict}`;
    2. a tenant or lifecycle row exists WITHOUT an admission (made by the old path) -- the old path
       answers, no second registration starts;
    3. the realm probe and the taken checks of today, unchanged;
    4. one transaction under the demo-cap lock: both daily budgets, the demo count, then the admission
       INSERT (the reservation). A refusal is today's `{:limit, which, language}`, BEFORE any instance;
    5. the system-authority start (`PlatformProcesses.start_register_tenant_system/3`), then the
       `instance_id` is stored on the admission.

  The start key is the slug alone, so a double click is a replay and a replay with other values never
  reaches the engine.

  ## The wait (`finish/4`)

  After the lock is released the call polls the instance projection (one indexed read, every 250 ms,
  at most `wait_ms / 250` reads). COMPLETED answers like the old path (`:created` / `:existing`);
  still running answers `{:ok, :accepted, %{status: "provisioning"}}`; ERROR / CANCELLED answers
  `{:ok, :accepted, %{status: "failed", reason: code}}` with a code of a CLOSED set. No message, no
  secret, no value of the request is in an answer.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.EventStore.InstanceProjection
  alias Letflow.PlatformProcesses
  alias Letflow.PlatformProcesses.SystemStart
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioner
  alias Letflow.TenantProvisioner.Admission
  alias Letflow.TenantProvisioner.Config
  alias Letflow.TenantProvisioner.Lifecycle

  @poll_ms 250

  @conflict_kinds ~w(platform_call_duplicate_slug platform_call_hostname_taken
                     platform_call_hostname_mismatch platform_call_realm_already_bound)
  @invalid_kinds ~w(platform_call_arg_invalid)

  @doc """
  True when a create runs through the process: the setting is on AND the step runner is on. With the
  setting on and the runner off, one warning is logged and the old path is used.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    cond do
      not Config.create_via_process?() ->
        false

      Application.get_env(:letflow, :start_platform_step_runner, false) ->
        true

      true ->
        Logger.warning(
          "provisioner: create_via_process is on but the platform step runner is off; old path used"
        )

        false
    end
  end

  @doc "The front gate and the start; see the moduledoc. Runs under `TenantProvisioner.with_lock/2`."
  @spec admit(map(), String.t(), String.t()) ::
          {:started, String.t(), :created | :existing}
          | {:old, TenantProvisioner.create_result()}
          | {:error, term()}
  def admit(request, platform_prefix, server_url) do
    fingerprint = fingerprint(request)

    case Repo.get(Admission, request.tenant_id) do
      %Admission{request_fingerprint: ^fingerprint} -> start(request, :existing)
      %Admission{} -> {:error, :conflict}
      nil -> admit_new(request, fingerprint, platform_prefix, server_url)
    end
  end

  defp admit_new(request, fingerprint, platform_prefix, server_url) do
    exists? =
      Repo.exists?(from(t in Letflow.Identity.Tenant, where: t.id == ^request.tenant_id)) or
        Repo.exists?(from(l in Lifecycle, where: l.tenant_id == ^request.tenant_id))

    cond do
      exists? ->
        {:old, TenantProvisioner.create_old_path(request, platform_prefix, server_url)}

      true ->
        with :ok <- TenantProvisioner.probe_realm(request.idp_realm_id),
             :ok <- TenantProvisioner.not_taken(request),
             :ok <- reserve(request, fingerprint) do
          start(request, :created)
        end
    end
  end

  # One transaction under the demo-cap lock (the same key as the old path's insert): budgets, count,
  # then the admission. The counts of `TenantProvisioner` include this reservation.
  defp reserve(request, fingerprint) do
    result =
      Repo.transaction(fn ->
        Repo.query!(
          "SELECT pg_advisory_xact_lock(hashtextextended('letflow.provisioner.demo_cap', 0))"
        )

        TenantProvisioner.check_budget(
          :source_ip_key,
          request.source_ip_key,
          Config.source_daily_budget(),
          :source_budget
        )

        TenantProvisioner.check_budget(
          :email_domain_key,
          request.email_domain_key,
          Config.email_domain_daily_budget(),
          :email_domain_budget
        )

        if TenantProvisioner.demo_count() >= Config.demo_cap(),
          do: Repo.rollback({:limit, :demo_cap})

        Repo.insert!(%Admission{
          tenant_id: request.tenant_id,
          tier: request.tier,
          language: request.language,
          expires_at: request.expires_at,
          source_ip_key: request.source_ip_key,
          email_domain_key: request.email_domain_key,
          request_fingerprint: fingerprint
        })

        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, {:limit, which}} -> {:error, {:limit, which, request.language}}
    end
  end

  defp start(request, outcome) do
    {:ok, system_start} =
      SystemStart.for_route(Map.get(request, :route, :admin_v1_tenants_create))

    case PlatformProcesses.start_register_tenant_system(request, system_start, []) do
      {:ok, %{instance_id: instance_id}} ->
        link(request.tenant_id, instance_id)
        {:started, instance_id, outcome}

      {:error, :idempotency_key_reuse} ->
        {:error, :conflict}

      {:error, reason} ->
        # The tag only: a start error can carry a changeset (INV-4, INV-8).
        Logger.error("provisioner: register_tenant start failed: #{inspect(tag(reason))}")
        {:error, :internal}
    end
  end

  defp link(tenant_id, instance_id) do
    Repo.update_all(
      from(a in Admission, where: a.tenant_id == ^tenant_id and is_nil(a.instance_id)),
      set: [instance_id: instance_id]
    )
  end

  @doc """
  Waits for the instance (at most `wait_ms`) and shapes the answer; see the moduledoc.
  """
  @spec finish(term(), map(), String.t(), non_neg_integer()) :: TenantProvisioner.create_result()
  def finish({:started, instance_id, outcome}, request, server_url, wait_ms) do
    case await(instance_id, div(wait_ms, @poll_ms)) do
      :completed ->
        {:ok, outcome, active_body(request, server_url)}

      :running ->
        {:ok, :accepted, accepted_body(request, "provisioning", nil)}

      :failed ->
        {:ok, :accepted, accepted_body(request, "failed", failure_reason(instance_id))}
    end
  end

  def finish({:old, result}, _request, _server_url, _wait_ms), do: result
  def finish({:error, _reason} = error, _request, _server_url, _wait_ms), do: error

  defp await(instance_id, polls_left) do
    case state(instance_id) do
      :running when polls_left > 0 ->
        Process.sleep(@poll_ms)
        await(instance_id, polls_left - 1)

      state ->
        state
    end
  end

  # One indexed read of the instance projection in the platform prefix.
  defp state(instance_id) do
    with {:ok, prefix} <- PlatformTenant.platform_prefix(),
         %InstanceProjection{status: status} <-
           Repo.get(InstanceProjection, instance_id, prefix: prefix) do
      case status do
        :completed -> :completed
        status when status in [:error, :cancelled] -> :failed
        _active -> :running
      end
    else
      _other -> :running
    end
  end

  @doc """
  The closed reason of a failed instance (`conflict`, `invalid_request` or `internal`), read from the
  failed step's closed failure kind. Never a message.
  """
  @spec failure_reason(String.t()) :: String.t()
  def failure_reason(instance_id) do
    with {:ok, prefix} <- PlatformTenant.platform_prefix(),
         kind when is_binary(kind) <-
           Repo.one(
             from(d in Letflow.PlatformFunctions.Dispatcher.StepDispatch,
               where: d.instance_id == ^instance_id and d.status == :given_up,
               select: d.last_failure_kind,
               limit: 1
             ),
             prefix: prefix
           ) do
      cond do
        kind in @conflict_kinds -> "conflict"
        kind in @invalid_kinds -> "invalid_request"
        true -> "internal"
      end
    else
      _other -> "internal"
    end
  rescue
    _error -> "internal"
  end

  @doc "The instance state of an admitted tenant for the `GET` read model: `:completed | :running | :failed`."
  @spec instance_state(String.t()) :: :completed | :running | :failed
  def instance_state(instance_id), do: state(instance_id)

  defp active_body(request, server_url) do
    %{
      tenant_id: request.tenant_id,
      status: "active",
      server_url: server_url,
      handover: %{login_url: "https://" <> request.hostname}
    }
  end

  defp accepted_body(request, status, reason) do
    base = %{
      tenant_id: request.tenant_id,
      status: status,
      poll: "/admin/v1/tenants/" <> request.tenant_id
    }

    if reason, do: Map.put(base, :reason, reason), else: base
  end

  @doc """
  The SHA-256 of the canonical encoding of the request AS SENT (`expires_at` as sent, nil when absent,
  never the computed default). The raw e-mail is not in the request (only its key), so no personal
  value is hashed in the clear.
  """
  @spec fingerprint(map()) :: binary()
  def fingerprint(request) do
    fields =
      for key <-
            ~w(tenant_id name language tier email_key hostname idp_realm_id expires_at_sent source_ip_key)a do
        {key, Map.get(request, key)}
      end

    :crypto.hash(:sha256, :erlang.term_to_binary(fields, [:deterministic]))
  end

  defp tag({tag, _detail}) when is_atom(tag), do: tag
  defp tag(tag) when is_atom(tag), do: tag
  defp tag(_other), do: :other
end
