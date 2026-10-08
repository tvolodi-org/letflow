defmodule Letflow.Identity.Tenant do
  @moduledoc """
  Ecto schema for the `tenants` table. Ported from R-Co
  `src/design/adp-04b-tenant-realm-binding.md` ("Data model and
  migration/backfill semantics", "Core types" `Tenant` struct, "Key
  invariants" 1-2).

  PROVENANCE (historical, not current decision authority):
  `status` distinguishes `:active` from `:migrating` from `:inactive` —
  `:migrating` is the concrete write-pause state R-Co's
  `src/api/middleware/tenant_status.zig` checks before allowing a mutating
  request through (see REQ-021); `:inactive` (REQ-075) is the broader
  deactivation state `Letflow.Plugs.TenantStatus` rejects on **every** HTTP
  method (not just writes) for any non-`PLATFORM_ADMIN` caller — see that
  module's moduledoc, and `docs/migration/stage-4-api-surface.md`'s
  2026-08-22 (REQ-075) REVIEWER sign-off entry for the exact authorized
  shape. Only `Letflow.Identity.deactivate_tenant/1` and
  `Letflow.Identity.reactivate_tenant/1` (via `status_changeset/2` below)
  ever write `:inactive`/`:active` through this path — `PATCH
  /tenants/:slug` cannot, structurally (see `admin_patch_changeset/2`'s
  @doc).

  `idp_realm_id` is nullable at the column level. adp-04b's own forward
  constraint ("non-default tenant insert requires non-empty idp_realm_id")
  is conditional on runtime OIDC-mode config, which a migration-time CHECK
  constraint cannot see — it is enforced as an application-level (changeset)
  invariant in REQ-019, not here. Its uniqueness (when present) is a
  partial unique index (`tenants_idp_realm_id_partial_index`, see the
  `CreateTenants` migration), resolving adp-04b's own Open Question OQ-2
  explicitly in favor of partial.

  This schema targets Ecto's single default schema — schema-per-tenant
  provisioning (Decision B,
  `docs/migration/decisions/0003-ecto-schema-strategy.md`) is deferred, see
  `lib/letflow/design/identity-schema.md` section 1.

  ## Changesets (REQ-019)

  `create_changeset/3` and `admin_patch_changeset/2` implement
  `lib/letflow/design/req019-tenant-realm-binding.md` §3. (ISS-0993 deleted the
  former `update_changeset/2`, which had no caller under `lib/` and cast
  `:status`; `status_changeset/2` is the only status writer.)

  **`idp_realm_id` is immutable after creation.** This is enforced
  structurally, not by a runtime rejection check: no update-type changeset's
  `cast/3` field list includes `:idp_realm_id`, so there is no field in any
  changeset's allowed inputs that could ever carry a value into it — an
  attempted change to it via `admin_patch_changeset/2` produces no change
  at all (not a validation error), because the field was never cast in the
  first place.

  **No dedicated admin-only rotation function exists in this module.** R-Co's
  own `adp-04b-tenant-realm-binding.md` leaves realm-rotation policy as its
  own unresolved open question (OQ-1: strict immutability vs. a
  dedicated admin operation); REQ-019's acceptance criteria do not ask for
  one, and no other requirement in this codebase currently needs one. So
  `idp_realm_id`, once set, has no code path anywhere in this module that can
  change or clear it again — see the design doc §3.1 for the full reasoning.

  **Narrow bind-once exception (ISS-1030).** A tenant onboarded without a realm
  has `idp_realm_id` NULL and could otherwise never be reached by a login.
  `realm_bind_changeset/2` is the ONLY changeset that casts `:idp_realm_id` on
  an existing row, and the only caller (`Letflow.Identity.bind_tenant_realm/3`)
  applies it under a row lock (`SELECT ... FOR UPDATE`), only while the column is
  still NULL and the tenant is `:active`: a realm that is set can never be changed or cleared. The
  platform operator alone reaches it (`POST /onboarding/:id/bind-realm`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Letflow.Identity.ColorContrast
  alias Letflow.Identity.TenantSettings

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenants" do
    field(:slug, :string)
    field(:display_name, :string)
    field(:status, Ecto.Enum, values: [:active, :migrating, :inactive], default: :active)
    field(:idp_realm_id, :string)
    field(:settings, TenantSettings)

    # DB-defaulted (priv/repo/migrations/20260923000001_add_storage_allowance_bytes_to_tenants.exs,
    # default 1_073_741_824), never cast in any changeset -- read_after_writes: true
    # matches this codebase's established pattern for this exact shape (see
    # PromotionAssertionRun.started_at, InstanceDefinitionSnapshot.snapshotted_at).
    # Without it, Repo.insert!/1 returns a struct with this field nil instead of the
    # real DB-assigned value (ISS pending, found via REQ-391's merge-reconciliation CI).
    field(:storage_allowance_bytes, :integer, read_after_writes: true)

    # REQ-442: per-tenant login disclosure mode (platform-security attribute).
    # NULL = use the deployment-wide mode. Cast ONLY by admin_patch_changeset/2
    # (PLATFORM_ADMIN); never in any pre-auth or tenant-admin-readable shape (INV-2).
    field(:login_disclosure_mode, :string)

    timestamps()
  end

  @login_disclosure_modes ["uniform_plus_email", "redirect_single"]

  @doc """
  The two values `login_disclosure_mode` may hold (a NULL means "use the
  deployment-wide mode"); mirrors the `tenants_login_disclosure_mode_check` CHECK.
  """
  @spec login_disclosure_modes() :: [String.t()]
  def login_disclosure_modes, do: @login_disclosure_modes

  @default_tenant_slug "bpm-default"

  @doc """
  Changeset for creating a new tenant. `oidc_mode` (`:enabled` or
  `:disabled`) is caller-resolved and passed in explicitly — this changeset
  does not read OIDC-enabled state from `Application` config itself, since no
  config key for a global OIDC-enabled/disabled toggle currently exists (see
  `lib/letflow/design/req019-tenant-realm-binding.md` §8 OQ-1). When
  `oidc_mode == :enabled` and the tenant being created is not the default
  tenant (`slug != "bpm-default"`), `idp_realm_id` is required. Otherwise it
  remains optional (nullable at the column level regardless).

  The default tenant (`slug == "bpm-default"`) is additionally pinned:
  its `idp_realm_id` must equal exactly `"bpm-default"`.
  """
  @spec create_changeset(t :: %__MODULE__{}, attrs :: map(), oidc_mode :: :enabled | :disabled) ::
          Ecto.Changeset.t()
  def create_changeset(tenant, attrs, oidc_mode) when oidc_mode in [:enabled, :disabled] do
    tenant
    |> cast(attrs, [:slug, :display_name, :status, :idp_realm_id])
    |> validate_required([:slug, :display_name])
    |> validate_default_tenant_pinning()
    |> validate_idp_realm_id_required(oidc_mode)
    |> unique_constraint(:slug)
    |> unique_constraint(:idp_realm_id, name: :tenants_idp_realm_id_partial_index)
  end

  @doc """
  Changeset for `PATCH /tenants/:slug` (REQ-075) — casts **only**
  `:display_name` and (REQ-442) `:login_disclosure_mode`, the latter validated
  against `login_disclosure_modes/0` (`nil` is allowed: reset to the deployment
  fallback). It is the only changeset that casts `:login_disclosure_mode`.
  `:status` is deliberately absent from this changeset's
  cast list (see
  `lib/letflow/design/req075-tenant-administration-routes.md` §6.4): this is
  what makes it structurally impossible for `PATCH /tenants/:slug` to ever
  flip a tenant's `:status`, so `deactivate_tenant/1`/`reactivate_tenant/1`
  (via `status_changeset/2`) remain the only two writers of that field. `:slug`
  and `:idp_realm_id` are absent for the same reason (immutability).
  """
  @spec admin_patch_changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def admin_patch_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:display_name, :login_disclosure_mode])
    |> validate_inclusion(:login_disclosure_mode, @login_disclosure_modes)
    |> check_constraint(:login_disclosure_mode, name: :tenants_login_disclosure_mode_check)
  end

  @realm_id_regex ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/
  @reserved_realm_ids ["master"]

  @doc """
  ISS-1030: the format a bindable realm id must have (1..64 ASCII letters,
  digits, `_` or `-`, starting with a letter or digit; no dot, so `.` and `..`
  can never form a path segment). Applied to the TRIMMED value.
  """
  @spec realm_id_format?(term()) :: boolean()
  def realm_id_format?(value) when is_binary(value), do: Regex.match?(@realm_id_regex, value)
  def realm_id_format?(_other), do: false

  @doc """
  ISS-1030: true for a reserved realm id (Keycloak's own administration realm,
  `master`), compared case-insensitively. Such a realm is never bindable.
  """
  @spec reserved_realm_id?(term()) :: boolean()
  def reserved_realm_id?(value) when is_binary(value),
    do: String.downcase(value) in @reserved_realm_ids

  def reserved_realm_id?(_other), do: false

  @doc """
  Changeset for the bind-once realm route (ISS-1030) -- casts **only**
  `:idp_realm_id`, validates its format and the reserved-name rule, and maps the
  partial unique index to a changeset error. It is the only changeset that casts
  `:idp_realm_id` on an existing row; the "only while NULL" rule is enforced by
  the row-locked check in `Letflow.Identity.bind_tenant_realm/3` (only while NULL
  and `:active`), not here.
  """
  @spec realm_bind_changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def realm_bind_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:idp_realm_id])
    |> validate_required([:idp_realm_id])
    |> validate_change(:idp_realm_id, fn :idp_realm_id, value ->
      cond do
        not realm_id_format?(value) -> [idp_realm_id: "has an invalid format"]
        reserved_realm_id?(value) -> [idp_realm_id: "is reserved"]
        true -> []
      end
    end)
    |> unique_constraint(:idp_realm_id, name: :tenants_idp_realm_id_partial_index)
  end

  @doc """
  Changeset for `POST /tenants/:slug/deactivate` and `POST
  /tenants/:slug/reactivate` (REQ-075) — casts **only** `:status`. Mirrors
  `admin_patch_changeset/2`'s structural-impossibility discipline in the
  other direction: this changeset cannot ever touch `:display_name`.
  """
  @spec status_changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def status_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:status])
    |> validate_required([:status])
  end

  @doc """
  Changeset for writing a tenant's `:settings` (REQ-280,
  `lib/letflow/design/req280-tenant-settings-store.md` §4) — casts **only**
  `:settings`. Mirrors `admin_patch_changeset/2`'s and `status_changeset/2`'s
  structural-impossibility discipline: `:status`, `:slug`, `:idp_realm_id`
  and `:display_name` are all structurally absent from this changeset's
  `cast/3` list, so none of them can ever be changed via this path,
  regardless of what `attrs` contains.

  No `validate_required/2` for `:settings` — a `nil` settings value ("tenant
  configured nothing yet") is a legal, expected state, and this changeset may
  also be called to clear settings back to `nil`.

  The closed top-level key vocabulary (exactly `app_name`, `logo_url`,
  `brand_colors`, `locales`, `default_locale`) is enforced by
  `Letflow.Identity.TenantSettings`, the custom `Ecto.Type` used for this
  field — an unrecognized top-level key is rejected by `cast/3` itself,
  before this function's own per-key value validation ever runs.

  Per-key value validation (design §5):

    * `app_name` — non-empty string, at most 100 characters (a conservative
      bound; no existing field in this schema states one either, so this
      picks a typical display-name-class limit rather than leaving it
      unbounded).
    * `logo_url` — an absolute `http`/`https` URL (via `URI.parse/1`), or
      `nil`.
    * `brand_colors` — a map whose only allowed key is `"primary"` (the
      current system has exactly one brand colour today, mirroring
      `mobile_tenant_config.ex`'s `@default_branding["primary_color"]` —
      see design §9 OQ-1; additional slots are new scope, not invented
      here), whose value must be a 6-digit hex color (`#RRGGBB`).
    * `locales` — a non-empty list of locale-shaped strings (light shape
      check: `~r/^[a-z]{2,3}(-[A-Z]{2})?$/`, not full BCP-47/CLDR
      validation — see design §9 OQ-3).
    * `default_locale` — a single locale-shaped string that, when `locales`
      is also present in the same write, must be a member of it.
  """
  @spec settings_changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def settings_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:settings])
    |> validate_change(:settings, &validate_settings_value/2)
  end

  defp validate_settings_value(:settings, settings) when is_map(settings) do
    []
    |> validate_app_name(settings)
    |> validate_logo_url(settings)
    |> validate_brand_colors(settings)
    |> validate_locales_and_default_locale(settings)
  end

  defp validate_settings_value(:settings, _nil_or_other), do: []

  @app_name_max_length 100

  defp validate_app_name(errors, %{"app_name" => app_name}) do
    cond do
      not is_binary(app_name) or app_name == "" ->
        [
          {:settings,
           "app_name must be a non-empty string of at most #{@app_name_max_length} characters"}
          | errors
        ]

      String.length(app_name) > @app_name_max_length ->
        [
          {:settings,
           "app_name must be a non-empty string of at most #{@app_name_max_length} characters"}
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_app_name(errors, _settings), do: errors

  defp validate_logo_url(errors, %{"logo_url" => nil}), do: errors

  defp validate_logo_url(errors, %{"logo_url" => logo_url}) do
    valid? =
      is_binary(logo_url) and
        case URI.parse(logo_url) do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            true

          _other ->
            false
        end

    if valid? do
      errors
    else
      [{:settings, "logo_url must be an absolute http(s) URL"} | errors]
    end
  end

  defp validate_logo_url(errors, _settings), do: errors

  @brand_colors_allowed_keys ~w(primary)
  @hex_color_regex ~r/^#[0-9A-Fa-f]{6}$/

  # REQ-382 §2.6 — the two `tokens.css` reference background surfaces
  # `brand_colors.primary` renders as interactive/link text against
  # (`--surface-page`/`--surface-card`). Typed once here rather than parsed
  # live from `tokens.css` (no CSS-parsing mechanism exists in this Elixir
  # codebase, and building one for two literals would be disproportionate) —
  # if `tokens.css`'s values ever change, these two literals must be updated
  # in lockstep; there is no automated check tying them together today (see
  # design doc §2.6, flagged as an open question for a future drift-detecting
  # test, out of this requirement's own scope).
  @surface_page_hex "#F8F9FA"
  @surface_card_hex "#FFFFFF"

  @doc """
  The closed `brand_colors` sub-key vocabulary (REQ-382) — exposes
  `@brand_colors_allowed_keys` so a caller (`Letflow.Routers.TenantSettings`)
  can partition a raw `brand_colors` map into recognized/rejected sub-keys
  using the exact same list `validate_brand_colors/2` itself enforces.
  """
  @spec brand_colors_allowed_keys() :: [String.t()]
  def brand_colors_allowed_keys, do: @brand_colors_allowed_keys

  defp validate_brand_colors(errors, %{"brand_colors" => brand_colors})
       when is_map(brand_colors) do
    unrecognized_key =
      brand_colors
      |> Map.keys()
      |> Enum.find(fn key -> key not in @brand_colors_allowed_keys end)

    cond do
      unrecognized_key != nil ->
        [{:settings, "unrecognized brand_colors key: #{inspect(unrecognized_key)}"} | errors]

      true ->
        Enum.reduce(brand_colors, errors, fn {key, value}, acc ->
          cond do
            not (is_binary(value) and Regex.match?(@hex_color_regex, value)) ->
              [{:settings, "brand_colors.#{key} must be a 6-digit hex color (#RRGGBB)"} | acc]

            not ColorContrast.meets_wcag_aa_normal_text?(value, @surface_page_hex) or
                not ColorContrast.meets_wcag_aa_normal_text?(value, @surface_card_hex) ->
              [{:settings, brand_colors_contrast_error(key, value)} | acc]

            true ->
              acc
          end
        end)
    end
  end

  defp validate_brand_colors(errors, %{"brand_colors" => _not_a_map}) do
    [{:settings, "brand_colors must be a map"} | errors]
  end

  defp validate_brand_colors(errors, _settings), do: errors

  # REQ-382 §2.4 — plain-language, verbatim-surfaceable error naming the
  # threshold, both computed ratios, and which reference background(s)
  # failed, so the caller isn't left guessing how close the submitted color
  # came to passing.
  defp brand_colors_contrast_error(key, value) do
    page_ratio = Float.round(ColorContrast.contrast_ratio(value, @surface_page_hex), 2)
    card_ratio = Float.round(ColorContrast.contrast_ratio(value, @surface_card_hex), 2)
    min_ratio = ColorContrast.aa_normal_text_min_ratio()

    "brand_colors.#{key} (#{value}) does not meet the WCAG AA contrast minimum " <>
      "(#{min_ratio}:1) against the page/card background; computed contrast ratio is " <>
      "#{page_ratio}:1 against #{@surface_page_hex} (page) and #{card_ratio}:1 against " <>
      "#{@surface_card_hex} (card)"
  end

  @locale_regex ~r/^[a-z]{2,3}(-[A-Z]{2})?$/

  defp validate_locales_and_default_locale(errors, settings) do
    errors
    |> validate_locales(settings)
    |> validate_default_locale(settings)
  end

  defp validate_locales(errors, %{"locales" => locales}) do
    valid? =
      is_list(locales) and locales != [] and
        Enum.all?(locales, fn locale ->
          is_binary(locale) and Regex.match?(@locale_regex, locale)
        end)

    if valid? do
      errors
    else
      [{:settings, "locales must be a non-empty list of locale codes"} | errors]
    end
  end

  defp validate_locales(errors, _settings), do: errors

  defp validate_default_locale(errors, %{"default_locale" => default_locale} = settings) do
    shape_valid? = is_binary(default_locale) and Regex.match?(@locale_regex, default_locale)

    cond do
      not shape_valid? ->
        [{:settings, "default_locale must be one of the supplied locales"} | errors]

      Map.has_key?(settings, "locales") and is_list(settings["locales"]) and
          default_locale not in settings["locales"] ->
        [{:settings, "default_locale must be one of the supplied locales"} | errors]

      true ->
        errors
    end
  end

  defp validate_default_locale(errors, _settings), do: errors

  defp validate_default_tenant_pinning(changeset) do
    if get_field(changeset, :slug) == @default_tenant_slug do
      validate_change(changeset, :idp_realm_id, fn :idp_realm_id, idp_realm_id ->
        if idp_realm_id == @default_tenant_slug do
          []
        else
          [idp_realm_id: "must equal \"#{@default_tenant_slug}\" for the default tenant"]
        end
      end)
      |> validate_required([:idp_realm_id])
    else
      changeset
    end
  end

  defp validate_idp_realm_id_required(changeset, :enabled) do
    if get_field(changeset, :slug) == @default_tenant_slug do
      changeset
    else
      validate_required(changeset, [:idp_realm_id])
    end
  end

  defp validate_idp_realm_id_required(changeset, :disabled), do: changeset
end
