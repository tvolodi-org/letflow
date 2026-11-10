defmodule Letflow.Signup.Provisioning do
  @moduledoc """
  T-1593 (TA-SL2b part a, decision 0085): the realm step of the sign-up saga. From a verified row in step
  `ready_for_provisioning`: ask the provisioner for the tenant's realm and first admin
  (`Letflow.Signup.RealmProvisioner`), record realm/issuer/template version, mail the one-time first
  credential, and stop at step `credential_sent` (the Letflow tenant create is part b).

  * **No double POST.** `claim/1` is a compare-and-set on `claimed_at` (stale after 2 minutes): the
    temporary password is shown once, so two runs must not both create.
  * **Bounded.** A run makes `length(retry_delays_ms) + 1` attempts; `max_attempts` caps the total per
    request. Permanent errors fail at once. Then `state: failed, step: provisioning_failed` with a fixed
    `last_error` code and one fixed-text warning. `resume/1` (mix `letflow.signup.resume`) is the cleanup path.
  * **The password lives in one local variable** from the 201 to the mail send. It is never written to
    the row, a log or an error (INV-4). If the mail fails or the process dies after the 201, the retry sees
    a replay (no password) and sends the "Forgot password" hint instead.
  * Nothing here deletes anything: an orphaned realm is removed by infra's reaper. Runs only when the
    platform flag is on and the provisioner is configured; otherwise a no-op.
  """

  import Ecto.Query

  alias Letflow.Repo
  alias Letflow.Signup
  alias Letflow.Signup.{Mailer, Messages, RealmProvisioner, Request}

  require Logger

  @supervisor Letflow.LoginDiscovery.TaskSupervisor
  @stale_claim_seconds 120
  @steps ["ready_for_provisioning", "realm_created"]
  @retryable ~w(unavailable rate_limited credential_mail_failed internal attempts_exhausted)

  @doc "True when the flag is on and the provisioner URL, token and hostname domain are all set."
  @spec configured?() :: boolean()
  def configured? do
    cfg = Signup.config()

    Signup.enabled?() and is_binary(cfg.provisioner_url) and is_binary(cfg.hostname_domain) and
      System.get_env(RealmProvisioner.token_env()) not in [nil, ""]
  end

  @doc "Starts `run/1` as a supervised task after the verify commit; always `:ok`, never raises (INV-8)."
  @spec start_async(String.t()) :: :ok
  def start_async(tenant_id) do
    if configured?() do
      Task.Supervisor.start_child(@supervisor, fn -> run(tenant_id) end)
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Runs the step for one request until it is done, failed, or someone else holds it.
  Returns `:ok` (credential sent), `:noop`, or `{:failed, code}`.
  """
  @spec run(String.t()) :: :ok | :noop | {:failed, String.t()}
  def run(tenant_id) do
    if configured?() do
      delays = Signup.config().retry_delays_ms
      loop(tenant_id, delays ++ [:last])
    else
      :noop
    end
  end

  defp loop(tenant_id, [delay | rest]) do
    case attempt(tenant_id) do
      :done ->
        :ok

      :noop ->
        :noop

      {:permanent, code} ->
        fail(tenant_id, code)

      {:retry, code, hint} ->
        if delay == :last do
          fail(tenant_id, code)
        else
          note_error(tenant_id, code)
          Process.sleep(hint || delay)
          loop(tenant_id, rest)
        end
    end
  end

  defp attempt(tenant_id) do
    cfg = Signup.config()

    case claim(tenant_id) do
      nil ->
        :noop

      %Request{step_attempts: n} when n > cfg.max_attempts ->
        release(tenant_id)
        {:permanent, :attempts_exhausted}

      row ->
        result =
          try do
            process(row, cfg)
          rescue
            _exception -> {:retry, :internal, nil}
          catch
            _kind, _reason -> {:retry, :internal, nil}
          end

        release(tenant_id)
        result
    end
  end

  @doc false
  @spec claim(String.t()) :: Request.t() | nil
  def claim(tenant_id) do
    now = DateTime.utc_now()
    stale = DateTime.add(now, -@stale_claim_seconds, :second)

    query =
      from(r in Request,
        where:
          r.tenant_id == ^tenant_id and r.state in ["verified", "provisioning"] and
            r.step in @steps and (is_nil(r.claimed_at) or r.claimed_at < ^stale),
        select: r
      )

    case Repo.update_all(query,
           set: [claimed_at: now, state: "provisioning", updated_at: now],
           inc: [step_attempts: 1]
         ) do
      {1, [row]} -> row
      _none -> nil
    end
  end

  defp release(tenant_id) do
    Repo.update_all(from(r in Request, where: r.tenant_id == ^tenant_id), set: [claimed_at: nil])
  end

  defp note_error(tenant_id, code) do
    Repo.update_all(from(r in Request, where: r.tenant_id == ^tenant_id),
      set: [last_error: Atom.to_string(code)]
    )
  end

  # ── one attempt ─────────────────────────────────────────────────────────

  defp process(%Request{email: nil}, _cfg), do: {:permanent, :no_recipient}

  # The realm exists (a crash or a mail failure after the 201): the password is gone.
  defp process(%Request{step: "realm_created"} = row, _cfg), do: send_credential(row, nil, nil)

  defp process(%Request{step: "ready_for_provisioning"} = row, cfg) do
    case RealmProvisioner.create_realm(row, cfg) do
      {:ok, _kind, realm} ->
        row =
          row
          |> Ecto.Changeset.change(
            idp_realm_id: realm.realm,
            idp_issuer: realm.issuer,
            template_version: realm.template_version,
            step: "realm_created"
          )
          |> Repo.update!()

        send_credential(row, realm.username, realm.password)

      {:error, {:rate_limited, hint}} ->
        {:retry, :rate_limited, hint}

      {:error, :unavailable} ->
        {:retry, :unavailable, nil}

      {:error, code} ->
        {:permanent, code}
    end
  end

  defp send_credential(row, username, password) do
    message =
      if is_binary(password) do
        Messages.first_credential(row.language, username || row.email, password)
      else
        Messages.reset_hint(row.language)
      end

    case Mailer.deliver_now(Map.put(message, :to, row.email)) do
      :ok ->
        row
        |> Ecto.Changeset.change(
          step: "credential_sent",
          credential_sent_at: DateTime.utc_now(),
          last_error: nil
        )
        |> Repo.update!()

        :done

      {:error, :failed} ->
        {:retry, :credential_mail_failed, nil}
    end
  end

  defp fail(tenant_id, code) do
    code = Atom.to_string(code)

    Repo.update_all(from(r in Request, where: r.tenant_id == ^tenant_id),
      set: [
        state: "failed",
        step: "provisioning_failed",
        last_error: code,
        claimed_at: nil,
        updated_at: DateTime.utc_now()
      ]
    )

    Logger.warning("signup provisioning failed: #{code}")
    {:failed, code}
  end

  # ── cleanup path ────────────────────────────────────────────────────────

  @doc """
  Operator resume (`mix letflow.signup.resume`): puts retryable `failed` rows (all of them with
  `force: true`) back to `provisioning` with a fresh attempt budget, then runs every unfinished request
  (or only `tenant_id:`) in the foreground. Returns `[{tenant_id, result}]`.
  """
  @spec resume(keyword()) :: [{String.t(), :ok | :noop | {:failed, String.t()}}]
  def resume(opts \\ []) do
    only = Keyword.get(opts, :tenant_id)
    force = Keyword.get(opts, :force, false)

    failed =
      from(r in Request, where: r.state == "failed" and r.step == "provisioning_failed")
      |> scope(only)
      |> Repo.all()
      |> Enum.filter(&(force or &1.last_error in @retryable))

    for row <- failed do
      step = if row.idp_realm_id, do: "realm_created", else: "ready_for_provisioning"

      Repo.update_all(from(r in Request, where: r.tenant_id == ^row.tenant_id),
        set: [state: "provisioning", step: step, step_attempts: 0, claimed_at: nil]
      )
    end

    from(r in Request,
      where: r.state in ["verified", "provisioning"] and r.step in @steps,
      select: r.tenant_id,
      order_by: r.inserted_at
    )
    |> scope(only)
    |> Repo.all()
    |> Enum.map(&{&1, run(&1)})
  end

  defp scope(query, nil), do: query
  defp scope(query, tenant_id), do: where(query, [r], r.tenant_id == ^tenant_id)
end
