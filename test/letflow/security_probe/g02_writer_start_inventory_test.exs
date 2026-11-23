defmodule Letflow.SecurityProbe.G02WriterStartInventoryTest do
  @moduledoc """
  G-02: a deterministic writer and process-start inventory. It closes the literal-only
  `module_start` scan and the definition-context call-graph gap without executing application code.

  W1 pins every Repo and Ecto.Multi call under lib/ and priv/, including the repository variables
  handed to transaction/Multi callbacks, any other receiver whose method name is a Repo mutation
  verb, and the repository functions brought into scope by an `import`. D1 derives every public
  writer in the `Letflow.Definitions` namespace whose local call graph writes, including create,
  update/PUT/PATCH, import, activation, rollback and promotion. S1 pins HTTP, module, scheduler and
  both SUB_PROCESS child starts, the child activation entry point included. S2 fails closed on an
  unapproved or computed `module_start` option in every syntactic form the detector sees: the
  `Keyword` and `Map` verbs, `List.keystore/4` and a literal keyword pair, through a renamed module,
  a file-scope alias, an `Elixir.`-prefixed alias or an imported function as well, and through
  `apply/3` when the module resolves to `Keyword`, `Map` or `List`. S3 judges each Engine start
  entry by the gate of the kind of start it performs: an entry that can start a root instance must
  reach `Letflow.Engine.gate_module_only_start/2`, an entry that reaches the SUB_PROCESS child
  activation must reach `Letflow.Engine.SubProcess.refuse_module_only_child/4`; the two gates are
  judged separately, so neither stands in for the other. The N-tests are seeded failing variants:
  removing a real Repo.update, adding an unclassified writer/start, hiding the start option behind
  Keyword.put or a computed value, hiding it behind a file-scope alias or an import, hiding a Multi
  write behind an `Elixir.`-prefixed alias, hiding the start option behind `apply/3`, hiding a
  definition writer behind `Repo.upsert`, and dropping a start gate all produce drift.
  """

  use ExUnit.Case, async: true

  alias Letflow.TestSupport.SecurityProbe.G02

  @moduletag :security_probe
  @moduletag probe_cost_s: 15

  @inventory "test/fixtures/security_probes/g02_repo_inventory.txt"

  @definition_classes %{
    {"Letflow.Definitions", :create, 2} => :graph_write,
    {"Letflow.Definitions", :create_owned, 3} => :graph_write,
    {"Letflow.Definitions", :create_with_variable_schemas, 3} => :graph_write,
    {"Letflow.Definitions", :update, 3} => :graph_write,
    {"Letflow.Definitions", :activate, 2} => :switch_on,
    {"Letflow.Definitions", :reactivate, 2} => :switch_on,
    {"Letflow.Definitions", :rollback_definition_version, 4} => :switch_on,
    {"Letflow.Definitions", :deprecate, 2} => :status_only,
    {"Letflow.Definitions", :archive, 2} => :status_only,
    {"Letflow.Definitions", :hard_delete, 2} => :status_only,
    {"Letflow.Definitions.ExportImport", :import, 3} => :graph_write,
    {"Letflow.Definitions.ExportImport", :import_with_variable_schemas, 4} => :graph_write,
    {"Letflow.Definitions.Promotion", :promote_definition, 3} => :switch_on,
    {"Letflow.Definitions.Promotion", :promote_active_definition, 5} => :switch_on,
    {"Letflow.Definitions.Promotion", :apply_review, 4} => :switch_on,
    {"Letflow.Definitions", :apply_promotion_assertion_rerun, 6} => :switch_on,
    {"Letflow.Definitions", :assign_sequence, 2} => :supporting_write,
    {"Letflow.Definitions", :entity_writes_activated_by, 4} => :supporting_write,
    {"Letflow.Definitions", :record_audit, 5} => :supporting_write,
    {"Letflow.Definitions", :record_audit, 6} => :supporting_write,
    {"Letflow.Definitions", :register_variable_schemas, 3} => :supporting_write,
    {"Letflow.Definitions.ActivatedBy", :ensure, 1} => :activation_write,
    {"Letflow.Definitions.ActivatedBy", :sign, 3} => :activation_write,
    {"Letflow.Definitions.PromotionReviewStore", :approve_review, 4} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :insert_review, 2} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :mark_review_applied, 2} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :mark_review_failed, 2} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :reject_review, 3} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :supersede_review, 3} => :review_write,
    {"Letflow.Definitions.Reactivation", :mark_definition, 3} => :reactivation,
    {"Letflow.Definitions.Reactivation", :reconcile_group, 2} => :reactivation,
    {"Letflow.Definitions.Reactivation", :reconcile_user, 2} => :reactivation,
    {"Letflow.Definitions.Reactivation", :reconcile_users, 2} => :reactivation,
    {"Letflow.Definitions.SnapshotStore", :create, 3} => :snapshot_write,
    {"Letflow.Definitions.SolutionPack", :apply_pack_update, 6} => :pack_write,
    {"Letflow.Definitions.SolutionPack", :capture_artefact_bases, 5} => :pack_write,
    {"Letflow.Definitions.SolutionPack", :install, 3} => :pack_write,
    {"Letflow.Definitions.SolutionPack", :install, 4} => :pack_write,
    {"Letflow.Definitions.SolutionPack", :install_entity_definitions, 5} => :pack_write,
    {"Letflow.Definitions.SolutionPack", :install_process_drafts, 5} => :pack_write,
    {"Letflow.Definitions.SolutionPackOverrideActivation", :activate, 7} => :switch_on,
    {"Letflow.Definitions.SolutionPackOverrideActivation", :activate, 8} => :switch_on,
    {"Letflow.Definitions.SolutionPackOverrides", :apply_update_outcomes, 4} => :override_write,
    {"Letflow.Definitions.SolutionPackOverrides", :create, 4} => :override_write,
    {"Letflow.Definitions.SolutionPackOverrides", :create, 5} => :override_write,
    {"Letflow.Definitions.SolutionPackOverrides", :new_version, 5} => :override_write,
    {"Letflow.Definitions.SolutionPackOverrides", :new_version, 6} => :override_write,
    {"Letflow.Definitions.SolutionPackOverrides", :retire, 4} => :override_write
  }

  # run/3 has two default arguments, so its one capture is present in all three generated arities.
  # The two identical engine.ex rows are distinct initial-start and continuation call sites; the two
  # prepare_child_activation rows are the distinct child-activation call sites. The platform row is
  # the one start of a platform definition: it carries the caller's auth_context, so the engine's
  # own start-permission gate judges it.
  @expected_starts [
    {"lib/letflow/engine.ex", "Letflow.Engine.SubProcess", :append_start_multi, :call},
    {"lib/letflow/engine.ex", "Letflow.Engine.SubProcess", :append_start_multi, :call},
    {"lib/letflow/engine.ex", "Letflow.Engine.SubProcess", :prepare_child_activation, :call},
    {"lib/letflow/engine.ex", "Letflow.Engine.SubProcess", :prepare_child_activation, :call},
    {"lib/letflow/modules/assets/documents/posting.ex", "Letflow.Engine", :create, :call},
    {"lib/letflow/modules/maintenance/orders.ex", "Letflow.Engine", :create, :call},
    {"lib/letflow/modules/stock/documents/posting.ex", "Letflow.Engine", :create, :call},
    {"lib/letflow/platform_processes.ex", "Letflow.Engine", :create, :call},
    {"lib/letflow/routers/instances.ex", "Letflow.Engine", :create, :call},
    {"lib/letflow/scheduler/scheduled_job_sweep.ex", "Letflow.Engine", :create, :capture},
    {"lib/letflow/scheduler/scheduled_job_sweep.ex", "Letflow.Engine", :create, :capture},
    {"lib/letflow/scheduler/scheduled_job_sweep.ex", "Letflow.Engine", :create, :capture}
  ]

  @module_start_paths [
    "lib/letflow/modules/assets/documents/posting.ex",
    "lib/letflow/modules/maintenance/orders.ex",
    "lib/letflow/modules/stock/documents/posting.ex"
  ]

  setup_all do
    {:ok, scan: G02.scan()}
  end

  test "W1: the checked-in inventory equals every real Repo and Ecto.Multi call", %{scan: scan} do
    expected = File.read!(@inventory)
    assert G02.inventory_drift(scan, expected) == []
  end

  test "W2: the real inventory is complete and non-empty across read, write and Multi verbs", %{
    scan: scan
  } do
    inventory = G02.repo_inventory(scan)
    assert length(inventory) > 2_000

    repo_verbs = for %{class: :repo, fun: fun} <- inventory, do: fun
    multi_verbs = for %{class: :multi, fun: fun} <- inventory, do: fun

    for verb <- [
          :all,
          :one,
          :get,
          :query,
          :query!,
          :transaction,
          :rollback,
          :insert,
          :insert!,
          :insert_all,
          :update,
          :update!,
          :update_all,
          :delete,
          :delete!,
          :delete_all
        ] do
      assert verb in repo_verbs, "Repo.#{verb} is absent from the real inventory"
    end

    assert :dynamic in repo_verbs,
           "dynamic apply(Repo, operation, args) is absent from the inventory"

    for verb <- [:new, :run, :merge, :insert, :update, :delete, :delete_all, :update_all] do
      assert verb in multi_verbs, "Ecto.Multi.#{verb} is absent from the real inventory"
    end
  end

  test "D1: every public writer in the definition namespace is classified", %{scan: scan} do
    expected = Map.keys(@definition_classes)
    assert G02.definition_drift(scan, expected) == []

    assert Enum.all?(
             Map.values(@definition_classes),
             &(&1 in [
                 :graph_write,
                 :switch_on,
                 :status_only,
                 :supporting_write,
                 :activation_write,
                 :review_write,
                 :reactivation,
                 :snapshot_write,
                 :pack_write,
                 :override_write
               ])
           )
  end

  test "S1: HTTP, module, scheduler and the SUB_PROCESS start paths form a closed inventory", %{
    scan: scan
  } do
    assert G02.start_drift(scan, @expected_starts) == []
  end

  test "S2: only the three module start files use module_start, always as literal true", %{
    scan: scan
  } do
    assert G02.module_start_violations(scan, @module_start_paths) == []

    assert scan |> G02.module_start_writes() |> Enum.map(& &1.path) |> Enum.sort() ==
             @module_start_paths
  end

  test "S3: every Engine start entry passes a module-start gate", %{scan: scan} do
    roots = G02.start_roots(scan)

    assert roots != []
    assert G02.unguarded_start_roots(scan) == []

    # The rule is per kind, so each gate is pinned on its own: the root instance start reaches the
    # root gate, and the child activation reaches the child gate. N13 removes each call site from a
    # copy of the real tree and shows the rule reporting it.
    assert G02.reaches_call?(
             scan,
             {"Letflow.Engine", :create, 2},
             "Letflow.Engine",
             :gate_module_only_start
           )

    assert G02.reaches_call?(
             scan,
             {"Letflow.Engine", :create, 2},
             "Letflow.Engine.SubProcess",
             :refuse_module_only_child
           )
  end

  test "N1 non-vacuity: deleting one real Repo.update makes the inventory probe fail", %{
    scan: scan
  } do
    update = Enum.find(G02.repo_inventory(scan), &(&1.class == :repo and &1.fun == :update))
    assert update

    broken = List.delete(G02.repo_inventory(scan), update)
    expected = File.read!(@inventory)

    assert [{:missing, line}] = G02.inventory_drift(broken, expected)
    assert line =~ " repo "
    assert line =~ ".update/"
  end

  test "N2 non-vacuity: direct, Multi, callback and dynamic writers cannot join definition paths silently" do
    source = """
    defmodule Letflow.Definitions do
      alias Letflow.Repo
      alias Letflow.Definitions.ProcessDefinition

      def import_unchecked(definition, attrs, opts) do
        changeset = ProcessDefinition.create_changeset(definition, attrs)
        Repo.insert(changeset, opts)
      end

      def activate_multi(multi, definition, attrs) do
        changeset = ProcessDefinition.update_changeset(definition, attrs)
        Ecto.Multi.update(multi, :definition, changeset)
      end

      def callback_write(multi, definition, attrs) do
        changeset = ProcessDefinition.update_changeset(definition, attrs)
        Ecto.Multi.run(multi, :definition, fn repo, _changes -> repo.update(changeset) end)
      end

      def dynamic_write(definition, attrs, operation) do
        changeset = ProcessDefinition.update_changeset(definition, attrs)
        apply(Repo, operation, [changeset])
      end

      defp persist_external(changeset), do: Repo.insert(changeset)
      def external_changeset(changeset), do: persist_external(changeset)
    end

    defmodule Letflow.Definitions.RogueWriter do
      alias Letflow.Repo
      alias Letflow.Definitions.ProcessDefinition

      def save(definition, attrs) do
        changeset = ProcessDefinition.update_changeset(definition, attrs)
        Repo.insert(changeset)
      end
    end
    """

    synthetic = G02.scan_source("synthetic/definitions.ex", source)
    entries = G02.definition_entries(synthetic)

    assert {"Letflow.Definitions", :import_unchecked, 3} in entries
    assert {"Letflow.Definitions", :activate_multi, 3} in entries
    assert {"Letflow.Definitions", :callback_write, 3} in entries
    assert {"Letflow.Definitions", :dynamic_write, 3} in entries
    assert {"Letflow.Definitions", :external_changeset, 1} in entries
    assert {"Letflow.Definitions.RogueWriter", :save, 2} in entries
    assert length(G02.definition_drift(synthetic, [])) == 6
    assert G02.definition_drift(synthetic, entries) == []
  end

  test "N3 non-vacuity: computed options and alternate start call forms are failing variants" do
    source = """
    defmodule RogueStart do
      alias Letflow.Engine
      alias Letflow.Engine.SubProcess
      alias Keyword, as: KW

      def direct(attrs, opts, flag) do
        Engine.create(attrs, Keyword.put(opts, :module_start, flag))
      end

      def piped(attrs, opts) do
        computed = opts |> Keyword.put_new(:module_start, true)
        Engine.create(attrs, computed)
      end

      def merged(attrs, opts) do
        Engine.create(attrs, Keyword.merge(opts, module_start: false))
      end

      def stored(attrs, opts) do
        Engine.create(attrs, List.keystore(opts, :module_start, 0, true))
      end

      def applied(attrs), do: apply(Engine, :create, [attrs, [module_start: true]])
      def dynamic(attrs, operation), do: apply(Engine, operation, [attrs, []])
      def captured, do: &Engine.create/2
      def aliased(opts), do: KW.put(opts, :module_start, true)
      def mapped(opts), do: Map.put(opts, :module_start, true)
      def replaced(opts), do: Map.replace(opts, :module_start, true)
      def new_mapped(opts), do: Map.put_new(opts, :module_start, true)
      def bang_mapped(opts), do: Map.replace!(opts, :module_start, true)
      def keyword_replaced(opts), do: Keyword.replace(opts, :module_start, true)
      def keyword_bang_replaced(opts), do: Keyword.replace!(opts, :module_start, true)
      def keyword_removed(opts), do: Keyword.delete(opts, :module_start)
      def map_removed(opts), do: Map.delete(opts, :module_start)
      def merged_true(attrs, opts), do: Engine.create(attrs, Keyword.merge(opts, module_start: true))

      def child(parent, variables, node, opts),
        do: SubProcess.prepare_child_activation(parent, variables, node, opts)
    end
    """

    synthetic = G02.scan_source("synthetic/rogue_start.ex", source)
    starts = G02.start_calls(synthetic)

    assert length(starts) == 9
    assert Enum.any?(starts, &(&1.form == :apply))
    assert Enum.any?(starts, &(&1.form == :dynamic_apply))
    assert Enum.any?(starts, &(&1.form == :capture))
    assert Enum.any?(starts, &(&1.fun == :prepare_child_activation and &1.arity == 4))
    assert length(G02.start_drift(synthetic, [])) == 9

    violations = G02.module_start_violations(synthetic, @module_start_paths)

    assert Enum.any?(violations, fn
             {_, _, :put, :computed, _} -> true
             _ -> false
           end)

    assert Enum.any?(violations, fn
             {_, _, :put_new, :literal_true, _} -> true
             _ -> false
           end)

    assert Enum.any?(violations, fn
             {_, _, :keyword, :literal_false, _} -> true
             _ -> false
           end)

    assert Enum.any?(violations, fn
             {_, _, :list_keystore, :literal_true, _} -> true
             _ -> false
           end)

    assert Enum.any?(violations, fn
             {_, _, :keyword, :literal_true, _} -> true
             _ -> false
           end)

    for form <- [:put, :map_put, :map_put_new, :map_replace, :map_replace!, :replace, :replace!] do
      assert Enum.any?(violations, fn
               {_, _, ^form, :literal_true, _} -> true
               _ -> false
             end)
    end

    for form <- [:keyword_delete, :map_delete] do
      assert Enum.any?(violations, fn
               {_, _, ^form, :removed, _} -> true
               _ -> false
             end)
    end

    # A renamed module resolves to the same module: exactly one literal-true Keyword put (the
    # aliased one) and one computed put (the direct one, whose value is a variable).
    assert Enum.count(violations, fn
             {_, _, :put, :literal_true, _} -> true
             _ -> false
           end) == 1

    assert Enum.count(violations, fn
             {_, _, :put, :computed, _} -> true
             _ -> false
           end) == 1
  end

  test "N4 detector self-check: renamed aliases, apply and callback repo variables are inventoried" do
    source = """
    defmodule SyntheticWriters do
      alias Letflow.Repo, as: Storage
      alias Ecto.Multi, as: Tx

      def write(repo_mod, changeset, query, rows, operation) do
        Storage.update!(changeset)
        repo_mod.delete_all(query)
        apply(Storage, :insert_all, ["things", rows])
        apply(Storage, operation, [changeset])
        apply(Tx, operation, [Tx.new()])
        Tx.insert(Tx.new(), :thing, changeset)
      end

      def arbitrary(store, changeset, query) do
        store.insert(changeset)
        Storage.transaction(fn store -> store.all(query) end)
      end
    end
    """

    calls = "synthetic/writers.ex" |> G02.scan_source(source) |> G02.repo_inventory()

    assert Enum.any?(calls, &(&1.target == "Letflow.Repo" and &1.fun == :update!))
    assert Enum.any?(calls, &(&1.target == "$repo_mod" and &1.fun == :delete_all))
    assert Enum.any?(calls, &(&1.fun == :insert_all and &1.form == :apply))

    assert Enum.any?(
             calls,
             &(&1.class == :repo and &1.fun == :dynamic and &1.form == :dynamic_apply)
           )

    assert Enum.any?(
             calls,
             &(&1.class == :multi and &1.fun == :dynamic and &1.form == :dynamic_apply)
           )

    assert Enum.any?(calls, &(&1.class == :multi and &1.fun == :insert))
    assert Enum.any?(calls, &(&1.target == "$store" and &1.fun == :insert))
    assert Enum.any?(calls, &(&1.target == "$store" and &1.fun == :all))
  end

  test "N5 compliant control: a reviewed module start with literal true is accepted" do
    source = """
    defmodule Letflow.Modules.Stock.Documents.Posting do
      alias Letflow.Engine
      alias Keyword, as: KW
      def start(attrs, prefix), do: Engine.create(attrs, prefix: prefix, module_start: true)
      def aliased(attrs, opts), do: Engine.create(attrs, KW.put(opts, :module_start, true))
    end
    """

    synthetic =
      G02.scan_source("lib/letflow/modules/stock/documents/posting.ex", source)

    assert G02.module_start_violations(synthetic, @module_start_paths) == []
    assert length(G02.start_calls(synthetic)) == 2
  end

  test "N6 non-vacuity: a start entry without a module-start gate is reported" do
    unguarded = """
    defmodule Letflow.Engine do
      def create(attrs, opts), do: start(attrs, opts)
      defp start(attrs, _opts), do: {:ok, attrs}
    end
    """

    guarded = """
    defmodule Letflow.Engine do
      def create(attrs, opts), do: lookup(opts)
      defp lookup(opts), do: gate_module_only_start({:ok, attrs}, opts)
      defp gate_module_only_start(found, _opts), do: found
    end
    """

    assert G02.unguarded_start_roots(G02.scan_source("synthetic/unguarded.ex", unguarded)) != []

    assert G02.unguarded_start_roots(G02.scan_source("synthetic/guarded.ex", guarded)) == []
  end

  test "N7 non-vacuity: a file-scope alias cannot hide a module_start write" do
    source = """
    alias Keyword, as: KW

    defmodule RogueFileScope do
      def start(opts), do: KW.put(opts, :module_start, true)
    end
    """

    synthetic = G02.scan_source("synthetic/rogue_file_scope.ex", source)
    violations = G02.module_start_violations(synthetic, @module_start_paths)

    assert Enum.any?(violations, fn
             {_, _, :put, :literal_true, _} -> true
             _ -> false
           end)

    # The compliant control: the same file at a reviewed module path is accepted.
    approved =
      G02.scan_source("lib/letflow/modules/stock/documents/posting.ex", source)

    assert G02.module_start_violations(approved, @module_start_paths) == []
  end

  test "N8 non-vacuity: an imported function cannot hide a module_start write" do
    file_scope = """
    import Keyword, only: [put: 3]

    defmodule RogueFileImport do
      def start(opts), do: put(opts, :module_start, true)
    end
    """

    module_scope = """
    defmodule RogueModuleImport do
      import Map

      def start(opts), do: put(opts, :module_start, true)
    end
    """

    file_violations =
      "synthetic/rogue_file_import.ex"
      |> G02.scan_source(file_scope)
      |> G02.module_start_violations(@module_start_paths)

    assert Enum.any?(file_violations, fn
             {_, _, :put, :literal_true, _} -> true
             _ -> false
           end)

    module_violations =
      "synthetic/rogue_module_import.ex"
      |> G02.scan_source(module_scope)
      |> G02.module_start_violations(@module_start_paths)

    assert Enum.any?(module_violations, fn
             {_, _, :map_put, :literal_true, _} -> true
             _ -> false
           end)

    approved =
      G02.scan_source("lib/letflow/modules/stock/documents/posting.ex", file_scope)

    assert G02.module_start_violations(approved, @module_start_paths) == []
  end

  test "N9 non-vacuity: an Elixir-prefixed alias cannot hide a Multi or Repo write" do
    source = """
    alias Elixir.Ecto.Multi
    alias Elixir.Letflow.Repo

    defmodule RoguePrefixed do
      def write(multi, changeset) do
        Multi.insert(multi, :thing, changeset)
        Repo.insert(changeset)
      end
    end
    """

    grouped = """
    alias Elixir.{Ecto.Multi}

    defmodule RogueGroupedPrefixed do
      def write(multi, changeset), do: Multi.insert(multi, :thing, changeset)
    end
    """

    calls =
      "synthetic/rogue_prefixed.ex"
      |> G02.scan_source(source)
      |> G02.repo_inventory()

    assert Enum.any?(
             calls,
             &(&1.class == :multi and &1.target == "Ecto.Multi" and &1.fun == :insert)
           )

    assert Enum.any?(
             calls,
             &(&1.class == :repo and &1.target == "Letflow.Repo" and &1.fun == :insert)
           )

    grouped_calls =
      "synthetic/rogue_grouped_prefixed.ex"
      |> G02.scan_source(grouped)
      |> G02.repo_inventory()

    assert Enum.any?(
             grouped_calls,
             &(&1.class == :multi and &1.target == "Ecto.Multi" and &1.fun == :insert)
           )
  end

  test "N10 detector self-check: an imported repository function is inventoried" do
    source = """
    import Letflow.Repo

    defmodule SyntheticImport do
      def write(changeset), do: insert(changeset)
      def read(query), do: all(query)
    end
    """

    calls =
      "synthetic/imported_repo.ex"
      |> G02.scan_source(source)
      |> G02.repo_inventory()

    assert Enum.any?(
             calls,
             &(&1.class == :repo and &1.target == "Letflow.Repo" and &1.fun == :insert)
           )

    assert Enum.any?(
             calls,
             &(&1.class == :repo and &1.target == "Letflow.Repo" and &1.fun == :all)
           )
  end

  test "N11 non-vacuity: an option written through apply/3 cannot hide a module_start write" do
    plain = """
    defmodule RogueApplyOption do
      def start(opts), do: apply(Keyword, :put, [opts, :module_start, true])
    end
    """

    aliased = """
    alias Keyword, as: KW

    defmodule RogueApplyAlias do
      def start(opts), do: apply(KW, :put, [opts, :module_start, true])
    end
    """

    prefixed = """
    defmodule RogueApplyPrefixed do
      def start(opts), do: apply(Elixir.Keyword, :put, [opts, :module_start, true])
    end
    """

    kernel = """
    defmodule RogueKernelApply do
      def start(opts), do: Kernel.apply(Keyword, :put, [opts, :module_start, true])
    end
    """

    erlang = """
    defmodule RogueErlangApply do
      def start(opts), do: :erlang.apply(Keyword, :put, [opts, :module_start, true])
    end
    """

    atom = """
    defmodule RogueAtomApply do
      def start(opts), do: apply(:"Elixir.Keyword", :put, [opts, :module_start, true])
    end
    """

    mapped = """
    defmodule RogueApplyMap do
      def start(opts), do: apply(Map, :put, [opts, :module_start, true])
    end
    """

    removed = """
    defmodule RogueApplyDelete do
      def start(opts), do: apply(Keyword, :delete, [opts, :module_start])
    end
    """

    for {source, form} <- [
          {plain, :apply_put},
          {aliased, :apply_put},
          {prefixed, :apply_put},
          {kernel, :apply_put},
          {erlang, :apply_put},
          {atom, :apply_put},
          {mapped, :apply_map_put}
        ] do
      violations =
        "synthetic/rogue_apply_option.ex"
        |> G02.scan_source(source)
        |> G02.module_start_violations(@module_start_paths)

      assert Enum.any?(violations, fn
               {_, _, ^form, :literal_true, _} -> true
               _ -> false
             end),
             "the apply/3 write form #{form} was not seen"
    end

    deletions =
      "synthetic/rogue_apply_delete.ex"
      |> G02.scan_source(removed)
      |> G02.module_start_violations(@module_start_paths)

    assert Enum.any?(deletions, fn
             {_, _, :apply_keyword_delete, :removed, _} -> true
             _ -> false
           end)

    # The compliant control: the same write at a reviewed module path is accepted.
    approved =
      G02.scan_source("lib/letflow/modules/stock/documents/posting.ex", plain)

    assert G02.module_start_violations(approved, @module_start_paths) == []
  end

  test "N12 non-vacuity: an upsert write is a definition writer" do
    source = """
    defmodule Letflow.Definitions.RogueUpsert do
      alias Letflow.Repo
      alias Letflow.Definitions.ProcessDefinition

      def save(definition, attrs) do
        changeset = ProcessDefinition.update_changeset(definition, attrs)
        Repo.upsert(changeset)
      end
    end
    """

    synthetic = G02.scan_source("synthetic/definitions.ex", source)
    entries = G02.definition_entries(synthetic)

    assert {"Letflow.Definitions.RogueUpsert", :save, 2} in entries
    assert G02.definition_drift(synthetic, entries) == []
  end

  test "N13 non-vacuity: removing a module-start gate from the real tree is reported" do
    scan = G02.scan()

    engine_source = File.read!("lib/letflow/engine.ex")

    without_root_gate =
      engine_source
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, "|> gate_module_only_start("))
      |> Enum.join("\n")

    assert without_root_gate != engine_source,
           "the root module-start gate call site was not found in lib/letflow/engine.ex"

    root_drift =
      scan
      |> replace_module("lib/letflow/engine.ex", without_root_gate)
      |> G02.unguarded_start_roots()

    assert Enum.any?(root_drift, fn
             {:missing_guard, "Letflow.Engine", :gate_module_only_start,
              {"Letflow.Engine", :create, 2}} ->
               true

             _other ->
               false
           end),
           "the removal of the root module-start gate was not reported: #{inspect(root_drift)}"

    sub_process_source = File.read!("lib/letflow/engine/sub_process.ex")

    without_child_gate =
      sub_process_source
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, "<- refuse_module_only_child("))
      |> Enum.join("\n")

    assert without_child_gate != sub_process_source,
           "the child module-start gate call site was not found in lib/letflow/engine/sub_process.ex"

    child_drift =
      scan
      |> replace_module("lib/letflow/engine/sub_process.ex", without_child_gate)
      |> G02.unguarded_start_roots()

    assert Enum.any?(child_drift, fn
             {:missing_guard, "Letflow.Engine.SubProcess", :refuse_module_only_child, _entry} ->
               true

             _other ->
               false
           end),
           "the removal of the child module-start gate was not reported: #{inspect(child_drift)}"

    # The compliant control: the real tree reaches both gates.
    assert G02.unguarded_start_roots(scan) == []
  end

  test "N14 non-vacuity: a write inside a file-scope protocol implementation is inventoried" do
    file_scope = """
    defmodule Fake do
    end

    defimpl String.Chars, for: Fake do
      def to_string(_value) do
        Repo.insert(%{})
      end
    end
    """

    synthetic = G02.scan_source("lib/letflow/fake.ex", file_scope)
    rows = G02.repo_inventory(synthetic)

    assert Enum.any?(rows, fn row ->
             row.class == :repo and row.fun == :insert and row.form == :call
           end),
           "the write inside the file-scope protocol implementation was not inventoried: #{inspect(rows)}"

    # The implementation is a module of its own, under the name Elixir gives it.
    assert Map.has_key?(synthetic.modules, "String.Chars.Fake")

    # The compliant control: the same write in an ordinary module is inventoried too.
    nested = """
    defmodule Fake do
      defimpl String.Chars, for: Fake do
        def to_string(_value) do
          Repo.insert(%{})
        end
      end
    end
    """

    nested_rows = G02.scan_source("lib/letflow/fake.ex", nested) |> G02.repo_inventory()

    assert Enum.any?(nested_rows, fn row ->
             row.class == :repo and row.fun == :insert and row.form == :call
           end),
           "the write inside the nested protocol implementation was not inventoried: #{inspect(nested_rows)}"
  end

  test "N15 non-vacuity: a write held in a module attribute cannot hide" do
    captured = """
    defmodule Fake do
      @ins &Repo.insert/2

      def go(changeset), do: @ins.(changeset)
    end
    """

    synthetic = G02.scan_source("lib/letflow/fake.ex", captured)
    rows = G02.repo_inventory(synthetic)

    assert Enum.any?(rows, fn row ->
             row.class == :repo and row.fun == :insert and row.form == :capture
           end),
           "the capture held in the module attribute was not inventoried: #{inspect(rows)}"

    assert Enum.any?(rows, fn row ->
             row.class == :repo and row.fun == :insert and row.form == :attribute_call
           end),
           "the call through the module attribute was not resolved: #{inspect(rows)}"

    # A module attribute that holds a MODULE is a call of that module.
    held_module = """
    defmodule Fake do
      @repo Letflow.Repo

      def go(changeset), do: @repo.insert(changeset)
    end
    """

    module_rows = G02.scan_source("lib/letflow/fake.ex", held_module) |> G02.repo_inventory()

    assert Enum.any?(module_rows, fn row ->
             row.class == :repo and row.fun == :insert and row.form == :attribute_call
           end),
           "the call through the module attribute was not resolved: #{inspect(module_rows)}"

    # The write behind the attribute is a definition write: the call graph reaches it.
    definition = """
    defmodule Letflow.Definitions.RogueAttribute do
      alias Letflow.Repo

      @ins &Repo.insert/2

      def save(changeset), do: @ins.(changeset)
    end
    """

    entries = G02.definition_entries(G02.scan_source("synthetic/definitions.ex", definition))

    assert {"Letflow.Definitions.RogueAttribute", :save, 1} in entries
  end

  test "T1: the class table lists every probe case with its test file and name" do
    doc = File.read!("docs/security-probes/G-02.md")
    source = File.read!(__ENV__.file)
    probe_test = Path.relative_to(__ENV__.file, File.cwd!())

    names =
      Regex.scan(~r/^\s*test\s+"([^"]+)"/m, source)
      |> Enum.map(fn [_full, name] -> name end)

    assert names != []

    for name <- names do
      assert doc =~ "#{probe_test}::#{name}",
             "the class table does not name the case #{name} with its test file"
    end

    for {_full, file, name} <-
          Regex.scan(~r{([\w./-]+\.exs)::([^|`\n]+)}, doc) do
      name = String.trim(name)

      assert File.exists?(file), "the class table names a missing test file #{file}"
      assert File.read!(file) =~ name, "the class table names a missing test #{name} in #{file}"
    end
  end

  test "T2: the D1 class table lists the same writers and classes as the map" do
    doc = File.read!("docs/security-probes/G-02.md")
    table = d1_table_entries(doc)

    expected =
      Map.new(@definition_classes, fn {{module, name, arity}, class} ->
        {{module, Atom.to_string(name), arity}, Atom.to_string(class)}
      end)

    assert table == expected
  end

  # The class table's D1 section writes a module's functions in a short form: an entry that names a
  # module (`Definitions.create/2`, `Promotion.promote_definition/3`) starts a new module, and a
  # bare entry (`create_owned/3`) continues the module named before it in the same row.
  defp d1_table_entries(doc) do
    section =
      doc
      |> String.split("\n## ")
      |> Enum.find(&String.starts_with?(&1, "Definition entry-point classes pinned by D1"))

    assert section, "the class table has no D1 section"

    section
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.map(&String.split(&1, "|"))
    |> Enum.filter(fn parts -> length(parts) >= 4 end)
    |> Enum.reject(fn [_empty, class_cell | _rest] ->
      trimmed = String.trim(class_cell)
      trimmed == "Class" or String.starts_with?(trimmed, "-")
    end)
    |> Enum.reduce(%{}, fn [_empty, class_cell, entries_cell | _rest], acc ->
      class = class_cell |> String.trim() |> String.replace(" ", "_")

      entries_cell
      |> d1_row_entries()
      |> Enum.reduce(acc, fn entry, acc -> Map.put(acc, entry, class) end)
    end)
  end

  defp d1_row_entries(entries_cell) do
    ~r/`([^`]+)`/
    |> Regex.scan(entries_cell)
    |> Enum.map(fn [_full, token] -> token end)
    |> Enum.reduce({[], nil}, fn token, {acc, current} ->
      [name, arity] = String.split(token, "/")
      arity = String.to_integer(arity)

      case String.split(name, ".") do
        [bare] ->
          {acc ++ [{current, bare, arity}], current}

        parts ->
          prefix = parts |> Enum.drop(-1) |> Enum.join(".")
          module = d1_module(prefix)
          {acc ++ [{module, List.last(parts), arity}], module}
      end
    end)
    |> elem(0)
  end

  defp d1_module("Definitions"), do: "Letflow.Definitions"
  defp d1_module(prefix), do: "Letflow.Definitions." <> prefix

  # A copy of the real tree with one module replaced by a mutated source. The scan keeps every
  # other module of the real tree, so the call graph is the real one; the token is fresh, so the
  # node-call cache of the original scan cannot serve the mutated module.
  defp replace_module(scan, path, source) do
    mutated = G02.scan_source(path, source)

    {name, data} =
      Enum.find(mutated.modules, fn {_name, data} -> data.path == path end)

    %{scan | modules: Map.put(scan.modules, name, data), token: make_ref()}
  end
end
