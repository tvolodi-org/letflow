defmodule Letflow.Plugs.LogoBodyParser do
  @moduledoc """
  `Plug.Parsers` parser for the one raw-image route (GH #3338, REQ-590):
  `PUT /tenant/logo`.

  `Plug.Parsers` answers any content type none of its parsers claims with a 415, before
  authentication. This parser claims ANY content type for `PUT /tenant/logo` only, so the
  router (after authentication and authorisation) can refuse a disallowed type with a reply
  that names the allowed ones. Every other request is handed on (`{:next, conn}`), so the 415
  of every other route is unchanged. `path_info` has the `/api/v1` prefix already removed by
  the router's `forward`.

  The raw bytes are kept under `"_logo"` of the body params; nothing is validated here. With
  the feature flag off the body is not read at all (the router answers the ordinary 404). The
  read is bounded by the pipeline's per-parser `length:` (the logo limit plus one byte, so the
  router measures the limit on the received bytes); a larger body raises
  `Plug.Parsers.RequestTooLargeError` (413), as an oversized JSON body does.
  """

  @behaviour Plug.Parsers

  alias Letflow.Identity.TenantLogo

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(
        %Plug.Conn{method: "PUT", path_info: ["tenant", "logo"]} = conn,
        _type,
        _subtype,
        _headers,
        opts
      ) do
    if TenantLogo.enabled?() do
      case Plug.Conn.read_body(conn, opts) do
        {:ok, body, conn} -> {:ok, %{"_logo" => body}, conn}
        {:more, _partial, conn} -> {:error, :too_large, conn}
        {:error, :timeout} -> raise Plug.TimeoutError
        {:error, _reason} -> raise Plug.BadRequestError
      end
    else
      {:ok, %{}, conn}
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}
end
