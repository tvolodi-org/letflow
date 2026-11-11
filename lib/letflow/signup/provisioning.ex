defmodule Letflow.Signup.Provisioning do
  @moduledoc """
  T-1593 (TA-SL2b part a, decision 0085): the realm step of the sign-up saga. From a verified row in step
  `ready_for_provisioning`: ask the provisioner for the tenant's realm and first admin
  (`Letflow.Signup.RealmProvisioner`), record realm/issuer/template version, mail the one-time first
  credential, then (T-1679, part 1a) create the Letflow tenant in-process through
  `Letflow.TenantProvisioner.create/1` with the row's `tenant_id` (step `tenant_created`), then (T-1685, part 1b)
  send the one welcome mail with the workspace link `https://<label>.<hostname_domain>/?realm=<slug>` in the
  person's language and complete the row (state/step `completed`). A mail failure is the retryable code
  `welcome_mail_failed`; the tenant stays and the credential mail is never repeated. Delivery is at-least-once only
  if the process dies between a successful send and the row update (same trade-off as the credential mail).

  * **The tenant create is idempotent and carries no credential.** A replay is the provisioner's own
    `:existing` answer (nothing is written); no `auth_context` or provisioner bearer token is involved
    (decision 0085 D9). A failed create is retryable (`tenant_internal`) and resumes at `credential_sent`,
    so the credential mail is never sent twice.

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
  alias Letflow.TenantProvisioner

  require Logger

  @supervisor Letflow.LoginDiscovery.TaskSupervisor
  @stale_claim_seconds 120
  @steps ["ready_for_provisioning", "realm_created", "credential_sent", "tenant_created"]
  # The steps the timer sweep resumes (decision 0085 addendum): `tenant_created` is left to the operator path.
  @resume_steps ["ready_for_provisioning", "realm_created", "credential_sent"]
  @sweep_limit 50
  @retryable ~w(unavailable rate_limited credential_mail_failed internal attempts_exhausted tenant_internal welcome_mail_failed)

  @doc "True when the flag is on and the provisioner URL, token and hostname domain are all set."
  @spec configured?() :: boolean()
  def configured? do
    cfg = Signup.config()

    Signup.enabled?() and is_binary(cfg.provisioner_url) and is_binary(cfg.hostname_domain) and
      System.get_env(RealmProvisioner.token_env()) not in [nil, ""]
  end

  @doc false
  # Tenant ids of unfinished requests the timer sweep may start: `verified`/`provisioning`, at one of the
  # three resumable steps, claim empty or older than the stale-claim age; never `failed`. Bounded per tick.
  @spec stale_unfinished_ids(DateTime.t()) :: [String.t()]
  def stale_unfinished_ids(now \\ DateTime.utc_now()) do
    stale = DateTime.add(now, -@stale_claim_seconds, :second)

    Repo.all(
      from(r in Request,
        where:
          r.state in ["verified", "provisioning"] and r.step in @resume_steps and
            (is_nil(r.claimed_at) or r.claimed_at < ^stale),
        select: r.tenant_id,
        order_by: r.inserted_at,
        limit: @sweep_limit
      )
    )
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
  Returns `:ok` (tenant created, welcome mail sent, row completed), `:noop`, or `{:failed, code}`.
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
  defp process(%Request{step: "realm_created"} = row, cfg),
    do: send_credential(row, nil, nil, cfg)

  # The credential mail went out (a failed or interrupted tenant create): never mail again.
  defp process(%Request{step: "credential_sent"} = row, cfg), do: create_tenant(row, cfg)

  # The tenant exists (a crash or a mail failure after the create): only the welcome mail is left.
  defp process(%Request{step: "tenant_created"} = row, cfg), do: send_welcome(row, cfg)

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

        send_credential(row, realm.username, realm.password, cfg)

      {:error, {:rate_limited, hint}} ->
        {:retry, :rate_limited, hint}

      {:error, :unavailable} ->
        {:retry, :unavailable, nil}

      {:error, code} ->
        {:permanent, code}
    end
  end

  defp send_credential(row, username, password, cfg) do
    message =
      if is_binary(password) do
        Messages.first_credential(row.language, username || row.email, password)
      else
        Messages.reset_hint(row.language)
      end

    case Mailer.deliver_now(Map.put(message, :to, row.email)) do
      :ok ->
        row =
          row
          |> Ecto.Changeset.change(
            step: "credential_sent",
            credential_sent_at: DateTime.utc_now(),
            last_error: nil
          )
          |> Repo.update!()

        create_tenant(row, cfg)

      {:error, :failed} ->
        {:retry, :credential_mail_failed, nil}
    end
  end

  # T-1679: the in-process tenant create. Parse first, so a bad field fails before any write.
  defp create_tenant(row, cfg) do
    body = %{
      "tenant_id" => row.tenant_id,
      "name" => row.company_name,
      "language" => row.language,
      "tier" => "demo",
      "owner_email" => row.email,
      "hostname" => hostname(row, cfg),
      "idp_realm_id" => row.idp_realm_id,
      "source_key" => source_key(row.ip_key)
    }

    with {:ok, request} <- TenantProvisioner.Request.parse(body),
         {:ok, _kind, _body} <- TenantProvisioner.create(request) do
      row
      |> Ecto.Changeset.change(step: "tenant_created", last_error: nil)
      |> Repo.update!()
      |> send_welcome(cfg)
    else
      {:error, :internal} -> {:retry, :tenant_internal, nil}
      {:error, :conflict} -> {:permanent, :tenant_conflict}
      {:error, {:limit, :demo_cap, _language}} -> {:permanent, :demo_cap_reached}
      {:error, {:limit, :source_budget, _language}} -> {:permanent, :source_budget}
      {:error, {:limit, :email_domain_budget, _language}} -> {:permanent, :email_domain_budget}
      {:error, _invalid_field} -> {:permanent, :invalid_tenant}
    end
  end

  defp hostname(row, cfg),
    do: RealmProvisioner.label(row.tenant_id) <> "." <> to_string(cfg.hostname_domain)

  # T-1685: the one welcome mail. Host from operator config and the server-made tenant id (INV-9).
  defp send_welcome(row, cfg) do
    link =
      "https://" <>
        hostname(row, cfg) <> "/?realm=" <> TenantProvisioner.Request.slug(row.tenant_id)

    case Mailer.deliver_now(Map.put(Messages.welcome(row.language, link), :to, row.email)) do
      :ok ->
        row
        |> Ecto.Changeset.change(state: "completed", step: "completed", last_error: nil)
        |> Repo.update!()

        :done

      {:error, :failed} ->
        {:retry, :welcome_mail_failed, nil}
    end
  end

  defp source_key(key) when is_binary(key), do: Base.encode16(key, case: :lower)
  defp source_key(_none), do: nil

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
      step =
        cond do
          row.credential_sent_at -> "credential_sent"
          row.idp_realm_id -> "realm_created"
          true -> "ready_for_provisioning"
        end

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
