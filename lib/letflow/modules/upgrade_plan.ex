defmodule Letflow.Modules.UpgradePlan do
  @moduledoc """
  REQ-768 (decision 0080, amending 0055 D2): the dry-run plan of a module upgrade, behind
  `POST /api/v1/tenant/modules/:module_id/upgrade/plan`.

  The plan compares a tenant's installed state (the `tenant_modules` row, its active managed
  entity definitions, the stamped process definitions, the ledger storage) with the module
  compiled into this build and its pack file, and reports:

  - each managed entity type as `unchanged | new_type | new_version | removed` with a change
    class A (safe on boot), B (needs a data step and an acknowledgement) or C (never applied
    automatically) and a reason code (`classify_entity/2`, pure);
  - the pack's process definitions as `unchanged` or `new_draft` (the plan creates nothing);
  - whether every stamped definition still passes the activation check AFTER the upgrade (the
    installed hash becomes the compiled one, the current installed hash joins the accepted
    list: exactly what `Letflow.ModuleUpgrade.Apply` will write);
  - the upgrade path steps, whether a path exists (`upgrade_path_available`; a tenant below the
    module's `min_upgradable_from` gets a normal 200 report with the marker and the apply slices
    must refuse on it), `applicable_on_boot` (decision 0080 Q3), and `plan_hash`.

  The only write is one `planned` row of the upgrade journal (`TenantModuleUpgrade`; reused when the hash repeats;
  older `planned` rows with another hash are set `abandoned`). A tenant already at the compiled
  version and hash gets an empty report and no row. No definition, record, event or audit row is
  touched or read. A DB failure rolls the whole plan back and is `{:error, :plan_failed}`.

  Each step carries `reversible`, and `point_of_no_return` is `nil` or the plain text naming the steps
  a rollback could not undo (REQ rollback slice, decision 0055 D9). Neither enters the `plan_hash`.

  Class B "covered by steps" is the coarse `steps != []`; the apply slice decides per step. The
  report is built from an explicit allow-list of literal keys (no row is serialised), so no
  hash, stamp, step body or tenant record content leaves this module. It counts nothing over
  fields, so there is no `entity_field_restrictions` value to suppress. `plan_hash` carries a
  version field (`"v"`) so the apply slice can extend its inputs; the code-step digest, the
  permission-matrix digest, config values and preflight counts of 0055 D2 are not inputs yet
  because nothing on main provides them.

  Tenancy: the tenant schema is `opts[:prefix]` (required, from the auth context in the router),
  passed to every query (INV-1). The `plan_hash` inputs come only from the tenant row, the
  compiled manifest and the pack file.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ModuleWrites
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Repo

  @rank %{"A" => 1, "B" => 2, "C" => 3}

  @spec plan(String.t(), Ecto.UUID.t() | String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, :unknown_module | :not_installed | :plan_failed}
  def plan(module_id, actor_id, opts) when is_binary(module_id) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Catalog.fetch(module_id) do
      {:error, :not_found} ->
        {:error, :unknown_module}

      {:ok, entry_module} ->
        run(entry_module, module_id, actor_id, prefix)
    end
  end

  defp run(entry_module, module_id, actor_id, prefix) do
    result =
      try do
        Repo.transaction(fn ->
          case build(entry_module, module_id, actor_id, prefix) do
            {:ok, report} -> report
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      rescue
        exception ->
          Logger.error("module upgrade plan failed: #{inspect(exception.__struct__)}")
          {:error, :plan_failed}
      end

    case result do
      {:ok, report} -> {:ok, report}
      {:error, :not_installed} -> {:error, :not_installed}
      {:error, _other} -> {:error, :plan_failed}
    end
  end

  defp build(entry_module, module_id, actor_id, prefix) do
    manifest = entry_module.manifest()
    {:ok, compiled_hash} = Catalog.manifest_hash(entry_module)

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":" <> module_id
    ])

    case Repo.get_by(TenantModule, [module_id: module_id], prefix: prefix) do
      nil ->
        {:error, :not_installed}

      %TenantModule{status: :uninstalled} ->
        {:error, :not_installed}

      %TenantModule{} = row ->
        if row.version == manifest.version and row.manifest_hash == compiled_hash do
          {:ok, up_to_date_report(module_id, row, manifest)}
        else
          {:ok, full_report(entry_module, manifest, compiled_hash, row, actor_id, prefix)}
        end
    end
  end

  defp up_to_date_report(module_id, row, manifest) do
    %{
      "module_id" => module_id,
      "from_version" => row.version,
      "to_version" => manifest.version,
      "up_to_date" => true,
      "entity_types" => [],
      "process_definitions" => [],
      "stamped_definitions" => [],
      "missing_ledger_storage" => [],
      "information" => information(manifest),
      "steps" => [],
      "point_of_no_return" => nil,
      "upgrade_path_available" => true,
      "path_error" => nil,
      "applicable_on_boot" => false,
      "plan_hash" => nil,
      "plan_id" => nil
    }
  end

  defp full_report(entry_module, manifest, compiled_hash, row, actor_id, prefix) do
    module_id = manifest.id
    to_version = manifest.version

    {steps, path_available?} =
      case Catalog.upgrade_path(manifest, row.version, to_version) do
        {:ok, steps} -> {steps, true}
        {:error, {:no_upgrade_path, _from, _to}} -> {[], false}
      end

    pack = pack_sections(manifest)
    tenant_types = tenant_entity_rows(module_id, Map.keys(pack.entities), prefix)
    entity_types = entity_rows(module_id, pack.entities, tenant_types, steps)
    process_rows = process_rows(module_id, pack.processes, prefix)

    stamped_rows =
      stamped_definition_rows(module_id, process_rows.stamped, row, compiled_hash, prefix)

    ledger_ids = ledger_ids(entry_module)

    report_steps =
      for step <- steps do
        %{
          "id" => step_id(step.id),
          "from" => step.from,
          "to" => step.to,
          "kind" => Atom.to_string(step.kind),
          "lossy" => step.lossy == true
        }
      end

    applicable_on_boot =
      report_steps == [] and
        Enum.all?(entity_types, &(&1["class"] in [nil, "A"])) and
        Enum.all?(stamped_rows, & &1["passes_activation"])

    inputs = %{
      "v" => 1,
      "module_id" => module_id,
      "target_version" => to_version,
      "compiled_manifest_hash" => compiled_hash,
      "upgrade_path_available" => path_available?,
      "steps" => report_steps,
      "entity_content" =>
        Map.new(pack.entities, fn {name, json} -> {name, OwnerStamp.graph_hash(json)} end),
      "process_content" => pack.process_content,
      "tenant" => %{
        "applied_version" => row.version,
        "installed_manifest_hash" => row.manifest_hash,
        "accepted" => Enum.sort(row.accepted_manifest_hashes || []),
        "active_entity_definition_ids" =>
          Map.new(tenant_types, fn {name, def_row} -> {name, def_row.id} end),
        "stamped_definition_ids" => process_rows.stamped |> Enum.map(& &1.id) |> Enum.sort(),
        "settings_hash" => OwnerStamp.graph_hash(row.settings || %{})
      }
    }

    plan_hash = compute_hash(inputs)
    plan_id = journal(module_id, row.version, to_version, plan_hash, actor_id, prefix)

    %{
      "module_id" => module_id,
      "from_version" => row.version,
      "to_version" => to_version,
      "up_to_date" => false,
      "entity_types" => entity_types,
      "process_definitions" => process_rows.report,
      "stamped_definitions" => stamped_rows,
      "missing_ledger_storage" => Letflow.Ledger.Storage.missing(prefix, ledger_ids),
      "information" => information(manifest),
      "steps" => Enum.zip_with(report_steps, steps, &Map.put(&1, "reversible", reversible?(&2))),
      "point_of_no_return" => point_of_no_return(report_steps, steps, row.version),
      "upgrade_path_available" => path_available?,
      "path_error" => if(path_available?, do: nil, else: "no_upgrade_path"),
      "applicable_on_boot" => applicable_on_boot,
      "plan_hash" => plan_hash,
      "plan_id" => plan_id
    }
  end

  @doc """
  Whether a step can be undone by a rollback (decision 0055 D9): not lossy and a declared `down`
  that is not `:irreversible`. A missing `down` counts as irreversible (fail closed). Pure.
  """
  @spec reversible?(Letflow.Modules.Step.t()) :: boolean()
  def reversible?(%Letflow.Modules.Step{lossy: lossy, down: down}),
    do: lossy != true and down not in [nil, :irreversible]

  # nil when every step is reversible (including no steps); otherwise the plain-language text. The
  # text is a constant plus manifest step ids and versions (no tenant data).
  defp point_of_no_return(report_steps, steps, from_version) do
    ids =
      for {report_step, step} <- Enum.zip(report_steps, steps),
          not reversible?(step),
          do: report_step["id"]

    case ids do
      [] ->
        nil

      ids ->
        %{
          "step_ids" => ids,
          "text" =>
            "Point of no return: after this upgrade the step(s) #{Enum.join(ids, ", ")} " <>
              "cannot be reversed. Going back to version #{from_version} will be refused, " <>
              "and data written by those steps stays."
        }
    end
  end

  @doc """
  The `plan_hash`: SHA-256 (lowercase hex) of the canonical JSON of `inputs`. Pure.
  """
  @spec compute_hash(map()) :: String.t()
  def compute_hash(inputs) when is_map(inputs), do: OwnerStamp.graph_hash(inputs)

  # ── pack sections ────────────────────────────────────────────────────────────────────────

  defp pack_sections(manifest) do
    with pack_path when is_binary(pack_path) <- Map.get(manifest, :pack),
         {:ok, %{} = document} <- Installs.read_pack_document(pack_path) do
      entities =
        for %{"name" => name, "definition_json" => json} <-
              List.wrap(document["entity_definitions"]),
            is_binary(name),
            is_map(json),
            into: %{},
            do: {name, json}

      processes =
        for %{"process_key" => key, "version" => version, "graph" => graph} <-
              List.wrap(document["definitions"]),
            is_binary(key),
            is_map(graph),
            do: {key, version, graph}

      %{
        entities: entities,
        processes: processes,
        process_content:
          Map.new(processes, fn {key, version, graph} ->
            {"#{key}@#{version}", OwnerStamp.graph_hash(graph)}
          end)
      }
    else
      _no_pack -> %{entities: %{}, processes: [], process_content: %{}}
    end
  end

  # ── entity types ─────────────────────────────────────────────────────────────────────────

  # %{name => active entity_definitions row} of the module's types in this tenant.
  defp tenant_entity_rows(module_id, pack_names, prefix) do
    from(d in EntityDefinition,
      where: d.status == :active and (d.managed_by == ^module_id or d.name in ^pack_names),
      order_by: d.name
    )
    |> Repo.all(prefix: prefix)
    |> Map.new(&{&1.name, &1})
  end

  defp entity_rows(module_id, pack_entities, tenant_types, steps) do
    covered? = steps != []

    in_pack =
      for {name, pack_json} <- Enum.sort(pack_entities) do
        tenant_row = Map.get(tenant_types, name)

        {change, class, reason, fields} =
          cond do
            tenant_row == nil ->
              {"new_type", "A", nil, field_names(pack_json)}

            tenant_row.managed_by != module_id ->
              {"new_version", "C", "owned_by_other", field_names(pack_json)}

            true ->
              case classify_entity(tenant_row.definition_json, pack_json) do
                :unchanged -> {"unchanged", nil, nil, field_names(pack_json)}
                {class, reason} -> {"new_version", class, reason, field_names(pack_json)}
              end
          end

        entity_row(name, change, class, reason, fields, class == "B" and covered?)
      end

    removed =
      for {name, row} <- Enum.sort(tenant_types),
          row.managed_by == module_id,
          not Map.has_key?(pack_entities, name),
          do:
            entity_row(
              name,
              "removed",
              "C",
              "type_removed_or_renamed",
              field_names(row.definition_json),
              false
            )

    in_pack ++ removed
  end

  defp entity_row(name, change, class, reason, fields, covered?) do
    %{
      "name" => name,
      "change" => change,
      "class" => class,
      "reason" => reason,
      "fields" => fields,
      "covered_by_steps" => if(class == "B", do: covered?, else: nil)
    }
  end

  defp field_names(%{"fields" => fields}) when is_list(fields) do
    for %{"name" => name} <- fields, is_binary(name), do: name
  end

  defp field_names(_json), do: []

  @doc """
  The change class of a managed entity type whose active definition is `tenant_json` and whose
  new definition is `pack_json`: `:unchanged`, or `{class, reason}` with the worst class of the
  differences (A < B < C; ties go to the alphabetically first reason). Pure.

  Deliberately over-strict where the cheap diff cannot tell widening from narrowing (an enum, a
  min/max or any other key of an existing field): such a change is B, never applied silently.
  """
  @spec classify_entity(map(), map()) :: :unchanged | {String.t(), String.t()}
  def classify_entity(tenant_json, pack_json) do
    if OwnerStamp.graph_hash(tenant_json) == OwnerStamp.graph_hash(pack_json) do
      :unchanged
    else
      diffs =
        field_diffs(tenant_json, pack_json) ++
          index_diffs(tenant_json, pack_json) ++ other_diffs(tenant_json, pack_json)

      case diffs do
        [] ->
          {"A", "metadata_changed"}

        _ ->
          diffs
          |> Enum.sort_by(fn {class, reason} -> {-Map.fetch!(@rank, class), reason} end)
          |> hd()
      end
    end
  end

  defp field_diffs(old_json, new_json) do
    old = fields_by_name(old_json)
    new = fields_by_name(new_json)

    added =
      for {name, field} <- new, not Map.has_key?(old, name) do
        if Map.get(field, "required") == true,
          do: {"B", "required_field_added"},
          else: {"A", "optional_field_added"}
      end

    removed = for {name, _} <- old, not Map.has_key?(new, name), do: {"B", "field_removed"}

    changed =
      for {name, new_field} <- new,
          old_field = Map.get(old, name),
          old_field != nil,
          old_field != new_field do
        cond do
          Map.get(old_field, "type") != Map.get(new_field, "type") ->
            {"B", "field_type_changed"}

          Map.get(old_field, "required") != true and Map.get(new_field, "required") == true ->
            {"B", "required_tightened"}

          true ->
            {"B", "field_changed"}
        end
      end

    added ++ removed ++ changed
  end

  defp fields_by_name(%{"fields" => fields}) when is_list(fields) do
    for %{"name" => name} = field <- fields, is_binary(name), into: %{}, do: {name, field}
  end

  defp fields_by_name(_json), do: %{}

  defp index_diffs(old_json, new_json) do
    old = indexes_by_name(old_json)
    new = indexes_by_name(new_json)

    added =
      for {name, index} <- new, not Map.has_key?(old, name) do
        if Map.get(index, "unique") == true,
          do: {"B", "index_changed"},
          else: {"A", "index_added"}
      end

    removed = for {name, _} <- old, not Map.has_key?(new, name), do: {"B", "index_changed"}

    changed =
      for {name, new_index} <- new,
          old_index = Map.get(old, name),
          old_index != nil,
          old_index != new_index,
          do: {"B", "index_changed"}

    added ++ removed ++ changed
  end

  defp indexes_by_name(%{"indexes" => indexes}) when is_list(indexes) do
    for %{"name" => name} = index <- indexes, is_binary(name), into: %{}, do: {name, index}
  end

  defp indexes_by_name(_json), do: %{}

  # Any other top-level key: description / display_name alone are metadata (A); anything else is B.
  defp other_diffs(old_json, new_json) do
    keys = Enum.uniq(Map.keys(old_json) ++ Map.keys(new_json)) -- ["fields", "indexes"]

    for key <- keys, Map.get(old_json, key) != Map.get(new_json, key) do
      if key in ["description", "display_name"],
        do: {"A", "metadata_changed"},
        else: {"B", "field_changed"}
    end
  end

  # ── process definitions and stamped definitions ──────────────────────────────────────────

  defp process_rows(module_id, pack_processes, prefix) do
    stamped =
      from(p in ProcessDefinition,
        where: p.owner_module == ^module_id,
        order_by: [p.name, p.version]
      )
      |> Repo.all(prefix: prefix)

    report =
      for {key, version, graph} <- Enum.sort(pack_processes) do
        body_hash = OwnerStamp.graph_hash(graph)

        unchanged? =
          Enum.any?(stamped, &(&1.name == key and &1.owner_body_hash == body_hash))

        %{
          "process_key" => key,
          "version" => version,
          "change" => if(unchanged?, do: "unchanged", else: "new_draft")
        }
      end

    %{stamped: stamped, report: report}
  end

  # Does each stamped definition pass the activation check under the POST-upgrade hashes?
  defp stamped_definition_rows(_module_id, stamped, row, compiled_hash, prefix) do
    accepted =
      Enum.uniq((row.accepted_manifest_hashes || []) ++ List.wrap(row.manifest_hash))

    hashes = %{installed: compiled_hash, accepted: accepted}

    for definition <- stamped do
      codes = definition_codes(definition, hashes, prefix)

      %{
        "name" => definition.name,
        "version" => definition.version,
        "status" => to_string(definition.status),
        "passes_activation" => codes == [],
        "violation_codes" => codes
      }
    end
  end

  defp definition_codes(definition, hashes, prefix) do
    case Graph.from_map(definition.graph) do
      {:ok, %Graph{nodes: nodes}} ->
        codes =
          for {node, writes} <- ModuleWrites.declared_nodes(nodes),
              violation <-
                ModuleWrites.node_violations_with_hashes(
                  node,
                  writes,
                  definition,
                  entity_write_count(node),
                  prefix,
                  hashes
                ),
              do: Atom.to_string(violation.code)

        codes |> Enum.uniq() |> Enum.sort()

      _unparseable ->
        ["graph_invalid"]
    end
  end

  defp entity_write_count(%Graph.Node{attributes: %{"entity_writes" => writes}})
       when is_list(writes),
       do: length(writes)

  defp entity_write_count(_node), do: 0

  # ── ledger, steps, information ───────────────────────────────────────────────────────────

  defp ledger_ids(entry_module) do
    entry_module.manifest()
    |> Map.get(:ledger, %{})
    |> Map.values()
    |> Enum.flat_map(fn %{ledger_ids: {:fixed, ids}} -> ids end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp step_id(id) when is_binary(id), do: id
  defp step_id(id) when is_atom(id), do: Atom.to_string(id)
  defp step_id(id), do: inspect(id)

  defp information(manifest) do
    route_policy_count =
      case Map.get(manifest, :route_policies) do
        list when is_list(list) -> length(list)
        map when is_map(map) -> map_size(map)
        _other -> 0
      end

    %{
      "permissions" =>
        manifest |> Map.get(:permissions, []) |> Enum.map(&to_string/1) |> Enum.sort(),
      "route_policy_count" => route_policy_count,
      "effective_at_deploy" => true
    }
  end

  # ── journal ──────────────────────────────────────────────────────────────────────────────

  defp journal(module_id, from_version, to_version, plan_hash, actor_id, prefix) do
    now = DateTime.utc_now()

    from(u in TenantModuleUpgrade,
      where:
        u.module_id == ^module_id and u.kind == :upgrade and u.state == :planned and
          u.plan_hash != ^plan_hash
    )
    |> Repo.update_all([set: [state: :abandoned, finished_at: now]], prefix: prefix)

    existing =
      from(u in TenantModuleUpgrade,
        where:
          u.module_id == ^module_id and u.kind == :upgrade and u.state == :planned and
            u.plan_hash == ^plan_hash,
        order_by: [asc: u.id],
        limit: 1
      )
      |> Repo.one(prefix: prefix)

    case existing do
      %TenantModuleUpgrade{id: id} ->
        id

      nil ->
        %TenantModuleUpgrade{}
        |> TenantModuleUpgrade.changeset(%{
          module_id: module_id,
          from_version: from_version,
          to_version: to_version,
          kind: :upgrade,
          state: :planned,
          plan_hash: plan_hash,
          actor_id: actor_id
        })
        |> Repo.insert!(prefix: prefix)
        |> Map.fetch!(:id)
    end
  end
end
