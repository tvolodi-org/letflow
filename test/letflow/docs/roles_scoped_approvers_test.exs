defmodule Letflow.Docs.RolesScopedApproversTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2d, T-F13 (AC 17 and the AC 13 amendment of PR #2810; SEC ruling RA-13),
  as amended by REQ-532 / GH #3091.

  REQ-518 AC 17 pinned three verbatim sentences in `docs/roles.md` that said no task carried a scope
  node until W3b. REQ-532 writes `tasks.scope_node_id`, so those sentences are false and are removed;
  this test now pins what replaces them:

    * `docs/roles.md` carries the section headed `Known limitation: scoped approvers (stage 2)`
      EXACTLY ONCE, and the section states the task scope rule (REQ-532): a task carries its
      instance's scope node, a NULL task is invisible to a scoped caller, and the F1 rule (routing
      role AND a TASK_WORKER grant covering the node; other roles never substitute);
    * the RA-13 exemption is stated in a blank-line-delimited paragraph of its own that mentions the
      exemption and contains no sentence of the section (the predicate, never a role name);
    * the three REQ-518 sentences are gone from the file.

  The rules live in `violations/1` (a pure function of the document text), run on the REAL file (it
  must report nothing) and on SEEDED bad documents (each rule must fire). The file is read with its
  working-tree line endings normalised to LF (`core.autocrlf` is true on the Windows checkouts). No
  database: `async: true`.
  """

  use ExUnit.Case, async: true

  @heading "## Known limitation: scoped approvers (stage 2)"

  # REQ-518 AC 17 sentences that REQ-532 made false: none may remain in the document
  @removed [
    "Tasks carry no scope node until W3b",
    "A scoped-only approver cannot see, claim or complete any task",
    "This gap blocks turning scope enforcement on"
  ]

  # the F1 rule terms the section must carry (REQ-518 AC 13/17 meaning, kept by REQ-532)
  @f1_terms [
    "TASK_WORKER grant",
    "routing role",
    "PROCESS_OPERATOR",
    "TENANT_ADMIN",
    "never substitutes",
    "task without a scope node",
    "Assigning and reassigning"
  ]

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

  # every rule as a list of violation atoms
  defp violations(doc) do
    body = section(doc)
    paragraphs = String.split(doc, ~r/\n[ \t]*\n/)
    exemption = Enum.filter(paragraphs, fn p -> p =~ "RA-13" and p =~ "exempt" end)

    heading =
      if occurrences(doc, @heading <> "\n") == 1, do: [], else: [:heading_not_exactly_once]

    removed =
      for sentence <- @removed, doc =~ sentence, do: {:removed_sentence_present, sentence}

    scope =
      cond do
        body == nil ->
          [:section_missing]

        not (body =~ "tasks.scope_node_id" and body =~ "REQ-532") ->
          [:scope_rule_missing]

        Enum.any?(@f1_terms, &(not (body =~ &1))) ->
          [:f1_rule_missing]

        true ->
          []
      end

    separate =
      cond do
        exemption == [] ->
          [:no_exemption_paragraph]

        Enum.any?(exemption, fn p -> Enum.any?(@removed, &(p =~ &1)) end) ->
          [:exemption_paragraph_holds_a_sentence]

        true ->
          []
      end

    heading ++ removed ++ scope ++ separate
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

  test "the REQ-518 AC 17 sentences that REQ-532 made false are gone from the file", %{doc: doc} do
    for sentence <- @removed, do: refute(doc =~ sentence, sentence)
  end

  test "the section states the REQ-532 scope rule and the F1 rule", %{doc: doc} do
    body = section(doc)

    assert body =~ "tasks.scope_node_id"
    assert body =~ "REQ-532"
    assert body =~ "NULL"

    for term <- @f1_terms, do: assert(body =~ term, term)
  end

  test "RA-13: a blank-line-delimited paragraph states the exemption (predicate, no role name) and contains no sentence of the section",
       %{doc: doc} do
    paragraphs = String.split(doc, ~r/\n[ \t]*\n/)
    [paragraph | _] = Enum.filter(paragraphs, fn p -> p =~ "RA-13" and p =~ "exempt" end)

    for sentence <- @removed, do: refute(paragraph =~ sentence)

    # the exemption paragraph is inside the section and states the predicate, not a role name
    assert section(doc) =~ paragraph
    assert paragraph =~ "tenant-wide"
    assert paragraph =~ "routing-role"
    assert paragraph =~ "never a role name"
  end

  describe "the rules are LIVE on seeded bad documents" do
    @good_exemption "The RA-13 exemption is separate: a principal exempt from the grant requirement."
    @good_scope "Each task carries the scope node of its instance (`tasks.scope_node_id`, REQ-532); a task without a scope node is NULL and stays fail-closed."
    @good_f1 "A scoped TASK_WORKER needs a routing role and a TASK_WORKER grant covering the node. A grant of PROCESS_OPERATOR or TENANT_ADMIN never substitutes for it, a task without a scope node is invisible to a scoped caller, and Assigning and reassigning follow the route permission."

    defp doc_with(paragraphs), do: Enum.join([@heading | paragraphs], "\n\n")

    defp good_doc, do: doc_with([@good_scope, @good_f1, @good_exemption])

    test "a well formed document breaks no rule" do
      assert violations(good_doc()) == []
    end

    test "a reintroduced REQ-518 sentence is reported" do
      doc =
        doc_with([@good_scope, @good_f1, @good_exemption, "Tasks carry no scope node until W3b."])

      assert {:removed_sentence_present, "Tasks carry no scope node until W3b"} in violations(doc)
    end

    test "a missing scope rule and a missing F1 term are reported" do
      no_scope = doc_with([@good_f1, @good_exemption])
      assert :scope_rule_missing in violations(no_scope)

      no_f1 = doc_with([@good_scope, "A routing role applies.", @good_exemption])
      assert :f1_rule_missing in violations(no_f1)
    end

    test "a missing section is reported" do
      assert :heading_not_exactly_once in violations("# Roles\n\n" <> @good_scope)
    end

    test "an exemption merged into a paragraph that holds a removed sentence, and no exemption paragraph, are reported" do
      merged =
        doc_with([
          @good_scope,
          @good_f1,
          "Tasks carry no scope node until W3b.\n" <> @good_exemption
        ])

      assert :exemption_paragraph_holds_a_sentence in violations(merged)

      none = doc_with([@good_scope, @good_f1, "Nothing about it."])
      assert :no_exemption_paragraph in violations(none)
    end
  end
end
