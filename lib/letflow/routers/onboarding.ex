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
  * GET  /:id/pending-admins (mounted path: `GET /api/v1/onboarding/:id/pending-admins`) -> `handle_list_pending_admins/2` (ISS-1030 PR 2)
  * DELETE /:id/pending-admins/:grant_id (mounted path: `DELETE /api/v1/onboarding/:id/pending-admins/:grant_id`) -> `handle_revoke_pending_admin/3` (ISS-1030 PR 2)

  All six require `:TenantsManage` — reused, not a new permission (same
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

  ## `POST /onboarding` starts a process (T-2704, pilot gap G17b)

  The route no longer creates or provisions a tenant (the old AC8/AC10 sequence
  `Identity.create_tenant/1` -> `provision_and_migrate/1` -> `create_onboarding/1`, with the
  `:migrating` status window, moved into the steps of the definition). `handle_create/1` validates
  the form, runs the pre-checks that need no write (reserved slug and hostname, taken slug,
  hostname and realm, the realm probe) and starts the active `platform.register_tenant`
  definition of the platform tenant through `Letflow.PlatformProcesses.start_register_tenant/2`,
  the ONE start function. The answer is 202 `{instance_id, status, slug}`
  (`Letflow.PlatformProcesses.RouteStart`); the steps create, provision, bind the realm and grant
  the first administrator afterwards. The `tenant.provision` step is the one place that sequences
  `TenantProvisioning.provision_tenant_schema/1` and `replay_migrations/2` for a new tenant.

  What the old route did and the process does NOT do yet (named gaps, not silent): the onboarding
  record of the hostname is not written by a step (no node reads `hostname`), and the old 201 body
  (`login`, `administrator`, `ignored_fields`) is gone with it. The sub-routes below (`bind-realm`,
  `pending-admins`, the two GETs) are unchanged.

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

  The `Idempotency-Key` header is therefore not read, and the web wizard no longer sends one
  (ISS-1091 / GH 2437). A resubmit of a slug or hostname that was already created answers 409 with
  the specific detail (for example "slug already exists") and creates nothing; it is NOT a replay of
  the original 201. The one case a replay would have covered, a retry after the 201 was lost in
  transit, is handled by looking the tenant up (`GET /onboarding?hostname=` or `GET /onboarding/:id`).

  ## Administrator and realm fields (ISS-1030)

  Design: `lib/letflow/design/iss1030-onboarding-administrator.md`. The request
  body is still validated against `@create_schema`, which drops every
  undeclared key, so the handler reads `conn.body_params` for the administrator
  fields (`admin_email`, `admin_username`, `admin_display_name`) and the NAMES
  of every other key, solely to echo them in the 201 body:

    * `administrator` -- `state` (`none` | `pending` | `not_stored`), a fixed
      `message`, the sent fields in `not_provisioned`, and `next_steps`. Only
      `admin_email` can become a grant (ISS-1030 PR 2): it is validated BEFORE
      the tenant is created (422, never echoed), stored as a pending
      `TENANT_ADMIN` grant after provisioning (`state: "pending"` with the
      `grant_id`), or reported `not_stored` when that insert failed (the tenant
      stays; 201). `admin_username` and `admin_display_name` are never acted on,
      only echoed as `not_provisioned`. A null or blank field counts as not sent.
    * `ignored_fields` -- names (never values) of every other body key, capped
      and sanitised.
    * `login` -- whether the tenant is loginable (a realm is bound) and, when
      not, the next steps.
    * `client_config`, `realm_config` are ordinary undeclared body keys (ADR 0044 Phase 1,
      REQ-468): they are named in `ignored_fields` like every other undeclared key and
      nothing else is answered for them. Values are never echoed.

  An optional `idp_realm_id` is trimmed, format-checked, refused when reserved,
  and verified against the configured identity provider
  (`Letflow.Oidc.RealmProbe`) before any row is written. A tenant onboarded
  without a realm is "not yet loginable" until the operator binds one with
  `POST /onboarding/:id/bind-realm` (bind-once: set only while NULL, never
  changed). Runbook: `docs/runbooks/onboarding-new-tenant-realm.md`.

  ## Pending administrator grants (ISS-1030 PR 2, decision 0048)

  The operator lists a tenant's grants with their AGE (`GET /:id/pending-admins`)
  and withdraws an open one (`DELETE /:id/pending-admins/:grant_id`). The tenant
  comes from the onboarding record, never from the request. There is NO route
  that creates or changes a grant other than the onboarding call itself. The
  operator's user id is written only to the platform tenant's own audit chain;
  the tenant chain never carries it.

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
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.Tenant
  alias Letflow.Oidc.RealmProbe
  alias Letflow.PlatformFunctions.Impl.TenantBindRealm
  alias Letflow.PlatformProcesses.RouteStart
  alias Letflow.PlatformTenant
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

  authz_get "/:id/pending-admins", :TenantsManage do
    handle_list_pending_admins(conn, conn.params["id"])
  end

  authz_delete "/:id/pending-admins/:grant_id", :TenantsManage do
    handle_revoke_pending_admin(conn, conn.params["id"], conn.params["grant_id"])
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

  @runbook "docs/runbooks/onboarding-new-tenant-realm.md"
  @not_loginable_next_step "Create the realm and its first administrator (#{@runbook}), " <>
                             "then bind it with POST /api/v1/onboarding/{id}/bind-realm."

  defp handle_create(conn) do
    body = conn.body_params

    case Validation.validate(@create_schema, body) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(sanitize_field_errors(field_errors)))

      {:ok, %{"slug" => slug, "hostname" => raw_hostname} = attrs} ->
        # The validator does not trim (it refuses only the empty string). Untrimmed, a padded hostname
        # would miss the duplicate pre-check and be stored trimmed, and a whitespace-only one would commit
        # the tenant and then fail the record after the commit (TEST-DESIGN-VALIDATOR B1). So it is
        # trimmed once here, and a blank result is refused before any write.
        hostname = String.trim(raw_hostname)
        attrs = Map.put(attrs, "hostname", hostname)

        with {:ok, realm, email_key} <- validate_create_extras(body, attrs),
             :ok <- hostname_present(hostname),
             :ok <- hostname_not_reserved(hostname),
             :ok <- codepoint_fit(attrs) do
          create_tenant(conn, attrs, slug, hostname, realm, email_key)
        else
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))
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

    slug_errors = slug_reserved_errors(Map.get(attrs, "slug"))

    email_result = admin_email_check(body)

    email_errors =
      case email_result do
        {:error, %FieldError{} = error} -> [error]
        _ok -> []
      end

    case {slug_errors ++ realm_errors ++ email_errors, realm_result, email_result} do
      {[], {:ok, realm}, {:ok, email_key}} -> {:ok, realm, email_key}
      {errors, _realm_result, _email_result} -> {:errors, errors}
    end
  end

  # ONE "sent" rule for the admin fields: JSON null or a string that is empty after trim counts as
  # NOT sent.
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

  # The administrator e-mail is validated and normalised BEFORE any row is written
  # (design 5.1 step 2): a non-string or malformed value is a 422 field error that
  # never echoes the value. Not sent means no grant.
  @spec admin_email_check(map()) :: {:ok, String.t() | nil} | {:error, FieldError.t()}
  defp admin_email_check(body) do
    case admin_field_sent(body, "admin_email") do
      :not_sent ->
        {:ok, nil}

      {:sent, value} when is_binary(value) ->
        case PendingAdminGrants.normalize_email(value) do
          {:ok, email_key} ->
            {:ok, email_key}

          :error ->
            {:error,
             %FieldError{
               field: "admin_email",
               constraint: "format",
               message: "must be a valid e-mail address"
             }}
        end

      {:sent, _non_string} ->
        {:error,
         %FieldError{
           field: "admin_email",
           constraint: "type.string",
           message: "must be a string"
         }}
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

  defp slug_reserved_errors(slug) do
    if Tenant.reserved_slug?(slug),
      do: [%FieldError{field: "slug", constraint: "reserved", message: "is reserved"}],
      else: []
  end

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

  # A realm bound elsewhere is refused before any row is written. The realm is NOT written
  # with the tenant: it is bound only after provisioning and the onboarding record succeed
  # (provision_and_bind/7), so a later failure such as a taken hostname cannot leave an
  # active tenant that already owns the realm (ISS-1030 SECURITY-REVIEWER F1).
  # The hostname is pre-checked as well (SECURITY-REVIEWER MAJOR-2): a taken hostname is answered 409
  # before any row is written, so the answer never leaves an active tenant behind. A hostname taken
  # between this read and the insert (a race) still leaves the tenant committed, as the runbook records.
  defp create_tenant(conn, attrs, slug, hostname, realm, email_key) do
    # A replay of an existing start is answered by the engine BEFORE any state precheck and before
    # the external realm probe: an identical retry keeps its 202 when the identity provider is down,
    # and a changed-value retry is the engine's 409.
    if RouteStart.started?(registration_form(attrs, slug, hostname, realm, email_key)) do
      start_registration(conn, attrs, slug, hostname, realm, email_key)
    else
      case verify_realm(conn, realm) do
        :ok ->
          create_new_tenant(conn, attrs, slug, hostname, realm, email_key)

        {:errors, field_errors} ->
          Response.send_problem(conn, Validation.problem(field_errors))

        {:halt, halted_conn} ->
          halted_conn
      end
    end
  end

  defp create_new_tenant(conn, attrs, slug, hostname, realm, email_key) do
    cond do
      realm_taken?(realm) ->
        Response.conflict(conn, "realm already bound")

      hostname_taken?(hostname) ->
        Response.conflict(conn, "hostname already bound")

      slug_taken?(slug) ->
        Response.conflict(conn, "slug already exists")

      true ->
        start_registration(conn, attrs, slug, hostname, realm, email_key)
    end
  end

  defp slug_taken?(slug), do: match?({:ok, _tenant}, Identity.get_tenant_by_slug(slug))

  defp realm_taken?(nil), do: false

  defp realm_taken?(realm),
    do: match?({:ok, _tenant}, Identity.resolve_tenant_by_realm(realm))

  defp hostname_taken?(hostname),
    do: match?({:ok, _record}, Identity.get_onboarding_by_hostname(hostname))

  # Postgres varchar(n) counts code points; the validator counts graphemes (String.length). A value
  # with combining marks can pass the validator and then fail the insert with a 500 after the tenant
  # is committed (SECURITY-REVIEWER BLOCKER F1). Checked here, before any write. The display name is
  # not listed: its column is `text` (migration 20261124110001) and its one rule is TenantCreate.bounded/1.
  @codepoint_max %{"slug" => 63, "hostname" => 255}

  defp codepoint_fit(attrs) do
    too_long =
      Enum.find(@codepoint_max, fn {field, max} ->
        length(String.codepoints(Map.fetch!(attrs, field))) > max
      end)

    case too_long do
      nil ->
        :ok

      {field, max} ->
        {:errors,
         [
           %FieldError{
             field: field,
             constraint: "max_length",
             message: "length must be at most #{max} characters"
           }
         ]}
    end
  end

  # A hostname that is only whitespace is refused before any write (see handle_create/1).
  defp hostname_present(""),
    do:
      {:errors,
       [%FieldError{field: "hostname", constraint: "required", message: "field is required"}]}

  defp hostname_present(_hostname), do: :ok

  defp hostname_not_reserved(hostname) do
    if Tenant.reserved_slug?(hostname |> String.split(".", parts: 2) |> hd()),
      do:
        {:errors,
         [%FieldError{field: "hostname", constraint: "reserved", message: "is reserved"}]},
      else: :ok
  end

  # T-2704 (pilot gap G17b): the route no longer creates or provisions the tenant. It starts the
  # active `platform.register_tenant` definition of the platform tenant (the ONE start function,
  # `Letflow.PlatformProcesses.start_register_tenant/2`) and answers 202 with the instance id; the
  # steps of the definition create, provision and bind. The progress page reads the instance.
  defp start_registration(conn, attrs, slug, hostname, realm, email_key) do
    RouteStart.respond(conn, registration_form(attrs, slug, hostname, realm, email_key))
  end

  defp registration_form(attrs, slug, hostname, realm, email_key) do
    %{
      slug: slug,
      name: Map.fetch!(attrs, "display_name"),
      hostname: hostname,
      realm_id: realm,
      admin_email: email_key
    }
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

    case TenantBindRealm.bind_tenant_realm(record.tenant_id, realm, opts) do
      # The response comes from the bind's own result: a read after the commit could fail
      # with the realm already bound (SECURITY-REVIEWER BLOCKER-1).
      {:ok, bound} ->
        Response.ok(conn, onboarding_map(record, %{idp_realm_id: bound.idp_realm_id}))

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :realm_already_bound} ->
        Response.conflict(conn, "realm already bound")

      {:error, :duplicate_realm} ->
        Response.conflict(conn, "realm already bound")

      {:error, :tenant_not_active} ->
        Response.conflict(conn, "tenant is not active")

      {:error, %Ecto.Changeset{}} ->
        Response.unprocessable(conn, "validation failed")

      {:error, :audit_failed} ->
        Response.internal_error(conn)
    end
  end

  # ── GET /:id/pending-admins and DELETE /:id/pending-admins/:grant_id ───────
  #
  # ISS-1030 PR 2 (design 5.2). The tenant is the onboarding record's, never a
  # request value. An unknown or malformed onboarding id or grant id is the same
  # plain 404. The operator's id is never part of a tenant-chain entry.

  defp handle_list_pending_admins(conn, id) do
    with {:ok, uuid} <- cast_uuid(id),
         {:ok, record} <- Identity.get_onboarding(uuid),
         {:ok, platform_prefix} <- verified_platform_prefix(conn) do
      list_pending_admins(conn, record, platform_prefix)
    else
      :platform_prefix_mismatch ->
        Logger.error("operator pending-admin list refused: platform prefix check failed")
        Response.internal_error(conn)

      _unknown_or_malformed_id ->
        Response.not_found(conn)
    end
  end

  defp list_pending_admins(conn, %OnboardingRecord{} = record, platform_prefix) do
    case PendingAdminGrants.registered_prefix(record.tenant_id) do
      {:ok, prefix} ->
        rows = PendingAdminGrants.list(prefix: prefix)
        creators = PendingAdminGrants.creators(Enum.map(rows, & &1.grant.id), platform_prefix)

        Response.ok(conn, %{
          "pending_admins" => Enum.map(rows, &pending_admin_map(&1, creators))
        })

      :error ->
        # Provisioning never registered a schema, so no grant can exist.
        Response.ok(conn, %{"pending_admins" => []})
    end
  rescue
    # A missing table (replay not yet done) or a database fault: fixed 500, nothing named (INV-8).
    exception ->
      Logger.error(
        "pending administrator list failed (tenant_id=#{inspect(record.tenant_id)}, " <>
          "exception=#{inspect(exception.__struct__)})"
      )

      Response.internal_error(conn)
  end

  defp pending_admin_map(%{grant: %PendingAdminGrant{} = grant} = row, creators) do
    %{
      "id" => grant.id,
      "email" => grant.email_key,
      "state" => Atom.to_string(row.state),
      "age_seconds" => row.age_seconds,
      "created_at" => iso8601(grant.inserted_at),
      "created_by_user_id" => Map.get(creators, grant.id),
      "bound_at" => iso8601(grant.consumed_at),
      "bound_user_id" => grant.consumed_by_user_id,
      "revoked_at" => iso8601(grant.revoked_at)
    }
  end

  defp handle_revoke_pending_admin(conn, id, grant_id) do
    with {:ok, uuid} <- cast_uuid(id),
         {:ok, grant_uuid} <- cast_uuid(grant_id),
         {:ok, record} <- Identity.get_onboarding(uuid),
         {:ok, platform_prefix} <- verified_platform_prefix(conn),
         {:ok, prefix} <- PendingAdminGrants.registered_prefix(record.tenant_id) do
      opts = [
        prefix: prefix,
        platform_prefix: platform_prefix,
        trace_id: conn.assigns[:trace_id]
      ]

      actor = %{user_id: conn.assigns.auth_context.user_id}

      case PendingAdminGrants.revoke(grant_uuid, actor, opts) do
        :ok -> Response.no_content(conn)
        {:error, :not_found} -> Response.not_found(conn)
        {:error, :not_open} -> Response.conflict(conn, "grant is not open")
        # REQ-497 PR 1b N1 (design 6.2 (d)): the last open grant of a 0-admin tenant.
        {:error, :last_tenant_wide_admin} -> Response.conflict(conn, "last_tenant_wide_admin")
        {:error, :audit_failed} -> Response.internal_error(conn)
      end
    else
      :platform_prefix_mismatch ->
        Logger.error("operator pending-admin revoke refused: platform prefix check failed")
        Response.internal_error(conn)

      _unknown_or_malformed_id ->
        Response.not_found(conn)
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
        # Trimmed as the create path trims it: a padded value would otherwise miss the stored, trimmed one.
        case Identity.get_onboarding_by_hostname(String.trim(hostname)) do
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
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp iso8601(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
