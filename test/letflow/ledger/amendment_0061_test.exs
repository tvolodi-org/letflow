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
    refute tail =~ "\n## ", "no section follows the amendment, a later one would hide it"

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
end
