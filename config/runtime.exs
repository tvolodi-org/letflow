import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# REQ-190 (docs/migration/decisions/0016-secrets-storage-backend.md §B,
# lib/letflow/design/req190-secrets-core.md §2): the envelope-encryption
# master key for Letflow.Secrets. Read here (NOT nested inside the
# `if config_env() == :prod do` block below) because 0016 §B requires
# startup to fail in EVERY environment, including CI/test — this repo's
# test setup (config/test.exs / test/test_helper.exs) must inject a real
# (test-only) 64-hex-char value; this block must never be weakened to make
# tests pass.
#
# Validation, in order (0016 §B, exact):
#   1. absent (nil) -> raise
#   2. not exactly 64 lowercase-hex characters -> raise
#   3. Base.decode16(value, case: :lower) must yield exactly 32 bytes
#      (implied by check 2, asserted explicitly per "no speculation")
#   4. the decoded 32 bytes must not be all-zeros or all-0xFF (rejected by
#      literal byte comparison, not the hex string, so it cannot be
#      bypassed by re-encoding) -> raise
#
# No default value of any kind exists anywhere in this file, in
# .env.example, or in any other committed config — absence is always a
# boot-time failure, never a silent fallback.
secrets_master_key_hex = System.get_env("LETFLOW_SECRETS_MASTER_KEY")

secrets_master_key_hex ||
  raise """
  environment variable LETFLOW_SECRETS_MASTER_KEY is missing.
  Required in every environment (including test/CI) -- Letflow.Secrets
  (REQ-190) never falls back to a default master key.
  Generate one with: openssl rand -hex 32
  """

unless byte_size(secrets_master_key_hex) == 64 and
         String.match?(secrets_master_key_hex, ~r/^[0-9a-f]{64}$/) do
  raise """
  environment variable LETFLOW_SECRETS_MASTER_KEY is malformed: it must be
  exactly 64 lowercase hexadecimal characters (32 bytes, hex-encoded).
  Generate one with: openssl rand -hex 32
  """
end

secrets_master_key =
  case Base.decode16(secrets_master_key_hex, case: :lower) do
    {:ok, <<_::binary-size(32)>> = decoded} ->
      decoded

    _ ->
      raise """
      environment variable LETFLOW_SECRETS_MASTER_KEY did not decode to
      exactly 32 bytes despite passing the 64-hex-character format check.
      This should be unreachable -- treat it as a real defect, not a config
      typo, if it fires.
      """
  end

if secrets_master_key == <<0::256>> or secrets_master_key == :binary.copy(<<0xFF>>, 32) do
  raise """
  environment variable LETFLOW_SECRETS_MASTER_KEY is a trivially-guessable
  value (all-zeros or all-0xFF). This is exactly the hardcoded-key failure
  mode docs/migration/decisions/0016-secrets-storage-backend.md exists to
  close off -- generate a real random key with: openssl rand -hex 32
  """
end

config :letflow, :secrets_master_key, secrets_master_key

# REQ-435 (design lib/letflow/design/req434-email-first-login-directory.md §2.2,
# decisions 0042 and 0043 D-C): the keyed-HMAC pepper(s) for the platform
# tenant-login directory (Letflow.LoginDirectory). Same startup discipline as the
# master key above -- read ONCE here, required in every environment
# (config/test.exs injects test-only values), never defaulted. Four variables:
#   LETFLOW_LOGIN_DIRECTORY_PEPPER / _ID                  (required: current pair)
#   LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS / _PREVIOUS_ID (both or neither: rotation)
# An empty or all-whitespace value counts as unset (D19). No message below ever
# echoes a value (INV-4). generate a pepper with: openssl rand -hex 32
ld_get = fn name ->
  case System.get_env(name) do
    nil -> nil
    value -> if String.trim(value) == "", do: nil, else: value
  end
end

ld_pepper = fn name ->
  hex =
    ld_get.(name) ||
      raise """
      environment variable #{name} is missing.
      Required for the login directory (REQ-435); there is no default.
      Generate a pepper with: openssl rand -hex 32
      """

  unless String.match?(hex, ~r/\A[0-9a-f]{64}\z/) do
    raise """
    environment variable #{name} is malformed: it must be exactly 64 lowercase
    hexadecimal characters (32 bytes, hex-encoded).
    Generate a pepper with: openssl rand -hex 32
    """
  end

  pepper = Base.decode16!(hex, case: :lower)

  if pepper == <<0::256>> or pepper == :binary.copy(<<0xFF>>, 32) do
    raise """
    environment variable #{name} is a trivially-guessable value (all-zeros or
    all-0xFF). Generate a real random value with: openssl rand -hex 32
    """
  end

  if pepper == secrets_master_key do
    raise """
    environment variable #{name} must be a distinct secret: it equals
    LETFLOW_SECRETS_MASTER_KEY. Generate a separate value with: openssl rand -hex 32
    """
  end

  pepper
end

ld_id = fn name ->
  id =
    ld_get.(name) ||
      raise """
      environment variable #{name} is missing.
      Required for the login directory (REQ-435); there is no default.
      """

  unless String.match?(id, ~r/\A[a-z0-9_-]{1,32}\z/) do
    raise """
    environment variable #{name} is malformed: it must be 1 to 32 characters
    from [a-z0-9_-].
    """
  end

  id
end

ld_current = %{
  pepper: ld_pepper.("LETFLOW_LOGIN_DIRECTORY_PEPPER"),
  id: ld_id.("LETFLOW_LOGIN_DIRECTORY_PEPPER_ID")
}

ld_previous_set? = {
  ld_get.("LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS") != nil,
  ld_get.("LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID") != nil
}

ld_previous =
  case ld_previous_set? do
    {false, false} ->
      nil

    {true, true} ->
      previous = %{
        pepper: ld_pepper.("LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS"),
        id: ld_id.("LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID")
      }

      if previous.pepper == ld_current.pepper do
        raise """
        environment variable LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS must differ
        from LETFLOW_LOGIN_DIRECTORY_PEPPER.
        """
      end

      if previous.id == ld_current.id do
        raise """
        environment variable LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID must differ
        from LETFLOW_LOGIN_DIRECTORY_PEPPER_ID (a key id must never be reused).
        """
      end

      previous

    _one_of_two ->
      raise """
      LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS and
      LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID must be set together or not at
      all (a rotation needs both the previous pepper and its id).
      """
  end

config :letflow, :login_directory_keys, current: ld_current, previous: ld_previous

# REQ-193: structured log level. Defaults to :info when LOG_LEVEL is absent in dev/prod,
# :debug in test (so capture_log([level: :debug]) can capture debug messages -- runtime.exs
# runs after all compile-time config and would otherwise override the default :debug level
# that ExUnit.CaptureLog relies on).
# Unrecognised values are fatal at startup (mirrors the LETFLOW_SECRETS_MASTER_KEY
# "boot-time failure via raise" pattern).
log_level_atom =
  case System.get_env("LOG_LEVEL", if(config_env() == :test, do: "debug", else: "info")) do
    "debug" ->
      :debug

    "info" ->
      :info

    "warn" ->
      :warning

    "warning" ->
      :warning

    "error" ->
      :error

    invalid ->
      raise "Invalid LOG_LEVEL=#{inspect(invalid)}. Must be one of: debug, info, warn, warning, error."
  end

config :logger, level: log_level_atom

# REQ-439 (REQ-CIP; design lib/letflow/design/req439-trusted-proxy-client-ip.md s4):
# trusted-proxy client-IP list and the login-discovery mount switch. Placed
# outside the prod-only block below (the :prod boot refusal needs config_env()
# and must fire before the prod-only DATABASE_URL raise) and evaluated in EVERY
# environment. Every message here is fixed text: no env value, header value or
# CIDR entry is ever echoed (INV-4). Logger is not guaranteed started while
# config evaluates (e.g. on a release), so warnings go to standard error.
trusted_proxies =
  case Letflow.Plugs.ClientIp.parse_cidrs(System.get_env("LETFLOW_TRUSTED_PROXIES") || "") do
    {:ok, cidrs} ->
      cidrs

    {:error, :invalid_cidr} ->
      raise "environment variable LETFLOW_TRUSTED_PROXIES contains an invalid CIDR entry. " <>
              "Expected a comma-separated list of IPv4/IPv6 addresses or CIDRs (for example a/N). " <>
              "The value is not echoed."
  end

login_discovery_enabled =
  case Letflow.Plugs.ClientIp.parse_enabled(
         System.get_env("LETFLOW_LOGIN_DISCOVERY_ENABLED"),
         config_env() != :prod
       ) do
    {:ok, enabled} ->
      enabled

    {:error, :invalid_boolean} ->
      raise "environment variable LETFLOW_LOGIN_DISCOVERY_ENABLED must be exactly true or false. " <>
              "The value is not echoed."
  end

case Letflow.Plugs.ClientIp.boot_check(config_env(), login_discovery_enabled, trusted_proxies) do
  {:error, :prod_requires_trusted_proxies} ->
    raise "LETFLOW_LOGIN_DISCOVERY_ENABLED is true but LETFLOW_TRUSTED_PROXIES is empty or " <>
            "unset: refusing to boot. Without a trusted proxy list the per-IP rate-limit key " <>
            "is the proxy hop shared by every visitor. Set LETFLOW_TRUSTED_PROXIES to the " <>
            "reverse proxy's CIDR(s), or set LETFLOW_LOGIN_DISCOVERY_ENABLED=false."

  :warn_zero_prefix ->
    IO.puts(
      :stderr,
      "[warning] LETFLOW_TRUSTED_PROXIES contains a /0 CIDR: every peer of that address " <>
        "family is trusted, so X-Real-IP is spoofable. Review the list."
    )

  :warn ->
    IO.puts(
      :stderr,
      "[warning] LETFLOW_LOGIN_DISCOVERY_ENABLED is true with LETFLOW_TRUSTED_PROXIES empty: " <>
        "per-IP rate limiting keys on the proxy hop (single shared bucket). Not allowed in prod."
    )

  :ok ->
    :ok
end

config :letflow, Letflow.Plugs.ClientIp, trusted_proxies: trusted_proxies
config :letflow, Letflow.Routers.LoginDiscovery, enabled: login_discovery_enabled

# REQ-437 (design req434 s7, D21/D22): OPTIONAL LETFLOW_LOGIN_DISCOVERY_MODE. Unset,
# empty or all-whitespace writes nothing, so the config/config.exs default
# (:redirect_single) stands in every environment; a set value must be exactly
# uniform_plus_email or redirect_single, anything else stops boot WITHOUT echoing it.
# Parsed by the single parser Letflow.LoginDirectory.parse_deployment_mode/1. The key is
# Letflow.LoginDiscovery, never Letflow.Routers.LoginDiscovery (that env stays
# exactly [enabled: boolean], asserted by REQ-439's runtime-config test).
case Letflow.LoginDirectory.parse_deployment_mode(System.get_env("LETFLOW_LOGIN_DISCOVERY_MODE")) do
  {:ok, nil} ->
    :ok

  {:ok, login_discovery_mode} ->
    config :letflow, Letflow.LoginDiscovery, mode: login_discovery_mode

  {:error, :invalid_mode} ->
    raise "environment variable LETFLOW_LOGIN_DISCOVERY_MODE must be unset/blank or exactly " <>
            "uniform_plus_email or redirect_single. The value is not echoed."
end

# ISS-1030 (design iss1030-onboarding-administrator.md s4.4; decision 0048): OPTIONAL
# LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS, a comma-separated list of realm names whose
# e-mail claim may bind a pending administrator grant WITHOUT `email_verified=true`.
# Unset or empty means none (the default, OFF). It is the ONLY source of the setting: no
# database column, API, tenant setting or claim can set it. A name outside the realm
# alphabet stops boot WITHOUT echoing it (INV-4). Read at boot; restart to change.
admin_bind_unverified_realms =
  "LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS"
  |> System.get_env()
  |> Kernel.||("")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

if not Enum.all?(admin_bind_unverified_realms, &Letflow.Identity.Tenant.realm_id_format?/1) or
     Enum.any?(admin_bind_unverified_realms, &Letflow.Identity.Tenant.reserved_realm_id?/1) do
  raise "environment variable LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS must be a comma-separated " <>
          "list of realm names (letters, digits, _ and -, at most 64 characters, not master). " <>
          "The value is not echoed."
end

config :letflow, :oidc_admin_bind_unverified_realms, admin_bind_unverified_realms

# REQ-441 (design lib/letflow/design/req441-mail-notifier-adapter.md s3; decision 0045):
# the notifier mail adapter. ALL variables are OPTIONAL: LETFLOW_MAIL_ADAPTER unset or
# blank writes nothing (the config/config.exs Noop default, or the config/test.exs double,
# stands); `noop` keeps Noop; `smtp` selects Letflow.LoginDiscovery.Notifier.Smtp and then
# requires LETFLOW_SMTP_HOST/PORT/USERNAME/PASSWORD, LETFLOW_MAIL_FROM and
# LETFLOW_PUBLIC_BASE_URL (optional: LETFLOW_SMTP_TLS, LETFLOW_MAIL_TIMEOUT_MS). INV-4: the
# username and password are passed to the parser ONLY as presence markers and are never
# written to app env (the adapter reads them from the OS env at call time); every raise
# names the variable, never a value. The adapter key written is the one REQ-444 reads.
mail_secret_present? = fn name ->
  case System.get_env(name) do
    value when is_binary(value) ->
      String.trim(value) != "" and not String.contains?(value, [<<0>>, "\r", "\n"])

    _unset ->
      false
  end
end

mail_env =
  ~w(LETFLOW_MAIL_ADAPTER LETFLOW_SMTP_HOST LETFLOW_SMTP_PORT LETFLOW_SMTP_TLS
     LETFLOW_MAIL_FROM LETFLOW_PUBLIC_BASE_URL LETFLOW_MAIL_TIMEOUT_MS)
  |> Map.new(fn name -> {name, System.get_env(name)} end)
  |> Map.put("LETFLOW_SMTP_USERNAME", mail_secret_present?.("LETFLOW_SMTP_USERNAME"))
  |> Map.put("LETFLOW_SMTP_PASSWORD", mail_secret_present?.("LETFLOW_SMTP_PASSWORD"))

# `mail_adapter` is the adapter module THIS block wrote into config (nil when
# LETFLOW_MAIL_ADAPTER was unset/blank and nothing was written, in which case the
# config/config.exs default stands). Code placed after this block (REQ-444's boot gate)
# reads this variable so it sees exactly the value the block resolved.
mail_adapter =
  case Letflow.LoginDiscovery.Notifier.Smtp.Config.parse(mail_env, config_env()) do
    {:ok, :unset} ->
      nil

    {:ok, {:noop, mail_parsed}} ->
      config :letflow, Letflow.LoginDiscovery.Notifier, mail_parsed.notifier
      Keyword.fetch!(mail_parsed.notifier, :adapter)

    {:ok, {:smtp, mail_parsed}} ->
      config :letflow, Letflow.LoginDiscovery.Notifier, mail_parsed.notifier
      config :letflow, Letflow.LoginDiscovery.Notifier.Smtp, mail_parsed.smtp
      Keyword.fetch!(mail_parsed.notifier, :adapter)

    {:error, {_kind, mail_var}} ->
      raise "environment variable #{mail_var} is missing or invalid for the selected mail " <>
              "adapter; the value is not echoed. LETFLOW_MAIL_ADAPTER accepts unset/blank, " <>
              "noop or smtp; LETFLOW_SMTP_TLS accepts unset/blank, starttls, tls or none " <>
              "(none only for a loopback host and never in :prod)."
  end

# REQ-572 / GH 3252 (decision 0072 D6): the tenant provisioner credential, QA only. ALL variables are
# OPTIONAL and unset writes nothing (`/admin/v1` then answers 404). Only SHA-256 hashes are configured,
# never the credential. Every raise names the variable, never a value (INV-4). Parsed by the single
# parser Letflow.TenantProvisioner.Config.
provisioner_env =
  ~w(LETFLOW_PROVISIONER_CREDENTIAL_SHA256 LETFLOW_PROVISIONER_READONLY_CREDENTIAL_SHA256
     LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES LETFLOW_PROVISIONER_DEMO_LIFETIME_DAYS
     LETFLOW_PROVISIONER_RETENTION_DAYS LETFLOW_PROVISIONER_DEMO_CAP
     LETFLOW_PROVISIONER_DEMO_ALARM_THRESHOLD LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES
     LETFLOW_PUBLIC_BASE_URL)
  |> Map.new(fn name -> {name, System.get_env(name)} end)

case Letflow.TenantProvisioner.Config.parse(provisioner_env, config_env()) do
  {:ok, provisioner_parsed} ->
    if provisioner_parsed.auth != [] do
      config :letflow, Letflow.Plugs.ProvisionerAuth, provisioner_parsed.auth
    end

    if provisioner_parsed.provisioner != [] do
      config :letflow, Letflow.TenantProvisioner, provisioner_parsed.provisioner
    end

    if provisioner_parsed.public_base_url do
      config :letflow, :provisioner_public_base_url, provisioner_parsed.public_base_url
    end

  {:error, provisioner_var} ->
    raise "environment variable #{provisioner_var} is invalid; the value is not echoed. The " <>
            "credential variables take 64 lowercase hex characters (a SHA-256), and the write " <>
            "and read hashes must differ."
end

# ISS-0993 / ISS-0994 (design iss0993-platform-scope-separation.md section 3): OPTIONAL
# LETFLOW_PLATFORM_TENANT_ID, the tenants.id UUID of the platform tenant (not a secret,
# never echoed). Unset, empty or whitespace writes nothing (config/config.exs default
# nil: nobody has platform scope) and boot continues. Malformed stops boot WITHOUT
# echoing the value. Parsed by the single parser Letflow.PlatformTenant.parse_env/1.
case Letflow.PlatformTenant.parse_env(System.get_env("LETFLOW_PLATFORM_TENANT_ID")) do
  {:ok, nil} ->
    # A2 text (design section 3). Silent under :test, where the pin is always unset.
    if config_env() != :test do
      IO.puts(
        :stderr,
        "[warning] LETFLOW_PLATFORM_TENANT_ID is unset: platform-scope operations are denied for every caller."
      )
    end

  {:ok, platform_tenant_id} ->
    config :letflow, Letflow.PlatformTenant, tenant_id: platform_tenant_id

  {:error, :invalid_uuid} ->
    raise "environment variable LETFLOW_PLATFORM_TENANT_ID must be unset/blank or a UUID. " <>
            "The value is not echoed."
end

# REQ-444 (decision 0043 D-D, 0042 OQ-3): the email-first ENABLEMENT GATE. Placed after
# REQ-439's trusted-proxy check and REQ-441's mail block so it sees the resolved
# `login_discovery_enabled` and `mail_adapter` (nil when LETFLOW_MAIL_ADAPTER is unset).
# Outside :dev/:test, an enabled mount refuses to boot without a legal-confirmation marker
# and a delivering adapter. The marker is ADVISORY: it cannot prove a confirmation
# happened, it only makes enabling without one a deliberate, auditable act. The raised
# text is fixed and never contains the marker or adapter value (INV-4).
login_directory_legal_marker = ld_get.("LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION")

case Letflow.LoginDiscovery.BootCheck.check(
       config_env(),
       login_discovery_enabled,
       login_directory_legal_marker,
       mail_adapter
     ) do
  :ok -> :ok
  {:error, reason} -> raise Letflow.LoginDiscovery.BootCheck.message(reason)
end

# ISS-1043 (GH #2384): the git commit SHA the release was built from, reported by the
# public GET /health as `sha`. deploy/Dockerfile's runtime stage sets LETFLOW_BUILD_SHA
# from the GIT_SHA build arg that deploy/redeploy-*.sh pass. Only 7..40 lowercase hex
# characters are kept (Letflow.BuildInfo.normalize_sha/1); unset, empty or junk -> nil,
# which /health reports as null. Not fatal when absent: a local or test build has no SHA.
config :letflow, :build_sha, Letflow.BuildInfo.normalize_sha(System.get_env("LETFLOW_BUILD_SHA"))

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://letflow:PASSWORD@db/letflow_prod
      """

  # ISS-0908 (GH-2032): prior default (10) drove Letflow.Admission's derived
  # global_cap (pool_size - reserved_headroom) down to 8 on QA, rejecting
  # ordinary SPA page loads (3-5 parallel requests) with 503 "tenant at
  # capacity". Raised to 30 -- the SAME value config/dev.exs already settled
  # on for ISS-0786's identical root-cause class -- mirroring that fix, not
  # re-deriving it. POOL_SIZE remains fully operator-overridable via env var;
  # only the fallback used when it's absent changes.
  config :letflow, Letflow.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "30")

  # ISS-0908 (GH-2032): wires Letflow.Admission's reserved_headroom to a real
  # env var in prod/QA -- previously no config file ever set
  # :letflow, :admission, :reserved_headroom, so the module's own
  # @default_reserved_headroom (2) always applied with no way for an operator
  # to tune it without a redeploy. Default kept at 2, matching
  # @default_reserved_headroom exactly -- this fix targets the pool_size side
  # of the cap, not the headroom side.
  config :letflow, :admission,
    reserved_headroom: String.to_integer(System.get_env("RESERVED_HEADROOM") || "2")

  # ISS-0015 (GH#71): the port was previously hardcoded in
  # lib/letflow/application.ex, despite config/prod.exs's own comment
  # already stating runtime-dependent values (DB connection, port) belong
  # here. Fixed alongside the port-collision fix for config/test.exs.
  config :letflow, http_port: String.to_integer(System.get_env("PORT") || "4000")

  # REQ-118: allowed CORS origins for the browser-origin SPA. Fail-closed —
  # an unset or empty CORS_ALLOWED_ORIGINS yields [] (no cross-origin caller
  # trusted), never a silent fallback to Letflow.Plugs.Cors's dev/test
  # default (`localhost:5173`/`127.0.0.1:4173`), which would be a security
  # hole in a real deployment. Comma-separated exact origins, e.g.
  # "https://app.example.com,https://staging.example.com".
  config :letflow,
         :cors_allowed_origins,
         (System.get_env("CORS_ALLOWED_ORIGINS") || "") |> String.split(",", trim: true)

  # :oidc keycloak_base_url/client_id: runtime-configurable (not baked into
  # the release image at compile time) so each deployed environment can
  # point at its own Keycloak host without a rebuild —
  # signing_algs/token_verifier stay in config/prod.exs since those don't
  # vary per environment. `Config` merges keys within :oidc across files
  # (config/prod.exs then this file), so this only adds/overrides
  # :keycloak_base_url and :client_id, it doesn't replace the whole keyword
  # list.
  #
  # REQ-370 (design req370-multi-issuer-oidc-verification.md §6):
  # :oidc, :issuer is retired as the trust source -- the tenants table is
  # now the sole source of issuer trust (Letflow.Oidc.ProviderRegistry
  # resolves each realm's own issuer as "#{keycloak_base_url}/realms/#{realm}").
  # OIDC_ISSUER is kept ONLY as a one-deprecation-cycle legacy-derivation
  # fallback for keycloak_base_url, so an already-deployed environment that
  # has only ever set OIDC_ISSUER continues to resolve its bpm-default realm
  # correctly without an immediate operator action. It is never consulted to
  # decide whether a non-default realm is trusted.
  #
  # derive_base_url_from_legacy_issuer/1 below is a small pure helper (a
  # local anonymous function, not a module function -- this file is a plain
  # script, not a module) that strips a trailing "/realms/<anything>" suffix
  # off a full legacy OIDC_ISSUER URL, yielding the shared Keycloak host.
  derive_base_url_from_legacy_issuer = fn
    nil ->
      nil

    issuer when is_binary(issuer) ->
      case Regex.run(~r{\A(.*?)/realms/[^/]+\z}, issuer) do
        [_full, base_url] -> base_url
        nil -> nil
      end
  end

  config :letflow, :oidc,
    keycloak_base_url:
      System.get_env("OIDC_KEYCLOAK_BASE_URL") ||
        derive_base_url_from_legacy_issuer.(System.get_env("OIDC_ISSUER")) ||
        "https://placeholder-keycloak.invalid",
    client_id: System.get_env("OIDC_CLIENT_ID") || "letflow-placeholder-client"
end
