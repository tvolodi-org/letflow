defmodule Letflow.QoimeksRehearsalRunbookTest do
  @moduledoc """
  REQ-880 (GH #4594): `docs/runbooks/qoimeks-rehearsal.md` carries the Qoimeks move rules (inventory
  section 8.10) as a table and the minimum master data calls of a fresh company. The section
  headings, the twelve rule names in order, the numbered freeze / ANALYZE / rollback steps, the
  script paths marked built, and the field and refusal names are checked against the repository.
  The checks are shown to bite on in-memory copies. No database.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @runbook Path.join(@root, "docs/runbooks/qoimeks-rehearsal.md")
  @moves "Move rules (Qoimeks inventory §8.10)"
  @masters "Minimum master data by API"
  @rules [
    "Copy",
    "One transaction",
    "Counts and hashes per table",
    "Current balances equal",
    "Check-only run first",
    "Short write freeze",
    "ANALYZE after the load",
    "Rollback",
    "Outside working hours",
    "No real data leaves production",
    "Old copy kept 30 days",
    "Own User-Agent"
  ]

  defp md, do: File.read!(@runbook)

  defp section(md, heading) do
    case String.split(md, "\n## #{heading}\n", parts: 2) do
      [_, rest] -> hd(String.split(rest, "\n## ", parts: 2))
      _ -> nil
    end
  end

  defp rows(text) do
    for line <- String.split(text, "\n"),
        String.starts_with?(line, "|"),
        cells =
          line
          |> String.trim()
          |> String.trim("|")
          |> String.split("|")
          |> Enum.map(&String.trim/1),
        do: cells
  end

  defp check_rules(md) do
    case section(md, @moves) do
      nil ->
        {:error, :no_section}

      text ->
        [_header, _sep | data] = rows(text)
        names = Enum.map(data, &hd/1)

        if names != @rules do
          {:error, %{rules: names}}
        else
          missing =
            for [_, how, state] <- data,
                String.contains?(state, "built"),
                [_, path] <- Regex.scan(~r/`(scripts\/[^`\s]+)`/, how),
                not File.exists?(Path.join(@root, path)),
                do: path

          if missing == [], do: :ok, else: {:error, %{missing_files: missing}}
        end
    end
  end

  @fields [
    {"lib/letflow/modules/org/import.ex", ["full_name"]},
    {"lib/letflow/modules/org/masters.ex", ["bin", "legal_entity_id"]}
  ]
  @reasons ["idempotency_key", "entity_type_managed", "quantity_invalid", "not_linked"]

  defp lib_text do
    Path.wildcard(Path.join(@root, "lib/letflow/**/*.ex"))
    |> Enum.map(&File.read!/1)
    |> Enum.join("\n")
  end

  defp check_masters(md, lib) do
    case section(md, @masters) do
      nil ->
        {:error, :no_section}

      text ->
        names = ["full_name", "bin", "legal_entity_id" | @reasons]
        absent = Enum.reject(names, &String.contains?(text, &1))

        source_missing =
          for {file, words} <- @fields,
              src = File.read!(Path.join(@root, file)),
              w <- words,
              not String.contains?(src, w),
              do: {file, w}

        lib_missing = Enum.reject(@reasons, &String.contains?(lib, &1))

        cond do
          absent != [] -> {:error, %{not_in_runbook: absent}}
          source_missing != [] -> {:error, %{not_in_source: source_missing}}
          lib_missing != [] -> {:error, %{not_in_lib: lib_missing}}
          true -> :ok
        end
    end
  end

  test "QR-1 both section headings exist" do
    assert section(md(), @moves)
    assert section(md(), @masters)
  end

  test "QR-2 the twelve rule rows are in order and built scripts exist" do
    assert :ok = check_rules(md())
  end

  test "QR-3 a removed rule row is caught" do
    text = md()
    row = Enum.find(String.split(text, "\n"), &String.starts_with?(&1, "| Rollback |"))
    assert row
    assert {:error, %{rules: _}} = check_rules(String.replace(text, row <> "\n", ""))
  end

  test "QR-4 a built script that does not exist is caught" do
    text = String.replace(md(), "scripts/pilot/qoimeks_compare.sh", "scripts/pilot/nope.sh")
    assert {:error, %{missing_files: ["scripts/pilot/nope.sh"]}} = check_rules(text)
  end

  test "QR-5 freeze, ANALYZE and rollback are numbered steps; one transaction is per file" do
    steps = section(md(), "Steps")
    assert steps =~ ~r/^8\. \*\*Write freeze/m
    assert steps =~ ~r/^9\. \*\*ANALYZE/m
    assert steps =~ "changes no row"
    assert steps =~ ~r/^10\. \*\*Rollback/m
    assert steps =~ "stock-movements.xlsx"
    [_, tx] = Regex.run(~r/\| One transaction \|([^\n]*)/, md())
    assert tx =~ "atomic=true"
    assert tx =~ "not one transaction"
  end

  test "QR-6 master data calls are in order with the stated refusals" do
    text = section(md(), @masters)

    order = [
      "legal-entities",
      "sites",
      "units",
      "employees",
      "location_node",
      "links",
      "upsert_by=external_ref",
      "Opening document"
    ]

    idx = Enum.map(order, fn w -> {w, :binary.match(text, w)} end)
    assert Enum.all?(idx, fn {_, m} -> m != :nomatch end)
    positions = Enum.map(idx, fn {_, {p, _}} -> p end)
    assert positions == Enum.sort(positions)
    assert text =~ "403"
    assert text =~ "(a uuid)"
  end

  test "QR-7 field and reason names exist in their sources" do
    assert :ok = check_masters(md(), lib_text())
  end

  test "QR-8 a renamed reason is caught" do
    text = String.replace(md(), "quantity_invalid", "quantity_wrong")
    assert {:error, %{not_in_runbook: ["quantity_invalid"]}} = check_masters(text, lib_text())
    lib = String.replace(lib_text(), "not_linked", "nl")
    assert {:error, %{not_in_lib: ["not_linked"]}} = check_masters(md(), lib)
  end
end
