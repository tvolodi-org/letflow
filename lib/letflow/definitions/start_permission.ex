defmodule Letflow.Definitions.StartPermission do
  @moduledoc """
  The permission a caller must hold to START an instance of a definition
  (T-2588, pilot gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e);
  T-2591, pilot gap G3, adds the DECLARED permission of the definition's own
  `start_permission` column).

  A definition that calls a platform function may be started only by a caller
  that holds the entry's permission -- `:TenantsManage` for the tenant family.
  The start variables of such a definition are TRUSTED inputs (the person who
  starts it chooses the values the platform function reads), so the start
  needs the same authority the activation does.

  ## The two requirements

  A start needs BOTH of these, and a definition that has neither starts as it
  always did:

    * the DERIVED requirement: the catalogue permission of the entries the
      definition's `platform_call` steps call (and of the entries its
      SUB_PROCESS children call). It is platform-scope: the start happens in
      the platform tenant, and everybody else gets the INV-5 answer.
    * the DECLARED requirement: the atom the definition's own `start_permission`
      column names (T-2591). It is a property of the definition, read from its
      own row, and it is evaluated in the CALLER's own tenant scope, so a
      company definition may declare one too.

  The declared permission may not be WEAKER than the derived one: activation
  refuses a version whose `start_permission` does not imply every derived
  permission (`activation_violation/1`). A weaker declaration would look like a
  guard while granting less than the step actually needs.

  ## The answer

  A caller without the permission, and every caller outside the platform tenant
  for a derived requirement, gets the answer for an UNKNOWN definition (INV-5):
  the start refuses, nothing is written, and the reason never reaches the
  caller.

  Pure: no query, no clock, never raises.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.PlatformCalls
  alias Letflow.PlatformTenant

  @doc """
  The permission atoms a definition's `platform_call` steps require of the
  person who starts an instance of it. Empty for an ordinary definition.
  """
  @spec required(Graph.t() | term()) :: [atom()]
  def required(graph) when is_list(graph), do: PlatformCalls.required_permissions(graph)

  def required(%Graph{nodes: nodes}) when is_list(nodes),
    do: PlatformCalls.required_permissions(nodes)

  def required(_other), do: []

  @doc """
  The permission a definition DECLARES for its start: `{:ok, atom}` for a
  version that carries one, `:none` when the column is empty, and
  `{:error, :unknown}` when the column names a permission the platform does
  not know.

  The column holds the ATOM NAME as a string (the column is read back without
  the atom table); an unknown name is refused rather than guessed.
  """
  @spec declared(map() | term()) :: {:ok, atom()} | :none | {:error, :unknown}
  def declared(definition) when is_map(definition) do
    case Map.get(definition, :start_permission) do
      nil -> :none
      "" -> :none
      name when is_binary(name) -> parse(name)
      _other -> {:error, :unknown}
    end
  end

  def declared(_other), do: :none

  defp parse(name) do
    trimmed = String.trim(name)

    # The atom is looked up in the permission table, never created from the
    # string: an unknown name is refused, and no new atom is born of a
    # caller's input.
    case Enum.find(Authorization.permissions(), &(Atom.to_string(&1) == trimmed)) do
      nil -> {:error, :unknown}
      atom -> {:ok, atom}
    end
  end

  @doc """
  The permission atoms a caller must hold to start `definition`: the DECLARED
  one (when it has one) together with the DERIVED ones.
  """
  @spec required_atoms(map() | term(), [map()]) :: [atom()]
  def required_atoms(definition, children \\ []) do
    derived = required_permission_atoms(definition, children)

    declared =
      case declared(definition) do
        {:ok, atom} -> [atom]
        _other -> []
      end

    Enum.uniq(declared ++ derived)
  end

  @doc """
  The authority of one start: `:ok` when the caller may start `definition`,
  `{:error, :not_found}` when it may not (the INV-5 answer).

  `auth_context` is the server-side request context (`:user_id`, `:tenant_id`,
  `:roles`); nil when the caller is not an HTTP principal (module code, a
  sub-process child), which may not start a definition that calls a platform
  function.

  `children` are the SUB_PROCESS child definitions the definition starts: a
  child inherits the parent's start variables, so it needs the same authority
  as a direct start. A child that calls a platform function therefore holds the
  parent's start to the same permission.
  """
  @spec check(map() | term(), map() | nil, [map()]) :: :ok | {:error, :not_found}
  def check(definition, auth_context, children \\ [])

  def check(definition, auth_context, children) when is_map(definition) do
    derived = required_permission_atoms(definition, children)

    declared =
      case declared(definition) do
        {:ok, atom} -> [atom]
        {:error, :unknown} -> [:__unknown_start_permission__]
        :none -> []
      end

    if derived == [] and declared == [] do
      # A definition with no requirement starts exactly as it always did -- a
      # caller that is not an HTTP principal (module code) included.
      :ok
    else
      case authorize(auth_context, derived, declared) do
        :ok -> :ok
        {:error, :not_found} -> {:error, :not_found}
      end
    end
  end

  def check(_definition, _auth_context, _children), do: :ok

  defp required_permission_atoms(%{graph: graph_map}, children) do
    own =
      case Graph.from_map(graph_map) do
        {:ok, graph} -> required(graph)
        :error -> []
      end

    from_children =
      children
      |> Enum.flat_map(fn child -> required_permission_atoms(child, []) end)
      |> Enum.uniq()

    Enum.uniq(own ++ from_children)
  end

  defp required_permission_atoms(_definition, _children), do: []

  # The DERIVED requirements are platform-scope: the start happens in the
  # platform tenant (INV-10), so a caller outside it is refused before the
  # permission is even looked at. The DECLARED requirement is evaluated in the
  # CALLER's own tenant scope: it is a property of the definition, not a
  # platform power, so a company definition may declare one.
  defp authorize(nil, _derived, _declared), do: {:error, :not_found}

  defp authorize(auth_context, derived, declared) when is_map(auth_context) do
    user_id = Map.get(auth_context, :user_id)
    tenant_id = Map.get(auth_context, :tenant_id)
    roles = Map.get(auth_context, :roles) || []

    if not is_binary(user_id) do
      {:error, :not_found}
    else
      platform? = PlatformTenant.platform_tenant?(tenant_id)

      context = %Authorization.AccessContext{
        user_id: user_id,
        roles: Authorization.roles_from_strings(roles),
        platform_tenant?: platform?
      }

      derived_ok? =
        derived == [] or
          (platform? and
             Enum.all?(derived, &(Authorization.evaluate_access(context, &1).kind == :Allow)))

      declared_ok? =
        Enum.all?(declared, fn
          :__unknown_start_permission__ -> false
          atom -> Authorization.evaluate_access(context, atom).kind == :Allow
        end)

      if derived_ok? and declared_ok? do
        :ok
      else
        {:error, :not_found}
      end
    end
  end

  defp authorize(_auth_context, _derived, _declared), do: {:error, :not_found}

  @doc """
  The activation-time refusal of a DECLARED `start_permission` that is weaker
  than a permission the definition's own steps require: `nil` when the
  declaration is acceptable, `{:start_permission_too_weak, declared, required}`
  when it is not.

  "Weaker" is decided over the ROLE TABLE: the declared permission is weaker
  when some role holds it that does NOT hold the required one. A declared
  permission that is exactly the required one, or a stronger one, is accepted.

  A definition with no `platform_call` step has no derived requirement, so
  every declared permission is acceptable: the declaration is then the ONLY
  requirement of the start.
  """
  @spec activation_violation(map() | term()) ::
          nil | {:start_permission_too_weak, atom(), atom()} | {:start_permission_unknown, term()}
  def activation_violation(definition) when is_map(definition) do
    case declared(definition) do
      {:error, :unknown} ->
        {:start_permission_unknown, Map.get(definition, :start_permission)}

      {:ok, declared_atom} ->
        derived =
          case Map.get(definition, :graph) do
            graph_map when is_map(graph_map) ->
              case Graph.from_map(graph_map) do
                {:ok, graph} -> required(graph)
                :error -> []
              end

            _other ->
              []
          end

        derived
        |> Enum.reject(&implies?(declared_atom, &1))
        |> case do
          [] -> nil
          [required_atom | _rest] -> {:start_permission_too_weak, declared_atom, required_atom}
        end

      :none ->
        nil
    end
  end

  def activation_violation(_definition), do: nil

  @doc """
  True when `declared` is NOT WEAKER than `required`: every role that holds
  `declared` holds `required` as well.

  The comparison runs over the role table in the PLATFORM tenant (the scope
  the derived permissions live in): a permission is stronger when the set of
  roles that hold it is a subset of the set that holds the weaker one.
  """
  @spec implies?(atom(), atom()) :: boolean()
  def implies?(declared, required) when is_atom(declared) and is_atom(required) do
    if declared == required do
      true
    else
      roles_holding(declared) -- roles_holding(required) == []
    end
  end

  def implies?(_declared, _required), do: false

  defp roles_holding(permission) do
    Enum.filter(Authorization.roles(), fn role ->
      Authorization.has_permission_in_scope?([role], permission, true)
    end)
  end
end
