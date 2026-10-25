defmodule Letflow.Plugs.CsvBodyParser do
  @moduledoc """
  `Plug.Parsers` parser for the one `text/csv` route (GH #3182, REQ-557):
  `POST /entities/records/:entity_type/import`.

  `Plug.Parsers` answers any content type none of its parsers claims with a 415. This parser
  claims `text/csv` only for a POST whose path is the record import route and hands every
  other request on (`{:next, conn}`), so the 415 of every other route is unchanged. `path_info`
  has the `/api/v1` prefix already removed by the router's `forward`.

  The raw text is kept under `"_csv"` of the body params, nothing is converted here: the body
  is read bounded by the pipeline's `length:`, and an over-limit body raises
  `Plug.Parsers.RequestTooLargeError` exactly as an oversized JSON body does (413). The
  conversion runs in `Letflow.Routers.Entities.RecordImport`, after authentication and
  authorisation.
  """

  @behaviour Plug.Parsers

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(
        %Plug.Conn{method: "POST", path_info: ["entities", "records", _type, "import"]} = conn,
        "text",
        "csv",
        _headers,
        opts
      ) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, %{"_csv" => body}, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, :timeout} -> raise Plug.TimeoutError
      {:error, _reason} -> raise Plug.BadRequestError
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}
end
