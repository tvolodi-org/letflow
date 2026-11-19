defmodule Letflow.ProductionTenantOnboardingRunbookTest do
  @moduledoc """
  T-2220: `docs/runbooks/production-tenant-onboarding.md` keeps its module order, checked names, repo paths
  and step structure in step with the code. No database. R1 and R5 are shown to bite on an in-memory copy.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog
  alias Letflow.Release.TenantOnboardingCheck

  @root Path.expand("../..", __DIR__)
  @runbook Path.join(@root, "docs/runbooks/production-tenant-onboarding.md")

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

    numbers == Enum.map(0..13, &Integer.to_string/1) and
      Enum.all?(sections, fn s ->
        Enum.all?(
          ["**Who:**", "**Do:**", "**Check:**", "**Rollback:**"],
          &String.contains?(s, &1)
        )
      end)
  end

  defp who_line(section), do: Regex.run(~r/^\*\*Who:\*\*.*$/m, section) |> hd()

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

  test "R5: steps 0..13 each have Who/Do/Check/Rollback and the infra-only steps say so" do
    src = text()
    assert steps_ok?(src)

    sections = steps(src)

    for n <- [0, 1, 2, 3, 8] do
      assert who_line(Enum.at(sections, n)) =~ "infra only", "step #{n}"
    end

    # bite: a copy with one Check line removed, and one with a step missing, fail
    refute steps_ok?(String.replace(src, "**Check:** 404, default realm", "404, default realm"))
    refute steps_ok?(String.replace(src, "### Step 13. Handover", "### Step 14. Handover"))
  end
end
