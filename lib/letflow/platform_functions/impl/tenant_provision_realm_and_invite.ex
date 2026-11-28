defmodule Letflow.PlatformFunctions.Impl.TenantProvisionRealmAndInvite do
  @moduledoc """
  The body of `tenant.provision_realm_and_invite` (T-3153, owner item 11 / D-195, slice G1;
  design `docs/design/provision-realm-and-invite-paths.md` rows P1..P3, A1..A3).

  The provisioner makes the tenant's identity realm and its first administrator; the
  administrator is invited by ONE mail. The step returns the realm id (output `realm_id`) and
  `tenant.bind_realm` is the next step of the process: this body binds nothing.

  ## Shared with the sign-up saga, not copied

  The HTTP client is `Letflow.Signup.RealmProvisioner` and the configuration is the sign-up's own
  (`Letflow.Signup.config/0`: `LETFLOW_SIGNUP_PROVISIONER_URL`, `_TOKEN`, `_HOSTNAME_DOMAIN`). The
  address is the allow-listed operator value, checked by the client (INV-9); no address is written
  here, and no new secret exists. The invite text is `Letflow.Signup.Messages.credential_or_hint/4`,
  the mail goes out through `Letflow.Signup.Mailer.deliver_now/1`. The sign-up FLAG is not read: it
  switches the public sign-up, not the platform's own tenant creation.

  ## The rows

    * P1 success -- the provisioner answers 201 with the one-time password; ONE mail carries it; the
      step answers `%{"realm_id" => realm}`.
    * P2 realm create fails (error, timeout, refusal) -- nothing is mailed, the step answers a code,
      the instance ends in ERROR and is retryable. The retry calls the provisioner with the SAME
      key: the request carries the tenant id (the entry's idempotency key, stable across retries),
      and the provisioner answers an existing realm as a replay.
    * P3 invite fails after the realm exists -- the mail failed after the 201. The password is gone
      (it lived in one local variable); the retry's provisioner call is a replay that creates no
      second realm, and the invite repeats as the "Forgot password" hint
      (`Messages.reset_hint/1`), exactly as the sign-up saga does.

  ## What is never stored

  The temporary password lives in one local variable from the provisioner's answer to the mail
  send: it is not in an output, the dispatch row, a log line or an error (INV-4, A1..A3). No branch
  logs the address, the realm or the hostname; every failure is a code of this module's closed set.
  A failing create shows its CAUSE class in the step log as the code: `platform_call_idp_unreachable`
  (transport, timeout, TLS, 502/503/504, 429: retryable) versus `platform_call_realm_create_failed`
  (the provisioner's own refusal); a realm that already exists is a replay and succeeds.
  Configuration absent (URL, token or hostname domain) is refused BEFORE any call:
  `platform_call_provisioner_not_configured`, nothing half-created.

  Residual: a crash between the mail and the commit of the step result repeats the invite as the
  hint mail (a second message, never a second credential).
  """

  alias Letflow.Signup
  alias Letflow.Signup.{Mailer, Messages, Provisioning, RealmProvisioner}

  # SF-01: byte caps before any per-character work. The e-mail cap is the RFC's limit in octets,
  # the slug the DNS label limit (it becomes the host label), the name a display name.
  @max_email_bytes 254
  @max_slug_bytes 63
  @max_name_bytes 200
  @slug_re ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/

  @typedoc "The stable code of a refused step."
  @type refusal ::
          :platform_call_arg_invalid
          | :platform_call_invalid_email
          | :platform_call_invalid_slug
          | :platform_call_provisioner_not_configured
          | :platform_call_realm_create_failed
          | :platform_call_idp_unreachable
          | :platform_call_invite_failed

  @doc "Runs the step over the resolved `inputs`."
  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    with {:ok, tenant_id} <- cast_uuid(Map.get(inputs, "tenant_id")),
         {:ok, email} <- check_email(Map.get(inputs, "admin_email")),
         {:ok, slug} <-
           check_slug(host_label(Map.get(inputs, "hostname"), Map.get(inputs, "slug"))),
         {:ok, name} <- check_name(Map.get(inputs, "name")),
         language = language(Map.get(inputs, "language")),
         :ok <- check_configured() do
      request = %{
        tenant_id: tenant_id,
        company_name: name,
        language: language,
        email: email,
        slug: slug
      }

      provision(request)
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp provision(request) do
    case RealmProvisioner.create_realm(request, Signup.config()) do
      {:ok, _kind, realm} -> invite(request, realm)
      {:error, :not_configured} -> {:error, :platform_call_provisioner_not_configured}
      {:error, :bad_url} -> {:error, :platform_call_provisioner_not_configured}
      {:error, code} -> {:error, classify(code)}
    end
  rescue
    _exception -> {:error, :platform_call_realm_create_failed}
  catch
    _kind, _reason -> {:error, :platform_call_realm_create_failed}
  end

  # The cause class of a failed create, as a code and never as text (no reason, no secret). The
  # client folds a transport error, a timeout, a TLS failure and a 5xx (502/503/504 of the public
  # proxy in front of the identity server) into `:unavailable`, and a 429 into `:rate_limited`: the
  # identity side is not reachable now, the step is retryable (row P2). A 4xx refusal of the
  # provisioner (401/403/400, demo cap) is its own answer and stays `realm_create_failed`; a
  # realm-exists answer (409, 200) is a REPLAY and a success, it never gets here.
  defp classify(:unavailable), do: :platform_call_idp_unreachable
  defp classify({:rate_limited, _delay}), do: :platform_call_idp_unreachable
  defp classify(_refusal), do: :platform_call_realm_create_failed

  # The password is read from `realm` for this one call and is not returned.
  defp invite(request, realm) do
    message =
      Messages.credential_or_hint(request.language, request.email, realm.username, realm.password)

    case Mailer.deliver_now(Map.put(message, :to, request.email)) do
      :ok -> {:ok, %{"realm_id" => realm.realm}}
      {:error, :failed} -> {:error, :platform_call_invite_failed}
    end
  end

  defp check_configured do
    if Provisioning.provisioner_ready?(),
      do: :ok,
      else: {:error, :platform_call_provisioner_not_configured}
  end

  # T-3154: the realm registers the tenant's HOST (the label before the hostname domain), which is the
  # visitor's chosen label on route 4 and not the `t-<hex>` slug. Without a hostname (or one that is not
  # a plain string within the byte cap) the slug is the label, as before. The result is checked by
  # `check_slug/1` like any label (byte cap first, SF-01).
  defp host_label(host, slug) when is_binary(host) and byte_size(host) in 1..253 do
    case String.split(host, ".", parts: 2) do
      [label, _rest] when label != "" -> label
      _other -> slug
    end
  end

  defp host_label(_host, slug), do: slug

  defp check_email(value) when is_binary(value) and byte_size(value) in 3..@max_email_bytes do
    if value =~ ~r/\A[^\s@]+@[^\s@]+\z/ and String.valid?(value),
      do: {:ok, value},
      else: {:error, :platform_call_invalid_email}
  end

  defp check_email(_value), do: {:error, :platform_call_invalid_email}

  defp check_slug(value) when is_binary(value) and byte_size(value) in 1..@max_slug_bytes do
    if Regex.match?(@slug_re, value),
      do: {:ok, value},
      else: {:error, :platform_call_invalid_slug}
  end

  defp check_slug(_value), do: {:error, :platform_call_invalid_slug}

  defp check_name(value) when is_binary(value) and byte_size(value) in 1..@max_name_bytes do
    if String.valid?(value), do: {:ok, value}, else: {:error, :platform_call_arg_invalid}
  end

  defp check_name(_value), do: {:error, :platform_call_arg_invalid}

  defp language(value) when is_binary(value) do
    if value in Messages.languages(), do: value, else: "en"
  end

  defp language(_value), do: "en"

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :platform_call_arg_invalid}
    end
  end

  defp cast_uuid(_value), do: {:error, :platform_call_arg_invalid}
end
