defmodule Letflow.Labels.DefaultsTest do
  @moduledoc """
  REQ-551 / GH #3180 D1: the allowlist comes from `priv/labels/entities_defaults.json` only
  (the web drift test keeps the file equal to the SPA catalog), pure placeholder lookup, and the
  locale normalisation of `Letflow.Labels`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Labels
  alias Letflow.Labels.Defaults

  test "D1 the file has en, ru and kk with the same ids and no refused-prefix id" do
    file = "priv/labels/entities_defaults.json" |> File.read!() |> Jason.decode!()
    assert file |> Map.keys() |> Enum.sort() == ["en", "kk", "ru"]
    id_sets = for {_locale, msgs} <- file, do: msgs |> Map.keys() |> Enum.sort()
    assert id_sets |> Enum.uniq() |> length() == 1

    for id <- hd(id_sets) do
      refute String.starts_with?(id, ["login.", "security.", "auth."])
      assert String.starts_with?(id, "entities.")
    end

    assert Defaults.ids() == hd(id_sets)
    assert file == Defaults.all()
  end

  test "overridable?/1 refuses prefixes, unknown ids and non-binaries" do
    assert Defaults.overridable?("entities.admin.landing.title")
    refute Defaults.overridable?("login.title")
    refute Defaults.overridable?("entities.no.such")
    refute Defaults.overridable?(nil)
  end

  test "placeholders/3 reads {name} names of the default text of the locale" do
    defaults = %{"en" => %{"a" => "x {one} {two_2}"}, "ru" => %{"a" => "plain"}}
    assert Defaults.placeholders(defaults, "a", "en") == MapSet.new(["one", "two_2"])
    assert Defaults.placeholders(defaults, "a", "ru") == MapSet.new()
    assert Defaults.placeholders(defaults, "missing", "en") == MapSet.new()
  end

  test "normalize_locale/1 maps by primary subtag" do
    assert Labels.normalize_locale("ru-RU") == {:ok, "ru"}
    assert Labels.normalize_locale("KK") == {:ok, "kk"}
    assert Labels.normalize_locale("de") == :error
    assert Labels.normalize_locale(nil) == :error
  end
end
