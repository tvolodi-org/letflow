defmodule Letflow.Plugs.XlsxBodyParser do
  @moduledoc """
  `Plug.Parsers` parser for the `.xlsx` media type on four routes: `POST
  /entities/records/:entity_type/import` (GH #3603, REQ-650), `POST /identity/users/import`
  (T-1609, REQ-791), `POST /modules/stock/stock-workbook/check` (REQ-884) and
  `POST /modules/stock/stock-workbook/apply` (REQ-885).

  Same shape as `Letflow.Plugs.CsvBodyParser`: it claims
  `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` only for a POST whose
  path is one of those four routes and hands every other request on (`{:next, conn}`), so the
  415 of every other route is unchanged. `Plug.Parsers` splits the content type at the first
  `/`, so the subtype is the whole `vnd.openxmlformats-officedocument.spreadsheetml.sheet`.

  The raw bytes are kept under `"_xlsx"` of the body params, nothing is read here: the body is
  read bounded by the pipeline's `length:` (2 MiB), and an over-limit body raises
  `Plug.Parsers.RequestTooLargeError` as an oversized JSON body does (413). The conversion runs
  in the route's own module (`Letflow.Routers.Entities.RecordImport`,
  `Letflow.Routers.Identity.UsersImport`, `Letflow.Modules.Stock.StockWorkbookImport`), after
  authentication and authorisation.
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

  # REQ-884: the check of a Qoimeks-layout balances workbook (module stock).
  def parse(
        %Plug.Conn{method: "POST", path_info: ["modules", "stock", "stock-workbook", "check"]} =
          conn,
        "application",
        "vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        _headers,
        opts
      ),
      do: read_xlsx(conn, opts)

  # REQ-885: the load (apply) of a Qoimeks-layout balances workbook as a quick count (module stock).
  def parse(
        %Plug.Conn{method: "POST", path_info: ["modules", "stock", "stock-workbook", "apply"]} =
          conn,
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
