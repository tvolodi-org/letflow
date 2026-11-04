defmodule Letflow.Entities.ScopeDeclaration do
  @moduledoc """
  Which entity types are scope-aware, and by which column (REQ-518 / GH #2535, decision 0051
  D6; design `lib/letflow/design/req518-compiler-scope-filter.md` section 3.2).

  A declaration has two owners. A MODULE owns the declarations of its types: the optional
  `:scope_declarations` manifest key, `%{entity_type_name => {:column, field_name} | :tenant_wide}`.
  For a tenant-owned type that no manifest names and no module manages, the third source is the
  core table `entity_scope_declarations` (REQ-635, decision 0070 D3), written only through
  `Letflow.Entities.ScopeDeclarations` by a tenant-wide TENANT_ADMIN. A declaration is never read
  from a tenant definition (`definition_json`), so a definition cannot declare, widen or remove one.

  ## Resolution (only these inputs)

    1. the compiled manifests of `Letflow.Modules.Catalog.entry_modules/0` that name the type;
       no manifest names it -> source 4 below (a malformed name costs no query);
    2. the declaring module must have a `tenant_modules` row of ANY status (one read per call):
       an uninstalled module keeps exactly its pre-uninstall read filters (decision 0066 D3);
    3. the type must be MANAGED by the declaring module (`ManagedTypes.owner_of/2`, one read per
       candidate type): the stamp must equal the declaring module id, otherwise `:undeclared`.
       An UNMANAGED type resolves to a declaration only when the declaring module id is on the
       test-only allowlist `config :letflow, :scope_declaration_unmanaged_modules` (set in
       `config/test.exs` only; `Catalog` rule 11 enforces the same rule at validation time).

    4. a type no manifest names, with a valid name: ONE read of `entity_scope_declarations` for all
       such types, then one `ManagedTypes.owner_of/2` per type that has a row; only an
       `:unmanaged` type takes its row (a row for a managed name is ignored). No row ->
       `:undeclared`.

  Anything else, including a malformed prefix or a type named by two modules, is `:undeclared`
  (fail closed). A type that is `:undeclared` returns no data to a scoped caller
  (`Letflow.Entities.Query.Compiler`).
  """

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.Catalog
  alias Letflow.Entities.ScopeDeclarations
  alias Letflow.Modules.Installs
  alias Letflow.TenantProvisioning

  @type declaration :: {:column, field :: String.t()} | :tenant_wide | :undeclared

  @doc "The declaration of one entity type (see the moduledoc). Same rules as `for_types/2`."
  @spec for_type(entity_type :: String.t(), prefix :: String.t()) :: declaration()
  def for_type(entity_type, prefix) when is_binary(entity_type) and is_binary(prefix) do
    entity_type |> List.wrap() |> for_types(prefix) |> Map.fetch!(entity_type)
  end

  @doc """
  The declarations of `entity_types` with one installed-modules read and, only for types some
  manifest names, one `owner_of` read per such type. Every requested type is a key of the
  result.
  """
  @spec for_types(entity_types :: [String.t()], prefix :: String.t()) ::
          %{String.t() => declaration()}
  def for_types(entity_types, prefix) when is_list(entity_types) and is_binary(prefix) do
    types = Enum.uniq(entity_types)
    base = Map.new(types, &{&1, :undeclared})

    candidates = candidates(types)

    rest =
      Enum.filter(types, &(not Map.has_key?(candidates, &1) and ManagedTypes.managed_name?(&1)))

    if map_size(candidates) == 0 and rest == [] do
      base
    else
      # A malformed prefix is :undeclared for every type (fail closed, no query).
      case TenantProvisioning.tenant_id_for_schema_name(prefix) do
        {:ok, _tenant_id} ->
          base
          |> resolve_manifest_types(candidates, prefix)
          |> resolve_table_types(rest, prefix)

        {:error, :invalid_schema_name} ->
          base
      end
    end
  end

  defp resolve_manifest_types(acc, candidates, _prefix) when map_size(candidates) == 0, do: acc

  defp resolve_manifest_types(acc, candidates, prefix) do
    installed = installed_module_ids(prefix)

    Enum.reduce(candidates, acc, fn {type, declared_by}, acc ->
      Map.put(acc, type, resolve_candidate(type, declared_by, installed, prefix))
    end)
  end

  # Third source: the tenant's own table, for types no manifest names.
  defp resolve_table_types(acc, [], _prefix), do: acc

  defp resolve_table_types(acc, types, prefix) do
    types
    |> ScopeDeclarations.for_types_rows(prefix)
    |> Enum.reduce(acc, fn {type, {kind, field}}, acc ->
      case ManagedTypes.owner_of(type, prefix) do
        :unmanaged -> Map.put(acc, type, table_declaration(kind, field))
        _managed_or_error -> acc
      end
    end)
  end

  defp table_declaration("tenant_wide", nil), do: :tenant_wide

  defp table_declaration("column", field) do
    if valid_declaration?({:column, field}), do: {:column, field}, else: :undeclared
  end

  defp table_declaration(_kind, _field), do: :undeclared

  @doc "True when some module manifest names `entity_type` in its `:scope_declarations`."
  @spec manifest_named?(term()) :: boolean()
  def manifest_named?(entity_type) when is_binary(entity_type),
    do: map_size(candidates([entity_type])) > 0

  def manifest_named?(_other), do: false

  # %{type => [{module_id, declaration}]} for the requested types only.
  defp candidates(types) do
    wanted = MapSet.new(types)

    Catalog.all_manifests()
    |> Enum.flat_map(fn manifest ->
      manifest
      |> Map.get(:scope_declarations, %{})
      |> Enum.filter(fn {type, _decl} -> MapSet.member?(wanted, type) end)
      |> Enum.map(fn {type, decl} -> {type, {manifest.id, decl}} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp installed_module_ids(prefix) do
    [prefix: prefix] |> Installs.list_all() |> MapSet.new(& &1.module_id)
  end

  # A type named by two modules is ambiguous: fail closed.
  defp resolve_candidate(_type, [_first, _second | _], _installed, _prefix), do: :undeclared

  defp resolve_candidate(type, [{module_id, decl}], installed, prefix) do
    if MapSet.member?(installed, module_id) and valid_declaration?(decl) do
      case ManagedTypes.owner_of(type, prefix) do
        {:ok, ^module_id} -> decl
        :unmanaged -> unmanaged_declaration(module_id, decl)
        _other -> :undeclared
      end
    else
      :undeclared
    end
  end

  defp unmanaged_declaration(module_id, decl) do
    if module_id in Application.get_env(:letflow, :scope_declaration_unmanaged_modules, []),
      do: decl,
      else: :undeclared
  end

  @doc """
  Whether `decl` is a well-formed manifest declaration (`:tenant_wide` or `{:column, field}`
  with a managed-name `field`). The single owner of the validity rule: `Letflow.Modules.Catalog`
  validation and `for_types/2` both call it.
  """
  @spec valid_declaration?(term()) :: boolean()
  def valid_declaration?(:tenant_wide), do: true

  def valid_declaration?({:column, field}) when is_binary(field),
    do: ManagedTypes.managed_name?(field)

  def valid_declaration?(_other), do: false
end
