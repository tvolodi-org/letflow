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
  @limitations_heading "## Known limitations of an enforced tenant"

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

  # --- AC 23: the single collecting section --------------------------------------------------------

  @runbook "docs/runbooks/scope-enforcement-on.md"
  @ac23_heading "Known limitations of an enforced tenant"
  @ac23_items [
    {"LIMIT-IDP-SYNC-WHOLE-GROUP", ["grant.sync_suppressed", "binding.pending_scope"]},
    {"LIMIT-POST-ROLES-409", ["scope_required"]},
    {"LIMIT-IMPORT-UPSERT-404", ["upsert_by", "external_ref", "404"]},
    {"LIMIT-ON-FLAG", ["shadow", "2f-b"]},
    {"LIMIT-MULTI-NODE-SHADOW-FLUSH", ["ShadowWindow", "flush"]},
    {"LIMIT-IDP-SERVICE-ACCOUNT-ADMIN", ["TENANT_ADMIN", "service principal"]},
    {"LIMIT-EMERGENCY-RESHADOW", ["shadow window", "restart"]}
  ]

  # The lines under the heading `ac23_heading` (any level) until the next heading of the same or
  # higher level (fewer or equal `#`); nil when the heading is absent.
  defp heading_body(text, heading) do
    lines = String.split(text, "\n")

    case Enum.find_index(lines, &Regex.match?(~r/^\#{1,6} #{Regex.escape(heading)}\s*$/, &1)) do
      nil ->
        nil

      index ->
        [head | rest] = Enum.drop(lines, index)
        [hashes] = Regex.run(~r/^\#+/, head)
        level = String.length(hashes)

        rest
        |> Enum.take_while(fn line ->
          case Regex.run(~r/^(\#+) /, line) do
            [_all, h] -> String.length(h) > level
            nil -> true
          end
        end)
    end
  end

  # The item begins with the literal token, which is not the prefix of a longer token.
  defp begins_with_token?(line, token) do
    case line do
      "- " <> rest ->
        String.starts_with?(rest, token) and
          not Regex.match?(~r/^[A-Za-z0-9_-]/, String.replace_prefix(rest, token, ""))

      _other ->
        false
    end
  end

  defp list_items(lines), do: Enum.filter(lines, &String.starts_with?(&1, "- "))

  # Violations of AC 23 for the doc and the runbook texts (pure).
  defp ac23_violations(doc, runbook) do
    case heading_body(doc, @ac23_heading) do
      nil ->
        [:heading_missing]

      body ->
        items = list_items(body)

        count = if length(items) == 7, do: [], else: [{:item_count, length(items)}]

        per_token =
          for {token, needles} <- @ac23_items,
              violation <- token_violations(doc, runbook, items, token, needles),
              do: violation

        count ++ per_token
    end
  end

  defp token_violations(doc, runbook, items, token, needles) do
    begins = Enum.filter(items, &begins_with_token?(&1, token))
    item = List.first(begins) || ""

    checks = [
      {length(begins) != 1, {:item_missing_or_duplicated, token}},
      {occurrences(doc, token) != 1, {:token_not_once_in_doc, token}},
      {occurrences(runbook, token) != 1, {:token_not_once_in_runbook, token}}
    ]

    needle_checks =
      for needle <- needles,
          do: {not String.contains?(item, needle), {:item_lacks, token, needle}}

    (checks ++ needle_checks) |> Enum.filter(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
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

  describe "AC 23 the collecting section of the known limitations" do
    setup do
      {:ok, doc: read("docs/roles.md"), runbook: read(@runbook)}
    end

    test "the real documents satisfy AC 23", %{doc: doc, runbook: runbook} do
      assert ac23_violations(doc, runbook) == []
    end

    test "under the heading ONLY there are exactly seven list items, each starting with its token",
         %{doc: doc} do
      body = heading_body(doc, @ac23_heading)
      items = list_items(body)

      assert length(items) == 7

      assert Enum.map(items, fn "- " <> rest -> rest |> String.split(":") |> hd() end) ==
               Enum.map(@ac23_items, &elem(&1, 0))

      # the other limitation list of the file is a different section and holds no token
      for {token, _needles} <- @ac23_items do
        assert occurrences(doc, token) == 1
        assert occurrences(read(@runbook), token) == 1
      end
    end

    test "the runbook states the AC 24 sentence (no production tenant is set to on until the supervisor says so)",
         %{runbook: runbook} do
      flat = String.replace(runbook, ~r/\s+/, " ")

      assert flat =~ "No production tenant is set to `on` until the supervisor says so"

      assert flat =~
               "No `on` flip in any customer tenant, pilot included, until GH #2869 and GH #2883 are implemented."

      assert flat =~
               "no test, seed, migration or script of that requirement flips a production tenant"
    end

    test "seeded offenders fire: missing heading, missing / duplicated token, an eighth item, a missing or duplicated new token, a missing needle, a token missing from the runbook",
         %{doc: doc, runbook: runbook} do
      assert ac23_violations(String.replace(doc, "## " <> @ac23_heading, "## Other"), runbook) ==
               [:heading_missing]

      assert {:item_missing_or_duplicated, "LIMIT-ON-FLAG"} in ac23_violations(
               String.replace(doc, "- LIMIT-ON-FLAG:", "- LIMIT-ON-FLAGS:"),
               runbook
             )

      assert {:token_not_once_in_doc, "LIMIT-POST-ROLES-409"} in ac23_violations(
               doc <> "\nSee LIMIT-POST-ROLES-409 again.\n",
               runbook
             )

      eighth =
        String.replace(
          doc,
          "- LIMIT-EMERGENCY-RESHADOW:",
          "- LIMIT-EXTRA: an eighth item\n- LIMIT-EMERGENCY-RESHADOW:"
        )

      assert {:item_count, 8} in ac23_violations(eighth, runbook)

      for token <- [
            "LIMIT-MULTI-NODE-SHADOW-FLUSH",
            "LIMIT-IDP-SERVICE-ACCOUNT-ADMIN",
            "LIMIT-EMERGENCY-RESHADOW"
          ] do
        renamed = String.replace(doc, "- " <> token <> ":", "- LIMIT-RENAMED:")
        assert {:item_missing_or_duplicated, token} in ac23_violations(renamed, runbook)

        duplicated_in_doc = doc <> "\nSee " <> token <> ".\n"
        assert {:token_not_once_in_doc, token} in ac23_violations(duplicated_in_doc, runbook)

        duplicated_in_runbook = runbook <> "\n" <> token <> "\n"
        assert {:token_not_once_in_runbook, token} in ac23_violations(doc, duplicated_in_runbook)

        missing_in_runbook = String.replace(runbook, token, "LIMIT-X")
        assert {:token_not_once_in_runbook, token} in ac23_violations(doc, missing_in_runbook)
      end

      # an item moved under a LATER heading of the same level is not "under that heading"
      moved = String.replace(doc, "- LIMIT-ON-FLAG:", "## Elsewhere\n\n- LIMIT-ON-FLAG:")
      violations = ac23_violations(moved, runbook)
      assert {:item_count, 3} in violations
      assert {:item_missing_or_duplicated, "LIMIT-ON-FLAG"} in violations

      assert {:item_lacks, "LIMIT-POST-ROLES-409", "scope_required"} in ac23_violations(
               String.replace(doc, "409 `scope_required`", "409"),
               runbook
             )

      assert {:token_not_once_in_runbook, "LIMIT-IMPORT-UPSERT-404"} in ac23_violations(
               doc,
               String.replace(runbook, "LIMIT-IMPORT-UPSERT-404", "LIMIT-X")
             )

      assert {:token_not_once_in_runbook, "LIMIT-IDP-SYNC-WHOLE-GROUP"} in ac23_violations(
               doc,
               runbook <> "\nLIMIT-IDP-SYNC-WHOLE-GROUP\n"
             )
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
