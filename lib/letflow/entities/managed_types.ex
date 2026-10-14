defmodule Letflow.Entities.ManagedTypes do
  @moduledoc """
  The `managed_by` write lock on entity types (REQ-496, decision 0050 D7; design
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §2.3-§2.5).

  A type NAME is managed by module M iff at least one `entity_definitions` row of
  that name has `managed_by = M` (design D2). The stamp is written only at insert,
  by `Letflow.Entities.Definitions.create_definition/3` when the caller passes an
  `Owner` whose `manages` set names the type, and the DB trigger keeps it
  immutable (D3).

  ## Who may hold an `Owner` (design D5, §3.5)

  An `Owner` is built only by `module_owner/1`, from a Catalog entry module's
  compiled manifest, and only `Letflow.Modules.Installs.install/3` calls it. No
  request field, header, opts key or pack key can produce one: the HTTP routers
  call the arities that hard-code `:tenant`. `mix letflow.check_boundaries` cannot
  express a per-function caller allow-list, so this restriction is pinned by a
  textual test instead (T-34): `module_owner(` appears only here and in
  `installs.ex`, and the `Owner` struct is constructed only here.

  ## Name format

  Every managed name matches `^[a-z][a-z0-9_]{0,63}$` (`Catalog.validate/2` rule 7).
  So a name failing the format can never be managed, and `owner_of/2` answers
  `:unmanaged` for it without a query.

  ## Advisory-lock namespaces

  Creates of one (tenant, name) are serialised by the transaction-scoped two-int4
  advisory lock `pg_advisory_xact_lock(496_001, hashtext("<tenant_id>:<name>"))`.
  Two-int4 keys live in a key space separate from single-bigint keys
  (`hashtext(schema_name)` in `Letflow.TenantProvisioning`, the tenant-template lock,
  the tenant-admin grant key), and within the two-int4 space the only other class id
  in use is `435_001` (`Letflow.LoginDirectory`'s `@lock_namespace`). A `hashtext`
  collision between two names only serialises them; it never wrongly allows.
  """

  import Ecto.Query

  alias Letflow.Entities.EntityDefinition
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  # Two-int4 advisory-lock class id; see the moduledoc for the other namespaces.
  @create_lock_namespace 496_001

  @managed_name_format ~r/^[a-z][a-z0-9_]{0,63}$/

  defmodule Owner do
    @moduledoc """
    A module's ownership claim, built only by
    `Letflow.Entities.ManagedTypes.module_owner/1` from a compiled manifest.
    """
    @enforce_keys [:module_id, :manages]
    defstruct [:module_id, :manages]

    @type t :: %__MODULE__{module_id: String.t(), manages: MapSet.t(String.t())}
  end

  @type owner :: :tenant | Owner.t()

  @doc """
  Builds the `Owner` for a Catalog entry module from its compiled manifest:
  `module_id` is the manifest `:id`, `manages` its `:manages_entity_types` (absent
  means none). Only `Letflow.Modules.Installs.install/3` may call this.
  """
  @spec module_owner(entry_module :: module()) :: Owner.t()
  def module_owner(entry_module) when is_atom(entry_module) do
    manifest = entry_module.manifest()

    %Owner{
      module_id: manifest.id,
      manages: MapSet.new(Map.get(manifest, :manages_entity_types, []))
    }
  end

  @doc "True when `name` is a binary in the managed-name format `^[a-z][a-z0-9_]{0,63}$`."
  @spec managed_name?(term()) :: boolean()
  def managed_name?(name) when is_binary(name), do: Regex.match?(@managed_name_format, name)
  def managed_name?(_name), do: false

  @doc """
  The module that manages entity type `name` in the tenant schema `prefix`, or
  `:unmanaged`. A name failing the managed-name format is `:unmanaged` without a
  query.
  """
  @spec owner_of(name :: String.t(), prefix :: String.t()) ::
          {:ok, module_id :: String.t()} | :unmanaged | {:error, :invalid_schema_name}
  def owner_of(name, prefix) when is_binary(prefix) do
    if managed_name?(name) do
      with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
        query =
          from(e in EntityDefinition,
            where: e.tenant_id == ^tenant_id and e.name == ^name and not is_nil(e.managed_by),
            select: e.managed_by,
            limit: 1
          )

        case Repo.one(query, prefix: prefix) do
          nil -> :unmanaged
          module_id -> {:ok, module_id}
        end
      end
    else
      :unmanaged
    end
  end

  @doc """
  The tenant-route check (design D6): `{:error, :entity_type_managed}` when `name`
  is managed by any module, `:ok` otherwise. Generic record and entity-definition
  write routes call it before reading anything else of the request.
  """
  @spec check_tenant_write(name :: String.t(), prefix :: String.t()) ::
          :ok | {:error, :entity_type_managed} | {:error, :invalid_schema_name}
  def check_tenant_write(name, prefix) do
    case owner_of(name, prefix) do
      {:ok, _module_id} -> {:error, :entity_type_managed}
      :unmanaged -> :ok
      {:error, :invalid_schema_name} = error -> error
    end
  end

  @doc """
  Decides whether `owner` may create a new version of entity type `name` and which
  stamp the new row gets (design §2.4's table): `{:ok, module_id}` stamps it,
  `{:ok, nil}` leaves it unmanaged. A non-binary `name` is `{:ok, nil}` (the
  Validator rejects it later).

  Must run inside the transaction that already holds `name`'s advisory lock
  (`lock_names/2`). `owner` is `:tenant` or an `%Owner{}` struct; any other term
  raises `FunctionClauseError` (a programmer error, never request data).
  """
  @spec check_create(name :: term(), owner(), prefix :: String.t()) ::
          {:ok, stamp :: String.t() | nil}
          | {:error, :entity_type_managed}
          | {:error, {:managed_name_taken, String.t()}}
          | {:error, :invalid_schema_name}
  def check_create(name, :tenant, prefix) when is_binary(prefix) do
    if is_binary(name) do
      case owner_of(name, prefix) do
        {:ok, _module_id} -> {:error, :entity_type_managed}
        :unmanaged -> {:ok, nil}
        {:error, :invalid_schema_name} = error -> error
      end
    else
      {:ok, nil}
    end
  end

  def check_create(name, %Owner{module_id: module_id, manages: manages}, prefix)
      when is_binary(prefix) do
    if is_binary(name) do
      claimed? = MapSet.member?(manages, name)

      case owner_of(name, prefix) do
        {:ok, ^module_id} when claimed? -> {:ok, module_id}
        {:ok, _other_or_unclaimed} -> {:error, :entity_type_managed}
        :unmanaged when claimed? -> claim_unmanaged_name(name, module_id, prefix)
        :unmanaged -> {:ok, nil}
        {:error, :invalid_schema_name} = error -> error
      end
    else
      {:ok, nil}
    end
  end

  # A module never locks a tenant's own existing type (design §2.4 table, last
  # `:unmanaged` rows): only a name with NO row at all may be claimed.
  defp claim_unmanaged_name(name, module_id, prefix) do
    query = from(e in EntityDefinition, where: e.name == ^name, select: 1, limit: 1)

    case Repo.one(query, prefix: prefix) do
      nil -> {:ok, module_id}
      1 -> {:error, {:managed_name_taken, name}}
    end
  end

  @doc """
  Takes the transaction-scoped create lock for each of `names` in the tenant schema
  `prefix`: deduplicated, names failing the managed-name format skipped, sorted
  ascending (byte order), one `pg_advisory_xact_lock(496_001, hashtext(...))` each.
  Sorting makes two concurrent pack installs acquire overlapping locks in the same
  order, so they cannot deadlock (design §2.5). Re-taking a lock the transaction
  already holds is granted immediately.
  """
  @spec lock_names([String.t()], prefix :: String.t()) :: :ok | {:error, :invalid_schema_name}
  def lock_names(names, prefix) when is_list(names) and is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      names
      |> Enum.filter(&managed_name?/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(&acquire_create_lock(tenant_id, &1))
    end
  end

  # Both arguments cast explicitly, as `Letflow.LoginDirectory` does; the key text is
  # a bound parameter (INV-7).
  defp acquire_create_lock(tenant_id, name) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock($1::int, hashtext($2))",
      [@create_lock_namespace, "#{tenant_id}:#{name}"]
    )

    :ok
  end
end
