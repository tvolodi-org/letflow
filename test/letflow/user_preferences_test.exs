defmodule Letflow.UserPreferencesTest do
  @moduledoc "T-1389: the whitelist and the pure validation of `Letflow.UserPreferences.put/3`."

  use ExUnit.Case, async: true

  alias Letflow.UserPreferences

  test "the whitelist mirrors the web layout registry" do
    assert UserPreferences.keys() == ["ui.document_layout", "ui.layout"]
    assert UserPreferences.allowed_values("ui.layout") == []
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

  test "U2 sanitize_layout rounds to 0.1 and the width to an integer" do
    sl = &UserPreferences.sanitize_layout/1

    pane = fn n ->
      sl.(%{"screens" => %{"a" => %{"panes" => %{"x" => [n]}}}})["screens"]["a"]["panes"]["x"]
    end

    assert pane.(38.26) == [38.3]
    assert pane.(14.25) == [14.3]
    assert pane.(15.04) == [15]
    assert sl.(%{"shell" => %{"sidenav" => %{"w" => 250.45}}})["shell"]["sidenav"]["w"] == 251
    assert sl.(%{"shell" => %{"sidenav" => %{"w" => 250.4}}})["shell"]["sidenav"]["w"] == 250
    assert sl.(:nope) == %{"v" => 1, "shell" => %{"sidenav" => %{}}, "screens" => %{}}
  end

  test "B1 linesMode survives only as grid or form" do
    sl = &UserPreferences.sanitize_layout/1
    mode = fn v -> sl.(%{"screens" => %{"a" => %{"linesMode" => v}}})["screens"]["a"] end

    assert mode.("grid") == %{"linesMode" => "grid"}
    assert mode.("form") == %{"linesMode" => "form"}
    assert mode.("table") == nil
    assert mode.(1) == nil
    assert mode.(nil) == nil

    kept =
      sl.(%{"screens" => %{"a" => %{"linesMode" => "form", "cols" => %{"t" => %{"c" => 29}}}}})

    assert kept["screens"]["a"] == %{"linesMode" => "form", "cols" => %{"t" => %{"c" => 29}}}
  end

  test "U3 a bad ui.layout is refused before any database access" do
    p = "no_such_schema"
    u = Ecto.UUID.generate()

    assert {:error, {:invalid, "invalid value for preference key: ui.layout"}} =
             UserPreferences.put(p, u, %{"ui.layout" => %{"v" => 1}})

    assert {:error, {:invalid, "invalid value for preference key: ui.layout"}} =
             UserPreferences.put(p, u, %{"ui.layout" => "{nope"})

    assert {:error, {:invalid, "preferences too large"}} =
             UserPreferences.put(p, u, %{"ui.layout" => String.duplicate("x", 8193)})
  end
end
