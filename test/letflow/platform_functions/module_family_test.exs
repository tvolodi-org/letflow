defmodule Letflow.PlatformFunctions.ModuleFamilyTest do
  @moduledoc """
  D-204 (the module-process conversion, the team record
  `docs/design-module-process-conversion.md` sections 1.1 to 1.3; the platform
  task P1 of section 6.1): the MODULE FAMILY of the compiled catalogue.

  A module function becomes a catalogue entry with `family: "<module id>"`,
  DERIVED at compile time from the module's own write-handler registration
  (`Letflow.Modules.WriteHandlerSpec`) plus the four new fields (`permission`,
  `outputs`, `idempotency_inputs`, `side_effect_classes`). A module gets no
  second, hand-written list of functions.

  This test proves:

    * the derivation (the ONE converted handler of the fixture module becomes
      one entry with the module's own id as its family, the module's own
      permission, the declared outputs, the idempotency key and the two
      MODULE side-effect classes);
    * that a handler WITHOUT a permission stays on the old owner-stamp path
      and contributes NO entry (so the catalogue of an unconverted module is
      the catalogue it was before);
    * the CLOSED list of refusal codes: every code of
      `Letflow.PlatformFunctions.ModuleFamily.codes/0` is reachable, and no
      other code is;
    * that the derivation NEVER raises: a manifest that cannot be turned into
      an entry is a refusal, not a crash (INV-8).

  Pure, no database: the catalogue is compiled into the build, and the
  derivation reads the compiled manifests only. `async: true` is safe.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.FixtureLedgerPost
  alias Letflow.Modules.WriteHandlerSpec
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.ModuleFamily

  # A fake entry module whose manifest the calling test puts in the process
  # dictionary, the seam `test/letflow/modules/catalog_write_handlers_test.exs`
  # already uses for an unvalidated manifest.
  defmodule ProbeEntry do
    @moduledoc false
    def manifest, do: Process.get(:d204_manifest)
  end

  defmodule ProbeEntryTwin do
    @moduledoc false
    def manifest, do: Process.get(:d204_manifest)
  end

  defmodule ProbeRaisingEntry do
    @moduledoc false
    def manifest, do: raise("the module's own manifest is broken")
  end

  describe "the derivation" do
    test "D-204-P1 the one converted handler becomes one entry of the module's own family" do
      assert {:ok, [entry]} = ModuleFamily.module_entries(FixtureLedgerPost)

      assert entry.name == "fixture_ledger_post.post_alpha"
      assert entry.family == "fixture_ledger_post"
      assert entry.version == "0.1.0"
      assert entry.permission == :FxlpPost
      assert entry.platform_tenant_only == false

      assert Entry.module_family?(entry)
      assert Entry.module_id(entry) == "fixture_ledger_post"
    end

    test "D-204-P1 the declared outputs are the entry's outputs" do
      {:ok, [entry]} = ModuleFamily.module_entries(FixtureLedgerPost)

      assert [
               %Entry.Output{name: "note_id", type: :uuid},
               %Entry.Output{name: "ledger_entry_id", type: :uuid}
             ] =
               entry.outputs

      assert Enum.map(entry.outputs, & &1.name) == ["note_id", "ledger_entry_id"]
    end

    test "D-204-P1 the idempotency key is the declared idempotency input" do
      {:ok, [entry]} = ModuleFamily.module_entries(FixtureLedgerPost)

      assert entry.idempotency_key == ["note"]
      assert Catalog.entry_map(entry)["idempotency_inputs"] == ["note"]
    end

    test "D-204-P1 the two MODULE side-effect classes carry the handler's own targets" do
      {:ok, [entry]} = ModuleFamily.module_entries(FixtureLedgerPost)

      assert Enum.map(entry.side_effects, & &1.class) == [:write_module_record, :ledger_post]
      assert Entry.write_like?(entry)

      assert Enum.find(entry.side_effects, &(&1.class == :write_module_record)).text =~
               "fxlp_note"

      assert Enum.find(entry.side_effects, &(&1.class == :ledger_post)).text =~ "alpha"
    end

    test "D-204-P1 every input of a module function comes from the START, never from a person" do
      {:ok, [entry]} = ModuleFamily.module_entries(FixtureLedgerPost)

      assert Enum.map(entry.inputs, & &1.name) == [
               "before",
               "note",
               "posting",
               "skip_note",
               "twice"
             ]

      assert Enum.all?(entry.inputs, &(&1.source_class == :start))
      assert Enum.find(entry.inputs, &(&1.name == "note")).required
      refute Enum.find(entry.inputs, &(&1.name == "posting")).required
    end

    test "D-204-P1 a handler WITHOUT a permission is no entry (it stays on the owner-stamp path)" do
      {:ok, entries} = ModuleFamily.module_entries(FixtureLedgerPost)

      assert Enum.map(entries, & &1.name) == ["fixture_ledger_post.post_alpha"]

      refute ModuleFamily.catalogue_handler?(%WriteHandlerSpec{
               name: "post_beta",
               function: {FixtureLedgerPost, :manifest},
               targets: ["fxlp_note"],
               args: %{}
             })

      assert ModuleFamily.catalogue_handler?(%WriteHandlerSpec{
               name: "post_alpha",
               function: {FixtureLedgerPost, :manifest},
               targets: ["fxlp_note"],
               args: %{},
               permission: :FxlpPost
             })
    end

    test "D-204-P1 the whole compiled catalogue holds the module family's entries too" do
      {:ok, entries} = ModuleFamily.entries()

      assert "fixture_ledger_post.post_alpha" in Enum.map(entries, & &1.name)
      assert {:ok, entry} = Catalog.fetch("fixture_ledger_post.post_alpha")
      assert entry.family == "fixture_ledger_post"
      assert entry.platform_tenant_only == false
    end
  end

  describe "the closed list of refusal codes" do
    test "D-204-P1 the codes are exactly the ones the derivation can answer" do
      assert ModuleFamily.codes() == [
               :module_entry_handlers_invalid,
               :module_entry_permission_invalid,
               :module_entry_permission_not_declared,
               :module_entry_outputs_invalid,
               :module_entry_side_effect_class_missing,
               :module_entry_side_effect_class_unknown,
               :module_entry_side_effect_class_duplicate,
               :module_entry_side_effect_class_conflict,
               :module_entry_idempotency_input_unknown,
               :module_entry_idempotency_input_optional,
               :module_entry_idempotency_missing,
               :module_entry_name_duplicate
             ]
    end

    test "D-204-P1 every code is reachable, and no other code is" do
      results =
        Enum.map(refusal_cases(), fn {code, case_spec} -> {code, refusal_case(case_spec)} end)

      for {code, result} <- results do
        assert result == {:error, code}, "expected #{inspect(code)}, got #{inspect(result)}"
      end

      reached = results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      assert reached == Enum.sort(ModuleFamily.codes())
    end
  end

  describe "never raises" do
    test "D-204-P1 a manifest that is not a map is a refusal, not a crash" do
      Process.put(:d204_manifest, "not a manifest")

      assert {:error, :module_entry_handlers_invalid} =
               ModuleFamily.module_entries(ProbeEntry)
    end

    test "D-204-P1 a module whose manifest is not a map is a refusal, not a crash" do
      Process.put(:d204_manifest, :not_a_manifest)

      assert {:error, :module_entry_handlers_invalid} =
               ModuleFamily.module_entries(ProbeEntry)
    end

    test "D-204-P1 a module whose manifest raises is a refusal, not a crash" do
      assert {:error, :module_entry_handlers_invalid} =
               ModuleFamily.module_entries(ProbeRaisingEntry)
    end

    test "D-204-P1 a handler that is not a spec is a refusal, not a crash" do
      assert {:error, :module_entry_handlers_invalid} =
               ModuleFamily.derive(%{id: "x"}, :not_a_handler)

      assert {:error, :module_entry_handlers_invalid} =
               ModuleFamily.derive(:not_a_manifest, %WriteHandlerSpec{
                 name: "a",
                 function: {ProbeEntry, :manifest},
                 targets: [],
                 args: %{}
               })
    end
  end

  # ── the refusal cases ──────────────────────────────────────────────────────────────────────
  #
  # One row per code of `codes/0`: the manifest or the handler that provokes
  # it, and the code the derivation answers with. The rows are the whole class
  # (the record's "fixed failure codes"), not one picked variant.

  defp refusal_cases do
    [
      {:module_entry_handlers_invalid,
       {:manifest, %{id: "probe_d204", write_handlers: :not_a_list}}},
      {:module_entry_permission_invalid, {:handler, %{permission: "Probe"}}},
      {:module_entry_permission_not_declared, {:handler, %{permission: :NotDeclared}}},
      {:module_entry_outputs_invalid, {:handler, %{outputs: [%{name: "", type: :uuid}]}}},
      {:module_entry_side_effect_class_missing, {:handler, %{side_effect_classes: []}}},
      {:module_entry_side_effect_class_unknown, {:handler, %{side_effect_classes: [:nope]}}},
      {:module_entry_side_effect_class_duplicate,
       {:handler, %{side_effect_classes: [:read, :read]}}},
      {:module_entry_side_effect_class_conflict,
       {:handler, %{side_effect_classes: [:read, :write_module_record]}}},
      {:module_entry_idempotency_input_unknown, {:handler, %{idempotency_inputs: ["nope"]}}},
      {:module_entry_idempotency_input_optional, {:handler, %{idempotency_inputs: ["when"]}}},
      {:module_entry_idempotency_missing, {:handler, %{idempotency_inputs: []}}},
      {:module_entry_name_duplicate, {:twins, %{}}}
    ]
  end

  defp refusal_case({:manifest, manifest}) do
    Process.put(:d204_manifest, manifest)
    ModuleFamily.entries_in([ProbeEntry])
  end

  defp refusal_case({:handler, overrides}) do
    Process.put(:d204_manifest, probe_manifest(overrides))
    ModuleFamily.entries_in([ProbeEntry])
  end

  defp refusal_case({:twins, _overrides}) do
    Process.put(:d204_manifest, probe_manifest(%{}))
    ModuleFamily.entries_in([ProbeEntry, ProbeEntryTwin])
  end

  defp probe_manifest(overrides) do
    handler = Map.merge(probe_handler(), overrides)

    %{
      id: "probe_d204",
      version: "0.1.0",
      permissions: [:Probe],
      write_handlers: [handler]
    }
  end

  defp probe_handler do
    %WriteHandlerSpec{
      name: "do_it",
      function: {ProbeEntry, :manifest},
      targets: ["pw_one"],
      args: %{"note" => %{required: true}, "when" => %{required: false}},
      permission: :Probe,
      outputs: [%{name: "note_id", type: :uuid}],
      idempotency_inputs: ["note"],
      side_effect_classes: [:write_module_record]
    }
  end
end
