defmodule Letflow.Modules.Exam.ManagedManifestTest do
  @moduledoc """
  GH #2596 T-01 and T-02 (AC1), design `lib/letflow/design/gh2596-exam-managed-types.md` sections
  2, 3 and 14 (spec `test/specs/GH2596-exam-managed.md`), extended by GH #2680 slice 3: the exam
  manifest manages EXACTLY the sixteen entity types of the exam pack (the six runtime/result types
  and the ten authoring types), and no pack type can be silently unmanaged.

  A NEW entity-definition file / pack entry that is not in `@declared` fails `unclassified/2`, so a
  new type must be declared deliberately.

  `async: false`: the install test provisions a tenant (`Sandbox.mode(:auto)`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ManagedTypes
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Installs

  @definitions_dir Path.join([File.cwd!(), "priv", "modules", "exam", "entity_definitions"])

  @declared ~w(answer_option category exam exam_manual_question exam_question_rule
               exam_question_rule_tag exam_section question question_tag tag certificate session
               session_answer session_event session_question session_question_score)

  defp source_names do
    @definitions_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&Path.rootname/1)
    |> Enum.sort()
  end

  defp pack_names do
    Fx.pack_document()["entity_definitions"] |> Enum.map(& &1["name"]) |> Enum.sort()
  end

  # The names in `names` that are not in `declared`.
  defp unclassified(names, declared), do: Enum.reject(names, &(&1 in declared))

  describe "T-01 (AC1): the declared set" do
    test "manages_entity_types, as a set, equals the sixteen exam names" do
      declared = Exam.manifest().manages_entity_types

      assert Enum.sort(declared) == Enum.sort(@declared)
      assert length(declared) == length(Enum.uniq(declared))
      assert MapSet.new(declared) == MapSet.new(Fx.runtime_types() ++ Fx.authoring_types())
    end

    test "every declared name satisfies ManagedTypes.managed_name?/1 and the manifest validates" do
      for name <- Exam.manifest().manages_entity_types do
        assert ManagedTypes.managed_name?(name), name
      end

      assert Catalog.validate(Exam.manifest()) == :ok
    end

    test "all ten authoring names are declared (GH #2680 slice 3), and the manifest version is unchanged" do
      declared = MapSet.new(Exam.manifest().manages_entity_types)

      for name <- Fx.authoring_types(), do: assert(MapSet.member?(declared, name), name)

      # OQ-6: BackfillExamTenantModules pins 0.1.0; the pack id/version are unchanged too.
      assert Exam.manifest().version == "0.1.0"
      assert Fx.pack_document()["version"] == "1.0.0"
    end
  end

  describe "T-02 (AC1): completeness" do
    test "source files == pack entries == the sixteen declared names; the two groups are disjoint" do
      assert source_names() == pack_names()
      assert source_names() == Enum.sort(@declared)
      assert length(source_names()) == 16

      assert Enum.sort(Fx.runtime_types() ++ Fx.authoring_types()) == Enum.sort(@declared)
      assert Enum.filter(Fx.runtime_types(), &(&1 in Fx.authoring_types())) == []
    end

    test "every pack entry's definition_json equals its source file (drift guard at 16)" do
      for packed <- Fx.pack_document()["entity_definitions"] do
        source =
          @definitions_dir
          |> Path.join("#{packed["name"]}.json")
          |> File.read!()
          |> Jason.decode!()

        assert packed["definition_json"] == source, packed["name"]
      end
    end

    test "a NEW type in neither list is reported, and a declared name missing from the sources is too (synthetic negatives)" do
      assert unclassified(source_names(), @declared) == []

      assert unclassified(["zzz_new_type" | source_names()], @declared) == ["zzz_new_type"]

      # Dropping a name from the declared list (a silently unmanaged runtime type) is caught.
      assert unclassified(source_names(), @declared -- ["certificate"]) == ["certificate"]
    end

    test "every declared name is in the pack (else Installs.check_managed_types_in_pack/2 fails every fresh install)" do
      pack = pack_names()
      for name <- Exam.manifest().manages_entity_types, do: assert(name in pack, name)
    end

    test "a fresh Installs.install(\"exam\", ...) succeeds: no managed_type_not_in_pack" do
      %{schema_name: schema} = Fx.bare_tenant!("gh2596-manifest-install", false)

      assert {:ok, %{module_id: "exam"}} =
               Installs.install("exam", Ecto.UUID.generate(),
                 prefix: schema,
                 rationale: "GH #2596 test: manifest completeness"
               )
    end
  end
end
