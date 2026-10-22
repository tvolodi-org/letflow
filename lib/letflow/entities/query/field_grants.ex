defmodule Letflow.Entities.Query.FieldGrants do
  @moduledoc """
  `field_grants.zig`-equivalent (REQ-231 §3) -- a per-user, per-entity-type/
  field access-control loader that redacts specific fields from a query
  result row (not the whole row), per QRY-05. See
  `lib/letflow/design/req231-entity-query-cursor-field-grants.md` §3 for
  the full design this module implements.

  ## New tables, not an existing primitive (design §3.1)

  Field-grant redaction does not map onto any existing Letflow
  authorization/RBAC primitive. `Letflow.Api.Authorization` (REQ-069) is
  coarse, route/action-level, all-or-nothing -- its own INV-2 states there
  is no third parameter through which "which field" could reach
  `evaluate_access/2` without breaking that module's pure, two-argument
  contract. `Letflow.Secrets.Redaction` (REQ-190) is a global,
  identity-blind key-name denylist with no `user_id` concept at all. Both
  modules were read in full for this design (see the design doc's §3.1);
  neither fits. This module is backed by two new, dedicated tenant-schema
  tables instead: `entity_field_restrictions` (default-deny) and
  `user_entity_grants` (per-user override) -- design §3.2.

  ## Grant model -- default-deny-with-explicit-override (design §3.2)

  A field with no `entity_field_restrictions` row is visible to every user
  unconditionally. A restricted field's *absence* from a given user's
  `user_entity_grants` rows is exactly that user's redaction set for that
  entity type.

  ## Redaction mechanism -- sentinel value, key retained (design §3.4)

  The key stays present in the returned `field_values` map; its value is
  replaced by the atom sentinel `:__field_redacted__` -- distinct from
  `Letflow.Secrets.Redaction`'s own `"[REDACTED]"` **string** literal
  deliberately, since a JSONB-sourced `field_values` map can legitimately
  contain that literal string as real business data, whereas an atom
  sentinel cannot collide with any JSON-decoded value (JSON has no atom
  type). Omission and `nil` were both rejected (design §3.4) since either
  is ambiguous with "this record never set this field" -- a present key
  with this sentinel states "data exists, you may not see it" unambiguously.

  This module uses schemaless `Ecto.Query`s against `entity_field_restrictions`/
  `user_entity_grants` (`from(x in "table_name", ...)`) rather than
  introducing new `Ecto.Schema` modules -- design §4 names only
  `Letflow.Entities.Query.Cursor`/`Letflow.Entities.Query.FieldGrants` as
  this slice's new modules, and this design specifies the tables and the
  read-side loader/redactor only (§5) -- a future write-path requirement
  owns authoring these rows and can add schema modules then if it needs
  them.
  """

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Entities.Record.Latest
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @redacted_sentinel :__field_redacted__

  @typedoc """
  The set of `field_name` values redacted for one `(user_id, entity_type)`
  pair, already resolved (restrictions minus that user's own grants).
  """
  @type restriction_set :: MapSet.t(String.t())

  @doc "The redaction sentinel value, `:__field_redacted__` (design §3.4)."
  @spec redacted_sentinel() :: :__field_redacted__
  def redacted_sentinel, do: @redacted_sentinel

  @doc """
  Computes `entity_field_restrictions` rows for `entity_type` whose
  `field_name` has no matching `user_entity_grants` row for
  `(user_id, entity_type, field_name)` -- a single anti-join query, scoped
  to the tenant schema named by `prefix` (design §3.5).

  Returns `MapSet.new([])` (never an error) when `entity_type` has no
  restricted fields at all -- an entity type with zero
  `entity_field_restrictions` rows is not an error condition, it is the
  common case.
  """
  @spec load_restrictions(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, restriction_set()} | {:error, :invalid_schema_name}
  def load_restrictions(user_id, entity_type, prefix)
      when is_binary(user_id) and is_binary(entity_type) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(fr in "entity_field_restrictions",
          left_join: g in "user_entity_grants",
          on:
            g.entity_type == fr.entity_type and
              g.field_name == fr.field_name and
              g.user_id == type(^user_id, Ecto.UUID),
          where: fr.entity_type == ^entity_type and is_nil(g.id),
          select: fr.field_name
        )

      field_names = Repo.all(query, prefix: prefix)
      {:ok, MapSet.new(field_names)}
    end
  end

  @doc """
  Pure, no I/O: for each `field_name` in `restriction_set` that is also a
  key of `field_values`, replaces that key's value with
  `:__field_redacted__` (design §3.4/§3.5). Every other key is passed
  through unchanged. A `restriction_set` naming a field absent from
  `field_values` is a no-op for that key, never an error (a restriction
  naming a field the current entity definition version no longer declares,
  or that this particular record never set).
  """
  @spec redact_field_values(field_values :: map(), restriction_set()) :: map()
  def redact_field_values(field_values, restriction_set) when is_map(field_values) do
    Map.new(field_values, fn {key, value} ->
      if MapSet.member?(restriction_set, key) do
        {key, @redacted_sentinel}
      else
        {key, value}
      end
    end)
  end

  @doc """
  Maps `redact_field_values/2` over every row's own `field_values`,
  returning a new `Page.t()` with the same `next_cursor`/`count` and each
  item's `field_values` redacted (design §3.5) -- the composition point
  where `Cursor.paginate/5`'s output and `load_restrictions/3`'s output
  meet.
  """
  @spec redact_page(
          Pagination.Page.t(Latest.t() | Letflow.Entities.Query.Compiler.entity_row()),
          restriction_set()
        ) :: Pagination.Page.t(Latest.t() | Letflow.Entities.Query.Compiler.entity_row())
  def redact_page(%Pagination.Page{items: items} = page, restriction_set) do
    %{page | items: Enum.map(items, &redact_item(&1, restriction_set))}
  end

  defp redact_item(%Latest{field_values: field_values} = item, restriction_set) do
    %{item | field_values: redact_field_values(field_values, restriction_set)}
  end

  defp redact_item(%{field_values: field_values} = item, restriction_set) when is_map(item) do
    %{item | field_values: redact_field_values(field_values, restriction_set)}
  end

  # ---------------------------------------------------------------------------------
  # REQ-300 -- FieldGrants composition with a joined read (design §7). Exactly
  # one new public function (`redact_joined_page/2`) plus one new private
  # helper (`redact_joined_item/2`) below this line -- `redacted_sentinel/0`,
  # `load_restrictions/3`, `redact_field_values/2`, `redact_page/2`, and
  # `redact_item/2` above are unmodified: same signatures, same bodies, same
  # tests still green.
  #
  # `load_restrictions/3`'s own anti-join is reused exactly as designed
  # today, for its original purpose -- computing one `(user_id,
  # entity_type)`'s restriction set -- called once per distinct entity type
  # present in a joined result. It is never repurposed as any part of the
  # join *mechanism* itself, which lives entirely in
  # `Letflow.Entities.Query.Compiler` (REQ-300 design §3-§5).
  #
  # `restriction_sets()` is keyed exactly the way a `Compiler.joined_row()`
  # itself is keyed -- the atom `:primary` for the primary entity's own
  # restriction set, and each joined `entity_type` string for that joined
  # entity's own set -- so a caller composes it with one
  # `load_restrictions/3` call per distinct entity type present (primary's
  # own entity type keyed under `:primary`, plus each `join_clause.entity_type`
  # keyed under that string; `through`'s own entity type is not included,
  # since its row is never exposed in a joined result -- REQ-300 design
  # §4). This is the direct answer to AC5's "keyed by entity-type-of-each-field,
  # not just the primary entity type": a joined entity's own restriction set
  # governs its own fields; the primary's redaction never leaks onto a
  # joined entity's fields and vice versa, because each is resolved and
  # redacted independently.
  #
  # For a non-join request (`join` absent/empty), `redact_page/2` continues
  # to be the right call, unchanged -- `redact_joined_page/2` is additive,
  # not a replacement.
  # ---------------------------------------------------------------------------------

  @typedoc """
  One restriction set per distinct entity present in a joined result,
  keyed the same way `Compiler.joined_row()` itself is keyed (design §7).
  """
  @type restriction_sets :: %{(:primary | String.t()) => restriction_set()}

  @doc """
  Maps `redact_field_values/2` over every entity in every joined row's own
  `Compiler.joined_row()` map -- `:primary` and every joined `entity_type`
  string key alike, with no special-casing of `:primary` over a joined key
  (design §7).
  """
  @spec redact_joined_page(
          Pagination.Page.t(Letflow.Entities.Query.Compiler.joined_row()),
          restriction_sets()
        ) :: Pagination.Page.t(Letflow.Entities.Query.Compiler.joined_row())
  def redact_joined_page(%Pagination.Page{items: items} = page, restriction_sets)
      when is_map(restriction_sets) do
    %{page | items: Enum.map(items, &redact_joined_item(&1, restriction_sets))}
  end

  defp redact_joined_item(joined_row, restriction_sets) when is_map(joined_row) do
    Map.new(joined_row, fn {key, entity_row} ->
      restriction_set = Map.fetch!(restriction_sets, key)

      {key,
       %{entity_row | field_values: redact_field_values(entity_row.field_values, restriction_set)}}
    end)
  end
end
