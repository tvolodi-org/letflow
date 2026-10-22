defmodule Letflow.Entities.ScopeDeclaration do
  @moduledoc """
  Which entity types are scope-aware, and by which column (REQ-518 / GH #2535, decision 0051
  D6; design `lib/letflow/design/req518-compiler-scope-filter.md` section 3.2).

  A declaration is owned by a MODULE: the optional `:scope_declarations` manifest key,
  `%{entity_type_name => {:column, field_name} | :tenant_wide}`. It is never read from a tenant
  definition (`definition_json`), so a tenant cannot declare, widen or remove one.

  ## Resolution (only these inputs)

    1. the compiled manifests of `Letflow.Modules.Catalog.entry_modules/0` that name the type;
       no manifest names it -> `:undeclared` with ZERO queries;
    2. the declaring module must be INSTALLED in the tenant (one read per call);
    3. the type must be MANAGED by the declaring module (`ManagedTypes.owner_of/2`, one read per
       candidate type): the stamp must equal the declaring module id, otherwise `:undeclared`.
       An UNMANAGED type resolves to a declaration only when the declaring module id is on the
       test-only allowlist `config :letflow, :scope_declaration_unmanaged_modules` (set in
       `config/test.exs` only; `Catalog` rule 11 enforces the same rule at validation time).

  Anything else, including a malformed prefix or a type named by two modules, is `:undeclared`
  (fail closed). A type that is `:undeclared` returns no data to a scoped caller
  (`Letflow.Entities.Query.Compiler`).
  """

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.Catalog
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

    case candidates(types) do
      empty when map_size(empty) == 0 ->
        base

      candidates ->
        # A malformed prefix is :undeclared for every type (fail closed, no query).
        case TenantProvisioning.tenant_id_for_schema_name(prefix) do
          {:ok, _tenant_id} ->
            installed = installed_module_ids(prefix)

            Enum.reduce(candidates, base, fn {type, declared_by}, acc ->
              Map.put(acc, type, resolve_candidate(type, declared_by, installed, prefix))
            end)

          {:error, :invalid_schema_name} ->
            base
        end
    end
  end

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
    [prefix: prefix] |> Installs.list_installed() |> MapSet.new(& &1.module_id)
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
