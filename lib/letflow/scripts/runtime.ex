defmodule Letflow.Scripts.Runtime do
  @moduledoc """
  GH 2534 PR 7c-1 (decision 0053 D2, D3, D5, D7 kill switch, D9): the ONE facade the engine
  and the definitions context call into the script registry (design
  `lib/letflow/design/gh2534-7c-script-handler.md` C18, sections 4.3, 4.5, 5.3, 8).

    * `pin_lookup/1` - the `PinResolver.Lookup` `script_lookup` closure (instance start).
    * `check_bindings/2` - the activation refusal, run inside the activating transaction by all
      three activation paths (`Definitions.activate/2`, promotion, version rollback).
    * `referenced_by_active_definition?/3` - the retire block (D3).
    * `prepare_run/3` - steps 1-4 of the per-row pipeline: kill switch, tenant status, version,
      manifest backstops and the run-time read re-check (`Policy.check_reads/2`), HMAC key.
      Every refusal is a closed detail code; nothing is cached across runs (7b-2a section 8).
    * `check_output/2`, `closed_output_schema?/1`, `declared_outputs/1` - pure output rules
      (C11, C11a).
    * `boot_check/2` - refuses `:scripts_test_hooks` in `:prod` (SECURITY note on the 7c gate).

  7c-2 (design 11.3): a binding may declare `reads`. Activation no longer refuses them; every
  run re-checks them against the tenant's CURRENT policy (`Policy.check_reads/2`: flagged type,
  active definition, no type restriction, known fields, and SEC N1 / P12: a `match.field`
  restricted now is refused), after the closed-output-schema refusal.
  The rows themselves are pre-fetched by the dispatcher through `Letflow.Engine.EntityPort`
  (`run_spec.reads`). The restricted opt-in (`restricted_inputs`, `reads[].restricted_fields`) is allowed since
  decision 0062 part 3 (the 0053 C10 limit is lifted): its outputs carry the run taint and
  `check_bindings/2` refuses a definition that would widen it (R5a).

  This module never calls `Letflow.Obs.Alerts` (C18: the dispatcher does) and holds no state.
  Every query is Ecto with bound parameters (INV-7), always in the caller's tenant prefix.
  """

  import Ecto.Query

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.ReservedReferences
  alias Letflow.Engine.ScriptInput
  alias Letflow.Engine.VariableLabels
  alias Letflow.Entities.HiddenLabels
  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.Identity
  alias Letflow.Repo
  alias Letflow.Scripts.HmacSecret
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Scripts.Validation

  @hook_kind "service_task"
  @form_hook_kind "form_validation"

  @type binding_reason ::
          :script_not_published
          | :script_version_conflict
          | :script_output_schema_open
          | :script_output_restriction_widened
          | :service_task_restricted_variable_reference

  @type binding :: %{
          script_key: String.t(),
          script_version: pos_integer(),
          script_sha256: String.t()
        }

  # Only what the pipeline reads (REVIEWER R3): the principal is derived by RunRecord from the
  # row (key, version), the declared outputs by check_output/2 from the manifest; `reads` is
  # the manifest's declared reads, handed to the read port (7c-2, `[]` = no port call).
  @type run_spec :: %{
          source: String.t(),
          manifest: map(),
          limits: %{
            instructions: pos_integer() | nil,
            timeout_ms: pos_integer() | nil,
            heap_words: pos_integer() | nil
          },
          fail_codes: [String.t()],
          reads: [map()],
          hmac_fun: HmacSecret.hmac_fun()
        }

  @type rejection ::
          :scripts_disabled
          | :tenant_inactive
          | :script_unavailable
          | :script_revoked
          | :pin_mismatch
          | :output_schema_open
          | :reads_not_allowed
          | :hmac_secret_missing

  # ── pins (design 4.3) ────────────────────────────────────────────────────────

  @doc """
  The `script_lookup` closure for `prefix`: one query of `script_rules` by `(key, version)`.
  `{:ok, %{resolved_id, version, sha256, hook_kind}}` ONLY for a `published` `service_task`
  version, or a `published` `form_validation` version while `Letflow.Scripts.form_validation_enabled?/0`
  holds (REQ-569); absent, draft, discarded, retired and revoked are all `{:error, :not_found}` (D1: a
  retired version gets no new pins). `hook_kind` lets the pin resolver check the kind against the
  node type that binds it.
  """
  @spec pin_lookup(String.t()) ::
          (String.t(), pos_integer() ->
             {:ok,
              %{
                required(:resolved_id) => String.t(),
                required(:version) => String.t(),
                required(:sha256) => String.t(),
                optional(:hook_kind) => String.t()
              }}
             | {:error, :not_found})
  def pin_lookup(prefix) when is_binary(prefix) do
    fn key, version ->
      with true <- Validation.key?(key) and is_integer(version) and version > 0,
           %ScriptRule{status: :published, hook_kind: hook_kind} = rule <-
             Repo.get_by(ScriptRule, [key: key, version: version], prefix: prefix),
           true <- pinnable_kind?(hook_kind) do
        {:ok,
         %{
           resolved_id: rule.id,
           version: Integer.to_string(rule.version),
           sha256: rule.sha256,
           hook_kind: rule.hook_kind
         }}
      else
        _ -> {:error, :not_found}
      end
    end
  end

  defp pinnable_kind?(@hook_kind), do: true
  defp pinnable_kind?(@form_hook_kind), do: Letflow.Scripts.form_validation_enabled?()
  defp pinnable_kind?(_other), do: false

  # ── activation refusal (design 4.5) ─────────────────────────────────────────

  @doc """
  The activation check (D2). For every `(key, version)` bound by a SERVICE_TASK node
  (`script_key`/`script_version`, a `service_task` version) or a HUMAN_TASK node
  (`validation_script_key`/`validation_script_version`, a `form_validation` version, REQ-569), in
  graph node order: a key already bound with a different version is `:script_version_conflict`
  (any mix of node types); the same key and version bound by the other node type is
  `:script_not_published` at the later node (one row has one kind); the row is read `FOR SHARE`
  (so a concurrent retire, which locks it `FOR UPDATE`, waits);
  anything but a `published` version of the node type's kind is `:script_not_published` (a
  `form_validation` version also needs `Letflow.Scripts.form_validation_enabled?/0`); then the
  closed output schema (C11a). Declared `reads` are allowed
  (7c-2) and re-checked on every run (`prepare_run/3`). Last (GH #2587 PR A1b, design 2A.2
  L9): a declared `input_schema` property in the reserved engine namespace
  (`VariableMerge.reserved_key?/1`) is `{:expression_references_reserved_variable, [ref]}`,
  `ref` naming the node and the property (`location: :script_input`), because
  `ScriptInput.build/4` reads declared inputs as exact flat keys. The first failing node is
  reported. Then the restriction flow (decision 0062 R5a, R12), SERVICE_TASK only (a validation
  hook writes nothing, decision 0067 D4): `:script_output_restriction_widened`
  and `:service_task_restricted_variable_reference`. MUST run inside the caller's transaction.
  """
  @spec check_bindings(Graph.t(), String.t()) ::
          :ok
          | {:error, {:script_binding_invalid, String.t(), binding_reason()}}
          | {:error,
             {:expression_references_reserved_variable,
              [Letflow.Definitions.ReservedReferences.reserved_reference()]}}
  def check_bindings(%Graph{nodes: nodes}, prefix) when is_binary(prefix) do
    nodes
    |> Enum.reduce_while({:ok, %{}}, fn node, {:ok, seen} ->
      case node_binding(node) do
        nil ->
          {:cont, {:ok, seen}}

        {key, version, kind} ->
          case check_one_binding(seen, key, version, prefix, kind) do
            :ok ->
              {:cont, {:ok, Map.put(seen, key, {version, kind})}}

            {:reserved_input, property} ->
              {:halt,
               {:error,
                {:expression_references_reserved_variable,
                 [reserved_input_reference(node.id, property)]}}}

            {:error, reason} ->
              {:halt, {:error, {:script_binding_invalid, node.id, reason}}}
          end
      end
    end)
    |> case do
      {:ok, _seen} -> check_restriction_flow(nodes, prefix)
      {:error, _} = error -> error
    end
  end

  defp node_binding(%{node_type: :SERVICE_TASK, attributes: attributes}) do
    with {key, version} <- script_binding(attributes), do: {key, version, @hook_kind}
  end

  defp node_binding(%{node_type: :HUMAN_TASK, attributes: attributes}) do
    with {key, version} <- validation_binding(attributes), do: {key, version, @form_hook_kind}
  end

  defp node_binding(_node), do: nil

  # ── restriction flow (decision 0062 R5a, R12; part 3) ────────────────────────

  # Static taint: every declared output of an opted-in script (a `restricted_inputs` `from` pair
  # or a declared read `restricted_fields`) is tainted with those labels wherever the graph reads
  # it (name based, no data flow: a name collision is a refusal the author fixes by renaming).
  # A tainted variable may not reach an entity write field outside its restriction set, a
  # `module_writes` argument, or a SERVICE_TASK URL / body template.
  defp check_restriction_flow(nodes, prefix) do
    tainted = tainted_outputs(nodes, prefix)

    if map_size(tainted) == 0 do
      :ok
    else
      restricted = HiddenLabels.load_platform_hidden_labels(prefix)

      Enum.find_value(nodes, :ok, fn node ->
        case flow_violation(node, tainted, restricted) do
          nil -> nil
          reason -> {:error, {:script_binding_invalid, node.id, reason}}
        end
      end)
    end
  end

  defp tainted_outputs(nodes, prefix) do
    nodes
    |> Enum.filter(&(&1.node_type == :SERVICE_TASK))
    |> Enum.reduce(%{}, fn node, acc ->
      with {key, version} <- script_binding(node.attributes),
           %{} = manifest <- bound_manifest(prefix, key, version),
           [_ | _] = taint <- manifest_taint(manifest) do
        manifest
        |> declared_outputs()
        |> Enum.reduce(acc, fn name, acc ->
          Map.update(acc, name, taint, &Enum.uniq(Enum.sort(&1 ++ taint)))
        end)
      else
        _ -> acc
      end
    end)
  end

  defp bound_manifest(prefix, key, version) do
    if Validation.key?(key) and is_integer(version) and version > 0 do
      Repo.one(
        from(r in ScriptRule,
          where: r.key == ^key and r.version == ^version and r.status == :published,
          select: r.manifest,
          lock: "FOR SHARE"
        ),
        prefix: prefix
      )
    end
  end

  @doc """
  The sorted `"entity_type.field"` labels a script run with this manifest is tainted by: its
  `restricted_inputs` `from` pairs plus the read taint (decision 0062 R5). Pure.
  """
  @spec manifest_taint(map()) :: [String.t()]
  def manifest_taint(manifest) do
    from_labels =
      manifest
      |> Validation.restricted_input_entries()
      |> Enum.flat_map(& &1["from"])
      |> Enum.map(&(&1["entity_type"] <> "." <> &1["field"]))

    (from_labels ++ ScriptInput.read_taint(Validation.declared_reads(manifest)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp flow_violation(%{attributes: attrs} = node, tainted, restricted) when is_map(attrs) do
    cond do
      Enum.any?(entity_write_vars(attrs), &widened?(&1, tainted, restricted)) ->
        :script_output_restriction_widened

      Enum.any?(module_write_vars(attrs), &Map.has_key?(tainted, &1)) ->
        :script_output_restriction_widened

      node.node_type == :SERVICE_TASK and
          ReservedReferences.restricted_reference_keys(
            [Map.get(attrs, "endpoint"), Map.get(attrs, "body_template")],
            MapSet.new(Map.keys(tainted))
          ) != [] ->
        :service_task_restricted_variable_reference

      true ->
        nil
    end
  end

  defp flow_violation(_node, _tainted, _restricted), do: nil

  # `{target label, variable}` of every `var` field of the node's entity_writes lines.
  defp entity_write_vars(attrs) do
    for %{"entity_type" => type, "fields" => %{} = fields} <- list_of(attrs["entity_writes"]),
        is_binary(type),
        {field, %{"var" => var}} <- fields,
        is_binary(var),
        do: {type <> "." <> to_string(field), var}
  end

  defp module_write_vars(attrs) do
    for %{"args" => %{} = args} <- list_of(attrs["module_writes"]),
        {_name, %{"var" => var}} <- args,
        is_binary(var),
        do: var
  end

  defp list_of(list) when is_list(list), do: list
  defp list_of(_other), do: []

  defp widened?({target, var}, tainted, restricted) do
    case Map.fetch(tainted, var) do
      {:ok, taint} ->
        case restricted do
          {:ok, set} -> not VariableLabels.write_allowed?(taint, target, set)
          _error -> true
        end

      :error ->
        false
    end
  end

  defp script_binding(attributes) when is_map(attributes) do
    case Map.get(attributes, "script_key") do
      key when is_binary(key) and key != "" -> {key, Map.get(attributes, "script_version")}
      _ -> nil
    end
  end

  defp script_binding(_attributes), do: nil

  defp validation_binding(attributes) when is_map(attributes) do
    case Map.get(attributes, "validation_script_key") do
      key when is_binary(key) and key != "" ->
        {key, Map.get(attributes, "validation_script_version")}

      _ ->
        nil
    end
  end

  defp validation_binding(_attributes), do: nil

  defp check_one_binding(seen, key, version, prefix, kind) do
    case Map.fetch(seen, key) do
      {:ok, {^version, ^kind}} -> :ok
      {:ok, {^version, _other_kind}} -> {:error, :script_not_published}
      {:ok, {_other_version, _kind}} -> {:error, :script_version_conflict}
      :error -> check_binding_row(key, version, prefix, kind)
    end
  end

  defp check_binding_row(key, version, prefix, kind) do
    rule =
      if Validation.key?(key) and is_integer(version) and version > 0 do
        Repo.one(
          from(r in ScriptRule,
            where: r.key == ^key and r.version == ^version,
            lock: "FOR SHARE"
          ),
          prefix: prefix
        )
      end

    case rule do
      %ScriptRule{status: :published, hook_kind: ^kind, manifest: manifest} ->
        cond do
          not pinnable_kind?(kind) -> {:error, :script_not_published}
          closed_output_schema?(manifest) -> check_reserved_inputs(manifest)
          true -> {:error, :script_output_schema_open}
        end

      _absent_or_not_published ->
        {:error, :script_not_published}
    end
  end

  # GH #2587 PR A1b (design 2A.2 L9): the sorted input_schema property names, the first
  # reserved one refuses the binding. A missing or non-object properties map has no names.
  defp check_reserved_inputs(manifest) do
    properties =
      case manifest do
        %{"input_schema" => %{"properties" => %{} = properties}} -> properties
        _no_properties -> %{}
      end

    properties
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find(&VariableMerge.reserved_key?/1)
    |> case do
      nil -> :ok
      property -> {:reserved_input, property}
    end
  end

  defp reserved_input_reference(node_id, property),
    do: ReservedReferences.reference(:node, node_id, :script_input, property, property)

  # ── retire block (design 4.5, C19) ───────────────────────────────────────────

  @doc """
  Whether an ACTIVE process definition binds `(key, version)` (a SERVICE_TASK `script_key` pair or a
  HUMAN_TASK `validation_script_key` pair): one query over
  `process_definitions` (through the leaf schema module, no call into the
  `Letflow.Definitions` context) with the jsonb containment document passed as a BOUND
  parameter (INV-7).
  """
  @spec referenced_by_active_definition?(String.t(), String.t(), pos_integer()) :: boolean()
  def referenced_by_active_definition?(prefix, key, version)
      when is_binary(prefix) and is_binary(key) and is_integer(version) do
    document = %{
      "nodes" => [%{"attributes" => %{"script_key" => key, "script_version" => version}}]
    }

    validation_document = %{
      "nodes" => [
        %{
          "attributes" => %{
            "validation_script_key" => key,
            "validation_script_version" => version
          }
        }
      ]
    }

    Repo.exists?(
      from(d in ProcessDefinition,
        where:
          d.status == :active and
            (fragment("? @> ?", d.graph, type(^document, :map)) or
               fragment("? @> ?", d.graph, type(^validation_document, :map)))
      ),
      prefix: prefix
    )
  end

  # ── run (design 5.3 steps 1-4) ───────────────────────────────────────────────

  @doc """
  Steps 1-4 of the per-row pipeline, before admission and before any data read:

    1. the effective kill switch (`scripts_disabled`), then the tenant status
       (`tenant_inactive` unless `:active`, SEC S5);
    2. the version by `(key, version)`: absent/draft/discarded `script_unavailable`, revoked
       `script_revoked`, a sha256 or hook-kind mismatch `pin_mismatch` (published and retired
       run, D1);
    3. manifest backstops, in this order (design 11.3, first failure wins): open output schema
       `output_schema_open`; then `Policy.check_reads/2` (reads and `restricted_inputs` `from`
       pairs) against the CURRENT policy `reads_not_allowed` (including SEC N1: a `match.field` restricted after publish
       is refused here, before any record query);
    4. the tenant HMAC key: `hmac_secret_missing` when absent. Nothing creates a key here.

  Read fresh on every call; nothing is cached.
  """
  @spec prepare_run(String.t(), Ecto.UUID.t(), binding()) ::
          {:ok, run_spec()} | {:rejected, rejection()}
  def prepare_run(prefix, tenant_id, %{} = binding) when is_binary(prefix) do
    with :ok <- check_enabled(prefix),
         :ok <- check_tenant_active(tenant_id),
         {:ok, rule} <- load_version(prefix, binding),
         :ok <- check_manifest(prefix, rule.manifest),
         {:ok, hmac_fun} <- resolve_hmac_fun(tenant_id) do
      manifest = rule.manifest
      limits = Map.get(manifest, "limits", %{})

      {:ok,
       %{
         source: rule.source,
         manifest: manifest,
         limits: %{
           instructions: limits["instructions"],
           timeout_ms: limits["timeout_ms"],
           heap_words: limits["heap_words"]
         },
         # never nil: a nil :fail_codes would make ScriptRunner accept ANY well-formed code
         fail_codes: manifest["fail_codes"] || [],
         reads: Validation.declared_reads(manifest),
         hmac_fun: hmac_fun
       }}
    end
  end

  defp check_enabled(prefix) do
    if Policy.kill_switch_on?(prefix), do: {:rejected, :scripts_disabled}, else: :ok
  end

  defp check_tenant_active(tenant_id) do
    case Identity.get_tenant(tenant_id) do
      {:ok, %{status: :active}} -> :ok
      _inactive_migrating_or_missing -> {:rejected, :tenant_inactive}
    end
  end

  defp load_version(prefix, %{script_key: key, script_version: version, script_sha256: sha}) do
    rule =
      if Validation.key?(key) and is_integer(version) and version > 0,
        do: Repo.get_by(ScriptRule, [key: key, version: version], prefix: prefix)

    case rule do
      %ScriptRule{status: :revoked} ->
        {:rejected, :script_revoked}

      %ScriptRule{status: status} = rule when status in [:published, :retired] ->
        if rule.sha256 == sha and rule.hook_kind == @hook_kind,
          do: {:ok, rule},
          else: {:rejected, :pin_mismatch}

      _absent_draft_or_discarded ->
        {:rejected, :script_unavailable}
    end
  end

  # Design 11.3 step order: 3a closed output schema, 3b the run-time re-check of the reads and
  # the restricted_inputs `from` pairs against the CURRENT policy (never cached). The restricted
  # opt-in itself is allowed since decision 0062 part 3 (C10 lifted).
  defp check_manifest(prefix, manifest) do
    cond do
      not closed_output_schema?(manifest) -> {:rejected, :output_schema_open}
      Policy.check_reads(prefix, manifest) != :ok -> {:rejected, :reads_not_allowed}
      true -> :ok
    end
  end

  # Design 7.2: the :script_task_hmac_fun_override seam replaces HmacSecret.hmac_fun/1 ONLY
  # when :scripts_test_hooks is exactly true (config/test.exs); anywhere else it is ignored.
  defp resolve_hmac_fun(tenant_id) do
    override = Application.get_env(:letflow, :script_task_hmac_fun_override)

    result =
      if test_hooks?() and is_function(override, 1),
        do: override.(tenant_id),
        else: HmacSecret.hmac_fun(tenant_id)

    case result do
      {:ok, fun} when is_function(fun, 1) -> {:ok, fun}
      _missing -> {:rejected, :hmac_secret_missing}
    end
  end

  @doc """
  The script-key rule (`^[a-z][a-z0-9_]{0,63}$`) for the engine side: delegates to the canonical
  `Letflow.Scripts.Validation.key?/1` (REVIEWER R5). Pure.
  """
  @spec script_key?(term()) :: boolean()
  def script_key?(key), do: Validation.key?(key)

  @doc "Whether the 7b/7c test seams are honoured (`:scripts_test_hooks` exactly `true`)."
  @spec test_hooks?() :: boolean()
  def test_hooks?, do: Application.get_env(:letflow, :scripts_test_hooks, false) == true

  # ── output rules (design 5.3 step 8, 8.2; C11, C11a) ─────────────────────────

  @doc """
  The binding's closed-output-schema rule (C11a, identical at activation, in `prepare_run/3`
  and at apply): `output_schema` is an object schema (`"type": "object"`) with a NON-EMPTY
  `properties` map and `"additionalProperties": false` at the top level. Pure.
  """
  @spec closed_output_schema?(term()) :: boolean()
  def closed_output_schema?(%{"output_schema" => %{} = schema}) do
    Map.get(schema, "type") == "object" and
      match?(%{} = props when map_size(props) > 0, Map.get(schema, "properties")) and
      Map.get(schema, "additionalProperties") == false
  end

  def closed_output_schema?(_manifest), do: false

  @doc "The top-level `output_schema.properties` names (`[]` when there are none). Pure."
  @spec declared_outputs(term()) :: [String.t()]
  def declared_outputs(%{"output_schema" => %{"properties" => %{} = props}}),
    do: props |> Map.keys() |> Enum.sort()

  def declared_outputs(_manifest), do: []

  @doc """
  The run-time output check, in this order: not a map `:output_not_object`; any top-level key
  starting with `$` `:writes_not_allowed` (C11, the reserved host-channel namespace, checked
  BEFORE the schema); a key not declared, or a schema failure, `:output_schema` (C11a). On
  success ONLY the declared properties are returned (`Map.take/2`). Pure.
  """
  @spec check_output(term(), map()) ::
          {:ok, map()} | {:error, :output_not_object | :writes_not_allowed | :output_schema}
  def check_output(output, manifest) when is_map(output) and is_map(manifest) do
    declared = declared_outputs(manifest)

    cond do
      writes_key?(output) ->
        {:error, :writes_not_allowed}

      Enum.any?(Map.keys(output), &(&1 not in declared)) ->
        {:error, :output_schema}

      JsonSchema.validate(output, Map.get(manifest, "output_schema", %{})) != [] ->
        {:error, :output_schema}

      true ->
        {:ok, Map.take(output, declared)}
    end
  end

  def check_output(_output, _manifest), do: {:error, :output_not_object}

  @doc """
  C11 recognition: `output` is a map and at least one top-level key, as a binary, starts with
  byte `$`. Nested `$` keys are plain data. Pure.
  """
  @spec writes_key?(term()) :: boolean()
  def writes_key?(output) when is_map(output),
    do: Enum.any?(Map.keys(output), &match?("$" <> _, to_key(&1)))

  def writes_key?(_output), do: false

  defp to_key(key) when is_binary(key), do: key
  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(_key), do: ""

  # ── boot guard (SECURITY note on the 7c gate) ───────────────────────────────

  @doc """
  Refuses `:scripts_test_hooks` in `:prod`: every 7b/7c test seam (`:before_case`, the runner,
  HMAC, pause and sweep-fault seams) is honoured only when that flag is true, so a prod node
  with it set would honour test-only behaviour. `Letflow.Application.start/2` raises on
  `{:error, _}`. Pure.
  """
  @spec boot_check(atom() | nil, term()) :: :ok | {:error, :scripts_test_hooks_in_prod}
  def boot_check(:prod, true), do: {:error, :scripts_test_hooks_in_prod}
  def boot_check(_env, _hooks), do: :ok
end
