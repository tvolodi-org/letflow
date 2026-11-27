defmodule Letflow.Definitions.ModuleOwnedChokePointTest do
  @moduledoc """
  T-3014 round 3 (PM 27 Nov 15:05): the module-owned-definition guard is structural.

    * (b) every non-GET route of the definitions and promotions routers (and the tenants
      promote route) is named in the table below, with the guard that covers it. A new
      mutating route that is not in the table fails here, so it cannot bypass the policy
      unnoticed.
    * (c) no code outside the definitions context and the definitions router calls the
      retiring writers (`archive`, `deprecate`, `update`, `delete`, `rollback_definition_version`);
      `activate` has the listed module-upgrade / seed callers, which run without
      `tenant_request` (the platform path). Promotion's own status write is guarded inside
      `Promotion` (`module_owned_name?/2`).

  The behaviour of each row is proven in `definitions_owner_stamp_test.exs` (class table) and
  `reserved_references_activation_test.exs` (promotion rows).
  """

  use ExUnit.Case, async: true

  @definitions_routes %{
    {"POST", "/:process_key/rollback"} => :tenant_request_guard,
    {"POST", "/:id/validate"} => :read_only,
    {"DELETE", "/:id"} => :guarded_delete,
    {"PATCH", "/:id"} => :guarded_update,
    {"PUT", "/:id"} => :guarded_update,
    {"POST", "/:id/archive"} => :guarded_update,
    {"POST", "/:id/deprecate"} => :guarded_update,
    {"POST", "/:id/reactivate"} => :tenant_request_guard,
    {"POST", "/:id/activate"} => :tenant_request_guard,
    {"POST", "/"} => :creates_unstamped_row,
    {"POST", "/import"} => :creates_unstamped_row
  }

  test "every non-GET definitions route is covered by the table" do
    actual =
      Letflow.Routers.Definitions.__authz_routes__()
      |> Enum.reject(fn {verb, _path, _perm} -> verb == "GET" end)
      |> Enum.map(fn {verb, path, _perm} -> {verb, path} end)
      |> Enum.sort()

    assert actual == @definitions_routes |> Map.keys() |> Enum.sort()
  end

  test "every non-GET promotions route is classified" do
    known = %{
      "/" => :review_only,
      "/:id/approve" => :review_only,
      "/:id/reject" => :review_only,
      "/:id/apply" => :promotion_guard,
      "/:review_id/run-assertions" => :review_only,
      "/plan" => :review_only
    }

    actual =
      Letflow.Routers.Promotions.__authz_routes__()
      |> Enum.reject(fn {verb, _path, _perm} -> verb == "GET" end)
      |> Enum.map(fn {_verb, path, _perm} -> path end)

    unknown = Enum.reject(actual, &Map.has_key?(known, &1))
    assert unknown == [], "unclassified promotions mutating routes: #{inspect(unknown)}"
  end

  test "the tenants promote route stays the only other definition-writing route" do
    promote =
      Letflow.Routers.Tenants.__authz_routes__()
      |> Enum.filter(fn {verb, path, _} ->
        verb != "GET" and String.contains?(path, "promote")
      end)
      |> Enum.map(fn {verb, path, _} -> {verb, path} end)

    assert promote == [{"POST", "/:test_tenant_id/promote/:process_key"}]
  end

  @retiring ~r/Definitions\.(archive|deprecate|update|delete|patch|rollback_definition_version)\(/
  @activating ~r/Definitions\.activate\(/

  defp lib_files do
    Path.wildcard("lib/letflow/**/*.ex")
    |> Enum.reject(&String.starts_with?(&1, "lib/letflow/design/"))
  end

  test "retiring writers are called only from the context and the definitions router" do
    allowed = ["lib/letflow/definitions.ex", "lib/letflow/routers/definitions.ex"]

    offenders =
      for f <- lib_files(), f not in allowed, File.read!(f) =~ @retiring, do: f

    assert offenders == []
  end

  test "activate is called without tenant_request only by the module-upgrade and seed paths" do
    allowed = [
      "lib/letflow/definitions.ex",
      "lib/letflow/routers/definitions.ex",
      "lib/letflow/definitions/solution_pack_override_activation.ex",
      "lib/letflow/platform_processes/seed.ex",
      "lib/letflow/modules/ensure_seeds.ex",
      "lib/letflow/modules/maintenance/orders.ex",
      "lib/letflow/modules/stock/documents/posting.ex",
      "lib/letflow/modules/assets/documents/posting.ex"
    ]

    offenders = for f <- lib_files(), f not in allowed, File.read!(f) =~ @activating, do: f
    assert offenders == []
  end

  test "promotion.ex retires rows only behind the module-owned guard" do
    src = File.read!("lib/letflow/definitions/promotion.ex")
    guard = :binary.match(src, "module_owned_name?(process_key, target_prefix)")
    retire = :binary.match(src, "deprecate_previous_active(process_key, target_prefix)\n")
    assert guard != :nomatch and retire != :nomatch
    assert elem(guard, 0) < elem(retire, 0)
    assert length(Regex.scan(~r/deprecate_previous_active\(process_key/, src)) == 2
  end
end
