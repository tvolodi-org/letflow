defmodule Letflow.Scripts.FormValidation do
  @moduledoc """
  REQ-581 / GH #3298 (decision 0067 D9, slice F-2): runs ONE `form_validation` script (hook 3)
  and returns a typed verdict. Pure of the engine: no route, no task write, no audit row (F-3
  and F-4 own those). The caller passes the tenant schema `prefix`, the pinned version, the
  facts of the submit and options.

  ## Order of steps (a `with` chain; every failure is a tuple, nothing raises)

    1. the `Letflow.Scripts.form_validation_enabled?/0` flag (default off): off, the sandbox is
       never started and no row is read;
    2. the pinned row is loaded under the tenant `prefix` (the only tenant selector; `facts` is
       never read for tenant data). `published` and `retired` rows run; an absent, draft,
       discarded or revoked row, a kind other than `form_validation`, a sha256 mismatch and a
       malformed pin are ONE result term, so a caller cannot tell a version of another tenant
       from one that does not exist (INV-5, INV-1);
    3. the closed output schema and `Letflow.Scripts.Policy.check_restricted_inputs/2` against
       the CURRENT policy (decision 0062, every run): failure is the same rejection;
    4. the facts are checked (`:input_invalid` when malformed);
    5. restriction filter: unless `publisher_may_restricted?: true` is passed, the manifest's
       `restricted_inputs` are treated as empty, so every labelled variable is omitted; with the
       opt-in, `Letflow.Engine.ScriptInput.build/4` applies the decision 0062 R6 label cover;
    6. the sandbox runs with `fail_codes: []` and a wall clock of `min(manifest timeout_ms,
       max_timeout_ms/0)`;
    7. the result is converted: the runner's `:script_failed` and any unknown outcome become
       `:script_error` (REQ-581 open question 3); the runner's `detail` (author text, `fail`
       payload) is dropped; a successful output must pass the closed output schema and the
       verdict shape (`verdict/2`), else `:output_invalid`.

  ## Verdicts

  `{"ok": true}` is `{:ok, :accepted}`. `{"ok": false, "code": c, "fields": [{"field": f,
  "code": fc}]}` is `{:ok, {:refused, %{code: c, fields: [%{field: f, code: fc}]}}}` when `c` and
  every `fc` are in the manifest's `refusal_codes` (one list supplies both) and every `f` is in
  the manifest's `fields`. Anything else is `:output_invalid`. The returned term holds nothing
  of the source, key, version, sha256 or submitted values.

  `stats` is always `%{duration_us, instructions_used, heap_words_at_end}`; when the sandbox did
  not report, `instructions_used` and `heap_words_at_end` are `nil` (and `duration_us` is 0 when
  it was not started).

  ## Wall clock (criterion 7)

  Default 5 ms, cap 50 ms (`default_timeout_ms/0`, `max_timeout_ms/0`). Measured on the dev host
  (2 runs of 200 calls of `return { ok = true }` through the real `ScriptRunner`, worker spawn,
  sandbox creation and script, timed around `ScriptRunner.run/3` only): warm median 0.10 ms, max
  0.2 to 0.3 ms; the default is the max rounded up to the next 5 ms. The FIRST call in a fresh
  VM took about 60 ms (code loading), above the cap: a caller should warm the runner once.
  `ScriptRunner.limits/0` and the SERVICE_TASK
  path are unchanged. A database error while loading the row is not rescued here: it aborts the
  caller's transaction regardless, and F-3 owns that mapping.

  The row load repeats about a dozen lines of `Letflow.Scripts.Runtime`'s private
  `load_version/2` on purpose: that one is bound to `service_task` and stays untouched.
  """

  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Engine.ScriptInput
  alias Letflow.Repo
  alias Letflow.Scripts.Hash
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.Runtime
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Scripts.Validation

  @default_timeout_ms 5
  @max_timeout_ms 50
  @max_verdict_bytes 65_536
  @hook_kind "form_validation"
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

  @type stats :: %{
          duration_us: non_neg_integer(),
          instructions_used: non_neg_integer() | nil,
          heap_words_at_end: non_neg_integer() | nil
        }
  @type error_code ::
          :script_rejected
          | :input_invalid
          | :script_error
          | :budget_exceeded
          | :memory_limit_exceeded
          | :timeout
          | :output_invalid
          | :script_busy
  @type result ::
          {:ok, :accepted}
          | {:ok,
             {:refused, %{code: String.t(), fields: [%{field: String.t(), code: String.t()}]}}}
          | {:error, error_code(), stats()}

  @doc "The wall clock (ms) a manifest without `limits.timeout_ms` gets."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc "The wall-clock cap (ms) of hook 3; a manifest `timeout_ms` above it is lowered to it."
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  @doc """
  Runs the pinned script `pin` (`%{script_key, script_version, script_sha256}`) under the tenant
  schema `prefix` on `facts`
  (`%{variables, variable_labels, instance_id, token_id, form, task}`). Option
  `:publisher_may_restricted?` (default false) lets labelled variables through the
  `restricted_inputs` label cover.
  """
  @spec run(String.t(), map(), map(), keyword()) :: result()
  def run(prefix, pin, facts, opts \\ []) when is_binary(prefix) and is_list(opts) do
    with :ok <- check_flag(),
         {:ok, rule} <- load_row(prefix, pin),
         :ok <- check_manifest(prefix, rule.manifest),
         :ok <- check_facts(facts),
         {:ok, input} <- build_input(rule.manifest, facts, opts) do
      execute(rule, input, prefix, facts)
    end
  end

  defp rejected, do: {:error, :script_rejected, @not_started}

  defp check_flag do
    if Letflow.Scripts.form_validation_enabled?(), do: :ok, else: rejected()
  end

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
    if Runtime.closed_output_schema?(manifest) and
         Policy.check_restricted_inputs(prefix, manifest) == :ok,
       do: :ok,
       else: rejected()
  end

  defp check_facts(%{
         variables: variables,
         variable_labels: labels,
         instance_id: instance_id,
         token_id: token_id,
         form: %{
           definition_id: _,
           definition_version: _,
           node_id: node_id,
           schema_version_hash: _
         },
         task: %{id: _, node_id: _, assignee_kind: _, now: %DateTime{}}
       })
       when is_map(variables) and is_map(labels) and is_binary(instance_id) and
              is_binary(token_id) and is_binary(node_id),
       do: :ok

  defp check_facts(_facts), do: {:error, :input_invalid, @not_started}

  defp build_input(manifest, facts, opts) do
    for_build =
      if Keyword.get(opts, :publisher_may_restricted?, false) == true,
        do: manifest,
        else: Map.put(manifest, "restricted_inputs", [])

    case ScriptInput.build(facts.variables, facts.variable_labels, for_build, nil) do
      {:ok, built, _taint} ->
        %{form: form, task: task} = facts

        {:ok,
         %{
           "output" => built,
           "form" => %{
             "definition_id" => form.definition_id,
             "definition_version" => form.definition_version,
             "node_id" => form.node_id,
             "schema_version_hash" => form.schema_version_hash
           },
           "task" => %{
             "id" => task.id,
             "node_id" => task.node_id,
             "assignee_kind" => task.assignee_kind,
             "now" => DateTime.to_iso8601(task.now)
           }
         }}

      {:error, :input_invalid} ->
        {:error, :input_invalid, @not_started}
    end
  end

  defp execute(rule, input, prefix, facts) do
    manifest = rule.manifest
    limits = Map.get(manifest, "limits", %{})

    opts = [
      tenant: prefix,
      fail_codes: [],
      ctx: %{
        instance_id: facts.instance_id,
        node_id: facts.form.node_id,
        token_id: facts.token_id,
        now: facts.task.now
      },
      instructions: limits["instructions"],
      heap_words: limits["heap_words"],
      timeout_ms: min(limits["timeout_ms"] || @default_timeout_ms, @max_timeout_ms)
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

    convert(outcome, manifest, measured)
  end

  defp convert({:ok, %{output: output, stats: stats}}, manifest, measured) do
    stats = reported_stats(stats, measured)

    with true <- oversized?(output) == false,
         {:ok, checked} <- Runtime.check_output(empty_fields_as_list(output), manifest),
         {:ok, verdict} <- verdict(checked, manifest) do
      {:ok, verdict}
    else
      _invalid -> {:error, :output_invalid, stats}
    end
  end

  defp convert({:error, code, _detail}, _manifest, measured) when code in @runner_errors,
    do: {:error, code, measured}

  defp convert(_script_failed_or_unknown, _manifest, measured),
    do: {:error, :script_error, measured}

  # A Lua empty table decodes as `%{}` (`ScriptValue.decode/2`), so it is the only way a script
  # can write an empty `fields` list; read it as `[]` before the schema check.
  defp empty_fields_as_list(%{"fields" => fields} = output) when fields == %{},
    do: Map.put(output, "fields", [])

  defp empty_fields_as_list(output), do: output

  defp oversized?(output) do
    byte_size(Hash.canon(output)) > @max_verdict_bytes
  rescue
    _error -> true
  end

  defp reported_stats(%{} = stats, measured) do
    if Enum.all?(@stat_keys, &Map.has_key?(stats, &1)),
      do: Map.take(stats, @stat_keys),
      else: measured
  end

  defp reported_stats(_stats, measured), do: measured

  @doc """
  The verdict of a closed-schema-checked output against the manifest's `refusal_codes` and
  `fields`. Pure.
  """
  @spec verdict(term(), map()) :: {:ok, :accepted | {:refused, map()}} | :error
  def verdict(%{"ok" => true} = output, _manifest) when map_size(output) == 1,
    do: {:ok, :accepted}

  def verdict(%{"ok" => false, "code" => code, "fields" => fields} = output, manifest)
      when map_size(output) == 3 and is_binary(code) and is_list(fields) do
    codes = Map.get(manifest, "refusal_codes", [])
    names = Map.get(manifest, "fields", [])

    with true <- code in codes,
         {:ok, entries} <- field_entries(fields, codes, names) do
      {:ok, {:refused, %{code: code, fields: entries}}}
    else
      _invalid -> :error
    end
  end

  def verdict(_output, _manifest), do: :error

  defp field_entries(fields, codes, names) do
    Enum.reduce_while(fields, {:ok, []}, fn
      %{"field" => field, "code" => code} = entry, {:ok, acc}
      when map_size(entry) == 2 and is_binary(field) and is_binary(code) ->
        if field in names and code in codes,
          do: {:cont, {:ok, [%{field: field, code: code} | acc]}},
          else: {:halt, :error}

      _bad, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # The test seam is honoured only when `:scripts_test_hooks` is exactly true (config/test.exs).
  defp runner do
    if Runtime.test_hooks?(),
      do: Application.get_env(:letflow, :form_validation_script_runner, ScriptRunner),
      else: ScriptRunner
  end
end
