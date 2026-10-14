defmodule Letflow.Identity.AuditContext do
  @moduledoc """
  GH 2547 (design `lib/letflow/design/gh2547-tenant-admin-audit-and-count.md` section
  2.2): who did an identity write, under which trace, through which channel.

  Callers pass it as the optional `:audit_context` key of the keyword `opts` the
  identity write functions already take (`Letflow.Identity.add_group_member/3`,
  `remove_group_member/3`, `create_token/3`, `revoke_token/2`,
  `Letflow.Identity.RoleRegistry.upsert_role/4`, `rebind_role/4`). A caller that omits
  it still gets an audited write: actor `nil`, the trace id from `Logger` metadata,
  source `"system"`.

  Pure: no DB access, no process state of its own. The trace id is correlation data
  only, never an authorization input.
  """

  @max_trace_codepoints 255
  @control_char_pattern ~r/\p{Cc}/u

  @type t :: %{
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:trace_id) => String.t() | nil,
          required(:source) => String.t()
        }

  @doc """
  Resolves `opts[:audit_context]` (a map, possibly partial) into a complete `t()`.

  `actor_id` is the map's `:actor_id` when it is a binary, else `nil`. `trace_id` is
  `normalize_trace_id/1` of the map's `:trace_id` when that is a non-empty binary,
  else `current_trace_id/0`. `source` is the map's `:source` when it is a binary, else
  `"system"`. A missing key, a non-map value or a malformed field never raises.
  """
  @spec from_opts(opts :: keyword()) :: t()
  def from_opts(opts) when is_list(opts) do
    context =
      case Keyword.get(opts, :audit_context) do
        %{} = map -> map
        _absent_or_malformed -> %{}
      end

    %{
      actor_id: binary_or_nil(Map.get(context, :actor_id)),
      trace_id: resolve_trace_id(Map.get(context, :trace_id)),
      source: binary_or(Map.get(context, :source), "system")
    }
  end

  @doc """
  The trace id of the calling process (`Logger.metadata()[:trace_id]`, set by
  `Letflow.Api.Context.assign_trace_id/1` for a request and by
  `Letflow.Obs.Logger.with_trace/1` for a CLI run), through `normalize_trace_id/1`.
  """
  @spec current_trace_id() :: String.t() | nil
  def current_trace_id, do: normalize_trace_id(Logger.metadata()[:trace_id])

  @doc """
  Makes a trace id safe for `audit_entries.trace_id` (`varchar(255)`), SEC-A1/SEC-A4.

  A non-binary or empty value, a binary that is not valid UTF-8 (the `x-trace-id`
  header is cut at 256 bytes and can end mid-codepoint), or one containing any control
  character (Unicode `Cc`: NUL, CR, LF, ...) returns `nil`: a hostile header degrades to
  "no correlation", never to "write refused". Otherwise the first 255 codepoints, so
  the cut is always on a UTF-8 boundary. Pure, never raises.
  """
  @spec normalize_trace_id(term()) :: String.t() | nil
  def normalize_trace_id(value) when is_binary(value) and value != "" do
    if String.valid?(value) and not String.match?(value, @control_char_pattern) do
      value
      |> String.codepoints()
      |> Enum.take(@max_trace_codepoints)
      |> Enum.join()
    end
  end

  def normalize_trace_id(_value), do: nil

  defp resolve_trace_id(value) when is_binary(value) and value != "",
    do: normalize_trace_id(value)

  defp resolve_trace_id(_value), do: current_trace_id()

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  defp binary_or(value, _default) when is_binary(value), do: value
  defp binary_or(_value, default), do: default
end
