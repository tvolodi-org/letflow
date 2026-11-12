defmodule Letflow.PilotRolloutRunbookTest do
  @moduledoc """
  REQ-786 (GH #4073): `docs/runbooks/pilot-rollout.md` keeps its module install order and its Data
  load table in step with the module manifests. The module ids, their `depends_on`, the record type
  set and the File import values are derived at run time from `Letflow.Modules.Catalog`; no count is
  pinned. The checks are shown to bite on in-memory copies (a row removed, a File import value
  flipped, `org` moved below `locations`). No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog

  @root Path.expand("../..", __DIR__)
  @runbook Path.join(@root, "docs/runbooks/pilot-rollout.md")

  @module_ids ~w(org catalog_items codes locations stock assets)
  @table_modules ~w(org locations catalog_items codes)
  @extra_types %{
    "stock_opening_line" => "stock",
    "assets_card" => "assets",
    "assets_opening_line" => "assets"
  }
  @headings [
    "Status",
    "Before the pilot starts",
    "Onboarding",
    "Data load",
    "Printed forms",
    "Support",
    "Open owner questions"
  ]
  @columns ["Order", "Record type", "Module", "File import", "How it comes in", "Source"]
  @forms ~w(Z-1 Z-2 Z-3 Z-4 Z-5 Z-6 Z-7 Inv-1 Inv-3 Inv-7 Inv-10 Inv-18 DA-1 DA-2 DA-3 DA-4 Inv-8 Inv-16)

  defp manifests do
    for mod <- Catalog.entry_modules(),
        m = mod.manifest(),
        m.id in @module_ids,
        into: %{},
        do: {m.id, m}
  end

  defp section(md, heading) do
    [_, rest] = String.split(md, "\n## #{heading}\n", parts: 2)
    hd(String.split(rest, "\n## ", parts: 2))
  end

  defp lines(text), do: String.split(text, "\n")

  # --- module install order -------------------------------------------------

  defp install_ids(md) do
    [_, rest] = String.split(md, "\n### Module install order\n", parts: 2)
    block = hd(String.split(rest, "\n## ", parts: 2))

    for line <- lines(block),
        [_, id] <- [Regex.run(~r/^\d+\.\s+`([^`]+)`/, line)],
        do: id
  end

  defp check_install(md, mans) do
    ids = install_ids(md)
    pos = ids |> Enum.with_index() |> Map.new()

    bad =
      for {id, i} <- pos,
          dep <- Map.get(mans, id, %{depends_on: []}).depends_on,
          dep_i = Map.get(pos, dep),
          is_nil(dep_i) or dep_i >= i,
          do: {id, dep}

    cond do
      Enum.sort(ids) != Enum.sort(Map.keys(mans)) ->
        {:error, %{ids: ids, expected: Enum.sort(Map.keys(mans))}}

      bad != [] ->
        {:error, %{order: bad}}

      true ->
        :ok
    end
  end

  # --- data load table ------------------------------------------------------

  defp rows(md) do
    for line <- lines(section(md, "Data load")),
        String.starts_with?(line, "|"),
        cells =
          line
          |> String.trim()
          |> String.trim("|")
          |> String.split("|")
          |> Enum.map(&String.trim/1),
        do: cells
  end

  defp expected_types(mans) do
    from_manifests =
      for id <- @table_modules, t <- mans[id].manages_entity_types, do: {t, id}

    Map.new(from_manifests) |> Map.merge(@extra_types)
  end

  defp check_table(md, mans) do
    [header, _sep | data] = rows(md)
    expected = expected_types(mans)

    parsed =
      for [order, type, mod, file, _how, _src] <- data do
        {String.to_integer(order), String.trim(type, "`"), String.trim(mod, "`"), file}
      end

    types = Enum.map(parsed, &elem(&1, 1))
    orders = Enum.map(parsed, &elem(&1, 0))
    pos = @module_ids |> Enum.with_index() |> Map.new()

    cond do
      header != @columns ->
        {:error, %{header: header}}

      Enum.sort(types) != Enum.sort(Map.keys(expected)) ->
        {:error,
         %{
           missing: Map.keys(expected) -- types,
           extra: types -- Map.keys(expected)
         }}

      orders != Enum.sort(orders) or orders != Enum.uniq(orders) ->
        {:error, %{orders: orders}}

      wrong = Enum.find(parsed, fn {_, t, m, _} -> expected[t] != m end) ->
        {:error, %{module: wrong}}

      wrong = Enum.find(parsed, &module_before_dependency?(&1, parsed, mans, pos)) ->
        {:error, %{dependency_order: wrong}}

      wrong =
          Enum.find(parsed, fn {_, t, m, f} ->
            f != if(Catalog.import_function(m, t) == :ok, do: "yes", else: "no")
          end) ->
        {:error, %{file_import: wrong}}

      true ->
        :ok
    end
  end

  defp module_before_dependency?({o, _t, m, _f}, parsed, mans, _pos) do
    deps = Map.get(mans, m, %{depends_on: []}).depends_on
    Enum.any?(parsed, fn {o2, _, m2, _} -> m2 in deps and o2 > o end)
  end

  setup_all do
    {:ok, md: File.read!(@runbook), mans: manifests()}
  end

  test "T1 the level-2 headings are the seven of the requirement, in order", %{md: md} do
    headings =
      for line <- lines(md),
          String.starts_with?(line, "## "),
          do: String.trim_leading(line, "## ")

    assert headings == @headings
  end

  test "T2 every role named in Onboarding is a real role; PLATFORM_ADMIN is cited with docs/roles.md",
       %{md: md} do
    onboarding = section(md, "Onboarding")
    roles = Letflow.Api.Authorization.roles() |> Enum.map(&to_string/1)

    tokens =
      Regex.scan(~r/`([A-Z][A-Z_]+)`/, onboarding) |> Enum.map(fn [_, t] -> t end) |> Enum.uniq()

    assert tokens != []
    for t <- tokens, do: assert(t in roles, "#{t} is not in Authorization.roles/0")
    assert String.contains?(onboarding, "PLATFORM_ADMIN")
    assert String.contains?(onboarding, "docs/roles.md")
  end

  test "T3 the module install list covers the six modules after their dependencies", %{
    md: md,
    mans: mans
  } do
    assert Map.keys(mans) |> Enum.sort() == Enum.sort(@module_ids)
    assert check_install(md, mans) == :ok
  end

  test "T4 the Data load table matches the manifests and import functions", %{md: md, mans: mans} do
    assert check_table(md, mans) == :ok
  end

  test "T5 the Printed forms section names all forms and cites the mapping", %{md: md} do
    forms = section(md, "Printed forms")
    for f <- @forms, do: assert(String.contains?(forms, f), "form #{f} missing")
    assert String.contains?(forms, "docs/assets/kz-forms-mapping.md")
  end

  test "T6 a copy with one Data load row removed fails and names the type", %{md: md, mans: mans} do
    copy =
      md
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "| 8 | `catalog_item` |"))
      |> Enum.join("\n")

    refute copy == md
    assert {:error, %{missing: missing}} = check_table(copy, mans)
    assert "catalog_item" in missing
  end

  test "T7 a copy with one File import value flipped fails", %{md: md, mans: mans} do
    copy =
      String.replace(md, "| `org_unit` | `org` | yes |", "| `org_unit` | `org` | no |")

    refute copy == md
    assert {:error, %{file_import: {_, "org_unit", "org", "no"}}} = check_table(copy, mans)
  end

  test "T8 a copy with org moved below locations fails", %{md: md, mans: mans} do
    copy =
      md
      |> String.replace("1. `org`\n", "TMP_ORG\n")
      |> String.replace("4. `locations`\n", "4. `locations`\n1. `org`\n")
      |> String.replace("TMP_ORG\n", "")

    refute copy == md
    assert {:error, %{order: bad}} = check_install(copy, mans)
    assert {"locations", "org"} in bad
  end

  test "T9 the sections cite their sources and give no invented hours", %{md: md} do
    for needle <- [
          "D-086",
          "Customers and rollout",
          "docs/runbooks/production-readiness.md",
          "The stock module is NOT enabled for a customer tenant until L6 AND L7 are done",
          "OQ-23",
          "D-063",
          "docs/runbooks/onboarding-new-tenant-realm.md",
          "Tenant type (REQ-469)",
          "0079 D1",
          "0083 D1",
          "docs/assets/asset-xlsx.md",
          "proposal, to be confirmed by the owner",
          "tvolodi-org/letflow",
          "pending the sign-in choice"
        ] do
      assert String.contains?(md, needle), "runbook does not mention #{needle}"
    end

    refute Regex.match?(~r/\d\s*(hours|h|min)\b/i, section(md, "Support"))

    source =
      File.read!(
        Path.join(@root, "docs/migration/decisions/0073-domain-neutral-ledger-primitive.md")
      )

    assert String.contains?(
             source,
             "The stock module is NOT enabled for a customer tenant until L6 AND L7 are done"
           )
  end

  test "T10 the open owner questions cover the required topics", %{md: md} do
    open = md |> section("Open owner questions") |> String.downcase()

    for topic <- ["dealer", "support hours", "channel", "length", "volume", "forms", "sign-in"] do
      assert String.contains?(open, topic), "open questions miss #{topic}"
    end
  end
end
