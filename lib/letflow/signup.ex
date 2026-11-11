defmodule Letflow.Signup do
  @moduledoc """
  T-1579 (TA-SL2a; docs/uat/ba-decisions/T-1567.md s5, decision 0084): the public sign-up saga, part 1.

  A visitor submits company name, e-mail and language; the platform mails a single-use link; following
  the link marks the request `verified` and reserves a `tenant_id`. Nothing is created in `tenants` or
  `tenant_lifecycles` here. From `ready_for_provisioning`, T-1593 (SL2b part a) asks infra's provisioner
  for the realm and first admin and mails the one-time credential (`Letflow.Signup.Provisioning`); the
  Letflow tenant is then created in-process (T-1679, part 1a, step `tenant_created`; the welcome mail is 1b). Everything sits behind `LETFLOW_SIGNUP_ENABLED` (default off,
  see `Letflow.Routers.Signup`).

  ## Saga

  Row per request in the global table `signup_requests`, keyed by the server-generated `tenant_id`.
  Steps: `await_verification` -> `verified` -> `ready_for_provisioning`. `advance/1` runs the next step
  and is a no-op when the postcondition already holds, so a repeat or a crash resumes at the first
  unfinished step.

  ## Anti-abuse (DB-counted: no process, no scheduler job, no supervisor child)

  Everything in `submit/3` runs in one transaction under a transaction-level advisory lock, so the caps
  are race-free (sign-up is low volume): stale rows are closed first, then the per-IP hourly cap, the
  per-address resend interval and mail cap, then the pending cap. The mail goes out after commit.

  T-1620 (TA-SL3), all in `submit/3` and before any row or mail: the e-mail policy
  (`Letflow.Signup.EmailPolicy`, disposable domains), the captcha hook (`Letflow.Signup.Captcha`, off until a
  vendor is chosen, owner question Q3), and under the lock a per-e-mail-domain hourly cap next to the per-IP
  one (`domain_key` is a hash; big free providers are exempt and bounded by the IP and pending caps). The
  invitation code (Q1) is not built.

  ## Privacy

  The raw IP is never stored (`ip_key` is a hash, IPv6 aggregated to /64). The token exists only in the
  mail; `token_hash` is its SHA-256. `email` is nulled when a row is closed as expired. Nothing here logs
  an e-mail, address, token or company name (INV-4).
  """

  import Ecto.Query

  alias Letflow.Identity.TenantMembership
  alias Letflow.Repo
  alias Letflow.Signup.{Captcha, EmailPolicy, Mailer, Messages, Provisioning, Request}

  @terms_version "placeholder-0"
  @max_company 200
  @max_email 254
  @max_sends 5
  @lock_key "letflow:signup"
  @email_re ~r/^[^\s@,;<>()\[\]\\"]+@[^\s@,;<>()\[\]\\"]+\.[^\s@,;<>()\[\]\\"]+$/

  @defaults [
    enabled: false,
    base_url: nil,
    pending_cap: 50,
    ip_hourly_cap: 5,
    resend_interval_seconds: 60,
    token_ttl_hours: 24,
    abandon_days: 7,
    # T-1620 (TA-SL3): per-domain cap, disposable list, captcha hook (nil = off).
    domain_hourly_cap: 20,
    domain_cap_exempt:
      ~w(gmail.com mail.ru yandex.ru outlook.com icloud.com bk.ru inbox.ru list.ru yahoo.com),
    disposable_domains: [],
    allow_domains: [],
    captcha_adapter: nil,
    # T-1593 (decision 0085): the realm step. Unset URL/domain = the step does not run.
    provisioner_url: nil,
    hostname_domain: nil,
    retry_delays_ms: [1000, 5000],
    max_attempts: 5,
    http_timeout_ms: 10_000,
    connect_timeout_ms: 3_000
  ]

  @type submit_result ::
          :accepted
          | {:error, {:invalid, [String.t()]}}
          | {:error, :rate_limited}
          | {:error, :rate_limited_domain}
          | {:error, :email_not_accepted}
          | {:error, :captcha_failed}
          | {:error, :unavailable}

  @doc "Terms version recorded with every request (a placeholder until the owner supplies the text)."
  @spec terms_version() :: String.t()
  def terms_version, do: @terms_version

  @doc "The settings, read per request: `config :letflow, Letflow.Signup`, defaults merged in."
  @spec config() :: map()
  def config do
    @defaults |> Keyword.merge(Application.get_env(:letflow, __MODULE__, [])) |> Map.new()
  end

  @doc "True only when the platform flag is exactly `true`."
  @spec enabled?() :: boolean()
  def enabled?, do: config().enabled == true

  @doc """
  Records a sign-up request (or re-sends the mail for an open one). `params` is the decoded JSON body;
  `client_ip` the resolved client address. Field errors depend only on the request; every well-formed
  request is `:accepted` whatever the state of the address (no probing).
  """
  @spec submit(map(), :inet.ip_address(), DateTime.t()) :: submit_result()
  def submit(params, client_ip, now \\ DateTime.utc_now()) when is_map(params) do
    cfg = config()

    with {:ok, fields} <- validate(params),
         :ok <- EmailPolicy.check(fields.email, cfg),
         :ok <- Captcha.check(cfg, params, client_ip) do
      ip_key = ip_key(client_ip)

      case transact(fn -> locked_submit(fields, ip_key, cfg, now) end) do
        {:ok, {:send, request, token}} ->
          Mailer.deliver_async(request, token)
          :accepted

        {:ok, :no_mail} ->
          :accepted

        {:ok, {:error, _} = error} ->
          error

        :conflict ->
          :accepted
      end
    end
  end

  @doc """
  Verifies a token. Idempotent within the token's lifetime. One failure for unknown, expired, closed
  and malformed tokens (INV-5).
  """
  @spec verify(term(), DateTime.t()) :: :ok | {:error, :invalid}
  def verify(token, now \\ DateTime.utc_now())

  def verify(token, now) when is_binary(token) and byte_size(token) in 20..100 do
    hash = hash_token(token)

    {:ok, result} =
      Repo.transaction(fn ->
        request =
          Repo.one(
            from(r in Request,
              where:
                r.token_hash == ^hash and
                  r.state in ["pending_verification", "verified", "provisioning"],
              lock: "FOR UPDATE"
            )
          )

        cond do
          is_nil(request) -> {:error, :invalid}
          DateTime.compare(request.token_expires_at, now) != :gt -> {:error, :invalid}
          true -> verify_row(request, now)
        end
      end)

    # T-1593: after the commit, off the request path; never changes the answer (INV-8).
    case result do
      {:ok, tenant_id} ->
        Provisioning.start_async(tenant_id)
        :ok

      other ->
        other
    end
  end

  def verify(_token, _now), do: {:error, :invalid}

  defp verify_row(%Request{state: "verified", step: "ready_for_provisioning"} = request, _now),
    do: {:ok, request.tenant_id}

  defp verify_row(%Request{state: "verified"}, _now), do: :ok
  defp verify_row(%Request{state: "provisioning"}, _now), do: :ok

  defp verify_row(%Request{state: "pending_verification"} = request, now) do
    request
    |> Ecto.Changeset.change(state: "verified", step: "verified", verified_at: now)
    |> Repo.update!()
    |> advance()
    |> then(&{:ok, &1.tenant_id})
  end

  @doc """
  Saga: runs the next step of a request and is a no-op when its postcondition holds. This function only
  covers the in-transaction steps up to `ready_for_provisioning`; the steps after it call a network
  service and run outside any transaction in `Letflow.Signup.Provisioning` (T-1593, decision 0085),
  which is idempotent in the same way (claim + postcondition per step).
  """
  @spec advance(Request.t()) :: Request.t()
  def advance(%Request{state: "verified", step: "verified"} = request) do
    request |> Ecto.Changeset.change(step: "ready_for_provisioning") |> Repo.update!()
  end

  def advance(%Request{} = request), do: request

  @doc "Closes open requests whose link expired or that are older than the abandon age. Returns the count."
  @spec expire_stale(DateTime.t()) :: non_neg_integer()
  def expire_stale(now \\ DateTime.utc_now()) do
    cfg = config()
    abandon_before = DateTime.add(now, -cfg.abandon_days * 86_400, :second)

    {count, _} =
      Repo.update_all(
        from(r in Request,
          where:
            r.state == "pending_verification" and
              (r.token_expires_at <= ^now or r.inserted_at <= ^abandon_before)
        ),
        set: [state: "expired", email: nil, token_hash: nil, updated_at: now]
      )

    count
  end

  # ── submit ──────────────────────────────────────────────────────────────

  defp transact(fun) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@lock_key])
      fun.()
    end)
  rescue
    Ecto.ConstraintError -> :conflict
  end

  defp locked_submit(fields, ip_key, cfg, now) do
    expire_stale(now)
    hour_ago = DateTime.add(now, -3600, :second)

    ip_count =
      Repo.aggregate(
        from(r in Request, where: r.ip_key == ^ip_key and r.inserted_at > ^hour_ago),
        :count
      )

    domain_key = domain_key(fields.email)

    cond do
      ip_count >= cfg.ip_hourly_cap ->
        {:error, :rate_limited}

      domain_limited?(domain_key, fields.email, cfg, hour_ago) ->
        {:error, :rate_limited_domain}

      # The cap is checked before the open-request lookup so a full cap answers every address alike
      # (an open sign-up must not be distinguishable from an unknown address, INV-5).
      Repo.aggregate(from(r in Request, where: r.state == "pending_verification"), :count) >=
          cfg.pending_cap ->
        {:error, :unavailable}

      open = open_request(fields.email) ->
        resend(open, cfg, now)

      true ->
        insert(fields, ip_key, cfg, now)
    end
  end

  defp domain_limited?(domain_key, email, cfg, hour_ago) do
    domain = EmailPolicy.domain(email)

    domain not in cfg.domain_cap_exempt and
      Repo.aggregate(
        from(r in Request, where: r.domain_key == ^domain_key and r.inserted_at > ^hour_ago),
        :count
      ) >= cfg.domain_hourly_cap
  end

  defp open_request(email) do
    Repo.one(
      from(r in Request,
        where:
          r.email == ^email and r.state in ["pending_verification", "verified", "provisioning"],
        lock: "FOR UPDATE"
      )
    )
  end

  defp resend(%Request{state: "pending_verification"} = request, cfg, now) do
    due? =
      is_nil(request.last_sent_at) or
        DateTime.diff(now, request.last_sent_at, :second) >= cfg.resend_interval_seconds

    if due? and request.send_count < @max_sends do
      {token, hash} = new_token()

      updated =
        request
        |> Ecto.Changeset.change(
          token_hash: hash,
          token_expires_at: expiry(cfg, now),
          send_count: request.send_count + 1,
          last_sent_at: now
        )
        |> Repo.update!()

      {:send, updated, token}
    else
      :no_mail
    end
  end

  defp resend(_verified_or_provisioning, _cfg, _now), do: :no_mail

  defp insert(fields, ip_key, cfg, now) do
    {token, hash} = new_token()

    request =
      Repo.insert!(%Request{
        tenant_id: Ecto.UUID.generate(),
        email: fields.email,
        company_name: fields.company_name,
        language: fields.language,
        state: "pending_verification",
        step: "await_verification",
        token_hash: hash,
        token_expires_at: expiry(cfg, now),
        send_count: 1,
        last_sent_at: now,
        ip_key: ip_key,
        domain_key: domain_key(fields.email),
        terms_version: @terms_version,
        terms_accepted_at: now
      })

    {:send, request, token}
  end

  defp expiry(cfg, now), do: DateTime.add(now, cfg.token_ttl_hours * 3600, :second)

  defp new_token do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {token, hash_token(token)}
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  @doc false
  @spec ip_key(:inet.ip_address()) :: binary()
  def ip_key(ip), do: :crypto.hash(:sha256, "letflow:signup:ip:v1:" <> ip_bucket(ip))

  @doc false
  @spec domain_key(String.t()) :: binary()
  def domain_key(email),
    do: :crypto.hash(:sha256, "letflow:signup:domain:v1:" <> to_string(EmailPolicy.domain(email)))

  defp ip_bucket({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: ip_bucket({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  defp ip_bucket({_, _, _, _} = v4), do: v4 |> :inet.ntoa() |> to_string()

  defp ip_bucket({a, b, c, d, _, _, _, _}),
    do: [a, b, c, d] |> Enum.map_join(":", &Integer.to_string(&1, 16))

  defp ip_bucket(_other), do: "unknown"

  # ── validation ──────────────────────────────────────────────────────────

  defp validate(params) do
    email = normalize_email(Map.get(params, "email"))
    company = normalize_company(Map.get(params, "company_name"))
    language = Map.get(params, "language")

    errors =
      Enum.reject(
        [
          if(is_nil(company), do: "company_name"),
          if(is_nil(email), do: "email"),
          if(language in Messages.languages(), do: nil, else: "language"),
          if(Map.get(params, "terms_accepted") == true, do: nil, else: "terms_accepted")
        ],
        &is_nil/1
      )

    case errors do
      [] -> {:ok, %{email: email, company_name: company, language: language}}
      fields -> {:error, {:invalid, fields}}
    end
  end

  defp normalize_email(email) when is_binary(email) do
    normalized = TenantMembership.normalize_subject_key(email)

    if byte_size(normalized) <= @max_email and Regex.match?(@email_re, normalized),
      do: normalized,
      else: nil
  end

  defp normalize_email(_other), do: nil

  defp normalize_company(name) when is_binary(name) do
    trimmed = String.trim(name)
    len = String.length(trimmed)

    if len in 1..@max_company//1 and String.valid?(trimmed) and
         not String.match?(trimmed, ~r/[\x00-\x1f]/),
       do: trimmed,
       else: nil
  end

  defp normalize_company(_other), do: nil
end
