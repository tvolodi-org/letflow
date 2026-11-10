defmodule Letflow.Modules.RuntimeDemo.Router do
  @moduledoc """
  T-1641: the one route of module `runtime_demo`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/runtime_demo`. `GET /ping` (permission `RuntimeDemoRead`) answers
  `200 {"runtime_demo": true, "release": <manifest version>}`.

  It exists because the skew gate (503 `module_version_ahead` / `module_upgrade_required`) is served on a
  module's routes, before the permission check. It reads no tenant data and writes nothing.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response

  authz_get "/ping", :RuntimeDemoRead do
    Response.ok(conn, %{
      "runtime_demo" => true,
      "release" => Letflow.Modules.RuntimeDemo.manifest().version
    })
  end
end
