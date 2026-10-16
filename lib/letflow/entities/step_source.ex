defmodule Letflow.Entities.StepSource do
  @moduledoc """
  GH #2627 (REQ-499 C0; decision 0054, design `gh2587-req499-pr-a-prerequisites.md`
  sections 3.3 and 8.2): WHO caused a process-step entity write. The struct
  replaces the plain `step_source` map `Letflow.Entities.Records.command_multi/3`
  used to validate; `new/1` is the ONLY validation of the shape, and
  `to_metadata/1` is the ONLY producer of the flat `source.*` event metadata.

  Invariants (exactly the ones `Records` enforced on the map):

    * `kind` is `"process_step"` (the only kind; a producer omits it and the
      constructor supplies it, so no caller writes the literal; any other value
      is refused);
    * exactly one of `task_id` / `dispatch_id` (the other is `nil`);
    * `instance_id`, `definition_id`, `activator_id` and the origin id are UUIDs
      (stored in `Ecto.UUID.cast/1` form, as the metadata always carried);
    * `node_id` is a valid UTF-8 string of 1..1024 bytes;
    * `definition_version` is a valid UTF-8 string of 1..255 bytes (the stored
      `ProcessDefinition.version`, #2587 D-B.9);
    * `line_index` is a non-negative integer;
    * `handler` / `write_ordinal` (GH #2590 / REQ-501 R4a, design
      `gh2590-req501-module-write-handlers.md` 4.4) are both `nil` for a declarative
      line and both set for a write made by a module write handler: `handler` is
      `%{module_id: String.t(), name: String.t()}` (each matching
      `^[a-z][a-z0-9_]{0,63}$`) and `write_ordinal` an integer in `1..49`.

  The line key and the `sys:step:` idempotency key of the write are DERIVED
  from the struct: `line_key/1` is the `line_index` of a declarative line and
  `20 + line_index * 50 + write_ordinal` of a handler write (the two ranges are
  disjoint), and `idempotency_key/1` builds `"sys:step:<origin id>:<line_index>"`,
  with `":<write_ordinal>"` appended for a handler write. A key that disagrees with
  the source's origin id, line index or ordinal cannot be expressed (#2627, OQ-C7).
  Step-name collision to know about (R4b): `StepWrites` names its 21st-line overflow failure
  `{:line, 20, :build}`, and `call_key(0)` is also 20. The two never coexist because the engine caps
  the COMBINED declarative + handler line count at 20 before any Multi is built (design 4.7), so
  the overflow clause is unreachable for a node with `module_writes`; R4b must keep that cap ahead
  of `multi/3` (the test in `step_source_test.exs` pins the numbers).
  Declarative lines are byte-identical to before (key, idempotency key and the 8
  metadata keys); a handler write adds exactly three metadata keys.

  The struct is built server-side from recorded values, never from a request
  body, so a malformed input is an internal-API refusal (`{:error,
  :invalid_step_source}`), never a raise (INV-8).
  """

  # :kind is enforced on the struct (a literal always names it) although new/1
  # takes it as optional input and supplies it: the struct is always complete.
  @enforce_keys [
    :kind,
    :instance_id,
    :node_id,
    :definition_id,
    :definition_version,
    :line_index,
    :activator_id
  ]
  defstruct [
    :kind,
    :instance_id,
    :task_id,
    :dispatch_id,
    :node_id,
    :definition_id,
    :definition_version,
    :line_index,
    :activator_id,
    :handler,
    :write_ordinal
  ]

  @type t :: %__MODULE__{
          kind: String.t(),
          instance_id: Ecto.UUID.t(),
          task_id: Ecto.UUID.t() | nil,
          dispatch_id: Ecto.UUID.t() | nil,
          node_id: String.t(),
          definition_id: Ecto.UUID.t(),
          definition_version: String.t(),
          line_index: non_neg_integer(),
          activator_id: Ecto.UUID.t(),
          handler: %{module_id: String.t(), name: String.t()} | nil,
          write_ordinal: 1..49 | nil
        }

  @kind "process_step"
  @node_id_max_bytes 1024
  @version_max_bytes 255
  @keys [
    :kind,
    :instance_id,
    :task_id,
    :dispatch_id,
    :node_id,
    :definition_id,
    :definition_version,
    :line_index,
    :activator_id,
    :handler,
    :write_ordinal
  ]
  @handler_name_format ~r/\A[a-z][a-z0-9_]{0,63}\z/

  # Handler writes use the namespace keys 20 + line_index * 50 + ordinal (ordinal 0 of each
  # call is reserved for call-level steps); declarative lines use their line_index (0..19).
  @handler_key_base 20
  @handler_key_stride 50
  @max_write_ordinal 49

  @doc """
  Validates an atom-keyed attribute map (closed key set; `kind` optional;
  `task_id`/`dispatch_id` may be absent or `nil`, exactly one must be set;
  `handler`/`write_ordinal` both absent/`nil` or both well formed) and returns the struct.
  """
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_step_source}
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with true <- Enum.all?(Map.keys(attrs), &(&1 in @keys)),
         true <- Map.get(attrs, :kind, @kind) == @kind,
         {:ok, task_id, dispatch_id} <- origin_ids(attrs),
         {:ok, instance_id} <- uuid(Map.get(attrs, :instance_id)),
         {:ok, definition_id} <- uuid(Map.get(attrs, :definition_id)),
         {:ok, activator_id} <- uuid(Map.get(attrs, :activator_id)),
         node_id when is_binary(node_id) and byte_size(node_id) in 1..@node_id_max_bytes <-
           Map.get(attrs, :node_id),
         true <- String.valid?(node_id),
         version when is_binary(version) and byte_size(version) in 1..@version_max_bytes <-
           Map.get(attrs, :definition_version),
         true <- String.valid?(version),
         line_index when is_integer(line_index) and line_index >= 0 <-
           Map.get(attrs, :line_index),
         {:ok, handler, write_ordinal} <- handler_fields(attrs) do
      {:ok,
       %__MODULE__{
         kind: @kind,
         instance_id: instance_id,
         task_id: task_id,
         dispatch_id: dispatch_id,
         node_id: node_id,
         definition_id: definition_id,
         definition_version: version,
         line_index: line_index,
         activator_id: activator_id,
         handler: handler,
         write_ordinal: write_ordinal
       }}
    else
      _invalid -> {:error, :invalid_step_source}
    end
  end

  def new(_other), do: {:error, :invalid_step_source}

  @doc "The tagged origin: `{:task, id}` or `{:dispatch, id}` (exactly one is set)."
  @spec origin(t()) :: {:task, Ecto.UUID.t()} | {:dispatch, Ecto.UUID.t()}
  def origin(%__MODULE__{task_id: id, dispatch_id: nil}) when is_binary(id), do: {:task, id}
  def origin(%__MODULE__{task_id: nil, dispatch_id: id}) when is_binary(id), do: {:dispatch, id}

  @doc """
  The step idempotency key of this line: `"sys:step:" <> origin id <> ":" <>
  line_index` (decision 0054 D9.2), the exact format `StepWrites` always built; a handler
  write appends `":" <> write_ordinal`.
  """
  @spec idempotency_key(t()) :: String.t()
  def idempotency_key(%__MODULE__{line_index: line_index, write_ordinal: nil} = source) do
    {_tag, id} = origin(source)
    "sys:step:" <> id <> ":" <> Integer.to_string(line_index)
  end

  def idempotency_key(%__MODULE__{line_index: line_index, write_ordinal: ordinal} = source)
      when is_integer(ordinal) do
    {_tag, id} = origin(source)
    "sys:step:" <> id <> ":" <> Integer.to_string(line_index) <> ":" <> Integer.to_string(ordinal)
  end

  @doc """
  The namespace key of this write's `{:line, key}` Multi steps: the `line_index` of a
  declarative line, `20 + line_index * 50 + write_ordinal` of a handler write.
  """
  @spec line_key(t()) :: non_neg_integer()
  def line_key(%__MODULE__{line_index: line_index, write_ordinal: nil}), do: line_index

  def line_key(%__MODULE__{line_index: line_index, write_ordinal: ordinal})
      when is_integer(ordinal),
      do: call_key(line_index) + ordinal

  @doc """
  The call-level key (ordinal 0) of the handler call declared at `line_index`: the base of the
  range `call_key + 1 .. call_key + 49` its writes use.
  """
  @spec call_key(non_neg_integer()) :: non_neg_integer()
  def call_key(line_index) when is_integer(line_index) and line_index >= 0,
    do: @handler_key_base + line_index * @handler_key_stride

  @doc """
  The declared `line_index` a namespace key belongs to: `div(key - 20, 50)` for a handler-range
  key, `:declarative` for a key below 20 (where the key is the line index itself).
  """
  @spec declared_line_index(non_neg_integer()) :: non_neg_integer() | :declarative
  def declared_line_index(key) when is_integer(key) and key >= 0 and key < @handler_key_base,
    do: :declarative

  def declared_line_index(key) when is_integer(key) and key >= @handler_key_base,
    do: div(key - @handler_key_base, @handler_key_stride)

  @doc """
  The flat string -> string `source.*` event metadata (D-A2.5): the integer
  `line_index` as a decimal string, `task_id` XOR `dispatch_id`. A handler write adds
  `source.handler_module`, `source.handler_name` and `source.write_ordinal`.
  """
  @spec to_metadata(t()) :: %{String.t() => String.t()}
  def to_metadata(%__MODULE__{} = source) do
    {origin_key, origin_id} =
      case source do
        %{task_id: id} when is_binary(id) -> {"source.task_id", id}
        %{dispatch_id: id} when is_binary(id) -> {"source.dispatch_id", id}
      end

    base = %{
      "source.kind" => source.kind,
      "source.instance_id" => source.instance_id,
      origin_key => origin_id,
      "source.node_id" => source.node_id,
      "source.definition_id" => source.definition_id,
      "source.definition_version" => source.definition_version,
      "source.line_index" => Integer.to_string(source.line_index),
      "source.activator_id" => source.activator_id
    }

    case source do
      %{handler: %{module_id: module_id, name: name}, write_ordinal: ordinal} ->
        Map.merge(base, %{
          "source.handler_module" => module_id,
          "source.handler_name" => name,
          "source.write_ordinal" => Integer.to_string(ordinal)
        })

      _declarative ->
        base
    end
  end

  defp origin_ids(attrs) do
    case {Map.get(attrs, :task_id), Map.get(attrs, :dispatch_id)} do
      {id, nil} when not is_nil(id) -> with {:ok, uuid} <- uuid(id), do: {:ok, uuid, nil}
      {nil, id} when not is_nil(id) -> with {:ok, uuid} <- uuid(id), do: {:ok, nil, uuid}
      _neither_or_both -> :error
    end
  end

  # Both nil (declarative) or both set and well formed (handler write); anything else is refused.
  defp handler_fields(attrs) do
    case {Map.get(attrs, :handler), Map.get(attrs, :write_ordinal)} do
      {nil, nil} ->
        {:ok, nil, nil}

      {%{module_id: module_id, name: name} = handler, ordinal}
      when map_size(handler) == 2 and is_integer(ordinal) and ordinal >= 1 and
             ordinal <= @max_write_ordinal ->
        if handler_name?(module_id) and handler_name?(name),
          do: {:ok, %{module_id: module_id, name: name}, ordinal},
          else: :error

      _other ->
        :error
    end
  end

  defp handler_name?(value), do: is_binary(value) and Regex.match?(@handler_name_format, value)

  defp uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp uuid(_other), do: :error
end
