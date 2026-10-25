defmodule Letflow.Api.RouteScopeOnFlipBlockerTest do
  @moduledoc """
  REQ-519 slice 2f-b (GH #2535), AC 22 / SEC C-1 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 4.7, tests T-RW1..T-RW4;
  spec `test/specs/REQ-519-2f-b.md`): the BUILD-ORDER blocker on making `on` settable.

  `on` may only be settable once every `/me/*` and `/help/*` read is classified and ruled. This file
  asserts on the REAL mounted route table and the REAL committed ruling list at the head of the PR:

    * T-RW1 no route whose path starts with `/me` or `/help` is default-sourced, and the committed
      snapshot holds no `/me` or `/help` line;
    * T-RW2 no `@self_service_routes` entry is `:pending_sec_ruling`, and every `:tenant_wide`
      entry carries a binary ruling id;
    * T-RW3 the four ruled routes are `:self_service` with exactly the rulings `0051-A7`,
      `SEC-518-R2-modules`, `SEC-REQ-449-access`, `SEC-518-R2-help`;
    * T-RW4 `RouteScope.audit_routes/3` returns `[]` on the real table.

  Each guard is proven live: a seeded default-sourced `/me` route, a seeded pending ruling and a
  seeded blank ruling are reported by the same checks (so a walk over nothing cannot pass).

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  @prefixes ["/me", "/help"]
  @expected_rulings %{
    "GET /me/memberships" => "0051-A7",
    "GET /me/modules" => "SEC-518-R2-modules",
    "GET /me/access" => "SEC-REQ-449-access",
    "GET /help/resolved" => "SEC-518-R2-help",
    "GET /definitions" => "SEC-525-R01",
    "GET /definitions/search" => "SEC-525-R04"
  }

  setup_all do
    {:ok, routes: RouteInventory.routes(), snapshot: RouteInventory.read_snapshot()}
  end

  defp self_service_path?(path),
    do: Enum.any?(@prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  defp default_sourced_self_service(routes),
    do: Enum.filter(routes, &(self_service_path?(&1.path) and &1.source == :default))

  defp pending(list), do: Enum.filter(list, &(&1.ruling == :pending_sec_ruling))

  defp unruled(list) do
    Enum.filter(list, fn entry ->
      entry.class == :tenant_wide and not (is_binary(entry.ruling) and entry.ruling != "")
    end)
  end

  describe "T-RW1 /me and /help are never default-sourced" do
    test "no mounted /me or /help route is default-sourced; the inventory sees them", %{
      routes: routes
    } do
      mine = Enum.filter(routes, &self_service_path?(&1.path))

      # a walk over nothing would pass: the four ruled routes are really mounted
      assert length(mine) >= 3

      assert mine |> Enum.map(&"#{&1.method} #{&1.path}") |> Enum.sort() ==
               @expected_rulings
               |> Map.keys()
               |> Enum.filter(&String.contains?(&1, ["/me/", "/help/"]))
               |> Enum.sort()

      assert default_sourced_self_service(routes) == []
    end

    test "the committed default-route snapshot holds no /me or /help line", %{snapshot: snapshot} do
      assert length(snapshot) > 100

      offenders =
        Enum.filter(snapshot, fn line ->
          [_method, path | _rest] = String.split(line, " ")
          self_service_path?(path)
        end)

      assert offenders == []
    end

    test "the check is live: a seeded default-sourced /me route is reported" do
      seeded = [
        %{
          router: Letflow.Routers.Me,
          method: "GET",
          path: "/me/something-new",
          key: :MembershipsRead,
          declared: nil,
          class: :tenant_wide,
          source: :default
        }
      ]

      assert [%{path: "/me/something-new"}] = default_sourced_self_service(seeded)
    end
  end

  describe "T-RW2 no ruling is pending and every tenant-wide entry is ruled" do
    test "the committed list has no :pending_sec_ruling entry and no blank ruling" do
      list = RouteScope.self_service_routes()

      assert length(list) == 6
      assert pending(list) == []
      assert unruled(list) == []
      assert Enum.all?(list, &is_binary(&1.ruling))
    end

    test "the checks are live: a seeded pending ruling and a seeded blank ruling are caught" do
      seeded = [
        %{
          route: "GET /me/x",
          key: :MembershipsRead,
          class: :self_service,
          ruling: :pending_sec_ruling
        },
        %{route: "GET /me/y", key: :MembershipsRead, class: :tenant_wide, ruling: ""},
        %{
          route: "GET /me/z",
          key: :MembershipsRead,
          class: :tenant_wide,
          ruling: :pending_sec_ruling
        }
      ]

      assert length(pending(seeded)) == 2
      assert [%{route: "GET /me/y"}, %{route: "GET /me/z"}] = unruled(seeded)
    end
  end

  describe "T-RW3 the six routes and their rulings" do
    test "each is :self_service with exactly its ruling id", %{routes: routes} do
      list = RouteScope.self_service_routes()

      assert Map.new(list, &{&1.route, &1.ruling}) == @expected_rulings
      assert Enum.all?(list, &(&1.class == :self_service))

      for route <- routes, self_service_path?(route.path) do
        assert route.class == :self_service, "#{route.method} #{route.path}"
        assert route.source == :declared, "#{route.method} #{route.path}"
      end

      for path <- ["/definitions", "/definitions/search"] do
        route = Enum.find(routes, &(&1.method == "GET" and &1.path == path))
        assert route.class == :self_service, path
        assert route.source == :declared, path
      end
    end
  end

  describe "T-RW4 the real walk" do
    test "audit_routes/3 returns [] on the real table, snapshot and ruling list", %{
      routes: routes,
      snapshot: snapshot
    } do
      assert RouteScope.audit_routes(routes, snapshot, RouteScope.self_service_routes()) == []
    end

    test "the walk is live: a seeded unlisted /me route is an error", %{
      routes: routes,
      snapshot: snapshot
    } do
      seeded = %{
        router: Letflow.Routers.Me,
        method: "GET",
        path: "/me/new-unlisted",
        key: :MembershipsRead,
        declared: nil,
        class: :tenant_wide,
        source: :default
      }

      errors = RouteScope.audit_routes(routes ++ [seeded], snapshot)

      assert errors != []

      assert Enum.any?(errors, fn {kind, _row} ->
               kind in [:self_service_not_listed, :unclassified]
             end)
    end
  end
end
