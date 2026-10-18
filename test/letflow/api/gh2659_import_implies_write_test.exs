defmodule Letflow.Api.Gh2659ImportImpliesWriteTest do
  @moduledoc """
  GH #2659 / REQ-505 PR-3, design section 7 and T12: `upsert_by` on
  `POST /entities/records/:entity_type/import` is gated by `EntitiesRecordsImport` ALONE, including
  its update branch. That is only free of privilege escalation while every role holding Import
  also holds `EntitiesRecordsWrite` (an update by ref is a write). This test pins that over
  `priv/permission_matrix/effective.golden` (the matrix `PermissionMatrixTest` keeps fresh): a
  future grant that gives a role Import without Write fails here and forces a conscious decision.

  Pure file read, no database: `async: true`.
  """

  use ExUnit.Case, async: true

  @golden "priv/permission_matrix/effective.golden"

  defp allowed_by_role(permission) do
    @golden
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(&String.split(&1, " "))
    |> Enum.filter(fn [_role, perm | _] -> perm == permission end)
    |> Map.new(fn [role, _perm, allowed | _] -> {role, allowed == "true"} end)
  end

  test "every role holding EntitiesRecordsImport also holds EntitiesRecordsWrite" do
    import = allowed_by_role("EntitiesRecordsImport")
    write = allowed_by_role("EntitiesRecordsWrite")

    holders = for {role, true} <- import, do: role
    assert holders != [], "no role holds EntitiesRecordsImport: the golden parse is broken"
    assert Map.keys(import) == Map.keys(write)

    for role <- holders do
      assert write[role] == true,
             "#{role} holds EntitiesRecordsImport but not EntitiesRecordsWrite: upsert_by would " <>
               "let it update records by external ref without the write grant (GH #2659 section 7)"
    end
  end

  test "the authorization moduledoc records that upsert is within Import's remit" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Letflow.Api.Authorization)
    assert doc =~ "upsert_by"
  end
end
