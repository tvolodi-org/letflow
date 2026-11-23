defmodule Letflow.Definitions.StepMapping do
  @moduledoc """
  The TYPED STEP MAPPING of a process definition (T-2594, pilot gap G13 of the
  "Register a tenant" pilot; owner acceptance item 2: "Each node declares its
  reads and writes, and activation refuses an undeclared variable or a write to
  a protected variable").

  A step that maps variables -- a catalogue call today, a notification step when
  the pilot builds it -- SAYS what it reads and what it writes. The
  declaration is checked against the definition's own `variable_schemas`, so the
  typed context of a definition is not a promise in prose but a rule the
  activation fence and the designer's validate route both enforce.

  ## The declaration

      reads  :: %{variable_name => type_name}
      writes :: %{variable_name => type_name}

  Both are maps of a variable's NAME to its JSON-Schema TYPE NAME -- one of
  `string`, `number`, `integer`, `boolean`, `object`, `array`. The names are
  flat: a dotted name is not a variable of this platform (the instance
  variables are one flat namespace).

  The declaration is REQUIRED. A step that maps variables and declares
  nothing maps nothing: without the declaration there is no way to know what
  the step would write, so the step is refused rather than trusted.

  ## What the declaration is checked against

  For every name the step declares, in BOTH directions:

    1. the RESERVED ENGINE NAMESPACE (`_sys`, `_sys.*`; the engine writes it
       for its own bookkeeping) is refused -- a step never reads it and never
       writes it;
    2. the name must be among the definition's `variable_schemas`: a step may
       not touch a variable the definition does not declare;
    3. the declared type must agree with the `variable_schemas` type of that
       name, and with the type the STEP'S CONTRACT declares for it (the
       catalogue entry's input or output type). Three sources, one type: a
       step that says `string` for a variable the definition declares as
       `number`, or for an input the catalogue declares as `number`, is
       refused.

  For the WRITES there are two more rules:

    4. a write to a variable a HUMAN TASK of the same graph may write is
       refused: a person must never decide what a platform step writes (the
       T-2430 rule, `Letflow.Engine.WriteTargets`);
    5. a write the step's contract does not produce is refused: a step may
       not claim an output its function does not have.

  And for the READS one more:

    6. every variable the step actually READS (a `var` argument) must be
       among the declared reads. The declaration is a superset of the real
       reads -- a step may declare a variable it does not read -- but never a
       subset: an undeclared read is exactly the hole the declaration exists
       to close.

  ## Where the check runs

  At ACTIVATION (the four paths that switch a version on: activate,
  reactivate, version rollback, promotion apply) and in the DESIGNER, through
  `POST /api/v1/definitions/:id/validate`. Both read the definition's own
  `variable_schemas` fresh, so a declaration is always checked against the
  schemas of the version that carries it.

  ## The runtime half

  The declaration is not only a design-time rule: the dispatcher of a platform
  step writes ONLY the outputs the step declares
  (`Letflow.PlatformFunctions.Dispatcher`). An output the function returned but
  the step did not declare is not written, so a function can never write a
  variable the definition did not ask for.

  ## Pure and total

  No query, no clock, never raises: a malformed declaration is read as
  "declared and refused", so more is refused, never less (INV-8).
  """

  alias Letflow.Definitions.SemanticValidation
  alias Letflow.Engine.VariableMerge
  alias Letflow.Engine.WriteTargets

  # The JSON-Schema type names a declaration may use. The list is closed: a
  # type the platform does not know is a malformed declaration, not a new
  # type invented by a tenant.
  @type_names ~w(array boolean integer number object string)

  # The bound on a declared variable name. The same bound the
  # `variable_schemas.variable_key` column carries (`varchar(255)`), so a
  # declared name can always be a schema key. The bound is checked BEFORE any
  # other work on the name (the byte-bound-first rule, INV-8).
  @max_name_bytes 255

  @typedoc """
  One violation of the typed mapping: the node it belongs to, the code, the
  side (`:reads` or `:writes`) and the variable name it is about (`nil` when
  the violation is about the declaration as a whole).
  """
  @type violation :: %{
          node_id: String.t(),
          code: atom(),
          side: :reads | :writes,
          name: String.t() | nil
        }

  @typedoc """
  The facts of ONE step that maps variables, as the caller derives them from
  the step's own attribute:

    * `reads` / `writes` -- the DECLARATION, or `:missing` when the step does
      not carry it;
    * `read_names` -- the variables the step actually reads;
    * `write_names` -- the variables the step's contract lets it write;
    * `read_types` / `write_types` -- the type the step's contract declares
      for each of those names.
  """
  @type mapping :: %{
          node_id: String.t(),
          reads: map() | :missing,
          writes: map() | :missing,
          read_names: [String.t()],
          write_names: [String.t()],
          read_types: %{String.t() => atom()},
          write_types: %{String.t() => atom()}
        }

  @doc """
  The violations of the given mappings against the definition's declared
  variable schemas.

  `declared_fields` is the `variable_schemas` map (a variable name to its
  stored JSON-Schema document), read fresh by the caller.
  `completer_writable` is the set of the variables a human task of the same
  graph may write.
  """
  @spec violations([mapping()], map(), MapSet.t(String.t())) :: [violation()]
  def violations(mappings, declared_fields, completer_writable)
      when is_list(mappings) and is_map(declared_fields) and is_struct(completer_writable, MapSet) do
    Enum.flat_map(mappings, &violations_for(&1, declared_fields, completer_writable))
  end

  @doc """
  The variables a human task of `nodes` may write: the `completer_inputs` of
  every HUMAN_TASK node and the properties of its `form_schema`. The rule is
  `Letflow.Engine.WriteTargets`' own, reused here so the two cannot disagree.
  """
  @spec completer_writable_keys([map()]) :: MapSet.t(String.t())
  def completer_writable_keys(nodes) when is_list(nodes) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.flat_map(&WriteTargets.completer_inputs/1)
    |> MapSet.new()
  end

  # ── the rules ───────────────────────────────────────────────────────────────────────────

  defp violations_for(mapping, declared_fields, completer_writable) do
    declaration_violations(mapping) ++
      side_violations(mapping, :reads, declared_fields) ++
      side_violations(mapping, :writes, declared_fields) ++
      write_rule_violations(mapping, completer_writable) ++
      read_coverage_violations(mapping)
  end

  # The declaration itself: both sides must be there, and both must be a map
  # of a plain variable name to a known type name.
  defp declaration_violations(mapping) do
    missing(mapping, :reads) ++
      missing(mapping, :writes) ++
      malformed_side(mapping, :reads) ++ malformed_side(mapping, :writes)
  end

  defp missing(mapping, side) do
    case Map.fetch(mapping, side) do
      {:ok, :missing} ->
        [
          %{
            node_id: mapping.node_id,
            code: :step_mapping_declaration_missing,
            side: side,
            name: nil
          }
        ]

      {:ok, _declared} ->
        []

      :error ->
        []
    end
  end

  defp malformed_side(mapping, side) do
    case Map.get(mapping, side) do
      :missing ->
        []

      declared when is_map(declared) ->
        Enum.flat_map(
          Enum.sort_by(declared, fn {name, _type} -> name end),
          fn {name, type} -> malformed_entry(mapping, side, name, type) end
        )

      _not_a_map ->
        [
          %{
            node_id: mapping.node_id,
            code: :step_mapping_declaration_malformed,
            side: side,
            name: nil
          }
        ]
    end
  end

  defp malformed_entry(mapping, side, name, type) do
    cond do
      not plain_name?(name) ->
        [
          %{
            node_id: mapping.node_id,
            code: :step_mapping_declaration_malformed,
            side: side,
            name: nil
          }
        ]

      not known_type?(type) ->
        [
          %{
            node_id: mapping.node_id,
            code: :step_mapping_declaration_malformed,
            side: side,
            name: name
          }
        ]

      true ->
        []
    end
  end

  # A name is plain when it is a non-empty binary, at most `@max_name_bytes`
  # long, and carries no dot: the instance variables are one flat namespace, so
  # a dotted name would be a path, not a variable.
  #
  # The reserved namespace is checked FIRST (in `side_violations/4`), so a
  # reserved name is reported as reserved and not as malformed.
  defp plain_name?(name) when is_binary(name) do
    byte_size(name) <= @max_name_bytes and name != "" and not String.contains?(name, ".")
  end

  defp plain_name?(_name), do: false

  defp known_type?(type) when is_binary(type), do: type in @type_names
  defp known_type?(_other), do: false

  # Per declared name: the reserved namespace, the definition's own schemas
  # and the type agreement.
  defp side_violations(mapping, side, declared_fields) do
    declared = Map.get(mapping, side)

    if is_map(declared) do
      declared
      |> Enum.sort_by(fn {name, _type} -> name end)
      |> Enum.flat_map(fn {name, type} ->
        name_violations(mapping, side, name, type, declared_fields)
      end)
    else
      []
    end
  end

  defp name_violations(mapping, side, name, type, declared_fields) do
    reserved =
      if reserved?(name) do
        [
          %{
            node_id: mapping.node_id,
            code: :step_mapping_reserved_refused,
            side: side,
            name: name
          }
        ]
      else
        []
      end

    schema =
      case Map.fetch(declared_fields, name) do
        {:ok, schema} ->
          schema_type_violations(mapping, side, name, type, schema)

        :error ->
          [
            %{
              node_id: mapping.node_id,
              code: :step_mapping_variable_undeclared,
              side: side,
              name: name
            }
          ]
      end

    reserved ++ schema
  end

  # The schema's type against the declared type, and the step contract's type
  # against the declared type. A schema or a contract that declares no type
  # constrains nothing (`:unknown` is exempt, as it is in
  # `Letflow.Definitions.SemanticValidation`).
  defp schema_type_violations(mapping, side, name, type, schema) do
    declared_family = type_family(type)
    schema_family = schema_type_family(schema)

    schema_mismatch =
      if mismatch?(declared_family, schema_family) do
        [%{node_id: mapping.node_id, code: :step_mapping_type_mismatch, side: side, name: name}]
      else
        []
      end

    contract_family = contract_type_family(mapping, side, name)

    contract_mismatch =
      if mismatch?(declared_family, contract_family) do
        [
          %{
            node_id: mapping.node_id,
            code: :step_mapping_entry_type_mismatch,
            side: side,
            name: name
          }
        ]
      else
        []
      end

    schema_mismatch ++ contract_mismatch
  end

  # The two write-only rules: a person must not decide what a step writes, and
  # a step may not claim an output its contract does not produce.
  defp write_rule_violations(mapping, completer_writable) do
    declared = Map.get(mapping, :writes)

    if is_map(declared) do
      declared
      |> Enum.sort_by(fn {name, _type} -> name end)
      |> Enum.flat_map(fn {name, _type} ->
        write_rule_violations_for(mapping, name, completer_writable)
      end)
    else
      []
    end
  end

  defp write_rule_violations_for(mapping, name, completer_writable) do
    completer =
      if MapSet.member?(completer_writable, name) do
        [
          %{
            node_id: mapping.node_id,
            code: :step_mapping_write_refused,
            side: :writes,
            name: name
          }
        ]
      else
        []
      end

    not_declared =
      if name not in write_names(mapping) do
        [
          %{
            node_id: mapping.node_id,
            code: :step_mapping_write_not_declared,
            side: :writes,
            name: name
          }
        ]
      else
        []
      end

    completer ++ not_declared
  end

  # Every variable the step really reads must be declared.
  defp read_coverage_violations(mapping) do
    declared = Map.get(mapping, :reads)

    if is_map(declared) do
      mapping
      |> read_names()
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&Map.has_key?(declared, &1))
      |> Enum.map(fn name ->
        %{node_id: mapping.node_id, code: :step_mapping_read_undeclared, side: :reads, name: name}
      end)
    else
      []
    end
  end

  # ── the inputs the rules need ──────────────────────────────────────────────────────────

  defp reserved?(name) when is_binary(name), do: VariableMerge.reserved_key?(name)
  defp reserved?(_other), do: false

  defp mismatch?(declared_family, other) do
    declared_family != :unknown and other != :unknown and declared_family != other
  end

  # The JSON-Schema type name of the DECLARATION.
  defp type_family("string"), do: :string
  defp type_family("number"), do: :numeric
  defp type_family("integer"), do: :numeric
  defp type_family("boolean"), do: :boolean
  defp type_family("object"), do: :object
  defp type_family("array"), do: :array
  defp type_family(_other), do: :unknown

  # The type family of the stored JSON-Schema document of the variable. The
  # rule is `Letflow.Definitions.SemanticValidation`'s own, reused so the two
  # cannot disagree about what a schema means.
  defp schema_type_family(schema) when is_map(schema) do
    case Map.get(schema, "type") do
      type when is_binary(type) ->
        SemanticValidation.type_family(type)

      types when is_list(types) ->
        types
        |> Enum.reject(&(&1 == "null"))
        |> Enum.map(&SemanticValidation.type_family/1)
        |> Enum.uniq()
        |> case do
          [single] -> single
          _other -> :unknown
        end

      _other ->
        :unknown
    end
  end

  defp schema_type_family(_schema), do: :unknown

  # The type family of the step CONTRACT for a name: the catalogue entry's
  # input type for a read, its output type for a write.
  defp contract_type_family(mapping, side, name) do
    types =
      if side == :reads, do: read_types_of(mapping), else: write_types_of(mapping)

    case Map.fetch(types, name) do
      {:ok, type} -> contract_family(type)
      :error -> :unknown
    end
  end

  # The mapping's own fields, read defensively: a malformed mapping is read as
  # "declares nothing", so more is refused, never less (INV-8).
  defp read_names(%{read_names: names}) when is_list(names), do: names
  defp read_names(_mapping), do: []

  defp write_names(%{write_names: names}) when is_list(names), do: names
  defp write_names(_mapping), do: []

  defp read_types_of(%{read_types: types}) when is_map(types), do: types
  defp read_types_of(_mapping), do: %{}

  defp write_types_of(%{write_types: types}) when is_map(types), do: types
  defp write_types_of(_mapping), do: %{}

  defp contract_family(:string), do: :string
  defp contract_family(:uuid), do: :string
  defp contract_family(:number), do: :numeric
  defp contract_family(:integer), do: :numeric
  defp contract_family(:boolean), do: :boolean
  defp contract_family(:object), do: :object
  defp contract_family(:array), do: :array
  defp contract_family(_other), do: :unknown
end
