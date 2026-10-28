defmodule Letflow.Scripts.EntityWrite do
  @moduledoc """
  REQ-601 / GH #3380 part B (decision 0065 D8, slice E-2): runs ONE pinned `entity_write` script
  (hook 1) for one record candidate and returns the derived field values with the read
  fingerprint. Pure of the engine: no route, no record write, no audit row, no lock (E-3 and
  later own those). The caller passes the tenant schema `prefix` (the only tenant selector;
  `facts` is never read for tenant data), the pinned version and the facts.

  ## Order of steps (a `with` chain; every failure is a tuple, nothing raises)

    1. the facts are checked (`entity_type`, a candidate with binary keys, `now`);
    2. the pinned row is loaded under `prefix`: `published` and `retired` rows run; an absent,
       draft, discarded or revoked row, another kind, a sha256 mismatch and a malformed pin are
       ONE result term (INV-5, INV-1);
    3. the closed output schema and `Letflow.Scripts.Policy.check_reads/2` against the CURRENT
       policy (every run): failure is the same rejection;
    4. every `derived_fields` name must be a field of the type's active definition and not
       scope-bearing (`Letflow.Entities.ScopeBearingField`): the same rejection;
    5. decision 0062 R5: `Letflow.Engine.VariableLabels.write_allowed?/3` over the manifest taint
       for every derived target; a failure to load the restricted set is a violation
       (`:script_output_restriction_widened`, sandbox never started);
    6. the input is built from the candidate (R6): a restricted candidate field is labelled
       `"<entity_type>.<field>"` and reaches the script only through a `restricted_inputs` entry
       whose `from` names that label AND only with `publisher_may_restricted?: true`;
    7. the read phase (`Letflow.Entities.ScriptReads.prefetch_with_fingerprint/3`), when the
       manifest declares reads;
    8. the sandbox runs;
    9. the result is converted to a stable tuple.

  `stats` is always `%{duration_us, instructions_used, heap_words_at_end}`; before the sandbox
  it is `duration_us: 0` with two `nil`. The returned term holds nothing of the source, key,
  version, sha256, author text or the fail payload. Do not call `run/4` inside a transaction
  when reads are declared (see `prefetch_with_fingerprint/3`).

  Test seams, honoured only when `Letflow.Scripts.Runtime.test_hooks?/0` is true:
  `:entity_write_script_runner` (the runner module) and `:entity_write_before_reads` (a
  zero-arity function called once, after the input is built and before the read phase).
  """

  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Engine.ScriptInput
  alias Letflow.Engine.VariableLabels
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.HiddenLabels
  alias Letflow.Entities.ScopeBearingField
  alias Letflow.Entities.ScriptReads
  alias Letflow.Repo
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.Runtime
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Scripts.Validation

  @hook_kind "entity_write"
  @runner_errors [
    :budget_exceeded,
    :memory_limit_exceeded,
    :timeout,
    :script_busy,
    :output_invalid,
    :script_error
  ]
  @stat_keys [:duration_us, :instructions_used, :heap_words_at_end]
  @not_started %{duration_us: 0, instructions_used: nil, heap_words_at_end: nil}
  @fallback_instance "entity-write"

  @type stats :: %{
          duration_us: non_neg_integer(),
          instructions_used: non_neg_integer() | nil,
          heap_words_at_end: non_neg_integer() | nil
        }
  @type error_code ::
          :script_rejected
          | :script_output_restriction_widened
          | :input_invalid
          | :script_error
          | :budget_exceeded
          | :memory_limit_exceeded
          | :timeout
          | :output_invalid
          | :script_busy

  @doc """
  Runs the pinned script `pin` (`%{script_key, script_version, script_sha256}`) under the tenant
  schema `prefix` on `facts` (`%{entity_type, candidate, now}`). Option
  `:publisher_may_restricted?` (default false) lets restricted candidate fields through the
  `restricted_inputs` label cover.
  """
  @spec run(String.t(), map(), map(), keyword()) ::
          {:ok, %{derived: map(), fingerprint: map(), stats: stats()}}
          | {:error, error_code() | {:script_failed, String.t()}, stats()}
  def run(prefix, pin, facts, opts \\ []) when is_binary(prefix) and is_list(opts) do
    with {:ok, type, candidate, now} <- check_facts(facts),
         {:ok, rule} <- load_row(prefix, pin),
         manifest = rule.manifest,
         :ok <- check_manifest(prefix, manifest),
         {:ok, targets} <- check_derived_fields(prefix, type, manifest),
         load = HiddenLabels.load_platform_hidden_labels(prefix),
         :ok <- check_r5(load, manifest, targets),
         {:ok, restricted} = load,
         {:ok, built} <-
           built_input(
             type,
             candidate,
             manifest,
             restricted,
             Keyword.get(opts, :publisher_may_restricted?, false) == true
           ),
         {:ok, input, fingerprint} <- read_phase(prefix, manifest, built) do
      execute(rule, input, fingerprint, prefix, type, now)
    end
  end

  defp rejected, do: {:error, :script_rejected, @not_started}

  defp check_facts(%{entity_type: type, candidate: candidate, now: %DateTime{} = now})
       when is_binary(type) and is_map(candidate) do
    if Enum.all?(Map.keys(candidate), &is_binary/1),
      do: {:ok, type, candidate, now},
      else: rejected()
  end

  defp check_facts(_facts), do: rejected()

  defp load_row(prefix, %{script_key: key, script_version: version, script_sha256: sha})
       when is_integer(version) and version > 0 and is_binary(sha) do
    rule =
      if Validation.key?(key),
        do: Repo.get_by(ScriptRule, [key: key, version: version], prefix: prefix)

    case rule do
      %ScriptRule{status: status, hook_kind: @hook_kind, sha256: ^sha}
      when status in [:published, :retired] ->
        {:ok, rule}

      _absent_draft_discarded_revoked_or_mismatch ->
        rejected()
    end
  end

  defp load_row(_prefix, _pin), do: rejected()

  defp check_manifest(prefix, manifest) do
    if Runtime.closed_output_schema?(manifest) and Policy.check_reads(prefix, manifest) == :ok,
      do: :ok,
      else: rejected()
  end

  defp check_derived_fields(prefix, type, manifest) do
    with [_ | _] = derived <- Map.get(manifest, "derived_fields"),
         true <- Enum.all?(derived, &is_binary/1),
         {:ok, definition} <- Definitions.get_active_definition_by_name(type, prefix),
         names = definition_field_names(definition),
         true <- Enum.all?(derived, &MapSet.member?(names, &1)),
         false <- Enum.any?(derived, &ScopeBearingField.scope_bearing?(definition, &1, prefix)) do
      {:ok, Enum.map(derived, &(type <> "." <> &1))}
    else
      _not_derivable -> rejected()
    end
  end

  defp definition_field_names(%{definition_json: %{"fields" => fields}}) when is_list(fields),
    do: for(%{"name" => name} when is_binary(name) <- fields, into: MapSet.new(), do: name)

  defp definition_field_names(_definition), do: MapSet.new()

  defp check_r5(load, manifest, targets) do
    if r5_violation?(load, Runtime.manifest_taint(manifest), targets),
      do: {:error, :script_output_restriction_widened, @not_started},
      else: :ok
  end

  @doc false
  # Decision 0062 R5. `load` is the raw `HiddenLabels.load_platform_hidden_labels/1` result: any
  # error is a violation (fail closed). Pure.
  @spec r5_violation?(term(), [String.t()], [String.t()]) :: boolean()
  def r5_violation?({:ok, %MapSet{} = restricted}, taint, targets) do
    not Enum.all?(targets, &VariableLabels.write_allowed?(taint, &1, restricted))
  end

  def r5_violation?(_load_error, _taint, _targets), do: true

  @doc false
  # Step 6 (decision 0062 R6). Labels each restricted candidate field `"<type>.<field>"`; unless
  # `publisher_may_restricted?` is true the `restricted_inputs` are emptied, so a labelled field
  # is omitted. Pure.
  @spec build_input(String.t(), map(), map(), MapSet.t(), boolean()) ::
          {:ok, map(), [String.t()]} | {:error, :input_invalid}
  def build_input(type, candidate, manifest, %MapSet{} = restricted, publisher_may_restricted?) do
    labels =
      for {field, _value} <- candidate,
          label = type <> "." <> field,
          MapSet.member?(restricted, label),
          into: %{},
          do: {field, [label]}

    for_build =
      if publisher_may_restricted?, do: manifest, else: Map.put(manifest, "restricted_inputs", [])

    ScriptInput.build(candidate, labels, for_build, nil)
  end

  defp built_input(type, candidate, manifest, restricted, may?) do
    case build_input(type, candidate, manifest, restricted, may?) do
      {:ok, built, _taint} -> {:ok, built}
      {:error, :input_invalid} -> {:error, :input_invalid, @not_started}
    end
  end

  defp read_phase(prefix, manifest, built) do
    case Validation.declared_reads(manifest) do
      [] ->
        {:ok, built, %{}}

      reads ->
        before_reads()

        case ScriptReads.prefetch_with_fingerprint(prefix, reads, built) do
          {:ok, rows, fingerprint} -> {:ok, ScriptInput.put_reads(built, rows), fingerprint}
          {:error, :reads_not_allowed} -> rejected()
        end
    end
  end

  defp execute(rule, input, fingerprint, prefix, type, now) do
    manifest = rule.manifest
    limits = Map.get(manifest, "limits", %{})

    opts = [
      tenant: prefix,
      fail_codes: Map.get(manifest, "fail_codes", []),
      ctx: %{
        instance_id: instance_id(type, prefix),
        node_id: type,
        token_id: "entity-write",
        now: now
      },
      instructions: limits["instructions"],
      heap_words: limits["heap_words"],
      timeout_ms: limits["timeout_ms"]
    ]

    started = System.monotonic_time(:microsecond)

    outcome =
      try do
        runner().run(rule.source, input, opts)
      catch
        _kind, _reason -> {:error, :script_error, %{}}
      end

    measured = %{
      duration_us: System.monotonic_time(:microsecond) - started,
      instructions_used: nil,
      heap_words_at_end: nil
    }

    convert(outcome, manifest, fingerprint, measured)
  end

  # Read only: an absent registry row never inserts one.
  defp instance_id(type, prefix) do
    case EntityTypeInstance.fetch_instance_id(type, prefix) do
      {:ok, id} -> id
      {:error, :not_found} -> @fallback_instance
    end
  end

  defp convert({:ok, %{output: output, stats: stats}}, manifest, fingerprint, measured) do
    stats = reported_stats(stats, measured)

    with {:ok, checked} <- Runtime.check_output(output, manifest),
         [] <- Map.keys(checked) -- Map.get(manifest, "derived_fields", []) do
      {:ok, %{derived: checked, fingerprint: fingerprint, stats: stats}}
    else
      _invalid -> {:error, :output_invalid, stats}
    end
  end

  defp convert({:error, code, _detail}, _manifest, _fingerprint, measured)
       when code in @runner_errors,
       do: {:error, code, measured}

  defp convert(
         {:error, :script_failed, %{fail: %{code: code}}},
         manifest,
         _fingerprint,
         measured
       )
       when is_binary(code) do
    if code in Map.get(manifest, "fail_codes", []),
      do: {:error, {:script_failed, code}, measured},
      else: {:error, :script_error, measured}
  end

  defp convert(_unknown, _manifest, _fingerprint, measured),
    do: {:error, :script_error, measured}

  defp reported_stats(%{} = stats, measured) do
    if Enum.all?(@stat_keys, &Map.has_key?(stats, &1)),
      do: Map.take(stats, @stat_keys),
      else: measured
  end

  defp reported_stats(_stats, measured), do: measured

  defp runner do
    if Runtime.test_hooks?(),
      do: Application.get_env(:letflow, :entity_write_script_runner, ScriptRunner),
      else: ScriptRunner
  end

  defp before_reads do
    with true <- Runtime.test_hooks?(),
         fun when is_function(fun, 0) <- Application.get_env(:letflow, :entity_write_before_reads) do
      fun.()
    end

    :ok
  end
end
