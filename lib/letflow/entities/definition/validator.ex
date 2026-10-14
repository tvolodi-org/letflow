defmodule Letflow.Entities.Definition.Validator do
  @moduledoc """
  The 13 structural validation rules for an `Letflow.Entities.Definition.t()`
  document (REQ-225, extended by REQ-301). See
  `lib/letflow/design/req225-entity-definition-schema-validation.md` §3 for
  the full design rules 1-9 implement, and
  `lib/letflow/design/req301-localized-text-field-type.md` §2 for rules 10
  and 11 (the `:locales`/`:search_strategy` shape rules REQ-301 adds).

  This module validates one document's own **internal** structural
  consistency only -- it takes no `tenant_id`, performs no persistence
  lookups, and never calls `Letflow.Repository` (REQ-226's job). It also
  performs no canonicalisation or hashing (`Letflow.Entities.Definition.Shape`'s
  job).

  ## Malformed-shape precondition (design §3 preamble)

  Basic shape/type checking (the document is a map with the required
  top-level keys; `fields` is a list of maps; each field's `type` is one of
  the 9 known atoms; every string-typed field is actually a string) is a
  precondition every one of the 11 numbered rules assumes has already
  passed. A document that fails this precondition is rejected with
  `{:error, [%Violation{rule: :malformed, ...}]}` -- `:malformed` is not one
  of the 11 numbered rules and is checked first, short-circuiting before any
  numbered rule runs.
  """

  alias Letflow.Entities.Definition

  defmodule Violation do
    @moduledoc "One structural-validation failure. See `Letflow.Entities.Definition.Validator`'s `t:violation/0`."
    defstruct [:rule, :path, :message]
  end

  @typedoc """
  One structural-validation failure. `rule` identifies exactly which of the
  11 rules fired; `path` locates the offending element inside the
  definition document as a list of keys/indices-by-name; `message` is a
  human-readable detail string, never used by callers to distinguish which
  rule fired (that is `rule`'s job).
  """
  @type violation :: %Violation{
          rule: atom(),
          path: [atom() | String.t()],
          message: String.t()
        }

  @name_format_regex ~r/^[a-z][a-z0-9_]{0,63}$/
  @locale_format_regex ~r/^[a-z]{2,8}$/
  @field_types [
    :string,
    :integer,
    :decimal,
    :boolean,
    :date,
    :datetime,
    :enum,
    :json,
    :localized_text
  ]

  @max_fields 200
  @max_indexes 32
  @max_fk_or_constraints 32

  @doc """
  Runs the malformed-shape precondition check followed by all 11 numbered
  rules against `definition`, collecting **every** violation found (not
  short-circuiting on the first) except that a `:malformed` failure
  short-circuits before any numbered rule runs. Returns `:ok` only when zero
  violations are found.
  """
  @spec validate(definition :: Definition.t()) :: :ok | {:error, [violation()]}
  def validate(definition) do
    case malformed_violations(definition) do
      [] ->
        violations =
          name_format_violations(definition) ++
            duplicate_name_violations(definition) ++
            queried_json_violations(definition) ++
            index_field_coverage_violations(definition) ++
            fk_field_coverage_violations(definition) ++
            enum_violations(definition) ++
            decimal_violations(definition) ++
            localized_text_violations(definition) ++
            search_strategy_violations(definition) ++
            cardinality_violations(definition)

        case violations do
          [] -> :ok
          _ -> {:error, violations}
        end

      malformed ->
        {:error, malformed}
    end
  end

  # --- malformed-shape precondition ------------------------------------------

  defp malformed_violations(definition) when not is_map(definition) do
    [malformed([], "definition must be a map")]
  end

  defp malformed_violations(definition) do
    []
    |> check_required_string(definition, :name)
    |> check_required_string(definition, :display_name)
    |> check_optional_string(definition, :description)
    |> check_required_list_of_maps(definition, :fields)
    |> check_optional_list_of_maps(definition, :indexes)
    |> check_optional_list_of_maps(definition, :foreign_keys)
    |> check_optional_list_of_maps(definition, :constraints)
    |> check_optional_boolean(definition, :append_only)
    |> then(fn violations ->
      if violations == [] do
        violations
        |> Kernel.++(field_shape_violations(get_list(definition, :fields)))
        |> Kernel.++(index_shape_violations(get_list(definition, :indexes)))
        |> Kernel.++(fk_shape_violations(get_list(definition, :foreign_keys)))
        |> Kernel.++(constraint_shape_violations(get_list(definition, :constraints)))
      else
        violations
      end
    end)
  end

  defp check_required_string(violations, definition, key) do
    case Map.fetch(definition, key) do
      {:ok, value} when is_binary(value) -> violations
      {:ok, _other} -> [malformed([key], "#{key} must be a string") | violations]
      :error -> [malformed([key], "#{key} is required") | violations]
    end
  end

  defp check_optional_string(violations, definition, key) do
    case Map.get(definition, key) do
      nil -> violations
      value when is_binary(value) -> violations
      _other -> [malformed([key], "#{key} must be a string") | violations]
    end
  end

  # GH #2529: `Map.fetch/2`, not `Map.get/2`, so a present `nil` (JSON null
  # arriving through a pack) is malformed rather than treated as absent -- a
  # stored null would change the content hash of a mutable type.
  @spec check_optional_boolean([violation()], Definition.t() | map(), atom()) :: [violation()]
  defp check_optional_boolean(violations, definition, key) do
    case Map.fetch(definition, key) do
      :error -> violations
      {:ok, value} when is_boolean(value) -> violations
      {:ok, _other} -> [malformed([key], "#{key} must be a boolean") | violations]
    end
  end

  defp check_required_list_of_maps(violations, definition, key) do
    case Map.fetch(definition, key) do
      {:ok, value} when is_list(value) ->
        if Enum.all?(value, &is_map/1) do
          violations
        else
          [malformed([key], "#{key} entries must all be maps") | violations]
        end

      {:ok, _other} ->
        [malformed([key], "#{key} must be a list") | violations]

      :error ->
        [malformed([key], "#{key} is required") | violations]
    end
  end

  defp check_optional_list_of_maps(violations, definition, key) do
    case Map.get(definition, key) do
      nil ->
        violations

      value when is_list(value) ->
        if Enum.all?(value, &is_map/1) do
          violations
        else
          [malformed([key], "#{key} entries must all be maps") | violations]
        end

      _other ->
        [malformed([key], "#{key} must be a list") | violations]
    end
  end

  defp field_shape_violations(fields) do
    Enum.flat_map(fields, fn field ->
      name = Map.get(field, :name)

      cond do
        not is_binary(Map.get(field, :name)) ->
          [malformed([:fields], "field name must be a string")]

        Map.get(field, :type) not in @field_types ->
          [malformed([:fields, name], "field type must be one of #{inspect(@field_types)}")]

        true ->
          []
      end
    end)
  end

  defp index_shape_violations(indexes) do
    Enum.flat_map(indexes, fn index ->
      cond do
        not is_binary(Map.get(index, :name)) ->
          [malformed([:indexes], "index name must be a string")]

        not (is_list(Map.get(index, :fields)) and Map.get(index, :fields) != []) ->
          [malformed([:indexes, Map.get(index, :name)], "index fields must be a non-empty list")]

        true ->
          []
      end
    end)
  end

  defp fk_shape_violations(fks) do
    Enum.flat_map(fks, fn fk ->
      cond do
        not is_binary(Map.get(fk, :name)) ->
          [malformed([:foreign_keys], "fk name must be a string")]

        not is_binary(Map.get(fk, :field)) ->
          [malformed([:foreign_keys, Map.get(fk, :name)], "fk field must be a string")]

        not is_binary(Map.get(fk, :references_entity)) ->
          [
            malformed(
              [:foreign_keys, Map.get(fk, :name)],
              "fk references_entity must be a string"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp constraint_shape_violations(constraints) do
    Enum.flat_map(constraints, fn constraint ->
      cond do
        not is_binary(Map.get(constraint, :name)) ->
          [malformed([:constraints], "constraint name must be a string")]

        Map.get(constraint, :type) != :unique ->
          [
            malformed(
              [:constraints, Map.get(constraint, :name)],
              "constraint type must be :unique"
            )
          ]

        not (is_list(Map.get(constraint, :fields)) and Map.get(constraint, :fields) != []) ->
          [
            malformed(
              [:constraints, Map.get(constraint, :name)],
              "constraint fields must be a non-empty list"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp malformed(path, message), do: %Violation{rule: :malformed, path: path, message: message}

  # --- accessors --------------------------------------------------------------

  defp get_list(definition, key), do: Map.get(definition, key) || []

  # --- Rule 1 -- name format (:name_format) -----------------------------------

  defp name_format_violations(definition) do
    name = Map.get(definition, :name)

    if Regex.match?(@name_format_regex, name) do
      []
    else
      [
        %Violation{
          rule: :name_format,
          path: [:name],
          message: "must match ^[a-z][a-z0-9_]{0,63}$"
        }
      ]
    end
  end

  # --- Rule 2 -- name uniqueness (:duplicate_name) -----------------------------

  defp duplicate_name_violations(definition) do
    duplicates_in_scope(get_list(definition, :fields), :fields) ++
      duplicates_in_scope(get_list(definition, :indexes), :indexes) ++
      duplicates_in_scope(
        get_list(definition, :foreign_keys) ++ get_list(definition, :constraints),
        :foreign_keys
      )
  end

  defp duplicates_in_scope(entries, scope) do
    entries
    |> Enum.map(&Map.get(&1, :name))
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} ->
      %Violation{
        rule: :duplicate_name,
        path: [scope, name],
        message: "duplicate name within scope #{inspect(scope)}"
      }
    end)
  end

  # --- Rule 3 -- queried + :json mutual exclusion (:queried_json_conflict) ----

  defp queried_json_violations(definition) do
    definition
    |> get_list(:fields)
    |> Enum.filter(fn field -> Map.get(field, :type) == :json and Map.get(field, :queried) end)
    |> Enum.map(fn field ->
      %Violation{
        rule: :queried_json_conflict,
        path: [:fields, Map.get(field, :name)],
        message: "a :json field cannot be queried: true"
      }
    end)
  end

  # --- Rule 4 -- index field coverage ------------------------------------------

  defp index_field_coverage_violations(definition) do
    fields_by_name = Map.new(get_list(definition, :fields), &{Map.get(&1, :name), &1})

    definition
    |> get_list(:indexes)
    |> Enum.flat_map(fn index ->
      index_name = Map.get(index, :name)

      Enum.flat_map(Map.get(index, :fields, []), fn field_name ->
        case Map.get(fields_by_name, field_name) do
          nil ->
            [
              %Violation{
                rule: :index_field_not_found,
                path: [:indexes, index_name, :fields, field_name],
                message: "field \"#{field_name}\" not found in fields"
              }
            ]

          field ->
            if Map.get(field, :queried) do
              []
            else
              [
                %Violation{
                  rule: :index_field_not_queried,
                  path: [:indexes, index_name, :fields, field_name],
                  message: "field \"#{field_name}\" is not queried: true"
                }
              ]
            end
        end
      end)
    end)
  end

  # --- Rule 5 -- FK field coverage (:fk_field_not_found) -----------------------

  defp fk_field_coverage_violations(definition) do
    field_names = MapSet.new(get_list(definition, :fields), &Map.get(&1, :name))

    fk_violations =
      definition
      |> get_list(:foreign_keys)
      |> Enum.filter(fn fk -> not MapSet.member?(field_names, Map.get(fk, :field)) end)
      |> Enum.map(fn fk ->
        field = Map.get(fk, :field)

        %Violation{
          rule: :fk_field_not_found,
          path: [:foreign_keys, Map.get(fk, :name), :field],
          message: "field \"#{field}\" not found in fields"
        }
      end)

    constraint_violations =
      definition
      |> get_list(:constraints)
      |> Enum.flat_map(fn constraint ->
        constraint_name = Map.get(constraint, :name)

        constraint
        |> Map.get(:fields, [])
        |> Enum.filter(&(not MapSet.member?(field_names, &1)))
        |> Enum.map(fn field ->
          %Violation{
            rule: :fk_field_not_found,
            path: [:constraints, constraint_name, :fields, field],
            message: "field \"#{field}\" not found in fields"
          }
        end)
      end)

    fk_violations ++ constraint_violations
  end

  # --- Rule 6 -- enum validity (:invalid_enum) ---------------------------------

  defp enum_violations(definition) do
    definition
    |> get_list(:fields)
    |> Enum.flat_map(fn field ->
      name = Map.get(field, :name)
      type = Map.get(field, :type)
      enum_values = Map.get(field, :enum_values)

      cond do
        type == :enum and not (is_list(enum_values) and enum_values != []) ->
          [
            %Violation{
              rule: :invalid_enum,
              path: [:fields, name, :enum_values],
              message: "enum_values must be a non-empty list when type is :enum"
            }
          ]

        type == :enum and length(Enum.uniq(enum_values)) != length(enum_values) ->
          [
            %Violation{
              rule: :invalid_enum,
              path: [:fields, name, :enum_values],
              message: "enum_values must not contain duplicates"
            }
          ]

        type != :enum and enum_values != nil ->
          [
            %Violation{
              rule: :invalid_enum,
              path: [:fields, name, :enum_values],
              message: "enum_values must be absent when type is not :enum"
            }
          ]

        true ->
          []
      end
    end)
  end

  # --- Rule 7 -- decimal-field validation (:invalid_decimal) -------------------

  defp decimal_violations(definition) do
    definition
    |> get_list(:fields)
    |> Enum.flat_map(fn field ->
      name = Map.get(field, :name)
      type = Map.get(field, :type)
      precision = Map.get(field, :decimal_precision)
      scale = Map.get(field, :decimal_scale)

      cond do
        type == :decimal and (precision == nil or scale == nil) ->
          [
            %Violation{
              rule: :invalid_decimal,
              path: [:fields, name],
              message:
                "decimal_precision and decimal_scale are both required when type is :decimal"
            }
          ]

        type == :decimal and scale > precision ->
          [
            %Violation{
              rule: :invalid_decimal,
              path: [:fields, name],
              message: "decimal_scale must not exceed decimal_precision"
            }
          ]

        type != :decimal and (precision != nil or scale != nil) ->
          [
            %Violation{
              rule: :invalid_decimal,
              path: [:fields, name],
              message:
                "decimal_precision and decimal_scale must be absent when type is not :decimal"
            }
          ]

        true ->
          []
      end
    end)
  end

  # --- Rule 10 -- locale-set shape (:invalid_localized_text) -------------------

  defp localized_text_violations(definition) do
    definition
    |> get_list(:fields)
    |> Enum.flat_map(fn field ->
      name = Map.get(field, :name)
      type = Map.get(field, :type)
      locales = Map.get(field, :locales)

      cond do
        type == :localized_text and not (is_list(locales) and locales != []) ->
          [
            %Violation{
              rule: :invalid_localized_text,
              path: [:fields, name, :locales],
              message: "locales must be a non-empty list when type is :localized_text"
            }
          ]

        type == :localized_text and length(Enum.uniq(locales)) != length(locales) ->
          [
            %Violation{
              rule: :invalid_localized_text,
              path: [:fields, name, :locales],
              message: "locales must not contain duplicates"
            }
          ]

        type == :localized_text and not Enum.all?(locales, &locale_format_valid?/1) ->
          Enum.flat_map(locales, fn locale ->
            if locale_format_valid?(locale) do
              []
            else
              [
                %Violation{
                  rule: :invalid_localized_text,
                  path: [:fields, name, :locales],
                  message: "locale #{inspect(locale)} must match ^[a-z]{2,8}$"
                }
              ]
            end
          end)

        type != :localized_text and locales != nil ->
          [
            %Violation{
              rule: :invalid_localized_text,
              path: [:fields, name, :locales],
              message: "locales must be absent when type is not :localized_text"
            }
          ]

        true ->
          []
      end
    end)
  end

  defp locale_format_valid?(locale) when is_binary(locale),
    do: Regex.match?(@locale_format_regex, locale)

  defp locale_format_valid?(_locale), do: false

  # --- Rule 11 -- search_strategy shape (:invalid_search_strategy) -------------

  defp search_strategy_violations(definition) do
    definition
    |> get_list(:fields)
    |> Enum.flat_map(fn field ->
      name = Map.get(field, :name)
      type = Map.get(field, :type)
      search_strategy = Map.get(field, :search_strategy)

      cond do
        type == :localized_text and search_strategy not in [nil, :plain, :fulltext] ->
          [
            %Violation{
              rule: :invalid_search_strategy,
              path: [:fields, name, :search_strategy],
              message: "search_strategy must be :plain or :fulltext"
            }
          ]

        type != :localized_text and search_strategy != nil ->
          [
            %Violation{
              rule: :invalid_search_strategy,
              path: [:fields, name, :search_strategy],
              message: "search_strategy must be absent when type is not :localized_text"
            }
          ]

        true ->
          []
      end
    end)
  end

  # --- Rules 8a/8b/8c -- cardinality limits -------------------------------------

  defp cardinality_violations(definition) do
    fields_count = length(get_list(definition, :fields))
    indexes_count = length(get_list(definition, :indexes))

    fk_or_constraints_count =
      length(get_list(definition, :foreign_keys)) + length(get_list(definition, :constraints))

    []
    |> maybe_prepend(fields_count > @max_fields, %Violation{
      rule: :too_many_fields,
      path: [:fields],
      message: "at most #{@max_fields} fields allowed, got #{fields_count}"
    })
    |> maybe_prepend(indexes_count > @max_indexes, %Violation{
      rule: :too_many_indexes,
      path: [:indexes],
      message: "at most #{@max_indexes} indexes allowed, got #{indexes_count}"
    })
    |> maybe_prepend(fk_or_constraints_count > @max_fk_or_constraints, %Violation{
      rule: :too_many_fk_or_constraints,
      path: [:foreign_keys],
      message:
        "combined foreign_keys + constraints count must be at most #{@max_fk_or_constraints}, got #{fk_or_constraints_count}"
    })
  end

  defp maybe_prepend(list, true, item), do: [item | list]
  defp maybe_prepend(list, false, _item), do: list

  # --- Rule 9 -- lifted (REQ-324) -----------------------------------------
  #
  # This rule used to reject any foreign key whose references_entity equaled
  # the definition's own name (:self_referential_fk). REQ-225's own design
  # doc (lib/letflow/design/req225-entity-definition-schema-validation.md,
  # numbered open item 4) named that outright reject a deliberate, narrow
  # choice made only because REQ-225's own description named
  # "self-referential-FK rejection" as one of its rule categories -- not
  # because a self-referential relationship is itself invalid -- and said
  # explicitly: "If a real tenant need for self-referential entity
  # hierarchies surfaces later, that is a follow-up requirement revising
  # this rule, not something this slice should quietly special-case now."
  # REQ-324 (S10 gap 14) is that follow-up: a self-referential fk_def is now
  # a legal document shape. Every OTHER Rule 5 (fk_field_coverage) /
  # Rule 9-adjacent invariant still applies to a self-referential fk exactly
  # as it does to any other fk -- lifting this rule removes only the
  # self-target check, nothing else.
end
