defmodule Letflow.Entities.ScopedWrites do
  @moduledoc """
  The scope rules of the generic record WRITE routes for a scoped caller (REQ-518 PR 2c-ii /
  GH #2535; design `lib/letflow/design/req518-compiler-scope-filter.md` 5.3 and 5.4, decision
  0051 D6 and D7, SEC rulings R-5, R-6 and C-3).

  Everything here is about a caller whose `Letflow.Entities.Query.Types.scope_set/0` is NOT `:all`
  (a tenant-wide caller, a token principal and every tenant that is not `on` carry `:all` and
  never reach these functions: their write path is byte for byte today's).

    * `type_gate/3` -- a type that is not declared by a column (undeclared, or a `:tenant_wide`
      master) is not writable by a scoped caller at all (R-6). One refusal, before the body is read.
    * `check_new_value/3` -- PURE (no I/O): the declared column of the NEW `field_values` must be a
      string in the caller's set. A missing, null or non-string value is refused. The router runs
      it BEFORE the idempotency claim (C-3), so a replayed key never confirms another caller's
      record; `Letflow.Entities.Records` runs it again before its transaction and, with the old
      value, inside it (the race backstop).
    * `check_batch/3` -- the same rule over EVERY entry of an import, so a batch is all-or-nothing
      with one answer (R-5).

  A refusal is always `:refused`; the router renders it as the generic `Response.not_found/1`
  (the same bytes as a by-id 404 and as a nonexistent type name, SEC C-6), counted through
  `Letflow.Entities.ScopedLookup.emit_not_found/2` and never audited. The check is set
  membership of a string, never a node read, so a nonexistent, retired, malformed, NULL and
  out-of-scope node id all give the identical answer.
  """

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.ScopedLookup
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Entities.ScopeResolver

  @doc """
  The declaration a scoped caller's write is checked against, or `:refused` for a type that is
  not scope-aware by a column. Scope `:all` is `{:ok, :unscoped}` with no read.
  """
  @spec type_gate(entity_type :: String.t(), Types.scope_set(), prefix :: String.t()) ::
          {:ok, ScopeDeclaration.declaration() | :unscoped} | :refused
  def type_gate(_entity_type, :all, _prefix), do: {:ok, :unscoped}
  def type_gate(_entity_type, :none, _prefix), do: :refused

  def type_gate(entity_type, {:nodes, _ids}, prefix) do
    case ScopeDeclaration.for_type(entity_type, prefix) do
      {:column, _field} = declaration -> {:ok, declaration}
      _tenant_wide_or_undeclared -> :refused
    end
  end

  @doc "The pure new-value check (see the moduledoc). `:unscoped` / scope `:all` is always `:ok`."
  @spec check_new_value(
          field_values :: term(),
          ScopeDeclaration.declaration() | :unscoped,
          Types.scope_set()
        ) :: :ok | :refused
  def check_new_value(_field_values, _declaration, :all), do: :ok
  def check_new_value(_field_values, :unscoped, _scope), do: :ok
  def check_new_value(_field_values, _declaration, :none), do: :refused

  def check_new_value(field_values, declaration, {:nodes, ids}) do
    case ScopeResolver.record_scope(%{declaration: declaration, field_values: field_values}) do
      {:node, node_id} -> if node_id in ids, do: :ok, else: :refused
      _tenant_wide_or_unresolvable -> :refused
    end
  end

  @doc """
  REFERENCES of the NEW document (SEC ruling BUG-1, AC 7): every non-null value of a field named
  by the definition's `foreign_keys` (promoted or not) must resolve, through the scope of the
  REFERENCED type, via `Letflow.Entities.ScopedLookup.all_in_scope?/4`. Otherwise `:refused`,
  the generic 404 with the same telemetry kind as a refused scope value, so an out-of-scope and
  a nonexistent target are indistinguishable (the database foreign key would otherwise answer 201
  vs 500).

  One lookup statement per referenced field with a well-formed value, issued whether the target
  is in scope, out of scope or absent; none for an absent or null value (skipped), for a
  malformed or non-string value (refused) or for an undeclared target. Every field is evaluated
  (no short-circuit). Scope `:all` is `:ok` with no read. There is NO exemption for an unchanged
  stored reference on an update (fail closed): a scoped PUT on a record whose stored reference
  has since left the caller's scope is the generic 404 until the reference is changed.
  Residual (accepted, SEC BUG-1 ruling): the referenced row's scope column can change between
  this check and the commit; no lock is taken on the referenced row.
  """
  @spec check_references(EntityDefinition.t(), term(), Types.scope_set(), String.t()) ::
          :ok | :refused
  def check_references(_definition, _field_values, :all, _prefix), do: :ok

  def check_references(%EntityDefinition{} = definition, field_values, scope, prefix) do
    verdicts =
      for {field, target} <- reference_fields(definition) do
        reference_verdict(field_values, field, target, scope, prefix)
      end

    if :refused in verdicts, do: :refused, else: :ok
  end

  @doc """
  `check_references/4` for a router that holds only the entity type: loads the active definition
  (an absent one is `:refused`). Scope `:all` reads nothing.
  """
  @spec check_references_of_type(String.t(), term(), Types.scope_set(), String.t()) ::
          :ok | :refused
  def check_references_of_type(_entity_type, _field_values, :all, _prefix), do: :ok

  def check_references_of_type(entity_type, field_values, scope, prefix) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, %EntityDefinition{} = definition} ->
        check_references(definition, field_values, scope, prefix)

      _absent_or_error ->
        :refused
    end
  end

  @doc """
  The import form of `check_references_of_type/4`: the distinct well-formed ids of every entry are
  collected per referenced field and resolved with ONE statement per field (position
  independent); any malformed value, unresolved id or undeclared target refuses the whole batch.
  """
  @spec check_batch_references(String.t(), [term()], Types.scope_set(), String.t()) ::
          :ok | :refused
  def check_batch_references(_entity_type, _entries, :all, _prefix), do: :ok

  def check_batch_references(entity_type, entries, scope, prefix) when is_list(entries) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, %EntityDefinition{} = definition} ->
        verdicts =
          for {field, target} <- reference_fields(definition) do
            batch_verdict(entries, field, target, scope, prefix)
          end

        if :refused in verdicts, do: :refused, else: :ok

      _absent_or_error ->
        :refused
    end
  end

  defp batch_verdict(entries, field, target, scope, prefix) do
    values = Enum.map(entries, &entry_reference(&1, field))

    if :malformed in values do
      :refused
    else
      resolve_ids(target, values |> Enum.filter(&is_binary/1) |> Enum.uniq(), scope, prefix)
    end
  end

  defp entry_reference(%{"field_values" => %{} = field_values}, field),
    do: classify_reference(Map.get(field_values, field))

  defp entry_reference(_entry, _field), do: :malformed

  defp reference_verdict(field_values, field, target, scope, prefix) do
    case entry_reference(%{"field_values" => field_values}, field) do
      :malformed -> :refused
      nil -> :ok
      id -> resolve_ids(target, [id], scope, prefix)
    end
  end

  defp resolve_ids(_target, [], _scope, _prefix), do: :ok

  defp resolve_ids(target, ids, scope, prefix) do
    if ScopedLookup.all_in_scope?(target, ids, scope, prefix), do: :ok, else: :refused
  end

  # nil / absent -> skipped (nil); a castable UUID -> the normalised id; anything else -> :malformed
  defp classify_reference(nil), do: nil

  defp classify_reference(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> :malformed
    end
  end

  defp classify_reference(_other), do: :malformed

  defp reference_fields(%EntityDefinition{definition_json: json}) when is_map(json) do
    for %{"field" => field, "references_entity" => target} <-
          List.wrap(Map.get(json, "foreign_keys")),
        is_binary(field) and is_binary(target),
        do: {field, target}
  end

  defp reference_fields(_definition), do: []

  @doc """
  The import pre-check: every entry's `"field_values"` passes `check_new_value/3`, else the whole
  batch is `:refused` (no row count, no per-row detail, independent of which entry or reason).
  """
  @spec check_batch(
          entries :: [term()],
          ScopeDeclaration.declaration() | :unscoped,
          Types.scope_set()
        ) :: :ok | :refused
  def check_batch(entries, declaration, scope) when is_list(entries) do
    verdicts = Enum.map(entries, &entry_verdict(&1, declaration, scope))
    if :refused in verdicts, do: :refused, else: :ok
  end

  defp entry_verdict(%{"field_values" => field_values}, declaration, scope),
    do: check_new_value(field_values, declaration, scope)

  defp entry_verdict(_entry_without_field_values, declaration, scope),
    do: check_new_value(%{}, declaration, scope)
end
