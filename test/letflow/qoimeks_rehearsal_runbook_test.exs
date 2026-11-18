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

  defp numbered_step(steps, number) do
    case Regex.run(~r/^#{number}\. \*\*.*?(?=^\d+\. \*\*|\z)/ms, steps) do
      [step] -> String.replace(step, ~r/\s+/, " ")
      nil -> ""
    end
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
    assert steps =~ ~r/^10\. \*\*Write freeze/m
    assert steps =~ ~r/^11\. \*\*ANALYZE/m
    assert steps =~ "changes no row"
    assert steps =~ ~r/^12\. \*\*Rollback/m
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

  test "QR-9 the code files, optional inputs and unchanged re-upload are documented" do
    text = md()
    steps = section(text, "Steps")
    assert text =~ "| 4 | `code_tag` | `Codes.Import` |"
    assert text =~ "| 5 | `code_assignment` | `Codes.ImportAssignment` |"
    assert text =~ "`value, kind, external_ref_system, external_ref_id`"
    assert text =~ "`code_id, target_type, target_id, external_ref_system, external_ref_id`"
    assert steps =~ "and `barcode` the SKU's barcode"
    assert steps =~ "optional\n   `codes.csv`"
    assert steps =~ "06-codes-NN.xlsx"
    assert steps =~ "07-code-assignments-NN.xlsx"
    assert steps =~ "after any\n   `05-item-places-NN.xlsx` files"
    assert steps =~ "every `code_tag` and `code_assignment` row, is `unchanged`"

    script = File.read!(Path.join(@root, "scripts/pilot/qoimeks_convert.py"))
    assert script =~ "[barcode]"
    assert script =~ "optional codes.csv"
    assert script =~ "06-codes-NN.xlsx"
    assert script =~ "07-code-assignments-NN.xlsx"
  end

  test "QR-G4 the tenant switch precedes line loading and the negative read-back follows it" do
    steps = section(md(), "Steps")
    switch = "5. **Allow negative opening balances**"
    upload = "6. **Upload the lines files**"
    read_back = "After the last file, a user with `StockRead`"
    switch_at = :binary.match(steps, switch)
    upload_at = :binary.match(steps, upload)
    read_back_at = :binary.match(steps, read_back)
    assert switch_at != :nomatch
    assert upload_at != :nomatch
    assert read_back_at != :nomatch
    assert switch_at < upload_at
    assert upload_at < read_back_at
    assert steps =~ "PUT /api/v1/ledger-settings/stock"
    assert steps =~ ":LedgerSettingsManage"

    assert steps =~
             ~s({"allow_negative": true, "reason": "Qoimeks rehearsal: load negative opening balances"})

    assert steps =~ "GET /api/v1/modules/stock/balances"
    assert steps =~ "quantity equals the extract exactly"
    assert steps =~ "skipped zero row has no opening line"
  end

  test "QR-G8A opening headers use the stock route, idempotency and the safe negative order" do
    steps = section(md(), "Steps")
    headers = numbered_step(steps, 4)
    setting = numbered_step(steps, 5)

    assert headers =~ "POST /api/v1/modules/stock/documents"
    assert headers =~ "Idempotency-Key"
    assert headers =~ "`POST /api/v1/documents` answers 403"
    assert headers =~ "Create the headers of the **positive** files now"
    assert setting =~ "Only now create the headers of the negative lines files"
    assert setting =~ "Order: positive headers, switch on, negative headers"
    assert setting =~ "422 `quantity_invalid`"

    ordered_steps = String.replace(steps, ~r/\s+/, " ")
    positive_at = :binary.match(ordered_steps, "Create the headers of the **positive** files now")
    switch_at = :binary.match(ordered_steps, "PUT /api/v1/ledger-settings/stock")

    negative_at =
      :binary.match(ordered_steps, "Only now create the headers of the negative lines files")

    assert positive_at != :nomatch
    assert switch_at != :nomatch
    assert negative_at != :nomatch
    assert positive_at < switch_at
    assert switch_at < negative_at
  end

  test "QR-G8B posting requires issue and approval, with four-eyes handling and retry-only post" do
    steps = section(md(), "Steps")
    upload = numbered_step(steps, 6)

    assert upload =~ "POST /api/v1/modules/stock/documents/<id>/issue"
    assert upload =~ "Idempotency-Key"
    assert upload =~ "stock_opening"
    assert upload =~ "approve"
    assert upload =~ "POST /api/v1/tasks/<task id>/complete"
    assert upload =~ "`{}`"
    assert upload =~ "four_eyes"
    assert upload =~ "defaults to `true`"
    assert upload =~ "403 `separation_of_duties`"
    assert upload =~ "PUT /api/v1/approval-rules/stock_opening/approve"
    assert upload =~ ~s({"four_eyes": false, "reason": "one-person Qoimeks rehearsal company"})
    assert upload =~ "pilot-rollout.md"
    assert upload =~ "step 6"
    assert upload =~ "POST /api/v1/modules/stock/documents/:id/post"
    assert upload =~ "only a retry"
    assert upload =~ "409 `document_not_issued`"
    assert upload =~ "409 `posting_pending`"
    assert upload =~ "positive documents first"
    assert upload =~ "negative documents last"

    four_eyes_at = :binary.match(upload, "PUT /api/v1/approval-rules/stock_opening/approve")
    issue_at = :binary.match(upload, "/issue")
    complete_at = :binary.match(upload, "/complete")
    read_back_at = :binary.match(upload, "After the last file")
    assert four_eyes_at != :nomatch
    assert issue_at != :nomatch
    assert complete_at != :nomatch
    assert read_back_at != :nomatch
    assert four_eyes_at < issue_at
    assert issue_at < complete_at
    assert complete_at < read_back_at
  end

  test "QR-G8C quantity comparison merges every cursor page, not only the xlsx first page" do
    compare = numbered_step(section(md(), "Steps"), 8)

    assert compare =~ "GET /api/v1/modules/stock/balances"
    assert compare =~ "next_cursor"
    assert compare =~ "cursor=<next_cursor>"
    assert compare =~ "null"
    assert compare =~ "every page"
    assert compare =~ "merge"
    assert compare =~ "only the first page"
    assert compare =~ "50 rows"
    assert compare =~ "13 pages for 603 rows"
    assert compare =~ "3 pages for 589 rows"
    assert compare =~ "stock-balances.xlsx"
  end

  test "QR-G8D repeat, counts and scope constraints match posted opening behavior" do
    text = md()
    steps = section(text, "Steps")
    counts = numbered_step(steps, 7)

    repeating =
      text
      |> String.split("Repeating:", parts: 2)
      |> Enum.at(1, "")
      |> String.replace(~r/\s+/, " ")

    scope = section(text, "Deliberately not here")

    assert counts =~ "without database access"
    assert counts =~ "record exports"
    assert counts =~ "stock document list"
    assert counts =~ "env file of the QA actor in the team root"
    assert counts =~ "never print"
    assert repeating =~ "only before the opening documents are posted"
    assert repeating =~ "document_not_draft"
    assert repeating =~ "nothing is written"
    refute scope =~ "posting of the opening documents"
    assert scope =~ "ledger-side count comparison"
  end

  test "QR-8 a renamed reason is caught" do
    text = String.replace(md(), "quantity_invalid", "quantity_wrong")
    assert {:error, %{not_in_runbook: ["quantity_invalid"]}} = check_masters(text, lib_text())
    lib = String.replace(lib_text(), "not_linked", "nl")
    assert {:error, %{not_in_lib: ["not_linked"]}} = check_masters(md(), lib)
  end
end
