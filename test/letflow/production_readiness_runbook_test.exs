defmodule Letflow.ProductionReadinessRunbookTest do
  @moduledoc """
  REQ-785 (GH #4057): `docs/runbooks/production-readiness.md` keeps its Settings table in step with
  `config/runtime.exs`. The set N of setting names is derived at run time (every
  `LETFLOW_*`/`OIDC_*` token plus every first argument of `System.get_env("NAME"...)`); no count is
  pinned. The check is shown to bite on an in-memory copy with a row removed and one with an extra row.
  No database.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @runbook Path.join(@root, "docs/runbooks/production-readiness.md")
  @runtime Path.join(@root, "config/runtime.exs")

  @headings [
    "Status",
    "Sign-in per company",
    "What a backup must hold",
    "Settings",
    "Open owner questions"
  ]

  defp names_in_runtime do
    src = File.read!(@runtime)

    prefixed = Regex.scan(~r/\b(?:LETFLOW|OIDC)_[A-Z0-9_]+\b/, src) |> Enum.map(&hd/1)

    getenv =
      Regex.scan(~r/System\.get_env\(\s*"([^"]+)"/, src)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.filter(&Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, &1))

    MapSet.new(prefixed ++ getenv)
  end

  defp settings_section(markdown) do
    [_, rest] = String.split(markdown, "\n## Settings\n", parts: 2)
    hd(String.split(rest, "\n## ", parts: 2))
  end

  defp table_names(markdown) do
    markdown
    |> settings_section()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\|\s*`([^`]+)`\s*\|/, line) do
        [_, name] -> [name]
        _ -> []
      end
    end)
  end

  defp check(markdown, names) do
    rows = MapSet.new(table_names(markdown))
    missing = names |> MapSet.difference(rows) |> Enum.sort()
    extra = rows |> MapSet.difference(names) |> Enum.sort()

    if missing == [] and extra == [], do: :ok, else: {:error, %{missing: missing, extra: extra}}
  end

  setup_all do
    {:ok, markdown: File.read!(@runbook)}
  end

  test "T1 every setting of runtime.exs has a row and no row names another setting", %{
    markdown: md
  } do
    assert MapSet.size(names_in_runtime()) > 0
    assert check(md, names_in_runtime()) == :ok
  end

  test "T2 a copy with one row removed fails and names it", %{markdown: md} do
    victim = "LETFLOW_SECRETS_MASTER_KEY"

    copy =
      md
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "| `#{victim}` |"))
      |> Enum.join("\n")

    assert {:error, %{missing: missing}} = check(copy, names_in_runtime())
    assert victim in missing
  end

  test "T3 a copy with an extra row fails and names it", %{markdown: md} do
    extra_row = "| `LETFLOW_NOT_A_SETTING` | no | nothing | none |\n"
    # inside the Settings table, directly above its last row
    copy = String.replace(md, "| `RESERVED_HEADROOM` |", extra_row <> "| `RESERVED_HEADROOM` |")
    refute copy == md

    assert {:error, %{extra: extra}} = check(copy, names_in_runtime())
    assert "LETFLOW_NOT_A_SETTING" in extra
  end

  test "T4 the level-2 headings are the five of the requirement, in order", %{markdown: md} do
    headings =
      for line <- String.split(md, "\n"),
          String.starts_with?(line, "## "),
          do: String.trim_leading(line, "## ")

    assert headings == @headings
  end

  test "T5 the sections cite their sources", %{markdown: md} do
    for needle <- [
          "D-019 item 3",
          "D-019 item 9",
          "D-086",
          "D-016",
          "D-019 item 7",
          "priv/keycloak/provisioner/v2/tenant-realm.json",
          "docs/runbooks/onboarding-new-tenant-realm.md",
          "Tenant type (REQ-469)",
          "LETFLOW_SECRETS_MASTER_KEY",
          "0016-secrets-storage-backend.md",
          "A purge does not erase backups or replicas",
          "docs/runbooks/tenant-provisioner-credential.md",
          "docs/runbooks/backup-restore.md"
        ] do
      assert String.contains?(md, needle), "runbook does not mention #{needle}"
    end

    # the quoted sentence really is in the source it is quoted from
    source = File.read!(Path.join(@root, "docs/runbooks/tenant-provisioner-credential.md"))
    assert String.contains?(source, "A purge does not erase backups or replicas")

    open =
      md
      |> String.split("\n## Open owner questions\n", parts: 2)
      |> List.last()
      |> String.downcase()

    for topic <- ["data loss", "restore time", "kept", "keycloak", "provisioning", "manage-users"] do
      assert String.contains?(open, topic), "open questions miss #{topic}"
    end
  end

  test "T6 every provisioner row says it stays unset until D-019 item 9 is approved", %{
    markdown: md
  } do
    rows =
      md
      |> settings_section()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| `LETFLOW_PROVISIONER_"))

    assert rows != []

    assert Enum.all?(
             rows,
             &String.contains?(&1, "stays unset in production until the owner approves")
           )
  end
end
