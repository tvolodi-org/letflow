defmodule Letflow.Docs.RolesOnFlipDocsTest do
  @moduledoc """
  REQ-519 slice 2f-b (GH #2535), AC 12 (the sentence in the docs, T-E15), AC 20 and the
  ON_IN_PRODUCTION obligations of SEC S-9 / design section 4.10 (spec
  `test/specs/REQ-519-2f-b.md`): what `docs/roles.md` must say before any tenant is flipped.

    * the AC 12 sentence is in `docs/roles.md` EXACTLY ONCE and equals
      `Letflow.ScopeEnforcement.ShadowWindow.scope_sentence/0` byte for byte (the code constant is
      the source of truth; the docs cannot drift);
    * the section "What `on` means in production today" holds the eight numbered items, in order,
      each with its load-bearing claim, after an introduction that names the open follow-ups
      (RA-6 / REQ-525..527 / #2862, #2869, #2870, amendment PR #2871);
    * the operator procedure states the transition table, the mandatory reasons and the gate codes
      (every code of the gate, and the thresholds' names and defaults);
    * the known limitations include the scoped `upsert_by external_ref` refusal in
      `import_scope_check/6`;
    * the platform-tenant sentence (SEC C-6) is present.

  The rules are pure functions of the document text, run on the REAL file and on SEEDED bad
  documents (so a missing item, a swapped order, a paraphrased sentence all fail). The file is read
  with line endings normalised to LF (`core.autocrlf` on the Windows checkouts). No database:
  `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.ScopeEnforcement.ShadowWindow

  @operator_heading "## Turning scope enforcement on and off (operator procedure)"
  @production_heading "## What `on` means in production today"
  @limitations_heading "## Known limitations of `on` (REQ-519)"

  @platform_sentence "A platform tenant stored as `on` does not restrict its PLATFORM_ADMIN on platform-scope routes; grants never decide platform scope."

  @gate_codes ~w(
    bindings_without_row
    org_inconsistent
    tokens_exceed_owner
    zero_tenant_wide_admins
    scoped_approvers_without_task_scope
    shadow_evidence_insufficient
  )

  # item number => the claims the item must carry (each a substring of the normalised item text)
  @items %{
    1 => ["interactive tenant-wide TENANT_ADMIN", "only from `shadow`", "audit trail"],
    2 => [
      "admin plane is closed to scoped admins",
      "uniform 403",
      "no longer widen",
      "fail closed"
    ],
    3 => [
      "does NOT deliver data-level scoping",
      "No installed module declares scope",
      "tasks.scope_node_id"
    ],
    4 => ["denials of tenant-wide and admin-plane routes"],
    5 => ["definitions, entity-definition, instance and service reads", "RA-6"],
    6 => ["Do not scope the CANDIDATE binding"],
    7 => ["mandatory reason", "Tokens cannot", "no platform-scope break-glass"],
    8 => [@platform_sentence]
  }

  defp read(path), do: path |> File.read!() |> String.replace("\r\n", "\n")

  defp occurrences(text, needle), do: length(:binary.matches(text, needle))

  # The text between `heading` and the next `## ` heading (or the end), without the heading line.
  defp section(text, heading) do
    case String.split(text, heading <> "\n", parts: 2) do
      [_before, rest] -> rest |> String.split(~r/\n## /, parts: 2) |> hd()
      [_whole] -> nil
    end
  end

  # `{introduction, %{n => item_text}}` of the production section (items are `N. ` lines).
  defp production(text) do
    body = section(text, @production_heading)

    if is_nil(body) do
      nil
    else
      [intro | rest] = String.split(body, ~r/\n(?=\d\. )/)

      items =
        rest
        |> Enum.map(fn item ->
          [number, text] = String.split(item, ". ", parts: 2)
          {String.to_integer(number), String.trim(text)}
        end)

      {intro, items}
    end
  end

  # Every violation of the documentation rules, as atoms / tuples (a pure function of the text).
  defp violations(text) do
    sentence = ShadowWindow.scope_sentence()

    base =
      [
        {occurrences(text, sentence) != 1, :scope_sentence_not_exactly_once},
        {occurrences(text, @platform_sentence) != 1, :platform_sentence_not_exactly_once},
        {is_nil(section(text, @operator_heading)), :operator_section_missing},
        {is_nil(section(text, @limitations_heading)), :limitations_section_missing}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    base ++ production_violations(text) ++ limitation_violations(text)
  end

  defp production_violations(text) do
    case production(text) do
      nil ->
        [:production_section_missing]

      {intro, items} ->
        numbers = Enum.map(items, &elem(&1, 0))

        order = if numbers == Enum.to_list(1..8), do: [], else: [{:item_numbers, numbers}]

        intro_gaps =
          for needle <- ["RA-6", "REQ-525..527", "#2862", "#2869", "#2870", "#2871"],
              not String.contains?(intro, needle),
              do: {:intro_missing, needle}

        item_gaps =
          for {number, claims} <- @items,
              {^number, item} <- [List.keyfind(items, number, 0) || {number, ""}],
              claim <- claims,
              not String.contains?(item, claim),
              do: {:item_missing_claim, number, claim}

        order ++ intro_gaps ++ item_gaps
    end
  end

  defp limitation_violations(text) do
    case section(text, @limitations_heading) do
      nil ->
        []

      body ->
        for needle <- [
              "upsert_by external_ref",
              "import_scope_check/6",
              "generic not-found",
              "create"
            ],
            not String.contains?(body, needle),
            do: {:limitation_missing, needle}
    end
  end

  # --- the real file -----------------------------------------------------------------------------

  describe "docs/roles.md" do
    setup do
      {:ok, text: read("docs/roles.md")}
    end

    test "T-E15 the AC 12 sentence is present exactly once and equals the code constant", %{
      text: text
    } do
      sentence = ShadowWindow.scope_sentence()

      assert occurrences(text, sentence) == 1
      # a one-line paragraph of its own, so a reflow cannot split it
      assert String.contains?(text, "\n\n" <> sentence <> "\n\n")
      # the constant is the verbatim AC 12 text, not a shortened form
      assert sentence ==
               "The shadow period proves only the denials of tenant-wide and admin-plane routes; denials on the data path (compiler predicate, 404 equivalence, writes, bulk and import, F1) are proven by the REQ-518 tests and the end-to-end suite, not by shadow."
    end

    test "no documentation rule is violated by the real document", %{text: text} do
      assert violations(text) == []
    end

    test "the production section has the eight items in order, each with its claim, after an introduction naming the follow-ups",
         %{text: text} do
      assert {intro, items} = production(text)

      assert Enum.map(items, &elem(&1, 0)) == Enum.to_list(1..8)

      for {number, claims} <- @items, claim <- claims do
        {^number, item} = List.keyfind(items, number, 0)
        assert String.contains?(item, claim), "item #{number} misses: #{claim}"
      end

      for needle <- [
            "pilot",
            "RA-6",
            "REQ-525..527",
            "#2862",
            "#2869",
            "#2870",
            "#2871",
            "0051 A8-A10"
          ] do
        assert String.contains?(intro, needle), "the introduction misses #{needle}"
      end
    end

    test "the platform-tenant sentence (SEC C-6) is item 8 and appears once", %{text: text} do
      assert occurrences(text, @platform_sentence) == 1
      {_intro, items} = production(text)
      assert {8, item} = List.keyfind(items, 8, 0)
      assert String.contains?(item, @platform_sentence)
    end

    test "the operator procedure carries the transition table, the reasons and the interactive-only rule",
         %{text: text} do
      body = section(text, @operator_heading)

      for row <- [
            "| `off` to `shadow` |",
            "| `shadow` to `on` |",
            "| `off` to `on` | 409 `shadow_required`",
            "| `on` to `shadow` | no precondition; a `reason` is mandatory |",
            "| `shadow` to `off`, `on` to `off` | no precondition; a `reason` is mandatory |"
          ] do
        assert String.contains?(body, row), "the table misses #{row}"
      end

      assert body =~ "interactive (OIDC) user who holds TENANT_ADMIN tenant-wide"

      assert body =~
               "API tokens, scoped admins, and a platform-tenant PLATFORM_ADMIN without TENANT_ADMIN get the uniform 403"

      assert body =~ "scope.enforcement_refused"
      assert body =~ "scope.enforcement_enabled"
      assert body =~ "scope.enforcement_disabled"
      assert body =~ "The flag route for ANOTHER tenant from the platform scope is not built."
    end

    test "every gate code, the thresholds and the integrity snapshot are documented", %{
      text: text
    } do
      body = section(text, @operator_heading)

      for code <- @gate_codes,
          do: assert(body =~ "`#{code}`", "the code #{code} is not documented")

      assert body =~ "`scope_shadow_min_days`"
      assert body =~ "default 7"
      assert body =~ "`scope_shadow_min_requests`"
      assert body =~ "default 100"
      assert body =~ "server configuration only"
      assert body =~ "`on_gate`"
      assert body =~ "/api/v1/tenant/scope-enforcement/integrity"
    end

    test "the gate codes in the docs are exactly the codes the gate can return", %{text: text} do
      type_source = File.read!("lib/letflow/scope_enforcement/on_gate.ex")

      for code <- @gate_codes,
          do: assert(type_source =~ ":#{code}", "the gate does not know #{code}")

      body = section(text, @operator_heading)

      documented =
        ~r/`([a-z_]+)`/
        |> Regex.scan(body, capture: :all_but_first)
        |> List.flatten()
        |> Enum.filter(&(&1 in @gate_codes))
        |> Enum.uniq()

      assert Enum.sort(documented) == Enum.sort(@gate_codes)
    end

    test "the known limitations name the scoped upsert refusal in import_scope_check/6", %{
      text: text
    } do
      body = section(text, @limitations_heading)

      assert body =~ "`upsert_by external_ref`"
      assert body =~ "`import_scope_check/6`"
      assert body =~ "generic not-found answer"
      assert body =~ "Only `create` mode imports are offered to a scoped caller."
      assert body =~ "tenant-wide callers are unchanged"
    end

    test "the code the docs point at exists: import_scope_check/6 is defined in the entities router" do
      source = File.read!("lib/letflow/routers/entities.ex")
      assert source =~ ~r/defp import_scope_check\(/
    end
  end

  # --- the rules are live --------------------------------------------------------------------------

  describe "the rules fire on seeded bad documents" do
    setup do
      {:ok, good: read("docs/roles.md")}
    end

    test "a paraphrased or missing sentence, and a duplicated one", %{good: good} do
      sentence = ShadowWindow.scope_sentence()

      assert :scope_sentence_not_exactly_once in violations(
               String.replace(good, sentence, "Shadow proves a lot.")
             )

      assert :scope_sentence_not_exactly_once in violations(good <> "\n" <> sentence <> "\n")

      assert :scope_sentence_not_exactly_once in violations(
               String.replace(good, "denials of tenant-wide", "denials of all")
             )
    end

    test "a missing item, a swapped order and a missing claim", %{good: good} do
      assert Enum.any?(
               violations(String.replace(good, "\n8. A platform tenant", "\nA platform tenant")),
               &match?({:item_numbers, _}, &1)
             )

      assert {:item_missing_claim, 6, "Do not scope the CANDIDATE binding"} in violations(
               String.replace(good, "Do not scope the CANDIDATE binding", "Scope what you like")
             )

      assert {:item_missing_claim, 7, "Tokens cannot"} in violations(
               String.replace(good, "Tokens cannot.", "Tokens can.")
             )
    end

    test "an introduction that forgets a follow-up", %{good: good} do
      assert {:intro_missing, "#2870"} in violations(String.replace(good, "#2870", "#0000"))

      assert {:intro_missing, "REQ-525..527"} in violations(
               String.replace(good, "REQ-525..527", "RA-6")
             )
    end

    test "missing sections", %{good: good} do
      assert :production_section_missing in violations(
               String.replace(good, @production_heading, "## Something else")
             )

      assert :operator_section_missing in violations(
               String.replace(good, @operator_heading, "## Other")
             )

      assert :limitations_section_missing in violations(
               String.replace(good, @limitations_heading, "## Other")
             )
    end

    test "a limitation section without the scoped upsert refusal", %{good: good} do
      assert {:limitation_missing, "import_scope_check/6"} in violations(
               String.replace(good, "import_scope_check/6", "the router")
             )
    end
  end
end
