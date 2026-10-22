defmodule Letflow.Engine.Lua.ScriptRunner.Config do
  @moduledoc """
  GH 2534 / GH 2545: the validated input of one tenant-script run, as a struct.

  Every limit the runtime enforces is in `@enforce_keys`: the instruction budget, the
  wall-clock deadline, the heap limit, the per-string byte cap and the output cap. A config
  without one of them cannot be built (`struct!/2` raises `ArgumentError` naming the key), so
  a missing limit is a construction error, never a run-time surprise inside the sandboxed
  path. `Letflow.Engine.Lua.ScriptRunner.run/3` builds it from the caller's options, clamped to
  the platform maxima.
  """

  @typedoc "The `ctx` a run sees: instance, node and token ids, and the clock."
  @type ctx :: %{
          instance_id: String.t(),
          node_id: String.t(),
          token_id: String.t(),
          now: DateTime.t()
        }

  @enforce_keys [
    :source,
    :input,
    :tenant,
    :ctx,
    :instructions,
    :timeout_ms,
    :heap_words,
    :max_string_bytes,
    :max_output_bytes,
    :admission
  ]
  defstruct @enforce_keys ++ [fail_codes: nil, author_detail: false]

  @type t :: %__MODULE__{
          source: String.t(),
          input: map(),
          tenant: String.t(),
          ctx: ctx(),
          instructions: pos_integer(),
          timeout_ms: pos_integer(),
          heap_words: pos_integer(),
          max_string_bytes: pos_integer(),
          max_output_bytes: pos_integer(),
          admission: atom(),
          fail_codes: [String.t()] | nil,
          author_detail: boolean()
        }
end
