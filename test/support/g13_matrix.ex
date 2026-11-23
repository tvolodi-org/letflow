defmodule Letflow.Support.G13Matrix do
  @moduledoc """
  Shared machinery of the G-13 security probe (the generated malformed-input /
  no-5xx matrix over every mutating route of the mounted tree).

  The probe is mechanical and derives EVERYTHING from the tree:

    * the route list comes from `Letflow.Support.RouteInventory.routes/0` -- the
      compiled route table of every mounted router (`__authz_routes__/0`), not a
      hand-written list, so a new route is covered the moment it is mounted;
    * the shape list is generated here, and every shape carries a canary that
      must not survive into the answer;
    * the verdict comes from ONE function, `violations/1`, which the real-tree
      run and the seeded failing case (the rogue router) both go through.

  The rules `violations/1` enforces (INV-8: a caller's own mistake answers a
  typed 4xx, never a crash and never a 5xx):

    * `:no_answer` -- the request produced no answer at all. A pipeline that
      refuses a body must still answer it.
    * `:server_error` -- the answer is a 5xx. A malformed body is the caller's
      mistake, not a server fault.
    * `:untyped_refusal` -- the refusal was signalled but the answer is not a
      typed problem document (or its status does not match the exception's own
      status). The pipeline's own contract is `application/problem+json` with a
      `status`, `title`, `type`, `detail` and `trace_id`.
    * `:unexpected_error` -- an error escaped that the pipeline does not own
      (anything but the parser's own exceptions, which the pipeline answers
      itself).
    * `:echoed_request` -- the answer carries something from the request.
    * `:wrong_refusal` -- the refusal is not the one the shape demands: the
      exception kind or the status it carries is not the one the shape's own
      `refusal:` pins (the CAPS dimension -- a body over the cap must be
      answered 413, not 400; a media type no parser claims must be answered
      415, not 400).

  The parser exceptions the pipeline owns are the ones `Plug.Parsers` raises:
  `Plug.Parsers.ParseError`, `Plug.Parsers.BadEncodingError`,
  `Plug.Parsers.UnsupportedMediaTypeError` and
  `Plug.Parsers.RequestTooLargeError`.
  """

  alias Letflow.Support.RouteInventory

  @mutating_methods ["POST", "PUT", "PATCH"]
  @canary "G13CANARYTOKEN"
  @json_limit 2_097_152

  @parser_exceptions [
    Plug.Parsers.ParseError,
    Plug.Parsers.BadEncodingError,
    Plug.Parsers.UnsupportedMediaTypeError,
    Plug.Parsers.RequestTooLargeError
  ]

  # What each refusing shape demands: the exception kinds it may be refused
  # with and the status that refusal must carry. The statuses are the ones the
  # exceptions themselves carry (`Plug.Exception.status/1`), so the pipeline
  # answers a refusal with the status the parser gave it.
  #
  # This table is what makes the CAPS dimension of the class enforceable: a
  # body over the cap must be refused with `RequestTooLargeError` (413). Raise
  # the pipeline's cap and the same body is refused with a parse error (400)
  # -- the wrong refusal, and the probe says so.
  @refusal_expectations %{
    parse: {400, [Plug.Parsers.ParseError, Plug.Parsers.BadEncodingError]},
    unsupported_media_type: {415, [Plug.Parsers.UnsupportedMediaTypeError]},
    too_large: {413, [Plug.Parsers.RequestTooLargeError]}
  }

  @doc """
  Every mutating route of the mounted tree, derived from the compiled route
  table. `POST`, `PUT` and `PATCH` are the methods that carry a request body;
  `DELETE` and `GET` are not part of the matrix.
  """
  @spec mutating_routes() :: [map()]
  def mutating_routes do
    for route <- RouteInventory.routes(), route.method in @mutating_methods, do: route
  end

  @doc "The generated shape list: the body shapes and content types of the matrix."
  @spec shapes() :: [map()]
  def shapes do
    [
      %{
        name: "malformed_json",
        content_type: "application/json",
        body: @canary <> ~s({"name":),
        canary: @canary,
        refusal: :parse
      },
      %{
        name: "not_utf8_json",
        content_type: "application/json",
        body: @canary <> <<0xFF, 0xFE, 0x00>>,
        canary: @canary,
        refusal: :parse
      },
      %{
        name: "text_plain",
        content_type: "text/plain",
        body: @canary <> "plain text body",
        canary: @canary,
        refusal: :unsupported_media_type
      },
      %{
        name: "xml",
        content_type: "application/xml",
        body: @canary <> "<root/>",
        canary: @canary,
        refusal: :unsupported_media_type
      },
      %{
        name: "octet_stream",
        content_type: "application/octet-stream",
        body: @canary <> <<0x00, 0x01, 0x02>>,
        canary: @canary,
        refusal: :unsupported_media_type
      },
      %{
        name: "over_cap",
        content_type: "application/json",
        body: over_cap_body(),
        canary: @canary,
        refusal: :too_large
      },
      %{
        name: "no_content_type",
        content_type: nil,
        body: @canary <> ~s({"name":"x"}),
        canary: @canary,
        refusal: :none
      },
      %{
        name: "empty_body",
        content_type: "application/json",
        body: "",
        canary: nil,
        refusal: :none
      },
      %{
        name: "not_an_object_json",
        content_type: "application/json",
        body: ~s(["#{@canary}"]),
        canary: @canary,
        refusal: :handler
      },
      %{
        name: "scalar_json",
        content_type: "application/json",
        body: ~s("#{@canary}"),
        canary: @canary,
        refusal: :handler
      },
      %{
        name: "number_json",
        content_type: "application/json",
        body: "42",
        canary: nil,
        refusal: :handler
      },
      %{
        name: "bool_json",
        content_type: "application/json",
        body: "true",
        canary: nil,
        refusal: :handler
      }
    ]
  end

  @doc "The canary every shape carries; it must not survive into an answer."
  @spec canary() :: String.t()
  def canary, do: @canary

  @doc "A body one byte over the pipeline's JSON cap (the 413 case)."
  @spec over_cap_body() :: binary()
  def over_cap_body do
    case Process.get(:g13_over_cap_body) do
      nil ->
        body = @canary <> :binary.copy("a", @json_limit + 1)
        Process.put(:g13_over_cap_body, body)
        body

      body ->
        body
    end
  end

  @doc "A route path with every path parameter replaced by a concrete value."
  @spec concrete_path(String.t()) :: String.t()
  def concrete_path(path) do
    Regex.replace(~r/:[a-zA-Z_]+/, path, "00000000-0000-0000-0000-000000000000")
  end

  @doc "The connection of one matrix cell: the route's method and path, the shape's body."
  @spec build_conn(map(), map()) :: Plug.Conn.t()
  def build_conn(route, shape) do
    method = route.method |> String.downcase() |> String.to_atom()
    conn = Plug.Test.conn(method, concrete_path(route.path), shape.body)

    case shape.content_type do
      nil -> conn
      type -> Plug.Conn.put_req_header(conn, "content-type", type)
    end
  end

  @doc """
  Dispatches one connection through `plug` and collects BOTH answers: the
  exception that escaped (if any) and the response the plug sent (if any).

  `Plug.ErrorHandler` answers first and re-raises afterwards -- that is the
  pipeline's own contract -- so a refusal shows up as a raised parser
  exception AND a response in the test adapter's mailbox.
  """
  @spec dispatch(Plug.Conn.t(), module()) :: map()
  def dispatch(conn, plug) do
    {_, %{ref: ref}} = conn.adapter

    raised =
      try do
        plug.call(conn, plug.init([]))
        nil
      rescue
        error -> error
      end

    response =
      receive do
        {^ref, {status, headers, body}} -> {status, headers, body}
      after
        0 -> nil
      end

    %{raised: raised, response: response}
  end

  @doc """
  The rules a single matrix cell breaks. An empty list means the cell is fine.
  """
  @spec violations(map()) :: [atom()]
  def violations(outcome) do
    []
    |> untyped_refusal(outcome)
    |> no_answer(outcome)
    |> server_error(outcome)
    |> unexpected_error(outcome)
    |> wrong_refusal(outcome)
    |> echoed_request(outcome)
  end

  @doc "True when the exception is one the pipeline answers itself."
  @spec parser_exception?(term()) :: boolean()
  def parser_exception?(exception) when is_exception(exception) do
    exception.__struct__ in @parser_exceptions
  end

  def parser_exception?(_other), do: false

  @doc "The status the parser's own exception carries (`Plug.Exception.status/1`)."
  @spec refusal_status(Exception.t()) :: integer()
  def refusal_status(exception), do: Plug.Exception.status(exception)

  @doc """
  What a shape's refusal must be: the status it must answer and the exception
  kinds it may be refused with. `nil` for a shape that expects no refusal
  (a body the parser accepts, or one whose refusal is the route's own
  business).
  """
  @spec expected_refusal(map()) :: {integer(), [module()]} | nil
  def expected_refusal(shape) when is_map(shape) do
    Map.get(@refusal_expectations, Map.get(shape, :refusal))
  end

  def expected_refusal(_other), do: nil

  @doc "The typed problem document of a response, or `:not_a_problem_document`."
  @spec problem_document({integer(), list(), binary()}) :: {integer(), map()} | atom()
  def problem_document({status, headers, body}) do
    content_types = for({"content-type", value} <- headers, do: value)

    with [content_type | _] <- content_types,
         true <- String.starts_with?(content_type, "application/problem+json"),
         {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded),
         true <- Map.has_key?(decoded, "status"),
         true <- Map.has_key?(decoded, "title"),
         true <- Map.has_key?(decoded, "detail") do
      {status, decoded}
    else
      _other -> :not_a_problem_document
    end
  end

  # A refusal the pipeline owns must be a TYPED problem document whose status is
  # the one the parser's own exception carries (`Plug.Exception.status/1`).
  defp untyped_refusal(acc, %{raised: raised, response: response}) do
    if parser_exception?(raised) do
      case problem_document(response || {0, [], ""}) do
        {status, decoded} ->
          if status == refusal_status(raised) and decoded["status"] == status do
            acc
          else
            [:untyped_refusal | acc]
          end

        :not_a_problem_document ->
          [:untyped_refusal | acc]
      end
    else
      acc
    end
  end

  # A request that produced no answer at all is a hole, whatever escaped: the
  # caller is left without a status and without a body.
  defp no_answer(acc, %{response: nil}), do: [:no_answer | acc]

  defp no_answer(acc, _outcome), do: acc

  defp server_error(acc, %{response: {status, _headers, _body}}) when status >= 500,
    do: [:server_error | acc]

  defp server_error(acc, _outcome), do: acc

  defp unexpected_error(acc, %{raised: nil}), do: acc

  defp unexpected_error(acc, %{raised: raised}) do
    if parser_exception?(raised), do: acc, else: [:unexpected_error | acc]
  end

  # A refusal must be the refusal the shape demands: the exception kind it may
  # be refused with and the status that refusal carries. A body over the cap
  # refused with a parse error (400) instead of `RequestTooLargeError` (413) is
  # the WRONG refusal -- a typed 4xx, but not the one the shape asked for.
  defp wrong_refusal(acc, %{raised: raised} = outcome) when is_exception(raised) do
    shape = Map.get(outcome, :shape)
    status = answer_status(outcome)

    if parser_exception?(raised) and is_map(shape) and is_integer(status) do
      case expected_refusal(shape) do
        {expected_status, expected_exceptions} ->
          if raised.__struct__ in expected_exceptions and status == expected_status do
            acc
          else
            [:wrong_refusal | acc]
          end

        nil ->
          acc
      end
    else
      acc
    end
  end

  defp wrong_refusal(acc, _outcome), do: acc

  # The status of the answer, or nil when the cell produced no answer.
  defp answer_status(%{response: {status, _headers, _body}}) when is_integer(status), do: status
  defp answer_status(_outcome), do: nil

  defp echoed_request(acc, %{response: {_status, _headers, body}} = outcome)
       when is_binary(body) do
    case Map.get(outcome, :shape, %{}) |> Map.get(:canary) do
      nil -> acc
      canary -> if String.contains?(body, canary), do: [:echoed_request | acc], else: acc
    end
  end

  defp echoed_request(acc, _outcome), do: acc

  @doc """
  The aggregate entry point of the probe: the whole matrix, one outcome per
  cell. The real-tree run and the seeded failing case (the rogue router) both
  go through THIS function, so a rule that stops working fails the seeded case
  too and not only the real tree.
  """
  @spec run([map()], [map()], (map(), map() -> map())) :: [map()]
  def run(routes, shapes, driver) do
    for route <- routes, shape <- shapes do
      outcome = driver.(route, shape)
      outcome = Map.merge(outcome, %{route: route, shape: shape})
      Map.put(outcome, :violations, violations(outcome))
    end
  end

  @doc "The default driver: one cell through the given plug."
  @spec driver(module()) :: (map(), map() -> map())
  def driver(plug) do
    fn route, shape ->
      route
      |> build_conn(shape)
      |> dispatch(plug)
    end
  end
end
