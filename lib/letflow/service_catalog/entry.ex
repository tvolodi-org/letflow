defmodule Letflow.ServiceCatalog.Entry do
  @moduledoc """
  Ecto schema for the `service_catalog` table. See
  `lib/letflow/design/req191-service-catalog-core.md` §2. Ordinary
  `Ecto.Schema`, no process — matches `Letflow.Dlq.Entry`'s plain-CRUD-table
  precedent.

  ## `service_id` — a caller-supplied string primary key (deliberate divergence)

  `@primary_key {:service_id, :string, autogenerate: false}` — the first
  schema in this codebase whose primary key is a caller-supplied string
  rather than a `binary_id`. Justified by SVC-01's own global-uniqueness
  rule making `service_id` the natural key: there is no separate surrogate
  id anywhere in the requirement text, R-Co's migration, or the wire
  contract. This also gives global `service_id` uniqueness across every
  tenant and both scopes for free, via the PK's own DB-level uniqueness --
  no separate unique index needed.

  ## GLOBAL table — divergence from decision 0003 Decision B

  This table lives in the default/public schema, not behind any tenant
  schema prefix (see the migration's own header comment and
  `Letflow.ServiceCatalog`'s moduledoc for the full R-Co-grounded reasoning
  and REVIEWER-sign-off flag). No `@schema_prefix` is declared, and no
  function in `Letflow.ServiceCatalog` accepts an `opts[:prefix]` — unlike
  every other S6 context module, this one's backing table has no per-tenant
  schema to scope into.

  ## `created_at`/`updated_at`, not `timestamps/1`

  Same reasoning as `Letflow.Dlq.Entry`'s own moduledoc section: the wire
  contract (`web/src/types/api.ts`'s `ServiceRecord.created_at`/`updated_at`)
  fixes these column names, which don't match `timestamps/1`'s default
  `inserted_at`/`updated_at` pair, so both fields are declared explicitly
  and stamped by `Letflow.ServiceCatalog` itself (`register/1` stamps both,
  `update_scope/2` stamps `updated_at` only) rather than relying on
  `timestamps/1`'s automatic behaviour.

  ## Changeset-level checks are advisory only

  `insert_changeset/2` and `update_scope_changeset/2` duplicate the
  migration's DB-level `CHECK` constraints (length, enum, range, scope/owner
  consistency) at the changeset level for a fast, friendly pre-flight error
  — but the DB constraint is the one REQ-191's acceptance criteria actually
  test against and is authoritative; these changeset checks never replace
  it.

  `endpoint_url` additionally gets a syntactic SSRF pre-flight (ISS-0950,
  `check_endpoint_url/1`): https scheme, no template placeholder in the
  scheme/authority, and no private/loopback/link-local IP-literal host. It is
  fast feedback only -- the INV-9 dispatch gate
  (`Letflow.Engine.ServiceTaskDispatcher`, with real DNS) stays authoritative.

  ## REQ-373 — version/status lifecycle (design
  ## `lib/letflow/design/req373-service-catalog-version-lifecycle.md` §1/§3.3)

  **Schema decision:** in-place `version`/`version_id`/`status`/
  `published_at`/`retired_at` columns on this table, representing the single
  CURRENT version, plus a new sibling table `service_catalog_versions`
  (`Letflow.ServiceCatalog.Version`) archiving every version a `publish`/
  `retire` supersedes — **not** a composite-key (`service_id` + `version`)
  versioned table. `Letflow.Engine.PinResolver.Lookup.catalog_lookup/1`
  itself takes only `service_id`, never a requested version (the one
  exception, added later by ISS-0917, is SERVICE_TASK dispatch:
  `Letflow.ServiceCatalog.resolve_pinned_version/3` fetches the pinned
  version by `version_id` or `(service_id, version)`), so composite-keying `service_catalog` would buy nothing at the one
  call site this exists to wire up, while forcing every existing bare
  `service_id`-keyed caller (this module's own five functions, the
  `SERVICE_TASK` graph-node reference, `scope_validator_lookup/1`) to gain a
  version parameter it structurally cannot supply. See
  `Letflow.ServiceCatalog`'s own moduledoc for the full reasoning.

  `status`'s Ecto representation: plain `Ecto.Enum, values: [:ACTIVE,
  :RETIRED]`, no `values:` remapping — mirrors `required_auth`'s own
  uppercase-atom convention rather than `scope`'s lowercase one, since the
  migration's DB `CHECK` constraint is `status IN ('ACTIVE', 'RETIRED')` and
  a plain `Ecto.Enum` serializes an atom to the DB verbatim by casing.
  Elixir-side code pattern-matches and constructs `:ACTIVE`/`:RETIRED`
  (uppercase) everywhere — never `:active`/`:retired`.

  **Retire-vs-fallback (AC4):** `Letflow.ServiceCatalog.retire/1` fails a
  fresh resolution outright rather than falling through to any other row —
  this schema enforces "at most one live row per `service_id`" as a
  structural invariant (there is only ever one row at all; a superseded
  version is *archived*, not kept as a second live row), so there is no
  second, still-current row to fall through to by construction. See
  `Letflow.ServiceCatalog.retire/1`'s own `@doc` for the full reasoning.

  **PLC-01/`module_ref` catalog versioning stays out of scope** — this
  schema versions `catalog_entry` (`service_catalog`) references only.
  `pin_resolver.ex`'s own "SCOPE GAP — service_catalog (S6) and PLC-01
  (unscoped) are not built" section names `module_ref` resolution against
  PLC-01 as unscoped to any stage; this requirement does not change that.

  **Reserved variable namespace (GH #2623):** `endpoint_url` may not reference the engine's
  reserved `_sys` namespace; see `check_endpoint_url_references/1`. The refusal carries
  `validation: :endpoint_url_reserved_variable`, distinct from `:endpoint_url_not_allowed`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Letflow.Definitions.ReservedReferences
  alias Letflow.Webhooks.UrlValidator

  @primary_key {:service_id, :string, autogenerate: false}
  schema "service_catalog" do
    field(:endpoint_url, :string)
    field(:request_schema, :string)
    field(:response_schema, :string)

    field(:required_auth, Ecto.Enum,
      values: [:NONE, :API_KEY, :OAUTH2, :MUTUAL_TLS],
      default: :NONE
    )

    field(:timeout_ms, :integer)
    field(:retry_policy, :string)
    field(:scope, Ecto.Enum, values: [:global, :tenant], default: :global)
    field(:owner_tenant_id, Ecto.UUID)

    # REQ-373 (design §1/§3.3) -- version identity + lifecycle status of the
    # single CURRENT version this row represents.
    field(:version, :string, default: "1")
    field(:version_id, Ecto.UUID)
    field(:status, Ecto.Enum, values: [:ACTIVE, :RETIRED], default: :ACTIVE)
    field(:published_at, :utc_datetime_usec)
    field(:retired_at, :utc_datetime_usec)

    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @castable_fields [
    :service_id,
    :endpoint_url,
    :request_schema,
    :response_schema,
    :required_auth,
    :timeout_ms,
    :retry_policy,
    :scope,
    :owner_tenant_id
  ]

  @doc """
  Changeset for `Letflow.ServiceCatalog.register/1`. `created_at`/
  `updated_at` are never castable from caller input -- always stamped by the
  context module, mirroring `process_definitions.status`'s "never castable
  from caller input" discipline for its own timestamp pair.
  """
  @spec insert_changeset(t(), map()) :: Ecto.Changeset.t()
  def insert_changeset(entry, attrs) do
    entry
    |> cast(attrs, @castable_fields)
    |> validate_required([:service_id, :endpoint_url, :required_auth, :timeout_ms, :scope])
    |> validate_length(:service_id, max: 255)
    |> validate_length(:endpoint_url, max: 2048)
    |> validate_endpoint_url()
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 3_600_000
    )
    |> unique_constraint(:service_id, name: :service_catalog_pkey)
    |> foreign_key_constraint(:owner_tenant_id)
    |> check_constraint(:owner_tenant_id,
      name: :chk_service_catalog_scope_owner_consistency,
      message: "scope/owner_tenant_id combination is invalid"
    )
  end

  @doc """
  Changeset for `Letflow.ServiceCatalog.update_scope/2` -- casts only
  `scope`/`owner_tenant_id`, per design §2.
  """
  @spec update_scope_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_scope_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:scope, :owner_tenant_id])
    |> validate_required([:scope])
    |> foreign_key_constraint(:owner_tenant_id)
    |> check_constraint(:owner_tenant_id,
      name: :chk_service_catalog_scope_owner_consistency,
      message: "scope/owner_tenant_id combination is invalid"
    )
  end

  @doc """
  Changeset for `Letflow.ServiceCatalog.publish/3` (design §3.1/§3.3) --
  replaces the row's version-specific fields wholesale with the newly
  published version's data. `version_id`/`version`/`status`/`published_at`
  are set by the caller (`ServiceCatalog.publish/3`), never derived here.
  """
  @spec publish_changeset(t(), map()) :: Ecto.Changeset.t()
  def publish_changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :version_id,
      :version,
      :status,
      :published_at,
      :retired_at,
      :endpoint_url,
      :request_schema,
      :response_schema,
      :required_auth,
      :timeout_ms,
      :retry_policy,
      :updated_at
    ])
    |> validate_required([
      :version_id,
      :version,
      :status,
      :published_at,
      :endpoint_url,
      :required_auth,
      :timeout_ms
    ])
    |> validate_length(:version, max: 255)
    |> validate_length(:endpoint_url, max: 2048)
    |> validate_endpoint_url()
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 3_600_000
    )
    |> unique_constraint(:version, name: :idx_service_catalog_versions_service_id_version)
  end

  @doc """
  Changeset for `Letflow.ServiceCatalog.retire/1` (design §3.2/§3.3) --
  stamps `status: :RETIRED` plus `retired_at`/`updated_at` (`DateTime.utc_now/0`,
  truncated to microsecond, read once here so both timestamps agree). Every
  version-specific technical field stays exactly as it was (retire freezes
  the row in place, per §2) -- no `attrs` argument, since retire never
  accepts caller-supplied field values.
  """
  @spec retire_changeset(t()) :: Ecto.Changeset.t()
  def retire_changeset(entry) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entry
    |> change(status: :RETIRED, retired_at: now, updated_at: now)
    |> validate_required([:status, :retired_at, :updated_at])
  end

  @endpoint_url_reserved_message "must not reference the reserved engine variable namespace"
  @endpoint_url_message "must be an https URL whose host is not a private, loopback or link-local address; template placeholders are allowed only after the host"

  @doc """
  Advisory, pure, no-DNS check of a catalog `endpoint_url` template (ISS-0950).

  Takes the *head* (scheme + `://` + authority, up to the first `/`, `?` or `#`
  after the first `"://"`), rejects it if it contains a template brace (a
  placeholder in scheme/userinfo/host/port could steer the request target), and
  otherwise runs `Letflow.Webhooks.UrlValidator.validate_syntactic/1` on it. The
  path/query/fragment tail is not inspected. The dispatch-time INV-9 gate
  (`UrlValidator.validate/2` with real DNS) is binding; this is fast feedback.
  """
  @spec check_endpoint_url(endpoint_url :: String.t()) ::
          :ok | {:error, :endpoint_url_not_allowed}
  def check_endpoint_url(endpoint_url) when is_binary(endpoint_url) do
    with {:ok, head} <- endpoint_head(endpoint_url),
         false <- String.contains?(head, ["{", "}"]),
         :ok <- UrlValidator.validate_syntactic(head) do
      :ok
    else
      _ -> {:error, :endpoint_url_not_allowed}
    end
  end

  @doc """
  Pure refusal of a catalog `endpoint_url` that references the reserved engine variable
  namespace (`{{variables._sys}}`, `{{variables._sys.<anything>}}`, any whitespace in the
  braces; GH #2623, invariant I-13). Uses `ReservedReferences.reserved_template_names/1`, the
  same predicate as the definition check. Independent of `check_endpoint_url/1`.
  """
  @spec check_endpoint_url_references(endpoint_url :: String.t()) ::
          :ok | {:error, :endpoint_url_reserved_variable}
  def check_endpoint_url_references(endpoint_url) do
    case ReservedReferences.reserved_template_names(endpoint_url) do
      [] -> :ok
      [_ | _] -> {:error, :endpoint_url_reserved_variable}
    end
  end

  @spec endpoint_head(String.t()) :: {:ok, String.t()} | :error
  defp endpoint_head(url) do
    case :binary.match(url, "://") do
      {pos, 3} ->
        after_sep = pos + 3
        rest = binary_part(url, after_sep, byte_size(url) - after_sep)

        case :binary.match(rest, ["/", "?", "#"]) do
          {idx, _} -> {:ok, binary_part(url, 0, after_sep + idx)}
          :nomatch -> {:ok, url}
        end

      :nomatch ->
        :error
    end
  end

  # Reads the effective value (get_field), not just the change: cast records no
  # change when a publish re-uses the stored URL, and validate_change would then
  # skip it. Skipped for nil (validate_required already errors) and when the
  # field already carries an error (e.g. length), to avoid a duplicate.
  @spec validate_endpoint_url(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_endpoint_url(changeset) do
    value = get_field(changeset, :endpoint_url)

    cond do
      is_nil(value) ->
        changeset

      Keyword.has_key?(changeset.errors, :endpoint_url) ->
        changeset

      check_endpoint_url_references(value) != :ok ->
        add_error(changeset, :endpoint_url, @endpoint_url_reserved_message,
          validation: :endpoint_url_reserved_variable
        )

      check_endpoint_url(value) == :ok ->
        changeset

      true ->
        add_error(changeset, :endpoint_url, @endpoint_url_message,
          validation: :endpoint_url_not_allowed
        )
    end
  end
end
