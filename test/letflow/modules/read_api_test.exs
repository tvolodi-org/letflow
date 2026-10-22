defmodule Letflow.Modules.ReadApiTest do
  use ExUnit.Case, async: true

  alias Letflow.Modules.ReadApi

  # The record-backed cases (live, deleted, two tenants) are exercised through the module read APIs
  # that delegate here: org/read_api_test.exs and catalog_items/read_api_test.exs.
  test "inputs that can never name a record are not_found without a query" do
    assert {:error, :not_found} = ReadApi.lookup("tenant_x", "not-a-uuid", ["org_site"])
    assert {:error, :not_found} = ReadApi.lookup("tenant_x", nil, ["org_site"])
    assert {:error, :not_found} = ReadApi.lookup(:nope, Ecto.UUID.generate(), ["org_site"])
    assert {:error, :not_found} = ReadApi.lookup("tenant_x", Ecto.UUID.generate(), [])
  end

  test "active?/3 is false for inputs that can never name a record" do
    refute ReadApi.active?("tenant_x", "not-a-uuid", ["org_site"])
    refute ReadApi.active?(nil, Ecto.UUID.generate(), ["org_site"])
  end
end
