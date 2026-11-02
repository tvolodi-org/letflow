defmodule Letflow.Modules.Org do
  @moduledoc """
  Foundation module `org` (GH #2661 / REQ-473, WMS foundation slice 0; decisions 0050 D1, 0052,
  0054 option A, 0057 D1): the shared organisation masters.

  Six entity types, shipped by the pack `priv/modules/org/pack.json` (generated from
  `priv/modules/org/entity_definitions/` by `priv/modules/org/generate_pack.exs`):

    * `org_legal_entity`, `org_site`, `org_unit` (a tree through the `parent` id string): the
      masters, each with a unique `code` and the nullable `external_ref_system` /
      `external_ref_id` import key (0057 D1);
    * `org_unit_membership`: a Letflow user id (text) in an org unit, unique per pair;
    * `org_position` and `org_employee` (GH #3584 / REQ-643, version 0.2.0): a position in the
      roster of one unit, and a person with an optional `user_id` link to a Letflow account.
      Their `org_unit_id` / `position_id` are real foreign keys (decision 0066 D-066); the key
      only proves the target exists; the same-unit and active checks are in the write functions (REQ-661).

  All six are declared in `manages_entity_types`, so after install the generic entity routes
  answer 403 `entity_type_managed`. This skeleton ships no routes, no permissions, no role
  grants. Write functions exist for the legal company, the site (GH #3619 / REQ-660) and the unit (GH #3618 / REQ-495), see
  below; the unit functions are REQ-495 (below) and the read API is REQ-506. References between the four original types are declarative strings (0050 D3.6), no
  foreign keys; the two new types use real ones. Read functions `active_employee?/2` and
  `employee_for_user/2` serve the materially responsible person / actual user terms (0050
  amendment 2026-10-31). `scope_declarations` (D-067) is inert until REQ-519.

  ## Write functions (GH #3619 / REQ-660)

  `create_legal_entity/3`, `update_legal_entity/4`, `retire_legal_entity/3`, `create_site/3`,
  `update_site/4` and `retire_site/3` (logic in `Letflow.Modules.Org.Masters`). Arguments
  `(prefix, [id,] attrs, opts)`; `opts` carries `:actor_id` and `:idempotency_key`. Each runs in one
  transaction under an advisory lock keyed `<prefix>:org_legal_entity_bin`, writes through
  `Letflow.Entities.Records` with the module authority, appends one audit entry and writes nothing
  on a refusal. Rules: `bin` is exactly 12 ASCII digits (no control digit; UAT assumption to be
  confirmed), two active companies of a tenant never share a bin (`:bin_taken`), `code` is immutable,
  a site names a live company (`:legal_entity_not_found`, `:legal_entity_inactive`), a company or
  site is retired by `active` false and is refused while an active site or unit names it
  (`:legal_entity_in_use`, `:site_in_use`). No route, permission or scope declaration is added.

  ## Unit write functions (GH #3618 / REQ-495)

  `create_unit/3`, `update_unit/4`, `move_unit/4` and `retire_unit/3` (preparation in
  `Letflow.Modules.Org.Units`, transaction in `Letflow.Modules.Org.Masters`). Same arguments and
  rules as above, plus the scope tree index: one transaction takes the advisory lock, then the
  index lock, writes the record, keeps the index row (`Letflow.ScopeNodePaths.write/2`) and appends
  one audit entry (`org_unit.created|renamed|updated|moved|retired`). A move or retire that the
  index refuses (`:cycle`, `:depth_exceeded`, `:node_has_grants`) writes nothing. Limit: the
  balance guard of a retire (D-065) is not built, since no ledger module exists yet.

  ## People write functions (GH #3617 / REQ-661)

  `create_position/3`, `update_position/4`, `retire_position/3`, `create_employee/3`,
  `update_employee/4`, `transfer_employee/5` and `retire_employee/3` (preparation in
  `Letflow.Modules.Org.People`, transaction in `Letflow.Modules.Org.Masters`). An employee's unit
  and position must be active and the position must be of the employee's unit
  (`:position_not_in_unit`); `user_id` must be a user of the tenant (`:user_not_found`); a position
  held by an active employee cannot be retired (`:position_in_use`); a transfer changes unit and
  position in one record version. The audit entries of an employee omit `full_name`.

  ## Import (GH #3599 / REQ-654)

  `import_row/3` serves the core import route for `org_unit`, `org_position` and `org_employee`
  (`Letflow.Modules.Org.Import`): upsert by external reference, references by external id under
  the file's system, every write through the functions above. Legal entities and sites are not
  imported.

  ## Read API contract (GH #2662)

  `prefix` must be derived server-side from the authenticated tenant, never from HTTP input:
  isolation is by `prefix` alone, and a wrong prefix reads another tenant with no check. The
  never-raise guarantee holds for a provisioned tenant prefix; a well-formed but unprovisioned
  `tenant_<hex>` prefix raises `undefined_table` from Postgres (not caught).

  `on_install/3` activates and promotes the six packed definitions inside the install
  transaction (decision 0052 D2) through `Letflow.Modules.EntityActivation`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  import Ecto.Query, only: [from: 2, limit: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  @types [
    "org_legal_entity",
    "org_site",
    "org_unit",
    "org_unit_membership",
    "org_position",
    "org_employee"
  ]

  @membership "org_unit_membership"
  @employee "org_employee"
  @unit "org_unit"

  @impl true
  defmanifest(
    id: "org",
    version: "0.2.0",
    depends_on: [],
    pack: "modules/org/pack.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: [
      "org_legal_entity",
      "org_site",
      "org_unit",
      "org_unit_membership",
      "org_position",
      "org_employee"
    ],
    scope_declarations: %{
      "org_legal_entity" => :tenant_wide,
      "org_site" => :tenant_wide,
      "org_unit" => :tenant_wide,
      "org_position" => {:column, "org_unit_id"},
      "org_employee" => {:column, "org_unit_id"}
    },
    import_functions: [
      %{entity_type: "org_unit", function: :import_row},
      %{entity_type: "org_position", function: :import_row},
      %{entity_type: "org_employee", function: :import_row}
    ]
  )

  @doc """
  The import function of `org_unit`, `org_position` and `org_employee` (GH #3599 / REQ-654,
  manifest `:import_functions`): one row of a file, called by the core import route. See
  `Letflow.Modules.Org.Import`; it writes only through the write functions below.
  """
  @spec import_row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, map()} | {:error, term()}
  def import_row(prefix, entry, ctx), do: Letflow.Modules.Org.Import.row(prefix, entry, ctx)

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @types)
  end

  @doc "Creates a legal company (GH #3619 / REQ-660); see `Letflow.Modules.Org.Masters`."
  defdelegate create_legal_entity(prefix, attrs, opts), to: Letflow.Modules.Org.Masters

  @doc "Changes a legal company (GH #3619 / REQ-660); see `Letflow.Modules.Org.Masters`."
  defdelegate update_legal_entity(prefix, id, attrs, opts), to: Letflow.Modules.Org.Masters

  @doc "Retires a legal company, never deletes it (GH #3619 / REQ-660); see `Letflow.Modules.Org.Masters`."
  defdelegate retire_legal_entity(prefix, id, opts), to: Letflow.Modules.Org.Masters

  @doc "Creates a site of a live company (GH #3619 / REQ-660); see `Letflow.Modules.Org.Masters`."
  defdelegate create_site(prefix, attrs, opts), to: Letflow.Modules.Org.Masters

  @doc "Changes a site (GH #3619 / REQ-660); see `Letflow.Modules.Org.Masters`."
  defdelegate update_site(prefix, id, attrs, opts), to: Letflow.Modules.Org.Masters

  @doc "Retires a site, never deletes it (GH #3619 / REQ-660); see `Letflow.Modules.Org.Masters`."
  defdelegate retire_site(prefix, id, opts), to: Letflow.Modules.Org.Masters

  @doc """
  Read API (GH #2662 / REQ-506, decision 0050 D2): the live record `id` (a `record_id` uuid) in
  tenant schema `prefix`, searched across the six org types.

  The map has string keys: `"record_id"`, `"entity_type"` (the type name) and every stored field
  value. A value that is not a uuid, an unknown uuid and a soft-deleted record are all
  `{:error, :not_found}` (never a raise, never distinguishable). Read-only and tenant-scoped by
  `prefix` alone.
  """
  @spec lookup(prefix :: String.t(), id :: term()) :: {:ok, map()} | {:error, :not_found}
  def lookup(prefix, id), do: ReadApi.lookup(prefix, id, @types)

  @doc """
  True only for an existing, non-deleted record (any of the six types) whose `active` field is
  `true`. A non-uuid `id` is `false`.
  """
  @spec active?(prefix :: String.t(), id :: term()) :: boolean()
  def active?(prefix, id) do
    ReadApi.active?(prefix, id, @types)
  end

  @doc """
  True only when `user_id` has an active `org_unit_membership` in `org_unit_id` and that
  `org_unit` is itself live and active. `org_unit_id` is a record_id uuid; a non-uuid value or a
  non-text `user_id`, one with NUL or invalid UTF-8, or one over 256 bytes is `false` (no query).
  `org_unit_id` and `user_id` are matched as exact text; the canonical lowercase uuid is expected.
  """
  @spec member?(prefix :: String.t(), user_id :: term(), org_unit_id :: term()) :: boolean()
  def member?(prefix, user_id, org_unit_id)
      when is_binary(prefix) and is_binary(user_id) do
    # `unit_by_id/2` runs before the membership query and `Latest.get_live/3` validates `prefix`
    # (`tenant_id_for_schema_name/1`), so no separate prefix check is needed here.
    with true <- safe_text?(user_id),
         {:ok, unit_id} <- Ecto.UUID.cast(org_unit_id),
         {:ok, %{"active" => true}} <- unit_by_id(prefix, unit_id) do
      active_membership?(prefix, user_id, unit_id)
    else
      _ -> false
    end
  end

  def member?(_prefix, _user_id, _org_unit_id), do: false

  @doc """
  True only when `id` is the record id of a live `org_employee` whose `active` is `true`
  (GH #3584 / REQ-643). A non-uuid, an unknown or soft-deleted id, an inactive employee and a
  live active record of another org type (an `org_unit` id) are `false`.
  """
  @spec active_employee?(prefix :: String.t(), id :: term()) :: boolean()
  def active_employee?(prefix, id), do: ReadApi.active?(prefix, id, [@employee])

  @doc """
  The live `org_employee` whose `user_id` equals `user_id` exactly, active or not (the caller
  checks `active`): `{:ok, map}` in the `lookup/2` shape, else `{:error, :not_found}`. A
  `user_id` that is not text, empty, contains NUL, is invalid UTF-8 or is over 256 bytes is
  `:not_found` with no query (the `safe_text?/1` rule of `member?/3`). `user_id` is unique per
  employee, so at most one row matches.
  """
  @spec employee_for_user(prefix :: String.t(), user_id :: term()) ::
          {:ok, map()} | {:error, :not_found}
  def employee_for_user(prefix, user_id)
      when is_binary(prefix) and is_binary(user_id) and user_id != "" do
    if safe_text?(user_id) do
      query =
        from(r in Latest,
          where:
            r.entity_type == @employee and not r.deleted and
              fragment("?->>'user_id' = ?", r.field_values, ^user_id),
          limit: 1
        )

      case Repo.one(query, prefix: prefix) do
        nil -> {:error, :not_found}
        row -> ReadApi.lookup(prefix, row.record_id, [@employee])
      end
    else
      {:error, :not_found}
    end
  end

  def employee_for_user(_prefix, _user_id), do: {:error, :not_found}

  # A bound text parameter must be valid UTF-8 without NUL or Postgres raises; the 256-byte cap
  # bounds a hostile string (a Letflow user id is a uuid or short subject, far below it).
  defp safe_text?(text) do
    byte_size(text) <= 256 and String.valid?(text) and not String.contains?(text, <<0>>)
  end

  defp unit_by_id(prefix, unit_id) do
    case Latest.get_live(unit_id, @unit, prefix) do
      {:ok, row} -> {:ok, row.field_values}
      error -> error
    end
  end

  defp active_membership?(prefix, user_id, unit_id) do
    query =
      from(r in Latest,
        where:
          r.entity_type == @membership and not r.deleted and
            fragment("?->>'user_id' = ?", r.field_values, ^user_id) and
            fragment("?->>'org_unit_id' = ?", r.field_values, ^unit_id) and
            fragment("?->>'active' = 'true'", r.field_values)
      )

    Repo.exists?(limit(query, 1), prefix: prefix)
  end

  @doc "Creates an org unit and its scope tree index row (GH #3618 / REQ-495); see `Letflow.Modules.Org.Units`."
  defdelegate create_unit(prefix, attrs, opts), to: Letflow.Modules.Org.Units

  @doc "Changes an org unit (GH #3618 / REQ-495); see `Letflow.Modules.Org.Units`."
  defdelegate update_unit(prefix, id, attrs, opts), to: Letflow.Modules.Org.Units

  @doc "Moves an org unit with its subtree (GH #3618 / REQ-495); see `Letflow.Modules.Org.Units`."
  defdelegate move_unit(prefix, unit_id, new_parent_id, opts), to: Letflow.Modules.Org.Units

  @doc "Retires an org unit, never deletes it (GH #3618 / REQ-495); see `Letflow.Modules.Org.Units`."
  defdelegate retire_unit(prefix, unit_id, opts), to: Letflow.Modules.Org.Units

  @doc "Creates a position in a live unit (GH #3617 / REQ-661); see `Letflow.Modules.Org.People`."
  defdelegate create_position(prefix, attrs, opts), to: Letflow.Modules.Org.People

  @doc "Changes a position (GH #3617 / REQ-661); see `Letflow.Modules.Org.People`."
  defdelegate update_position(prefix, id, attrs, opts), to: Letflow.Modules.Org.People

  @doc "Retires a position, never deletes it (GH #3617 / REQ-661); see `Letflow.Modules.Org.People`."
  defdelegate retire_position(prefix, id, opts), to: Letflow.Modules.Org.People

  @doc "Creates an employee (GH #3617 / REQ-661); see `Letflow.Modules.Org.People`."
  defdelegate create_employee(prefix, attrs, opts), to: Letflow.Modules.Org.People

  @doc "Changes an employee (GH #3617 / REQ-661); see `Letflow.Modules.Org.People`."
  defdelegate update_employee(prefix, id, attrs, opts), to: Letflow.Modules.Org.People

  @doc "Transfers an employee to another unit and position (GH #3617 / REQ-661); see `Letflow.Modules.Org.People`."
  defdelegate transfer_employee(prefix, id, org_unit_id, position_id, opts),
    to: Letflow.Modules.Org.People

  @doc "Retires an employee, never deletes it (GH #3617 / REQ-661); see `Letflow.Modules.Org.People`."
  defdelegate retire_employee(prefix, id, opts), to: Letflow.Modules.Org.People
end
