defmodule Letflow.ModuleUpgrade.Rollback do
  @moduledoc """
  Decision 0055 D9/D10 (module upgrade rollback slice): the rollback of a module to its PREVIOUS applied
  version, behind `POST /api/v1/tenant/modules/:module_id/rollback`. Per tenant, `:ModulesManage` only.

  The target is the `from_version` of the newest `done` upgrade journal row that no `done` rollback has
  reversed. The body names it (`target_version`), so a blind click cannot walk the chain. One
  transaction, under the same advisory lock as the plan and the apply, then:

  - each entity definition the upgrade replaced is re-activated (that exact row, through the same
    activation gate as any activation; a strict-decimal change with records is refused,
    `rollback_refused`),
  - the `tenant_modules` row gets the previous version and manifest hash back; the hash it held joins
    `accepted_manifest_hashes` (drafts stamped with it must keep passing),
  - one `kind: :rollback` journal row (`touches["reverses"]` names the upgrade row) and one
    `module.rollback` audit entry are written.

  Nothing is dropped: types the upgrade created and process drafts stay and are reported. Declared
  `down` steps are validated, reported and gated but never executed (the data-step runner does not
  exist; `Letflow.ModuleUpgrade.Apply` refuses any plan with a step, so no `done` row has one). A step
  that is lossy, `:irreversible` or has no `down` forbids the rollback (`rollback_forbidden`).

  Refusals, in order: `no_previous_version`, `rollback_not_recorded` (the upgrade row has no usable
  `undo` block: it was written before rollback existed, or the tenant row moved without it),
  `module_version_ahead`, `rollback_target_mismatch`, `no_upgrade_path_from_target`,
  `rollback_forbidden`, `rollback_needs_runner`, `rollback_refused`, `upgrade_running`. All answer 409
  and carry code-like extras only. With `dry_run: true` the same checks run and nothing is written; a
  refusal is then reported inside the 200 body (`rollback_possible: false`, `refusal`).

  Tenancy: the schema is `opts[:prefix]` only (from the auth context in the router); the request body
  is read for exactly `rationale`, `target_version` and `dry_run` (INV-1). The report holds field and
  index NAMES from definition JSON and counts of process drafts, never record content (INV-2).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Audit
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Modules.UpgradePlan
  alias Letflow.Repo

  @lock_timeout "10s"
  @statement_timeout "120s"

  @type error ::
          :rationale_required
          | :target_version_required
          | :dry_run_invalid
          | :not_found
          | {:refused, String.t(), map()}
          | {:failed, String.t()}

  @doc """
  Rolls `module_id` back for the tenant in `opts[:prefix]`. Returns `{:ok, body}` (also for a dry run) or
  `{:error, error()}`; `{:failed, "internal_error"}` is the only 500.
  """
  @spec rollback(String.t(), Ecto.UUID.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def rollback(module_id, actor_id, params, opts) when is_binary(module_id) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, rationale} <- fetch_rationale(params),
         {:ok, target} <- fetch_target(params),
         {:ok, dry_run?} <- fetch_dry_run(params),
         {:ok, entry_module} <- fetch_entry(module_id),
         :ok <- installed?(module_id, prefix) do
      run(entry_module, module_id, actor_id, rationale, target, dry_run?, prefix)
    end
  end

  @doc """
  The ids (strings) of the upgrade journal rows of `module_id` that a `done` rollback has reversed.
  """
  @spec reversed_ids(String.t(), String.t()) :: [String.t()]
  def reversed_ids(module_id, prefix) do
    from(u in TenantModuleUpgrade,
      where: u.module_id == ^module_id and u.kind == :rollback and u.state == :done,
      select: u.touches
    )
    |> Repo.all(prefix: prefix)
    |> Enum.flat_map(fn
      %{"reverses" => id} when is_binary(id) -> [id]
      _other -> []
    end)
  end

  # ── request validation ─────────────────────────────────────────────────────────────────

  defp fetch_rationale(params) do
    case Map.get(params, "rationale") do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, :rationale_required}, else: {:ok, value}

      _other ->
        {:error, :rationale_required}
    end
  end

  defp fetch_target(params) do
    case Map.get(params, "target_version") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :target_version_required}
    end
  end

  defp fetch_dry_run(params) do
    case Map.get(params, "dry_run", false) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, :dry_run_invalid}
    end
  end

  defp fetch_entry(module_id) do
    case Catalog.fetch(module_id) do
      {:ok, entry_module} -> {:ok, entry_module}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp installed?(module_id, prefix) do
    case Repo.get_by(TenantModule, [module_id: module_id], prefix: prefix) do
      %TenantModule{status: :active} -> :ok
      _none_or_uninstalled -> {:error, :not_found}
    end
  end

  # ── the transaction ────────────────────────────────────────────────────────────────────

  defp run(entry_module, module_id, actor_id, rationale, target, dry_run?, prefix) do
    outcome =
      try do
        Repo.transaction(fn ->
          transact(entry_module, module_id, actor_id, rationale, target, dry_run?, prefix)
        end)
      rescue
        exception -> {:error, {:failed, failure_code(exception)}}
      catch
        _kind, _reason -> {:error, {:failed, "internal_error"}}
      end

    case outcome do
      {:ok, body} ->
        {:ok, body}

      {:error, {:refused, code, extras}} when dry_run? ->
        {:ok, refused_report(module_id, target, code, extras, prefix)}

      {:error, {:refused, _code, _extras} = refusal} ->
        {:error, refusal}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, {:failed, code}} ->
        fail(module_id, actor_id, rationale, target, code, dry_run?, prefix)

      {:error, _other} ->
        fail(module_id, actor_id, rationale, target, "internal_error", dry_run?, prefix)
    end
  end

  defp fail(module_id, actor_id, rationale, target, code, dry_run?, prefix) do
    Logger.error("module rollback failed: module_id=#{module_id} code=#{code}")
    unless dry_run?, do: journal_failure(module_id, actor_id, rationale, target, code, prefix)
    {:error, {:failed, code}}
  end

  defp transact(entry_module, module_id, actor_id, rationale, target, dry_run?, prefix) do
    Repo.query!("SET LOCAL lock_timeout = '#{@lock_timeout}'")
    Repo.query!("SET LOCAL statement_timeout = '#{@statement_timeout}'")

    # Same key as the plan's and the apply's lock.
    %{rows: [[locked?]]} =
      Repo.query!("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [
        prefix <> ":" <> module_id
      ])

    unless locked?, do: Repo.rollback({:refused, "upgrade_running", %{}})

    row =
      from(m in TenantModule, where: m.module_id == ^module_id, lock: "FOR UPDATE")
      |> Repo.one!(prefix: prefix)

    if row.status != :active, do: Repo.rollback(:not_found)

    manifest = entry_module.manifest()
    candidate = candidate(module_id, prefix)

    steps =
      case gate(candidate, manifest, row, target) do
        {:ok, steps} -> steps
        {:error, {code, extras}} -> Repo.rollback({:refused, code, extras})
      end

    undo = candidate.touches["undo"]
    targets = target_definitions(undo, prefix)
    entity_types = entity_report(undo, targets, prefix)
    drafts = count_drafts(module_id, undo["to_manifest_hash"], prefix)

    base = %{
      "module_id" => module_id,
      "from_version" => row.version,
      "target_version" => target,
      "dry_run" => dry_run?,
      "rollback_possible" => true,
      "refusal" => nil,
      "point_of_no_return" => nil,
      "entity_types" => entity_types,
      "process_drafts_kept" => drafts,
      "steps" => Enum.map(steps, &%{"id" => step_id(&1.id), "reversible" => true})
    }

    if dry_run? do
      Map.merge(base, %{"state" => "dry_run", "rollback_id" => nil})
    else
      execute(row, candidate, undo, targets, base, actor_id, rationale, prefix)
    end
  end

  # The newest `done` upgrade row that no `done` rollback reversed.
  defp candidate(module_id, prefix) do
    reversed = reversed_ids(module_id, prefix)

    from(u in TenantModuleUpgrade,
      where: u.module_id == ^module_id and u.kind == :upgrade and u.state == :done,
      order_by: [desc: u.finished_at, desc: u.id]
    )
    |> Repo.all(prefix: prefix)
    |> Enum.find(&(&1.id not in reversed))
  end

  # ── the gate (pure) ────────────────────────────────────────────────────────────────────

  @doc """
  The refusals that need no write, in order, over the candidate upgrade row (or `nil`), the compiled
  `manifest`, the tenant row and the requested `target` version. Returns `{:ok, steps}` (the down steps
  to run, always `[]` for a rollback that can proceed) or `{:error, {code, extras}}`. Pure.
  """
  @spec gate(TenantModuleUpgrade.t() | nil, map(), TenantModule.t(), String.t()) ::
          {:ok, list()} | {:error, {String.t(), map()}}
  def gate(nil, _manifest, _row, _target), do: {:error, {"no_previous_version", %{}}}

  def gate(%TenantModuleUpgrade{} = candidate, manifest, %TenantModule{} = row, target) do
    cond do
      not recorded?(candidate, row) ->
        {:error, {"rollback_not_recorded", %{}}}

      version_compare(row.version, manifest.version) == :gt ->
        {:error, {"module_version_ahead", %{}}}

      candidate.from_version != target ->
        {:error, {"rollback_target_mismatch", %{}}}

      match?({:error, _}, Catalog.upgrade_path(manifest, target, manifest.version)) ->
        {:error, {"no_upgrade_path_from_target", %{}}}

      true ->
        steps_gate(Catalog.upgrade_path(manifest, target, row.version))
    end
  end

  defp steps_gate({:error, _no_path}), do: {:error, {"no_upgrade_path_from_target", %{}}}
  defp steps_gate({:ok, []}), do: {:ok, []}

  defp steps_gate({:ok, steps}) do
    case Enum.find(steps, &(not UpgradePlan.reversible?(&1))) do
      nil -> {:error, {"rollback_needs_runner", %{}}}
      step -> {:error, {"rollback_forbidden", %{"step_id" => step_id(step.id)}}}
    end
  end

  defp recorded?(%TenantModuleUpgrade{touches: %{"undo" => undo}} = candidate, row)
       when is_map(undo) do
    is_binary(undo["from_manifest_hash"]) and is_binary(undo["to_manifest_hash"]) and
      is_map(undo["previous_definitions"]) and is_list(undo["new_types"]) and
      candidate.to_version == row.version and undo["to_manifest_hash"] == row.manifest_hash
  end

  defp recorded?(_candidate, _row), do: false

  defp version_compare(a, b) do
    with {:ok, va} <- Version.parse(a), {:ok, vb} <- Version.parse(b) do
      Version.compare(va, vb)
    else
      _invalid -> :eq
    end
  end

  # ── the work ───────────────────────────────────────────────────────────────────────────

  # %{name => %EntityDefinition{}} of the rows to re-activate. A recorded id that is gone is a tenant
  # state this journal cannot undo: fail closed.
  defp target_definitions(undo, prefix) do
    Map.new(undo["previous_definitions"], fn {name, id} ->
      case is_binary(id) && Repo.get(EntityDefinition, id, prefix: prefix) do
        %EntityDefinition{name: ^name} = definition ->
          {name, definition}

        _gone ->
          Repo.rollback({:refused, "rollback_not_recorded", %{}})
      end
    end)
  end

  defp entity_report(undo, targets, prefix) do
    reactivated =
      for {name, target} <- Enum.sort(targets) do
        current =
          case Definitions.get_active_definition_by_name(name, prefix) do
            {:ok, %EntityDefinition{} = definition} -> definition
            _none -> nil
          end

        %{
          "name" => name,
          "change" => "reactivated",
          "fields_not_in_target" => missing(current, target, "fields"),
          "indexes_not_in_target" => missing(current, target, "indexes")
        }
      end

    kept =
      for name <- Enum.sort(undo["new_types"]) do
        %{
          "name" => name,
          "change" => "kept_new_type",
          "fields_not_in_target" => [],
          "indexes_not_in_target" => []
        }
      end

    reactivated ++ kept
  end

  defp missing(nil, _target, _key), do: []

  defp missing(%EntityDefinition{} = current, %EntityDefinition{} = target, key) do
    (names(current, key) -- names(target, key)) |> Enum.sort()
  end

  defp names(%EntityDefinition{definition_json: json}, key) do
    for item <- List.wrap(Map.get(json, key)),
        is_map(item),
        name = Map.get(item, "name"),
        is_binary(name),
        do: name
  end

  defp count_drafts(module_id, hash, prefix) do
    from(p in ProcessDefinition,
      where: p.owner_module == ^module_id and p.owner_manifest_hash == ^hash,
      select: count(p.id)
    )
    |> Repo.one(prefix: prefix)
  end

  defp execute(row, candidate, undo, targets, base, actor_id, rationale, prefix) do
    Enum.each(Enum.sort(targets), fn {name, definition} ->
      activate(name, definition, actor_id, rationale, prefix)
    end)

    current = row.accepted_manifest_hashes || []

    accepted =
      if is_binary(row.manifest_hash) and row.manifest_hash not in current,
        do: current ++ [row.manifest_hash],
        else: current

    {:ok, _updated} =
      row
      |> TenantModule.upgrade_changeset(%{
        version: candidate.from_version,
        manifest_hash: undo["from_manifest_hash"],
        accepted_manifest_hashes: accepted
      })
      |> Repo.update(prefix: prefix)

    body = Map.merge(base, %{"state" => "done", "rollback_id" => nil})
    now = DateTime.utc_now()

    {:ok, journal} =
      %TenantModuleUpgrade{}
      |> TenantModuleUpgrade.changeset(%{
        module_id: row.module_id,
        from_version: row.version,
        to_version: candidate.from_version,
        kind: :rollback,
        state: :done,
        actor_id: actor_id,
        rationale: rationale,
        started_at: now,
        finished_at: now,
        touches: %{"reverses" => candidate.id, "result" => body}
      })
      |> Repo.insert(prefix: prefix)

    audit!(row, candidate, base, rationale, actor_id, prefix)

    %{body | "rollback_id" => journal.id}
  end

  defp activate(name, definition, actor_id, rationale, prefix) do
    already_active? =
      match?(
        {:ok, %EntityDefinition{id: id}} when id == definition.id,
        Definitions.get_active_definition_by_name(name, prefix)
      )

    if not already_active? do
      case Definitions.activate_definition_row(definition, actor_id, rationale, prefix) do
        {:ok, _activated} ->
          :ok

        {:error, {:decimal_strict_change, _fields}} ->
          Repo.rollback({:refused, "rollback_refused", %{"reason" => "decimal_strict_change"}})

        {:error, _other} ->
          Repo.rollback({:failed, "activation_refused"})
      end
    end
  end

  defp audit!(row, candidate, base, rationale, actor_id, prefix) do
    {:ok, _entry} =
      Audit.insert_entry(
        Repo,
        %{
          actor_id: actor_id,
          action: "module.rollback",
          resource_type: "tenant_module",
          resource_id: row.id,
          before_state: %{"module_id" => row.module_id, "version" => row.version},
          after_state: %{
            "module_id" => row.module_id,
            "version" => candidate.from_version,
            "reverses" => candidate.id,
            "step_ids" => [],
            "rationale" => rationale,
            "counts" => %{
              "entity_types" => length(base["entity_types"]),
              "process_drafts_kept" => base["process_drafts_kept"]
            }
          }
        },
        prefix
      )

    :ok
  end

  # A dry run that was refused: the same closed key set, nothing written.
  defp refused_report(module_id, target, code, extras, prefix) do
    from_version =
      case Repo.get_by(TenantModule, [module_id: module_id], prefix: prefix) do
        %TenantModule{version: version} -> version
        nil -> nil
      end

    %{
      "module_id" => module_id,
      "from_version" => from_version,
      "target_version" => target,
      "dry_run" => true,
      "state" => "dry_run",
      "rollback_possible" => false,
      "refusal" => code,
      "point_of_no_return" => point_of_no_return(code, extras, target),
      "entity_types" => [],
      "process_drafts_kept" => 0,
      "steps" => [],
      "rollback_id" => nil
    }
  end

  defp point_of_no_return("rollback_forbidden", %{"step_id" => id}, target) do
    %{
      "step_ids" => [id],
      "text" =>
        "Point of no return: step #{id} cannot be reversed, so going back to version #{target} is refused."
    }
  end

  defp point_of_no_return(_code, _extras, _target), do: nil

  defp step_id(id) when is_binary(id), do: id
  defp step_id(id) when is_atom(id), do: Atom.to_string(id)
  defp step_id(id), do: inspect(id)

  # After the rolled-back transaction: one `failed` row in a transaction of its own. Never raises.
  defp journal_failure(module_id, actor_id, rationale, target, code, prefix) do
    Repo.transaction(fn ->
      version =
        case Repo.get_by(TenantModule, [module_id: module_id], prefix: prefix) do
          %TenantModule{version: version} -> version
          nil -> "unknown"
        end

      %TenantModuleUpgrade{}
      |> TenantModuleUpgrade.changeset(%{
        module_id: module_id,
        from_version: version,
        to_version: target,
        kind: :rollback,
        state: :failed,
        actor_id: actor_id,
        rationale: rationale,
        error_code: code,
        finished_at: DateTime.utc_now()
      })
      |> Repo.insert!(prefix: prefix)
    end)

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Closed set; the exception text is never logged or returned (INV-4, INV-8).
  defp failure_code(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: "lock_timeout"
  defp failure_code(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: "apply_timeout"
  defp failure_code(_exception), do: "internal_error"
end
