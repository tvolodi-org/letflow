defmodule Mix.Tasks.Letflow.CheckUatScenarioSchemaTest do
  @moduledoc """
  Coverage for REQ-358 -- `mix letflow.check_uat_scenario_schema`
  (`lib/mix/tasks/letflow.check_uat_scenario_schema.ex`).

  Spec: `test/specs/REQ-358.md`. Design:
  `lib/letflow/design/req358-uat-scope-branching-env.md` §2 (mechanical rules
  SCHEMA-1..6), §1.2 (the `scope`/`company_id` default-derivation rule) and §3
  (the login-routing throwaway fixture). Run: `WF02-REQ358-20260916`, WF-02
  Step 3.

  This is a WF-02 (new-code) requirement, not a WF-03 regression, so the
  fail-first-against-pre-fix-code discipline does not apply here -- the
  module under test is genuinely new and there is no prior "broken" version
  to run these tests against. Instead, every fixture below is built so that a
  concrete, plausible bug in `check_scenario/2` would turn it red; each test
  says which SCHEMA rule it pins and, where useful, names the specific
  mistake it would catch (e.g. "an implementation that only checks
  `scope:` and never falls back to `company_id:`" for the backward-compat
  fixtures).

  ## What this suite intentionally does NOT test

  `check_scenario/2` and `check_file/1` are exhaustively covered here. The
  module has **no branch-evaluation/branch-matching function** -- confirmed
  by reading `lib/mix/tasks/letflow.check_uat_scenario_schema.ex` in full:
  its only exported functions are `run/1`, `check_file/1`, `check_scenario/2`
  and `render/1`, none of which pick a branch or evaluate a `when:` condition
  against an observed fact. Branch *evaluation* (which of
  `platform_admin_dashboard` / `tenant_user_dashboard` /
  `unauthenticated_fallback` actually runs for a given session) is
  UAT-RUNNER's own runtime job against a live role/session, per
  `.claude/agents/uat-runner.md`'s "Evaluating a `when:` branch" section (design
  §4.3) -- it is a Claude subagent reading procedural markdown against a real
  HTTP session, not an Elixir function, and is not unit-testable here. This
  suite proves AC4's *schema* half only: the login-routing fixture's
  three-branch shape is valid under SCHEMA-1..6. The runtime-evaluation half
  is exercised by a real UAT-RUNNER run against QA, dispatched separately
  (not this step's job -- see the REQ-358 task description).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Mix.Tasks.Letflow.CheckUatScenarioSchema, as: Check

  @project_root Path.expand("../../..", __DIR__)
  @meridian_file Path.join(
                   @project_root,
                   "test/fixtures/uat/scenarios/meridian/loan-origination-below-threshold.yaml"
                 )
  @platform_file Path.join(
                   @project_root,
                   "test/fixtures/uat/scenarios/platform/definition-promotion-approved.yaml"
                 )
  @login_routing_file Path.join(
                        @project_root,
                        "test/fixtures/uat/scenarios/_throwaway/login-routing-example.yaml"
                      )

  # ------------------------------------------------------------------
  # Fixture construction. Plain Elixir maps with string keys, matching
  # YamlElixir.read_from_file/1's own output shape (the codebase's existing
  # convention -- see test/support/simulation/scenario_fixture.ex) so
  # check_scenario/2 is exercised exactly as run/1 would call it, without
  # going through the filesystem for every case.
  # ------------------------------------------------------------------

  @fixture_path "fixture.yaml"

  defp flat_step,
    do: %{"step" => 1, "actor" => "viewer", "action" => "does a thing", "via" => "gui"}

  defp flat_outcome, do: %{"id" => "EO-001", "description" => "something is observed"}

  # A minimal, otherwise-fully-valid flat (non-branching) scenario. Callers
  # override only the keys under test so each fixture stays legible about
  # what it is actually pinning.
  defp valid_flat(overrides) do
    %{
      "id" => "REQ-358-fixture",
      "title" => "A valid flat scenario",
      "version" => "1.0",
      "scope" => "lending",
      "steps" => [flat_step()],
      "expected_outcomes" => [flat_outcome()]
    }
    |> Map.merge(overrides)
  end

  defp branch(name, when_clause) do
    %{
      "name" => name,
      "when" => when_clause,
      "steps" => [flat_step()],
      "expected_outcomes" => [flat_outcome()]
    }
  end

  # A minimal, otherwise-fully-valid branching scenario built from the given
  # branch list.
  defp valid_branching(branches) do
    %{
      "id" => "REQ-358-fixture",
      "title" => "A valid branching scenario",
      "version" => "1.0",
      "scope" => "platform",
      "branches" => branches
    }
  end

  defp rules(violations), do: violations |> Enum.map(& &1.rule) |> Enum.uniq() |> Enum.sort()

  defp check(data), do: Check.check_scenario(@fixture_path, data)

  # ==================================================================
  # AC1 -- backward compatibility (design §1.2's default-derivation rule)
  # ==================================================================

  describe "AC1 -- backward compatibility" do
    test "F-SCOPE-FROM-COMPANY-ID -- no scope:, only company_id:, resolves and passes" do
      # No `scope:` key at all -- exactly the shape of all 29 pre-existing
      # scenario files. An implementation that requires an explicit `scope:`
      # key (never falling back to `company_id:`) would flag SCHEMA-3 here;
      # this fixture is what makes that mistake visible.
      data =
        valid_flat(%{})
        |> Map.delete("scope")
        |> Map.put("company_id", "meridian")

      violations = check(data)

      assert violations == [],
             "an existing tenant-scenario shape (company_id, no scope) must validate " <>
               "unchanged -- got #{inspect(violations)}"
    end

    test "F-SCOPE-FROM-COMPANY-ID-PLATFORM -- company_id: platform resolves too" do
      data = valid_flat(%{}) |> Map.delete("scope") |> Map.put("company_id", "platform")

      assert check(data) == []
    end

    test "F-SCOPE-EXPLICIT-NO-COMPANY-ID -- an explicit scope: with no company_id: is fine" do
      # The forward-looking case design §1.2 also describes: a genuinely new
      # Letflow-native scenario with no legacy company binding at all.
      data = valid_flat(%{"scope" => "lending"}) |> Map.delete("company_id")

      assert check(data) == []
    end

    test "T-LIVE-MERIDIAN -- the real, unedited meridian fixture validates via check_file/1" do
      # AC1's own evidence mechanism per design §5: run against the real,
      # untouched file (no scope: key, only company_id: meridian) and see a
      # clean OK. Uses check_file/1 (not check_scenario/2) so the real
      # YAML-parsing path is exercised too, not just the pure core.
      assert File.exists?(@meridian_file), "fixture corpus must contain the meridian file"

      result = Check.check_file(@meridian_file)

      assert result.ok? == true

      assert result.violations == [],
             "the untouched meridian file must pass with zero edits -- got " <>
               inspect(result.violations)
    end

    test "T-LIVE-PLATFORM -- the real, unedited platform fixture validates via check_file/1" do
      assert File.exists?(@platform_file), "fixture corpus must contain the platform file"

      result = Check.check_file(@platform_file)

      assert result.ok? == true
      assert result.violations == []
    end
  end

  # ==================================================================
  # AC2 -- malformed scope/branching fixtures are rejected with a specific,
  # checkable error (one test case per SCHEMA-3..6 rule named in the design)
  # ==================================================================

  describe "AC2 -- malformed rejection" do
    test "F-SCOPE-MISSING -- neither scope: nor company_id: is SCHEMA-3" do
      data = valid_flat(%{}) |> Map.delete("scope")

      violations = check(data)

      assert rules(violations) == ["SCHEMA-3"]
      assert Enum.any?(violations, &(&1.message =~ "neither `scope:` nor `company_id:`"))
    end

    test "F-SCOPE-EMPTY-STRING -- scope: \"\" does not silently pass SCHEMA-3" do
      # A common malformed shape: the key is present but its value is the
      # empty string. A check that only tests Map.has_key?/2 (never
      # non-emptiness) would let this through; this fixture catches that.
      data = valid_flat(%{"scope" => ""}) |> Map.delete("company_id")

      assert rules(check(data)) == ["SCHEMA-3"]
    end

    test "F-SCOPE-WRONG-TYPE -- a non-string scope: is SCHEMA-3, not coerced" do
      data = valid_flat(%{"scope" => 42}) |> Map.delete("company_id")

      assert rules(check(data)) == ["SCHEMA-3"]
    end

    test "F-REQUIRED-FIELDS-MISSING -- missing id/title/version is SCHEMA-2, one per field" do
      data = %{
        "scope" => "lending",
        "steps" => [flat_step()],
        "expected_outcomes" => [flat_outcome()]
      }

      violations = check(data)

      assert rules(violations) == ["SCHEMA-2"]
      assert length(violations) == 3, "id, title AND version must each be flagged individually"
    end

    test "F-BOTH-STEPS-AND-BRANCHES -- carrying both step shapes at once is SCHEMA-4" do
      data =
        valid_flat(%{})
        |> Map.put("branches", [
          branch("only_branch", %{"fact" => "role", "op" => "eq", "value" => "PLATFORM_ADMIN"})
        ])

      violations = check(data)

      assert rules(violations) == ["SCHEMA-4"]
      assert Enum.any?(violations, &(&1.message =~ "must use exactly one of the two step shapes"))
    end

    test "F-NEITHER-STEPS-NOR-BRANCHES -- carrying neither step shape is SCHEMA-4" do
      data = valid_flat(%{}) |> Map.delete("steps") |> Map.delete("expected_outcomes")

      violations = check(data)

      assert rules(violations) == ["SCHEMA-4"]
      assert Enum.any?(violations, &(&1.message =~ "must define at least one step shape"))
    end

    test "F-BRANCHES-EMPTY-LIST -- branches: [] is SCHEMA-5" do
      data = valid_branching([])

      assert rules(check(data)) == ["SCHEMA-5"]
    end

    test "F-BRANCH-BAD-OP -- an operator outside eq/in is SCHEMA-5, not silently allowed" do
      # This is the guardrail the design is explicit about: the `when:`
      # vocabulary is deliberately narrow (eq/in/else only, never and/or/not
      # or a relational operator). An implementation that accepts any string
      # op (or only rejects a hardcoded blocklist) would let "gt" through.
      data =
        valid_branching([
          branch("bad_op", %{"fact" => "role", "op" => "gt", "value" => "PLATFORM_ADMIN"})
        ])

      violations = check(data)

      assert rules(violations) == ["SCHEMA-5"]
      assert Enum.any?(violations, &(&1.message =~ "only `eq` and `in` are allowed"))
    end

    test "F-BRANCH-EQ-WITH-LIST-VALUE -- op: eq with a list value is SCHEMA-5" do
      data =
        valid_branching([
          branch("wrong_value_shape", %{"fact" => "role", "op" => "eq", "value" => ["A", "B"]})
        ])

      assert rules(check(data)) == ["SCHEMA-5"]
    end

    test "F-BRANCH-IN-WITH-EMPTY-LIST -- op: in with an empty value list is SCHEMA-5" do
      data =
        valid_branching([
          branch("empty_in_list", %{"fact" => "role", "op" => "in", "value" => []})
        ])

      assert rules(check(data)) == ["SCHEMA-5"]
    end

    test "F-BRANCH-MISSING-NAME -- a branch with no name is SCHEMA-5" do
      bad_branch =
        %{"fact" => "role", "op" => "eq", "value" => "PLATFORM_ADMIN"}
        |> then(
          &%{"when" => &1, "steps" => [flat_step()], "expected_outcomes" => [flat_outcome()]}
        )

      violations = check(valid_branching([bad_branch]))

      assert rules(violations) == ["SCHEMA-5"]
      assert Enum.any?(violations, &(&1.message =~ "missing or empty `name`"))
    end

    test "F-BRANCH-DUPLICATE-NAME -- two branches sharing a name is SCHEMA-5" do
      data =
        valid_branching([
          branch("same_name", %{"fact" => "role", "op" => "eq", "value" => "PLATFORM_ADMIN"}),
          branch("same_name", %{"fact" => "role", "op" => "eq", "value" => "TENANT_ADMIN"})
        ])

      violations = check(data)

      assert "SCHEMA-5" in rules(violations)
      assert Enum.any?(violations, &(&1.message =~ "not unique within the file"))
    end

    test "F-BRANCH-EMPTY-STEPS -- a branch with an empty steps: list is SCHEMA-5" do
      bad_branch = %{
        "name" => "empty_steps",
        "when" => %{"fact" => "role", "op" => "eq", "value" => "X"},
        "steps" => [],
        "expected_outcomes" => [flat_outcome()]
      }

      violations = check(valid_branching([bad_branch]))

      assert rules(violations) == ["SCHEMA-5"]
      assert Enum.any?(violations, &(&1.message =~ "missing or empty `steps:` list"))
    end

    test "F-ELSE-NOT-LAST -- an else branch that is not the final entry is SCHEMA-6" do
      data =
        valid_branching([
          branch("fallback", "else"),
          branch("tenant_user_dashboard", %{
            "fact" => "role",
            "op" => "in",
            "value" => ["TENANT_ADMIN"]
          })
        ])

      violations = check(data)

      assert rules(violations) == ["SCHEMA-6"]
      assert Enum.any?(violations, &(&1.message =~ "is not the last entry"))
    end

    test "F-ELSE-MULTIPLE -- two else branches in one file is SCHEMA-6" do
      data =
        valid_branching([
          branch("fallback_one", "else"),
          branch("fallback_two", "else")
        ])

      violations = check(data)

      assert rules(violations) == ["SCHEMA-6"]
      assert Enum.any?(violations, &(&1.message =~ "at most one is allowed"))
    end

    test "F-PARSE-ERROR -- a file that is not valid YAML is rejected via check_file/1, SCHEMA-1" do
      dir = Path.join(System.tmp_dir!(), "letflow-cuss-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "broken.yaml")
      # An unterminated flow-mapping: guaranteed to fail YAML parsing rather
      # than parsing into something merely wrong-shaped.
      File.write!(path, "id: [this is not closed\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      result = Check.check_file(path)

      assert result.ok? == false
      assert [violation] = result.violations
      assert violation.rule == "SCHEMA-1"
      assert violation.message =~ "YAML parse error"
    end

    test "F-NOT-A-MAPPING -- a file whose top level is a list, not a map, is SCHEMA-1" do
      dir = Path.join(System.tmp_dir!(), "letflow-cuss-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "list.yaml")
      File.write!(path, "- one\n- two\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      result = Check.check_file(path)

      assert result.ok? == false
      assert [violation] = result.violations
      assert violation.rule == "SCHEMA-1"
      assert violation.message =~ "not a mapping"
    end
  end

  # ==================================================================
  # AC4 -- branching sufficiency (schema-validation half; see moduledoc for
  # why UAT-RUNNER's own runtime branch evaluation is not covered here)
  # ==================================================================

  describe "AC4 -- branching sufficiency (schema half)" do
    test "T-LOGIN-ROUTING-FIXTURE-VALID -- the three-branch login-routing fixture validates" do
      # Proves the eq/in/else vocabulary is SCHEMA-1..6-valid for exactly the
      # role=PLATFORM_ADMIN / role=<tenant-role> / unauthenticated (else)
      # shape the requirement text names -- design §3's throwaway fixture.
      assert File.exists?(@login_routing_file),
             "the throwaway login-routing fixture must exist for this AC4 check"

      result = Check.check_file(@login_routing_file)

      assert result.ok? == true

      assert result.violations == [],
             "the login-routing fixture must be schema-valid -- got #{inspect(result.violations)}"
    end

    test "F-LOGIN-ROUTING-SHAPE-HERMETIC -- the same three-branch shape, built in-suite" do
      # A hermetic counterpart to T-LOGIN-ROUTING-FIXTURE-VALID: the exact
      # branch shape named in the requirement text (PLATFORM_ADMIN / a
      # tenant-role list / else), built as an in-suite fixture rather than
      # read from disk, so this property does not depend on that file's
      # continued existence at its current path.
      data =
        valid_branching([
          branch("platform_admin_dashboard", %{
            "fact" => "role",
            "op" => "eq",
            "value" => "PLATFORM_ADMIN"
          }),
          branch("tenant_user_dashboard", %{
            "fact" => "role",
            "op" => "in",
            "value" => ["TENANT_ADMIN", "TENANT_USER"]
          }),
          branch("unauthenticated_fallback", "else")
        ])

      assert check(data) == []
    end
  end

  describe "F-TOTALITY -- ok? agrees with the violations list, for every fixture above" do
    test "check_file/1's ok? is true iff violations is empty" do
      for path <- [@meridian_file, @platform_file, @login_routing_file] do
        result = Check.check_file(path)
        assert result.ok? == (result.violations == []), path
      end
    end
  end

  # ==================================================================
  # REQ-452 -- actor roster, expect_refusal, rules SCHEMA-7..12
  #
  # Hermetic: every corpus is written to a throwaway tmp dir (scenario files
  # plus a roster file, JSON-encoded -- JSON is valid YAML) and checked via
  # check_paths/3. No DB; the only live-corpus use is T-LIVE-ROSTER. Each
  # rule fixture violates ONLY the rule under test.
  # ==================================================================

  @known_roles ["PLATFORM_ADMIN", "TASK_WORKER"]
  @live_roster Path.join(@project_root, "test/fixtures/uat/actors.yaml")
  @live_glob Path.join(@project_root, "test/fixtures/uat/scenarios/**/*.yaml")

  # Frozen in the test itself: the roster's refusal_coverage_exempt may only
  # shrink, never grow beyond this list (REQ-452 AC).
  @initial_refusal_exempt ~w(bilimbaga meridian platform swiftroute vortex)

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "letflow-r452-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A valid scenario in `scope` with one step by `actor`; carries a refusal
  # step unless refusal: false.
  defp r452_scenario(id, scope, actor, opts \\ []) do
    step = %{"step" => 1, "actor" => actor, "action" => "tries a thing", "via" => "gui"}

    step =
      if Keyword.get(opts, :refusal, true), do: Map.put(step, "expect_refusal", true), else: step

    %{
      "id" => id,
      "title" => "Fixture #{id}",
      "version" => "1.0",
      "scope" => scope,
      "steps" => [step],
      "expected_outcomes" => [%{"id" => "EO-1", "description" => "refused"}]
    }
  end

  defp r452_roster(overrides) do
    Map.merge(
      %{
        "actors" => %{
          "actor-acme-bob" => %{"tenant" => "acme", "builtin_roles" => ["TASK_WORKER"]},
          "actor-platform-pat" => %{
            "tenant" => "platform",
            "builtin_roles" => ["PLATFORM_ADMIN"]
          }
        }
      },
      overrides
    )
  end

  defp r452_tenant_admin_roster(extra) do
    r452_roster(
      Map.merge(
        %{
          "actors" => %{
            "actor-acme-bob" => %{"tenant" => "acme", "builtin_roles" => ["PLATFORM_ADMIN"]}
          }
        },
        extra
      )
    )
  end

  # Writes the corpus; returns {scenario_paths, roster_path, report}.
  defp r452_run(scenarios, roster, known_roles \\ @known_roles) do
    dir = tmp_dir()
    roster_path = Path.join(dir, "actors.json")
    File.write!(roster_path, Jason.encode!(roster))

    paths =
      for scenario <- scenarios do
        path = Path.join(dir, "#{scenario["id"]}.yaml")
        File.write!(path, Jason.encode!(scenario))
        path
      end

    {paths, roster_path, Check.check_paths(paths, roster_path, known_roles)}
  end

  defp tags(report), do: rules(report.violations)

  defp only(report, tag), do: Enum.filter(report.violations, &(&1.rule == tag))

  defp exempt_overflow(exempt),
    do: MapSet.difference(MapSet.new(exempt), MapSet.new(@initial_refusal_exempt))

  describe "REQ-452 baseline" do
    test "T-R452-BASE -- the shared fixture corpus is clean, so every rule test isolates its rule" do
      {_paths, _rp, report} =
        r452_run([r452_scenario("base", "acme", "actor-acme-bob")], r452_roster(%{}))

      assert report.violations == []
      assert report.actor_stats == %{login_actors: 1, in_roster: 1, unresolved: 0, missing: 0}
    end
  end

  describe "SCHEMA-7 (rule a) -- login actor must be in the roster" do
    test "T-SCHEMA-7 -- an actor in neither actors: nor unresolved: names rule, file and actor" do
      {[path], _rp, report} =
        r452_run([r452_scenario("s7", "acme", "actor-acme-ghost")], r452_roster(%{}))

      assert tags(report) == ["SCHEMA-7"]
      assert [v] = report.violations
      assert v.file == path
      assert v.message =~ "actor-acme-ghost"
      assert report.actor_stats.missing == 1
    end

    test "T-SCHEMA-7-NEG -- an actor listed only under unresolved: passes (a recorded gap)" do
      roster = r452_roster(%{"unresolved" => %{"actor-acme-ghost" => %{"searched" => ["grep"]}}})
      {_p, _rp, report} = r452_run([r452_scenario("s7n", "acme", "actor-acme-ghost")], roster)

      assert report.violations == []
      assert report.actor_stats.unresolved == 1
    end

    test "T-SCHEMA-7-NONLOGIN -- actor-system-* and actor-any are not login actors" do
      scenario = r452_scenario("s7x", "acme", "actor-system-engine")

      scenario =
        put_in(scenario, ["steps"], [
          hd(scenario["steps"]),
          %{"step" => 2, "actor" => "actor-any", "action" => "x", "via" => "gui"}
        ])

      {_p, _rp, report} = r452_run([scenario], r452_roster(%{}))

      assert report.violations == []
      assert report.actor_stats.login_actors == 0
    end
  end

  describe "SCHEMA-8 (rule b) -- builtin_roles must be in Authorization.roles/0" do
    defp unknown_role_roster do
      r452_roster(%{
        "actors" => %{
          "actor-acme-bob" => %{"tenant" => "acme", "builtin_roles" => ["TENANT_BOSS"]}
        }
      })
    end

    test "T-SCHEMA-8 -- an unknown role names rule, roster file and actor" do
      {_p, rp, report} =
        r452_run([r452_scenario("s8", "acme", "actor-acme-bob")], unknown_role_roster())

      assert tags(report) == ["SCHEMA-8"]
      assert [v] = report.violations
      assert v.file == rp
      assert v.message =~ "actor-acme-bob"
      assert v.message =~ "TENANT_BOSS"
    end

    test "T-SCHEMA-8-FOLLOWS-ROLES -- the same role passes once it is in the passed role list" do
      {_p, _rp, report} =
        r452_run(
          [r452_scenario("s8f", "acme", "actor-acme-bob")],
          unknown_role_roster(),
          @known_roles ++ ["TENANT_BOSS"]
        )

      assert report.violations == []
    end

    test "T-KNOWN-ROLE-NAMES -- known_role_names/0 is exactly Authorization.roles/0 as strings" do
      assert Check.known_role_names() ==
               Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)

      assert "PLATFORM_ADMIN" in Check.known_role_names()
    end
  end

  describe "SCHEMA-9 (rule c) -- tenant actor must not hold PLATFORM_ADMIN" do
    test "T-SCHEMA-9 -- tenant acme + PLATFORM_ADMIN, no exemption, names rule, roster file, actor" do
      {_p, rp, report} =
        r452_run([r452_scenario("s9", "acme", "actor-acme-bob")], r452_tenant_admin_roster(%{}))

      assert tags(report) == ["SCHEMA-9"]
      assert [v] = report.violations
      assert v.file == rp
      assert v.message =~ "actor-acme-bob"
    end

    test "T-SCHEMA-9-LEGACY -- the legacy_platform_admin exemption silences rule (c)" do
      roster =
        r452_tenant_admin_roster(%{
          "legacy_platform_admin" => %{
            "actor-acme-bob" => %{
              "since" => "2026-10-06",
              "reason" => "no TENANT_ADMIN yet",
              "removed_by" => "REQ-454"
            }
          }
        })

      {_p, _rp, report} = r452_run([r452_scenario("s9l", "acme", "actor-acme-bob")], roster)

      assert report.violations == []
    end

    test "T-SCHEMA-9-PLATFORM -- a platform-tenant PLATFORM_ADMIN is fine" do
      {_p, _rp, report} =
        r452_run([r452_scenario("s9p", "platform", "actor-platform-pat")], r452_roster(%{}))

      assert report.violations == []
    end

    test "T-SCHEMA-12-LEGACY-STALE -- a legacy entry for a non-PLATFORM_ADMIN actor is SCHEMA-12" do
      roster =
        r452_roster(%{
          "legacy_platform_admin" => %{
            "actor-acme-bob" => %{
              "since" => "2026-10-06",
              "reason" => "stale",
              "removed_by" => "REQ-454"
            }
          }
        })

      {_p, rp, report} = r452_run([r452_scenario("s9s", "acme", "actor-acme-bob")], roster)

      assert tags(report) == ["SCHEMA-12"]
      assert hd(report.violations).file == rp
    end
  end

  describe "SCHEMA-10 (rule d) -- platform actor only in scope platform" do
    test "T-SCHEMA-10 -- platform actor in a scope-acme scenario names rule, file, actor" do
      {[path], _rp, report} =
        r452_run([r452_scenario("s10", "acme", "actor-platform-pat")], r452_roster(%{}))

      assert tags(report) == ["SCHEMA-10"]
      assert [v] = report.violations
      assert v.file == path
      assert v.message =~ "actor-platform-pat"
      assert v.message =~ "s10"
    end

    test "T-SCHEMA-10-ALLOWED -- the scenario id in platform_actor_allowed with a reason passes" do
      roster = r452_roster(%{"platform_actor_allowed" => %{"s10a" => "tenant onboarding"}})
      {_p, _rp, report} = r452_run([r452_scenario("s10a", "acme", "actor-platform-pat")], roster)

      assert report.violations == []
    end

    test "T-SCHEMA-10-EMPTY-REASON -- an allowed entry with an empty reason is rejected as SCHEMA-12 (roster fails to load, so cross rules do not run)" do
      roster = r452_roster(%{"platform_actor_allowed" => %{"s10e" => "  "}})
      {_p, _rp, report} = r452_run([r452_scenario("s10e", "acme", "actor-platform-pat")], roster)

      assert tags(report) == ["SCHEMA-12"]
      assert hd(report.violations).message =~ "s10e"
    end
  end

  describe "SCHEMA-11 (rule e) -- every scope needs a refusal step or an exemption" do
    test "T-SCHEMA-11 -- scope with no refusal step names rule, first file, scope" do
      {[path], _rp, report} =
        r452_run(
          [r452_scenario("s11", "acme", "actor-acme-bob", refusal: false)],
          r452_roster(%{})
        )

      assert tags(report) == ["SCHEMA-11"]
      assert [v] = report.violations
      assert v.file == path
      assert v.message =~ "\"acme\""
    end

    test "T-SCHEMA-11-NEG-FLAT -- a flat step with expect_refusal: true covers the scope" do
      {_p, _rp, report} =
        r452_run([r452_scenario("s11f", "acme", "actor-acme-bob")], r452_roster(%{}))

      assert report.violations == []
    end

    test "T-SCHEMA-11-NEG-BRANCH -- a refusal step inside a branch covers the scope" do
      step = %{
        "step" => 1,
        "actor" => "actor-acme-bob",
        "action" => "tries a thing",
        "via" => "gui",
        "expect_refusal" => true
      }

      scenario = %{
        "id" => "s11b",
        "title" => "Branching",
        "version" => "1.0",
        "scope" => "acme",
        "branches" => [
          %{
            "name" => "all",
            "when" => "else",
            "steps" => [step],
            "expected_outcomes" => [%{"id" => "EO-1", "description" => "refused"}]
          }
        ]
      }

      {_p, _rp, report} = r452_run([scenario], r452_roster(%{}))

      assert report.violations == []
    end

    test "T-SCHEMA-11-NEG-EXEMPT -- a scope in refusal_coverage_exempt passes without a refusal step" do
      roster = r452_roster(%{"refusal_coverage_exempt" => ["acme"]})

      {_p, _rp, report} =
        r452_run([r452_scenario("s11e", "acme", "actor-acme-bob", refusal: false)], roster)

      assert report.violations == []
    end

    test "T-SCHEMA-11-ONE-OF-MANY -- one refusal step among several scenarios covers the whole scope" do
      {_p, _rp, report} =
        r452_run(
          [
            r452_scenario("s11m1", "acme", "actor-acme-bob", refusal: false),
            r452_scenario("s11m2", "acme", "actor-acme-bob")
          ],
          r452_roster(%{})
        )

      assert report.violations == []
    end

    test "T-SCHEMA-11-COMPANY-ID -- scope resolved from company_id: is grouped too" do
      scenario =
        r452_scenario("s11c", "x", "actor-acme-bob", refusal: false)
        |> Map.delete("scope")
        |> Map.put("company_id", "acme")

      {_p, _rp, report} = r452_run([scenario], r452_roster(%{}))

      assert tags(report) == ["SCHEMA-11"]
      assert hd(report.violations).message =~ "\"acme\""
    end
  end

  describe "SCHEMA-12 -- structural integrity of roster and expect_refusal" do
    test "T-SCHEMA-12-NON-BOOLEAN -- expect_refusal: \"yes\" is SCHEMA-12 naming the step" do
      data =
        valid_flat(%{"steps" => [Map.put(flat_step(), "expect_refusal", "yes")]})

      violations = check(data)

      assert rules(violations) == ["SCHEMA-12"]
      assert [v] = violations
      assert v.file == @fixture_path
      assert v.message =~ "step 1: expect_refusal must be a boolean"
    end

    test "T-SCHEMA-12-NON-BOOLEAN-BRANCH -- same check inside branches[].steps" do
      step = Map.put(flat_step(), "expect_refusal", 1)

      data =
        valid_branching([
          %{
            "name" => "b",
            "when" => "else",
            "steps" => [step],
            "expected_outcomes" => [flat_outcome()]
          }
        ])

      assert rules(check(data)) == ["SCHEMA-12"]
    end

    test "T-SCHEMA-12-BOOLEAN-OK -- true and false are both accepted" do
      for v <- [true, false] do
        data = valid_flat(%{"steps" => [Map.put(flat_step(), "expect_refusal", v)]})
        assert check(data) == []
      end
    end

    test "T-SCHEMA-12-MISSING-ROSTER -- a missing roster file is one SCHEMA-12 on the roster path, not a crash" do
      dir = tmp_dir()
      missing = Path.join(dir, "nope.yaml")
      path = Path.join(dir, "s.yaml")
      File.write!(path, Jason.encode!(r452_scenario("sm", "acme", "actor-acme-bob")))

      report = Check.check_paths([path], missing, @known_roles)

      assert tags(report) == ["SCHEMA-12"]
      assert [v] = report.violations
      assert v.file == missing
      assert report.actor_stats == :not_loaded
    end

    test "T-SCHEMA-12-EMPTY-ACTORS -- an empty actors: map is SCHEMA-12" do
      {_p, rp, report} =
        r452_run([r452_scenario("se", "acme", "actor-acme-bob")], %{"actors" => %{}})

      assert tags(report) == ["SCHEMA-12"]
      assert Enum.all?(report.violations, &(&1.file == rp))
    end

    test "T-SCHEMA-12-BAD-SINCE -- a legacy_platform_admin since that is not an ISO date is SCHEMA-12" do
      roster =
        r452_tenant_admin_roster(%{
          "legacy_platform_admin" => %{
            "actor-acme-bob" => %{
              "since" => "last tuesday",
              "reason" => "r",
              "removed_by" => "REQ-454"
            }
          }
        })

      {_p, rp, report} = r452_run([r452_scenario("sd", "acme", "actor-acme-bob")], roster)

      assert "SCHEMA-12" in tags(report)
      assert Enum.any?(only(report, "SCHEMA-12"), &(&1.file == rp and &1.message =~ "since"))
    end

    test "T-SCHEMA-12-ENTRY-SHAPE -- an actor with empty builtin_roles or no tenant is SCHEMA-12" do
      roster =
        r452_roster(%{
          "actors" => %{
            "actor-acme-bob" => %{"tenant" => "acme", "builtin_roles" => []},
            "actor-acme-eve" => %{"builtin_roles" => ["TASK_WORKER"]}
          }
        })

      {_p, _rp, report} = r452_run([r452_scenario("sh", "acme", "actor-acme-bob")], roster)

      messages = report |> only("SCHEMA-12") |> Enum.map(& &1.message)
      assert Enum.any?(messages, &(&1 =~ "actor-acme-bob"))
      assert Enum.any?(messages, &(&1 =~ "actor-acme-eve"))
    end

    test "T-SCHEMA-12-UNRESOLVED -- unresolved entry without searches, or also in actors:, is SCHEMA-12" do
      roster =
        r452_roster(%{
          "unresolved" => %{
            "actor-acme-ghost" => %{"searched" => []},
            "actor-acme-bob" => %{"searched" => ["x"]}
          }
        })

      {_p, _rp, report} = r452_run([r452_scenario("su", "acme", "actor-acme-bob")], roster)

      messages = report |> only("SCHEMA-12") |> Enum.map(& &1.message)
      assert Enum.any?(messages, &(&1 =~ "actor-acme-ghost"))
      assert Enum.any?(messages, &(&1 =~ "actor-acme-bob"))
    end

    test "T-SCHEMA-12-ALLOWED-NOT-STRING -- platform_actor_allowed value that is not a string is SCHEMA-12" do
      roster = r452_roster(%{"platform_actor_allowed" => %{"x" => nil}})
      {_p, _rp, report} = r452_run([r452_scenario("sa", "acme", "actor-acme-bob")], roster)

      assert tags(report) == ["SCHEMA-12"]
    end

    test "T-SCHEMA-12-EXEMPT-SHAPE -- refusal_coverage_exempt that is not a list of strings is SCHEMA-12" do
      roster = r452_roster(%{"refusal_coverage_exempt" => "acme"})
      {_p, _rp, report} = r452_run([r452_scenario("sx", "acme", "actor-acme-bob")], roster)

      assert tags(report) == ["SCHEMA-12"]
    end
  end

  describe "render/1 -- actor roster counts" do
    test "T-RENDER-COUNTS -- the Actor roster line carries the three counts" do
      {_p, _rp, report} =
        r452_run([r452_scenario("rc", "acme", "actor-acme-ghost")], r452_roster(%{}))

      out = report |> Check.render() |> IO.iodata_to_binary()

      assert out =~ "Actor roster:"
      assert out =~ "1 login actor(s) in corpus: 0 in roster, 0 unresolved, 1 missing"
    end

    test "T-RENDER-NO-STATS -- a report without actor_stats still renders" do
      report = %{files: [], file_count: 0, violations: []}

      refute IO.iodata_to_binary(Check.render(report)) =~ "Actor roster:"
    end
  end

  describe "refusal_coverage_exempt is frozen to a shrinking subset" do
    test "T-EXEMPT-FROZEN -- the real roster's exempt list is a subset of the frozen initial list" do
      assert {:ok, roster} = Check.read_roster(@live_roster)

      assert MapSet.size(exempt_overflow(roster.refusal_coverage_exempt)) == 0,
             "refusal_coverage_exempt may only shrink; extra scopes: " <>
               inspect(exempt_overflow(roster.refusal_coverage_exempt))
    end

    test "T-EXEMPT-FROZEN-BITES -- a fabricated extra scope is caught by the same helper" do
      assert MapSet.to_list(exempt_overflow(@initial_refusal_exempt ++ ["newscope"])) ==
               ["newscope"]
    end

    test "T-EXEMPT-SHRINK-OK -- a strictly smaller list passes the helper" do
      assert MapSet.size(exempt_overflow(["meridian"])) == 0
    end
  end

  describe "live corpus" do
    test "T-LIVE-ROSTER -- real actors.yaml plus every real scenario passes with no missing actor" do
      paths = @live_glob |> Path.wildcard() |> Enum.sort()
      assert paths != []

      report = Check.check_paths(paths, @live_roster, Check.known_role_names())

      assert report.violations == [], inspect(report.violations)
      stats = report.actor_stats
      assert stats.missing == 0
      assert stats.login_actors == stats.in_roster + stats.unresolved
      assert stats.login_actors > 0
    end
  end
end
