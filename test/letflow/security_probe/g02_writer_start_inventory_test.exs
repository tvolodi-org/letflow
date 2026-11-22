defmodule Letflow.SecurityProbe.G02WriterStartInventoryTest do
  @moduledoc """
  G-02: a deterministic writer and process-start inventory. It closes the literal-only
  `module_start` scan and the definition-context call-graph gap without executing application code.

  W1 pins every Repo and Ecto.Multi call under lib/ and priv/, including the repository variables
  handed to transaction/Multi callbacks and any other receiver whose method name is a Repo mutation
  verb. D1 derives every public writer in the `Letflow.Definitions` namespace whose local call graph
  writes, including create, update/PUT/PATCH, import, activation, rollback and promotion. S1 pins
  HTTP, module, scheduler and both SUB_PROCESS child starts, the child activation entry point
  included. S2 fails closed on an unapproved or computed `module_start` option in every syntactic
  form the detector sees: the `Keyword` and `Map` verbs, `List.keystore/4` and a literal keyword
  pair, through a renamed module as well. S3 asserts that every Engine start entry reaches a
  module-start gate (the root gate for a root instance, the child gate for a SUB_PROCESS child).
  The N-tests are seeded failing variants: removing a real Repo.update, adding an unclassified
  writer/start, hiding the start option behind Keyword.put or a computed value, and dropping a
  start gate all produce drift.
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
    {"Letflow.Definitions", :register_variable_schemas, 3} => :supporting_write,
    {"Letflow.Definitions.ActivatedBy", :ensure, 1} => :activation_write,
    {"Letflow.Definitions.ActivatedBy", :sign, 3} => :activation_write,
    {"Letflow.Definitions.PromotionReviewStore", :approve_review, 4} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :insert_review, 2} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :mark_review_applied, 2} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :mark_review_failed, 2} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :reject_review, 3} => :review_write,
    {"Letflow.Definitions.PromotionReviewStore", :supersede_review, 3} => :review_write,
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
  # prepare_child_activation rows are the distinct child-activation call sites.
  @expected_starts [
    {"lib/letflow/engine.ex", "Letflow.Engine.SubProcess", :append_start_multi, :call},
    {"lib/letflow/engine.ex", "Letflow.Engine.SubProcess", :append_start_multi, :call},
    {"lib/letflow/engine.ex", "Letflow.Engine.SubProcess", :prepare_child_activation, :call},
    {"lib/letflow/engine.ex", "Letflow.Engine.SubProcess", :prepare_child_activation, :call},
    {"lib/letflow/modules/assets/documents/posting.ex", "Letflow.Engine", :create, :call},
    {"lib/letflow/modules/maintenance/orders.ex", "Letflow.Engine", :create, :call},
    {"lib/letflow/modules/stock/documents/posting.ex", "Letflow.Engine", :create, :call},
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
end
