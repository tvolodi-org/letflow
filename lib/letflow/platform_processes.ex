defmodule Letflow.PlatformProcesses do
  @moduledoc """
  The platform PROCESSES: the definitions of the platform tenant that carry a
  business function of the platform itself, and the ONE way each of them is
  started (T-2591, pilot gap G3; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)).

  ## Why this module exists

  The pilot's rule is that a business function is a PROCESS, not a code path:
  the "Register tenant" screen starts an instance of the active
  `platform.register_tenant` definition, and the engine runs its steps. The
  definition itself is shipped by gap G9 (the seed); THIS module owns the part
  every caller shares: which definition runs, which variables the start
  carries, and the authority the start needs.

  The other paths that do the same business function (gap G17: the tenant
  route, the provisioner mount, the self-service signup) call THIS function
  too, so there is exactly one place where a platform process is started and
  exactly one place that decides what a caller may start.

  ## The authority

  The start goes through `Letflow.Engine.create/2`, the ONE start function,
  which checks the definition's start permission: the catalogue permission of
  the steps the definition calls (`:TenantsManage` for the tenant family) and
  the permission the definition DECLARES in its own `start_permission` column
  (`Letflow.Definitions.StartPermission`). A caller without it -- a company
  tenant's administrator, a platform user without `:TenantsManage` -- gets the
  answer for an UNKNOWN definition (INV-5), and nothing is written.

  ## The variables of the start

  The start variables are the FORM's values under the names the catalogue's
  tenant family declares (`Letflow.PlatformFunctions.TenantFamily`): `slug`
  and `name` (the display name) are the `:start`-class inputs of
  `tenant.validate` and `tenant.create`, `realm_id` the input of
  `tenant.bind_realm`, `admin_email` the input of
  `tenant.grant_first_admins`. `hostname` travels with them, because the
  platform's own tenant table carries it.

  A definition that declares `variable_schemas` must declare THESE names: the
  start is validated against the definition's own schemas, so a definition
  that renames one of them cannot be started from the screen.
  """

  alias Letflow.Engine
  alias Letflow.PlatformTenant

  @doc """
  The key of the pilot's registration definition, in the platform tenant.
  """
  @spec register_tenant_definition_name() :: String.t()
  def register_tenant_definition_name, do: "platform.register_tenant"

  @doc """
  The start variables of the registration process, built from the form's values.

  The names are the catalogue's own (see the moduledoc). A value the caller
  did not send is OMITTED, never sent as a nil: a step that declares the
  input reads it from the variables, and a missing key is the absence of the
  input.
  """
  @spec register_tenant_variables(map()) :: map()
  def register_tenant_variables(form) when is_map(form) do
    # The instance variables are a STRING-keyed map (the engine's own
    # namespace), so the names travel as strings.
    %{}
    |> put_present("slug", Map.get(form, :slug))
    |> put_present("name", Map.get(form, :name))
    |> put_present("hostname", Map.get(form, :hostname))
    |> put_present("realm_id", Map.get(form, :realm_id))
    |> put_present("admin_email", Map.get(form, :admin_email))
  end

  @doc """
  The idempotency key of a route's start: the SLUG alone (PM decision, T-2704).

  The same slug with the SAME values is a replay of the first start (a double
  click answers the first instance); the same slug with OTHER values is a key
  reuse, which the engine refuses and the route answers 409 -- never a second
  tenant. The engine compares the start variables of the replay with the first
  start's, so the key need not carry them.
  """
  @spec register_tenant_start_key(map()) :: String.t()
  def register_tenant_start_key(form) when is_map(form) do
    "register-tenant:" <> to_string(Map.get(form, :slug))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Starts the active version of the registration definition in the PLATFORM
  tenant.

  `opts` carries the caller's identity and the start's own key:

    * `:actor_id` -- the person who starts it (the audit actor);
    * `:idempotency_key` -- the key of this start (the caller's, so a replay
      of the same request is the same start);
    * `:auth_context` -- the server-side request context, which the start
      permission is evaluated against.

  The answer is the engine's own: `{:ok, result}` with the instance id, or
  the engine's error tuple. The definition is looked up in the platform tenant
  only: a caller of another tenant never reaches a platform definition.

  A missing `:actor_id` or `:idempotency_key` is a TYPED error
  (`{:error, :missing_actor_id}`, `{:error, :missing_idempotency_key}`), never a
  raise (INV-8): this seam is called by a route, and a route that forgets an
  option must not answer a 500.
  """
  @spec start_register_tenant(map(), keyword()) ::
          {:ok, Engine.create_result()} | {:error, term()}
  def start_register_tenant(form, opts) when is_map(form) and is_list(opts) do
    with {:ok, actor_id} <- fetch_opt(opts, :actor_id),
         {:ok, idempotency_key} <- fetch_opt(opts, :idempotency_key),
         {:ok, platform_prefix} <- PlatformTenant.platform_prefix() do
      attrs = %{
        definition_name: register_tenant_definition_name(),
        initial_variables: register_tenant_variables(form),
        actor_id: actor_id,
        idempotency_key: idempotency_key
      }

      Engine.create(attrs,
        prefix: platform_prefix,
        auth_context: Keyword.get(opts, :auth_context)
      )
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :platform_tenant_not_configured}
    end
  end

  # A required option, read without raising: a missing or empty value is a
  # typed error the caller can answer (INV-8).
  defp fetch_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :"missing_#{key}"}
    end
  end
end
