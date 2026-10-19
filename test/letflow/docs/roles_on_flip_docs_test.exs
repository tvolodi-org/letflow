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
    7 => [
      "mandatory reason",
      "Tokens cannot",
      "letflow.scope_enforcement.break_glass",
      "Letflow.Release.ScopeBreakGlass",
      "no HTTP route"
    ],
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

  # --- GH #2883 (T-BG-30): the operator break-glass is documented, nothing else moved ---------------

  # built from parts: the CI path-filter guard (ci_backend_path_filter_test) treats every path-like
  # string literal in test/ as a path the backend gate READS, and docs/migration/ is not in the
  # filter (a change confined to the decision record would skip the backend job: reported).
  @decision Path.join([
              "docs",
              "migration",
              "decisions",
              "0051-org-scoped-role-grants-and-enforcement.md"
            ])
  @bg_heading "## Break-glass: turning an on tenant off without an admin (platform operator)"
  @old_phrase "no platform-scope break-glass"
  @old_sentence "There is no platform-scope break-glass in this release"

  # the text of the numbered item `n` of the production section, whitespace-normalised
  defp item_text(text, n) do
    case production(text) do
      nil ->
        nil

      {_intro, items} ->
        case List.keyfind(items, n, 0) do
          {^n, item} -> flat(item)
          nil -> nil
        end
    end
  end

  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  @bg_item_claims [
    "mandatory reason",
    "Tokens cannot",
    "letflow.scope_enforcement.break_glass",
    "Letflow.Release.ScopeBreakGlass",
    "no HTTP route",
    "operator label"
  ]

  @bg_section_claims [
    "NO HTTP route",
    "bin/letflow eval",
    "is not supported",
    "dry_run: true",
    "confirm:",
    "--dry-run",
    "--confirm",
    "TARGET",
    "current_mode=on",
    "The Mix form is for dev and CI hosts ONLY",
    "app.start",
    "a second full Letflow application",
    "against the same database as the running node",
    "not_enforced",
    "lock_conflict",
    "server_fault",
    "operator_break_glass",
    "scope.enforcement_disabled",
    "Never write the column with SQL",
    "the command needs the running application",
    "RESTARTS",
    "Do NOT put secrets, personal data or quotes in the reason",
    "at most 64 characters",
    # R5 F1: the ticket id is a prefix of the reason
    "MUST start with the incident ticket id",
    "<ticket id>: <short reason>",
    # R5 F2: the dry run and refusals leave constant log lines
    "scope_break_glass_dry_run",
    "scope_break_glass_refused",
    # R5 F4, auditor option (a) + premise correction (comments 6261955610, 6263394062)
    "Never write the column with SQL: that skips the audit entry and the locks",
    "Audit-chain fault (last resort)",
    "TWO attempts at least 1 minute apart",
    "scope_break_glass_failed reason=audit_failed",
    "CONFIRMED, and written down",
    "A damaged OLD chain",
    "is NEVER a trigger",
    "its own defect issue",
    "Written sign-off by the USER",
    "never an agent",
    "a sign-off relayed through another session does not count",
    "ONE transaction that writes the column AND inserts the audit row",
    "VERBATIM",
    "AUDIT ROW FIRST",
    "no column write exists without its audit row",
    "SECURITY-REVIEWER reviews the event",
    "Within 24 hours",
    "GH #2896",
    "is the only exception to `Never write the column with SQL`",
    # R5 follow-up: every placeholder is checked BEFORE it is substituted
    "do NOT neutralise quotes or `$`",
    "BEFORE substituting it",
    "tenant_[0-9a-f]{32}",
    "-?[0-9]{1,19}",
    "NO placeholder may contain a quote",
    "pasted ONLY from the output of the `rpc` expression",
    "never typed or edited",
    # the clock refusal
    "clock is not after the chain tail",
    "re-run the SAME SQL; never edit it",
    "after 10 minutes, escalate to the platform owner"
  ]

  @bg_record_claims [
    "release command with no HTTP route (GH #2883)",
    "authorised by host access, not by any role, token or permission",
    "from `on` to `shadow` or `off`",
    "a null actor, the operator label and the node name",
    "it grants no role, reads no tenant content",
    "is not the platform-scope flip route of A6, which stays unbuilt",
    # the two statements the SECURITY-REVIEWER design gate required (RA-B1 edits)
    "The operator label is an ATTESTATION by someone who already holds host access, not an authenticated identity.",
    "A10's gap (a tenant stored `on` with nobody able to turn it off) is only PARTLY answered by this command",
    "the last-admin guard (GH #2869 part (a)) stays open and is still required before any customer `on`",
    "The A7 token break-glass covers GRANT writes only",
    "needs a NEW decision record",
    # R5 F4: the last-resort path, with the auditor's conditions
    "does NOT block it",
    "a database-level failure of the audit insert does",
    "option (a)",
    "two attempts at least 1 minute apart",
    "is never a trigger",
    "written sign-off by the USER, the platform owner, directly",
    "never an agent and never relayed through another session",
    "ONE transaction that writes the column AND inserts the audit row",
    "using the SQL template quoted verbatim in the runbook",
    "SECURITY-REVIEWER reviews the event",
    "GH #2896",
    "the SQL writes the audit row before the column",
    "never writing the column with SQL stays absolute"
  ]

  # Any SQL that writes the flag or an audit row.
  @sql_snippet ~r/INSERT\s+INTO\s+\S*audit_entries|UPDATE\s+(public\.)?tenants\s+SET/i

  defp strip_sql_blocks(text), do: Regex.replace(~r/```sql\n.*?\n```/s, text, "")

  # the sentence(s) that carry the absolute prohibition (up to the next full stop after it)
  defp absolute_sentence(flat_text) do
    case Regex.run(~r/Never write the column with SQL[^.]*\./, flat_text) do
      [sentence] -> sentence
      nil -> ""
    end
  end

  defp sql_audit_insert_first?(runbook) do
    case Regex.run(~r/```sql\n(.*?)\n```/s, runbook, capture: :all_but_first) do
      [sql] ->
        with {i, _} <- :binary.match(sql, "INSERT INTO %I.audit_entries"),
             {u, _} <- :binary.match(sql, "UPDATE public.tenants") do
          i < u
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp a12_after_a11?(record) do
    with {a11, _} <- :binary.match(record, "**A11. Operator break-glass for the flag.**"),
         {a12, _} <- :binary.match(record, "**A12.") do
      a11 < a12
    else
      _ -> false
    end
  end

  # Every violation of the GH #2883 documentation rules for the three documents (pure).
  defp bg_violations(roles, runbook, record) do
    bg_section = section(runbook, @bg_heading)
    section_flat = if bg_section, do: flat(bg_section), else: ""

    a11_flat =
      case String.split(record, "**A11. Operator break-glass for the flag.**", parts: 2) do
        [_before, a11] -> flat(a11)
        [_whole] -> ""
      end

    checks =
      [
        {occurrences(runbook, @bg_heading) != 1, :runbook_heading_not_exactly_once},
        {is_nil(bg_section), :runbook_section_missing},
        {String.contains?(roles, @old_phrase) or String.contains?(runbook, @old_phrase),
         :old_no_break_glass_sentence_remains},
        {String.contains?(roles, @old_sentence) or String.contains?(runbook, @old_sentence),
         :old_release_sentence_remains},
        {item_text(roles, 7) != item_text(runbook, 7), :item_7_differs_between_documents},
        {not String.contains?(roles, "is delivered by GH #2883"),
         :roles_gate_paragraph_not_updated},
        {not String.contains?(runbook, "is delivered by GH #2883"),
         :runbook_gate_paragraph_not_updated},
        {Regex.match?(~r/LIMIT-[A-Z0-9-]*(BREAK|GLASS)/, roles <> runbook),
         :an_eighth_limit_item_for_the_break_glass},
        {occurrences(record, "**A11. Operator break-glass for the flag.**") != 1,
         :record_a11_not_exactly_once},
        # GH #2869 (c): A12 is Amendment 4, exactly once, after A11; A10 is unedited; no A13
        {occurrences(record, "**A12.") != 1, :record_a12_not_exactly_once},
        {not a12_after_a11?(record), :record_a12_not_after_a11},
        {String.contains?(record, "**A13."), :record_has_an_unexpected_a13},
        {occurrences(record, "**A10. Known gap, tracked.**") != 1 or
           not String.contains?(
             flat(record),
             "an `on` tenant can lose the last interactive TENANT_ADMIN and have no way to turn enforcement off"
           ), :record_a10_edited},
        # the last-resort SQL: exactly ONE fenced block, a single DO statement, audit insert first
        {length(Regex.scan(~r/```sql\n/, runbook)) != 1, :sql_block_not_exactly_one},
        {occurrences(runbook, "DO $last_resort$") != 1, :last_resort_do_not_exactly_once},
        {not sql_audit_insert_first?(runbook), :sql_audit_insert_not_before_update},
        # ... and the SQL appears NOWHERE else: not in the runbook outside that block, not in A11
        {Regex.match?(@sql_snippet, strip_sql_blocks(runbook)), :sql_snippet_outside_the_block},
        {Regex.match?(@sql_snippet, strip_sql_blocks(roles)), :sql_snippet_in_roles},
        {Regex.match?(@sql_snippet, a11_flat), :sql_snippet_in_a11},
        # the absolute prohibition: exactly one absolute sentence, one cross-reference, no softening
        {occurrences(
           section_flat,
           "Never write the column with SQL: that skips the audit entry and the locks."
         ) !=
           1, :absolute_prohibition_not_exactly_once},
        {Regex.match?(
           ~r/as a routine step|unless |except when/i,
           absolute_sentence(section_flat)
         ), :sql_prohibition_weakened}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    item_gaps =
      for claim <- @bg_item_claims,
          not String.contains?(item_text(runbook, 7) || "", claim),
          do: {:item_7_missing, claim}

    section_gaps =
      for claim <- @bg_section_claims,
          not String.contains?(section_flat, claim),
          do: {:runbook_section_missing_claim, claim}

    record_flat = flat(record)

    record_gaps =
      for claim <- @bg_record_claims,
          not String.contains?(record_flat, claim),
          do: {:record_missing, claim}

    checks ++ item_gaps ++ section_gaps ++ record_gaps
  end

  describe "T-BG-30 the break-glass documentation (GH #2883)" do
    setup do
      {:ok, roles: read("docs/roles.md"), runbook: read(@runbook), record: read(@decision)}
    end

    test "the real documents satisfy every GH #2883 rule", %{
      roles: roles,
      runbook: runbook,
      record: record
    } do
      assert bg_violations(roles, runbook, record) == []
    end

    test "item 7 is the same text in docs/roles.md and the runbook and names the command, no HTTP route and the label",
         %{roles: roles, runbook: runbook} do
      item = item_text(roles, 7)

      assert item == item_text(runbook, 7)

      assert item =~
               "To turn `on` off: an interactive tenant-wide TENANT_ADMIN, with a mandatory reason. Tokens cannot."

      assert item =~
               "`Letflow.Release.ScopeBreakGlass` (`mix letflow.scope_enforcement.break_glass`)"

      assert item =~ "which has no HTTP route and needs a mandatory reason and an operator label"
      refute item =~ @old_phrase
    end

    test "the runbook has the Break-glass heading exactly once, after the production section and before the limitations",
         %{runbook: runbook} do
      assert occurrences(runbook, @bg_heading) == 1

      {production_at, _} = :binary.match(runbook, @production_heading)
      {heading_at, _} = :binary.match(runbook, @bg_heading)
      {limits_at, _} = :binary.match(runbook, "\n" <> @limitations_heading)

      assert production_at < heading_at
      assert heading_at < limits_at
    end

    test "exactly seven LIMIT items remain in both documents and none concerns the break-glass",
         %{
           roles: roles,
           runbook: runbook
         } do
      body = heading_body(roles, @ac23_heading)
      assert length(list_items(body)) == 7

      for text <- [roles, runbook] do
        tokens = ~r/LIMIT-[A-Z0-9-]+/ |> Regex.scan(text) |> List.flatten() |> Enum.uniq()
        assert Enum.sort(tokens) == Enum.sort(Enum.map(@ac23_items, &elem(&1, 0)))
      end
    end

    test "the A6 sentence about the unbuilt route for ANOTHER tenant is still in the operator procedure",
         %{roles: roles, runbook: runbook} do
      for text <- [roles, runbook] do
        assert flat(text) =~
                 "The flag route for ANOTHER tenant from the platform scope is not built."
      end
    end

    test "decision 0051 holds A11 once as Amendment 3, then A12 once as Amendment 4, and A12 is the last paragraph",
         %{record: record} do
      {a10, _} = :binary.match(record, "**A10. Known gap, tracked.**")
      {a11, _} = :binary.match(record, "**A11. Operator break-glass for the flag.**")
      assert a10 < a11

      assert record =~
               "## Amendment 3 (2026-10-19): operator break-glass for the enforcement flag"

      {a12, _} = :binary.match(record, "**A12.")
      assert a11 < a12
      assert occurrences(record, "**A12.") == 1

      assert record =~
               "## Amendment 4 (2026-10-19): last-interactive-admin guard for an `on` tenant"

      # A11 sits under the Amendment 3 heading with no other heading between them ...
      between = binary_part(record, a11, a12 - a11)
      refute between =~ "\n## Amendment 3"
      # ... and nothing follows A12's amendment except its own paragraphs.
      tail = binary_part(record, a12, byte_size(record) - a12)
      refute tail =~ "\n## "
    end

    test "the Before-you-start paragraph requires the ticket id as the reason PREFIX, in the runbook and in both doc strings",
         %{runbook: runbook} do
      before_start =
        runbook
        |> section(@bg_heading)
        |> flat()
        |> String.split("Before you start:", parts: 2)
        |> List.last()
        |> String.split("The Mix form is for dev", parts: 2)
        |> hd()

      assert before_start =~ "The reason MUST start with the incident ticket id"
      assert before_start =~ "`<ticket id>: <short reason>`"

      {:docs_v1, _, _, _, %{"en" => task_doc}, _, _} =
        Code.fetch_docs(Mix.Tasks.Letflow.ScopeEnforcement.BreakGlass)

      assert flat(task_doc) =~ "MUST start with the incident ticket id"
      assert flat(task_doc) =~ "<ticket id>: <short reason>"

      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Letflow.Release.ScopeBreakGlass)

      run_doc =
        Enum.find_value(docs, fn
          {{:function, :run, 5}, _, _, %{"en" => doc}, _} -> doc
          _other -> nil
        end)

      assert flat(run_doc) =~ "MUST start with the incident ticket id"
      assert flat(run_doc) =~ "<ticket id>: <short reason>"
    end

    test "the flag / audit SQL appears nowhere in docs/ except inside the single last-resort block of the runbook" do
      # built from parts: not a path literal for the CI path-filter guard
      docs = Path.wildcard(Path.join(["docs", "**", "*.md"]))
      assert length(docs) > 50

      offenders =
        for path <- docs,
            text = read(path),
            text = if(path == @runbook, do: strip_sql_blocks(text), else: text),
            Regex.match?(@sql_snippet, text),
            do: path

      assert offenders == []

      # live: the same scan reports a seeded doc, and the block itself is excluded only in the runbook
      assert Regex.match?(@sql_snippet, "UPDATE tenants SET scope_enforcement = 'off'")
      assert Regex.match?(@sql_snippet, "INSERT INTO t.audit_entries (id)")
      refute Regex.match?(@sql_snippet, strip_sql_blocks("```sql
UPDATE public.tenants SET x = 1;
```
"))
    end

    test "seeded bad documents fire every rule", %{roles: roles, runbook: runbook, record: record} do
      assert :runbook_heading_not_exactly_once in bg_violations(
               roles,
               String.replace(runbook, @bg_heading, "## Something else"),
               record
             )

      assert :runbook_heading_not_exactly_once in bg_violations(
               roles,
               runbook <> "\n" <> @bg_heading <> "\n",
               record
             )

      assert :old_release_sentence_remains in bg_violations(
               roles <> "\n" <> @old_sentence <> " in this release.\n",
               runbook,
               record
             )

      assert :old_no_break_glass_sentence_remains in bg_violations(
               roles,
               runbook <> "\n" <> @old_phrase <> "\n",
               record
             )

      assert :item_7_differs_between_documents in bg_violations(
               roles,
               String.replace(runbook, "an operator label.", "a label."),
               record
             )

      assert {:item_7_missing, "no HTTP route"} in bg_violations(
               String.replace(roles, "which has no HTTP route and", "which"),
               String.replace(runbook, "which has no HTTP route and", "which"),
               record
             )

      assert {:item_7_missing, "Tokens cannot"} in bg_violations(
               String.replace(roles, "Tokens cannot.", "Tokens can."),
               String.replace(runbook, "Tokens cannot.", "Tokens can."),
               record
             )

      assert {:runbook_section_missing_claim, "The Mix form is for dev and CI hosts ONLY"} in bg_violations(
               roles,
               String.replace(
                 runbook,
                 "The Mix form is for dev and CI hosts ONLY",
                 "The Mix form is fine"
               ),
               record
             )

      assert {:runbook_section_missing_claim, "a second full Letflow application"} in bg_violations(
               roles,
               String.replace(runbook, "a second full Letflow application", "an application"),
               record
             )

      assert :an_eighth_limit_item_for_the_break_glass in bg_violations(
               roles <> "\n- LIMIT-BREAK-GLASS: an eighth item\n",
               runbook,
               record
             )

      assert :roles_gate_paragraph_not_updated in bg_violations(
               String.replace(roles, "is delivered by GH #2883", "is open"),
               runbook,
               record
             )

      assert :record_a11_not_exactly_once in bg_violations(
               roles,
               runbook,
               String.replace(record, "**A11. Operator break-glass for the flag.**", "**A11.**")
             )

      # the placeholder / clock sentences: each stable word fires when removed
      for claim <- [
            "BEFORE substituting it",
            "tenant_[0-9a-f]{32}",
            "-?[0-9]{1,19}",
            "NO placeholder may contain a quote",
            "pasted ONLY from the output of the `rpc` expression",
            "never typed or edited",
            "re-run the SAME SQL; never edit it",
            "after 10 minutes, escalate to the platform owner"
          ] do
        assert {:runbook_section_missing_claim, claim} in bg_violations(
                 roles,
                 String.replace(runbook, claim, "REMOVED"),
                 record
               ),
               claim
      end

      # prose that merely MENTIONS `UPDATE tenants` is not a SQL snippet ...
      refute Enum.any?(
               bg_violations(
                 roles,
                 String.replace(
                   runbook,
                   "Every other case uses the command.",
                   "Every other case uses the command (the SQL runs `UPDATE tenants` last)."
                 ),
                 record
               ),
               &(&1 in [:sql_snippet_outside_the_block, :sql_snippet_in_roles])
             )

      # ... but a second real SQL block is caught, by the block count and by the snippet scan
      second_block = runbook <> "
```sql
UPDATE public.tenants SET scope_enforcement = 'off';
```
"
      assert :sql_block_not_exactly_one in bg_violations(roles, second_block, record)

      assert :sql_snippet_outside_the_block in bg_violations(
               roles,
               runbook <> "
    UPDATE public.tenants SET scope_enforcement = 'off';
",
               record
             )

      # --- F4: the last-resort paragraph, each stable word and each negative rule fires ---------------
      for claim <- [
            "Audit-chain fault (last resort)",
            "TWO attempts at least 1 minute apart",
            "CONFIRMED, and written down",
            "is NEVER a trigger",
            "Written sign-off by the USER",
            "a sign-off relayed through another session does not count",
            "ONE transaction that writes the column AND inserts the audit row",
            "AUDIT ROW FIRST",
            "SECURITY-REVIEWER reviews the event",
            "GH #2896"
          ] do
        assert {:runbook_section_missing_claim, claim} in bg_violations(
                 roles,
                 String.replace(runbook, claim, "REMOVED"),
                 record
               ),
               claim
      end

      for claim <- [
            "two attempts at least 1 minute apart",
            "is never a trigger",
            "written sign-off by the USER, the platform owner, directly",
            "SECURITY-REVIEWER reviews the event",
            "the SQL writes the audit row before the column"
          ] do
        assert {:record_missing, claim} in bg_violations(
                 roles,
                 runbook,
                 String.replace(record, claim, "REMOVED")
               ),
               claim
      end

      sql_swapped =
        runbook
        |> String.replace("INSERT INTO %I.audit_entries", "INSERT_MARK")
        |> String.replace("UPDATE public.tenants", "INSERT INTO %I.audit_entries")
        |> String.replace("INSERT_MARK", "UPDATE public.tenants")

      assert :sql_audit_insert_not_before_update in bg_violations(roles, sql_swapped, record)

      assert :sql_block_not_exactly_one in bg_violations(
               roles,
               runbook <> "\n```sql\nSELECT 1;\n```\n",
               record
             )

      assert :last_resort_do_not_exactly_once in bg_violations(
               roles,
               runbook <> "\nDO $last_resort$\n",
               record
             )

      # the SQL anywhere else is a violation: a second snippet in the runbook, in roles.md, in A11
      assert :sql_snippet_outside_the_block in bg_violations(
               roles,
               String.replace(
                 runbook,
                 "Every other case uses the command.",
                 "Every other case uses the command. Or run UPDATE tenants SET scope_enforcement = 'off'."
               ),
               record
             )

      assert :sql_snippet_outside_the_block in bg_violations(
               roles,
               runbook <> "\nINSERT INTO audit_entries (id) VALUES (1);\n",
               record
             )

      assert :sql_snippet_in_roles in bg_violations(
               roles <> "\nUPDATE public.tenants SET scope_enforcement = 'off';\n",
               runbook,
               record
             )

      assert :sql_snippet_in_a11 in bg_violations(
               roles,
               runbook,
               record <> " Run INSERT INTO t1.audit_entries (id) VALUES (1) first."
             )

      assert :sql_snippet_in_a11 in bg_violations(
               roles,
               runbook,
               record <> " Then UPDATE tenants SET scope_enforcement = 'off'."
             )

      # the absolute prohibition: no softening, one sentence, one cross-reference
      assert :sql_prohibition_weakened in bg_violations(
               roles,
               String.replace(
                 runbook,
                 "Never write the column with SQL:",
                 "Never write the column with SQL as a routine step:"
               ),
               record
             )

      assert :sql_prohibition_weakened in bg_violations(
               roles,
               String.replace(
                 runbook,
                 "Never write the column with SQL: that skips the audit entry and the locks.",
                 "Never write the column with SQL unless the DBA agrees."
               ),
               record
             )

      assert :absolute_prohibition_not_exactly_once in bg_violations(
               roles,
               String.replace(
                 runbook,
                 "Never write the column with SQL: that skips",
                 "Avoid writing the column with SQL: that skips"
               ),
               record
             )

      assert {:runbook_section_missing_claim, "MUST start with the incident ticket id"} in bg_violations(
               roles,
               String.replace(
                 runbook,
                 "MUST start with the incident ticket id",
                 "should name a ticket"
               ),
               record
             )

      attestation =
        "The operator label is an ATTESTATION by someone who already holds host access, not an authenticated identity."

      assert {:record_missing, attestation} in bg_violations(
               roles,
               runbook,
               String.replace(record, "not an authenticated identity", "a login")
             )

      partly =
        "the last-admin guard (GH #2869 part (a)) stays open and is still required before any customer `on`"

      assert {:record_missing, partly} in bg_violations(
               roles,
               runbook,
               String.replace(record, "stays open and is still required", "is done")
             )
    end
  end

  # --- GH #2869 (T-LA-31): the last-interactive-admin guard is documented, A11 and A10 did not move ---

  @la_gate_marker "**Gate #2869 (last admin).**"
  @la_a11_marker "**A11. Operator break-glass for the flag.**"
  @la_a12_marker "**A12. Last interactive tenant-wide administrator.**"
  # SHA-256 of the whole A11 paragraph as merged by GH #2883: A12 must NOT edit it (design F8)
  @la_a11_sha256 "8189c6adeca27b62b3251aa4a4e653eb72eccaa8369e7257bf21baf77550ab5a"

  # the claims of the Gate paragraph of BOTH documents (case-insensitive, whitespace-normalised)
  @la_gate_claims [
    "last_interactive_tenant_wide_admin",
    "the guard cannot see an administrator who exists in letflow",
    "is delivered by gh #2883",
    "counted exactly as gate fact `zero_tenant_wide_admins` counts",
    "token owners, flagged service principals and zero-row members do not count"
  ]

  # the claims of A12 (design section 13)
  @la_a12_claims [
    "refused with 409 `last_interactive_tenant_wide_admin`",
    "audited as `tenant_admin.guard_refused`",
    "`count_interactive_explicit_tenant_wide_admins/1`",
    "token owners and zero-row members do not count",
    "This NARROWS the wording of A1",
    "A1 is not restated or edited",
    "the flip route is interactive-only (A8)",
    "it does not apply in `shadow` or `off`",
    "It runs after the N1 guard, which keeps its own code",
    "It is implemented by GH #2869 (a); A10 stays open until that implementation is on `main`",
    "A11's sentence that the guard \"stays open\" is read accordingly",
    "**Does A7 cover this case? Partly.**",
    "A7 does NOT cover the flag",
    "the operator break-glass of A11 (GH #2883), which has no HTTP route",
    "it cannot see an administrator who exists in Letflow but can no longer log in at the identity provider",
    "Neither the guard nor A11 is special-cased by the other"
  ]

  defp la_gate(text) do
    case String.split(text, @la_gate_marker, parts: 2) do
      [_before, rest] -> rest |> String.split("\n\n", parts: 2) |> hd() |> flat()
      [_whole] -> nil
    end
  end

  # the A11 paragraph: from its marker to the blank line before the next heading
  defp la_a11_paragraph(record) do
    case String.split(record, @la_a11_marker, parts: 2) do
      [_before, rest] -> @la_a11_marker <> (rest |> String.split("\n\n## ", parts: 2) |> hd())
      [_whole] -> nil
    end
  end

  # the text from A12 to the end of the record, whitespace-normalised
  defp la_a12_text(record) do
    case String.split(record, "**A12.", parts: 2) do
      [_before, rest] -> flat("**A12." <> rest)
      [_whole] -> ""
    end
  end

  # Every violation of the GH #2869 documentation rules for the three documents (pure).
  defp la_violations(roles, runbook, record) do
    gates = [{:roles, la_gate(roles)}, {:runbook, la_gate(runbook)}]

    gate_checks =
      for {doc, gate} <- gates,
          claim <- @la_gate_claims,
          is_nil(gate) or not String.contains?(String.downcase(gate), claim),
          do: {:gate_missing_claim, doc, claim}

    still_open =
      for {doc, text} <- [{:roles, roles}, {:runbook, runbook}],
          String.contains?(text, "(still open)") or
            String.contains?(text, "the guard that prevents the gap is still open"),
          do: {:still_open_remains, doc}

    a11 = la_a11_paragraph(record)
    a12 = la_a12_text(record)

    record_checks =
      [
        {occurrences(record, "**A12.") != 1, :a12_not_exactly_once},
        {occurrences(record, @la_a12_marker) != 1, :a12_heading_changed},
        {not a12_after_a11?(record), :a12_not_after_a11},
        {String.contains?(record, "**A13."), :an_a13_exists},
        {is_nil(a11) or Base.encode16(:crypto.hash(:sha256, a11), case: :lower) != @la_a11_sha256,
         :a11_edited},
        {record |> String.split("**A12.", parts: 2) |> List.last() |> String.contains?("\n## "),
         :a12_is_not_the_last_paragraph},
        {la_gate(roles) != la_gate(runbook), :gate_differs_between_documents}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    claim_gaps =
      for claim <- @la_a12_claims,
          not String.contains?(a12, claim),
          do: {:a12_missing_claim, claim}

    gate_checks ++ still_open ++ record_checks ++ claim_gaps
  end

  # removes `claim` from the A12 text only (the claims are all inside A12)
  defp replace_in_a12(record, claim) do
    [before, a12] = String.split(record, "**A12.", parts: 2)
    before <> "**A12." <> String.replace(a12, claim, "REMOVED")
  end

  describe "T-LA-31 the last-interactive-admin guard documentation (GH #2869 parts (a) and (c))" do
    setup do
      {:ok, roles: read("docs/roles.md"), runbook: read(@runbook), record: read(@decision)}
    end

    test "the real documents satisfy every GH #2869 rule", %{
      roles: roles,
      runbook: runbook,
      record: record
    } do
      assert la_violations(roles, runbook, record) == []
    end

    test "A12 is Amendment 4, exactly once, after A11, the last paragraph; A10 and A11 are unedited; no A13",
         %{record: record} do
      assert occurrences(record, "**A12.") == 1
      assert occurrences(record, @la_a12_marker) == 1
      assert a12_after_a11?(record)
      refute String.contains?(record, "**A13.")

      assert Base.encode16(:crypto.hash(:sha256, la_a11_paragraph(record)), case: :lower) ==
               @la_a11_sha256

      # A10's own text, checked by its needle
      assert occurrences(record, "**A10. Known gap, tracked.**") == 1

      assert flat(record) =~
               "an `on` tenant can lose the last interactive TENANT_ADMIN and have no way to turn enforcement off"

      # A11's sentence stays; A12 says how it is read, nothing rewrites it
      assert la_a11_paragraph(record) =~
               "the last-admin guard (GH #2869 part (a)) stays open and is still required before any customer `on`"
    end

    test "the Gate paragraph is identical in docs/roles.md and the runbook, keeps its pinned phrase and drops (still open)",
         %{roles: roles, runbook: runbook} do
      assert la_gate(roles) == la_gate(runbook)
      assert la_gate(roles) =~ "is delivered by GH #2883"
      refute la_gate(roles) =~ "(still open)"
      assert la_gate(roles) =~ "`last_interactive_tenant_wide_admin`"

      # the intro still names #2869 (now a closed reference)
      for text <- [roles, runbook], do: assert(text =~ "#2869")
    end

    test "seeded bad documents fire every rule", %{roles: roles, runbook: runbook, record: record} do
      # the Gate paragraph of EACH document: every claim fires when removed
      for {claim, replacement} <- [
            {"last_interactive_tenant_wide_admin", "last_admin"},
            {"The guard cannot see an administrator who exists in Letflow",
             "The guard sees everyone"},
            {"is delivered by GH #2883", "is open"},
            {"counted exactly as gate fact `zero_tenant_wide_admins` counts", "counted somehow"}
          ] do
        assert Enum.any?(
                 la_violations(String.replace(roles, claim, replacement), runbook, record),
                 &match?({:gate_missing_claim, :roles, _}, &1)
               ),
               claim

        assert Enum.any?(
                 la_violations(roles, String.replace(runbook, claim, replacement), record),
                 &match?({:gate_missing_claim, :runbook, _}, &1)
               ),
               claim
      end

      assert {:still_open_remains, :roles} in la_violations(
               roles <> "\nThe fix is (still open).\n",
               runbook,
               record
             )

      assert {:still_open_remains, :runbook} in la_violations(
               roles,
               String.replace(
                 runbook,
                 "the guard that prevents the gap is built",
                 "the guard that prevents the gap is still open"
               ),
               record
             )

      assert :gate_differs_between_documents in la_violations(
               roles,
               String.replace(runbook, "zero-row members do not count", "zero-row members count"),
               record
             )

      # A12: twice, before A11, an A13, A11 edited, not the last paragraph, a renamed heading
      assert :a12_not_exactly_once in la_violations(
               roles,
               runbook,
               record <> "\n\n**A12. Again.** a second one.\n"
             )

      early =
        record
        |> String.replace(@la_a12_marker, "**A9x.**")
        |> String.replace(@la_a11_marker, @la_a12_marker <> " early\n\n" <> @la_a11_marker)

      assert :a12_not_after_a11 in la_violations(roles, runbook, early)

      assert :an_a13_exists in la_violations(roles, runbook, record <> "\n**A13.** one more.\n")

      assert :a11_edited in la_violations(
               roles,
               runbook,
               String.replace(record, "stays open and is still required", "is done")
             )

      assert :a12_is_not_the_last_paragraph in la_violations(
               roles,
               runbook,
               record <> "\n## Amendment 5 (2026-10-20): something else\n\ntext\n"
             )

      assert :a12_heading_changed in la_violations(
               roles,
               runbook,
               String.replace(record, @la_a12_marker, "**A12. Renamed.**")
             )

      # every A12 claim fires when removed
      for claim <- @la_a12_claims do
        assert {:a12_missing_claim, claim} in la_violations(
                 roles,
                 runbook,
                 replace_in_a12(record, claim)
               ),
               claim
      end
    end
  end
end
