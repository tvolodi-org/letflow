defmodule Letflow.Engine.ScriptTaskDispatcher do
  @moduledoc """
  GH 2534 PR 7c-1 (decision 0053 D2, D3, D5, D7, D8, D9, F-E): the SERVICE_TASK `script` route's
  dispatcher. Design: `lib/letflow/design/gh2534-7c-script-handler.md` sections 5-7 (C1-C6,
  C13-C16, C20, C21). Plain context module, no process; `Letflow.Engine.ScriptTaskDispatcher.Poller`
  calls `run_tick/2`, and tests call `run_tick/2`, `claim_next/1` and `run_claimed/2` directly.

  ## Row life cycle (table `script_task_dispatches`, C1)

  `pending` -> claim (transaction A: `running`, `attempt + 1`, lease) -> the run, holding NO
  transaction and NO pooled connection -> apply (transaction B,
  `Letflow.Engine.apply_script_task_result/3`): a CAS on `(id, instance_id, node_id, attempt,
  status = 'running')`, then the instance effect and the terminal status in the SAME
  transaction. A duplicate, late, swept or cancelled apply finds no row and writes nothing
  (`:stale`). Only `script_busy` goes back to `pending` (C5, capped); every other outcome is
  terminal on its first occurrence. An expired lease is swept into a `timeout` /
  `lease_expired` incident through the same CAS and is NEVER re-run (C6).

  ## Per-row pipeline (section 5.3, order normative)

  1-4 `Letflow.Scripts.Runtime.prepare_run/3` (kill switch, tenant status, version, manifest
  backstops incl. the run-time `check_reads` re-check, HMAC key) BEFORE admission and before
  any data read; 5 the input from the instance's own variables (field-minimal), plus, when the
  manifest declares `reads` (7c-2), the rows pre-fetched through the engine-defined
  `Letflow.Engine.ScriptReadPort` (implementation from `config :letflow, :script_read_port`,
  resolved per run; a port refusal is `script_rejected` / `reads_not_allowed` with no run);
  6 the HMAC of the canonical `{ctx, input}`; 7 the
  run, called FROM THE CALLING (poller) PROCESS so the 7a watchdog monitors it; 8 the output
  check (`$` keys refused, only declared properties kept); 9-10 apply or reschedule.

  ## Fairness (5.1a, SEC S2)

  `run_tick/2` serves tenants round-robin, at most ONE row per tenant per pass, under a global
  wall-time budget checked between rows; the start tenant rotates every tick.

  ## Never raises, never leaks (INV-8, SEC S3)

  Every per-row step runs inside `try/rescue/catch`; a catch is counted and logged as ONE line
  carrying only the dispatch id, the tenant schema and a class tag (`raised | thrown |
  exited`). Rescues bind no stacktrace and format nothing caught. Logs carry only ids, the
  tenant schema and closed codes.

  ## Test seams

  `:script_task_runner`, `:script_task_hmac_fun_override` (in `Scripts.Runtime`),
  `:script_task_apply_pause` (in the engine), `:script_task_cancel_pause` and
  `:script_task_sweep_fault` are honoured ONLY when `Application.get_env(:letflow,
  :scripts_test_hooks)` is exactly `true` (set only in `config/test.exs`; the application
  refuses to boot in `:prod` with it set, `Letflow.Scripts.Runtime.boot_check/2`).
  """

  import Ecto.Query

  require Logger

  alias Letflow.Engine.ScriptInput
  alias Letflow.Engine.ScriptTaskDispatcher.ScriptTaskDispatch
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Obs.Alerts
  alias Letflow.Repo
  alias Letflow.Scripts.Runtime
  alias Letflow.TenantProvisioning

  @platform_max_wall_ms 5_000
  @caller_margin_ms 2_000

  @defaults [
    poll_interval_ms: 1_000,
    tick_budget_ms: 10_000,
    max_dispatches_per_cycle: 16,
    sweep_limit: 64,
    sweep_failure_limit: 5,
    lease_margin_ms: 23_000,
    busy_retry_limit: 10,
    busy_backoff_base_ms: 500,
    busy_backoff_cap_ms: 30_000
  ]

  @type code :: Letflow.Engine.Lua.ScriptRunner.code()
  @type outcome :: :ok | code()
  @type detail ::
          :scripts_disabled
          | :tenant_inactive
          | :reads_not_allowed
          | :script_unavailable
          | :script_revoked
          | :pin_mismatch
          | :restricted_opt_in_unsupported
          | :output_schema_open
          | :hmac_secret_missing
          | :hmac_failed
          | :input_invalid
          | :output_decode
          | :output_not_object
          | :writes_not_allowed
          | :output_schema
          | :variable_schema_rejected
          | :busy_retries_exhausted
          | :lease_expired
          | :apply_failed
          | :no_matching_gateway_edge
          | :instance_not_active
          | :instance_cancelled
  @type claim :: %{
          dispatch_id: Ecto.UUID.t(),
          instance_id: Ecto.UUID.t(),
          node_id: String.t(),
          attempt: pos_integer()
        }
  @type run_facts :: %{
          row: ScriptTaskDispatch.t(),
          phase: :rejected | :ran | :lease_expired,
          outcome: outcome(),
          detail: detail() | nil,
          fail_code: String.t() | nil,
          hmac: {key_version :: pos_integer(), hex :: String.t()} | nil,
          stats:
            nil
            | %{
                duration_us: non_neg_integer(),
                instructions_used: non_neg_integer() | nil,
                heap_words: non_neg_integer() | nil,
                input_dropped: non_neg_integer() | nil
              }
        }
  @type run_record :: %{required(String.t()) => String.t() | integer() | nil}
  @type result ::
          {:ok, output :: map(), run_facts()}
          | {:failed, code(), detail() | nil, run_facts()}
  @type tick_summary :: %{
          tenants: non_neg_integer(),
          passes: non_neg_integer(),
          swept: non_neg_integer(),
          sweep_failed: non_neg_integer(),
          ran: non_neg_integer(),
          applied: non_neg_integer(),
          failed: non_neg_integer(),
          rescheduled: non_neg_integer(),
          stale: non_neg_integer(),
          cancelled: non_neg_integer(),
          budget_exhausted: boolean()
        }

  # ── config (read fresh per call) ─────────────────────────────────────────────

  @doc "One `config :letflow, :script_task_dispatcher` value, or its default."
  @spec config(atom()) :: integer()
  def config(key) do
    :letflow
    |> Application.get_env(:script_task_dispatcher, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc """
  The lease set at claim (C3): the platform maximum wall clock (5 s) plus the 7a caller margin
  (2 s) plus `lease_margin_ms` (clamped to at least 1 s); 30 s by default.
  """
  @spec lease_ms() :: pos_integer()
  def lease_ms,
    do: @platform_max_wall_ms + @caller_margin_ms + max(config(:lease_margin_ms), 1_000)

  @doc "Busy backoff (C5): `min(base * 2^busy_retries, cap)` ms, no jitter. Pure."
  @spec busy_backoff_ms(non_neg_integer()) :: pos_integer()
  def busy_backoff_ms(busy_retries) when is_integer(busy_retries) and busy_retries >= 0 do
    min(
      config(:busy_backoff_base_ms) * Integer.pow(2, busy_retries),
      config(:busy_backoff_cap_ms)
    )
  end

  # ── tick (5.1a) ──────────────────────────────────────────────────────────────

  @doc """
  One poller tick over `schemas`, starting at `offset rem length(schemas)`: a sweep pass, then
  run passes serving each tenant at most one row per pass (and at most
  `max_dispatches_per_cycle` rows PER TENANT per tick), stopping once `tick_budget_ms` has elapsed (the
  deadline is checked between rows). Returns the summary and `offset + 1`. Never raises.
  """
  @spec run_tick([String.t()], non_neg_integer()) :: {tick_summary(), non_neg_integer()}
  def run_tick(schemas, offset) when is_list(schemas) and is_integer(offset) and offset >= 0 do
    summary = empty_summary(length(schemas))

    case schemas do
      [] ->
        {summary, offset + 1}

      _ ->
        start = rem(offset, length(schemas))
        rotated = Enum.drop(schemas, start) ++ Enum.take(schemas, start)
        deadline = System.monotonic_time(:millisecond) + config(:tick_budget_ms)

        summary = Enum.reduce(rotated, summary, &sweep_tenant/2)
        summary = run_passes(rotated, deadline, %{}, MapSet.new(), summary)
        {summary, offset + 1}
    end
  end

  defp empty_summary(tenants) do
    %{
      tenants: tenants,
      passes: 0,
      swept: 0,
      sweep_failed: 0,
      ran: 0,
      applied: 0,
      failed: 0,
      rescheduled: 0,
      stale: 0,
      cancelled: 0,
      budget_exhausted: false
    }
  end

  defp sweep_tenant(prefix, summary) do
    %{swept: swept, failed: failed} = sweep_expired_leases(prefix, config(:sweep_limit))
    %{summary | swept: summary.swept + swept, sweep_failed: summary.sweep_failed + failed}
  rescue
    _ ->
      log_caught(nil, prefix, "raised")
      summary
  catch
    kind, _ ->
      log_caught(nil, prefix, class_tag(kind))
      summary
  end

  defp run_passes(rotated, deadline, counts, empty, summary) do
    cap = config(:max_dispatches_per_cycle)

    {ran_any?, counts, empty, summary} =
      Enum.reduce_while(rotated, {false, counts, empty, summary}, fn prefix,
                                                                     {ran_any?, counts, empty,
                                                                      summary} ->
        cond do
          MapSet.member?(empty, prefix) or Map.get(counts, prefix, 0) >= cap ->
            {:cont, {ran_any?, counts, empty, summary}}

          System.monotonic_time(:millisecond) >= deadline ->
            {:halt, {false, counts, empty, %{summary | budget_exhausted: true}}}

          true ->
            case claim_and_run(prefix) do
              :none ->
                {:cont, {ran_any?, counts, MapSet.put(empty, prefix), summary}}

              {:ran, outcome} ->
                {:cont,
                 {true, Map.update(counts, prefix, 1, &(&1 + 1)), empty,
                  count_outcome(summary, outcome)}}
            end
        end
      end)

    summary = %{summary | passes: summary.passes + 1}

    if ran_any? and not summary.budget_exhausted,
      do: run_passes(rotated, deadline, counts, empty, summary),
      else: summary
  end

  # One claim + run for one tenant. A raise in the claim marks the tenant empty for this tick;
  # a raise in the run is counted as a run (the row stays `running`; the sweep handles it).
  defp claim_and_run(prefix) do
    case safe_claim(prefix) do
      :none ->
        :none

      {:ok, row} ->
        outcome =
          try do
            run_claimed(row, prefix)
          rescue
            _ ->
              log_caught(row.id, prefix, "raised")
              :caught
          catch
            kind, _ ->
              log_caught(row.id, prefix, class_tag(kind))
              :caught
          end

        {:ran, outcome}
    end
  end

  defp safe_claim(prefix) do
    claim_next(prefix)
  rescue
    _ ->
      log_caught(nil, prefix, "raised")
      :none
  catch
    kind, _ ->
      log_caught(nil, prefix, class_tag(kind))
      :none
  end

  defp count_outcome(summary, outcome) do
    summary = %{summary | ran: summary.ran + 1}

    case outcome do
      {:ok, :applied} -> %{summary | applied: summary.applied + 1}
      {:ok, :failed} -> %{summary | failed: summary.failed + 1}
      {:ok, :rescheduled} -> %{summary | rescheduled: summary.rescheduled + 1}
      {:ok, :stale} -> %{summary | stale: summary.stale + 1}
      {:ok, :cancelled} -> %{summary | cancelled: summary.cancelled + 1}
      _apply_failed_or_caught -> summary
    end
  end

  defp class_tag(:throw), do: "thrown"
  defp class_tag(:exit), do: "exited"
  defp class_tag(_error), do: "raised"

  # SEC S3: the ONLY fields are the dispatch id, the tenant schema and the class tag.
  defp log_caught(dispatch_id, prefix, tag) do
    Logger.error("script task step caught",
      component: "script_task",
      dispatch_id: dispatch_id,
      tenant_schema: prefix,
      tag: tag
    )
  end

  # ── claim (5.2, transaction A) ───────────────────────────────────────────────

  @doc """
  Claims ONE due row: an unlocked select of candidate ids (`pending`, due, instance
  `:active`), then, in a short transaction, the first of them still `pending` locked
  `FOR UPDATE SKIP LOCKED` and set `running` with `attempt + 1`, `claimed_at`, the lease,
  `claimed_by` and `updated_at`. Returns the updated row, or `:none`.
  """
  @spec claim_next(String.t()) :: {:ok, ScriptTaskDispatch.t()} | :none
  def claim_next(prefix) when is_binary(prefix) do
    now = now()

    candidate_ids =
      ScriptTaskDispatch
      |> join(:inner, [d], p in InstanceProjection, on: p.instance_id == d.instance_id)
      |> where(
        [d, p],
        d.status == "pending" and d.next_attempt_at <= ^now and p.status == :active
      )
      |> order_by([d], asc: d.next_attempt_at, asc: d.id)
      |> limit(8)
      |> select([d], d.id)
      |> Repo.all(prefix: prefix)

    case candidate_ids do
      [] -> :none
      ids -> lock_and_claim(ids, prefix)
    end
  end

  defp lock_and_claim(ids, prefix) do
    Repo.transaction(fn ->
      locked =
        ScriptTaskDispatch
        |> where([d], d.id in ^ids and d.status == "pending")
        |> order_by([d], asc: d.next_attempt_at, asc: d.id)
        |> limit(1)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> select([d], d.id)
        |> Repo.one(prefix: prefix)

      case locked do
        nil ->
          :none

        id ->
          now = now()

          {1, [row]} =
            ScriptTaskDispatch
            |> where([d], d.id == ^id and d.status == "pending")
            |> select([d], d)
            |> Repo.update_all(
              [
                set: [
                  status: "running",
                  claimed_at: now,
                  lease_expires_at: DateTime.add(now, lease_ms(), :millisecond),
                  claimed_by: String.slice(Atom.to_string(node()), 0, 255),
                  updated_at: now
                ],
                inc: [attempt: 1]
              ],
              prefix: prefix
            )

          {:ok, row}
      end
    end)
    |> case do
      {:ok, {:ok, row}} -> {:ok, row}
      _none_or_error -> :none
    end
  end

  # ── per-row pipeline (5.3) ───────────────────────────────────────────────────

  @doc """
  Runs one claimed row through the pipeline (no transaction held) and applies or reschedules
  its result. A failed apply is followed by ONE transaction B' recording `script_rejected` /
  `apply_failed` through the same CAS; if that fails too the row stays `running` and the lease
  sweep turns it into an incident (never a silent stall, never a re-run).
  """
  @spec run_claimed(ScriptTaskDispatch.t(), String.t()) ::
          {:ok, :applied | :failed | :rescheduled | :cancelled | :stale}
          | {:error, :apply_failed}
  def run_claimed(%ScriptTaskDispatch{} = row, prefix) when is_binary(prefix) do
    claim = claim_of(row)

    case pipeline(row, prefix) do
      {:busy, facts} -> reschedule_busy(claim, facts, prefix) |> normalize_reschedule()
      result -> apply_with_followup(claim, result, prefix)
    end
  end

  defp normalize_reschedule({:ok, outcome}), do: {:ok, outcome}
  defp normalize_reschedule({:error, _reason}), do: {:error, :apply_failed}

  defp claim_of(row),
    do: %{
      dispatch_id: row.id,
      instance_id: row.instance_id,
      node_id: row.node_id,
      attempt: row.attempt
    }

  defp apply_with_followup(claim, result, prefix) do
    case Letflow.Engine.apply_script_task_result(claim, result, prefix) do
      {:ok, outcome} ->
        {:ok, outcome}

      {:error, _reason} ->
        facts = result_facts(result)

        followup =
          {:failed, :script_rejected, :apply_failed, %{facts | outcome: :script_rejected}}

        case Letflow.Engine.apply_script_task_result(claim, followup, prefix) do
          {:ok, outcome} ->
            {:ok, outcome}

          {:error, _reason} ->
            Logger.error("script task apply failed",
              component: "script_task",
              dispatch_id: claim.dispatch_id,
              tenant_schema: prefix,
              detail: "apply_failed"
            )

            {:error, :apply_failed}
        end
    end
  end

  defp result_facts({:ok, _output, facts}), do: facts
  defp result_facts({:failed, _code, _detail, facts}), do: facts

  defp pipeline(row, prefix) do
    binding = %{
      script_key: row.script_key,
      script_version: row.script_version,
      script_sha256: row.script_sha256
    }

    prepared =
      case TenantProvisioning.tenant_id_for_schema_name(prefix) do
        {:ok, tenant_id} -> Runtime.prepare_run(prefix, tenant_id, binding)
        _error -> {:rejected, :tenant_inactive}
      end

    case prepared do
      {:rejected, :hmac_secret_missing} ->
        Alerts.notify_script_hmac_secret_missing(prefix)
        rejected(row, :hmac_secret_missing)

      {:rejected, detail} ->
        rejected(row, detail)

      {:ok, spec} ->
        Alerts.clear_script_hmac_secret_missing(prefix)
        run_with_spec(row, spec, prefix)
    end
  end

  defp rejected(row, detail) do
    {:failed, :script_rejected, detail, facts(row, :rejected, :script_rejected, detail, nil)}
  end

  defp facts(row, phase, outcome, detail, hmac, stats \\ nil, fail_code \\ nil) do
    %{
      row: row,
      phase: phase,
      outcome: outcome,
      detail: detail,
      fail_code: fail_code,
      hmac: hmac,
      stats: stats
    }
  end

  defp run_with_spec(row, spec, prefix) do
    variables =
      case Repo.get_by(InstanceProjection, [instance_id: row.instance_id], prefix: prefix) do
        %InstanceProjection{variables: %{} = variables} -> variables
        _missing -> %{}
      end

    with {:ok, declared_vars} <- ScriptInput.build(variables, spec.manifest, nil),
         {:ok, reads_result} <- prefetch(spec.reads, declared_vars, prefix),
         input = ScriptInput.put_reads(declared_vars, reads_result),
         ctx = hmac_ctx(row),
         {:ok, hmac} <- spec.hmac_fun.(ScriptInput.canonical(input, ctx)) do
      run_script(row, spec, input, hmac, prefix)
    else
      {:error, :input_invalid} -> rejected(row, :input_invalid)
      {:error, :reads_not_allowed} -> rejected(row, :reads_not_allowed)
      _hmac_failed -> rejected(row, :hmac_failed)
    end
  end

  # 7c-2 (design 11.1): the read port is called only when the manifest declares reads, with the
  # run's own prefix and the script's declared input variables. Its implementation is resolved
  # from config on every run, so no engine file names it. Anything but `{:ok, map}` is a
  # refusal: no partial input, no run.
  defp prefetch([], _declared_vars, _prefix), do: {:ok, nil}

  defp prefetch(reads, declared_vars, prefix) when is_list(reads) do
    port = Application.fetch_env!(:letflow, :script_read_port)

    case port.prefetch(prefix, reads, declared_vars) do
      {:ok, %{} = rows} -> {:ok, rows}
      _refused -> {:error, :reads_not_allowed}
    end
  end

  defp hmac_ctx(row) do
    %{
      "instance_id" => row.instance_id,
      "node_id" => row.node_id,
      "token_id" => row.token_id,
      "now" => DateTime.to_iso8601(row.event_time)
    }
  end

  defp run_script(row, spec, input, hmac, prefix) do
    runner = runner()
    t0 = System.monotonic_time(:microsecond)

    result =
      runner.run(spec.source, input,
        tenant: prefix,
        ctx: %{
          instance_id: row.instance_id,
          node_id: row.node_id,
          token_id: row.token_id,
          now: row.event_time
        },
        fail_codes: spec.fail_codes,
        instructions: spec.limits.instructions,
        timeout_ms: spec.limits.timeout_ms,
        heap_words: spec.limits.heap_words
      )

    duration_us = System.monotonic_time(:microsecond) - t0

    base_stats = %{
      duration_us: duration_us,
      instructions_used: nil,
      heap_words: nil,
      input_dropped: nil
    }

    case result do
      {:ok, %{output: output, stats: stats}} ->
        run_stats = %{
          base_stats
          | instructions_used: stats[:instructions_used],
            heap_words: stats[:heap_words_at_end],
            input_dropped: stats[:input_dropped]
        }

        case Runtime.check_output(output, spec.manifest) do
          {:ok, declared} ->
            {:ok, declared, facts(row, :ran, :ok, nil, hmac, run_stats)}

          {:error, detail} ->
            {:failed, :output_invalid, detail,
             facts(row, :ran, :output_invalid, detail, hmac, run_stats)}
        end

      {:error, :script_busy, _detail} ->
        {:busy, facts(row, :ran, :script_busy, nil, hmac, base_stats)}

      {:error, :output_invalid, _detail} ->
        {:failed, :output_invalid, :output_decode,
         facts(row, :ran, :output_invalid, :output_decode, hmac, base_stats)}

      {:error, :script_failed, detail} ->
        fail_code =
          case detail do
            %{fail: %{code: code}} when is_binary(code) -> code
            _ -> nil
          end

        {:failed, :script_failed, nil,
         facts(row, :ran, :script_failed, nil, hmac, base_stats, fail_code)}

      {:error, code, _detail}
      when code in [
             :script_error,
             :budget_exceeded,
             :memory_limit_exceeded,
             :timeout,
             :script_rejected
           ] ->
        {:failed, code, nil, facts(row, :ran, code, nil, hmac, base_stats)}

      _unexpected ->
        {:failed, :script_error, nil, facts(row, :ran, :script_error, nil, hmac, base_stats)}
    end
  end

  # [CDV C2] the runner seam is honoured only under :scripts_test_hooks.
  defp runner do
    case Application.get_env(:letflow, :script_task_runner) do
      module when is_atom(module) and not is_nil(module) ->
        if Runtime.test_hooks?(), do: module, else: Letflow.Engine.Lua.ScriptRunner

      _ ->
        Letflow.Engine.Lua.ScriptRunner
    end
  end

  # ── busy reschedule (5.5) ────────────────────────────────────────────────────

  @doc """
  The `script_busy` path (C5): same CAS as the apply; below `busy_retry_limit` the row goes
  back to `pending` with `busy_retries + 1` and `next_attempt_at = now + busy_backoff_ms/1`, no
  event; at the limit the busy outcome is applied as a `script_busy` / `busy_retries_exhausted`
  incident.
  """
  @spec reschedule_busy(claim(), run_facts(), String.t()) ::
          {:ok, :rescheduled | :failed | :stale} | {:error, term()}
  def reschedule_busy(claim, facts, prefix) do
    limit = config(:busy_retry_limit)

    result =
      Repo.transaction(fn ->
        case lock_cas(claim, prefix) do
          nil ->
            :stale

          %ScriptTaskDispatch{busy_retries: retries} when retries < limit ->
            now = now()

            {1, _} =
              ScriptTaskDispatch
              |> cas_query(claim)
              |> Repo.update_all(
                [
                  set: [
                    status: "pending",
                    busy_retries: retries + 1,
                    next_attempt_at: DateTime.add(now, busy_backoff_ms(retries), :millisecond),
                    lease_expires_at: nil,
                    updated_at: now
                  ]
                ],
                prefix: prefix
              )

            :rescheduled

          %ScriptTaskDispatch{} ->
            :exhausted
        end
      end)

    case result do
      {:ok, :exhausted} ->
        apply_with_followup(
          claim,
          {:failed, :script_busy, :busy_retries_exhausted,
           %{facts | phase: :ran, outcome: :script_busy, detail: :busy_retries_exhausted}},
          prefix
        )

      {:ok, outcome} ->
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_cas(claim, prefix) do
    ScriptTaskDispatch
    |> cas_query(claim)
    |> lock("FOR UPDATE")
    |> Repo.one(prefix: prefix)
  end

  @doc false
  # The CAS predicate (C4), shared with Letflow.Engine.apply_script_task_result/3.
  @spec cas_query(Ecto.Queryable.t(), claim()) :: Ecto.Query.t()
  def cas_query(queryable, claim) do
    %{dispatch_id: id, instance_id: instance_id, node_id: node_id, attempt: attempt} = claim

    from(d in queryable,
      where:
        d.id == ^id and d.instance_id == ^instance_id and d.node_id == ^node_id and
          d.attempt == ^attempt and d.status == "running"
    )
  end

  # ── lease sweep (5.6, C6, C21) ───────────────────────────────────────────────

  @doc """
  Turns up to `limit` expired leases (`running`, `lease_expires_at < now`, fewer than
  `sweep_failure_limit` failed sweeps) into `timeout` / `lease_expired` incidents through the
  apply CAS. Never re-pends, never runs a script. A failed sweep apply increments
  `sweep_failures` (its own CAS update); reaching the limit logs ONE `sweep_stuck` error line
  and emits `[:letflow, :script_task, :sweep_stuck]`; other failures are reported as ONE
  aggregated warning per call (per tenant per tick) carrying only the count.
  """
  @spec sweep_expired_leases(String.t(), pos_integer()) :: %{
          swept: non_neg_integer(),
          failed: non_neg_integer()
        }
  def sweep_expired_leases(prefix, limit) when is_binary(prefix) and is_integer(limit) do
    now = now()
    failure_limit = config(:sweep_failure_limit)

    rows =
      ScriptTaskDispatch
      |> where(
        [d],
        d.status == "running" and d.lease_expires_at < ^now and d.sweep_failures < ^failure_limit
      )
      |> order_by([d], asc: d.lease_expires_at, asc: d.id)
      |> limit(^limit)
      |> Repo.all(prefix: prefix)

    {swept, failed, warn} =
      Enum.reduce(rows, {0, 0, 0}, fn row, {swept, failed, warn} ->
        case sweep_one(row, prefix) do
          :ok ->
            {swept + 1, failed, warn}

          :failed ->
            case record_sweep_failure(row, prefix, failure_limit) do
              :stuck -> {swept, failed + 1, warn}
              :counted -> {swept, failed + 1, warn + 1}
            end
        end
      end)

    if warn > 0 do
      Logger.warning("script task sweep failures",
        component: "script_task",
        tenant_schema: prefix,
        count: warn
      )
    end

    %{swept: swept, failed: failed}
  end

  defp sweep_one(row, prefix) do
    claim = claim_of(row)
    facts = facts(row, :lease_expired, :timeout, :lease_expired, nil)

    result =
      case sweep_fault(row.id) do
        :fail ->
          {:error, :forced}

        _ ->
          Letflow.Engine.apply_script_task_result(
            claim,
            {:failed, :timeout, :lease_expired, facts},
            prefix
          )
      end

    case result do
      {:ok, _applied_failed_cancelled_or_stale} -> :ok
      _error -> :failed
    end
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  defp sweep_fault(dispatch_id) do
    case Application.get_env(:letflow, :script_task_sweep_fault) do
      fun when is_function(fun, 1) -> if Runtime.test_hooks?(), do: fun.(dispatch_id), else: :ok
      _ -> :ok
    end
  end

  # Its own tiny CAS update; the transition to the limit is the ONE stuck report.
  defp record_sweep_failure(row, prefix, failure_limit) do
    {count, rows} =
      ScriptTaskDispatch
      |> where([d], d.id == ^row.id and d.status == "running" and d.attempt == ^row.attempt)
      |> select([d], d.sweep_failures)
      |> Repo.update_all([inc: [sweep_failures: 1], set: [updated_at: now()]], prefix: prefix)

    case {count, rows} do
      {1, [^failure_limit]} ->
        Logger.error("script task sweep stuck",
          component: "script_task",
          dispatch_id: row.id,
          tenant_schema: prefix,
          tag: "sweep_stuck"
        )

        :telemetry.execute(
          [:letflow, :script_task, :sweep_stuck],
          %{count: 1},
          %{dispatch_id: row.id, tenant_schema: prefix}
        )

        :stuck

      _other ->
        :counted
    end
  rescue
    _ -> :counted
  end

  # ── cancellation (5.6, CDV C5) ───────────────────────────────────────────────

  @doc """
  `Letflow.Engine.cancel_instance/3`'s `:script_task_dispatch_cancellations` step (after the
  HTTP dispatch step, BEFORE the projection lock: dispatch row -> projection, the apply's
  order). Sets the instance's `pending` AND `running` rows `cancelled` (`finished_at`,
  `outcome_detail = "instance_cancelled"`, `updated_at`). A running script finishes in its
  sandbox; its apply is then `:stale`.
  """
  @spec cancel_open_dispatches(module(), Ecto.UUID.t(), DateTime.t(), String.t()) ::
          {:ok, non_neg_integer()}
  def cancel_open_dispatches(repo, instance_id, at, prefix) do
    {count, _} =
      ScriptTaskDispatch
      |> where([d], d.instance_id == ^instance_id and d.status in ["pending", "running"])
      |> repo.update_all(
        [
          set: [
            status: "cancelled",
            finished_at: at,
            outcome_detail: "instance_cancelled",
            updated_at: at
          ]
        ],
        prefix: prefix
      )

    pause(:script_task_cancel_pause, :after_cancel)
    {:ok, count}
  end

  @doc false
  # The AC18a pause seams: a 1-arity function, honoured only under :scripts_test_hooks.
  @spec pause(atom(), atom()) :: :ok
  def pause(key, point) do
    case Application.get_env(:letflow, key) do
      fun when is_function(fun, 1) ->
        if Runtime.test_hooks?(), do: fun.(point)
        :ok

      _ ->
        :ok
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
