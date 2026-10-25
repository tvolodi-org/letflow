defmodule Letflow.Api.RouteScopeSelfServiceEntryTest do
  @moduledoc """
  GH #2825: the shape of one `@self_service_routes` entry is checked when `Letflow.Api.RouteScope`
  compiles. The shipped entries pass (the module would not load otherwise); each malformed shape
  raises `ArgumentError` from `RouteScope.SelfServiceEntry.validate!/1`, the same check the module
  body runs on every entry. The walk rules of `audit_routes/3` are tested in
  `route_scope_self_service_test.exs` and are not repeated here.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.RouteScope
  alias Letflow.Api.RouteScope.SelfServiceEntry

  defp entry(fields) do
    Map.merge(
      %{
        route: "GET /me/modules",
        key: :MyModulesRead,
        class: :self_service,
        ruling: "SEC-518-R2-modules"
      },
      Map.new(fields)
    )
  end

  defp rejects(fields) do
    assert_raise ArgumentError, ~r/malformed @self_service_routes entry/, fn ->
      SelfServiceEntry.validate!(entry(fields))
    end
  end

  test "every shipped entry passes the shape check" do
    for shipped <- RouteScope.self_service_routes() do
      assert SelfServiceEntry.validate!(shipped) == shipped
    end
  end

  test "a well-formed entry is returned unchanged, including a tenant-wide pending entry" do
    assert SelfServiceEntry.validate!(entry(%{})) == entry(%{})

    pending = entry(%{class: :tenant_wide, ruling: :pending_sec_ruling})
    assert SelfServiceEntry.validate!(pending) == pending
  end

  test "a missing field is rejected" do
    assert_raise ArgumentError, ~r/fields must be exactly/, fn ->
      SelfServiceEntry.validate!(Map.delete(entry(%{}), :ruling))
    end
  end

  test "an extra field is rejected" do
    assert_raise ArgumentError, ~r/fields must be exactly/, fn ->
      SelfServiceEntry.validate!(Map.put(entry(%{}), :note, "x"))
    end
  end

  test "a value that is not a map is rejected" do
    assert_raise ArgumentError, ~r/an entry must be a map/, fn ->
      # `apply/3`: a literal non-map passed to `validate!/1` directly is a type warning.
      apply(SelfServiceEntry, :validate!, ["GET /me/modules"])
    end
  end

  test "a route that is not METHOD PATH is rejected" do
    rejects(route: "/me/modules")
    rejects(route: "GET")
    rejects(route: :"GET /me/modules")
  end

  test "an unknown HTTP method is rejected" do
    rejects(route: "FETCH /me/modules")
  end

  test "a route outside /me and /help is rejected" do
    rejects(route: "GET /mentor/modules")
    rejects(route: "GET /entities/records/:entity_type")
    rejects(route: "GET /definitionsx/list")
  end

  test "a route under /definitions is accepted, a path-segment match" do
    for path <- ["/definitions", "/definitions/search"] do
      accepted = entry(route: "GET " <> path, key: :DefinitionsRead, ruling: "SEC-525-R01")
      assert SelfServiceEntry.validate!(accepted) == accepted
    end
  end

  test "a key that is not an atom is rejected" do
    rejects(key: "MyModulesRead")
    rejects(key: nil)
    rejects(key: true)
  end

  test "a class other than :self_service or :tenant_wide is rejected" do
    rejects(class: :filter)
    rejects(class: {:resolver, {RouteScope, :audit_routes}})
  end

  test "a blank or non-string ruling is rejected" do
    rejects(ruling: "")
    rejects(ruling: "   ")
    rejects(ruling: nil)
    rejects(ruling: 42)
  end

  test ":pending_sec_ruling is rejected on a :self_service entry" do
    assert_raise ArgumentError, ~r/only valid on a :tenant_wide entry/, fn ->
      SelfServiceEntry.validate!(entry(%{ruling: :pending_sec_ruling}))
    end
  end

  test "a module that carries a malformed entry fails to load" do
    source = """
    defmodule Letflow.Api.RouteScopeSelfServiceEntryTest.Malformed do
      @entries [%{route: "GET /me/modules", key: :MyModulesRead, class: :self_service}]
      Enum.each(@entries, &Letflow.Api.RouteScope.SelfServiceEntry.validate!/1)
    end
    """

    assert_raise ArgumentError, ~r/fields must be exactly/, fn ->
      Code.eval_string(source)
    end
  end
end
