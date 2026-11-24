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

  The DECLARED requirement is evaluated with the ROLE MATRIX
  (`Letflow.Api.Authorization.has_permission_in_scope?/4`), the same notion the
  activation fence below uses: a caller without one of the roles the matrix
  names for the declared atom is refused. An atom that EVERY role holds
  (`:MyAccessRead` and its two siblings) therefore still admits every caller
  with a role -- the fence sees the same table and calls such a declaration
  "not weaker", so the two decisions agree.

  ## The children count with the parent

  A SUB_PROCESS child inherits the parent's start variables, so it needs the
  same authority as a direct start. BOTH of the child's requirements join the
  parent's start: the child's DERIVED atoms (T-2588) and the child's DECLARED
  atom (T-2591). A child that declares a permission the caller does not hold
  therefore cannot be started through its parent either.

  ## The declaration may not be weaker than the steps need

  The declared permission may not be WEAKER than the derived one: activation
  refuses a version whose `start_permission` does not imply every derived
  permission of the definition AND of the children it starts
  (`activation_violation/2`). A weaker declaration would look like a guard
  while granting less than the step actually needs.

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
  alias Letflow.PlatformProcesses.SystemStart

  # The atom that stands for a DECLARED permission the platform does not know:
  # no caller holds it, so a start with it is refused. It is not a permission
  # atom of the table, so it can never be granted by a role or by a grant.
  @unknown_permission :__unknown_start_permission__

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
  The DECLARED permission atoms of a definition and of the children it starts:
  the atom each `start_permission` column names.

  A name the platform does not know is the sentinel `@unknown_permission`: no
  caller holds it, so a start with it is refused and an activation with it is
  refused too.
  """
  @spec declared_atoms(map() | term(), [map()]) :: [atom()]
  def declared_atoms(definition, children \\ [])

  def declared_atoms(definition, children) when is_map(definition) do
    own =
      case declared(definition) do
        {:ok, atom} -> [atom]
        {:error, :unknown} -> [@unknown_permission]
        :none -> []
      end

    from_children =
      children
      |> Enum.flat_map(fn child -> declared_atoms(child, []) end)
      |> Enum.uniq()

    Enum.uniq(own ++ from_children)
  end

  def declared_atoms(_definition, _children), do: []

  @doc """
  The authority of one start: `:ok` when the caller may start `definition`,
  `{:error, :not_found}` when it may not (the INV-5 answer).

  `auth_context` is the server-side request context (`:user_id`, `:tenant_id`,
  `:roles` and the tenant's `:role_overlay`); nil when the caller is not an
  HTTP principal (module code, a sub-process child), which may not start a
  definition that calls a platform function.

  `children` are the SUB_PROCESS child definitions the definition starts: a
  child inherits the parent's start variables, so it needs the same authority
  as a direct start. A child that calls a platform function therefore holds the
  parent's start to the same permission, and so does a child that DECLARES one.
  """
  @spec check(map() | term(), map() | nil, [map()], keyword()) :: :ok | {:error, :not_found}
  def check(definition, auth_context, children \\ [], opts \\ []) when is_list(opts) do
    # T-2727 (pilot gap G17c): a start that carries a `%SystemStart{}` has NO person behind it. It is
    # admitted by `system_check/4` only (one definition, platform prefix, exact permission, no child,
    # v2 contract); a system start that is not admitted is refused, whatever `auth_context` says.
    case Keyword.get(opts, :system_start) do
      nil -> check_person(definition, auth_context, children)
      %SystemStart{} = system_start -> system_check(system_start, definition, children, opts)
      _other -> {:error, :not_found}
    end
  end

  defp check_person(definition, auth_context, children) when is_map(definition) do
    derived = required_permission_atoms(definition, children)
    declared = declared_atoms(definition, children)

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

  defp check_person(_definition, _auth_context, _children), do: :ok

  # The conditions of C1 (`docs/platform-register-tenant-v2.md` section 6.2): ALL must hold, else the
  # answer is the one for an unknown definition and nothing is written.
  defp system_check(%SystemStart{definition_name: name}, definition, children, opts)
       when is_map(definition) do
    prefix = Keyword.get(opts, :prefix)

    ok? =
      Map.get(definition, :name) == name and
        name == "platform.register_tenant" and
        is_binary(prefix) and PlatformTenant.platform_prefix?(prefix) and
        children == [] and
        required_permission_atoms(definition, children) == [:TenantsManage] and
        declared_atoms(definition, children) == [:TenantsManage] and
        v2_contract?(definition, prefix)

    if ok? do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp system_check(_system_start, _definition, _children, _opts), do: {:error, :not_found}

  # The v2 start contract: the definition declares the three variables the system start needs.
  @v2_keys ["requested_tenant_id", "tenant_type", "notify_admin"]
  defp v2_contract?(%{id: id}, prefix) do
    case Letflow.Definitions.variable_schema_entries(id, prefix: prefix) do
      {:ok, entries} ->
        keys = Enum.map(entries, & &1.variable_key)
        Enum.all?(@v2_keys, &(&1 in keys))

      _error ->
        false
    end
  end

  defp v2_contract?(_definition, _prefix), do: false

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
    role_strings = Map.get(auth_context, :roles) || []

    # The tenant's grant overlay, resolved by the route's own authorization
    # (`Letflow.Plugs.Authorize`): the start reads the SAME facts the route
    # read, so a caller who holds the declared permission through a grant is
    # not refused a start the route allowed.
    overlay = Map.get(auth_context, :role_overlay) || %{}

    if not is_binary(user_id) do
      {:error, :not_found}
    else
      platform? = PlatformTenant.platform_tenant?(tenant_id)

      # The ONE role resolution (`Letflow.Api.Authorization.effective_roles/2`):
      # `:PLATFORM_ADMIN` counts only in the platform tenant, exactly as the
      # route's own authorization decided it.
      roles = Authorization.effective_roles(role_strings, platform?)

      derived_ok? =
        derived == [] or
          (platform? and
             Enum.all?(derived, &Authorization.has_permission_in_scope?(roles, &1, true)))

      declared_ok? =
        Enum.all?(declared, fn
          @unknown_permission -> false
          atom -> Authorization.has_permission_in_scope?(roles, atom, platform?, overlay)
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
  than a permission the definition's steps require: `nil` when the declaration
  is acceptable, `{:start_permission_too_weak, declared, required}` when it is
  not, and `{:start_permission_unknown, name}` when a declaration names a
  permission the platform does not know.

  "Weaker" is decided over the ROLE TABLE: the declared permission is weaker
  when some role holds it that does NOT hold the required one. A declared
  permission that is exactly the required one, or a stronger one, is accepted.

  The required permissions are the DERIVED ones of the definition AND of the
  children it starts (`children`): the start check demands the same set, so
  the fence may not be narrower than the check it guards.

  A definition with no `platform_call` step has no derived requirement, so
  every declared permission is acceptable: the declaration is then the ONLY
  requirement of the start.
  """
  @spec activation_violation(map() | term(), [map()]) ::
          nil | {:start_permission_too_weak, atom(), atom()} | {:start_permission_unknown, term()}
  def activation_violation(definition, children \\ [])

  def activation_violation(definition, children) when is_map(definition) do
    case unknown_declaration(definition, children) do
      nil ->
        case declared(definition) do
          {:ok, declared_atom} ->
            required_permission_atoms(definition, children)
            |> Enum.reject(&implies?(declared_atom, &1))
            |> case do
              [] ->
                nil

              [required_atom | _rest] ->
                {:start_permission_too_weak, declared_atom, required_atom}
            end

          _none ->
            nil
        end

      name ->
        {:start_permission_unknown, name}
    end
  end

  def activation_violation(_definition, _children), do: nil

  # The name of the first DECLARED permission the platform does not know: the
  # definition's own, or a child's (a child is activated on its own, but its
  # unknown declaration would make the parent's start impossible for everybody,
  # so the parent's activation refuses it too).
  defp unknown_declaration(definition, children) do
    own =
      case declared(definition) do
        {:error, :unknown} -> Map.get(definition, :start_permission)
        _known -> nil
      end

    from_children =
      Enum.find_value(children, fn child ->
        case unknown_declaration(child, []) do
          nil -> nil
          name -> name
        end
      end)

    own || from_children
  end

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
