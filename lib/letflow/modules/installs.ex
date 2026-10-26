defmodule Letflow.Modules.Installs do
  @moduledoc """
  Per-tenant module install/list context (REQ-402, design
  `lib/letflow/design/req402-tenant-modules-install-context.md` §3;
  `docs/migration/decisions/0039-platform-module-solution-layering.md` D5).

  ## File placement (D3)

  `lib/letflow/modules/installs.ex`, one level, no subdirectory — core
  mechanism file, named explicitly in decision 0039 D3.

  ## Tenant scoping (INV-1)

  The tenant is identified ONLY by `opts[:prefix]` — no function here
  accepts a tenant id or schema name as a separate argument
  (`docs/agents/instructions/security-invariants.md` INV-1; AC7's literal
  grep contract: `git grep -nE "def (install|list_installed)\\(" lib/letflow/modules/installs.ex`
  must show no parameter named `tenant_id` or `schema`).

  ## Scope

  `install/3` rejects an unknown module id, a module already installed, and
  a module whose `depends_on` is not fully satisfied; if the manifest names
  a `pack`, installs it through the EXISTING
  `Letflow.Definitions.SolutionPack.install/3` (no second pack installer);
  inserts the `tenant_modules` row; then calls the module's `on_install/3`
  if exported, else its `on_install/2` if exported (never both; decision 0052 D3).

  ## Rationale (decision 0052 D3, GH 2531)

  `opts[:rationale]` is REQUIRED for every install: a non-blank string, the
  installer's own justification, passed VERBATIM to `on_install/3` as
  `ctx.rationale` and from there to `activate_definition/4`'s append-only
  activation trail. Missing, non-string or blank returns
  `{:error, :rationale_required}` before anything is written. The HTTP layer
  never synthesises one; internal non-HTTP callers pass a fixed, reviewed
  constant naming the cause. All of this happens in ONE `Repo.transaction/1` — any step
  failing rolls back every write, including the pack install (design §3.4).

  ## Managed entity types (REQ-496, decision 0050 D7)

  The pack is installed with the module's `Letflow.Entities.ManagedTypes.Owner`,
  built from its compiled manifest by `ManagedTypes.module_owner/1` -- this is the
  ONLY caller of that function and of `SolutionPack.install/4` with an `Owner`.
  Every name the manifest lists in `manages_entity_types` must be among the entity
  definitions the pack inserted, else `{:error, {:pack_install_failed,
  {:managed_type_not_in_pack, name}}}` and everything rolls back.

  ## Ownership stamp (GH #2590 / REQ-501 R2, decision 0054 D6)

  The same `Owner` (`version`, `manifest_hash` filled by `module_owner/1`) makes
  `SolutionPack.install/4` create the pack's PROCESS definitions through
  `Letflow.Definitions.create_owned/3`: each version row is stamped in its INSERT with the
  module id, version, manifest hash and the hash of its graph. This is the ONLY path that
  stamps a row. `tenant_modules.manifest_hash` records the same manifest hash. A module
  installed before R2 has no installed hash (NULL, OQ-R7: no backfill); it is reinstalled or
  upgraded, not reconstructed. Nothing consumes the stamp yet (activation checks are R3).

  OUT OF SCOPE (0039 D5, REQ-402's own BUILDS): installing several modules
  in dependency order in one request (solution install, REQ-415); settings
  writes to an already-installed module (REQ-414); uninstall.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Definitions.SolutionPack
  alias Letflow.Entities.ManagedTypes
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.InstallContext
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @type opts :: [prefix: String.t(), rationale: String.t()]

  @type install_error ::
          {:error, :unknown_module}
          | {:error, :rationale_required}
          | {:error, :already_installed}
          | {:error, {:dependency_not_installed, module_id :: String.t()}}
          | {:error,
             {:pack_install_failed,
              SolutionPack.install_error() | {:managed_type_not_in_pack, String.t()}}}
          | {:error, {:on_install_failed, term()}}
          | {:error, :module_install_ddl_failed}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Every module currently installed in the tenant identified by
  `opts[:prefix]`, ordered by `installed_at` ascending. Raises if `:prefix`
  is missing from `opts` — a tenant-scoped call with no prefix is a
  programmer error, not a runtime `{:error, ...}` case.
  """
  @spec list_installed(opts()) :: [TenantModule.t()]
  def list_installed(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    Repo.all(from(m in TenantModule, order_by: [asc: m.installed_at]), prefix: prefix)
  end

  @doc """
  Installs `module_id` into the tenant identified by `opts[:prefix]`, as
  `actor_id`. See moduledoc and design §3.3/§3.4 for the full transaction
  structure and rollback semantics.
  """
  @spec install(module_id :: String.t(), actor_id :: Ecto.UUID.t(), opts()) ::
          {:ok, TenantModule.t()} | install_error()
  def install(module_id, actor_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, rationale} <- fetch_rationale(opts),
         {:ok, entry_module} <- fetch_module(module_id) do
      owner = ManagedTypes.module_owner(entry_module)

      install_transaction(module_id, fn ->
        with :ok <- check_not_already_installed(module_id, prefix),
             :ok <- check_dependencies_installed(entry_module, prefix),
             {:ok, pack_entity_definition_ids} <-
               maybe_install_pack(entry_module, actor_id, opts, owner),
             :ok <- check_managed_types_in_pack(owner, pack_entity_definition_ids),
             {:ok, tenant_module} <- insert_tenant_module(entry_module, owner, prefix),
             ctx = %InstallContext{
               actor_id: actor_id,
               rationale: rationale,
               tenant_prefix: prefix,
               pack_entity_definition_ids: pack_entity_definition_ids
             },
             :ok <- maybe_run_on_install(entry_module, prefix, tenant_module.settings, ctx) do
          tenant_module
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # GH #2540: a database error raised by DDL (column promotion, entity table creation)
  # inside the install transaction, or reported by the promotion as `{:ddl_failed, _}`,
  # becomes the typed `:module_install_ddl_failed`. The transaction has already rolled back
  # every write. Logged once here, with the trace id from the Logger metadata, the module id
  # and the SQLSTATE only: never the exception message (it can carry SQL, schema and
  # table names) and never record values (INV-8).
  defp install_transaction(module_id, fun) do
    case Repo.transaction(fun) do
      {:error, {:on_install_failed, {:promotion_failed, _type, _attribute, {:ddl_failed, error}}}} ->
        ddl_failed(module_id, error)

      result ->
        result
    end
  rescue
    error in Postgrex.Error -> ddl_failed(module_id, error)
  end

  defp ddl_failed(module_id, error) do
    Logger.error(
      "module install failed: database error during DDL " <>
        "(trace_id=#{Logger.metadata()[:trace_id]} module_id=#{module_id} sqlstate=#{sqlstate(error)})"
    )

    {:error, :module_install_ddl_failed}
  end

  defp sqlstate(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp sqlstate(_other), do: :unknown

  @doc """
  Whether `module_id` is installed for the tenant identified by
  `opts[:prefix]` (REQ-404, design
  `lib/letflow/design/req404-module-router-mount.md` §2) -- backs
  `Letflow.Routers.Modules`' D5 install gate. Raises if `:prefix` is
  missing from `opts`, the same "programmer error, not a runtime
  `{:error, ...}` case" convention `list_installed/1` already uses.

  A single indexed-lookup `Repo.exists?/2` query, the same shape
  `install/3`'s own internal dependency check already uses (see
  `module_installed?/2` below) -- not `list_installed/1` + membership check,
  which would load every installed row just to answer a boolean.
  """
  @spec installed?(module_id :: String.t(), opts()) :: boolean()
  def installed?(module_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    module_installed?(module_id, prefix)
  end

  @doc """
  Creates the pack's entity definition `name` (inactive, stamped with the module's `managed_by`)
  in a tenant that has `module_id` installed but lacks it (REQ-582; used by
  `Letflow.Entities.ManagedTypes.AssignmentDefinition`). Writes no `tenant_modules` or
  `solution_pack_installs` row and never activates. `name` must be one of the manifest's
  `manages_entity_types`. Schema source: `opts[:prefix]` only (INV-1). The caller owns the
  surrounding transaction (this opens a nested one, which joins it).
  """
  @spec ensure_pack_entity_definition(
          module_id :: String.t(),
          name :: String.t(),
          actor_id :: Ecto.UUID.t(),
          opts()
        ) :: {:ok, Letflow.Entities.EntityDefinition.t()} | {:error, term()}
  def ensure_pack_entity_definition(module_id, name, actor_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, entry_module} <- fetch_module(module_id),
         true <- module_installed?(module_id, prefix) or {:error, :module_not_installed},
         manifest = entry_module.manifest(),
         true <- name in manifest.manages_entity_types or {:error, :not_a_managed_type},
         pack_path when is_binary(pack_path) <- manifest.pack || {:error, :not_a_managed_type},
         {:ok, document} <- read_pack_document(pack_path),
         owner = ManagedTypes.module_owner(entry_module),
         {:ok, [created]} <-
           SolutionPack.install_entity_definitions(document, [name], actor_id, opts, owner) do
      {:ok, created}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Updates the `settings` of the installed module identified by `module_id`
  in the tenant identified by `opts[:prefix]` (REQ-414).

  Validation order:
  1. Module must be known to `Catalog` — if not, `{:error, {:module_not_installed, module_id}}`.
  2. `settings` must conform to the manifest's `settings_schema`:
     - If `settings_schema` is `nil`, only `%{}` (an empty map) is accepted;
       any non-empty map returns `{:error, {:settings_validation_failed, :no_schema}}`.
     - If `settings_schema` is a map, validates with the existing
       `Letflow.EventStore.Registry.JsonSchema.validate/2`; any violations
       return `{:error, {:settings_validation_failed, violations}}`.
  3. A `tenant_modules` row must exist for `module_id` in the tenant schema —
     if not, `{:error, {:module_not_installed, module_id}}`.
  4. The row's `settings` field is updated.

  Schema source: `opts[:prefix]` only (INV-1) — never a body field.
  """
  @spec put_settings(String.t(), map(), opts()) ::
          {:ok, TenantModule.t()}
          | {:error, {:module_not_installed, String.t()}}
          | {:error, {:settings_validation_failed, term()}}
  def put_settings(module_id, settings, opts \\ []) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, entry_module} <- fetch_module_for_settings(module_id),
         :ok <- validate_settings(settings, entry_module.manifest().settings_schema),
         {:ok, tenant_module} <- fetch_tenant_module_row(module_id, prefix) do
      tenant_module
      |> TenantModule.settings_changeset(%{settings: settings})
      |> Repo.update(prefix: prefix)
    end
  end

  @doc """
  The manifest hash recorded when `module_id` was installed in the tenant identified by
  `opts[:prefix]` (GH #2590 / REQ-501 R2).

  `{:error, :not_installed}` when no `tenant_modules` row exists, and
  `{:error, :no_installed_hash}` when the row predates the column (OQ-R7: no backfill, so
  such a module has no installed hash until it is reinstalled or upgraded). Nothing in core
  consumes it yet; the activation check (R3) and the run-time check (R4) are its readers.
  Raises without `:prefix`, like `list_installed/1`.
  """
  @spec installed_manifest_hash(module_id :: String.t(), opts()) ::
          {:ok, String.t()} | {:error, :not_installed | :no_installed_hash}
  def installed_manifest_hash(module_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get_by(TenantModule, [module_id: module_id], prefix: prefix) do
      nil -> {:error, :not_installed}
      %TenantModule{manifest_hash: hash} when is_binary(hash) -> {:ok, hash}
      %TenantModule{manifest_hash: nil} -> {:error, :no_installed_hash}
    end
  end

  defp fetch_module_for_settings(module_id) do
    case Catalog.fetch(module_id) do
      {:ok, entry_module} -> {:ok, entry_module}
      {:error, :not_found} -> {:error, {:module_not_installed, module_id}}
    end
  end

  # nil schema: only accept an empty settings map.
  defp validate_settings(settings, nil) when map_size(settings) == 0, do: :ok
  defp validate_settings(_settings, nil), do: {:error, {:settings_validation_failed, :no_schema}}

  # Non-nil schema: delegate to the existing JSON Schema validator.
  defp validate_settings(settings, schema) do
    case JsonSchema.validate(settings, schema) do
      [] -> :ok
      failures -> {:error, {:settings_validation_failed, failures}}
    end
  end

  defp fetch_tenant_module_row(module_id, prefix) do
    case Repo.get_by(TenantModule, [module_id: module_id], prefix: prefix) do
      nil -> {:error, {:module_not_installed, module_id}}
      %TenantModule{} = tm -> {:ok, tm}
    end
  end

  defp fetch_module(module_id) do
    case Catalog.fetch(module_id) do
      {:ok, entry_module} -> {:ok, entry_module}
      {:error, :not_found} -> {:error, :unknown_module}
    end
  end

  defp check_not_already_installed(module_id, prefix) do
    case Repo.get_by(TenantModule, [module_id: module_id], prefix: prefix) do
      nil -> :ok
      %TenantModule{} -> {:error, :already_installed}
    end
  end

  defp check_dependencies_installed(entry_module, prefix) do
    entry_module.manifest().depends_on
    |> Enum.find(fn dep_id -> not module_installed?(dep_id, prefix) end)
    |> case do
      nil -> :ok
      missing_dep_id -> {:error, {:dependency_not_installed, missing_dep_id}}
    end
  end

  # Shared by check_dependencies_installed/2 (install/3's own dependency
  # check) and the public installed?/2 above -- both ask the identical
  # question ("does a tenant_modules row for this module_id exist in this
  # tenant's schema?"), so both share this one query shape.
  defp module_installed?(module_id, prefix) do
    Repo.exists?(from(m in TenantModule, where: m.module_id == ^module_id), prefix: prefix)
  end

  # Returns the entity definitions THIS install's pack inserted, `%{name => id}`
  # (0052 D6: on_install/3 may activate only these; empty without a pack).
  defp maybe_install_pack(entry_module, actor_id, opts, owner) do
    case entry_module.manifest().pack do
      nil ->
        {:ok, %{}}

      pack_path ->
        with {:ok, document} <- read_pack_document(pack_path),
             {:ok, install_result} <- SolutionPack.install(document, actor_id, opts, owner) do
          {:ok,
           Map.new(install_result.installed_entity_definitions, fn installed ->
             {installed.name, installed.new_entity_definition_id}
           end)}
        else
          {:error, reason} -> {:error, {:pack_install_failed, reason}}
        end
    end
  end

  # REQ-496 (design §2.7): a declared managed type the pack did not insert (or any
  # declared type when the module has no pack) fails the install. Sorted, so the
  # reported name is deterministic.
  defp check_managed_types_in_pack(owner, pack_entity_definition_ids) do
    owner.manages
    |> Enum.sort()
    |> Enum.find(&(not Map.has_key?(pack_entity_definition_ids, &1)))
    |> case do
      nil -> :ok
      name -> {:error, {:pack_install_failed, {:managed_type_not_in_pack, name}}}
    end
  end

  defp read_pack_document(pack_path) do
    path = Path.join(Application.app_dir(:letflow, "priv"), pack_path)

    with {:ok, contents} <- File.read(path) do
      Jason.decode(contents)
    end
  end

  # The manifest hash recorded here is the SAME value the pack's process definitions were
  # stamped with (`owner.manifest_hash`: one `Catalog.manifest_hash/1` call per install).
  defp insert_tenant_module(entry_module, owner, prefix) do
    attrs = %{
      module_id: entry_module.manifest().id,
      version: entry_module.manifest().version,
      installed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
      settings: %{},
      manifest_hash: owner.manifest_hash
    }

    %TenantModule{}
    |> TenantModule.insert_changeset(attrs)
    |> Repo.insert(prefix: prefix)
  end

  @doc """
  Decision 0052 D3: the install rationale from `opts`, verbatim once it is known to be non-blank. Shared with
  `Letflow.Modules.Solutions.install/3`, which checks it before installing any
  module so a solution install with no rationale writes nothing.
  """
  @spec fetch_rationale(keyword()) :: {:ok, String.t()} | {:error, :rationale_required}
  def fetch_rationale(opts) do
    case Keyword.get(opts, :rationale) do
      rationale when is_binary(rationale) ->
        case String.trim(rationale) do
          "" -> {:error, :rationale_required}
          _non_blank -> {:ok, rationale}
        end

      _other ->
        {:error, :rationale_required}
    end
  end

  # 0052 D3: `on_install/3` is preferred; a module exporting both arities runs ONLY /3.
  defp maybe_run_on_install(entry_module, prefix, settings, ctx) do
    result =
      cond do
        function_exported?(entry_module, :on_install, 3) ->
          entry_module.on_install(prefix, settings, ctx)

        function_exported?(entry_module, :on_install, 2) ->
          entry_module.on_install(prefix, settings)

        true ->
          :ok
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:on_install_failed, reason}}
    end
  end
end
