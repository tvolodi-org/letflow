defmodule Letflow.Modules.Exam.ExamDefinitionsTest do
  @moduledoc """
  Runs the five exam-configuration entity-definition documents REQ-327 authors
  under `priv/modules/exam/entity_definitions/` through the real
  `Letflow.Entities.Definition.Validator.validate/1`, and asserts their relational
  shape and naming conventions mechanically.

  These are pack **content** documents, not application code. The point of this
  test is that authored content which has never been through the real validator is
  not done -- so it reads each file from `priv` at runtime and asserts `:ok`.

  ## Why this file re-implements the atomizer

  `Letflow.Definitions.SolutionPack.atomize_definition_json/1` is `defp`. Rather
  than change a gated production module (REQ-327 authors no application code), the
  translation is mirrored here from the same static whitelists
  (`@top_level_keys`, `@field_keys`, `@field_types`, `@search_strategies`,
  `@index_keys`, `@fk_keys`, `@constraint_keys` in
  `lib/letflow/definitions/solution_pack.ex`). `test "atomizer whitelists match
  solution_pack.ex"` below guards the mirror against drift by asserting that every
  key these documents actually use is one the production whitelists accept, via a
  real `SolutionPack` parse of a wrapped document.

  REQ-411: moved from `test/letflow/packs/bilimbaga_exam_definitions_test.exs`;
  paths updated to `priv/modules/exam/entity_definitions/`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Definition.Validator

  @documents ~w(
    exam
    exam_section
    exam_question_rule
    exam_question_rule_tag
    exam_manual_question
  )

  @entry_name_regex ~r/^[a-z][a-z0-9_]{0,63}$/

  # Mirrors of solution_pack.ex's static whitelists. See moduledoc.
  @top_level_keys %{
    "name" => :name,
    "display_name" => :display_name,
    "description" => :description,
    "fields" => :fields,
    "indexes" => :indexes,
    "foreign_keys" => :foreign_keys,
    "constraints" => :constraints
  }

  @field_keys %{
    "name" => :name,
    "type" => :type,
    "required" => :required,
    "queried" => :queried,
    "enum_values" => :enum_values,
    "decimal_precision" => :decimal_precision,
    "decimal_scale" => :decimal_scale,
    "default" => :default,
    "locales" => :locales,
    "search_strategy" => :search_strategy
  }

  @field_types %{
    "string" => :string,
    "integer" => :integer,
    "decimal" => :decimal,
    "boolean" => :boolean,
    "date" => :date,
    "datetime" => :datetime,
    "enum" => :enum,
    "json" => :json,
    "localized_text" => :localized_text
  }

  @search_strategies %{"plain" => :plain, "fulltext" => :fulltext}

  @index_keys %{"name" => :name, "fields" => :fields, "unique" => :unique}

  @fk_keys %{
    "name" => :name,
    "field" => :field,
    "references_entity" => :references_entity,
    "references_field" => :references_field
  }

  @constraint_keys %{"name" => :name, "type" => :type, "fields" => :fields}

  describe "every authored document passes the real validator" do
    for document <- @documents do
      test "#{document}.json validates to :ok" do
        assert :ok == Validator.validate(load(unquote(document)))
      end
    end
  end

  describe "top-level document shape" do
    for document <- @documents do
      test "#{document}.json carries only the seven permitted top-level keys" do
        raw = load_raw(unquote(document))

        assert Map.keys(raw) -- Map.keys(@top_level_keys) == [],
               "unexpected top-level key(s) in #{unquote(document)}.json"

        for required <- ~w(name display_name description fields) do
          assert Map.has_key?(raw, required)
        end

        assert raw["name"] == unquote(document),
               "the document's own name must match its filename"
      end
    end
  end

  describe "relational shape" do
    test "exam declares zero foreign keys and zero constraints" do
      doc = load("exam")

      assert Map.get(doc, :foreign_keys, []) == []
      assert Map.get(doc, :constraints, []) == []
    end

    test "category: one self fk on parent_id; question: fks to category and to itself" do
      assert fk_pairs(load("category")) == [{"parent_id", "category"}]

      assert fk_pairs(load("question")) == [
               {"category_id", "category"},
               {"parent_id", "question"}
             ]
    end

    test "exam_section: one fk to exam, unique over [exam_id, sort_order]" do
      doc = load("exam_section")

      assert fk_pairs(doc) == [{"exam_id", "exam"}]
      assert unique_field_sets(doc) == [["exam_id", "sort_order"]]
    end

    test "exam_question_rule: three fks, unique over [exam_id, sort_order]" do
      doc = load("exam_question_rule")

      assert fk_pairs(doc) == [
               {"exam_id", "exam"},
               {"section_id", "exam_section"},
               {"category_id", "category"}
             ]

      assert unique_field_sets(doc) == [["exam_id", "sort_order"]]
    end

    test "exam_question_rule_tag: two fks, unique over [rule_id, tag_id]" do
      doc = load("exam_question_rule_tag")

      assert fk_pairs(doc) == [
               {"rule_id", "exam_question_rule"},
               {"tag_id", "tag"}
             ]

      assert unique_field_sets(doc) == [["rule_id", "tag_id"]]
    end

    test "exam_manual_question: two fks, unique over [rule_id, question_id]" do
      doc = load("exam_manual_question")

      assert fk_pairs(doc) == [
               {"rule_id", "exam_question_rule"},
               {"question_id", "question"}
             ]

      assert unique_field_sets(doc) == [["rule_id", "question_id"]]
    end
  end

  describe "index and naming preconditions" do
    for document <- @documents do
      test "#{document}.json: every indexed field exists and is queried: true" do
        doc = load(unquote(document))
        fields_by_name = Map.new(Map.get(doc, :fields, []), &{&1.name, &1})

        for index <- Map.get(doc, :indexes, []), field_name <- index.fields do
          field = Map.get(fields_by_name, field_name)
          assert field != nil, "index #{index.name} names unknown field #{field_name}"

          assert Map.get(field, :queried) == true,
                 "index #{index.name} names field #{field_name}, which is not queried: true"
        end
      end

      test "#{document}.json: every index/fk/constraint entry has a conforming name" do
        doc = load(unquote(document))

        for scope <- [:indexes, :foreign_keys, :constraints],
            entry <- Map.get(doc, scope, []) do
          name = Map.get(entry, :name)

          assert is_binary(name), "#{scope} entry is missing a string name"
          assert name != "", "#{scope} entry has an empty name"

          assert Regex.match?(@entry_name_regex, name),
                 "#{scope} name #{inspect(name)} must match ^[a-z][a-z0-9_]{0,63}$"
        end
      end

      test "#{document}.json: fk and constraint names do not collide in their shared scope" do
        doc = load(unquote(document))

        # Rule 2 (duplicate_name_violations/1) concatenates foreign_keys and
        # constraints into ONE uniqueness scope, so these must be distinct.
        shared =
          Enum.map(Map.get(doc, :foreign_keys, []), & &1.name) ++
            Enum.map(Map.get(doc, :constraints, []), & &1.name)

        assert shared == Enum.uniq(shared),
               "duplicate name in the shared foreign_keys+constraints scope: #{inspect(shared)}"
      end

      test "#{document}.json: entry names follow the <prefix>_<entity>_<columns> convention" do
        doc = load(unquote(document))
        entity = doc.name

        for index <- Map.get(doc, :indexes, []) do
          assert index.name == "idx_" <> entity <> "_" <> Enum.join(index.fields, "_")
        end

        for fk <- Map.get(doc, :foreign_keys, []) do
          assert fk.name == "fk_" <> entity <> "_" <> fk.field
        end

        for constraint <- Map.get(doc, :constraints, []) do
          assert constraint.name ==
                   "uq_" <> entity <> "_" <> Enum.join(constraint.fields, "_")
        end
      end
    end
  end

  describe "deliberate modelling decisions" do
    test "no document declares tag_ids or any other array-of-references field" do
      for document <- @documents, field <- Map.get(load(document), :fields, []) do
        refute field.name == "tag_ids",
               "#{document}.json declares tag_ids; it must be remodelled as exam_question_rule_tag"

        refute field.type == :json,
               "#{document}.json declares a :json field (#{field.name})"
      end
    end

    test "exam_question_rule's description records the tag_ids remodelling" do
      description = load("exam_question_rule").description

      assert description =~ "tag_ids"
      assert description =~ "exam_question_rule_tag"
      assert description =~ "docs/anti-patterns.md"

      assert description =~
               "Modelling many-to-many as an array of references on the parent record"
    end

    test "exam_question_rule_tag records that it has no source table" do
      description = load("exam_question_rule_tag").description

      assert description =~ "NO SOURCE TABLE"
      assert description =~ "tag_ids"
    end

    test "no document declares id, created_at, updated_at, created_by or assigned_by" do
      omitted = ~w(id created_at updated_at created_by assigned_by)

      for document <- @documents, field <- Map.get(load(document), :fields, []) do
        refute field.name in omitted,
               "#{document}.json declares the omitted field #{field.name}"
      end
    end

    test "exam.json records why created_by is dropped and what answers authorship" do
      description = load("exam").description

      assert description =~ "created_by"
      assert description =~ "actor_id"
    end

    test "every document cites FR-BB31 and roadmap section 3.1" do
      for document <- @documents do
        description = load(document).description

        assert description =~ "FR-BB31", "#{document}.json does not cite FR-BB31"

        assert description =~ "3.1",
               "#{document}.json does not cite roadmap section 3.1"
      end
    end

    test "exam and exam_section localize their title over kk/ru/en" do
      exam = load("exam")
      exam_title = field(exam, "title")

      assert exam_title.type == :localized_text
      assert exam_title.locales == ["kk", "ru", "en"]
      assert exam_title.search_strategy == :plain
      assert exam_title.queried == true

      exam_description = field(exam, "description")
      assert exam_description.type == :localized_text
      assert exam_description.locales == ["kk", "ru", "en"]

      section_title = field(load("exam_section"), "title")
      assert section_title.type == :localized_text
      assert section_title.locales == ["kk", "ru", "en"]
      assert section_title.search_strategy == :plain
    end

    test "exam_question_rule.difficulty is :string, not :enum, and says why" do
      rule = load("exam_question_rule")
      difficulty = field(rule, "difficulty")

      assert difficulty.type == :string
      refute Map.has_key?(difficulty, :enum_values)

      assert rule.description =~ "CHECK"
      assert rule.description =~ "questions.difficulty"
      assert rule.description =~ "deliberate"
    end

    test "exam.passing_score_pct ports DECIMAL(5, 2) verbatim" do
      pct = field(load("exam"), "passing_score_pct")

      assert pct.type == :decimal
      assert pct.decimal_precision == 5
      assert pct.decimal_scale == 2
    end
  end

  describe "the relocated-constraints record" do
    test "README-constraints.md exists and covers every source CHECK" do
      readme = File.read!(Path.join(definitions_dir(), "README-constraints.md"))

      for fragment <- [
            "exams_availability_check",
            "passing_score_pct BETWEEN 0 AND 100",
            "time_limit_minutes > 0",
            "max_attempts > 0",
            "count       INT NOT NULL CHECK (count > 0)",
            "sort_order >= 0",
            "exam_assignments_id_required"
          ] do
        assert readme =~ fragment, "README-constraints.md omits #{inspect(fragment)}"
      end

      # It names the enforcing code and the Expr evaluators the form layer uses.
      assert readme =~ "constraint_shape_violations/1"
      assert readme =~ "lib/letflow/entities/definition/validator.ex"
      assert readme =~ "REQ-291"
      assert readme =~ "REQ-292"
      assert readme =~ "REQ-293"

      # It states the loss plainly rather than presenting relocation as equivalent.
      assert readme =~ "THIS IS A LOSS, NOT AN EQUIVALENT RELOCATION"

      # It records exam_assignment as the former open question, resolved by REQ-582 (shape 1).
      assert readme =~ "exam_assignment` — was NOT authored"
      assert readme =~ "REQ-582 took shape 1"
      assert readme =~ "FR-BB33"
      assert readme =~ "polymorphic"
      assert readme =~ "OPEN QUESTION"
    end

    test "exam_assignment is authored as a definition document (REQ-582 took shape 1)" do
      assert File.exists?(Path.join(definitions_dir(), "exam_assignment.json"))
    end
  end

  describe "atomizer mirror" do
    test "the mirrored whitelists match solution_pack.ex's, key for key" do
      # Guards the mirror above against drift. `atomize_definition_json/1` and its
      # whitelists are `defp`, and REQ-327 authors no application code, so this
      # reads the module's source rather than changing it to expose them. If a
      # whitelist in solution_pack.ex gains or loses a key, this fails and the
      # mirror must be updated before the :ok assertions above can be trusted.
      source =
        :letflow
        |> Application.app_dir("../../../../lib/letflow/definitions/solution_pack.ex")
        |> Path.expand()
        |> File.read!()

      for {attribute, mirror} <- [
            {"@top_level_keys", @top_level_keys},
            {"@field_keys", @field_keys},
            {"@field_types", @field_types},
            {"@search_strategies", @search_strategies},
            {"@index_keys", @index_keys},
            {"@fk_keys", @fk_keys},
            {"@constraint_keys", @constraint_keys}
          ] do
        assert source =~ attribute, "#{attribute} no longer exists in solution_pack.ex"

        for key <- Map.keys(mirror) do
          assert source =~ "\"#{key}\" =>",
                 "#{attribute} mirror lists #{inspect(key)}, absent from solution_pack.ex"
        end
      end
    end

    test "every key these documents use is on the mirrored whitelists" do
      # Redundant with atomize/1 succeeding in every test above (it rejects an
      # unrecognised key outright rather than dropping it, per 0026 section 4),
      # but asserted explicitly so the failure names the offending key.
      for document <- @documents do
        raw = load_raw(document)

        assert Map.keys(raw) -- Map.keys(@top_level_keys) == []

        for field <- raw["fields"] do
          assert Map.keys(field) -- Map.keys(@field_keys) == []
          assert Map.has_key?(@field_types, field["type"])
        end

        for index <- Map.get(raw, "indexes", []) do
          assert Map.keys(index) -- Map.keys(@index_keys) == []
        end

        for fk <- Map.get(raw, "foreign_keys", []) do
          assert Map.keys(fk) -- Map.keys(@fk_keys) == []
        end

        for constraint <- Map.get(raw, "constraints", []) do
          assert Map.keys(constraint) -- Map.keys(@constraint_keys) == []
          assert constraint["type"] == "unique"
        end
      end
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp definitions_dir do
    Path.join(Application.app_dir(:letflow, "priv"), "modules/exam/entity_definitions")
  end

  defp load_raw(name) do
    definitions_dir()
    |> Path.join(name <> ".json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp load(name) do
    {:ok, document} = atomize(load_raw(name))
    document
  end

  defp field(document, name) do
    Enum.find(document.fields, &(&1.name == name)) ||
      flunk("field #{inspect(name)} not found in #{document.name}")
  end

  defp fk_pairs(document) do
    Enum.map(Map.get(document, :foreign_keys, []), &{&1.field, &1.references_entity})
  end

  defp unique_field_sets(document) do
    document
    |> Map.get(:constraints, [])
    |> Enum.map(fn constraint ->
      assert constraint.type == :unique
      constraint.fields
    end)
  end

  defp atomize(raw) do
    with {:ok, top} <- translate_keys(raw, @top_level_keys),
         {:ok, top} <- translate_list(top, :fields, &translate_field/1),
         {:ok, top} <- translate_list(top, :indexes, &translate_keys(&1, @index_keys)),
         {:ok, top} <- translate_list(top, :foreign_keys, &translate_keys(&1, @fk_keys)),
         {:ok, top} <- translate_list(top, :constraints, &translate_constraint/1) do
      {:ok, top}
    end
  end

  defp translate_keys(raw, whitelist) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(whitelist, key) do
        {:ok, atom_key} -> {:cont, {:ok, Map.put(acc, atom_key, value)}}
        :error -> {:halt, {:error, {:unrecognised_key, key}}}
      end
    end)
  end

  defp translate_list(top, key, translator) do
    case Map.fetch(top, key) do
      :error ->
        {:ok, top}

      {:ok, entries} when is_list(entries) ->
        entries
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          case translator.(entry) do
            {:ok, translated} -> {:cont, {:ok, [translated | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Map.put(top, key, Enum.reverse(acc))}
          {:error, _reason} = error -> error
        end
    end
  end

  defp translate_field(raw) do
    with {:ok, field} <- translate_keys(raw, @field_keys),
         {:ok, field} <- translate_value(field, :type, @field_types),
         {:ok, field} <- translate_value(field, :search_strategy, @search_strategies) do
      {:ok, field}
    end
  end

  defp translate_constraint(raw) do
    with {:ok, constraint} <- translate_keys(raw, @constraint_keys) do
      case Map.fetch(constraint, :type) do
        {:ok, "unique"} -> {:ok, Map.put(constraint, :type, :unique)}
        :error -> {:ok, constraint}
        {:ok, other} -> {:error, {:unsupported_constraint_type, other}}
      end
    end
  end

  defp translate_value(map, key, whitelist) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, map}

      {:ok, value} ->
        case Map.fetch(whitelist, value) do
          {:ok, translated} -> {:ok, Map.put(map, key, translated)}
          :error -> {:error, {:unrecognised_value, key, value}}
        end
    end
  end
end
