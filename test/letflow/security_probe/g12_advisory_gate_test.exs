defmodule Letflow.SecurityProbe.G12AdvisoryGateTest do
  @moduledoc """
  G-12: the PR-blocking dependency advisory gate and the SAST scan of the Elixir tree.

  Gap **G-12** of the team repository's `docs/security-coverage.md` §4:

  > PR-blocking dependency advisory gate plus Sobelow (or justified equivalent) and a real Dart
  > advisory source.

  The coverage map found the dependency audit **report-only**: `mix hex.audit` and `npm audit`
  ran weekly, every step `continue-on-error`, with no `pull_request` trigger; `flutter pub
  outdated` was version freshness, not an advisory check; and no SAST scanner was configured.

  The gate is `mix letflow.advisory_gate`
  (`lib/mix/tasks/letflow.advisory_gate.ex`): it reads the three real advisory sources (Hex via
  `mix hex.audit`, npm via `npm audit --omit=dev`, Dart via the OSV `Pub` ecosystem), keeps the
  advisories that hit a **production** dependency at **medium** severity or above, and fails
  unless every one of them is covered by an entry of `priv/security/advisory-allow.json` that has
  not expired. The SAST half scans `lib/` with the rules of the same module and fails on a
  finding `priv/security/sast-allow.json` does not accept.

  The probe is mechanical: no model, no network, no clock, no database. The network half runs in
  the CI step that calls the gate; the decision half (severity, production scope, allow-list,
  expiry, SAST rules) is what this file proves, with a seeded failing case that the gate must
  catch. The class table is `docs/security-probes/G-12.md`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @moduletag :security_probe
  @moduletag probe_cost_s: 30

  alias Mix.Tasks.Letflow.AdvisoryGate, as: Gate

  @root Path.expand("../../..", __DIR__)
  @fixtures Path.join(@root, "test/fixtures/security_probes/g12")
  @seeded_tree Path.join(@fixtures, "seeded_tree")
  @ci_workflow Path.join(@root, ".github/workflows/ci.yml")

  setup do
    {:ok,
     packages: Gate.production_packages(@seeded_tree),
     advisories: Gate.read_feed!(Path.join(@seeded_tree, "advisories.json")),
     allow: Gate.read_allow_list!(Path.join(@fixtures, "allow_list.json"))}
  end

  defp entry(allow, id), do: Enum.filter(allow, &(&1.id == id))

  defp advisory(advisories, id), do: Enum.find(advisories, &(&1.id == id))

  test "G12: the seeded vulnerable dependency makes the gate fail", ctx do
    verdict = Gate.evaluate(ctx.advisories, [], ctx.packages)

    assert verdict.status == :fail
    assert [{blocking, :not_accepted}] = verdict.blocking
    assert blocking.id == "EEF-CVE-2026-120287"
    assert blocking.ecosystem == :hex
    assert blocking.package == "plug"
    assert blocking.severity == "high"
  end

  test "G12: a low severity advisory does not block the gate", ctx do
    low = [advisory(ctx.advisories, "GHSA-0000-seeded-low")]
    verdict = Gate.evaluate(low, [], ctx.packages)

    assert verdict.status == :pass
    assert verdict.blocking == []
    assert [{:below_threshold, _advisory}] = verdict.informational
  end

  test "G12: an advisory on a test-only dependency is out of scope", ctx do
    dev = [advisory(ctx.advisories, "GHSA-0000-seeded-dev")]
    verdict = Gate.evaluate(dev, [], ctx.packages)

    assert verdict.status == :pass
    assert verdict.blocking == []
    assert [{:out_of_production, _advisory}] = verdict.informational
  end

  test "G12: an npm advisory on a production dependency blocks the gate", ctx do
    advisories = Gate.read_feed!(Path.join(@seeded_tree, "advisories_npm_pub.json"))
    npm = Enum.filter(advisories, &(&1.id == "GHSA-0000-seeded-npm"))
    verdict = Gate.evaluate(npm, [], ctx.packages)

    assert verdict.status == :fail
    assert [{blocking, :not_accepted}] = verdict.blocking
    assert blocking.id == "GHSA-0000-seeded-npm"
    assert blocking.ecosystem == :npm
    assert blocking.package == "left-pad"
  end

  test "G12: a Dart advisory on a production dependency blocks the gate", ctx do
    advisories = Gate.read_feed!(Path.join(@seeded_tree, "advisories_npm_pub.json"))
    pub = Enum.filter(advisories, &(&1.id == "GHSA-0000-seeded-pub"))
    verdict = Gate.evaluate(pub, [], ctx.packages)

    assert verdict.status == :fail
    assert [{blocking, :not_accepted}] = verdict.blocking
    assert blocking.id == "GHSA-0000-seeded-pub"
    assert blocking.ecosystem == :pub
    assert blocking.package == "http"
  end

  test "G12: an advisory on a dev-only npm dependency is out of scope", ctx do
    advisories = Gate.read_feed!(Path.join(@seeded_tree, "advisories_npm_pub.json"))
    dev = Enum.filter(advisories, &(&1.id == "GHSA-0000-seeded-npm-dev"))
    verdict = Gate.evaluate(dev, [], ctx.packages)

    assert verdict.status == :pass
    assert verdict.blocking == []
    assert [{:out_of_production, _advisory}] = verdict.informational
  end

  test "G12: a live allow-list entry accepts the advisory", ctx do
    accepted = entry(ctx.allow, "EEF-CVE-2026-120287")
    verdict = Gate.evaluate(ctx.advisories, accepted, ctx.packages)

    assert verdict.status == :pass
    assert verdict.blocking == []
    assert [{_advisory, allow_entry}] = verdict.accepted
    assert allow_entry.reason =~ "live exception"
    assert allow_entry.owner == "team"
  end

  test "G12: an expired allow-list entry fails the gate", ctx do
    expired = entry(ctx.allow, "GHSA-0000-seeded-expired")
    verdict = Gate.evaluate(ctx.advisories, expired, ctx.packages)

    assert verdict.status == :fail
    assert [{_entry, :expired}] = verdict.expired
  end

  test "G12: an allow-list entry for an advisory that no longer exists is reported", ctx do
    stale = entry(ctx.allow, "GHSA-0000-seeded-stale")
    verdict = Gate.evaluate([], stale, ctx.packages)

    assert verdict.status == :pass
    assert [{_entry, :stale}] = verdict.stale
  end

  test "G12: the production dependency inventory of the tree is not empty" do
    packages = Gate.production_packages(@root)

    assert map_size(packages.hex) > 0, "no production hex dependency was found"
    assert map_size(packages.npm) > 0, "no production npm dependency was found"
    assert map_size(packages.pub) > 0, "no production dart dependency was found"

    # The inventory is a production one: a test-only dependency is not in it.
    refute Map.has_key?(packages.hex, "stream_data")
    refute Map.has_key?(packages.hex, "yaml_elixir")

    # Every key is the bare package name. A key that keeps the indentation of the lock file
    # ("  http") never matches an advisory, and that source would then silently never block a
    # pull request -- the Dart half of the gate looked exactly like that.
    for ecosystem <- [:hex, :npm, :pub], {name, _version} <- packages[ecosystem] do
      assert name == String.trim(name),
             "#{ecosystem}: #{inspect(name)} is not a bare package name"
    end
  end

  test "G12: the shipped allow-list file carries the required fields" do
    path = Path.join(@root, "priv/security/advisory-allow.json")
    entries = Gate.read_allow_list!(path)

    for entry <- entries do
      assert entry.id != ""
      assert entry.package != ""
      assert entry.reason != ""
      assert entry.owner != ""
      assert {:ok, _date} = Date.from_iso8601(entry.expires), "entry without a parsable expiry"
    end
  end

  test "G12: the CI workflow runs the advisory gate and the step is not continue-on-error" do
    workflow = File.read!(@ci_workflow)

    assert workflow =~ "pull_request:"
    assert workflow =~ "merge_group:"

    steps = String.split(workflow, ~r/\n      - name: /)
    gate_steps = Enum.filter(steps, &(&1 =~ "letflow.advisory_gate"))

    assert gate_steps != [], "no CI step runs the advisory gate"
    assert Enum.any?(gate_steps, &(&1 =~ "mix letflow.advisory_gate"))

    refute Enum.any?(gate_steps, &(&1 =~ "continue-on-error: true")),
           "the advisory gate step is continue-on-error: it would not block a pull request"
  end

  test "G12: the advisory gate is a Mix task of this repository" do
    assert Mix.Task.get("letflow.advisory_gate") == Gate
  end

  test "G12: the SAST rules flag every violation of the seeded rogue file" do
    findings = Gate.sast_findings(@seeded_tree)
    rules = findings |> Enum.map(& &1.rule) |> Enum.uniq() |> Enum.sort()

    assert rules == [
             "command_injection",
             "sql_interpolation",
             "unsafe_atom",
             "unsafe_deserialization",
             "weak_hash"
           ]

    # Every finding names the seeded file: the scan looked at the tree it was given.
    assert Enum.all?(findings, &(&1.file =~ "rogue_sast.ex"))
  end

  test "G12: the real tree has no SAST finding outside the accepted list" do
    findings = Gate.sast_findings(@root)
    allow = Gate.read_allow_list!(Path.join(@root, "priv/security/sast-allow.json"))
    verdict = Gate.evaluate_sast(findings, allow)

    assert verdict.status == :pass,
           "unaccepted SAST findings: #{inspect(Enum.map(verdict.blocking, fn {f, _} -> f.id end))}"
  end

  @tag :tmp_dir
  test "G12: the id of a finding does not move when the file grows above the site", %{
    tmp_dir: tmp
  } do
    source = File.read!(Path.join(@seeded_tree, "lib/rogue_sast.ex"))
    padding = String.duplicate("# a line above the site\n", 40)

    ids =
      for {name, text} <- [{"plain", source}, {"padded", padding <> source}] do
        root = Path.join(tmp, name)
        File.mkdir_p!(Path.join(root, "lib"))
        File.write!(Path.join(root, "lib/rogue_sast.ex"), text)

        Gate.sast_findings(root) |> Enum.map(& &1.id) |> Enum.sort()
      end

    [plain_ids, padded_ids] = ids

    assert plain_ids != [], "the seeded file produced no finding at all"
    # The same sites, forty lines further down: the id of a finding is the rule, the file and
    # a hash of the call -- not the line -- so an accepted site does not become a NEW finding
    # when something is inserted above it, and the gate does not block unrelated pull
    # requests that touch the file.
    assert plain_ids == padded_ids
  end

  @tag :tmp_dir
  test "G12: the advisory report prints its verdict instead of crashing", %{tmp_dir: tmp} do
    allow_path = Path.join(tmp, "advisory-allow.json")

    File.write!(
      allow_path,
      Jason.encode!(%{
        "version" => 1,
        "entries" => [
          %{
            "id" => "EEF-CVE-2026-120287",
            "package" => "plug",
            "reason" => "Seeded case: a live exception with a date in the future.",
            "owner" => "team",
            "expires" => "2099-01-01"
          }
        ]
      })
    )

    output =
      capture_io(fn ->
        Gate.run([
          "--feed",
          Path.join(@seeded_tree, "advisories.json"),
          "--root",
          @seeded_tree,
          "--allow-list",
          allow_path
        ])
      end)

    assert output =~ "advisory gate: PASS"
    assert output =~ "accepted hex/plug EEF-CVE-2026-120287"
  end

  @tag :tmp_dir
  test "G12: the SAST report prints its verdict instead of crashing", %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "lib"))
    File.write!(Path.join(tmp, "lib/clean.ex"), "defmodule Clean do\n  def run, do: :ok\nend\n")

    File.mkdir_p!(Path.join(tmp, "priv/security"))

    File.write!(
      Path.join(tmp, "priv/security/sast-allow.json"),
      ~s({"version": 1, "entries": []})
    )

    output = capture_io(fn -> Gate.run(["--sast-only", "--root", tmp]) end)

    assert output =~ "sast scan: PASS"
  end
end
