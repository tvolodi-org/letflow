defmodule Letflow.Plugs.XlsxBodyParser do
  @moduledoc """
  `Plug.Parsers` parser for the `.xlsx` media type on two import routes: `POST
  /entities/records/:entity_type/import` (GH #3603, REQ-650) and `POST /identity/users/import`
  (T-1609, REQ-790).

  Same shape as `Letflow.Plugs.CsvBodyParser`: it claims
  `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` only for a POST whose
  path is the record import route and hands every other request on (`{:next, conn}`), so the
  415 of every other route is unchanged. `Plug.Parsers` splits the content type at the first
  `/`, so the subtype is the whole `vnd.openxmlformats-officedocument.spreadsheetml.sheet`.

  The raw bytes are kept under `"_xlsx"` of the body params, nothing is read here: the body is
  read bounded by the pipeline's `length:` (2 MiB), and an over-limit body raises
  `Plug.Parsers.RequestTooLargeError` as an oversized JSON body does (413). The conversion runs
  in `Letflow.Routers.Entities.RecordImport`, after authentication and authorisation.
  """

  @behaviour Plug.Parsers

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(
        %Plug.Conn{method: "POST", path_info: ["entities", "records", _type, "import"]} = conn,
        "application",
        "vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        _headers,
        opts
      ),
      do: read_xlsx(conn, opts)

  def parse(
        %Plug.Conn{method: "POST", path_info: ["identity", "users", "import"]} = conn,
        "application",
        "vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        _headers,
        opts
      ),
      do: read_xlsx(conn, opts)

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  defp read_xlsx(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, %{"_xlsx" => body}, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, :timeout} -> raise Plug.TimeoutError
      {:error, _reason} -> raise Plug.BadRequestError
    end
  end
end
