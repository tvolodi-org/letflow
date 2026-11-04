defmodule Letflow.Ledger.Amendment0061Test do
  @moduledoc """
  REQ-686 criterion 7: decision 0061 carries the class 5b amendment, appended as a new section whose
  quoted text is word for word the text of decision 0073 A3; no earlier line of 0061 changed.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @file_0061 "docs/migration/decisions/0061-engine-lock-order-platform-invariant.md"
  @file_0073 "docs/migration/decisions/0073-domain-neutral-ledger-primitive.md"

  defp lf(text), do: String.replace(text, "\r\n", "\n")

  test "the amendment section exists and quotes 0073 A3 word for word" do
    adr = lf(File.read!(@file_0061))
    source = lf(File.read!(@file_0073))

    [_, rest] = String.split(source, "### A3 Lock order", parts: 2)
    [quote | _] = Regex.run(~r/^> Rule 1 gains class 5b[^\n]*$/m, rest)

    assert adr =~ "\n## Amended (REQ-686, ledger class 5b)\n"
    [_, amendment] = String.split(adr, "## Amended (REQ-686, ledger class 5b)\n", parts: 2)
    assert String.contains?(amendment, quote)
    assert quote =~ "class 5b"
  end

  test "the amendment is the last section and adds lines only" do
    adr = lf(File.read!(@file_0061))
    {index, _} = :binary.match(adr, "## Amended (REQ-686, ledger class 5b)")
    tail = binary_part(adr, index, byte_size(adr) - index)

    # REQ-688 appends exactly one later section (D-1 below); no other section may follow.
    sections = Regex.scan(~r/^## .*$/m, tail) |> List.flatten()

    assert sections == [
             "## Amended (REQ-686, ledger class 5b)",
             "## Amended (REQ-688, ledger pre-lock on the service apply)"
           ]

    case System.cmd("git", ["diff", "--numstat", "origin/main", "--", @file_0061],
           stderr_to_stdout: true
         ) do
      {out, 0} when out != "" ->
        [_added, deleted | _] = String.split(out, "\t")
        assert deleted == "0"

      _no_git_or_origin_or_unchanged ->
        :ok
    end
  end

  # REQ-688 criterion 8 (D-1): the pre-lock amendment follows the REQ-686 section, is the last
  # section and carries the four items of the requirement text.
  test "D-1 the REQ-688 amendment follows REQ-686 and has the four items" do
    adr = lf(File.read!(@file_0061))
    heading = "## Amended (REQ-688, ledger pre-lock on the service apply)\n"

    {at_686, _} = :binary.match(adr, "## Amended (REQ-686, ledger class 5b)")
    {at_688, _} = :binary.match(adr, heading)
    assert at_688 > at_686

    [_, section] = String.split(adr, heading, parts: 2)
    refute section =~ "\n## "
    assert section =~ "Source: decision 0073 D-L12 and slice table row L5"

    for item <- [
          "Item 1 (placement).",
          "Item 2 (containment).",
          "Item 3 (guard, rule 4).",
          "Item 4 (forced overlap, rule 5)."
        ] do
      assert section =~ item
    end

    assert String.trim_trailing(section) =~
             "both commit with no deadlock."
  end
end
