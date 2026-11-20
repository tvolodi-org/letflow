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
       row: created as stamped DRAFTS;
    5. (T-2353) activation of each such UNMODIFIED draft by the tenant-local system actor
       (`Letflow.Modules.ProcessActivator`), see below.

  Activation (step 5) happens only when every row of the process name belongs to this module AND
  the row it would supersede is pristine: the stamped `owner_body_hash` equals the hash of the row's
  own graph (the module's previous unmodified definition), and the draft's own graph still hashes to
  its stamp. With no active row it activates only when no row of the name was ever activated or retired
  (a deprecated row is an admin's decision, not ours to undo). The ordinary `Definitions.activate/2`
  validators and its `definition.activate` audit run; the older ACTIVE version is deprecated by that
  call, and running instances stay pinned to their version. One `module.seed_activated` audit entry
  per activation names the module, `"key@version"`, the superseded version and the system actor.
  The activation is tied to the system actor, not to a human; a `needs_reactivation` flag raised
  later on that definition is cleared by a user with `DefinitionsActivate` (`reactivate/2`).
  An activation that is refused (validator, system actor unavailable) never fails the upgrade: the
  draft stays and is listed.

  It never overwrites or deletes a row and never touches records. A definition the tenant modified
  (a stamp whose hash no longer matches its graph) or created (any row of the name not owned by this
  module) is never superseded: the old row keeps its place, the new draft stays DRAFT and the answer
  lists it under `process_activation_needed` for a user with `DefinitionsActivate`.
  A tenant-created definition of the same name is left alone (never listed as created).

  Every item created writes one audit entry (`module.seed_created`; a document type writes its own
  `document.type_registered`). The answer lists what was created, as closed keys and names only:
  `entity_definitions`, `entity_tables`, `document_types`, `process_drafts` (`"key@version"`),
  `process_activated` (`"key@version"`) and `process_activation_needed`. A second run creates
  nothing, activates a pristine draft an earlier run left (idempotent repair) and lists what still
  needs a user.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Documents.DocumentType
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.Installs
  alias Letflow.Modules.ProcessActivator
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
         {:ok, drafts, activated, needed} <-
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
         "process_activated" => activated,
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

    rows = load_rows(packed, prefix)

    {selection, _needed} = classify(packed, rows, module_id, manifest.version)

    with {:ok, drafts} <-
           SolutionPack.install_process_drafts(
             document,
             selection,
             actor_id,
             [prefix: prefix, draft_suffix: manifest.version],
             owner
           ),
         {:ok, activated} <-
           activate_pristine(packed, module_id, manifest.version, actor_id, prefix) do
      {_selection, needed} =
        classify(packed, load_rows(packed, prefix), module_id, manifest.version)

      {:ok, drafts, activated, needed}
    end
  end

  defp load_rows(packed, prefix) do
    from(p in ProcessDefinition,
      where: p.name in ^Enum.map(packed, &elem(&1, 0)),
      order_by: [p.name, p.created_at]
    )
    |> Repo.all(prefix: prefix)
    |> Enum.group_by(& &1.name)
  end

  # ── 5. activation of unmodified drafts ──────────────────────────────────────────────────

  defp activate_pristine(packed, module_id, module_version, actor_id, prefix) do
    packed
    |> Enum.reduce_while({:ok, []}, fn {key, _version, hash}, {:ok, acc} ->
      rows =
        Repo.all(
          from(p in ProcessDefinition,
            where: p.name == ^key,
            order_by: [desc: p.created_at, desc: p.id],
            lock: "FOR UPDATE"
          ),
          prefix: prefix
        )

      case activation_plan(rows, module_id, module_version, hash) do
        {:activate, draft, superseded} ->
          case activate_isolated(draft, superseded, module_id, actor_id, prefix) do
            :ok -> {:cont, {:ok, ["#{draft.name}@#{draft.version}" | acc]}}
            :refused -> {:cont, {:ok, acc}}
            {:error, _reason} = error -> {:halt, error}
          end

        :skip ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # Pure decision. `rows` is every row of the name, newest first.
  defp activation_plan(rows, module_id, module_version, hash) do
    draft =
      Enum.find(rows, fn row ->
        row.status == :draft and row.owner_body_hash == hash and
          row.owner_module_version == module_version and OwnerStamp.graph_hash(row.graph) == hash
      end)

    active = Enum.find(rows, &(&1.status == :active))

    cond do
      draft == nil ->
        :skip

      not Enum.all?(rows, &(&1.owner_module == module_id)) ->
        :skip

      active == nil and Enum.all?(rows, &(&1.status == :draft)) ->
        {:activate, draft, nil}

      active == nil ->
        :skip

      pristine?(active) and not current?(active, hash, module_version) ->
        {:activate, draft, active}

      true ->
        :skip
    end
  end

  defp pristine?(row), do: OwnerStamp.graph_hash(row.graph) == row.owner_body_hash

  defp current?(row, hash, module_version),
    do: row.owner_body_hash == hash and row.owner_module_version == module_version

  # `Definitions.activate/2` rolls back its own (nested) transaction on a refusal and that would poison
  # the caller's. So the draft is first checked with `Definitions.precheck_activation/3` (the same
  # read-only validators): a refusal there (validator, entity-write hash mismatch, system actor
  # unavailable) never fails the upgrade, the draft stays and is listed under
  # `process_activation_needed`. The rows are locked FOR UPDATE by the caller, so the check holds
  # for the activation; a refusal after a passed check is unexpected and fails the upgrade.
  defp activate_isolated(draft, superseded, module_id, actor_id, prefix) do
    with {:ok, authority} <- ProcessActivator.system_authority(prefix),
         :ok <- Definitions.precheck_activation(draft, prefix, authority) do
      with {:ok, _activated} <-
             Definitions.activate(draft.id, prefix: prefix, activator: authority),
           :ok <- audit_activated(draft, superseded, module_id, actor_id, authority, prefix) do
        :ok
      end
    else
      {:error, reason} ->
        Logger.warning("module seed activation refused: #{inspect(tag(reason))}")
        :refused
    end
  end

  defp tag(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp tag(reason), do: reason

  defp audit_activated(draft, superseded, module_id, actor_id, authority, prefix) do
    case Audit.insert_entry(
           Repo,
           %{
             actor_id: actor_id,
             action: "module.seed_activated",
             resource_type: "process_definition",
             resource_id: draft.id,
             before_state: nil,
             after_state: %{
               "module_id" => module_id,
               "item" => "#{draft.name}@#{draft.version}",
               "superseded_version" => superseded && superseded.owner_module_version,
               "activated_by" => authority.user_id
             }
           },
           prefix
         ) do
      {:ok, _entry} -> :ok
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
