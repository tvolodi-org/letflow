defmodule Letflow.Modules.EnsureSeeds do
  @moduledoc """
  T-2217 (GH #4752): the additive "ensure" step of a module. `on_install/3` runs only at install, and a
  module upgrade creates only the definitions its plan names, so a tenant installed at an older
  version can lack what a newer version added: document types, entity definitions and their tables,
  process definitions. This step creates exactly those missing items, in this order, in the caller's
  transaction, under the tenant schema `opts[:prefix]` (INV-1) and nothing else:

    1. entity definitions of the module's `manages_entity_types` that the pack ships and the tenant
       has no row of at all: created stamped, then activated with the caller's rationale;
    2. the entity table of every managed type that has an active definition and no table yet
       (`EntityActivation.ensure_promoted/2`; a table that exists is never altered);
    3. the module's own `ensure_seeds/2` hook (stock: its document types, insert-only);
    4. the pack's process definitions whose graph and current module version the tenant holds in no
       row: created as stamped DRAFTS, never activated.

  It never overwrites, deactivates or deletes a row, never touches records, and activates nothing
  over an ACTIVE definition: an active process definition with an older graph or module version keeps
  running and the answer lists it under `process_activation_needed`; a user with `DefinitionsActivate` activates the
  new draft (the activation is tied to that user, and running instances stay pinned to their version).
  A tenant-created definition of the same name is left alone (never listed as created).

  Every item created writes one audit entry (`module.seed_created`; a document type writes its own
  `document.type_registered`). The answer lists what was created, as closed keys and names only:
  `entity_definitions`, `entity_tables`, `document_types`, `process_drafts` (`"key@version"`) and
  `process_activation_needed`. A second run creates nothing; pending activation remains listed.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Documents.DocumentType
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type report :: %{String.t() => [String.t()] | [map()]}

  @doc """
  Runs the step for `entry_module` (`owner` is `ManagedTypes.module_owner/1` of it, computed by the
  caller). The caller owns the surrounding transaction: `{:error, reason}` means "roll back".
  """
  @spec run(module(), term(), Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, report()} | {:error, term()}
  def run(entry_module, owner, actor_id, rationale, prefix) when is_binary(prefix) do
    manifest = entry_module.manifest()
    module_id = manifest.id
    types = Map.get(manifest, :manages_entity_types, [])
    missing_tables = Enum.reject(types, &table_exists?(prefix, &1))

    with {:ok, document} <- pack_document(manifest),
         {:ok, definitions} <-
           ensure_entity_definitions(document, types, actor_id, rationale, prefix, owner),
         {:ok, _promoted} <- EntityActivation.ensure_promoted(prefix, types),
         {:ok, document_types} <- ensure_document_types(entry_module, module_id, actor_id, prefix),
         {:ok, drafts, needed} <-
           ensure_process_drafts(document, module_id, manifest, actor_id, prefix, owner) do
      tables = Enum.filter(missing_tables, &table_exists?(prefix, &1))

      created = [
        {"entity_definition", definitions},
        {"entity_table", tables},
        {"process_definition", drafts}
      ]

      audit_created(created, module_id, actor_id, prefix)

      {:ok,
       %{
         "entity_definitions" => definitions,
         "entity_tables" => tables,
         "document_types" => document_types,
         "process_drafts" => drafts,
         "process_activation_needed" => needed
       }}
    end
  end

  defp table_exists?(prefix, name) do
    with {:ok, table} <- TenantProvisioning.table_name_for_entity_type(name) do
      TenantProvisioning.entity_table_exists?(prefix, table)
    else
      _invalid -> false
    end
  end

  defp pack_document(manifest) do
    case Map.get(manifest, :pack) do
      path when is_binary(path) -> Installs.read_pack_document(path)
      _no_pack -> {:ok, %{}}
    end
  end

  # ── 1. entity definitions ───────────────────────────────────────────────────────────────

  defp ensure_entity_definitions(document, types, actor_id, rationale, prefix, owner) do
    packed = for %{"name" => name} <- List.wrap(document["entity_definitions"]), do: name

    held =
      from(d in EntityDefinition, where: d.name in ^types, select: d.name, distinct: true)
      |> Repo.all(prefix: prefix)

    missing = Enum.filter(types, &(&1 in packed and &1 not in held))

    # Activation promotes constrained columns. Never let a newly registered definition alter a
    # table that predates this repair, even when the definition row itself has disappeared.
    with :ok <- missing_definition_tables_absent(missing, prefix),
         {:ok, created, ids} <- create_definitions(document, missing, actor_id, prefix, owner),
         :ok <-
           EntityActivation.activate_and_promote(
             prefix,
             %{actor_id: actor_id, rationale: rationale, pack_entity_definition_ids: ids},
             created
           ) do
      {:ok, created}
    end
  end

  defp missing_definition_tables_absent(names, prefix) do
    case Enum.find(names, &table_exists?(prefix, &1)) do
      nil -> :ok
      name -> {:error, {:entity_name_conflict, name}}
    end
  end

  defp create_definitions(_document, [], _actor_id, _prefix, _owner), do: {:ok, [], %{}}

  defp create_definitions(document, missing, actor_id, prefix, owner) do
    case SolutionPack.install_entity_definitions(
           document,
           missing,
           actor_id,
           [prefix: prefix],
           owner
         ) do
      {:ok, rows} ->
        names = MapSet.new(rows, & &1.name)
        {:ok, Enum.filter(missing, &MapSet.member?(names, &1)), Map.new(rows, &{&1.name, &1.id})}

      {:error, _reason} = error ->
        error
    end
  end

  # ── 3. document types (and any other seed of the module's own hook) ──────────────────────

  defp ensure_document_types(entry_module, module_id, actor_id, prefix) do
    before_keys = document_type_keys(module_id, prefix)

    with :ok <- Installs.ensure_seeds(entry_module, prefix, actor_id) do
      {:ok, (document_type_keys(module_id, prefix) -- before_keys) |> Enum.sort()}
    end
  end

  defp document_type_keys(module_id, prefix) do
    from(t in DocumentType, where: t.owner_module == ^module_id, select: t.key)
    |> Repo.all(prefix: prefix)
  end

  # ── 4. process definitions ──────────────────────────────────────────────────────────────

  defp ensure_process_drafts(document, module_id, manifest, actor_id, prefix, owner) do
    packed =
      for %{"process_key" => key, "version" => version, "graph" => graph} <-
            List.wrap(document["definitions"]),
          is_binary(key),
          is_map(graph),
          do: {key, version, OwnerStamp.graph_hash(graph)}

    rows =
      from(p in ProcessDefinition,
        where: p.name in ^Enum.map(packed, &elem(&1, 0)),
        order_by: [p.name, p.created_at]
      )
      |> Repo.all(prefix: prefix)
      |> Enum.group_by(& &1.name)

    {selection, needed} = classify(packed, rows, module_id, manifest.version)

    case SolutionPack.install_process_drafts(
           document,
           selection,
           actor_id,
           [prefix: prefix, draft_suffix: manifest.version],
           owner
         ) do
      {:ok, drafts} -> {:ok, drafts, needed}
      {:error, _reason} = error -> error
    end
  end

  # A packed process needs a draft when the tenant holds no row with its graph and current owner
  # version and every row of the name is this module's (or there is none): a tenant-created definition
  # is never ours to shadow. An ACTIVE older module row stays listed until a user activates the draft.
  defp classify(packed, rows, module_id, module_version) do
    {selection, needed} =
      Enum.reduce(packed, {[], []}, fn {key, version, hash}, {selection, needed} ->
        held = Map.get(rows, key, [])
        ours? = Enum.all?(held, &(&1.owner_module == module_id))

        if ours? do
          active = Enum.find(held, &(&1.status == :active))

          needed =
            if active &&
                 (active.owner_body_hash != hash or active.owner_module_version != module_version),
               do: [
                 %{
                   "name" => key,
                   "active_version" => active.owner_module_version,
                   "new_version" => module_version
                 }
                 | needed
               ],
               else: needed

          if Enum.any?(held, fn row ->
               row.owner_body_hash == hash and row.owner_module_version == module_version
             end),
             do: {selection, needed},
             else: {[{key, version} | selection], needed}
        else
          {selection, needed}
        end
      end)

    {Enum.reverse(selection), Enum.reverse(needed)}
  end

  # ── audit ──────────────────────────────────────────────────────────────────────────────

  defp audit_created(created, module_id, actor_id, prefix) do
    for {resource_type, ids} <- created, id <- ids do
      {:ok, _entry} =
        Audit.insert_entry(
          Repo,
          %{
            actor_id: actor_id,
            action: "module.seed_created",
            resource_type: resource_type,
            resource_id: id,
            before_state: nil,
            after_state: %{"module_id" => module_id, "item" => id}
          },
          prefix
        )
    end

    :ok
  end
end
