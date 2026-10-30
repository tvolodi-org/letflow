defmodule Letflow.Api.PermissionMatrixTest do
  @moduledoc """
  GH #2586 / REQ-498: the effective-permission golden file, its parser, the
  freshness and classification checks, and the production-list proofs
  (design `lib/letflow/design/gh2586-permission-matrix-golden.md` section 13,
  T1-T33).

  Pure, no DB: almost every case builds in-memory matrices (strings) or calls
  `PermissionMatrix.build/3` with injected functions. The cases that read real
  files or compiled code are T1b, T9, T19, T20, T24, T28, T29; T33 shells out
  to git in a temp repository. None checks out a `Letflow.Repo` connection, so
  `async: true` is safe.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.PermissionMatrix
  alias Letflow.Modules.Catalog
  alias Mix.Tasks.Letflow.PermissionMatrix, as: MatrixTask

  @pa "PLATFORM_ADMIN"
  @ta "TENANT_ADMIN"
  @tw "TASK_WORKER"
  @cand "CANDIDATE"
  @roles [@cand, @pa, @tw, @ta]

  @exam_atoms [
    "ExamCertificateIssue",
    "ExamSessionRead",
    "ExamSessionReportEvent",
    "ExamSessionSave",
    "ExamSessionStart",
    "ExamSessionSubmit"
  ]

  # --- in-memory matrix helpers ----------------------------------------------------------

  # owners: %{perm => owner}; trues: %{{role, perm} => via}. Every (role, perm) pair not in
  # `trues` is a false row.
  defp mx(modules, owners, trues) do
    permissions = owners |> Map.keys() |> Enum.sort()

    rows =
      for role <- @roles, perm <- permissions, into: %{} do
        row =
          case Map.fetch(trues, {role, perm}) do
            {:ok, via} -> %{allowed: true, owner: owners[perm], via: via}
            :error -> %{allowed: false, owner: owners[perm], via: :none}
          end

        {{role, perm}, row}
      end

    %{format: 1, modules: modules, roles: Enum.sort(@roles), permissions: permissions, rows: rows}
  end

  # The baseline every classification case starts from: core atom CoreA (PA/TA via core),
  # module m@1 atom ModX (PA/TA via core, TASK_WORKER via grant).
  defp base_owners, do: %{"CoreA" => :core, "ModX" => {:module, "m"}}

  defp base_trues do
    %{
      {@pa, "CoreA"} => :core,
      {@ta, "CoreA"} => :core,
      {@pa, "ModX"} => :core,
      {@ta, "ModX"} => :core,
      {@tw, "ModX"} => :grant
    }
  end

  defp baseline, do: mx(%{"m" => "1"}, base_owners(), base_trues())

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        core_policy_atoms: MapSet.new(["CoreA"]),
        route_refs: %{"ModX" => ["m"]},
        declarations: %{},
        module_dirs_present: MapSet.new()
      },
      overrides
    )
  end

  # A computed matrix with a new module atom `perm` owned by m (version 2).
  defp with_new_atom(perm, extra_trues) do
    mx(
      %{"m" => "2"},
      Map.put(base_owners(), perm, {:module, "m"}),
      base_trues()
      |> Map.merge(%{{@pa, perm} => :core, {@ta, perm} => :core})
      |> Map.merge(extra_trues)
    )
  end

  defp build!(roles, permissions, opts) do
    inputs =
      Map.merge(
        %{
          allows?: fn _r, _p -> false end,
          core_allows?: fn _r, _p -> false end,
          module_permissions: [],
          modules: %{}
        },
        Map.new(opts)
      )

    {:ok, matrix} = PermissionMatrix.build(roles, permissions, inputs)
    matrix
  end

  defp join(lines), do: Enum.join(lines, "\n") <> "\n"

  defp without_m,
    do: mx(%{}, %{"CoreA" => :core}, Map.take(base_trues(), [{@pa, "CoreA"}, {@ta, "CoreA"}]))

  # --- AC1 ------------------------------------------------------------------------------

  describe "T1 AC1: cardinality with injected roles and permissions" do
    test "8 roles x N permissions gives 8 * N rows and matching header counts" do
      roles = for i <- 1..8, do: :"R#{i}"
      permissions = [:P1, :P2, :P3, :P4, :P5]
      matrix = build!(roles, permissions, allows?: fn r, _p -> r == :R1 end)

      assert map_size(matrix.rows) == 8 * 5
      header = PermissionMatrix.header_lines(matrix)
      assert "# roles: 8" in header
      assert "# permissions: 5" in header
      assert "# rows: 40" in header
    end
  end

  describe "T1b AC1: the committed golden file" do
    test "parses; its permissions are core ++ Exam ++ Procurement, 8 x that many rows, modules exam@version" do
      {:ok, golden} =
        PermissionMatrix.parse(File.read!("priv/permission_matrix/effective.golden"))

      expected =
        (Authorization.core_permissions() ++
           Letflow.Modules.Exam.manifest().permissions ++
           Letflow.Modules.Procurement.manifest().permissions)
        |> Enum.map(&Atom.to_string/1)
        |> Enum.sort()

      assert golden.permissions == expected
      assert length(golden.roles) == 8
      assert map_size(golden.rows) == 8 * length(expected)

      assert golden.modules == %{
               "exam" => Letflow.Modules.Exam.manifest().version,
               "org" => Letflow.Modules.Org.manifest().version,
               "catalog_items" => Letflow.Modules.CatalogItems.manifest().version,
               "procurement" => Letflow.Modules.Procurement.manifest().version,
               "locations" => Letflow.Modules.Locations.manifest().version
             }

      for role <- golden.roles do
        assert golden.rows[{role, "MyModulesRead"}] == %{allowed: true, owner: :core, via: :core}
        assert golden.rows[{role, "MyAccessRead"}] == %{allowed: true, owner: :core, via: :core}
      end
    end
  end

  # --- AC2 ------------------------------------------------------------------------------

  defp production_matrix(extra_perms) do
    owners =
      Map.new(@exam_atoms ++ extra_perms, fn p -> {p, {:module, "exam"}} end)
      |> Map.put("CoreA", :core)

    mx(%{"exam" => "0.1.0"}, owners, %{})
  end

  describe "T2-T4 AC2: check_production_list/3" do
    test "T2: a fixture atom in the matrix fails" do
      matrix = production_matrix(["FixtureRead"])

      assert PermissionMatrix.check_production_list(matrix, MapSet.new(["FixtureRead"]), :dev) ==
               {:error, [{:fixture_atoms_present, ["FixtureRead"]}]}
    end

    test "T3: a matrix lacking the Exam atoms fails" do
      matrix = mx(%{}, %{"CoreA" => :core}, %{})

      assert PermissionMatrix.check_production_list(matrix, MapSet.new(["FixtureRead"]), :dev) ==
               {:error, [{:production_atoms_missing, @exam_atoms}]}
    end

    test "T4: a correct matrix under :test fails with a distinct MIX_ENV=test message" do
      matrix = production_matrix([])

      assert PermissionMatrix.check_production_list(matrix, MapSet.new(["FixtureRead"]), :dev) ==
               :ok

      assert {:error, errors} =
               PermissionMatrix.check_production_list(matrix, MapSet.new(["FixtureRead"]), :test)

      assert {:wrong_env, :test} in errors
      message = PermissionMatrix.describe({:wrong_env, :test})
      assert message =~ "refuses MIX_ENV=test"
      assert message =~ "MIX_ENV=dev mix letflow.permission_matrix --check"
      refute message == PermissionMatrix.describe({:wrong_env, :bench})
    end
  end

  # --- AC3 ------------------------------------------------------------------------------

  describe "T5 AC3: a new module atom with only a route_policies entry" do
    test "exactly PA/TA rows added, classified pre_approved, no failures" do
      computed = with_new_atom("ModNew", %{})
      context = ctx(%{route_refs: %{"ModX" => ["m"], "ModNew" => ["m"]}})

      assert PermissionMatrix.true_set_diff(baseline(), computed) ==
               %{added: [{@pa, "ModNew"}, {@ta, "ModNew"}], removed: []}

      report = PermissionMatrix.classify(baseline(), computed, context)
      assert report.labels == [:pre_approved]
      assert report.failures == []
      assert report.pre_approved == [{@pa, "ModNew", "m"}, {@ta, "ModNew", "m"}]
    end
  end

  # --- AC4 ------------------------------------------------------------------------------

  describe "T6 AC4a: an existing atom granted to a role that lacked it" do
    test "another module's existing atom gained via grant is a :module_grant widening" do
      computed = mx(%{"m" => "2"}, base_owners(), Map.put(base_trues(), {@cand, "ModX"}, :grant))
      report = PermissionMatrix.classify(baseline(), computed, ctx())

      assert report.failures == [{:widening, @cand, "ModX", :module_grant}]
    end
  end

  describe "T7 AC4b: a new atom granted to a role other than PA/TA" do
    test "via grant: the CANDIDATE row fails, PA/TA stay pre-approved" do
      computed = with_new_atom("ModNew", %{{@cand, "ModNew"} => :grant})
      context = ctx(%{route_refs: %{"ModX" => ["m"], "ModNew" => ["m"]}})
      report = PermissionMatrix.classify(baseline(), computed, context)

      assert report.failures == [{:widening, @cand, "ModNew", :module_grant}]
      assert report.pre_approved == [{@pa, "ModNew", "m"}, {@ta, "ModNew", "m"}]
    end

    test "via core: :new_atom_non_admin_role" do
      computed = with_new_atom("ModNew", %{{@cand, "ModNew"} => :core})
      context = ctx(%{route_refs: %{"ModX" => ["m"], "ModNew" => ["m"]}})
      report = PermissionMatrix.classify(baseline(), computed, context)

      assert report.failures == [{:widening, @cand, "ModNew", :new_atom_non_admin_role}]
    end
  end

  describe "T8 AC4c: atoms referenced by a core route policy, or not owned by one module's routes" do
    test "(i) a via-grant row on a core policy atom is :core_policy_atom" do
      computed = mx(%{"m" => "1"}, base_owners(), Map.put(base_trues(), {@tw, "CoreA"}, :grant))
      report = PermissionMatrix.classify(baseline(), computed, ctx())

      assert report.failures == [{:widening, @tw, "CoreA", :core_policy_atom}]
    end

    test "(ii) a new module atom in core_policy_atoms is never pre-approved (injected context)" do
      computed = with_new_atom("ModNew", %{})

      context =
        ctx(%{
          core_policy_atoms: MapSet.new(["CoreA", "ModNew"]),
          route_refs: %{"ModX" => ["m"], "ModNew" => ["m"]}
        })

      report = PermissionMatrix.classify(baseline(), computed, context)

      assert report.failures == [
               {:widening, @pa, "ModNew", :core_policy_atom},
               {:widening, @ta, "ModNew", :core_policy_atom}
             ]

      assert report.pre_approved == []
    end

    test "(iii) a new atom also named in another module's route_policies" do
      computed = with_new_atom("ModNew", %{})
      context = ctx(%{route_refs: %{"ModX" => ["m"], "ModNew" => ["m", "other"]}})
      report = PermissionMatrix.classify(baseline(), computed, context)

      assert report.failures == [
               {:widening, @pa, "ModNew", :referenced_by_other_module},
               {:widening, @ta, "ModNew", :referenced_by_other_module}
             ]
    end

    test "(iv) a new atom the owner's route_policies do not name is :not_routed_by_owner" do
      computed = with_new_atom("ModNew", %{})

      for refs <- [%{"ModX" => ["m"]}, %{"ModX" => ["m"], "ModNew" => []}] do
        report = PermissionMatrix.classify(baseline(), computed, ctx(%{route_refs: refs}))

        assert report.failures == [
                 {:widening, @pa, "ModNew", :not_routed_by_owner},
                 {:widening, @ta, "ModNew", :not_routed_by_owner}
               ]

        assert report.pre_approved == []
      end
    end
  end

  # --- T9 fixture scan --------------------------------------------------------------------

  describe "T9 AC2: fixture_permissions/1" do
    test "the scan of the real test/support/modules sources is a superset of the fixtures' atoms" do
      sources =
        "test/support/modules/**/*.{ex,exs}"
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&{&1, File.read!(&1)})

      assert {:ok, scanned} = PermissionMatrix.fixture_permissions(sources)

      union =
        (Catalog.entry_modules() -- [Letflow.Modules.Exam, Letflow.Modules.Procurement])
        |> Enum.flat_map(& &1.manifest().permissions)
        |> MapSet.new(&Atom.to_string/1)

      assert MapSet.size(union) > 0
      assert MapSet.subset?(union, scanned)
    end

    test "a non-literal permissions value is unscannable, with its line" do
      source = """
      defmodule X do
        @perms [:A]
        def manifest, do: %{
          permissions: @perms
        }
      end
      """

      assert PermissionMatrix.fixture_permissions([{"x.ex", source}]) ==
               {:error, {:unscannable_fixture_manifest, "x.ex", 4}}
    end

    test "literal lists in keyword and map form are collected" do
      source =
        "defmodule Y do\n  def a, do: [permissions: [:A, :B]]\n  def b, do: %{permissions: [:C]}\nend\n"

      assert PermissionMatrix.fixture_permissions([{"y.ex", source}]) ==
               {:ok, MapSet.new(["A", "B", "C"])}
    end

    test "no sources and an unparsable source are errors" do
      assert PermissionMatrix.fixture_permissions([]) == {:error, :no_fixture_sources}

      assert PermissionMatrix.fixture_permissions([{"z.ex", "defmodule Z do"}]) ==
               {:error, {:fixture_parse_error, "z.ex"}}
    end
  end

  # --- AC5 ------------------------------------------------------------------------------

  describe "T10-T11 AC5: non-circumvention" do
    test "T10: a module widening with the golden regenerated in the same change still fails" do
      computed = mx(%{"m" => "2"}, base_owners(), Map.put(base_trues(), {@cand, "ModX"}, :grant))
      regenerated_golden = computed

      assert PermissionMatrix.freshness(regenerated_golden, computed) == :ok

      assert PermissionMatrix.classify(baseline(), computed, ctx()).failures == [
               {:widening, @cand, "ModX", :module_grant}
             ]
    end

    test "T11: a core-only change with a regenerated golden passes and is reported as a core change" do
      computed =
        mx(
          %{"m" => "1"},
          Map.put(base_owners(), "CoreK", :core),
          Map.merge(base_trues(), %{{@pa, "CoreK"} => :core, {@ta, "CoreK"} => :core})
        )

      assert PermissionMatrix.freshness(computed, computed) == :ok
      report = PermissionMatrix.classify(baseline(), computed, ctx())

      assert report.failures == []
      assert report.labels == [:core_change]
      assert report.core_changes == [{:added, @pa, "CoreK"}, {:added, @ta, "CoreK"}]

      assert PermissionMatrix.format_report(report) =~
               ~r/\ACORE MATRIX CHANGE: mandatory SECURITY-REVIEWER trigger/
    end
  end

  describe "check_result/4 (TDV F1): golden -> freshness only, git baseline -> classification only" do
    test "a module widening with the golden regenerated to match still fails against the baseline" do
      computed = mx(%{"m" => "2"}, base_owners(), Map.put(base_trues(), {@cand, "ModX"}, :grant))
      regenerated_golden = computed

      result = PermissionMatrix.check_result(regenerated_golden, baseline(), computed, ctx())

      assert result.failures == [{:widening, @cand, "ModX", :module_grant}]
      assert result.report.failures == [{:widening, @cand, "ModX", :module_grant}]
    end

    test "an unchanged matrix passes; a stale golden fails freshness even with a clean baseline" do
      assert PermissionMatrix.check_result(baseline(), baseline(), baseline(), ctx()).failures ==
               []

      stale = mx(%{"m" => "1"}, base_owners(), Map.delete(base_trues(), {@tw, "ModX"}))

      assert [{:golden_stale, %{added: ["TASK_WORKER ModX true module:m grant"]}}] =
               PermissionMatrix.check_result(stale, baseline(), baseline(), ctx()).failures
    end

    test "an unreadable golden is carried through; :absent is the bootstrap classification" do
      result =
        PermissionMatrix.check_result(
          {:error, {:golden_missing, "x", :enoent}},
          :absent,
          baseline(),
          ctx()
        )

      assert result.failures == [{:golden_missing, "x", :enoent}]
      assert result.report.labels == [:bootstrap]
    end
  end

  describe "REVIEWER F4: switch combinations" do
    test "--write with --baseline-ref, and --check with --write, are refused before any work" do
      assert_raise Mix.Error, ~r/--baseline-ref applies to --check only/, fn ->
        MatrixTask.run(["--write", "--baseline-ref", "HEAD~1"])
      end

      assert_raise Mix.Error, ~r/pass --check or --write, not both/, fn ->
        MatrixTask.run(["--check", "--write"])
      end
    end
  end

  describe "SEC F2: a via change alone is a core change" do
    test "grant -> core on a row true on both sides is {:via_changed, ...} with the banner" do
      computed = mx(%{"m" => "1"}, base_owners(), Map.put(base_trues(), {@tw, "ModX"}, :core))
      report = PermissionMatrix.classify(baseline(), computed, ctx())

      assert report.failures == []
      assert report.labels == [:core_change]
      assert report.core_changes == [{:via_changed, @tw, "ModX", :grant, :core}]
      text = PermissionMatrix.format_report(report)
      assert text =~ ~r/\ACORE MATRIX CHANGE: mandatory SECURITY-REVIEWER trigger/
      assert text =~ "via of TASK_WORKER ModX: grant -> core"

      back = PermissionMatrix.classify(computed, baseline(), ctx())
      assert back.core_changes == [{:via_changed, @tw, "ModX", :core, :grant}]
    end
  end

  describe "REVIEWER F1: context_from_manifests/2 never crashes on a malformed widens_grants" do
    test "a non-list counts as [], a non-{atom, atom} entry is skipped" do
      manifest = fn id, widens ->
        %{id: id, route_policies: [{"GET", "/x", :ModX}], widens_grants: widens}
      end

      context =
        PermissionMatrix.context_from_manifests(
          [
            manifest.("bad", :not_a_list),
            manifest.("mixed", ["x", {:TASK_WORKER, :A}, {"R", :B}])
          ],
          MapSet.new()
        )

      assert context.declarations == %{"bad" => [], "mixed" => [{"TASK_WORKER", "A"}]}
      assert context.route_refs == %{"ModX" => ["bad", "mixed"]}
    end
  end

  # --- AC6 / AC7 ------------------------------------------------------------------------

  defp narrowed(version),
    do: mx(%{"m" => version}, base_owners(), Map.delete(base_trues(), {@tw, "ModX"}))

  describe "T12-T16 AC6/AC7: narrowing declarations, both directions" do
    test "T12: a narrowing without a declaration fails" do
      report = PermissionMatrix.classify(baseline(), narrowed("2"), ctx())
      assert report.failures == [{:unmatched_narrowing, @tw, "ModX", "m"}]
    end

    test "T13: an exact declaration matches it" do
      report =
        PermissionMatrix.classify(
          baseline(),
          narrowed("2"),
          ctx(%{declarations: %{"m" => [{@tw, "ModX"}]}})
        )

      assert report.failures == []
      assert report.labels == [:narrowing]
      assert report.narrowings == [{@tw, "ModX", "m"}]
    end

    test "T13b: a declaration from a different module does not match" do
      report =
        PermissionMatrix.classify(
          baseline(),
          mx(%{"m" => "2", "n" => "1"}, base_owners(), Map.delete(base_trues(), {@tw, "ModX"})),
          ctx(%{declarations: %{"n" => [{@tw, "ModX"}]}})
        )

      assert report.failures == [
               {:unmatched_declaration, "n", @tw, "ModX"},
               {:unmatched_narrowing, @tw, "ModX", "m"}
             ]
    end

    test "T14: a declaration that matches no diff row fails" do
      computed = mx(%{"m" => "2"}, base_owners(), base_trues())

      report =
        PermissionMatrix.classify(
          baseline(),
          computed,
          ctx(%{declarations: %{"m" => [{@cand, "ModX"}]}})
        )

      assert report.failures == [{:unmatched_declaration, "m", @cand, "ModX"}]
    end

    test "T15: with an unchanged version a declaration is inert, and a narrowing says to bump the version" do
      unchanged = mx(%{"m" => "1"}, base_owners(), base_trues())

      report =
        PermissionMatrix.classify(
          baseline(),
          unchanged,
          ctx(%{declarations: %{"m" => [{@cand, "ModX"}]}})
        )

      assert report.failures == []
      assert report.inert_declarations == [{"m", @cand, "ModX"}]

      narrowing_report = PermissionMatrix.classify(baseline(), narrowed("1"), ctx())
      assert narrowing_report.failures == [{:unmatched_narrowing, @tw, "ModX", "m"}]

      assert PermissionMatrix.format_report(narrowing_report) =~
               "bump the module version and declare it in `widens_grants`"

      bumped_text =
        PermissionMatrix.format_report(
          PermissionMatrix.classify(baseline(), narrowed("2"), ctx())
        )

      refute bumped_text =~ "bump the module version"
    end

    test "T16 AC7: a declaration naming a widening row is refused, also with an unchanged version" do
      for version <- ["1", "2"] do
        computed =
          mx(%{"m" => version}, base_owners(), Map.put(base_trues(), {@cand, "ModX"}, :grant))

        report =
          PermissionMatrix.classify(
            baseline(),
            computed,
            ctx(%{declarations: %{"m" => [{@cand, "ModX"}]}})
          )

        assert report.failures == [
                 {:declaration_authorises_widening, "m", @cand, "ModX"},
                 {:widening, @cand, "ModX", :module_grant}
               ]

        assert report.narrowings == []
      end
    end
  end

  # --- AC10 / AC11 ----------------------------------------------------------------------

  describe "T17 AC10: a core change without regenerating the golden is stale" do
    test "an injected atom absent from the golden, and a flipped core_allows? for one role" do
      roles = [:PLATFORM_ADMIN, :TASK_WORKER]
      allows? = fn r, _p -> r == :PLATFORM_ADMIN end
      golden = build!(roles, [:A, :B], allows?: allows?, core_allows?: allows?)
      with_k = build!(roles, [:A, :B, :K], allows?: allows?, core_allows?: allows?)

      assert {:error, {:golden_stale, stale}} = PermissionMatrix.freshness(golden, with_k)
      assert stale.added == ["PLATFORM_ADMIN K true core core", "TASK_WORKER K false core -"]
      assert stale.removed == []

      flipped =
        build!(roles, [:A, :B],
          allows?: allows?,
          core_allows?: fn r, p -> r == :PLATFORM_ADMIN and p != :A end
        )

      assert {:error, {:golden_stale, stale}} = PermissionMatrix.freshness(golden, flipped)
      assert stale.added == ["PLATFORM_ADMIN A true core grant"]
      assert stale.removed == ["PLATFORM_ADMIN A true core core"]
    end
  end

  describe "T18 AC11: --write output is deterministic" do
    test "shuffled inputs render identically, sorted, LF only, one trailing LF, round-trips" do
      roles = [:TENANT_ADMIN, :CANDIDATE, :PLATFORM_ADMIN]
      permissions = [:Zed, :Alpha, :Mod1, :Beta]

      opts = [
        allows?: fn r, p -> r == :PLATFORM_ADMIN or p == :Mod1 end,
        core_allows?: fn r, _p -> r == :PLATFORM_ADMIN end,
        module_permissions: [{"mod", [:Mod1]}],
        modules: %{"mod" => "1.0.0"}
      ]

      one = PermissionMatrix.render(build!(roles, permissions, opts))
      two = PermissionMatrix.render(build!(Enum.reverse(roles), Enum.shuffle(permissions), opts))

      assert one == two
      refute one =~ "\r"
      assert String.ends_with?(one, "\n")
      refute String.ends_with?(one, "\n\n")

      data = one |> String.split("\n", trim: true) |> Enum.drop(8)
      keys = Enum.map(data, fn line -> line |> String.split(" ") |> Enum.take(2) end)
      assert keys == Enum.sort(keys)
      assert hd(data) == "CANDIDATE Alpha false core -"
      assert "CANDIDATE Mod1 true module:mod grant" in data

      {:ok, parsed} = PermissionMatrix.parse(one)
      assert PermissionMatrix.render(parsed) == one
    end
  end

  # --- D7 / section 3 -------------------------------------------------------------------

  describe "T19 D7: every core route policy resolves to a core permission" do
    test "required_permission/1 maps every endpoint_policy_key atom (minus the markers) into core_permissions/0" do
      {:ok, types} = Code.Typespec.fetch_types(Authorization)

      [members] =
        for {:type, {:endpoint_policy_key, {:type, _, :union, members}, []}} <- types, do: members

      keys =
        for {:atom, _, key} <- members,
            key not in [:UnmatchedPlatformPath, :UnmatchedRoute],
            do: key

      assert length(keys) > 40
      core = Authorization.core_permissions()

      for key <- keys do
        assert Authorization.required_permission(key) in core,
               "#{inspect(key)} resolves to #{inspect(Authorization.required_permission(key))}, not a core permission"
      end
    end
  end

  describe "T20: role_allows_without_module_grants?/2" do
    test "role_allows?/2 == without-grants OR Catalog.role_grants/1, for every pair" do
      for role <- Authorization.roles(), perm <- Authorization.permissions() do
        assert Authorization.role_allows?(role, perm) ==
                 (Authorization.role_allows_without_module_grants?(role, perm) or
                    perm in Catalog.role_grants(role)),
               "#{role} #{perm}"
      end

      for role <- Authorization.roles() do
        assert Authorization.role_allows_without_module_grants?(role, :MyModulesRead)
      end

      # The fixture grant is the one row only role_grants makes true in the test env.
      assert Authorization.role_allows?(:TASK_WORKER, :FixtureRead)
      refute Authorization.role_allows_without_module_grants?(:TASK_WORKER, :FixtureRead)
    end
  end

  # --- T21 parse errors -----------------------------------------------------------------

  describe "T21 section 2.2: parse/1 is strict" do
    setup do
      text =
        PermissionMatrix.render(
          build!([:PLATFORM_ADMIN, :TASK_WORKER], [:A, :B],
            allows?: fn r, _p -> r == :PLATFORM_ADMIN end,
            core_allows?: fn _r, _p -> true end
          )
        )

      %{text: text, lines: String.split(text, "\n", trim: true)}
    end

    test "format 2 is unsupported", %{lines: lines} do
      assert PermissionMatrix.parse(join(List.replace_at(lines, 1, "# format: 2"))) ==
               {:error, {:unsupported_format, "2"}}
    end

    test "a missing header line is malformed", %{lines: lines} do
      assert PermissionMatrix.parse(join(List.delete_at(lines, 2))) ==
               {:error, {:malformed_header, 3}}
    end

    test "a 4-field row and `false core` are malformed rows", %{lines: lines} do
      assert PermissionMatrix.parse(join(List.replace_at(lines, 8, "PLATFORM_ADMIN A true core"))) ==
               {:error, {:malformed_row, 9}}

      assert PermissionMatrix.parse(
               join(List.replace_at(lines, 8, "PLATFORM_ADMIN A false core core"))
             ) ==
               {:error, {:malformed_row, 9}}

      assert PermissionMatrix.parse(
               join(List.replace_at(lines, 8, "PLATFORM_ADMIN A true core -"))
             ) ==
               {:error, {:malformed_row, 9}}
    end

    test "a duplicate row and a count mismatch", %{lines: lines} do
      duplicate = List.replace_at(lines, 9, Enum.at(lines, 8))

      assert {:error, {:duplicate_row, "PLATFORM_ADMIN", "A"}} =
               PermissionMatrix.parse(join(duplicate))

      assert {:error, {:count_mismatch, 4, 3}} =
               PermissionMatrix.parse(join(List.delete_at(lines, -1)))
    end

    test "CRLF input parses equal to LF input", %{text: text} do
      assert PermissionMatrix.parse(String.replace(text, "\n", "\r\n")) ==
               PermissionMatrix.parse(text)
    end
  end

  describe "T22 D18: bootstrap_allowed?/2" do
    test "only when the base commit lacks both the golden and the task" do
      assert PermissionMatrix.bootstrap_allowed?(false, false)
      refute PermissionMatrix.bootstrap_allowed?(false, true)
    end

    test "classify(:absent, ...) is the bootstrap report" do
      report = PermissionMatrix.classify(:absent, baseline(), ctx())
      assert report.labels == [:bootstrap]
      assert report.failures == []
    end
  end

  describe "T23 section 4.3 step 4: module removal" do
    test "a removed module whose directory is gone is a core change, not a failure" do
      report = PermissionMatrix.classify(baseline(), without_m(), ctx())
      assert report.failures == []
      assert report.core_changes == [{:module_removed, "m"}]
      assert report.labels == [:core_change]
    end

    test "a module dropped from the list while its directory remains fails" do
      report =
        PermissionMatrix.classify(
          baseline(),
          without_m(),
          ctx(%{module_dirs_present: MapSet.new(["m"])})
        )

      assert report.failures == [{:module_unregistered_but_present, "m"}]
    end

    test "a core rule that stops granting a kept module atom is a core change, not a narrowing" do
      computed = mx(%{"m" => "1"}, base_owners(), Map.delete(base_trues(), {@ta, "ModX"}))
      report = PermissionMatrix.classify(baseline(), computed, ctx())

      assert report.failures == []
      assert report.core_changes == [{:removed, @ta, "ModX"}]
    end
  end

  # --- AC9 / F2: textual pins on ci.yml and mix.exs ------------------------------------

  describe "T24 AC9: the CI step" do
    test "backend_static runs the dev-env check with the marker greps; shared caches keep _build/dev" do
      ci = ".github/workflows/ci.yml" |> File.read!() |> String.replace("\r\n", "\n")

      [_, static_job] = String.split(ci, "\n  backend_static:\n", parts: 2)
      [static_job, shard_job] = String.split(static_job, "\n  backend_shard:\n", parts: 2)

      step_name = "- name: Effective permission matrix (MIX_ENV=dev, production module list)"
      [_, step] = String.split(static_job, step_name, parts: 2)

      step = step |> String.split("\n      - name: ") |> hd()

      assert step =~ "MIX_ENV: dev"
      assert step =~ "mix letflow.permission_matrix --check --baseline-ref"
      assert step =~ "grep -q '^# modules: '"
      assert step =~ "PERMISSION-MATRIX-REPORT v1 baseline=$ref_sha head=$head_sha"
      assert step =~ "ref_sha=$(git rev-parse --verify"
      assert step =~ "head_sha=$(git rev-parse HEAD)"
      refute step =~ "MIX_ENV: test"

      assert static_job =~ "key: ${{ runner.os }}-mix-dev-${{ hashFiles('mix.lock') }}"

      # The shared caches deliberately keep _build/dev: the remaining MIX_ENV=dev subprocess
      # tests (GH #2611) need a warm dev build; excluding it made them time out on #2612.
      for job <- [static_job, shard_job] do
        assert job =~ "            deps\n            _build\n          key:"
        refute job =~ "!_build/dev"
      end
    end

    test "mix.exs @check_static_steps does not contain the task" do
      steps = mix_exs_attribute(:check_static_steps)
      assert is_list(steps) and steps != []
      refute "letflow.permission_matrix" in steps
      refute Enum.any?(steps, &(is_binary(&1) and &1 =~ "permission_matrix"))
    end
  end

  describe "T29 F2 d: no alias shadows the task" do
    test "aliases/0 has no letflow.permission_matrix key and preferred_envs does not pin it to :test" do
      {:ok, ast} = Code.string_to_quoted(File.read!("mix.exs"))

      alias_keys =
        collect(ast, fn
          {:defp, _, [{:aliases, _, _}, [do: list]]} when is_list(list) ->
            for {key, _} <- list, do: key

          _ ->
            nil
        end)

      assert alias_keys != []
      refute :"letflow.permission_matrix" in alias_keys
      refute "letflow.permission_matrix" in alias_keys

      preferred =
        collect(ast, fn
          {:preferred_envs, list} when is_list(list) -> for {key, value} <- list, do: {key, value}
          _ -> nil
        end)

      assert preferred != []

      refute Enum.any?(preferred, fn {key, _} -> to_string(key) == "letflow.permission_matrix" end)
    end
  end

  defp mix_exs_attribute(name) do
    {:ok, ast} = Code.string_to_quoted(File.read!("mix.exs"))

    [value] =
      collect(ast, fn
        {:@, _, [{^name, _, [value]}]} -> [value]
        _ -> nil
      end)

    value
  end

  defp collect(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          found -> {node, acc ++ found}
        end
      end)

    acc
  end

  # --- F1: module-list proof -------------------------------------------------------------

  @clean_sources [
    {"config/config.exs", "import Config\nconfig :letflow, :modules, [Letflow.Modules.Exam]\n"},
    {"config/dev.exs",
     "import Config\nconfig :letflow, start_http: true, http_port: 4000\nconfig :letflow, Letflow.Repo, pool_size: 30\n"},
    {"config/test.exs",
     "import Config\nconfig :letflow, :modules, [Letflow.Modules.Exam, Fixture]\n"}
  ]

  describe "T25-T27 F1: check_module_list/3" do
    test "T25: equal prod/dev/compiled lists and clean sources pass" do
      exam = Letflow.Modules.Exam

      assert PermissionMatrix.check_module_list(
               [exam],
               %{prod: [exam], dev: [exam]},
               @clean_sources
             ) == :ok
    end

    test "T26: a prod or dev list that differs from the compiled one fails, order included" do
      exam = Letflow.Modules.Exam

      assert PermissionMatrix.check_module_list(
               [exam],
               %{prod: [exam, NewMod], dev: [exam]},
               @clean_sources
             ) ==
               {:error, [{:config_modules_mismatch, :prod, [exam, NewMod], [exam]}]}

      assert PermissionMatrix.check_module_list(
               [exam],
               %{prod: [exam], dev: [exam, NewMod]},
               @clean_sources
             ) ==
               {:error, [{:config_modules_mismatch, :dev, [exam, NewMod], [exam]}]}

      assert PermissionMatrix.check_module_list(
               [exam, B],
               %{prod: [B, exam], dev: [exam, B]},
               @clean_sources
             ) ==
               {:error, [{:config_modules_mismatch, :prod, [B, exam], [exam, B]}]}
    end

    test "T27: a :modules setting outside config.exs/test.exs is refused; unparsable sources too" do
      exam = Letflow.Modules.Exam
      ok = %{prod: [exam], dev: [exam]}

      prod = {"config/prod.exs", "import Config\n\nconfig :letflow, :modules, [X]\n"}

      assert PermissionMatrix.check_module_list([exam], ok, @clean_sources ++ [prod]) ==
               {:error, [{:modules_set_outside_allowed_files, "config/prod.exs", 3}]}

      runtime = {"config/runtime.exs", "import Config\nconfig :letflow, modules: [X], other: 1\n"}

      assert PermissionMatrix.check_module_list([exam], ok, [runtime]) ==
               {:error, [{:modules_set_outside_allowed_files, "config/runtime.exs", 2}]}

      qualified = {"config/prod.exs", "Config.config(:letflow, :modules, [X])\n"}

      assert PermissionMatrix.check_module_list([exam], ok, [qualified]) ==
               {:error, [{:modules_set_outside_allowed_files, "config/prod.exs", 1}]}

      for key_source <- ["key", "String.to_atom(\"modules\")"] do
        computed_key = {"config/prod.exs", "import Config\nconfig :letflow, #{key_source}, [X]\n"}

        assert PermissionMatrix.check_module_list([exam], ok, [computed_key]) ==
                 {:error, [{:modules_set_outside_allowed_files, "config/prod.exs", 2}]},
               key_source
      end

      alias_key =
        {"config/prod.exs", "import Config\nconfig :letflow, Letflow.Repo, pool_size: 1\n"}

      assert PermissionMatrix.check_module_list([exam], ok, [alias_key]) == :ok

      non_literal = {"config/prod.exs", "import Config\nconfig :letflow, opts\n"}

      assert PermissionMatrix.check_module_list([exam], ok, [non_literal]) ==
               {:error, [{:modules_set_outside_allowed_files, "config/prod.exs", 2}]}

      for allowed <- ["config/config.exs", "config/test.exs"] do
        assert PermissionMatrix.check_module_list([exam], ok, [{allowed, elem(prod, 1)}]) == :ok
      end

      assert PermissionMatrix.check_module_list([exam], ok, [
               {"config/dev.exs", "config :letflow, ["}
             ]) ==
               {:error, [{:unscannable_config, "config/dev.exs"}]}
    end
  end

  describe "T28 F1: the real config files" do
    test "the source scan passes and the :prod config list is [Exam, Org, CatalogItems, Procurement, Locations]" do
      sources =
        "config/*.exs" |> Path.wildcard() |> Enum.sort() |> Enum.map(&{&1, File.read!(&1)})

      assert length(sources) >= 5

      prod_modules =
        "config/config.exs" |> Config.Reader.read!(env: :prod) |> get_in([:letflow, :modules])

      assert prod_modules == [
               Letflow.Modules.Exam,
               Letflow.Modules.Org,
               Letflow.Modules.CatalogItems,
               Letflow.Modules.Procurement,
               Letflow.Modules.Locations
             ]

      # The :dev read is done by the CI step itself: config/dev.exs raises when
      # MIX_TEST_PARTITION is set, which scripts/test_parallel.sh sets.
      modules = [
        Letflow.Modules.Exam,
        Letflow.Modules.Org,
        Letflow.Modules.CatalogItems,
        Letflow.Modules.Procurement,
        Letflow.Modules.Locations
      ]

      assert PermissionMatrix.check_module_list(
               modules,
               %{prod: prod_modules, dev: modules},
               sources
             ) ==
               :ok
    end
  end

  # --- F3 / F4 --------------------------------------------------------------------------

  describe "T30 F3: a core rule granting a module atom to a non-admin role" do
    test "is refused as :core_rule_on_module_atom; a core atom flipping true is a core change" do
      computed = mx(%{"m" => "1"}, base_owners(), Map.put(base_trues(), {@cand, "ModX"}, :core))
      report = PermissionMatrix.classify(baseline(), computed, ctx())
      assert report.failures == [{:widening, @cand, "ModX", :core_rule_on_module_atom}]

      core_flip = mx(%{"m" => "1"}, base_owners(), Map.put(base_trues(), {@tw, "CoreA"}, :core))
      report = PermissionMatrix.classify(baseline(), core_flip, ctx())
      assert report.failures == []
      assert report.core_changes == [{:added, @tw, "CoreA"}]
    end

    test "an existing module atom newly true for TENANT_ADMIN via core is a core change" do
      base = mx(%{"m" => "1"}, base_owners(), Map.delete(base_trues(), {@ta, "ModX"}))
      report = PermissionMatrix.classify(base, baseline(), ctx())
      assert report.failures == []
      assert report.core_changes == [{:added, @ta, "ModX"}]
    end
  end

  describe "T31 F4: a core atom that was granted by a module" do
    test "its narrowing is unattributable and no declaration matches it" do
      base = mx(%{"m" => "1"}, base_owners(), Map.put(base_trues(), {@tw, "CoreA"}, :grant))
      computed = mx(%{"m" => "2"}, base_owners(), base_trues())

      report =
        PermissionMatrix.classify(
          base,
          computed,
          ctx(%{declarations: %{"m" => [{@tw, "CoreA"}]}})
        )

      assert report.failures == [
               {:unattributable_narrowing, @tw, "CoreA"},
               {:unmatched_declaration, "m", @tw, "CoreA"}
             ]

      assert report.narrowings == []
    end
  end

  describe "T32 F4: one atom declared by two modules" do
    test "build/3 reads the raw per-manifest lists" do
      inputs = %{
        allows?: fn _, _ -> true end,
        core_allows?: fn _, _ -> true end,
        module_permissions: [{"b", [:X]}, {"a", [:X, :Y]}],
        modules: %{"a" => "1", "b" => "1"}
      }

      assert PermissionMatrix.build([:PLATFORM_ADMIN], [:X, :Y], inputs) ==
               {:error, {:duplicate_module_permission, :X, ["a", "b"]}}

      assert PermissionMatrix.build([:PLATFORM_ADMIN], [:X, :X], %{
               inputs
               | module_permissions: []
             }) ==
               {:error, {:duplicate_permission, :X}}
    end

    test "owner and via come from the raw lists and core_allows?" do
      matrix =
        build!([:PLATFORM_ADMIN, :TASK_WORKER], [:Core, :X],
          allows?: fn r, p -> r == :PLATFORM_ADMIN or p == :X end,
          core_allows?: fn r, _ -> r == :PLATFORM_ADMIN end,
          module_permissions: [{"a", [:X]}],
          modules: %{"a" => "1"}
        )

      assert matrix.rows[{"TASK_WORKER", "X"}] == %{
               allowed: true,
               owner: {:module, "a"},
               via: :grant
             }

      assert matrix.rows[{"PLATFORM_ADMIN", "X"}] == %{
               allowed: true,
               owner: {:module, "a"},
               via: :core
             }

      assert matrix.rows[{"TASK_WORKER", "Core"}] == %{allowed: false, owner: :core, via: :none}
    end
  end

  # --- F2 b/c, SEC R1 -------------------------------------------------------------------

  describe "T33 F2 b, F2 c, SEC R1: the baseline ref and the marker" do
    test "check_baseline_ref/4" do
      s = String.duplicate("a", 40)
      h = String.duplicate("b", 40)

      assert PermissionMatrix.check_baseline_ref(s, s, 1, true) == {:error, :baseline_is_head}
      assert PermissionMatrix.check_baseline_ref(s, s, 2, true) == {:error, :baseline_is_head}

      assert PermissionMatrix.check_baseline_ref(s, h, 1, false) ==
               {:error, :baseline_not_ancestor}

      assert PermissionMatrix.check_baseline_ref(s, h, 1, true) == :ok

      assert PermissionMatrix.check_baseline_ref(s, h, 2, false) ==
               {:error, :baseline_not_ancestor}

      assert PermissionMatrix.check_baseline_ref(s, h, 2, true) == :ok
      assert PermissionMatrix.baseline_anchor(2) == "HEAD^1"
      assert PermissionMatrix.baseline_anchor(1) == "HEAD"
    end

    test "in a real --no-ff merge the task rejects HEAD^2 (the PR tip) and HEAD, accepts HEAD^1" do
      # Short path: the generated tmp_dir embeds the whole test name and overflows
      # git's path limit on Windows checkouts.
      dir = Path.join(System.tmp_dir!(), "pm_merge_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      git = fn args ->
        {out, 0} =
          System.cmd("git", args,
            cd: dir,
            stderr_to_stdout: true,
            env: [{"GIT_DIR", nil}, {"GIT_INDEX_FILE", nil}, {"GIT_WORK_TREE", nil}]
          )

        String.trim(out)
      end

      commit = fn name ->
        File.write!(Path.join(dir, name), name)
        git.(["add", name])

        git.([
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@example.invalid",
          "-c",
          "commit.gpgsign=false",
          "commit",
          "-q",
          "-m",
          name
        ])
      end

      git.(["init", "-q"])
      git.(["symbolic-ref", "HEAD", "refs/heads/main"])
      commit.("base")
      git.(["branch", "pr"])
      commit.("main2")
      git.(["checkout", "-q", "pr"])
      commit.("pr1")
      git.(["checkout", "-q", "main"])

      git.([
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "merge",
        "-q",
        "--no-ff",
        "-m",
        "merge",
        "pr"
      ])

      p1 = git.(["rev-parse", "HEAD^1"])
      head = git.(["rev-parse", "HEAD"])

      assert MatrixTask.resolve_baseline("HEAD^2", dir) ==
               {:error, {:baseline_not_ancestor, "HEAD^2"}}

      assert MatrixTask.resolve_baseline("HEAD", dir) == {:error, {:baseline_is_head, "HEAD"}}

      assert MatrixTask.resolve_baseline("HEAD^1", dir) ==
               {:ok, %{ref: "HEAD^1", ref_sha: p1, head_sha: head}}

      assert {:error, {:baseline_unavailable, "no-such-ref", _}} =
               MatrixTask.resolve_baseline("no-such-ref", dir)
    end

    test "report_marker/3 renders exactly the pass line" do
      a = String.duplicate("a", 40)
      h = String.duplicate("b", 40)
      empty = PermissionMatrix.classify(baseline(), baseline(), ctx())

      assert PermissionMatrix.report_marker(a, h, empty) ==
               "PERMISSION-MATRIX-REPORT v1 baseline=#{a} head=#{h} labels=- result=pass"

      assert PermissionMatrix.report_marker(a, h, %{empty | labels: [:core_change, :pre_approved]}) ==
               "PERMISSION-MATRIX-REPORT v1 baseline=#{a} head=#{h} labels=core_change,pre_approved result=pass"

      bootstrap = PermissionMatrix.classify(:absent, baseline(), ctx())

      assert PermissionMatrix.report_marker(a, h, bootstrap) ==
               "PERMISSION-MATRIX-REPORT v1 baseline=#{a} head=#{h} labels=bootstrap result=pass"
    end
  end
end
