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
    * `line_index` is a non-negative integer.

  The line key and the `sys:step:` idempotency key of the write are DERIVED
  from the struct (`line_index/1` is the field itself, `idempotency_key/1`
  builds `"sys:step:<origin id>:<line_index>"`), so a key that disagrees with
  the source's origin id or line index cannot be expressed (#2627, OQ-C7).

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
    :activator_id
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
          activator_id: Ecto.UUID.t()
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
    :activator_id
  ]

  @doc """
  Validates an atom-keyed attribute map (closed key set; `kind` optional;
  `task_id`/`dispatch_id` may be absent or `nil`, exactly one must be set) and returns the struct.
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
           Map.get(attrs, :line_index) do
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
         activator_id: activator_id
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
  line_index` (decision 0054 D9.2), the exact format `StepWrites` always built.
  """
  @spec idempotency_key(t()) :: String.t()
  def idempotency_key(%__MODULE__{line_index: line_index} = source) do
    {_tag, id} = origin(source)
    "sys:step:" <> id <> ":" <> Integer.to_string(line_index)
  end

  @doc """
  The flat string -> string `source.*` event metadata (D-A2.5): the integer
  `line_index` as a decimal string, `task_id` XOR `dispatch_id`.
  """
  @spec to_metadata(t()) :: %{String.t() => String.t()}
  def to_metadata(%__MODULE__{} = source) do
    {origin_key, origin_id} =
      case source do
        %{task_id: id} when is_binary(id) -> {"source.task_id", id}
        %{dispatch_id: id} when is_binary(id) -> {"source.dispatch_id", id}
      end

    %{
      "source.kind" => source.kind,
      "source.instance_id" => source.instance_id,
      origin_key => origin_id,
      "source.node_id" => source.node_id,
      "source.definition_id" => source.definition_id,
      "source.definition_version" => source.definition_version,
      "source.line_index" => Integer.to_string(source.line_index),
      "source.activator_id" => source.activator_id
    }
  end

  defp origin_ids(attrs) do
    case {Map.get(attrs, :task_id), Map.get(attrs, :dispatch_id)} do
      {id, nil} when not is_nil(id) -> with {:ok, uuid} <- uuid(id), do: {:ok, uuid, nil}
      {nil, id} when not is_nil(id) -> with {:ok, uuid} <- uuid(id), do: {:ok, nil, uuid}
      _neither_or_both -> :error
    end
  end

  defp uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp uuid(_other), do: :error
end
