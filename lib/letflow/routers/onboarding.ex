defmodule Letflow.Routers.Onboarding do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Tenant self-service onboarding sub-router (REQ-076), mounted at `/onboarding`
  directly by `Letflow.Plugs.ApiPipeline` (so full paths under `/api/v1` are
  `/api/v1/onboarding`, `/api/v1/onboarding/:id`). Ports `src/api/routes/onboarding.zig`'s
  `handleOnboarding`, `handleGetOnboarding`, `handleGetOnboardingByHostname`. See
  `lib/letflow/design/req076-identity-tokens-roles-onboarding.md` §8 for the full design.

  * POST /                (mounted path: `POST /api/v1/onboarding`)          -> `handle_create/1`
  * GET  /:id              (mounted path: `GET /api/v1/onboarding/:id`)       -> `handle_get/2`
  * GET  /?hostname=       (mounted path: `GET /api/v1/onboarding`)           -> `handle_get_by_hostname/1`
  * POST /:id/bind-realm   (mounted path: `POST /api/v1/onboarding/:id/bind-realm`) -> `handle_bind_realm/2` (ISS-1030)

  All four require `:TenantsManage` — reused, not a new permission (same
  risk class and PLATFORM_ADMIN-only intent as `Letflow.Routers.Tenants`,
  REQ-075 §1.1: creating a tenant, and reading records that disclose which
  hostnames/slugs exist platform-wide, is exactly the kind of "wrong role,
  right nobody" operation that matrix already gates this way). No
  tenant-scoped `:prefix` preamble exists on this router (unlike
  `Letflow.Routers.Identity`) — same structural reason `Letflow.Routers.Tenants`
  has none: these handlers decide which tenants exist, so there is no tenant
  context to scope by. Every handler calls
  `Letflow.Api.Authorization.evaluate_access/2` **before any `Repo` call of any
  kind** — a `Deny403` decision returns immediately.

  ## Scope rule (ISS-0993 / ISS-0994): PLATFORM scope

  `:TenantsManage` is a PLATFORM-scope permission
  (`Letflow.Api.Authorization.permission_scope/1`): it is honoured only for a
  `PLATFORM_ADMIN` whose database-resolved tenant is the configured platform
  tenant (`Letflow.PlatformTenant`, `LETFLOW_PLATFORM_TENANT_ID`; unset means
  nobody). A `PLATFORM_ADMIN` of any other tenant gets 403. Wording in this
  moduledoc that calls the permission "`PLATFORM_ADMIN`-only" is superseded by
  this rule. Enforcement is live (A2): a non-operator gets the same fixed 403 whether the path matches a route or not; the platform-tenant operator keeps the router's 404 on an unmatched path. No handler here names an existing tenant (no `authorize_target_tenant/2` call is needed): the platform gate runs before any handler.
  An unmatched sub-path of this mount answers the same 403 for a
  non-operator (design OQ-4); this router's catch-all is
  `authz_unmatched(:platform_prefix)`.

  ## One tenant-provisioning path, not two (AC8)

  `POST /onboarding`'s tenant-creation sequence is `Letflow.Identity.create_tenant/1`
  -> `Letflow.TenantOnboarding.provision_and_migrate/1` (which itself sequences
  `Letflow.TenantProvisioning.provision_tenant_schema/1` and
  `Letflow.TenantProvisioning.replay_migrations/2` — the **identical**
  two-call sequence `Letflow.Routers.Tenants`'s `POST /tenants` handler
  already uses, REQ-075 §7.1) -> `Letflow.Identity.create_onboarding/1`. This
  module does not reimplement schema creation or migration replay, and does
  not add a second orchestration — there is one tenant-provisioning path on
  this platform, not two. As of the AC9/AC10 SCOPE EXTENSION (run
  `WF02-REQ076-20260822`), `Letflow.TenantOnboarding.provision_and_migrate/1`
  is also the function the recovery entry point
  (`Letflow.TenantOnboarding.recover_provisioning/1`, AC9) calls — one place,
  not two, that ever sequences these primitives.

  ## The `:migrating` status window (AC10)

  `handle_create/1` creates the tenant row with `"status" => "migrating"`
  (`Letflow.Identity.Tenant.status`'s existing three-value `Ecto.Enum` — no
  schema/changeset change). `Letflow.TenantOnboarding.provision_and_migrate/1`
  flips it to `:active` on success. See `Letflow.TenantOnboarding`'s own
  moduledoc for the full AC10 argument, including the accepted,
  structurally-credential-less empty-schema read gap (OQ-6) — not repeated
  here.

  ## The `GET /onboarding?hostname=` PLATFORM_ADMIN gate is deliberate (AC7, INV-5)

  This route is gated identically to its two siblings (`:TenantsManage`,
  PLATFORM_ADMIN-only) — **not** a public/pre-authentication lookup, even
  though the query mechanism (a bare hostname string, not a resource id
  scoped to the caller's own tenant) might suggest otherwise. Two independent
  reasons, both confirmed by direct inspection, not assumed:

    PROVENANCE (historical, not current decision authority):
    1. The historical Zig `handleGetOnboardingByHostname` (`onboarding.zig:379-409`)
       opens with the identical `actor.role != .PLATFORM_ADMIN` gate as its two
       siblings — confirmed by direct inspection, there is no pre-authentication
       branch anywhere in that handler.
    2. The frontend's only real caller of this endpoint
       (`web/src/api/onboarding.ts`'s `getOnboardingByHostname`, from
       `OnboardingResultPage.tsx`) is reached exclusively via the
       `admin/onboarding/:onboardingId/result` route. That route requires
       authentication (`ProtectedRoute` in `web/src/components/layout/AppShell.tsx`
       checks `isAuthenticated` only) — it is **not**, by itself, restricted to
       PLATFORM_ADMIN specifically; `AppShell.tsx`'s `roles:` array on that
       route only controls sidebar link visibility, not access. The real
       enforcement of "only a PLATFORM_ADMIN can actually use this page's data"
       is this backend route's own `:TenantsManage` gate below, not anything on
       the frontend. There is no anonymous/pre-login caller of this endpoint
       anywhere in the already-written frontend contract.

  The indistinguishability guarantee AC7/INV-5 demand protects a caller who
  does **not** hold `:TenantsManage` — since `evaluate_access/2` runs before
  any `Repo` call on this route (same ordering as every handler below), a
  hostname that was never bound to any tenant and a hostname bound to a real
  *other* tenant both produce a byte-identical 403 with zero DB round trips
  either way, for any caller lacking `:TenantsManage`. What a `:TenantsManage`
  caller itself sees (200 for a bound hostname, 404 for an unbound one) is
  deliberately **not** required to be indistinguishable — that caller already
  has standing to know, exactly like `GET /onboarding/:id`'s own plain 404 for
  a nonexistent id, never claimed to be INV-5-protected either.

  ## What is deliberately NOT ported (design §8.5)

  Keycloak realm/client provisioning, initial-admin-user creation, the
  idempotency-key header + conflict-on-mismatch mechanism, and the
  background-saga `state: pending/completed/failed` polling shape are all
  absent here — none has an acceptance criterion in this requirement, and this
  module's flow is fully synchronous (a slow provisioning step blocks the HTTP
  response rather than returning 201 immediately and polling), matching
  `Letflow.Routers.Tenants`'s own synchronous `POST /tenants` orchestration.
  The `hostname`/`slug` unique-index constraints on `onboarding_registry` and
  `tenants` already give this simpler flow a comparable "can't silently
  double-create" property without the saga/idempotency-record machinery.

  ## Administrator and realm fields (ISS-1030)

  Design: `lib/letflow/design/iss1030-onboarding-administrator.md`. The request
  body is still validated against `@create_schema`, which drops every
  undeclared key, so the handler reads `conn.body_params` for the administrator
  fields (`admin_email`, `admin_username`, `admin_display_name`) and the NAMES
  of every other key, solely to echo them in the 201 body:

    * `administrator` -- `state` (`none` | `not_provisioned`), a fixed
      `message`, the sent fields in `not_provisioned`, and `next_steps`.
      Nothing is stored or acted on; a null or blank field counts as not sent.
    * `ignored_fields` -- names (never values) of every other body key, capped
      and sanitised.
    * `login` -- whether the tenant is loginable (a realm is bound) and, when
      not, the next steps.

  An optional `idp_realm_id` is trimmed, format-checked, refused when reserved,
  and verified against the configured identity provider
  (`Letflow.Oidc.RealmProbe`) before any row is written. A tenant onboarded
  without a realm is "not yet loginable" until the operator binds one with
  `POST /onboarding/:id/bind-realm` (bind-once: set only while NULL, never
  changed). Runbook: `docs/runbooks/onboarding-new-tenant-realm.md`.

  ## Response allowlist

  `onboarding_map/2` is a hand-built map with exactly the six keys named in
  its own @doc — never a `Jason.Encoder` derivation over
  `%Letflow.Identity.OnboardingRecord{}`.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Api.Validation.FieldError
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Oidc.RealmProbe
  alias Letflow.PlatformTenant
  alias Letflow.TenantOnboarding
  alias Letflow.TenantProvisioning

  authz_post "/", :TenantsManage do
    handle_create(conn)
  end

  authz_get "/:id", :TenantsManage do
    handle_get(conn, conn.params["id"])
  end

  authz_post "/:id/bind-realm", :TenantsManage do
    handle_bind_realm(conn, conn.params["id"])
  end

  authz_get "/", :TenantsManage do
    handle_get_by_hostname(conn)
  end

  authz_unmatched(:platform_prefix)

  # ── POST / (design §8.2/§8.3, AC8) ───────────────────────────────────────

  @create_schema [
    %FieldConstraint{
      name: "slug",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 3,
      max_length: 63
    },
    %FieldConstraint{
      name: "display_name",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "hostname",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    # ISS-1030: optional; trimmed and checked by validate_realm_field/1.
    %FieldConstraint{name: "idp_realm_id", required: false, type: :string, max_length: 64}
  ]

  @bind_realm_schema [
    %FieldConstraint{name: "idp_realm_id", required: true, type: :string, max_length: 64}
  ]

  @known_create_fields ["slug", "display_name", "hostname", "idp_realm_id"]
  @admin_fields ["admin_email", "admin_username", "admin_display_name"]
  @ignored_fields_max 20
  @ignored_field_name_max 64
  @echo_value_max 255

  @runbook "docs/runbooks/onboarding-new-tenant-realm.md"
  @not_loginable_next_step "Create the realm and its first administrator (#{@runbook}), " <>
                             "then bind it with POST /api/v1/onboarding/{id}/bind-realm."

  @administrator_next_steps [
    "Follow #{@runbook} to create the realm and its first administrator.",
    "Bind the realm with POST /api/v1/onboarding/{id}/bind-realm (or give idp_realm_id when onboarding).",
    "The first administrator must carry the realm role TENANT_ADMIN."
  ]

  @none_message "This tenant has no administrator. Nobody can administer it until one is set up: " <>
                  "follow #{@runbook} (create the realm and its first administrator with the " <>
                  "TENANT_ADMIN role, then bind the realm)."
  @none_other_fields_message " The other administrator details you entered were NOT used."
  @not_provisioned_message "The administrator details you entered were NOT used. The platform does " <>
                             "not create realm users from the wizard yet; follow #{@runbook}."

  defp handle_create(conn) do
    body = conn.body_params

    case Validation.validate(@create_schema, body) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(sanitize_field_errors(field_errors)))

      {:ok, %{"slug" => slug, "hostname" => hostname} = attrs} ->
        with {:ok, realm} <- validate_create_extras(body, attrs),
             :ok <- verify_realm(conn, realm) do
          create_with_realm(conn, attrs, body, slug, hostname, realm)
        else
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:halt, halted_conn} ->
            halted_conn
        end
    end
  end

  # Field errors for the optional extras, all collected before any row is written.
  defp validate_create_extras(body, attrs) do
    realm_result = validate_realm_field(Map.get(attrs, "idp_realm_id"))

    realm_errors =
      case realm_result do
        {:error, %FieldError{} = error} -> [error]
        _ok -> []
      end

    case {realm_errors ++ admin_email_errors(body), realm_result} do
      {[], {:ok, realm}} -> {:ok, realm}
      {errors, _realm_result} -> {:errors, errors}
    end
  end

  # A non-string admin_email is a 422 field error (it can never become a
  # grant); the value is never echoed.
  defp admin_email_errors(body) do
    case admin_field_sent(body, "admin_email") do
      {:sent, value} when not is_binary(value) ->
        [
          %FieldError{
            field: "admin_email",
            constraint: "type.string",
            message: "must be a string"
          }
        ]

      _absent_or_string ->
        []
    end
  end

  # Trim first and STORE the trimmed value. Never echoes the value.
  @spec validate_realm_field(term()) :: {:ok, String.t() | nil} | {:error, FieldError.t()}
  defp validate_realm_field(nil), do: {:ok, nil}

  defp validate_realm_field(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        {:error, realm_field_error("not_blank", "must not be blank")}

      not Tenant.realm_id_format?(trimmed) ->
        {:error, realm_field_error("format", "has an invalid format")}

      Tenant.reserved_realm_id?(trimmed) ->
        {:error, realm_field_error("reserved", "is reserved")}

      true ->
        {:ok, trimmed}
    end
  end

  # A non-string value was already refused by the schema's type check.
  defp validate_realm_field(_other), do: {:ok, nil}

  defp realm_field_error(constraint, message),
    do: %FieldError{field: "idp_realm_id", constraint: constraint, message: message}

  # The schema's own type/length errors would echo the received value; the
  # realm id is never echoed.
  defp sanitize_field_errors(field_errors) do
    Enum.map(field_errors, fn
      %FieldError{field: "idp_realm_id"} = error -> %{error | received: nil}
      error -> error
    end)
  end

  # Existence check against the configured identity provider. A nil realm is
  # allowed (the tenant is created "not yet loginable").
  defp verify_realm(_conn, nil), do: :ok

  defp verify_realm(conn, realm) do
    case RealmProbe.verify(realm) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:errors, [realm_field_error("not_found", "realm not found")]}

      {:error, :unreachable} ->
        {:halt,
         conn
         |> put_resp_header("retry-after", "5")
         |> Response.service_unavailable("identity provider could not be reached")}
    end
  end

  defp create_with_realm(conn, attrs, body, slug, hostname, realm) do
    create_attrs =
      attrs
      |> Map.take(["slug", "display_name"])
      |> Map.put("status", "migrating")
      |> put_realm(realm)

    case Identity.create_tenant(create_attrs) do
      {:error, :duplicate_slug} ->
        Response.conflict(conn, "slug already exists")

      {:error, %Ecto.Changeset{} = changeset} ->
        if realm_unique_conflict?(changeset) do
          Response.conflict(conn, "realm already bound")
        else
          Response.unprocessable(conn, "validation failed")
        end

      {:ok, tenant} ->
        provision_and_bind(conn, tenant, slug, hostname, body)
    end
  end

  defp put_realm(attrs, nil), do: attrs
  defp put_realm(attrs, realm), do: Map.put(attrs, "idp_realm_id", realm)

  defp realm_unique_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:idp_realm_id, {_message, keyword}} -> Keyword.get(keyword, :constraint) == :unique
      _other -> false
    end)
  end

  # Routes through Letflow.TenantOnboarding.provision_and_migrate/1 (AC8/AC9's
  # "one tenant-provisioning path, not two") -- the same function the
  # recovery entry point (Letflow.TenantOnboarding.recover_provisioning/1)
  # calls, rather than this handler sequencing
  # Letflow.TenantProvisioning.provision_tenant_schema/1 and
  # Letflow.TenantProvisioning.replay_migrations/2 itself. Same external
  # behavior as before this extension: both failure tags below still fall
  # into the same internal_error catch-all. No compensating rollback on a
  # provisioning/replay failure -- see Letflow.TenantProvisioning's moduledoc
  # "No reconciliation path for a half-provisioned tenant" section. Adding a
  # rollback here would orphan a real Postgres schema; not attempted.
  defp provision_and_bind(conn, tenant, slug, hostname, body) do
    with {:ok, _registration} <- TenantOnboarding.provision_and_migrate(tenant.id),
         {:ok, record} <-
           Identity.create_onboarding(%{tenant_id: tenant.id, slug: slug, hostname: hostname}),
         {:ok, login_state} <- Identity.get_onboarding_login_state(record.tenant_id) do
      created_body =
        record
        |> onboarding_map(login_state)
        |> Map.put("administrator", administrator_map(body))
        |> Map.put("ignored_fields", ignored_fields(body))

      Response.created(conn, created_body)
    else
      {:error, :duplicate_hostname} -> Response.conflict(conn, "hostname already bound")
      {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
      {:error, {:provisioning_failed, _reason}} -> Response.internal_error(conn)
      {:error, {:migration_failed, _exception}} -> Response.internal_error(conn)
      _provisioning_or_replay_error -> Response.internal_error(conn)
    end
  end

  # ── Administrator echo and ignored fields (design §3.4) ──────────────────

  # ONE "sent" rule for all three admin fields: JSON null or a string that is
  # empty after trim counts as NOT sent.
  @spec admin_field_sent(map(), String.t()) :: {:sent, term()} | :not_sent
  defp admin_field_sent(body, field) do
    case Map.get(body, field) do
      nil ->
        :not_sent

      value when is_binary(value) ->
        if String.trim(value) == "", do: :not_sent, else: {:sent, value}

      value ->
        {:sent, value}
    end
  end

  defp administrator_map(body) do
    sent =
      Enum.flat_map(@admin_fields, fn field ->
        case admin_field_sent(body, field) do
          {:sent, value} -> [{field, value}]
          :not_sent -> []
        end
      end)

    email_sent? = Enum.any?(sent, fn {field, _value} -> field == "admin_email" end)

    {state, message} =
      cond do
        email_sent? -> {"not_provisioned", @not_provisioned_message}
        sent == [] -> {"none", @none_message}
        true -> {"none", @none_message <> @none_other_fields_message}
      end

    %{
      "state" => state,
      "message" => message,
      "not_provisioned" => Enum.map(sent, &echo_field/1),
      "next_steps" => @administrator_next_steps
    }
  end

  # The value is echoed only when it is a string of at most 255 characters; the
  # operator's own input goes back to the same operator and is never logged.
  defp echo_field({field, value}) when is_binary(value) do
    if String.length(value) <= @echo_value_max,
      do: %{"field" => field, "value" => value},
      else: %{"field" => field}
  end

  defp echo_field({field, _non_string}), do: %{"field" => field}

  defp ignored_fields(body) do
    names =
      body
      |> Map.keys()
      |> Enum.reject(&(&1 in @known_create_fields or &1 in @admin_fields))
      |> Enum.map(&sanitize_field_name/1)
      |> Enum.uniq()
      |> Enum.sort()

    if length(names) > @ignored_fields_max,
      do: Enum.take(names, @ignored_fields_max) ++ ["..."],
      else: names
  end

  # Control characters (U+0000-U+001F, U+007F) stripped, then truncated.
  defp sanitize_field_name(name) do
    name
    |> to_string()
    |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
    |> String.slice(0, @ignored_field_name_max)
  end

  # ── POST /:id/bind-realm (design §3.2) ───────────────────────────────────
  #
  # Bind-once: sets idp_realm_id only while it is NULL and the tenant is
  # :active. Plain 404 for an unknown onboarding id (same as GET /:id).

  defp handle_bind_realm(conn, id) do
    with {:ok, uuid} <- cast_uuid(id),
         {:ok, record} <- Identity.get_onboarding(uuid) do
      bind_realm(conn, record)
    else
      _unknown_or_malformed_id -> Response.not_found(conn)
    end
  end

  defp cast_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_other), do: :error

  defp bind_realm(conn, %OnboardingRecord{} = record) do
    case Validation.validate(@bind_realm_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(sanitize_field_errors(field_errors)))

      {:ok, attrs} ->
        with {:ok, realm} <- bind_realm_value(attrs),
             {:ok, platform_prefix} <- verified_platform_prefix(conn),
             :ok <- verify_realm(conn, realm) do
          perform_bind(conn, record, realm, platform_prefix)
        else
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:halt, halted_conn} ->
            halted_conn

          :platform_prefix_mismatch ->
            Logger.error("operator realm bind refused: platform prefix check failed")
            Response.internal_error(conn)
        end
    end
  end

  defp bind_realm_value(attrs) do
    case validate_realm_field(Map.get(attrs, "idp_realm_id")) do
      {:ok, realm} when is_binary(realm) -> {:ok, realm}
      {:ok, nil} -> {:errors, [realm_field_error("required", "field is required")]}
      {:error, %FieldError{} = error} -> {:errors, [error]}
    end
  end

  # Design section 7a: the platform prefix comes from ONE accessor and must
  # equal the schema of the caller's database-resolved tenant. A mismatch or an
  # unconfigured platform tenant fails closed (fixed 500, nothing written).
  defp verified_platform_prefix(conn) do
    with {:ok, platform_prefix} <- PlatformTenant.platform_prefix(),
         {:ok, caller_prefix} <-
           TenantProvisioning.schema_name_for_tenant(conn.assigns.auth_context.tenant_id),
         true <- platform_prefix == caller_prefix do
      {:ok, platform_prefix}
    else
      _error_or_mismatch -> :platform_prefix_mismatch
    end
  end

  defp perform_bind(conn, record, realm, platform_prefix) do
    opts = [
      actor_id: conn.assigns.auth_context.user_id,
      platform_prefix: platform_prefix,
      trace_id: conn.assigns[:trace_id]
    ]

    case Identity.bind_tenant_realm(record.tenant_id, realm, opts) do
      {:ok, _tenant} -> respond_with_record(conn, record)
      {:error, :not_found} -> Response.not_found(conn)
      {:error, :realm_already_bound} -> Response.conflict(conn, "realm already bound")
      {:error, :duplicate_realm} -> Response.conflict(conn, "realm already bound")
      {:error, :tenant_not_active} -> Response.conflict(conn, "tenant is not active")
      {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
      {:error, :audit_failed} -> Response.internal_error(conn)
    end
  end

  # ── GET /:id (design §8.3) ───────────────────────────────────────────────
  #
  # Plain 404 -- this route is authenticated/PLATFORM_ADMIN, not the
  # anti-enumeration one (see moduledoc's "GET /onboarding?hostname= ... is
  # deliberate" section for why the hostname route differs).

  defp handle_get(conn, id) do
    case Identity.get_onboarding(id) do
      {:ok, record} -> respond_with_record(conn, record)
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # ── GET /?hostname= (design §8.3/§8.4, AC7, INV-5) ───────────────────────

  defp handle_get_by_hostname(conn) do
    conn = fetch_query_params(conn)

    case Map.get(conn.query_params, "hostname") do
      hostname when is_binary(hostname) and hostname != "" ->
        case Identity.get_onboarding_by_hostname(hostname) do
          {:ok, record} -> respond_with_record(conn, record)
          {:error, :not_found} -> Response.not_found(conn)
        end

      _missing_or_empty ->
        Response.bad_request(conn, "hostname query parameter is required")
    end
  end

  # 200 with the onboarding map (plus its `login` key) for a record whose
  # tenant still exists.
  defp respond_with_record(conn, %OnboardingRecord{} = record) do
    case Identity.get_onboarding_login_state(record.tenant_id) do
      {:ok, login_state} -> Response.ok(conn, onboarding_map(record, login_state))
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # ── Response allowlist ────────────────────────────────────────────────────

  @doc false
  # Exactly 6 keys, hand-built -- never a Jason.Encoder derivation over the
  # full %OnboardingRecord{} struct. `login` (ISS-1030) is the only key beyond
  # the original five.
  @spec onboarding_map(OnboardingRecord.t(), %{idp_realm_id: String.t() | nil}) :: map()
  defp onboarding_map(%OnboardingRecord{} = record, %{idp_realm_id: realm}) do
    %{
      "id" => record.id,
      "tenant_id" => record.tenant_id,
      "slug" => record.slug,
      "hostname" => record.hostname,
      "created_at" => iso8601(record.inserted_at),
      "login" => login_map(realm)
    }
  end

  defp login_map(realm) when is_binary(realm) do
    %{
      "loginable" => true,
      "status" => "realm_bound",
      "idp_realm_id" => realm,
      "next_steps" => []
    }
  end

  defp login_map(nil) do
    %{
      "loginable" => false,
      "status" => "not_yet_loginable",
      "idp_realm_id" => nil,
      "next_steps" => [@not_loginable_next_step]
    }
  end

  # Matches Letflow.Routers.Identity's own user_map/1 convention exactly (ISO
  # 8601 via DateTime.to_iso8601/1 over the NaiveDateTime-as-UTC assumption
  # already established elsewhere in this codebase).
  defp iso8601(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
