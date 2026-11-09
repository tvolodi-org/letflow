defmodule Letflow.ModuleUpgrade.Apply do
  @moduledoc """
  REQ-770 (decision 0080 Q1/Q2/Q5/Q6, amending 0055 D2/D5/D10): the module upgrade apply, behind
  `POST /api/v1/tenant/modules/:module_id/upgrade`. It applies an upgrade plan WITHOUT data steps in
  one transaction: the new entity-definition versions are created and activated, new process
  definitions are created as stamped drafts, the module's ledger storage is ensured, the replaced
  manifest hash joins `tenant_modules.accepted_manifest_hashes`, the row's version and hash are
  re-written, the journal row (the upgrade journal) becomes `done` and one `module.upgrade`
  audit entry is written. Declarative data steps (REQ-773: `set_default`, `backfill_from_constant`,
  `copy_field`) run in the same transaction through `Letflow.ModuleUpgrade.StepExec`, up to the
  record cap `Letflow.ModuleUpgrade.Settings.one_tx_max_records/0`; a plan with a code step, a step
  outside that vocabulary, or more records than the cap is refused (`upgrade_needs_runner`).

  The apply recomputes the plan with `Letflow.Modules.UpgradePlan.plan/3` inside its own transaction
  (same code the admin saw) and refuses a `plan_hash` that is not the recomputed one
  (`plan_mismatch`). A refusal rolls everything back and writes nothing. A failure after the first
  write rolls everything back and then writes one `failed` journal row in a transaction of its own.
  A repeat of a `done` plan answers the stored body with no write. The definition writing lives in
  `Letflow.Modules.Installs.apply_upgrade_pack/5` (caller-scan fences keep module-owner calls there).

  Not done here: `on_install/3` seeds are not re-run (a new seed is a step); the partial
  unique index on `running` rows (no `running` row is ever committed by a one-transaction apply; the
  transaction-level advisory lock is the exclusion).

  The journal row's `touches` also holds an `"undo"` block (the manifest hashes before and after and
  the ids of the entity-definition rows that were active before) that `Letflow.ModuleUpgrade.Rollback`
  needs; an upgrade row written before it existed cannot be rolled back.

  Tenancy: the schema is `opts[:prefix]` only (from the auth context in the router); the request
  body is read for exactly `rationale`, `plan_hash` and `ack_destructive` (INV-1).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Audit
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.Definitions
  alias Letflow.ModuleUpgrade.Rollback
  alias Letflow.ModuleUpgrade.Settings
  alias Letflow.ModuleUpgrade.StepExec
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.StepRecords
  alias Letflow.Modules.StepSpec
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Modules.UpgradePlan
  alias Letflow.Repo

  # Fixed constants (decision 0080 names only the record-count setting, which belongs to REQ-773).
  @lock_timeout "10s"
  @statement_timeout "120s"

  @type error ::
          :rationale_required
          | :plan_hash_required
          | :ack_destructive_invalid
          | :not_found
          | {:refused, String.t(), map()}
          | {:failed, String.t()}

  @doc """
  Applies the upgrade of `module_id` for the plan named in the body. `params` is the decoded
  request body (`rationale`, `plan_hash`, optional `ack_destructive`). Returns `{:ok, body}` (also for
  a repeat of a `done` plan) or `{:error, error()}`; `{:failed, "internal_error"}` is the only 500.
  """
  @spec apply_upgrade(String.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def apply_upgrade(module_id, actor_id, params, opts) when is_binary(module_id) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, rationale} <- fetch_rationale(params),
         {:ok, plan_hash} <- fetch_plan_hash(params),
         {:ok, ack} <- fetch_ack(params),
         {:ok, entry_module} <- fetch_entry(module_id),
         :ok <- installed?(module_id, prefix) do
      case replay(module_id, plan_hash, prefix) do
        {:ok, body} -> {:ok, body}
        :none -> run(entry_module, module_id, actor_id, rationale, plan_hash, ack, prefix)
      end
    end
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

  defp fetch_plan_hash(params) do
    case Map.get(params, "plan_hash") do
      value when is_binary(value) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
          do: {:ok, value},
          else: {:error, :plan_hash_required}

      _other ->
        {:error, :plan_hash_required}
    end
  end

  defp fetch_ack(params) do
    case Map.get(params, "ack_destructive", []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list |> Enum.uniq() |> Enum.sort()},
          else: {:error, :ack_destructive_invalid}

      _other ->
        {:error, :ack_destructive_invalid}
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

  # ── replay ─────────────────────────────────────────────────────────────────────────────

  defp replay(module_id, plan_hash, prefix) do
    reversed = Rollback.reversed_ids(module_id, prefix)

    rows =
      from(u in TenantModuleUpgrade,
        where:
          u.module_id == ^module_id and u.kind == :upgrade and u.state == :done and
            u.plan_hash == ^plan_hash,
        order_by: [desc: u.finished_at]
      )
      |> Repo.all(prefix: prefix)

    # A row a `done` rollback reversed is history, not an answer: the upgrade must run again.
    case Enum.find(rows, &(&1.id not in reversed)) do
      %TenantModuleUpgrade{touches: %{"result" => %{} = body}} -> {:ok, body}
      _none -> :none
    end
  end

  # ── the transaction ────────────────────────────────────────────────────────────────────

  defp run(entry_module, module_id, actor_id, rationale, plan_hash, ack, prefix) do
    outcome =
      try do
        Repo.transaction(fn ->
          transact(entry_module, module_id, actor_id, rationale, plan_hash, ack, prefix)
        end)
      rescue
        exception ->
          {:error, {:failed, failure_code(exception)}}
      catch
        _kind, _reason ->
          {:error, {:failed, "internal_error"}}
      end

    case outcome do
      {:ok, body} ->
        {:ok, body}

      {:error, {:refused, _code, _extras} = refusal} ->
        {:error, refusal}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, {:failed, code}} ->
        Logger.error("module upgrade apply failed: module_id=#{module_id} code=#{code}")
        journal_failure(module_id, actor_id, rationale, plan_hash, code, prefix)
        {:error, {:failed, code}}

      {:error, _other} ->
        Logger.error("module upgrade apply failed: module_id=#{module_id} code=internal_error")
        journal_failure(module_id, actor_id, rationale, plan_hash, "internal_error", prefix)
        {:error, {:failed, "internal_error"}}
    end
  end

  defp transact(entry_module, module_id, actor_id, rationale, plan_hash, ack, prefix) do
    Repo.query!("SET LOCAL lock_timeout = '#{@lock_timeout}'")
    Repo.query!("SET LOCAL statement_timeout = '#{@statement_timeout}'")

    # Same key as `UpgradePlan`'s blocking lock (re-entrant for this session).
    %{rows: [[locked?]]} =
      Repo.query!("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [
        prefix <> ":" <> module_id
      ])

    unless locked?, do: Repo.rollback({:refused, "upgrade_running", %{}})

    case replay(module_id, plan_hash, prefix) do
      {:ok, body} ->
        body

      :none ->
        apply_locked(entry_module, module_id, actor_id, rationale, plan_hash, ack, prefix)
    end
  end

  defp apply_locked(entry_module, module_id, actor_id, rationale, plan_hash, ack, prefix) do
    report =
      case UpgradePlan.plan(module_id, actor_id, prefix: prefix) do
        {:ok, report} ->
          report

        {:error, reason} when reason in [:unknown_module, :not_installed] ->
          Repo.rollback(:not_found)

        {:error, :plan_failed} ->
          Repo.rollback({:failed, "internal_error"})
      end

    if report["up_to_date"] == true or report["plan_hash"] != plan_hash do
      Repo.rollback({:refused, "plan_mismatch", %{}})
    end

    manifest = entry_module.manifest()

    exec =
      UpgradePlan.path_steps(manifest, report["from_version"], report["to_version"])
      |> UpgradePlan.executable_steps()

    # Re-counted under the advisory lock (decision 0080 Q5); field-independent for a restricted step.
    report = Map.put(report, "data_step_bound", UpgradePlan.data_step_bound(exec, prefix))

    case gate(report, ack, Settings.one_tx_max_records()) do
      :ok -> :ok
      {:error, {code, extras}} -> Repo.rollback({:refused, code, extras})
    end

    row =
      from(m in TenantModule, where: m.module_id == ^module_id, lock: "FOR UPDATE")
      |> Repo.one!(prefix: prefix)

    now = DateTime.utc_now()

    from(u in TenantModuleUpgrade,
      where: u.module_id == ^module_id and u.kind == :upgrade and u.state == :failed
    )
    |> Repo.update_all([set: [state: :abandoned, finished_at: now]], prefix: prefix)

    selection = selection(entry_module, report)
    previous = previous_definitions(selection.entities, prefix)

    pack_result =
      case Installs.apply_upgrade_pack(module_id, actor_id, rationale, selection, prefix: prefix) do
        {:ok, result} ->
          result

        {:error, {:activation_refused, _name, _reason}} ->
          Repo.rollback({:failed, "activation_refused"})

        {:error, :storage_refused} ->
          Repo.rollback({:failed, "storage_refused"})

        {:error, _other} ->
          Repo.rollback({:failed, "internal_error"})
      end

    data_results = run_data_steps(exec, report, module_id, actor_id, plan_hash, prefix)

    {accepted, appended?, failing} =
      accepted_hashes(row, module_id, pack_result.compiled_manifest_hash, report, prefix)

    {:ok, _updated} =
      row
      |> TenantModule.upgrade_changeset(%{
        version: report["to_version"],
        manifest_hash: pack_result.compiled_manifest_hash,
        accepted_manifest_hashes: accepted
      })
      |> Repo.update(prefix: prefix)

    counts = %{
      "entity_versions" => pack_result.entity_versions,
      "process_drafts" => length(pack_result.process_drafts),
      "ledger_ids" => pack_result.ledger_ids,
      "accepted_hashes_added" => if(appended?, do: 1, else: 0)
    }

    {body_steps, records_migrated} = data_step_body(data_results, exec, report, prefix)
    counts = counts |> Map.put("data_steps", length(exec)) |> put_migrated(records_migrated)

    audit!(
      row,
      report,
      plan_hash,
      ack,
      rationale,
      counts,
      Enum.map(exec, & &1.id),
      actor_id,
      prefix
    )

    body = %{
      "module_id" => module_id,
      "from_version" => report["from_version"],
      "to_version" => report["to_version"],
      "plan_hash" => plan_hash,
      "state" => "done",
      "upgrade_id" => report["plan_id"],
      "entity_versions_created" => pack_result.entity_versions,
      "process_drafts_created" => pack_result.process_drafts,
      "ledger_ids_ensured" => pack_result.ledger_ids,
      "accepted_hash_appended" => appended?,
      "failing_definitions" => failing,
      "data_steps" => body_steps,
      "records_migrated" => records_migrated
    }

    undo = %{
      "from_manifest_hash" => row.manifest_hash,
      "to_manifest_hash" => pack_result.compiled_manifest_hash,
      "previous_definitions" => previous,
      "new_types" => Enum.reject(selection.entities, &Map.has_key?(previous, &1))
    }

    finish_journal(report["plan_id"], actor_id, rationale, body, undo, now, prefix)
    body
  end

  # REQ-773: the data steps, in the apply's transaction, after the definitions are active. Nothing is
  # observable between the two inside one transaction, so this equals "between insert and
  # activation" of the requirement text. A failure rolls the whole apply back.
  defp run_data_steps([], _report, _module_id, _actor_id, _plan_hash, _prefix), do: []

  defp run_data_steps(exec, report, module_id, actor_id, plan_hash, prefix) do
    case StepExec.run_all(prefix, report["plan_id"], plan_hash, actor_id, module_id, exec) do
      {:ok, results} -> results
      {:error, :step_error} -> Repo.rollback({:failed, "step_error"})
      {:error, :step_raised} -> Repo.rollback({:failed, "step_raised"})
    end
  end

  # Per-step counts and the total, or none at all when ANY step touches a restricted field or a
  # type the actor cannot read (INV-2: the body and the audit chain are read by more than the
  # data readers, and a partial sum could be subtracted from).
  defp data_step_body([], _exec, _report, _prefix), do: {[], 0}

  defp data_step_body(results, exec, _report, prefix) do
    if Enum.any?(exec, &StepRecords.restricted?(&1.spec, prefix)) do
      {Enum.map(results, &Map.delete(&1, "records")), nil}
    else
      {results, Enum.reduce(results, 0, &(&1["records"] + &2))}
    end
  end

  defp put_migrated(counts, nil), do: counts
  defp put_migrated(counts, total), do: Map.put(counts, "records_migrated", total)

  # %{name => id of the entity-definition row that is ACTIVE now} for the types the upgrade touches
  # (the activation pointer is the authority, not the row status). What a rollback re-activates.
  defp previous_definitions(names, prefix) do
    Enum.reduce(names, %{}, fn name, acc ->
      case Definitions.get_active_definition_by_name(name, prefix) do
        {:ok, %{id: id}} -> Map.put(acc, name, id)
        _no_active_row -> acc
      end
    end)
  end

  # ── the gate (pure) ────────────────────────────────────────────────────────────────────

  @doc """
  The refusals that depend only on the recomputed `report`, the acknowledged step ids `ack` and the
  one-transaction record cap `cap`, in this order: no upgrade path, a Class C row, a Class B row
  with no covering step, the acknowledgement set (must equal the plan's step ids when a Class B row
  exists, else must be empty), a step this apply cannot run (a code step or an op outside the
  executable vocabulary), more records than `cap` (`report["data_step_bound"]`, re-counted by the
  caller). Returns `:ok` or `{:error, {code, extras}}`. Pure.
  """
  @spec gate(map(), [String.t()], pos_integer()) :: :ok | {:error, {String.t(), map()}}
  def gate(report, ack, cap) when is_map(report) and is_list(ack) and is_integer(cap) do
    rows = Map.get(report, "entity_types", [])
    steps = Map.get(report, "steps", [])
    class_c = Enum.filter(rows, &(&1["class"] == "C"))
    class_b = Enum.filter(rows, &(&1["class"] == "B"))
    uncovered = Enum.filter(class_b, &(&1["covered_by_steps"] != true))
    step_ids = steps |> Enum.map(& &1["id"]) |> Enum.uniq() |> Enum.sort()
    required = if class_b == [], do: [], else: step_ids

    cond do
      report["upgrade_path_available"] != true ->
        {:error, {"no_upgrade_path", %{}}}

      class_c != [] ->
        {:error, {"upgrade_forbidden", %{"reasons" => reasons(class_c)}}}

      uncovered != [] ->
        {:error,
         {"upgrade_forbidden",
          %{
            "reasons" =>
              Enum.map(uncovered, &%{"reason" => "step_required", "subject" => &1["name"]})
          }}}

      Enum.sort(Enum.uniq(ack)) != required ->
        {:error, {"ack_mismatch", %{}}}

      Enum.any?(steps, &(not runnable_step?(&1))) ->
        {:error, {"upgrade_needs_runner", %{}}}

      Map.get(report, "data_step_bound", 0) > cap ->
        {:error, {"upgrade_needs_runner", %{}}}

      true ->
        :ok
    end
  end

  defp runnable_step?(%{"kind" => "declarative", "op" => op}),
    do: op in Enum.map(StepSpec.executable_ops(), &Atom.to_string/1)

  defp runnable_step?(_step), do: false

  defp reasons(rows),
    do: Enum.map(rows, &%{"reason" => &1["reason"], "subject" => &1["name"]})

  # ── selection, accepted hashes, audit, journal ─────────────────────────────────────────

  defp selection(entry_module, report) do
    managed = Map.get(entry_module.manifest(), :manages_entity_types, [])

    changed =
      for %{"change" => change, "name" => name} <- report["entity_types"],
          change in ["new_type", "new_version"],
          do: name

    ordered = Enum.filter(managed, &(&1 in changed)) ++ Enum.sort(changed -- managed)

    processes =
      for %{"change" => "new_draft", "process_key" => key, "version" => version} <-
            report["process_definitions"],
          do: {key, version}

    %{entities: ordered, processes: processes, to_version: report["to_version"]}
  end

  # The hash the row held joins the accepted list only when every definition stamped with it passes
  # the activation check under the post-upgrade hashes (decision 0080 Q1); the list only grows.
  defp accepted_hashes(row, module_id, compiled_hash, report, prefix) do
    old = row.manifest_hash
    current = row.accepted_manifest_hashes || []

    failing =
      for %{"passes_activation" => false} = definition <- report["stamped_definitions"] do
        %{
          "name" => definition["name"],
          "version" => definition["version"],
          "violation_codes" => definition["violation_codes"]
        }
      end

    stamped_with_old =
      if is_binary(old) do
        from(p in ProcessDefinition,
          where: p.owner_module == ^module_id and p.owner_manifest_hash == ^old,
          select: {p.name, p.version}
        )
        |> Repo.all(prefix: prefix)
        |> MapSet.new()
      else
        MapSet.new()
      end

    old_failing? =
      Enum.any?(failing, &MapSet.member?(stamped_with_old, {&1["name"], &1["version"]}))

    if is_binary(old) and old != compiled_hash and old not in current and not old_failing? do
      {current ++ [old], true, failing}
    else
      {current, false, failing}
    end
  end

  defp audit!(row, report, plan_hash, ack, rationale, counts, step_ids, actor_id, prefix) do
    {:ok, _entry} =
      Audit.insert_entry(
        Repo,
        %{
          actor_id: actor_id,
          action: "module.upgrade",
          resource_type: "tenant_module",
          resource_id: row.id,
          before_state: %{"module_id" => row.module_id, "version" => report["from_version"]},
          after_state: %{
            "module_id" => row.module_id,
            "version" => report["to_version"],
            "plan_hash" => plan_hash,
            "step_ids" => step_ids,
            "ack_destructive" => ack,
            "rationale" => rationale,
            "counts" => counts
          }
        },
        prefix
      )

    :ok
  end

  defp finish_journal(plan_id, actor_id, rationale, body, undo, now, prefix) do
    {:ok, _row} =
      TenantModuleUpgrade
      |> Repo.get!(plan_id, prefix: prefix)
      |> TenantModuleUpgrade.changeset(%{
        state: :done,
        actor_id: actor_id,
        rationale: rationale,
        started_at: now,
        finished_at: DateTime.utc_now(),
        touches: %{"result" => body, "undo" => undo}
      })
      |> Repo.update(prefix: prefix)

    :ok
  end

  # After the rolled-back transaction: one `failed` row in a transaction of its own. Never raises.
  defp journal_failure(module_id, actor_id, rationale, plan_hash, code, prefix) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      existing =
        from(u in TenantModuleUpgrade,
          where:
            u.module_id == ^module_id and u.kind == :upgrade and u.state == :planned and
              u.plan_hash == ^plan_hash,
          order_by: [asc: u.id],
          limit: 1
        )
        |> Repo.one(prefix: prefix)

      row =
        existing ||
          %TenantModuleUpgrade{}
          |> TenantModuleUpgrade.changeset(%{
            module_id: module_id,
            from_version: failed_from_version(module_id, prefix),
            to_version: failed_to_version(module_id),
            kind: :upgrade,
            state: :planned,
            plan_hash: plan_hash
          })
          |> Repo.insert!(prefix: prefix)

      row
      |> TenantModuleUpgrade.changeset(%{
        state: :failed,
        error_code: code,
        actor_id: actor_id,
        rationale: rationale,
        finished_at: now
      })
      |> Repo.update!(prefix: prefix)
    end)

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp failed_from_version(module_id, prefix) do
    case Repo.get_by(TenantModule, [module_id: module_id], prefix: prefix) do
      %TenantModule{version: version} -> version
      nil -> "unknown"
    end
  end

  defp failed_to_version(module_id) do
    with {:ok, entry_module} <- Catalog.fetch(module_id) do
      entry_module.manifest().version
    else
      _other -> "unknown"
    end
  end

  # Closed set; the exception text is never logged or returned (INV-4, INV-8).
  defp failure_code(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: "lock_timeout"
  defp failure_code(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: "apply_timeout"
  defp failure_code(_exception), do: "internal_error"
end
