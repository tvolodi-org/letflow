defmodule Letflow.Signup.Provisioning do
  @moduledoc """
  T-1593 (TA-SL2b part a, decision 0085): the provisioning saga of a verified sign-up. T-3154 (owner item 11 /
  D-195) moved the realm out of it: from a verified row in step `ready_for_provisioning` the saga creates the
  Letflow tenant in-process through `Letflow.TenantProvisioner.create/2` with the row's `tenant_id` and NO realm,
  so the `platform.register_tenant` PROCESS makes the realm and the first administrator
  (`tenant.provision_realm_and_invite`, which asks `Letflow.Signup.RealmProvisioner` through the sign-up's own
  wiring) and sends the ONE credential mail. This module calls the provisioner no more and sends no credential
  mail for a new row. Then (T-1685, part 1b)
  send the one welcome mail with the workspace link `https://<label>.<hostname_domain>/?realm=<slug>` in the
  person's language and complete the row (state/step `completed`). A mail failure is the retryable code
  `welcome_mail_failed`; the tenant stays and the credential mail is never repeated. Delivery is at-least-once only
  if the process dies between a successful send and the row update (same trade-off as the credential mail).
  A row an earlier build left at `realm_created` or `credential_sent` already has its realm: the create binds it
  (the realm is the optional field of the create) and the process makes none.

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
  @retryable ~w(unavailable rate_limited credential_mail_failed internal attempts_exhausted tenant_internal tenant_pending welcome_mail_failed)

  @doc "True when the flag is on and the provisioner URL, token and hostname domain are all set."
  @spec configured?() :: boolean()
  def configured?, do: Signup.enabled?() and provisioner_ready?()

  @doc """
  T-3153: true when the provisioner URL, token and hostname domain are set, whatever the sign-up flag says
  (the platform step `tenant.provision_realm_and_invite` reuses the same wiring).
  """
  @spec provisioner_ready?() :: boolean()
  def provisioner_ready? do
    cfg = Signup.config()

    is_binary(cfg.provisioner_url) and is_binary(cfg.hostname_domain) and
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

      {:retry, code, _hint} ->
        if delay == :last do
          fail(tenant_id, code)
        else
          note_error(tenant_id, code)
          Process.sleep(delay)
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

  # A row an earlier build left here (realm made by the saga, credential mail not confirmed): the
  # password is gone, so the hint mail goes out and the process binds the existing realm.
  defp process(%Request{step: "realm_created"} = row, cfg),
    do: send_credential(row, nil, nil, cfg)

  # The credential mail went out (a failed or interrupted tenant create): never mail again.
  defp process(%Request{step: "credential_sent"} = row, cfg), do: create_tenant(row, cfg)

  # The tenant exists (a crash or a mail failure after the create): only the welcome mail is left.
  defp process(%Request{step: "tenant_created"} = row, cfg), do: send_welcome(row, cfg)

  # T-3154: route 4 no longer asks the provisioner itself. The registration PROCESS makes the realm and
  # the first administrator and sends the ONE credential mail (`tenant.provision_realm_and_invite`), so
  # the saga goes straight to the tenant create. The host must still carry an allowed suffix BEFORE the
  # process starts: otherwise the create refuses it later and the process would leave an orphan realm.
  defp process(%Request{step: "ready_for_provisioning"} = row, cfg) do
    case TenantProvisioner.Request.hostname(
           hostname(row, cfg),
           TenantProvisioner.Config.allowed_hostname_suffixes()
         ) do
      {:ok, _host} -> create_tenant(row, cfg)
      {:error, _field} -> {:permanent, :invalid_tenant}
    end
  end

  defp send_credential(row, username, password, cfg) do
    message = Messages.credential_or_hint(row.language, row.email, username, password)

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
      "source_key" => source_key(row.ip_key)
    }

    # A row that already has a realm (made by an earlier build) binds it; a new one has none and the
    # process makes it.
    body = if row.idp_realm_id, do: Map.put(body, "idp_realm_id", row.idp_realm_id), else: body

    # T-2728: route 4 starts the registration process (setting-guarded inside `create/2`) and never
    # waits: a running instance is a retry of the sweep, a failed one maps to the closed codes.
    with {:ok, request} <- TenantProvisioner.Request.parse(body),
         {:ok, kind, answer} <-
           TenantProvisioner.create(request, route: :signup_provisioning, wait_ms: 0),
         :ok <- settled(kind, answer) do
      row
      |> Ecto.Changeset.change(step: "tenant_created", last_error: nil)
      |> Repo.update!()
      |> send_welcome(cfg)
    else
      {:pending, :running} -> {:retry, :tenant_pending, nil}
      {:pending, "conflict"} -> {:permanent, :tenant_conflict}
      {:pending, _failed} -> {:retry, :tenant_internal, nil}
      {:error, :internal} -> {:retry, :tenant_internal, nil}
      {:error, :conflict} -> {:permanent, :tenant_conflict}
      {:error, {:limit, :demo_cap, _language}} -> {:permanent, :demo_cap_reached}
      {:error, {:limit, :source_budget, _language}} -> {:permanent, :source_budget}
      {:error, {:limit, :email_domain_budget, _language}} -> {:permanent, :email_domain_budget}
      {:error, _invalid_field} -> {:permanent, :invalid_tenant}
    end
  end

  # `:accepted` is the process create that has not finished: running, or failed with a closed reason.
  defp settled(:accepted, %{status: "failed", reason: reason}), do: {:pending, reason}
  defp settled(:accepted, _running), do: {:pending, :running}
  defp settled(_created_or_existing, _answer), do: :ok

  # T-2748: the visitor's chosen slug is the host label; a row without one keeps the derived `t-<hex>` label.
  @doc "The tenant host of a sign-up row: `<slug or derived label>.<hostname domain>`."
  @spec hostname(map(), map()) :: String.t()
  def hostname(row, cfg),
    do:
      (row.slug || RealmProvisioner.label(row.tenant_id)) <> "." <> to_string(cfg.hostname_domain)

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

  @doc """
  T-2748: the visitor's own retry of one `failed` request: a retryable failure goes back to `provisioning`
  at its resumable step with a fresh attempt budget (same rules as `resume/1`); a permanent one stays.
  """
  @spec retry_failed(String.t()) :: :ok | :not_retryable | :slug_taken
  def retry_failed(tenant_id) do
    row =
      Repo.one(
        from(r in Request,
          where:
            r.tenant_id == ^tenant_id and r.state == "failed" and r.step == "provisioning_failed"
        )
      )

    # SF-13: the visitor never refills the platform's budget: `step_attempts` is NOT reset, so every run of
    # every visitor retry draws on the same `max_attempts` total; an exhausted budget is permanent for them.
    if (row && row.last_error in @retryable) and row.last_error != "attempts_exhausted" and
         row.step_attempts < Signup.config().max_attempts do
      step =
        cond do
          row.credential_sent_at -> "credential_sent"
          row.idp_realm_id -> "realm_created"
          true -> "ready_for_provisioning"
        end

      # A failed row released its slug (`signup_requests_slug_open_index`); another visitor may hold it now.
      # The update is the atomic check: the index refuses it, the newer holder is untouched (INV-8).
      try do
        Repo.update_all(from(r in Request, where: r.tenant_id == ^tenant_id),
          set: [state: "provisioning", step: step, claimed_at: nil]
        )

        :ok
      rescue
        e in Postgrex.Error ->
          case e.postgres do
            %{code: :unique_violation, constraint: "signup_requests_slug_open_index"} ->
              :slug_taken

            # the same e-mail has a newer live request: this one stays failed (one open request per e-mail)
            %{code: :unique_violation, constraint: "signup_requests_open_email_index"} ->
              :not_retryable

            _ ->
              reraise(e, __STACKTRACE__)
          end
      end
    else
      :not_retryable
    end
  end

  defp scope(query, nil), do: query
  defp scope(query, tenant_id), do: where(query, [r], r.tenant_id == ^tenant_id)
end
