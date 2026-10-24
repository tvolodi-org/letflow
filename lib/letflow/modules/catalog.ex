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
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Modules.ManifestHash
  alias Letflow.Modules.Module
  alias Letflow.Modules.WriteHandlerSpec

  @modules Application.compile_env(:letflow, :modules, [])

  @name_format ~r/\A[a-z][a-z0-9_]{0,63}\z/

  defmodule WriteHandler do
    @moduledoc """
    A write handler a module registered in its manifest (`:write_handlers`),
    as resolved by `Letflow.Modules.Catalog.write_handler/2` (GH #2590 /
    REQ-501 R1). Built only inside `catalog.ex`; every other file receives
    one from `Catalog` and never constructs one.

    The struct is an UNTRUSTED descriptor: it carries no function to call, and
    `Catalog.call_write_handler/4` re-resolves by `module_id` and `name`, so
    every other field (`entry_module`, `targets`, `args`) of a forged value is
    ignored there. Consumers that need the targets re-resolve through
    `Catalog.write_handler/2`. The manifest entry is a `Letflow.Modules.WriteHandlerSpec`
    struct.
    """

    @enforce_keys [:module_id, :name, :entry_module, :targets, :args]
    defstruct [:module_id, :name, :entry_module, :targets, :args]

    @type t :: %__MODULE__{
            module_id: String.t(),
            name: String.t(),
            entry_module: module(),
            targets: [String.t()],
            args: %{String.t() => %{required: boolean()}}
          }
  end

  @doc "The list of registered entry modules, in config order."
  @spec entry_modules() :: [module()]
  def entry_modules, do: @modules

  @doc """
  Every entity-type name declared in some registered module's `manages_entity_types`
  (GH #2581), as `%{name => module_id}`. If two modules declare one name the lowest
  `module_id` wins, only to be deterministic. Pure: reads the compiled manifests.
  """
  @spec managed_name_declarations() :: %{String.t() => String.t()}
  def managed_name_declarations do
    entry_modules()
    |> Enum.map(& &1.manifest())
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.reduce(%{}, fn manifest, acc ->
      manifest
      |> Map.get(:manages_entity_types, [])
      |> Enum.reduce(acc, fn name, inner -> Map.put(inner, name, manifest.id) end)
    end)
  end

  @doc """
  Creates a record of an entity type that a module manages (GH #2680 slice 3) through that module's
  own authoring surface: a system path with no HTTP user, for the mix seed task. A type with no
  authoring surface returns `:not_managed`, and the caller writes it on the generic path.
  Request paths must not call this: they use the module's HTTP routes, which check the caller.
  """
  @spec create_via_module_surface(Letflow.Entities.Records.create_attrs(), prefix :: String.t()) ::
          :not_managed | {:ok, term()} | {:error, term()}
  def create_via_module_surface(%{entity_type: entity_type} = attrs, prefix) do
    if entity_type in Letflow.Modules.Exam.Authoring.authoring_types(),
      do: Letflow.Modules.Exam.Authoring.create(attrs, prefix),
      else: :not_managed
  end

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

  @doc """
  Resolves a registered write handler by module id and handler name
  (GH #2590 / REQ-501 R1, design section 4.1, D-R.1/D-R.2).

  Resolution is binary comparison against the compiled manifest list only:
  a non-binary argument, an unknown module or an unknown handler answers
  `{:error, :not_found}`; no atom is ever created from the arguments
  (`String.to_atom`, `Module.concat`, `binary_to_term` are not used).

  `validate/2` runs only in tests and the mix task, so resolution RE-CHECKS
  the whole write-handler registration of the module on every call (shape,
  names, targets within that manifest's `manages_entity_types`, handler
  module within the entry module's namespace, `function_exported?/3`);
  any failure is `{:error, :not_found}` (fail closed, no distinct code).
  """
  @spec write_handler(module_id :: term(), name :: term()) ::
          {:ok, WriteHandler.t()} | {:error, :not_found}
  def write_handler(module_id, name), do: write_handler_in(entry_modules(), module_id, name)

  @doc false
  # Same as write_handler/2 over an explicit entry-module list: the seam the
  # F-6 tests use to resolve against a manifest that never went through
  # validate/2 (the compiled list is fixed at compile time).
  @spec write_handler_in([module()], term(), term()) ::
          {:ok, WriteHandler.t()} | {:error, :not_found}
  def write_handler_in(entries, module_id, name) do
    case resolve_write_handler(entries, module_id, name) do
      {:ok, handler, _function} -> {:ok, handler}
      :error -> {:error, :not_found}
    end
  end

  # Exactly one entry may carry the id (a duplicated id is ambiguous: fail
  # closed rather than pick the first); then the whole registration of that
  # module is re-validated; then the name is looked up. The function to call is
  # returned beside the descriptor and never stored in it.
  defp resolve_write_handler(entries, module_id, name)
       when is_list(entries) and is_binary(module_id) and is_binary(name) do
    with [entry] <-
           Enum.filter(entries, fn entry_module -> entry_module.manifest().id == module_id end),
         manifest = entry.manifest(),
         :ok <- validate_write_handlers(manifest, entry),
         spec when not is_nil(spec) <-
           Enum.find(Map.get(manifest, :write_handlers, []), &(&1.name == name)) do
      {:ok,
       %WriteHandler{
         module_id: module_id,
         name: name,
         entry_module: entry,
         targets: Enum.sort(spec.targets),
         args: spec.args
       }, spec.function}
    else
      _ -> :error
    end
  end

  defp resolve_write_handler(_entries, _module_id, _name), do: :error

  @doc """
  Calls a registered write handler: `apply/3` of the handler function the
  Catalog itself resolved (the only `apply` of handler code). The struct's
  `module_id`/`name` are re-resolved here and every other field of it is
  ignored. Returns the handler's raw return (the caller validates the shape),
  or `{:error, :not_found}` when the registration no longer resolves. No
  caller exists in R1.
  """
  @spec call_write_handler(WriteHandler.t(), Ecto.Multi.t(), ctx :: struct(), args :: map()) ::
          term()
  def call_write_handler(%WriteHandler{module_id: module_id, name: name}, multi, ctx, args) do
    case resolve_write_handler(entry_modules(), module_id, name) do
      {:ok, _handler, {module, fun}} -> apply(module, fun, [multi, ctx, args])
      :error -> {:error, :not_found}
    end
  end

  @doc """
  The SHA-256 manifest hash (`Letflow.Modules.ManifestHash`) of a registered
  entry module (by module atom) or of the module with the given manifest id.
  Computed per call from the compiled manifest; no state is kept.
  """
  @spec manifest_hash(entry_module :: module() | String.t()) ::
          {:ok, String.t()} | {:error, :not_found}
  def manifest_hash(id) when is_binary(id) do
    case fetch(id) do
      {:ok, entry_module} -> manifest_hash(entry_module)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def manifest_hash(entry_module) when is_atom(entry_module) do
    if entry_module in entry_modules() do
      {:ok, ManifestHash.compute(entry_module.manifest())}
    else
      {:error, :not_found}
    end
  end

  def manifest_hash(_other), do: {:error, :not_found}

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

  Rules seven to nine run after those six, in this order:

    * `{:invalid_manages_entity_types, value}` — rule 7 (REQ-496, 0050 D7):
      the optional `:manages_entity_types` key is present but not a list of
      distinct binaries each matching `^[a-z][a-z0-9_]{0,63}$`. Absent is
      valid.
    * rule 8 (GH #2586 / REQ-498, decision 0055 D7): the optional
      `:widens_grants` key, a list of `{role, permission}` declarations of a
      NARROWING (a role losing a module atom) between two versions of this
      module. Absent is valid. Errors, first one returned:
      `{:invalid_widens_grants, value}` (not a list, or an element not a
      2-tuple; `value` is the whole key value),
      `{:unknown_widens_grants_role, role}` (first element not in
      `Letflow.Api.Authorization.roles/0`),
      `{:invalid_widens_grants_permission, permission}` (second element not an
      atom). Deliberately not checked: that the permission is in this
      manifest's own `:permissions` (a narrowing may remove the atom), and
      duplicates. The declaration is informational only: it can match a
      narrowing in `mix letflow.permission_matrix --check`, never authorise a
      widening (`Letflow.Api.PermissionMatrix`).
    * `{:permission_declared_by_other_module, permission, other_id}` — rule 9
      (GH #2586 F4): an atom in this manifest's `:permissions` that another
      manifest of the known set (a different `id`) also declares. Checked
      against the raw per-manifest lists, not `permissions/0` (which
      deduplicates); first offending atom in this manifest's order, first
      other manifest in known-set order.

  Rule 10 (GH #2590 / REQ-501 R1, design section 4.1) runs last: the optional
  `:write_handlers` key, a list of `Letflow.Modules.WriteHandlerSpec` structs
  (`name`, `function: {Mod, :fun}`, `targets`, `args`). Absent or `[]` is valid. Errors, first one returned:

    * `{:invalid_write_handlers, value}` - not a list of valid
      `WriteHandlerSpec` structs (a plain map is refused), a name outside `^[a-z][a-z0-9_]{0,63}$`, `targets` not a list
      of distinct binaries, `args` not `%{binary => %{required: boolean}}`, or
      `function` not a `{module, function}` atom pair.
    * `{:duplicate_write_handler, name}`.
    * `{:invalid_module_id_for_handlers, id}` - the manifest `id` outside the
      name format while handlers are declared.
    * `{:write_handler_without_managed_types, name}` - no (or empty)
      `:manages_entity_types`.
    * `{:write_handler_no_targets, name}`.
    * `{:write_handler_target_not_managed, name, target}` - target absent from
      this manifest's own `:manages_entity_types`.
    * `{:write_handler_outside_module, name}` - the handler module is not
      strictly nested under the namespace of the registered entry module
      carrying this manifest (the entry module itself is refused) (also when no registered module carries the manifest).
    * `{:write_handler_function_not_exported, name}` - not loadable, or no
      exported arity-3 function.

  Rule 11 (REQ-518) runs after rule 10: the optional `:scope_declarations` key. Errors:
  `{:invalid_scope_declarations, value}` (not a map of managed-format names to
  `{:column, field}` or `:tenant_wide`), `{:scope_declaration_unmanaged_type, name}` (a key not
  in the same manifest's `:manages_entity_types`, unless the module id is on the test-only
  `:scope_declaration_unmanaged_modules` allowlist), `{:duplicate_scope_declaration, name}`
  (another known manifest declares the same type). Absent is valid.
  """
  @spec validate(Module.manifest(), [Module.manifest()]) :: :ok | {:error, {atom(), term()}}
  def validate(manifest, known_manifests) do
    # Rule 10 needs the entry module (handler namespace, function_exported?/3);
    # a manifest no registered module carries has none and fails closed there.
    entry_module =
      Enum.find(entry_modules(), fn entry -> entry.manifest().id == Map.get(manifest, :id) end)

    with :ok <- validate_role_grants_known(manifest),
         :ok <- validate_granted_permissions_declared(manifest),
         :ok <- validate_no_core_permission_collision(manifest),
         :ok <- validate_depends_on_registered(manifest, known_manifests),
         :ok <- validate_unique_id(manifest, known_manifests),
         :ok <- validate_route_policy_permissions_declared(manifest),
         :ok <- validate_manages_entity_types(manifest),
         :ok <- validate_widens_grants(manifest),
         :ok <- validate_permissions_not_declared_elsewhere(manifest, known_manifests),
         :ok <- validate_write_handlers(manifest, entry_module),
         :ok <- validate_scope_declarations(manifest, known_manifests) do
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

  # Rule 8 (GH #2586 / REQ-498, design gh2586-permission-matrix-golden.md section 7).
  defp validate_widens_grants(manifest) do
    case Map.fetch(manifest, :widens_grants) do
      :error ->
        :ok

      {:ok, entries} ->
        if is_list(entries) and Enum.all?(entries, &match?({_, _}, &1)) do
          validate_widens_grants_entries(entries)
        else
          {:error, {:invalid_widens_grants, entries}}
        end
    end
  end

  defp validate_widens_grants_entries(entries) do
    roles = Authorization.roles()

    cond do
      bad = Enum.find(entries, fn {role, _} -> role not in roles end) ->
        {:error, {:unknown_widens_grants_role, elem(bad, 0)}}

      bad = Enum.find(entries, fn {_, permission} -> not is_atom(permission) end) ->
        {:error, {:invalid_widens_grants_permission, elem(bad, 1)}}

      true ->
        :ok
    end
  end

  # Rule 9 (GH #2586 F4): raw per-manifest lists, never permissions/0 (Enum.uniq/1).
  defp validate_permissions_not_declared_elsewhere(manifest, known_manifests) do
    others = Enum.reject(known_manifests, &(&1.id == manifest.id))

    Enum.find_value(manifest.permissions, :ok, fn permission ->
      case Enum.find(others, &(permission in &1.permissions)) do
        nil -> nil
        other -> {:error, {:permission_declared_by_other_module, permission, other.id}}
      end
    end)
  end

  # Rule 11 (REQ-518 / GH #2535, design req518-compiler-scope-filter.md 3.2, SEC ruling R-3).
  # The optional `:scope_declarations` key: `%{type_name => {:column, field} | :tenant_wide}`.
  # Every key is a managed-name-format name that the SAME manifest lists in
  # `:manages_entity_types` -- except for a module id on the test-only allowlist
  # `:scope_declaration_unmanaged_modules` (set in config/test.exs only). A type declared by
  # two manifests is a duplicate.
  defp validate_scope_declarations(manifest, known_manifests) do
    case Map.fetch(manifest, :scope_declarations) do
      :error ->
        :ok

      {:ok, decls} when is_map(decls) and not is_struct(decls) ->
        with :ok <- check_scope_declaration_entries(manifest, decls) do
          check_scope_declaration_duplicates(manifest, decls, known_manifests)
        end

      {:ok, other} ->
        {:error, {:invalid_scope_declarations, other}}
    end
  end

  defp check_scope_declaration_entries(manifest, decls) do
    managed = Map.get(manifest, :manages_entity_types, [])

    allowlisted? =
      Map.get(manifest, :id) in Application.get_env(
        :letflow,
        :scope_declaration_unmanaged_modules,
        []
      )

    Enum.find_value(decls, :ok, fn {name, decl} ->
      cond do
        not (ManagedTypes.managed_name?(name) and ScopeDeclaration.valid_declaration?(decl)) ->
          {:error, {:invalid_scope_declarations, decls}}

        not allowlisted? and name not in managed ->
          {:error, {:scope_declaration_unmanaged_type, name}}

        true ->
          nil
      end
    end)
  end

  defp declares_scope_type?(manifest, name) do
    case Map.get(manifest, :scope_declarations, %{}) do
      decls when is_map(decls) -> Map.has_key?(decls, name)
      _not_a_map -> false
    end
  end

  defp check_scope_declaration_duplicates(manifest, decls, known_manifests) do
    others = Enum.reject(known_manifests, &(&1.id == manifest.id))

    Enum.find_value(Map.keys(decls), :ok, fn name ->
      if Enum.any?(others, &declares_scope_type?(&1, name)),
        do: {:error, {:duplicate_scope_declaration, name}}
    end)
  end

  # Rule 10 (GH #2590 / REQ-501 R1). Shared by validate/2 and the per-call
  # re-check in write_handler_in/3 (F-6); `entry_module` may be nil.
  defp validate_write_handlers(manifest, entry_module) do
    case Map.get(manifest, :write_handlers, []) do
      [] ->
        :ok

      handlers ->
        with :ok <- check_handler_shapes(handlers),
             :ok <- check_handler_names_unique(handlers),
             :ok <- check_handler_module_id(manifest),
             :ok <- check_handler_managed_types(manifest, handlers) do
          check_handler_targets_and_code(manifest, handlers, entry_module)
        end
    end
  end

  defp check_handler_shapes(handlers) do
    if is_list(handlers) and Enum.all?(handlers, &well_formed_handler?/1) do
      :ok
    else
      {:error, {:invalid_write_handlers, handlers}}
    end
  end

  defp well_formed_handler?(handler), do: WriteHandlerSpec.valid?(handler)

  defp check_handler_names_unique(handlers) do
    names = Enum.map(handlers, & &1.name)

    case Enum.find(names, fn name -> Enum.count(names, &(&1 == name)) > 1 end) do
      nil -> :ok
      name -> {:error, {:duplicate_write_handler, name}}
    end
  end

  defp check_handler_module_id(manifest) do
    id = Map.get(manifest, :id)

    if is_binary(id) and Regex.match?(@name_format, id) do
      :ok
    else
      {:error, {:invalid_module_id_for_handlers, id}}
    end
  end

  defp check_handler_managed_types(manifest, [first | _]) do
    case Map.get(manifest, :manages_entity_types) do
      [_ | _] -> :ok
      _ -> {:error, {:write_handler_without_managed_types, first.name}}
    end
  end

  defp check_handler_targets_and_code(manifest, handlers, entry_module) do
    managed = Map.fetch!(manifest, :manages_entity_types)

    Enum.find_value(handlers, :ok, fn handler ->
      {module, fun} = handler.function

      cond do
        handler.targets == [] ->
          {:error, {:write_handler_no_targets, handler.name}}

        bad = Enum.find(handler.targets, &(&1 not in managed)) ->
          {:error, {:write_handler_target_not_managed, handler.name, bad}}

        not in_module_namespace?(module, entry_module) ->
          {:error, {:write_handler_outside_module, handler.name}}

        not (Code.ensure_loaded?(module) and function_exported?(module, fun, 3)) ->
          {:error, {:write_handler_function_not_exported, handler.name}}

        true ->
          nil
      end
    end)
  end

  defp in_module_namespace?(_module, nil), do: false

  defp in_module_namespace?(module, entry_module) do
    # strictly nested: the entry module itself is refused (it exports
    # on_install/3, which would pass the arity-3 check)
    String.starts_with?(Atom.to_string(module), Atom.to_string(entry_module) <> ".")
  end
end
