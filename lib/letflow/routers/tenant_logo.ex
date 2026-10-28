defmodule Letflow.Routers.TenantLogo do
  @moduledoc """
  REQ-590 / GH #3338 part 1 -- the tenant logo write path. Mounted at `/tenant/logo` by
  `Letflow.Plugs.ApiPipeline` (full paths `PUT` and `DELETE /api/v1/tenant/logo`), gated by
  `:TenantSettingsManage` like `Letflow.Routers.TenantSettings`.

  The tenant is always the caller's own: the prefix comes from `conn.assigns.scoped_opts` and
  the ids from `conn.assigns.auth_context`; no path or body member names a tenant. Behind
  `:tenant_logo_upload_enabled` (default false): with the flag off both routes answer the
  ordinary not-found, after authorisation, so an unauthorised caller learns nothing from it.

  The raw image arrives under `"_logo"` of the body params, read by
  `Letflow.Plugs.LogoBodyParser` (the only way a non-JSON body reaches this router). The declared
  type is checked here first, from the `content-type` header, before the body is looked at.
  Validation and storage are `Letflow.Identity.TenantLogo`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Identity.TenantLogo

  @allowed_detail "allowed types: image/png, image/jpeg, image/webp"

  authz_put "/", :TenantSettingsManage do
    if TenantLogo.enabled?(), do: handle_put(conn), else: Response.not_found(conn)
  end

  authz_delete "/", :TenantSettingsManage do
    if TenantLogo.enabled?(), do: handle_delete(conn), else: Response.not_found(conn)
  end

  authz_unmatched(:ordinary)

  defp handle_put(conn) do
    type = declared_type(conn)

    if type in TenantLogo.allowed_content_types() do
      case conn.body_params do
        %{"_logo" => bytes} when is_binary(bytes) -> store(conn, type, bytes)
        _ -> Response.bad_request(conn, "request body must be the raw image bytes")
      end
    else
      refuse(conn, :type)
    end
  end

  defp store(conn, type, bytes) do
    with :ok <- TenantLogo.validate(type, bytes),
         {:ok, logo} <-
           TenantLogo.put(
             prefix(conn),
             conn.assigns.auth_context.tenant_id,
             conn.assigns.auth_context.user_id,
             type,
             bytes,
             conn.assigns[:trace_id]
           ) do
      Response.ok(conn, %{
        "content_type" => logo.content_type,
        "byte_size" => logo.byte_size,
        "content_hash" => logo.content_hash,
        "updated_at" => logo.updated_at
      })
    else
      {:error, :audit_failed} -> Response.internal_error(conn)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp handle_delete(conn) do
    case TenantLogo.delete(
           prefix(conn),
           conn.assigns.auth_context.tenant_id,
           conn.assigns.auth_context.user_id,
           conn.assigns[:trace_id]
         ) do
      {:ok, _row} -> Response.ok(conn, %{"deleted" => true})
      {:error, :not_found} -> Response.not_found(conn)
      {:error, :audit_failed} -> Response.internal_error(conn)
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp declared_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [value | _] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> ""
    end
  end

  defp refuse(conn, :type), do: Response.unsupported_media_type(conn, @allowed_detail)

  defp refuse(conn, :too_large),
    do: Response.payload_too_large(conn, "logo must be at most #{TenantLogo.max_bytes()} bytes")

  defp refuse(conn, :signature),
    do: Response.unprocessable(conn, "image bytes do not match the declared content type")

  defp refuse(conn, {:infected, verdict}),
    do: Response.unprocessable(conn, "upload refused by the content scanner: " <> verdict)

  defp refuse(conn, :scan_unavailable),
    do: Response.unprocessable(conn, "upload could not be scanned; try again later")
end
