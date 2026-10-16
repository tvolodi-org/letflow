defmodule Letflow.Modules.Exam.ManagedManifestTest do
  @moduledoc """
  GH #2596 T-01 and T-02 (AC1), design `lib/letflow/design/gh2596-exam-managed-types.md` sections
  2, 3 and 14 (spec `test/specs/GH2596-exam-managed.md`): the exam manifest manages EXACTLY the six
  runtime/result types, and no pack type can be silently unmanaged.

  By the supervisor ruling of 2026-10-16 (superseding "ALL 16") the ten authoring types stay
  unmanaged so the web admin keeps authoring them through the generic `/records` routes; they are
  listed below in `@authoring_ruling` with the reason. A NEW entity-definition file / pack entry
  that is in neither the declared six nor that list fails `unclassified/3`, so a new type must be
  classified deliberately.

  `async: false`: the install test provisions a tenant (`Sandbox.mode(:auto)`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ManagedTypes
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Installs

  @definitions_dir Path.join([File.cwd!(), "priv", "modules", "exam", "entity_definitions"])

  @declared ~w(certificate session session_answer session_event session_question session_question_score)

  @reason "tenant-editable by ruling 2026-10-16 until the exam authoring write surface exists"
  @authoring_ruling Map.new(
                      ~w(answer_option category exam exam_manual_question exam_question_rule
                         exam_question_rule_tag exam_section question question_tag tag),
                      &{&1, @reason}
                    )

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

  # The names in `names` that are neither declared managed nor in the authoring allowlist.
  defp unclassified(names, declared, allowlist),
    do: Enum.reject(names, &(&1 in declared or Map.has_key?(allowlist, &1)))

  describe "T-01 (AC1): the declared set" do
    test "manages_entity_types, as a set, equals the literal six runtime names" do
      declared = Exam.manifest().manages_entity_types

      assert Enum.sort(declared) == @declared
      assert length(declared) == length(Enum.uniq(declared))
      assert MapSet.new(declared) == MapSet.new(Fx.runtime_types())
    end

    test "every declared name satisfies ManagedTypes.managed_name?/1 and the manifest validates" do
      for name <- Exam.manifest().manages_entity_types do
        assert ManagedTypes.managed_name?(name), name
      end

      assert Catalog.validate(Exam.manifest()) == :ok
    end

    test "none of the ten authoring names is declared (the ruling), and the manifest version is unchanged" do
      declared = MapSet.new(Exam.manifest().manages_entity_types)

      for name <- Map.keys(@authoring_ruling), do: refute(MapSet.member?(declared, name), name)

      # OQ-6: BackfillExamTenantModules pins 0.1.0; the pack id/version are unchanged too.
      assert Exam.manifest().version == "0.1.0"
      assert Fx.pack_document()["version"] == "1.0.0"
    end
  end

  describe "T-02 (AC1): completeness" do
    test "source files == pack entries == declared six UNION the ten-name authoring allowlist; the two are disjoint" do
      assert source_names() == pack_names()
      assert source_names() == Enum.sort(@declared ++ Map.keys(@authoring_ruling))
      assert length(source_names()) == 16

      assert Enum.filter(@declared, &Map.has_key?(@authoring_ruling, &1)) == []
      assert Enum.all?(Map.values(@authoring_ruling), &(&1 =~ "ruling 2026-10-16"))
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
      assert unclassified(source_names(), @declared, @authoring_ruling) == []

      assert unclassified(["zzz_new_type" | source_names()], @declared, @authoring_ruling) ==
               ["zzz_new_type"]

      # Dropping a name from the declared list (a silently unmanaged runtime type) is caught.
      assert unclassified(source_names(), @declared -- ["certificate"], @authoring_ruling) ==
               ["certificate"]
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
