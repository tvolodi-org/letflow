defmodule Letflow.UserPreferencesTest do
  @moduledoc "T-1389: the whitelist and the pure validation of `Letflow.UserPreferences.put/3`."

  use ExUnit.Case, async: true

  alias Letflow.UserPreferences

  test "the whitelist mirrors the web layout registry" do
    assert UserPreferences.keys() == ["ui.document_layout"]
    assert UserPreferences.allowed_values("ui.document_layout") == ["row", "tabs"]
    assert UserPreferences.allowed_values("nope") == []
  end

  test "invalid input is refused before any database access" do
    # a prefix that does not exist: reaching the database would raise
    p = "no_such_schema"
    u = Ecto.UUID.generate()

    assert {:error, {:invalid, "unknown preference key: a.b"}} =
             UserPreferences.put(p, u, %{"a.b" => 1})

    assert {:error, {:invalid, "invalid preference key"}} =
             UserPreferences.put(p, u, %{"A b" => 1})

    assert {:error, {:invalid, "invalid value for preference key: ui.document_layout"}} =
             UserPreferences.put(p, u, %{"ui.document_layout" => "grid"})

    assert {:error, {:invalid, "preferences must be a non-empty object"}} =
             UserPreferences.put(p, u, %{})

    assert {:error, {:invalid, "preferences must be a non-empty object"}} =
             UserPreferences.put(p, u, nil)
  end
end
