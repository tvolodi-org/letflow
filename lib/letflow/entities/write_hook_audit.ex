defmodule Letflow.Entities.WriteHookAudit do
  @moduledoc """
  REQ-618 / GH #3445 (decision 0065 D6, D8 slice E-4): the audit row of a hooked write.

  Every write that reaches the hook for a bound type appends exactly one `entity_write_hook.run`
  row to `audit_entries` for its final outcome (one row per write, not per retry; `attempts` says
  how many runs it took):

    * accepted: `audit_step/2` adds the row as a step of the write's `Ecto.Multi`, immediately
      before `:upsert_record_latest` (after the sequence locks, `:allocate_number` and the
      other checks, decision 0061 items 5, 5a, 6), so a failure of the record write rolls it
      back with the write;
    * rejected: `audit_rejected/4` writes it in its own transaction, after the write transaction
      has ended (the caller guarantees it is outside any transaction). A failure to write it is
      swallowed with one constant log line: the caller keeps the typed error (INV-8).

  `after_state` holds exactly the keys of `@after_state_keys`: the script pin, the HMAC of the
  canonical `{ctx, input}`, the outcome class, the attempt count, the run stats and the
  principal. Never a derived, input or candidate value, script source or error text
  (INV-4, INV-5, decision 0065 threat case 5). Every `Repo` call goes through `Letflow.Audit`
  with the tenant `prefix` (INV-1).
  """

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Repo

  require Logger

  @action "entity_write_hook.run"
  @after_state_keys [
    :script_key,
    :script_version,
    :script_sha256,
    :hmac_key_version,
    :hmac_hex,
    :outcome_class,
    :attempts,
    :duration_us,
    :instructions_used,
    :heap_words_at_end,
    :principal
  ]

  @doc "The action string of every row of this module."
  @spec action() :: String.t()
  def action, do: @action

  @doc "The exact key set of `after_state` (atoms; they are strings once stored)."
  @spec after_state_keys() :: [atom()]
  def after_state_keys, do: @after_state_keys

  @doc """
  The audit attrs of one hooked write. `audit` is `%{pin, actor_id, attempts, stats, hmac}`;
  `outcome` is `:accepted` or the D6 code (`{:script_failed, _}` is stored as `"script_failed"`:
  the manifest-declared code is not stored).
  """
  @spec attrs(map(), :accepted | atom() | {:script_failed, String.t()}, String.t(), String.t()) ::
          map()
  def attrs(audit, outcome, resource_type, resource_id) do
    {key_version, hex} = hmac_parts(audit.hmac)
    stats = audit.stats

    %{
      actor_id: audit.actor_id,
      action: @action,
      resource_type: resource_type,
      resource_id: resource_id,
      before_state: nil,
      after_state: %{
        script_key: audit.pin.script_key,
        script_version: audit.pin.script_version,
        script_sha256: audit.pin.script_sha256,
        hmac_key_version: key_version,
        hmac_hex: hex,
        outcome_class: outcome_class(outcome),
        attempts: audit.attempts,
        duration_us: stats.duration_us,
        instructions_used: stats.instructions_used,
        heap_words_at_end: stats.heap_words_at_end,
        principal: "tenant_wide"
      }
    }
  end

  @doc """
  Adds the accepted row as the step `:hook_audit` of `multi`; `multi` is returned unchanged for
  an unbound type (`ctx[:hook]` nil).
  """
  @spec audit_step(Multi.t(), map()) :: Multi.t()
  def audit_step(multi, %{hook: %{audit: audit}} = ctx) do
    attrs = attrs(audit, :accepted, ctx.entity_type, ctx.record_id)
    Audit.append_multi(multi, :hook_audit, attrs, ctx.prefix)
  end

  def audit_step(multi, _ctx), do: multi

  @doc """
  Writes the row of a rejected hooked write in its own transaction. `hook` is the lookup map
  with `:actor_id` and `:record_id` (nil for a create: the resource is then the type name).
  Never raises and never changes the caller's result.
  """
  @spec audit_rejected(map(), atom() | {:script_failed, String.t()}, map(), pos_integer()) :: :ok
  def audit_rejected(hook, code, info, attempts) do
    audit = %{
      pin: hook.pin,
      actor_id: Map.get(hook, :actor_id),
      attempts: attempts,
      stats: info.stats,
      hmac: info.hmac
    }

    attrs = attrs(audit, code, hook.type, Map.get(hook, :record_id) || hook.type)

    case Audit.insert_entry(Repo, attrs, hook.prefix) do
      {:ok, _entry} -> :ok
      _error -> not_written()
    end
  rescue
    _exception -> not_written()
  catch
    _kind, _reason -> not_written()
  end

  defp not_written do
    Logger.warning("entity write hook audit row not written")
    :ok
  end

  defp hmac_parts({key_version, hex}), do: {key_version, hex}
  defp hmac_parts(nil), do: {nil, nil}

  defp outcome_class(:accepted), do: "accepted"
  defp outcome_class({:script_failed, _code}), do: "script_failed"
  defp outcome_class(code) when is_atom(code), do: Atom.to_string(code)
end
