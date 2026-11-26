defmodule Letflow.ProductionTenantOnboardingRunbookTest do
  @moduledoc """
  T-2220: `docs/runbooks/production-tenant-onboarding.md` keeps its module order, checked names, repo paths
  and step structure in step with the code. No database. R1 and R5 are shown to bite on an in-memory copy.

  T-2388 (owner decision D-164): step 20 sets the count four-eyes rule of the sss tenant OFF with the
  reason text the owner gave, names the audit entries and the readiness check that shows the value, and
  keeps the other rules a separate choice. The rules the runbook names are the shipped stock pack's own
  four-eyes steps, and the reason text is one the product's own reason rule accepts.
  """

  use ExUnit.Case, async: true

  alias Letflow.Audit.Reason
  alias Letflow.Modules.Catalog
  alias Letflow.Release.TenantOnboardingCheck

  @root Path.expand("../..", __DIR__)
  @runbook Path.join(@root, "docs/runbooks/production-tenant-onboarding.md")

  # The reason the owner gave for the count rule of Client 1 (D-164).
  @reason "Client 1, storekeeper counts from the phone, one administrator, owner decision D-164"

  defp text, do: File.read!(@runbook)

  defp module_line(src) do
    [line] = Regex.run(~r/^Default modules, in install order:.*$/m, src)
    Regex.scan(~r/`([a-z_]+)`/, line) |> Enum.map(&List.last/1)
  end

  defp order_valid?(ids) do
    ids
    |> Enum.with_index()
    |> Enum.all?(fn {id, i} ->
      {:ok, entry} = Catalog.fetch(id)
      Enum.all?(entry.manifest().depends_on, &(&1 in Enum.take(ids, i)))
    end)
  end

  defp steps(src) do
    parts = Regex.split(~r/^### Step /m, src)
    tl(parts) |> Enum.map(&("### Step " <> &1))
  end

  defp steps_ok?(src) do
    sections = steps(src)

    numbers = Enum.map(sections, fn s -> Regex.run(~r/^### Step (\d+)\./, s) |> List.last() end)

    numbers == Enum.map(0..23, &Integer.to_string/1) and
      Enum.all?(sections, fn s ->
        Enum.all?(
          ["**Who:**", "**Do:**", "**Check:**", "**Rollback:**"],
          &String.contains?(s, &1)
        )
      end)
  end

  defp who_line(section), do: Regex.run(~r/^\*\*Who:\*\*.*$/m, section) |> hd()

  defp step(src, n), do: Enum.at(steps(src), n)

  test "R1: the module line equals the check's default list and is a valid dependency order" do
    ids = module_line(text())
    assert ids == TenantOnboardingCheck.default_modules()
    assert order_valid?(ids)

    refute order_valid?(["stock", "org", "locations", "catalog_items", "codes"])
  end

  test "R2: the runbook names the checked document types, tables and the release call" do
    src = text()

    for name <- TenantOnboardingCheck.document_types() ++ TenantOnboardingCheck.tables(),
        do: assert(src =~ name)

    assert src =~ "Letflow.Release.tenant_onboarding_check"
    Code.ensure_loaded!(Letflow.Release)
    assert function_exported?(Letflow.Release, :tenant_onboarding_check, 2)
  end

  test "R3: every repo path the runbook cites exists" do
    paths =
      Regex.scan(~r/`((?:docs|priv|lib|scripts|test)\/[^`\s]+)`/, text())
      |> Enum.map(&List.last/1)
      |> Enum.map(&String.trim_trailing(&1, ":"))
      |> Enum.reject(&(String.contains?(&1, "<") or String.contains?(&1, "*")))

    assert paths != []
    for p <- paths, do: assert(File.exists?(Path.join(@root, p)), "missing: #{p}")
  end

  test "R4: no secret-shaped text" do
    src = text()
    refute src =~ ~r/lf_tok_[A-Za-z0-9]/
    refute src =~ ~r/password\s*[:=]\s*\S/i
    refute src =~ ~r/[A-Za-z0-9._%+-]+@(?!<)[A-Za-z0-9-]+\.[a-z]{2,}/
  end

  test "R5: steps 0..23 each have Who/Do/Check/Rollback and the infra-only steps say so" do
    src = text()
    assert steps_ok?(src)

    sections = steps(src)

    for n <- [0, 1, 2, 3, 8, 15, 22] do
      assert who_line(Enum.at(sections, n)) =~ "infra only", "step #{n}"
    end

    # bite: a copy with one Check line removed, and one with a step missing, fail
    refute steps_ok?(String.replace(src, "**Check:** 404, default realm", "404, default realm"))
    refute steps_ok?(String.replace(src, "### Step 13. Handover", "### Step 15. Handover"))
  end

  test "R6 (D-164): step 20 sets the count rule OFF with the reason, the audit entries and the check" do
    s20 = step(text(), 20)

    assert s20 =~ "D-164"
    assert s20 =~ "PUT /api/v1/approval-rules/stock_quick_count/approve"
    assert s20 =~ "{\"four_eyes\": false, \"reason\": \"" <> @reason <> "\"}"

    # the two audit entries the product writes for the switch and for each self-approval
    assert s20 =~ "approval_rule.changed"
    assert s20 =~ "self-approved, four-eyes off"

    # T-2411: the count posts at once with the switch OFF; an older pending count stays pending
    assert s20 =~
             "With the count switch OFF the storekeeper's count posts at once on the phone and on the web"

    assert s20 =~ "stays pending until an administrator approves"

    # the readiness check that shows the value, and the line to read
    assert s20 =~ "Letflow.Release.tenant_onboarding_check"

    assert s20 =~
             "INFO four-eyes on=1 off=1 steps=stock_opening.approve=on,stock_quick_count.approve=off"

    # the reason is required: the runbook says so, and the product's rule says so
    assert s20 =~ "invalid_reason"
    assert Reason.validate("") == :error
    assert Reason.validate(nil) == :error
  end

  test "R6b (D-164): the runbook says the switch is an interactive act, like the route requires" do
    s20 = step(text(), 20)

    # the route accepts only a person signed in in the browser; an API token is refused
    assert s20 =~ "insufficient permissions"

    Code.ensure_loaded!(Letflow.Routers.ApprovalRules)

    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
      Code.fetch_docs(Letflow.Routers.ApprovalRules)

    assert moduledoc =~ ":oidc"
  end

  test "R7 (D-164): the reason text of the runbook is the owner's text and the product accepts it" do
    src = text()
    assert Regex.run(~r/\{"four_eyes": false, "reason": "([^"]+)"\}/, src)

    [_call, reason] = Regex.run(~r/\{"four_eyes": false, "reason": "([^"]+)"\}/, src)
    assert reason == @reason
    assert Reason.validate(reason) == {:ok, reason}
  end

  test "R8 (D-165): step 20 holds the decision table: every document kind, its rule, the default OFF" do
    rows =
      step(text(), 20)
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| "))
      |> Enum.map(fn line ->
        line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
      end)

    assert [header | data] = rows

    assert header == [
             "Document kind",
             "Rule",
             "Default (a new tenant)",
             "Client 1 (sss)",
             "What the staff see"
           ]

    assert length(data) == 4

    for [_kind, rule, default, _client1, effect] <- data do
      assert default == "OFF"
      assert effect != ""
      assert rule =~ "/ approve"
    end

    kinds = Enum.map(data, &hd/1)
    assert "Opening balance (`stock_opening`)" in kinds
    assert "Count from the phone (`stock_quick_count`)" in kinds
    assert "Excel load that creates counts" in kinds
    assert Enum.any?(kinds, &(&1 =~ "Asset opening (`assets_opening`)"))

    # the count rule is OFF for Client 1 (D-164); the opening rule stays a separate choice
    [opening, count, workbook, _assets] = data

    assert count |> Enum.at(3) =~ "OFF"
    assert count |> Enum.at(3) =~ "D-164"
    assert workbook |> Enum.at(3) =~ "OFF"
    assert workbook |> Enum.at(3) =~ "D-164"
    assert opening |> Enum.at(3) =~ "separate choice"
    refute opening |> Enum.at(3) =~ "D-164"

    # the count rule is the owner's decision; the opening rule stays a separate choice
    s20 = step(text(), 20)
    assert s20 =~ "The opening rule stays a separate choice"
    assert s20 =~ "The default is OFF"
  end

  test "R9 (D-164): the rules the runbook names are the shipped stock pack's own four-eyes steps" do
    pack = Jason.decode!(File.read!(Path.join(@root, "priv/modules/stock/pack.json")))

    rules =
      for definition <- pack["definitions"],
          node <- definition["graph"]["nodes"],
          get_in(node, ["attributes", "distinct_from"]) not in [nil, []],
          do: "#{definition["process_key"]} / #{node["id"]}"

    assert Enum.sort(rules) == ["stock_opening / approve", "stock_quick_count / approve"]

    src = text()
    for rule <- rules, do: assert(src =~ rule, "the runbook does not name #{rule}")
  end

  test "R10 (T-2404): the browser setup part has the click path, reason, read-back, en and ru, and the nothing-to-set lines" do
    src = text()
    i = :binary.match(src, "## Browser setup by the company administrator") |> elem(0)
    part = binary_part(src, i, byte_size(src) - i)
    [part, _] = String.split(part, "## Rollback summary", parts: 2)

    assert part =~ "/admin/approval-rules"
    assert part =~ "/admin/ledger-settings"
    assert part =~ "stock_quick_count"
    assert part =~ @reason
    assert part =~ "approval_rule.changed"
    assert part =~ "owner to decide"
    assert part =~ "stock_opening"

    # the real screen labels, English and Russian, from the shipped catalogs
    for label <- [
          "Require a different person to approve",
          "Требовать утверждения другим человеком",
          "Правила утверждения",
          "Negative balances",
          "Отрицательные остатки",
          "Сохранить"
        ] do
      assert part =~ label

      assert File.read!(
               Path.join(@root, "web/src/pages/admin/approval-rules/approvalRulesMessages.ts")
             ) <>
               File.read!(
                 Path.join(@root, "web/src/pages/admin/ledger-settings/ledgerSettingsMessages.ts")
               ) =~
               label
    end

    # the nothing-to-set lines
    assert part =~ "Default location"
    assert part =~ "Document numbering"
    assert part =~ "Asia/Almaty"
    assert Reason.validate(@reason) == {:ok, @reason}
  end

  test "R11 (T-2424): the fresh-tenant proof makes the count-row setup recommended and pins the screen remarks" do
    src = text()
    s20 = step(src, 20)
    i = :binary.match(src, "## Browser setup by the company administrator") |> elem(0)
    part = binary_part(src, i, byte_size(src) - i)
    [part, _] = String.split(part, "## Rollback summary", parts: 2)

    # A fresh tenant needs no setup to count, but the explicit row records the owner decision.
    for section <- [s20, part] do
      assert section =~ "RECOMMENDED, not required"
      assert section =~ "РЕКОМЕНДУЕТСЯ, но не обязательна"
      assert section =~ "approval_rule.changed"
      assert section =~ "administrator's name"
      assert section =~ "именем администратора"
    end

    # The two real rows and their untouched default, in both languages.
    assert part =~ "The Approval rules screen lists TWO rows"
    assert part =~ "На экране две строки"
    assert part =~ "Never changed (default: off)"
    assert part =~ "Не менялось (по умолчанию: выключено)"

    # The proof found the supported stock paths and the old wrong path.
    for path <- ["/admin/stock/balances", "/admin/stock/quick-count", "/admin/stock/documents"] do
      assert part =~ path
    end

    assert part =~ "/stock/balances` is a 404"

    # Conditional note, disabled Save and the claimed reversal task, in English and Russian.
    assert part =~ "only after the reason \"Other\""
    assert part =~ "then the note is required"
    assert part =~ "только после выбора причины «Другое»"
    assert part =~ "после этого примечание обязательно"
    assert part =~ "Save stays disabled until a reason is typed"
    assert part =~ "Enter a reason to save"
    assert part =~ "кнопка «Сохранить» неактивна, пока не введена причина"
    assert part =~ "Укажите причину, чтобы сохранить"
    assert part =~ "created for the administrator group"
    assert part =~ "must be CLAIMED first, then completed"
    assert part =~ "создаётся для группы администраторов"
    assert part =~ "сначала ВЗЯТЬ В РАБОТУ, а затем завершить"

    # T-2423 already said this once; the proof remarks must not add a second copy.
    assert length(Regex.scan(~r/The Excel balances load has no rule of its own/, part)) == 1
    assert length(Regex.scan(~r/У загрузки остатков из Excel своего правила нет/, part)) == 1
  end
end
