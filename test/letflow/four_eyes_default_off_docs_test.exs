defmodule Letflow.FourEyesDefaultOffDocsTest do
  @moduledoc """
  T-2390 (owner decision D-165, 2026-11-20): the four-eyes rule (a second person must approve) is
  OFF by default for a NEW tenant, per document kind; a company switches it ON on request. The
  operator-facing docs say so: the onboarding runbook (step 20 and its table), the pilot runbook,
  the count runbook, the workbook runbook, the rehearsal runbook and `docs/roles.md`.

  Every doc this test reads is covered by the backend gate's `BACKEND_PATHS_RE` (`docs/runbooks/`
  and `docs/roles.md`), so a change to any of them runs this test. No database.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @onboarding "docs/runbooks/production-tenant-onboarding.md"
  @pilot "docs/runbooks/pilot-rollout.md"
  @counts "docs/runbooks/stock-counts.md"
  @workbook "docs/runbooks/stock-workbook-import.md"
  @rehearsal "docs/runbooks/qoimeks-rehearsal.md"
  @roles "docs/roles.md"

  # The reason the owner gave for the count rule of Client 1 (D-164).
  @reason "Client 1, storekeeper counts from the phone, one administrator, owner decision D-164"

  defp read!(path), do: File.read!(Path.join(@root, path))

  defp step_20(text) do
    parts = Regex.split(~r/^### Step /m, text)
    "### Step " <> Enum.at(tl(parts), 20)
  end

  defp table_rows(text) do
    step_20(text)
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| "))
    |> Enum.map(fn line ->
      line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
    end)
  end

  test "D165-1: the onboarding runbook says the default is OFF and the switch is ON on request" do
    s20 = step_20(read!(@onboarding))

    # the default of every rule, for a tenant created after the decision
    assert s20 =~ "The default of every rule is OFF for a tenant created"
    assert s20 =~ "after owner decision D-165 (2026-11-20)"
    assert s20 =~ "The default is OFF"

    # the switch: where, how and with what
    assert s20 =~ "Admin > Approval rules"
    assert s20 =~ "PUT /api/v1/approval-rules/:definition_name/:node_id"
    assert s20 =~ "GET /api/v1/approval-rules"
    assert s20 =~ ~s({"four_eyes": true, "reason": "Two administrators)
    assert s20 =~ "with a reason"
    assert s20 =~ "invalid_reason"

    # a one-administrator company needs no switch at all
    assert s20 =~ "works out of the box"

    # a tenant created before the decision keeps the old default
    assert s20 =~ "A tenant created"

    refute s20 =~ "The default is ON"
  end

  test "D165-2: step 20 holds one table row per document kind, the default OFF, and what the staff see" do
    assert [header | data] = table_rows(read!(@onboarding))

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
      assert rule =~ "/ approve"
      # what the staff see: the rule ON (a second person) or OFF (the document posts at once)
      assert effect =~ "ON"
      assert effect =~ "OFF"
    end

    kinds = Enum.map(data, &hd/1)
    assert "Opening balance (`stock_opening`)" in kinds
    assert "Count from the phone (`stock_quick_count`)" in kinds
    assert "Excel load that creates counts" in kinds
    assert Enum.any?(kinds, &(&1 =~ "Asset opening (`assets_opening`)"))

    # the self-approval the staff see in the audit when the rule is OFF
    s20 = step_20(read!(@onboarding))
    assert s20 =~ "self-approved, four-eyes off"
    assert s20 =~ "My Tasks"
  end

  test "D165-3: the pilot, count, workbook, rehearsal and roles docs carry the OFF default" do
    pilot = read!(@pilot)
    assert pilot =~ "every rule of a new tenant is OFF by default"
    assert pilot =~ "owner decision D-165, 2026-11-20"
    assert pilot =~ "switches the rule ON, per document kind"
    assert pilot =~ "it is OFF by default like every other rule of a new tenant (D-165)"

    counts = read!(@counts)
    assert counts =~ "Four eyes are OFF by"
    assert counts =~ "default in a new tenant (owner decision D-165)"
    assert counts =~ "PUT /approval-rules/stock_quick_count/approve"

    workbook = read!(@workbook)
    assert workbook =~ "That is the default of a new"

    assert workbook =~
             "tenant (owner decision D-165): the rule is OFF until the tenant administrator switches it ON"

    assert workbook =~ "per rule, with a reason (`PUT /approval-rules/stock_quick_count/approve`)"

    rehearsal = read!(@rehearsal)
    assert rehearsal =~ "defaults to `false`"
    assert rehearsal =~ "owner decision D-165"

    roles = read!(@roles)
    assert roles =~ "OFF by default in a new tenant (owner decision D-165, 2026-11-20)"

    assert roles =~
             "switches the rule ON per document kind, with a reason, on Admin > Approval rules"
  end

  test "D165-4: the Client 1 count rule stays OFF and explicit (owner decision D-164)" do
    onboarding = read!(@onboarding)
    pilot = read!(@pilot)

    for text <- [onboarding, pilot] do
      assert text =~ "D-164"
      assert text =~ @reason
      assert text =~ "stock_quick_count / approve"
      assert text =~ "self-approved, four-eyes off"
    end

    # the count rule of Client 1 is OFF, the opening rule is a separate choice
    s20 = step_20(onboarding)
    assert s20 =~ "For sss (Client 1) the count rule is OFF"
    assert s20 =~ "The opening rule stays a separate choice"
    assert s20 =~ ~s({"four_eyes": false, "reason": "#{@reason}"})
  end

  test "D165-5: none of the docs still claims that the four-eyes default is ON" do
    refute read!(@onboarding) =~ "The default is ON"
    refute read!(@pilot) =~ "otherwise they stay on (the default)"
    refute read!(@counts) =~ "Four eyes are ON by"
    refute read!(@workbook) =~ "**Four eyes ON (default).**"
    refute read!(@rehearsal) =~ "defaults to `true`"
    refute read!(@roles) =~ "stays ON by default"
  end

  test "D165-6 (T-2423): the Excel load follows the count rule, there are two rules on the screen" do
    onboarding = read!(@onboarding)
    assert onboarding =~ "The Excel balances load has no rule of its own"
    assert onboarding =~ "У загрузки остатков из Excel своего правила нет"
    assert onboarding =~ "the Excel load follows the quick count rule"
    assert read!(@workbook) =~ "follows the `stock_quick_count / approve` rule"

    design = read!("docs/design/four-eyes-switch.md")
    refute design =~ "count, workbook load, asset opening"
    assert design =~ "is not a third rule"
  end

  test "D165-7 (T-2423): the external reference columns take lower-case letters, digits, underscores" do
    for path <- [@onboarding, @rehearsal] do
      text = read!(path)
      assert text =~ "lower-case letters, digits and underscores"
      assert text =~ "`SSS` and `UOM-PCS` are"
      assert text =~ "external_ref_system or external_ref_id is not valid"
    end
  end
end
