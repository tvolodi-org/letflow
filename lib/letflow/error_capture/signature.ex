defmodule Letflow.ErrorCapture.Signature do
  @moduledoc """
  Pure signature of a server error (T-1951, design section 4.3): a SHA-256 of source, kind, method, route
  template, error type, top `Letflow.*` frame and (for a plain answer) the status. The exception MESSAGE,
  the arguments of a stack frame and file/line are never read: they carry values and a deploy would split
  every group. Every part is cut to 200 characters.
  """

  alias Letflow.Api.AuthzDenyLog

  @max 200

  @doc "The hex signature of an entry map (`:source, :kind, :method, :route, :error_type, :top_frame, :status`)."
  @spec compute(map()) :: String.t()
  def compute(%{} = e) do
    status_part = if e.kind == "http_status", do: Integer.to_string(e.status), else: ""

    [e.source, e.kind, e.method, e.route, e.error_type, e.top_frame, status_part]
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The exception type name: module of the normalized exception, `throw` or `exit`."
  @spec error_type(:error | :throw | :exit, term(), list()) :: String.t()
  def error_type(:error, reason, stack) do
    case Exception.normalize(:error, reason, stack) do
      %{__struct__: mod} -> cut(inspect(mod))
      _ -> "error"
    end
  end

  def error_type(:throw, _reason, _stack), do: "throw"
  def error_type(_kind, _reason, _stack), do: "exit"

  @doc "`Mod.fun/arity` of the first `Letflow.*` frame, else of the first frame, else `\"unknown\"`."
  @spec top_frame(list()) :: String.t()
  def top_frame(stack) when is_list(stack) do
    frames =
      Enum.filter(
        stack,
        &match?({m, f, a, _} when is_atom(m) and is_atom(f) and (is_list(a) or is_integer(a)), &1)
      )

    frame =
      Enum.find(frames, fn {mod, _, _, _} ->
        String.starts_with?(Atom.to_string(mod), "Elixir.Letflow.")
      end) ||
        List.first(frames)

    case frame do
      {mod, fun, args, _loc} ->
        arity = if is_list(args), do: length(args), else: args
        cut("#{inspect(mod)}.#{fun}/#{arity}")

      nil ->
        "unknown"
    end
  end

  def top_frame(_other), do: "unknown"

  @doc "Method token and route template of a conn, via the shared allow-listing helpers."
  @spec route_parts(Plug.Conn.t()) :: {String.t(), String.t()}
  def route_parts(conn),
    do: {AuthzDenyLog.method_token(conn.method), cut(AuthzDenyLog.route_pattern(conn))}

  @spec cut(term()) :: String.t()
  def cut(s) when is_binary(s), do: String.slice(s, 0, @max)
  def cut(_), do: ""
end
