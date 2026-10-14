defmodule Letflow.Modules.Catalog do
  @moduledoc """
  Reads the compiled list of platform modules and exposes lookup, the
  permission/role-grant unions, and manifest validation over it (REQ-400,
  `docs/migration/decisions/0039-platform-module-solution-layering.md` D4;
  design `lib/letflow/design/req400-module-behaviour-catalog.md` §2/§3).

  ## File placement (D3)

  `lib/letflow/modules/catalog.ex`, one level, no subdirectory — the **only**
  core file D3 permits to reference a file inside a `lib/letflow/modules/<id>/`
  directory. This module names a concrete module only via the compiled
  `config :letflow, :modules` list below — never by building a module name
  from a string (D3's xref limitation; `mix letflow.check_boundaries`,
  REQ-405, will encode this exception, not built here).

  ## Why this is a plain module, not a process (AC4)

  No long-running OTP server process, no started/registered process of any
  kind, no supervision-tree entry, no ETS table. `Letflow.Engine.create/2`
  already established this precedent for exactly this class of decision
  (REQ-045: "a plain transactional context module... with concurrency
  arbitrated by Postgres row locks, not a supervised process per instance";
  the per-instance supervision module for that subsystem "exists but is
  deliberately empty"). 0039's own REVIEWER sign-off restates it directly
  for this module: "A module is a code boundary, not a process; no module
  gets its own supervision entry unless its own design justifies one
  through the normal gates." `Catalog`'s data (the module list) is fixed at
  compile time via `Application.compile_env/3`; there is no runtime
  mutation and no concurrent-write hazard, so there is no reason for a
  process boundary.

  ## Source of the module list

  Read once at compile time via `Application.compile_env/3` (not
  `Application.get_env/3`) — the module list defines what code exists in the
  running build, not a runtime-togglable flag, so a compile-time read is the
  correct primitive. `config/config.exs` registers `[]` (no real module
  ships in P1); `config/test.exs` registers `[Letflow.Modules.Fixture]` for
  the test env only.

  ## Manifest validation is test-time, not a runtime guard

  None of the functions below perform manifest validation on every call —
  `validate/1`/`validate/2` are ordinary application functions a test calls
  once per manifest at `mix test` time (design §2.3, §3.1). Running the full
  six-rule check on every `fetch/1`/`permissions/0` call would be wasted
  work at request time; the validation test plus 0039's future boundary/CI
  checks (REQ-405) are the enforcement point.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.Module

  @modules Application.compile_env(:letflow, :modules, [])

  @doc "The list of registered entry modules, in config order."
  @spec entry_modules() :: [module()]
  def entry_modules, do: @modules

  @doc "Looks up a registered entry module by its manifest's `:id` string."
  @spec fetch(id :: String.t()) :: {:ok, module()} | {:error, :not_found}
  def fetch(id) do
    case Enum.find(entry_modules(), fn entry_module -> entry_module.manifest().id == id end) do
      nil -> {:error, :not_found}
      entry_module -> {:ok, entry_module}
    end
  end

  @doc """
  The set of `pack_id` values owned by registered modules (REQ-411).

  Used by `POST /api/v1/solution-packs/install` to refuse direct installation
  of a pack that is owned by a registered module (the caller must use the
  module-install route instead).  Returns a `MapSet.t(String.t())`.

  Reads each module's pack.json at call time; modules with `pack: nil` in
  their manifest contribute nothing.  One file-read per module that declares
  a pack — negligible on the admin-only install path.
  """
  @spec module_pack_ids() :: MapSet.t(String.t())
  def module_pack_ids do
    entry_modules()
    |> Enum.flat_map(fn entry_module ->
      case entry_module.manifest().pack do
        nil ->
          []

        pack_path ->
          full_path = Path.join(Application.app_dir(:letflow, "priv"), pack_path)

          with {:ok, contents} <- File.read(full_path),
               {:ok, %{"pack_id" => pack_id}} <- Jason.decode(contents) do
            [pack_id]
          else
            _ -> []
          end
      end
    end)
    |> MapSet.new()
  end

  @doc "The union of every registered module's own declared `:permissions`."
  @spec permissions() :: [atom()]
  def permissions do
    entry_modules()
    |> Enum.flat_map(fn entry_module -> entry_module.manifest().permissions end)
    |> Enum.uniq()
  end

  @doc """
  The union, over every registered module, of that module's own
  `role_grants[role]` — empty list if no module grants anything to `role`.
  """
  @spec role_grants(role :: atom()) :: [atom()]
  def role_grants(role) do
    entry_modules()
    |> Enum.flat_map(fn entry_module ->
      Map.get(entry_module.manifest().role_grants, role, [])
    end)
    |> Enum.uniq()
  end

  @doc """
  Validates `manifest` against the six invariants (design §3.2) using every
  currently-registered module's manifest as the "known set" for the
  set-relative rules (depends_on / uniqueness). Equivalent to
  `validate(manifest, all_manifests())`.
  """
  @spec validate(Module.manifest()) :: :ok | {:error, {atom(), term()}}
  def validate(manifest), do: validate(manifest, all_manifests())

  @doc """
  Validates `manifest` against the six invariants (design §3.2), taking the
  "known set" of manifests explicitly — the set `depends_on`/uniqueness are
  checked against. `manifest` itself is folded into that set implicitly
  (a manifest counts as registered for its own dependents/uniqueness check),
  so callers may pass any set: the real registered set (`all_manifests/0`),
  a pair of deliberately-colliding inline manifests, or the real set with one
  bad inline manifest appended.

  Returns `:ok`, or `{:error, {rule_name, detail}}` naming which of the six
  rules failed:

    * `{:unknown_role, role}` — a `role_grants` key not in
      `Letflow.Api.Authorization.roles/0`.
    * `{:ungranted_permission_declared, permission}` — a `role_grants` value
      containing a permission atom absent from the manifest's own
      `:permissions`.
    * `{:core_permission_collision, permission}` — a `:permissions` atom that
      also appears in `Letflow.Api.Authorization.permissions/0`.
    * `{:unknown_dependency, module_id}` — a `depends_on` entry naming an id
      no manifest in the known set (plus `manifest` itself) carries.
    * `{:duplicate_module_id, module_id}` — more than one manifest in the
      known set (plus `manifest` itself) shares `manifest.id`.
    * `{:undeclared_route_permission, permission}` — a `route_policies` entry
      naming a permission absent from the manifest's own `:permissions`.

  A seventh rule (REQ-496, 0050 D7) runs after those six:

    * `{:invalid_manages_entity_types, value}` — the optional
      `:manages_entity_types` key is present but not a list of distinct
      binaries each matching `^[a-z][a-z0-9_]{0,63}$`. Absent is valid.
  """
  @spec validate(Module.manifest(), [Module.manifest()]) :: :ok | {:error, {atom(), term()}}
  def validate(manifest, known_manifests) do
    with :ok <- validate_role_grants_known(manifest),
         :ok <- validate_granted_permissions_declared(manifest),
         :ok <- validate_no_core_permission_collision(manifest),
         :ok <- validate_depends_on_registered(manifest, known_manifests),
         :ok <- validate_unique_id(manifest, known_manifests),
         :ok <- validate_route_policy_permissions_declared(manifest),
         :ok <- validate_manages_entity_types(manifest) do
      :ok
    end
  end

  @doc "Every currently-registered module's own `manifest/0` return value."
  @spec all_manifests() :: [Module.manifest()]
  def all_manifests, do: Enum.map(entry_modules(), & &1.manifest())

  defp validate_role_grants_known(manifest) do
    roles = Authorization.roles()

    manifest.role_grants
    |> Map.keys()
    |> Enum.find(fn role -> role not in roles end)
    |> case do
      nil -> :ok
      bad_role -> {:error, {:unknown_role, bad_role}}
    end
  end

  defp validate_granted_permissions_declared(manifest) do
    manifest.role_grants
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.find(fn permission -> permission not in manifest.permissions end)
    |> case do
      nil -> :ok
      bad_permission -> {:error, {:ungranted_permission_declared, bad_permission}}
    end
  end

  defp validate_no_core_permission_collision(manifest) do
    # REQ-401: Authorization.permissions/0 now includes every registered
    # module's own permissions (this module's own permissions/0 union folded
    # in); this check must compare against core's permissions alone
    # (Authorization.core_permissions/0), or every module would trivially
    # collide with itself.
    core_permissions = Authorization.core_permissions()

    manifest.permissions
    |> Enum.find(fn permission -> permission in core_permissions end)
    |> case do
      nil -> :ok
      bad_permission -> {:error, {:core_permission_collision, bad_permission}}
    end
  end

  defp validate_depends_on_registered(manifest, known_manifests) do
    known_ids =
      known_manifests
      |> Enum.map(& &1.id)
      |> MapSet.new()
      |> MapSet.put(manifest.id)

    manifest.depends_on
    |> Enum.find(fn dep_id -> dep_id not in known_ids end)
    |> case do
      nil -> :ok
      bad_id -> {:error, {:unknown_dependency, bad_id}}
    end
  end

  defp validate_unique_id(manifest, known_manifests) do
    effective_set =
      if Enum.any?(known_manifests, &(&1.id == manifest.id)) do
        known_manifests
      else
        [manifest | known_manifests]
      end

    if Enum.count(effective_set, &(&1.id == manifest.id)) > 1 do
      {:error, {:duplicate_module_id, manifest.id}}
    else
      :ok
    end
  end

  defp validate_route_policy_permissions_declared(manifest) do
    manifest.route_policies
    |> Enum.find(fn {_method, _path_pattern, permission} ->
      permission not in manifest.permissions
    end)
    |> case do
      nil ->
        :ok

      {_method, _path_pattern, bad_permission} ->
        {:error, {:undeclared_route_permission, bad_permission}}
    end
  end

  defp validate_manages_entity_types(manifest) do
    case Map.fetch(manifest, :manages_entity_types) do
      :error ->
        :ok

      {:ok, names} when is_list(names) ->
        if Enum.all?(names, &ManagedTypes.managed_name?/1) and
             length(Enum.uniq(names)) == length(names) do
          :ok
        else
          {:error, {:invalid_manages_entity_types, names}}
        end

      {:ok, other} ->
        {:error, {:invalid_manages_entity_types, other}}
    end
  end
end
