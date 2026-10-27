defmodule Letflow.Modules.Exam.EntityDefinitionsTest do
  @moduledoc """
  Verifies the ten bucket-A entity-definition documents authored under
  `priv/modules/exam/entity_definitions/` -- REQ-326's five, and REQ-329's
  five live-session documents (session, session_question, session_answer,
  session_event, session_question_score) -- against the real
  `Letflow.Entities.Definition.Validator.validate/1` -- not a re-implemented
  or mocked validator. Each document is loaded from `priv/` at runtime via
  `Application.app_dir/2`, JSON-decoded with `Jason`, and translated from
  its string-keyed JSON shape into the atom-keyed `Letflow.Entities.Definition.t()`
  shape the validator requires, mirroring the static whitelist translation
  `Letflow.Definitions.SolutionPack`'s `atomize_definition_json/1` performs
  on the same bytes at install time (REQ-328).

  REQ-327's five exam-configuration documents (exam, exam_section,
  exam_question_rule, exam_question_rule_tag, exam_manual_question) are
  deliberately NOT covered here -- they already have their own dedicated
  coverage in `test/letflow/modules/exam/exam_definitions_test.exs`, and
  duplicating that here would be redundant.

  REQ-411: moved from `test/letflow/packs/bilimbaga_entity_definitions_test.exs`;
  paths updated to `priv/modules/exam/entity_definitions/`.

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency -- `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Definition.Validator

  @entity_definitions_dir Application.app_dir(:letflow, "priv/modules/exam/entity_definitions")

  @entity_files %{
    "category" => "category.json",
    "tag" => "tag.json",
    "question" => "question.json",
    "answer_option" => "answer_option.json",
    "question_tag" => "question_tag.json",
    "session" => "session.json",
    "session_question" => "session_question.json",
    "session_answer" => "session_answer.json",
    "session_event" => "session_event.json",
    "session_question_score" => "session_question_score.json"
  }

  @name_format_regex ~r/^[a-z][a-z0-9_]{0,63}$/

  # ---------------------------------------------------------------------------
  # Translation helpers -- static whitelist, mirroring
  # Letflow.Definitions.SolutionPack's atomize_definition_json/1.
  # ---------------------------------------------------------------------------

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

  @constraint_types %{"unique" => :unique}

  defp load_definition!(filename) do
    path = Path.join(@entity_definitions_dir, filename)
    raw = path |> File.read!() |> Jason.decode!()
    translate_top(raw)
  end

  defp translate_top(raw) do
    raw
    |> translate_keys(@top_level_keys)
    |> translate_list(:fields, &translate_field/1)
    |> translate_list(:indexes, &translate_index/1)
    |> translate_list(:foreign_keys, &translate_fk/1)
    |> translate_list(:constraints, &translate_constraint/1)
  end

  defp translate_field(raw) do
    raw
    |> translate_keys(@field_keys)
    |> translate_value(:type, @field_types)
    |> translate_value(:search_strategy, @search_strategies)
  end

  defp translate_index(raw), do: translate_keys(raw, @index_keys)

  defp translate_fk(raw), do: translate_keys(raw, @fk_keys)

  defp translate_constraint(raw) do
    raw
    |> translate_keys(@constraint_keys)
    |> translate_value(:type, @constraint_types)
  end

  defp translate_keys(map, whitelist) do
    Map.new(map, fn {k, v} ->
      atom_key = Map.fetch!(whitelist, k)
      {atom_key, v}
    end)
  end

  defp translate_list(top, key, item_fun) do
    case Map.get(top, key) do
      nil -> top
      list when is_list(list) -> Map.put(top, key, Enum.map(list, item_fun))
    end
  end

  defp translate_value(map, key, whitelist) do
    case Map.get(map, key) do
      nil -> map
      raw_value -> Map.put(map, key, Map.fetch!(whitelist, raw_value))
    end
  end

  defp field(definition, name) do
    Enum.find(definition.fields, &(&1.name == name))
  end

  # ---------------------------------------------------------------------------
  # AC -- every one of the five documents passes validate/1 with :ok.
  # ---------------------------------------------------------------------------

  describe "each of the five documents validates as :ok" do
    for {entity_name, filename} <- @entity_files do
      test "#{entity_name} (#{filename}) passes Validator.validate/1" do
        definition = load_definition!(unquote(filename))
        assert Validator.validate(definition) == :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC -- exact relational shape, mechanically asserted.
  # ---------------------------------------------------------------------------

  describe "relational shape" do
    test "question declares exactly two foreign_keys entries: category_id -> category, parent_id -> question" do
      definition = load_definition!("question.json")

      assert [
               %{field: "category_id", references_entity: "category"},
               %{name: "fk_question_parent_id", field: "parent_id", references_entity: "question"}
             ] = definition.foreign_keys
    end

    test "category declares exactly one foreign_keys entry: parent_id -> category" do
      definition = load_definition!("category.json")

      assert [
               %{name: "fk_category_parent_id", field: "parent_id", references_entity: "category"}
             ] = definition.foreign_keys
    end

    for {name, file} <- [{"category", "category.json"}, {"question", "question.json"}] do
      test "#{name} declares parent_id (string, queried, optional) with idx_#{name}_parent_id" do
        definition = load_definition!(unquote(file))
        field = Enum.find(definition.fields, &(&1.name == "parent_id"))

        assert %{type: :string, queried: true, required: false} = field
        assert Enum.any?(definition.indexes, &(&1.name == "idx_#{unquote(name)}_parent_id"))
        refute definition.description =~ "REQ-324 (pending)"
        refute definition.description =~ "deliberate gap"
      end
    end

    test "answer_option declares exactly one foreign_keys entry: question_id -> question" do
      definition = load_definition!("answer_option.json")
      assert [%{field: "question_id", references_entity: "question"}] = definition.foreign_keys
    end

    test "question_tag declares exactly two foreign_keys entries: question_id -> question and tag_id -> tag" do
      definition = load_definition!("question_tag.json")
      fks = Enum.map(definition.foreign_keys, &{&1.field, &1.references_entity})
      assert length(definition.foreign_keys) == 2
      assert {"question_id", "question"} in fks
      assert {"tag_id", "tag"} in fks
    end

    test "tag carries a constraints entry of type unique over [name]" do
      definition = load_definition!("tag.json")
      assert [%{type: :unique, fields: ["name"]}] = definition.constraints
    end

    test "question_tag carries a constraints entry of type unique over [question_id, tag_id]" do
      definition = load_definition!("question_tag.json")
      assert [%{type: :unique, fields: ["question_id", "tag_id"]}] = definition.constraints
    end

    test "every field named in any indexes entry of any of the five documents is queried: true" do
      for {_entity_name, filename} <- @entity_files do
        definition = load_definition!(filename)
        fields_by_name = Map.new(definition.fields, &{&1.name, &1})

        for index <- Map.get(definition, :indexes, []),
            field_name <- index.fields do
          field = Map.fetch!(fields_by_name, field_name)

          assert field.queried == true,
                 "#{filename}: index #{index.name} references #{field_name}, which is not queried: true"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC -- every indexes/foreign_keys/constraints entry carries a valid,
  # unique-within-scope string name.
  # ---------------------------------------------------------------------------

  describe "index/fk/constraint name shape and uniqueness" do
    test "every entry in indexes, foreign_keys and constraints has a name matching ^[a-z][a-z0-9_]{0,63}$" do
      for {_entity_name, filename} <- @entity_files do
        definition = load_definition!(filename)

        all_entries =
          Map.get(definition, :indexes, []) ++
            Map.get(definition, :foreign_keys, []) ++
            Map.get(definition, :constraints, [])

        for entry <- all_entries do
          assert is_binary(entry.name),
                 "#{filename}: entry name must be a string, got #{inspect(entry.name)}"

          assert entry.name != "", "#{filename}: entry name must not be empty"

          assert Regex.match?(@name_format_regex, entry.name),
                 "#{filename}: entry name #{inspect(entry.name)} does not match ^[a-z][a-z0-9_]{0,63}$"
        end
      end
    end

    test "foreign_keys names and constraints names within a single document contain no duplicate (Rule 2's shared scope)" do
      for {_entity_name, filename} <- @entity_files do
        definition = load_definition!(filename)

        shared_scope_names =
          Enum.map(
            Map.get(definition, :foreign_keys, []) ++ Map.get(definition, :constraints, []),
            & &1.name
          )

        assert Enum.uniq(shared_scope_names) == shared_scope_names,
               "#{filename}: duplicate name(s) found in the shared foreign_keys+constraints scope: #{inspect(shared_scope_names)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC -- the four localized_text fields have the exact locales/search_strategy
  # shape, and tag.name is :string.
  # ---------------------------------------------------------------------------

  describe "localized_text fields" do
    test "category.name is :localized_text with locales [kk, ru, en] and search_strategy :plain" do
      definition = load_definition!("category.json")
      f = field(definition, "name")
      assert f.type == :localized_text
      assert f.locales == ["kk", "ru", "en"]
      assert f.search_strategy == :plain
    end

    test "question.stem is :localized_text with locales [kk, ru, en] and search_strategy :fulltext" do
      definition = load_definition!("question.json")
      f = field(definition, "stem")
      assert f.type == :localized_text
      assert f.locales == ["kk", "ru", "en"]
      assert f.search_strategy == :fulltext
    end

    test "question.explanation is :localized_text with locales [kk, ru, en] and search_strategy :plain" do
      definition = load_definition!("question.json")
      f = field(definition, "explanation")
      assert f.type == :localized_text
      assert f.locales == ["kk", "ru", "en"]
      assert f.search_strategy == :plain
    end

    test "answer_option.text is :localized_text with locales [kk, ru, en] and search_strategy :plain" do
      definition = load_definition!("answer_option.json")
      f = field(definition, "text")
      assert f.type == :localized_text
      assert f.locales == ["kk", "ru", "en"]
      assert f.search_strategy == :plain
    end

    test "tag.name is :string, not :localized_text" do
      definition = load_definition!("tag.json")
      f = field(definition, "name")
      assert f.type == :string
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-329 AC -- session.status declares exactly the four enum values, and
  # session.expires_at is queried: true (REQ-331's auto-submit sweep depends
  # on it having an indexed predicate to scan).
  # ---------------------------------------------------------------------------

  describe "session-specific field shape (REQ-329)" do
    test "session.status is :enum with exactly [in_progress, submitted, auto_submitted, grading_pending]" do
      definition = load_definition!("session.json")
      f = field(definition, "status")
      assert f.type == :enum
      assert f.enum_values == ["in_progress", "submitted", "auto_submitted", "grading_pending"]
    end

    test "session.expires_at is queried: true" do
      definition = load_definition!("session.json")
      f = field(definition, "expires_at")
      assert f.queried == true
    end

    # GH #2682 / REQ-511: the per-session exam snapshot is one optional, non-queried JSON field.
    # Not queried (it can never be filtered, sorted or grouped on) and not required (a session
    # created before the rollout has none).
    test "session.exam_snapshot is an optional :json field that is not queried" do
      definition = load_definition!("session.json")
      f = field(definition, "exam_snapshot")
      assert f.type == :json
      assert f.queried == false
      assert f.required == false
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-329 AC (also true of REQ-326/327's ten) -- no document declares an
  # id, created_at, updated_at or created_by field: the record subsystem
  # owns record identity and the event store owns the timeline.
  # ---------------------------------------------------------------------------

  describe "no document declares record-identity or timeline fields" do
    test "none of the ten documents declares id, created_at, updated_at or created_by" do
      for {_entity_name, filename} <- @entity_files do
        definition = load_definition!(filename)
        field_names = Enum.map(definition.fields, & &1.name)

        for forbidden <- ["id", "created_at", "updated_at", "created_by"] do
          refute forbidden in field_names,
                 "#{filename}: declares forbidden field #{forbidden}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-329 AC -- session_question, session_answer and session_question_score
  # each express their source's composite PRIMARY KEY (or, for
  # session_answer, its source UNIQUE) as a `constraints` entry of type
  # :unique over the two-field natural key, NOT as a declared primary key.
  # ---------------------------------------------------------------------------

  describe "session join entities express their natural key as a unique constraint" do
    test "session_question carries a constraints entry of type unique over [session_id, question_id]" do
      definition = load_definition!("session_question.json")
      assert [%{type: :unique, fields: ["session_id", "question_id"]}] = definition.constraints
    end

    test "session_answer carries a constraints entry of type unique over [session_id, question_id]" do
      definition = load_definition!("session_answer.json")
      assert [%{type: :unique, fields: ["session_id", "question_id"]}] = definition.constraints
    end

    test "session_question_score carries a constraints entry of type unique over [session_id, question_id]" do
      definition = load_definition!("session_question_score.json")
      assert [%{type: :unique, fields: ["session_id", "question_id"]}] = definition.constraints
    end

    test "none of the three declares a field named id" do
      for filename <- [
            "session_question.json",
            "session_answer.json",
            "session_question_score.json"
          ] do
        definition = load_definition!(filename)

        refute Enum.any?(definition.fields, &(&1.name == "id")),
               "#{filename}: declares a field named id where a constraints entry is expected instead"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # REQ-329 AC -- session_event is named session_event, not tab_switch_event,
  # and declares the added event_type field with its three enum values.
  # ---------------------------------------------------------------------------

  describe "session_event naming and added event_type field (REQ-329)" do
    test "session_event's own name field is session_event, not tab_switch_event" do
      definition = load_definition!("session_event.json")
      assert definition.name == "session_event"
    end

    test "session_event declares event_type as :enum with exactly [tab_switch, blur, fullscreen_exit]" do
      definition = load_definition!("session_event.json")
      f = field(definition, "event_type")
      assert f != nil
      assert f.type == :enum
      assert f.enum_values == ["tab_switch", "blur", "fullscreen_exit"]
    end
  end
end
