defmodule Letflow.Docs.RolesScopedApproversTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2d, T-F13 (AC 17 and the AC 13 amendment of PR #2810; design
  `lib/letflow/design/req518-compiler-scope-filter.md` C.5, 10.3; spec `test/specs/REQ-518-2d.md`;
  SEC ruling RA-13): `docs/roles.md` carries a section headed
  `Known limitation: scoped approvers (stage 2)` that contains the three verbatim sentences S1, S2
  and S3 EXACTLY ONCE EACH file-wide (exact string match, no paraphrase), and the RA-13
  exemption is stated in a blank-line-delimited paragraph of its own that mentions the exemption
  and contains NONE of the three strings.

  The rules live in `violations/1` (a pure function of the document text), which is run on the REAL
  file (it must report nothing) and on SEEDED bad documents (each rule must fire: a duplicated or
  paraphrased sentence, a missing sentence, a missing section, the exemption merged into a
  paragraph that holds a verbatim sentence, no exemption paragraph).

  The file is read with its working-tree line endings normalised to LF (`core.autocrlf` is true on
  the Windows checkouts). The three strings are also checked against the requirement text of AC 17
  in `docs/requirements.yaml`, so a changed requirement sentence cannot silently diverge from the
  doc. No database: `async: true`.
  """

  use ExUnit.Case, async: true

  @heading "## Known limitation: scoped approvers (stage 2)"

  @s1 "Tasks carry no scope node until W3b; this is a known limitation of stage 2, not a bug."
  @s2 "A scoped-only approver cannot see, claim or complete any task while scope enforcement is on for the tenant."
  @s3 "This gap blocks turning scope enforcement on for any tenant that has scoped approvers, until the W3b writer of tasks.scope_node_id lands."

  defp read(path), do: path |> File.read!() |> String.replace("\r\n", "\n")

  defp occurrences(text, needle), do: length(:binary.matches(text, needle))

  defp section(text) do
    case String.split(text, @heading <> "\n", parts: 2) do
      [_before, rest] ->
        case String.split(rest, ~r/\n## /, parts: 2) do
          [body, _next] -> body
          [body] -> body
        end

      [_no_section] ->
        nil
    end
  end

  # every rule of AC 17 and the RA-13 paragraph rule of AC 13, as a list of violation atoms
  defp violations(doc) do
    body = section(doc)
    paragraphs = String.split(doc, ~r/\n[ \t]*\n/)

    exemption = Enum.filter(paragraphs, fn p -> p =~ "RA-13" and p =~ "exempt" end)

    heading =
      if occurrences(doc, @heading <> "\n") == 1, do: [], else: [:heading_not_exactly_once]

    sentences =
      for {name, sentence} <- [s1: @s1, s2: @s2, s3: @s3],
          occurrences(doc, sentence) != 1,
          do: {:sentence_not_exactly_once, name}

    inside =
      for {name, sentence} <- [s1: @s1, s2: @s2, s3: @s3],
          body == nil or occurrences(body, sentence) != 1,
          do: {:sentence_not_in_section, name}

    separate =
      cond do
        exemption == [] ->
          [:no_exemption_paragraph]

        Enum.any?(exemption, fn p -> Enum.any?([@s1, @s2, @s3], &(p =~ &1)) end) ->
          [:exemption_paragraph_holds_a_sentence]

        true ->
          []
      end

    heading ++ sentences ++ inside ++ separate
  end

  setup_all do
    {:ok, doc: read("docs/roles.md")}
  end

  test "the real docs/roles.md breaks no rule", %{doc: doc} do
    assert violations(doc) == []
  end

  test "the section heading exists exactly once, as a level-2 heading", %{doc: doc} do
    assert occurrences(doc, @heading <> "\n") == 1
    assert occurrences(doc, "Known limitation: scoped approvers (stage 2)") == 1
  end

  test "S1, S2 and S3 each occur EXACTLY ONCE in docs/roles.md, verbatim", %{doc: doc} do
    for {name, sentence} <- [s1: @s1, s2: @s2, s3: @s3] do
      assert occurrences(doc, sentence) == 1, "#{name} must occur exactly once"
    end

    # exact match, not a paraphrase: a changed word would not be found
    refute doc =~ "scoped approver cannot see"
  end

  test "the three sentences sit inside the section, in order S1, S2, S3", %{doc: doc} do
    body = section(doc)

    for sentence <- [@s1, @s2, @s3] do
      assert occurrences(body, sentence) == 1
    end

    positions =
      for sentence <- [@s1, @s2, @s3] do
        {at, _len} = :binary.match(body, sentence)
        at
      end

    assert positions == Enum.sort(positions)
  end

  test "the three strings equal the sentences of AC 17 in docs/requirements.yaml (no silent divergence)" do
    yaml = read("docs/requirements.yaml")

    for sentence <- [@s1, @s2, @s3] do
      assert occurrences(yaml, sentence) >= 1, sentence
    end
  end

  test "RA-13: a blank-line-delimited paragraph states the exemption (predicate, no role name) and contains none of S1, S2, S3",
       %{doc: doc} do
    paragraphs = String.split(doc, ~r/\n[ \t]*\n/)
    [paragraph | _] = Enum.filter(paragraphs, fn p -> p =~ "RA-13" and p =~ "exempt" end)

    for sentence <- [@s1, @s2, @s3], do: refute(paragraph =~ sentence)

    # the exemption paragraph is inside the section and states the predicate, not a role name
    assert section(doc) =~ paragraph
    assert paragraph =~ "tenant-wide"
    assert paragraph =~ "routing-role"
    assert paragraph =~ "never a role name"
  end

  test "the section states the F1 rule: routing role AND a TASK_WORKER grant covering the node; other roles never substitute; a node-less task is invisible; assign follows the route permission",
       %{doc: doc} do
    body = section(doc)

    assert body =~ "TASK_WORKER grant"
    assert body =~ "routing role"
    assert body =~ "PROCESS_OPERATOR"
    assert body =~ "TENANT_ADMIN"
    assert body =~ "never substitutes"
    assert body =~ "task without a scope node"
    assert body =~ "Assigning and reassigning"
  end

  describe "the rules are LIVE on seeded bad documents" do
    @good_exemption "The RA-13 exemption is separate: a principal exempt from the grant requirement."

    defp doc_with(paragraphs), do: Enum.join([@heading | paragraphs], "\n\n")

    test "a duplicated S2 (file-wide count 2) is reported" do
      doc = doc_with([@s1 <> "\n" <> @s2 <> "\n" <> @s3, @good_exemption, "Again: " <> @s2])
      assert {:sentence_not_exactly_once, :s2} in violations(doc)
    end

    test "a paraphrased S1 is reported (exact match, no paraphrase)" do
      paraphrased = "Tasks have no scope node until W3b; this is a known limit of stage 2."
      doc = doc_with([paraphrased <> "\n" <> @s2 <> "\n" <> @s3, @good_exemption])
      assert {:sentence_not_exactly_once, :s1} in violations(doc)
    end

    test "a missing S3 and a missing section are reported" do
      doc = doc_with([@s1 <> "\n" <> @s2, @good_exemption])
      assert {:sentence_not_exactly_once, :s3} in violations(doc)

      assert :heading_not_exactly_once in violations("# Roles\n\n" <> @s1 <> @s2 <> @s3)
    end

    test "a sentence outside the section is reported" do
      doc = doc_with([@s1 <> "\n" <> @s2, @good_exemption]) <> "\n\n## Matrix\n\n" <> @s3
      assert {:sentence_not_in_section, :s3} in violations(doc)
    end

    test "an exemption merged into a paragraph that holds a verbatim sentence, and no exemption paragraph, are reported" do
      merged = doc_with([@s1 <> "\n" <> @s2 <> "\n" <> @s3 <> "\n" <> @good_exemption])
      assert :exemption_paragraph_holds_a_sentence in violations(merged)

      none = doc_with([@s1 <> "\n" <> @s2 <> "\n" <> @s3, "Nothing about it."])
      assert :no_exemption_paragraph in violations(none)
    end

    test "a well formed document breaks no rule" do
      assert violations(doc_with([@s1 <> "\n" <> @s2 <> "\n" <> @s3, @good_exemption])) == []
    end
  end
end
