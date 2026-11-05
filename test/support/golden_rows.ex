defmodule Letflow.GoldenRows do
  @moduledoc """
  Test helper: exact role rows of one permission in
  `priv/permission_matrix/effective.golden`, independent of how many roles exist.
  """

  import ExUnit.Assertions

  @golden "priv/permission_matrix/effective.golden"

  @doc """
  Asserts that `permission` has exactly one row per role of the golden (the role
  family is every role that appears in the file), that the roles with `true` are
  exactly `expected_true` and that every other row is `false`.
  """
  def assert_true_only_for(permission, expected_true) do
    rows =
      @golden
      |> File.read!()
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.map(&String.split(&1, " ", trim: true))

    all_roles = rows |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort()

    perm_rows = Enum.filter(rows, fn [_role, perm | _] -> perm == permission end)
    perm_roles = perm_rows |> Enum.map(&hd/1) |> Enum.sort()

    assert perm_roles == all_roles,
           "#{permission}: expected one row per role #{inspect(all_roles)}, got #{inspect(perm_roles)}"

    for [role, _perm, effective | _] <- perm_rows do
      assert effective in ["true", "false"], "#{permission} #{role}: bad value #{effective}"
    end

    trues = for [role, _perm, "true" | _] <- perm_rows, do: role
    assert Enum.sort(trues) == Enum.sort(expected_true)
  end
end
