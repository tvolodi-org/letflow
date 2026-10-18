defmodule Letflow.Support.RouteInventory do
  @moduledoc """
  Test support for the REQ-517 PR 2b route-scope walk (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.1): discovers every
  route of every mounted core and module router and classifies it with
  `Letflow.Api.RouteScope.class_of/1`. The mount discovery is the one of
  `test/letflow/api/platform_scope_inventory_test.exs` (the `forward(...)` lines of
  `lib/letflow/plugs/api_pipeline.ex`, and the module routers of
  `Letflow.Modules.Catalog.entry_modules/0` mounted at `/modules/<manifest id>`).
  """

  alias Letflow.Api.RouteScope
  alias Letflow.Modules.Catalog

  @pipeline_path "lib/letflow/plugs/api_pipeline.ex"
  @snapshot_path "test/fixtures/route_scope/tenant_wide_default_routes.txt"

  @doc "The committed default-route snapshot path."
  @spec snapshot_path() :: Path.t()
  def snapshot_path, do: @snapshot_path

  @doc "Every route of every mounted router, with its FULL mounted path and its class."
  @spec routes() :: [RouteScope.route_row()]
  def routes do
    mounts = Map.new(all_mounts())

    for router <- discovered_routers(),
        {method, local, key} <- router.__authz_routes__(),
        prefix = Map.fetch!(mounts, router) do
      declared = declared_class(router, method, local)

      private =
        if declared, do: %{policy_key: key, scope_class: declared}, else: %{policy_key: key}

      {class, source} = RouteScope.class_of(private)

      %{
        router: router,
        method: method,
        path: full_path(prefix, local),
        key: key,
        declared: declared,
        class: class,
        source: source
      }
    end
  end

  @doc "The sorted `METHOD FULL_PATH KEY` lines of the default-sourced routes (the snapshot)."
  @spec default_snapshot_lines([RouteScope.route_row()]) :: [String.t()]
  def default_snapshot_lines(routes) do
    routes
    |> Enum.filter(&(&1.source == :default))
    |> Enum.map(&RouteScope.snapshot_line/1)
    |> Enum.sort()
  end

  @doc "The committed snapshot lines (blank lines ignored)."
  @spec read_snapshot() :: [String.t()]
  def read_snapshot do
    @snapshot_path
    |> File.read!()
    |> String.split(["\r\n", "\n"], trim: true)
  end

  defp declared_class(router, method, local) do
    Enum.find_value(router.__authz_route_scopes__(), fn
      {^method, ^local, class} -> class
      _other -> nil
    end)
  end

  defp pipeline_mounts do
    ~r/forward\(\s*"([^"]+)"\s*,\s*to:\s*([A-Za-z0-9_.]+)\s*\)/
    |> Regex.scan(File.read!(@pipeline_path))
    |> Enum.map(fn [_all, prefix, module] -> {Module.concat([module]), prefix} end)
  end

  defp module_mounts do
    for entry <- Catalog.entry_modules(),
        Code.ensure_loaded?(entry),
        function_exported?(entry, :router, 0) do
      {entry.router(), "/modules/" <> entry.manifest().id}
    end
  end

  defp all_mounts, do: pipeline_mounts() ++ module_mounts()

  defp discovered_routers do
    for module <- Application.spec(:letflow, :modules),
        Code.ensure_loaded?(module),
        function_exported?(module, :__authz_routes__, 0),
        do: module
  end

  defp full_path(prefix, "/"), do: prefix
  defp full_path(prefix, local), do: prefix <> local
end
