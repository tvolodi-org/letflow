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

  @activating ~r/Definitions\.activate\(/

  defp lib_files do
    Path.wildcard("lib/letflow/**/*.ex")
    |> Enum.reject(&String.starts_with?(&1, "lib/letflow/design/"))
  end

  test "retiring writers are called only from the context and the definitions router" do
    allowed = ["lib/letflow/definitions.ex", "lib/letflow/routers/definitions.ex"]

    offenders =
      for f <- lib_files(), f not in allowed, retiring_call?(File.read!(f)), do: f

    assert offenders == []
  end

  # Also resolves `alias Letflow.Definitions, as: X` (module or file scope).
  defp retiring_call?(src) do
    aliases =
      Regex.scan(~r/alias\s+Letflow\.Definitions,\s*as:\s*([A-Z]\w*)/, src)
      |> Enum.map(fn [_, a] -> a end)

    names = Enum.join(["Definitions" | aliases], "|")

    Regex.match?(
      ~r/\b(#{names})\.(archive|deprecate|update|delete|patch|rollback_definition_version)\(/,
      src
    ) or Regex.match?(~r/Elixir\.Letflow\.Definitions\.(archive|deprecate|update|delete)\(/, src)
  end

  test "raw status writes on process_definitions live only in the context and promotion" do
    allowed = ["lib/letflow/definitions.ex", "lib/letflow/definitions/promotion.ex"]

    offenders =
      for f <- lib_files(), f not in allowed, raw_status_write?(File.read!(f)), do: f

    assert offenders == []
  end

  # A `ProcessDefinition` query followed within 600 bytes by update_all/Repo.update and `status`.
  defp raw_status_write?(src) do
    Regex.scan(~r/ProcessDefinition(?:\s|\)|,)/, src, return: :index)
    |> Enum.any?(fn [{i, _}] ->
      window = binary_part(src, i, min(600, byte_size(src) - i))
      Regex.match?(~r/update_all\(|Repo\.update!?\(/, window) and window =~ "status"
    end)
  end

  test "every guarded route's classification is backed by an executed class-table attempt" do
    table = File.read!("test/letflow/routers/definitions_owner_stamp_test.exs")

    unbacked =
      for {{verb, path}, kind} <- @definitions_routes,
          kind not in [:read_only, :creates_unstamped_row],
          not backed?(table, verb, path),
          do: {verb, path}

    assert unbacked == [],
           "classified but never attempted in the class table: #{inspect(unbacked)}"
  end

  defp backed?(table, verb, path) do
    suffix = path |> String.replace(~r{^/:(id|process_key)}, "") |> Regex.escape()
    Regex.match?(~r/\{"#{verb}", "\/#\{[^}]+\}#{suffix}"/, table)
  end

  test "activate is called without tenant_request only by the module-upgrade and seed paths" do
    allowed = [
      "lib/letflow/definitions.ex",
      "lib/letflow/routers/definitions.ex",
      "lib/letflow/platform_processes/seed.ex",
      "lib/letflow/modules/ensure_seeds.ex",
      "lib/letflow/modules/maintenance/orders.ex",
      "lib/letflow/modules/stock/documents/posting.ex",
      "lib/letflow/modules/assets/documents/posting.ex"
    ]

    # N1 (T-3167): a call site outside that list must pass `tenant_request: true` in its call.
    offenders =
      for f <- lib_files(),
          f not in allowed,
          src = File.read!(f),
          src =~ @activating,
          Enum.any?(String.split(src, "Definitions.activate(") |> tl(), fn rest ->
            not String.contains?(String.slice(rest, 0, 400), "tenant_request: true")
          end),
          do: f

    assert offenders == []
    src = File.read!("lib/letflow/definitions/solution_pack_override_activation.ex")
    assert src =~ ~r/Definitions\.activate\(.{0,400}tenant_request: true/s
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
