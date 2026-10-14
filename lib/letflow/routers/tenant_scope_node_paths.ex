defmodule Letflow.Routers.TenantScopeNodePaths do
  @moduledoc """
  REQ-496 (decision 0050 D8; design
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §6.5) — the
  read-only consistency check of the caller's own tenant's `scope_node_paths`
  table.

  Mounted at `/tenant/scope-node-paths` by `Letflow.Plugs.ApiPipeline`. One route:
  `GET /consistency` (full path `GET /api/v1/tenant/scope-node-paths/consistency`),
  policy key `:ScopeNodePathsConsistencyRead`, which requires the tenant-scope
  permission `:UsersGroupsRolesManage` (the holders of the tree-write permission).

  The tenant comes ONLY from `conn.assigns.scoped_opts[:prefix]`; the path has no
  tenant segment and the query string and body are never read (INV-1). The body
  lists node ids only, no record data (INV-2), and is built field by field from
  `Letflow.ScopeNodePaths.Consistency.check/1`'s report, so a future report key
  cannot leak into the response.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.ScopeNodePaths.Consistency

  authz_get "/consistency", :ScopeNodePathsConsistencyRead do
    handle_consistency(conn)
  end

  authz_unmatched(:ordinary)

  @spec handle_consistency(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_consistency(conn) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    case Consistency.check(prefix) do
      {:ok, report} -> Response.ok(conn, report_map(report))
      {:error, :invalid_schema_name} -> Response.internal_error(conn)
    end
  end

  defp report_map(report) do
    %{
      "status" => Atom.to_string(report.status),
      "checked_nodes" => report.checked_nodes,
      "max_depth" => report.max_depth,
      "counts" => %{
        "orphans" => report.counts.orphans,
        "cycles" => report.counts.cycles,
        "depth_exceeded" => report.counts.depth_exceeded,
        "malformed" => report.counts.malformed,
        "stale_paths" => report.counts.stale_paths
      },
      "orphans" => report.orphans,
      "cycles" => report.cycles,
      "depth_exceeded" => report.depth_exceeded,
      "malformed" => report.malformed,
      "stale_paths" => report.stale_paths,
      "truncated" => report.truncated
    }
  end
end
