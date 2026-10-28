defmodule Letflow.Entities.WriteHook do
  @moduledoc """
  REQ-607 / GH #3413 part A (decision 0065 D8 slice E-3): the pre-write hook of `Letflow.Entities.Records`.

  `Records.create_record/3`, `update_record/3` and both branches of `upsert_record_by_external_ref/4`
  ask `lookup/3` whether the type has a binding (`entity_type_hook_bindings`). An unbound type, and
  every managed type (a managed type is never hooked, so the owning module's write is unchanged
  even if a binding row exists), takes today's path with nothing else run. A bound type goes through
  `attempts/3`: one `Letflow.Scripts.EntityWrite.run/4` per attempt, outside every lock, then the
  caller's `finish` builds the write whose transaction starts with `prelude/2`:

    1. `SET LOCAL lock_timeout = '2s'` and `SET LOCAL statement_timeout = '5s'` (the constants of
       `Letflow.Engine`'s `@entity_write_set_*`, 0054 D3 open point 4; constants only, INV-7);
    2. the `instance_sequences` row of the written type and of every read type, ascending by type
       name in byte order (the order the fingerprint is taken in; the written type once);
    3. the fingerprint compare: every read type's locked counter must equal the one the script's
       reads saw, else `{:error, :hook_fingerprint_mismatch}` before the first write.

  A mismatch re-runs the whole hook (read phase included); three attempts in total, then
  `{:error, :derived_value_conflict}`. `script_busy` shares that budget. A lock timeout, deadlock or
  statement timeout becomes `{:error, :entity_write_contention}`; any other exception while the hook
  runs becomes `{:error, :script_error}`. Errors are bare atoms (or `{:script_failed, code}`): no
  term holds source, key, version, sha256 or exception text.

  A caller already inside a transaction gets `{:error, :script_error}` before anything runs: the
  hook would otherwise run under the caller's locks and its `SET LOCAL`s would leak into that
  transaction. `Letflow.Scheduler.RecordDeadlineSweep` is such a caller, so a deadline transition of
  a hooked type is unsupported in this slice.

  Every `Repo` call passes `prefix:` (INV-1, INV-6); every query uses bound parameters (INV-7).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.WriteHookAudit
  alias Letflow.EntityTypeHooks.Binding
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.EventStore.Registry.ValidationFailure
  alias Letflow.Repo
  alias Letflow.Scripts.EntityWrite
  alias Letflow.Scripts.ScriptRule

  require Logger

  @max_attempts 3
  @backoff_ms 25
  @contention_codes [:lock_not_available, :deadlock_detected, :query_canceled]
  # The two `SET LOCAL` literals in `prelude/2` are the statements of `Letflow.Engine` (`@entity_write_set_*`).

  @type hook :: %{
          type: String.t(),
          prefix: String.t(),
          pin: %{script_key: String.t(), script_version: integer(), script_sha256: String.t()},
          derived_fields: [String.t()]
        }
  @type hook_ctx :: %{
          type: String.t(),
          prefix: String.t(),
          derived_fields: [String.t()],
          fingerprint: %{String.t() => integer()},
          locks: [{String.t(), Ecto.UUID.t()}],
          audit: map()
        }

  @doc """
  `{:hooked, hook}` for a non-managed type with a binding, else `:unbound`. A managed type is
  `:unbound` without any read.
  """
  @spec lookup(EntityDefinition.t(), String.t(), String.t()) :: {:hooked, hook()} | :unbound
  def lookup(%EntityDefinition{managed_by: managed_by}, _entity_type, _prefix)
      when not is_nil(managed_by),
      do: :unbound

  def lookup(%EntityDefinition{}, entity_type, prefix)
      when is_binary(entity_type) and is_binary(prefix) do
    case Repo.one(from(b in Binding, where: b.entity_type == ^entity_type, limit: 1),
           prefix: prefix
         ) do
      nil ->
        :unbound

      %Binding{} = binding ->
        {:hooked,
         %{
           type: entity_type,
           prefix: prefix,
           pin: %{
             script_key: binding.script_key,
             script_version: binding.script_version,
             script_sha256: binding.script_sha256
           },
           derived_fields: derived_fields(binding, prefix)
         }}
    end
  end

  # An absent or odd row gives `[]`; `EntityWrite.run/4` then answers its single rejection.
  defp derived_fields(binding, prefix) do
    rule =
      Repo.get_by(ScriptRule, [key: binding.script_key, version: binding.script_version],
        prefix: prefix
      )

    case rule do
      %ScriptRule{manifest: %{"derived_fields" => [_ | _] = names}} ->
        Enum.filter(names, &is_binary/1)

      _other ->
        []
    end
  end

  @doc "A payload naming a derived field is refused with the record validation error shape."
  @spec refuse_derived(hook(), map()) ::
          :ok | {:error, {:record_payload_invalid, [ValidationFailure.t()]}}
  def refuse_derived(%{derived_fields: derived}, payload) when is_map(payload) do
    case Enum.filter(derived, &Map.has_key?(payload, &1)) do
      [] ->
        :ok

      named ->
        {:error,
         {:record_payload_invalid,
          Enum.map(named, fn name ->
            %ValidationFailure{
              field_path: "/" <> name,
              constraint: "additionalProperties",
              actual: nil
            }
          end)}}
    end
  end

  @doc """
  Runs the hook for `candidate` and calls `finish.(derived, fingerprint, info)`; a `finish` result of
  `{:error, :hook_fingerprint_mismatch}` runs the whole hook again, at most #{@max_attempts}
  attempts in total.
  """
  @spec attempts(hook(), map(), (map(), map(), map() -> term())) :: term()
  def attempts(hook, candidate, finish) when is_function(finish, 3) do
    if Repo.in_transaction?(),
      do: {:error, :script_error},
      else: attempt(hook, candidate, finish, 1)
  end

  # `info` handed to `finish` and to the audit row: `%{attempts, stats, hmac}` of THIS attempt.
  # REQ-618: a final rejection decided by the hook itself (a code of the D6 table, including
  # the third `script_busy` and the third fingerprint mismatch) writes one rejected audit row.
  defp attempt(hook, candidate, finish, n) do
    case run_hook(hook, candidate) do
      {:ok, %{derived: derived, fingerprint: fingerprint}, info} ->
        info = Map.put(info, :attempts, n)

        case finish.(derived, fingerprint, info) do
          {:error, :hook_fingerprint_mismatch} when n < @max_attempts ->
            attempt(hook, candidate, finish, n + 1)

          {:error, :hook_fingerprint_mismatch} ->
            reject(hook, :derived_value_conflict, info)

          other ->
            other
        end

      {:error, :script_busy, _info} when n < @max_attempts ->
        Process.sleep(@backoff_ms * n)
        attempt(hook, candidate, finish, n + 1)

      {:error, code, info} ->
        reject(hook, code, Map.put(info, :attempts, n))
    end
  end

  # Contention is not a D6 outcome of the hook: nothing ran to a decision, nothing is audited.
  defp reject(_hook, :entity_write_contention, _info), do: {:error, :entity_write_contention}

  defp reject(hook, code, info) do
    WriteHookAudit.audit_rejected(hook, code, info, info.attempts)
    {:error, code}
  end

  @not_started %{duration_us: 0, instructions_used: nil, heap_words_at_end: nil}

  defp run_hook(hook, candidate) do
    facts = %{entity_type: hook.type, candidate: candidate, now: DateTime.utc_now()}

    case EntityWrite.run_audited(hook.prefix, hook.pin, facts, publisher_may_restricted?: false) do
      {{:ok, %{derived: _, fingerprint: _, stats: stats} = ok}, hmac} ->
        {:ok, ok, %{stats: stats, hmac: hmac}}

      {{:error, code, stats}, hmac} ->
        {:error, normalise(code), %{stats: stats, hmac: hmac}}
    end
  rescue
    exception ->
      {:error, code} = classify_exception(exception)
      {:error, code, %{stats: @not_started, hmac: nil}}
  catch
    _kind, _reason -> {:error, :script_error, %{stats: @not_started, hmac: nil}}
  end

  # D6 has no row for these two `EntityWrite` codes: the widened-restriction violation is an
  # invalid output, the input build failure a not-started rejection (assumptions A4 of the design).
  defp normalise(:script_output_restriction_widened), do: :output_invalid
  defp normalise(:input_invalid), do: :script_rejected
  defp normalise(code), do: code

  @doc false
  # The one classification of an exception raised while the hook runs or its write transaction.
  @spec classify_exception(Exception.t()) ::
          {:error, :entity_write_contention | :script_error}
  def classify_exception(exception) do
    if contention?(exception) do
      {:error, :entity_write_contention}
    else
      Logger.warning("entity write hook failed: #{inspect(exception.__struct__)}")
      {:error, :script_error}
    end
  end

  defp contention?(%Postgrex.Error{postgres: %{code: code}}), do: code in @contention_codes
  defp contention?(%DBConnection.ConnectionError{}), do: true
  defp contention?(_exception), do: false

  @doc """
  The write-side context of one attempt: the lock set (the written type and every read type,
  ascending by byte order, each once) with the registry id of each. Runs before the transaction.
  """
  @spec context(hook(), map(), map()) :: {:ok, hook_ctx()} | {:error, term()}
  def context(hook, fingerprint, info) when is_map(fingerprint) and is_map(info) do
    types = Enum.sort(Enum.uniq([hook.type | Map.keys(fingerprint)]))

    types
    |> Enum.reduce_while({:ok, []}, fn type, {:ok, acc} ->
      case EntityTypeInstance.get_or_create(type, hook.prefix) do
        {:ok, id} -> {:cont, {:ok, [{type, id} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, locks} ->
        {:ok,
         %{
           type: hook.type,
           prefix: hook.prefix,
           derived_fields: hook.derived_fields,
           fingerprint: fingerprint,
           locks: Enum.reverse(locks),
           audit: %{
             pin: hook.pin,
             actor_id: Map.get(hook, :actor_id),
             attempts: info.attempts,
             stats: info.stats,
             hmac: info.hmac
           }
         }}

      error ->
        error
    end
  end

  @doc "Prepends the timeouts, the lock set and the fingerprint compare to the write's Multi."
  @spec prelude(Multi.t(), hook_ctx() | nil) :: Multi.t()
  def prelude(multi, nil), do: multi

  def prelude(multi, %{prefix: prefix, locks: locks, fingerprint: fingerprint}) do
    multi
    |> Multi.run(:hook_set_lock_timeout, fn repo, _changes ->
      repo.query!("SET LOCAL lock_timeout = '2s'")
      {:ok, :set}
    end)
    |> Multi.run(:hook_set_statement_timeout, fn repo, _changes ->
      repo.query!("SET LOCAL statement_timeout = '5s'")
      {:ok, :set}
    end)
    |> then(fn acc ->
      Enum.reduce(locks, acc, fn {type, id}, multi_acc ->
        Multi.run(multi_acc, {:hook_lock, type}, fn repo, _changes ->
          EventStore.lock_instance_sequence(repo, id, prefix)
        end)
      end)
    end)
    |> Multi.run(:hook_compare, fn repo, _changes ->
      compare(repo, locks, fingerprint, prefix)
    end)
  end

  defp compare(repo, locks, fingerprint, prefix) do
    ids = Map.new(locks)

    matches? =
      Enum.all?(fingerprint, fn {type, seen} ->
        repo.one(
          from(s in InstanceSequence,
            where: s.instance_id == ^Map.fetch!(ids, type),
            select: s.next_seq
          ),
          prefix: prefix
        ) == seen
      end)

    if matches?, do: {:ok, :match}, else: {:error, :hook_fingerprint_mismatch}
  end

  @doc """
  Runs the hooked write transaction. A lock timeout, deadlock or statement timeout becomes
  `{:error, :entity_write_contention}`; any other exception is re-raised unchanged.
  """
  @spec guard((-> term())) :: term()
  def guard(fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception ->
      if contention?(exception),
        do: {:error, :entity_write_contention},
        else: reraise(exception, __STACKTRACE__)
  end
end
