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

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.PlatformProcesses.SystemStart
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
        initial_variables:
          operator_variables(form, platform_prefix, register_tenant_start_key(form)),
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

  # The operator start's variables, version-aware (design section 1). The v2 keys
  # (`tenant_type`, `notify_admin`) travel only when the definition version the start runs
  # declares them: the ACTIVE version for a new start, the ORIGINAL start's version for a replay
  # (the replay must compare equal to the first start's variables). `notify_admin` is true only
  # when an `admin_email` was supplied.
  defp operator_variables(form, prefix, key) do
    base = register_tenant_variables(form)

    v2 =
      form
      |> Map.take([:tenant_type])
      |> Enum.reduce(%{"notify_admin" => present?(Map.get(form, :admin_email))}, fn
        {:tenant_type, value}, acc when is_binary(value) and value != "" ->
          Map.put(acc, "tenant_type", value)

        _other, acc ->
          acc
      end)
      |> Map.put("provision_realm", provision_realm?(form))

    case declared_keys(prefix, key) do
      {:ok, keys} -> Map.merge(base, Map.take(v2, keys))
      :error -> base
    end
  end

  @doc """
  Whether the ACTIVE registration definition declares the `tenant_type` input (v2). A route that
  receives a `tenant_type` refuses it with 422 when this is false (v1), instead of dropping it.
  """
  @spec register_tenant_accepts_tenant_type?() :: boolean()
  def register_tenant_accepts_tenant_type? do
    with {:ok, prefix} <- PlatformTenant.platform_prefix(),
         {:ok, keys} <-
           declared_keys(prefix, "register-tenant:none-" <> Ecto.UUID.generate()) do
      "tenant_type" in keys
    else
      _other -> false
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  # T-3154 (v3): the process makes the realm when none was supplied and there is a first administrator
  # to invite. An operator form (routes 1 and 2) also needs the provisioner to be configured: an
  # environment without one keeps today's "not yet loginable" tenant instead of an instance in ERROR.
  defp provision_realm?(form) do
    not present?(Map.get(form, :realm_id)) and present?(Map.get(form, :admin_email)) and
      Letflow.Signup.Provisioning.provisioner_ready?()
  end

  defp declared_keys(prefix, key) do
    definition_ref =
      case Letflow.Engine.IdempotentReplay.lookup(key, prefix) do
        {:ok, original} -> {:id, Map.get(original.payload || %{}, "definition_id")}
        _none -> {:name, register_tenant_definition_name()}
      end

    result =
      case definition_ref do
        {:id, id} when is_binary(id) -> Definitions.get_by_id(id, prefix: prefix)
        {:id, _} -> {:error, :not_found}
        {:name, name} -> Definitions.get_active_by_name(name, prefix: prefix)
      end

    with {:ok, definition} <- result,
         {:ok, entries} <- Definitions.variable_schema_entries(definition.id, prefix: prefix) do
      {:ok, Enum.map(entries, & &1.variable_key)}
    else
      _other -> :error
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

  @doc """
  The start variables of a SYSTEM start (routes 3 and 4), built from the map
  `Letflow.TenantProvisioner.Request.parse/1` returns (`docs/platform-register-tenant-v2.md` section
  1). This and `register_tenant_variables/1` are the only places that name start variables: no request
  body field reaches the variables under a name this function did not choose.

  `tier`, `language`, `expires_at` and both digests are NOT variables: they live in the admission row.
  `notify_admin` is always `false` here (the provisioner sends no mail).
  """
  @spec register_tenant_system_variables(map()) :: map()
  def register_tenant_system_variables(request) when is_map(request) do
    tenant_id = Map.get(request, :tenant_id)

    %{"notify_admin" => false, "provision_realm" => not present?(Map.get(request, :idp_realm_id))}
    |> put_present("language", Map.get(request, :language))
    |> put_present("slug", slug_of(tenant_id))
    |> put_present("name", Map.get(request, :name))
    |> put_present("requested_tenant_id", tenant_id)
    |> put_present("hostname", Map.get(request, :hostname))
    |> put_present("realm_id", Map.get(request, :idp_realm_id))
    |> put_present("admin_email", Map.get(request, :email_key))
  end

  defp slug_of(id) when is_binary(id), do: "t-" <> String.replace(id, "-", "")
  defp slug_of(_other), do: nil

  @doc """
  Starts the active registration definition with the narrow SYSTEM authority (T-2727, pilot gap G17c;
  decision record 0094, Update "The system-authority start").

  `system_start` is a `%Letflow.PlatformProcesses.SystemStart{}` the server built with
  `SystemStart.for_route/1`. The engine admits it for the registration definition only, in the platform
  prefix only (`Letflow.Definitions.StartPermission.check/4`); the audit row carries
  `actor_kind: "system"` and the route. The actor is the platform sentinel, the prefix is the platform
  prefix and never the caller's.

  Answers `{:ok, create_result}`, `{:error, :not_found}` (not admitted, or no active definition),
  `{:error, :platform_tenant_not_configured}`, `{:error, :register_tenant_v2_missing}` (the active
  version does not carry the v2 contract; checked before the start, NEW starts only), or the engine's
  own error tuple. Never raises (INV-8).
  """
  @spec start_register_tenant_system(map(), SystemStart.t(), keyword()) ::
          {:ok, Engine.create_result()} | {:error, term()}
  def start_register_tenant_system(request, %SystemStart{} = system_start, opts)
      when is_map(request) and is_list(opts) do
    variables = register_tenant_system_variables(request)

    with {:ok, slug} <- fetch_slug(variables),
         {:ok, platform_prefix} <- platform_prefix(),
         key = register_tenant_start_key(%{slug: slug}),
         :ok <- v2_contract(platform_prefix, key),
         {:ok, variables} <- declared_variables(variables, platform_prefix, key) do
      attrs = %{
        definition_name: register_tenant_definition_name(),
        initial_variables: variables,
        actor_id: Letflow.EventStore.platform_actor_id(),
        idempotency_key: register_tenant_start_key(%{slug: slug})
      }

      Engine.create(attrs, prefix: platform_prefix, auth_context: nil, system_start: system_start)
    end
  end

  def start_register_tenant_system(_request, _system_start, _opts), do: {:error, :not_found}

  # T-3154: the variables go only under the names the definition version of THIS start declares (the
  # active one for a new start, the original's for a replay, so a replay of a v2 start compares equal).
  # A start that must make the realm needs a version that declares `provision_realm` (v3): an older
  # active version fails CLOSED, the same code as a missing v2 contract.
  defp declared_variables(variables, prefix, key) do
    case declared_keys(prefix, key) do
      {:ok, keys} ->
        # An existing start (a replay or a reuse) is answered by the engine from its ledger, by
        # comparing the variables under the ORIGINAL version's names: it is never refused here.
        if Map.get(variables, "provision_realm") == true and "provision_realm" not in keys and
             not match?({:ok, _}, Letflow.Engine.IdempotentReplay.lookup(key, prefix)) do
          require Logger
          Logger.error("register_tenant_v3_missing")
          {:error, :register_tenant_v2_missing}
        else
          {:ok, Map.take(variables, keys)}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp fetch_slug(%{"slug" => slug}) when is_binary(slug), do: {:ok, slug}
  defp fetch_slug(_variables), do: {:error, :invalid_request}

  defp platform_prefix do
    case PlatformTenant.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      _other -> {:error, :platform_tenant_not_configured}
    end
  end

  # The active version must carry the v2 contract; a wrong version fails CLOSED with a log line that
  # names the tag only.
  defp v2_contract(prefix, key) do
    # An existing start is answered from the ledger by the engine, before the definition lookup: it
    # needs no contract check (the first start passed it).
    case Letflow.Engine.IdempotentReplay.lookup(key, prefix) do
      {:ok, _original} -> :ok
      _none -> check_v2_contract(prefix)
    end
  end

  defp check_v2_contract(prefix) do
    with {:ok, active} <-
           Definitions.get_active_by_name(register_tenant_definition_name(), prefix: prefix),
         {:ok, entries} <- Definitions.variable_schema_entries(active.id, prefix: prefix),
         keys = Enum.map(entries, & &1.variable_key),
         true <- Enum.all?(["requested_tenant_id", "tenant_type", "notify_admin"], &(&1 in keys)) do
      :ok
    else
      {:error, :not_found} ->
        {:error, :not_found}

      _other ->
        require Logger
        Logger.error("register_tenant_v2_missing")
        {:error, :register_tenant_v2_missing}
    end
  end
end
