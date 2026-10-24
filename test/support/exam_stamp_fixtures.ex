defmodule Letflow.ExamStampFixtures do
  @moduledoc """
  Shared fixtures for the GH #2596 exam managed-type tests (design
  `lib/letflow/design/gh2596-exam-managed-types.md` sections 7 and 14; spec
  `test/specs/GH2596-exam-managed.md`).

  Every tenant built here commits real DDL and real rows (`Sandbox.mode(:auto)`, set by
  `Letflow.TenantFixture.provisioned_tenant!/1` and `Letflow.ExamFixtures`), because
  `Letflow.Entities.ManagedTypes.Stamp` and `TamperInventory` refuse to run inside a transaction.
  Callers must be `async: false`. Teardown is registered with `on_exit/1` here.

  Builds of the six runtime definition rows, each UNSTAMPED (the installed-before-the-change
  state, case (b) of the design):

    * b1 `legacy_tenant!/1`: FK-stripped legacy rows (`Letflow.ExamFixtures`), the shape ISS-0690
      says QA/BilimBaga hold;
    * b2 `bare_tenant!/2` + `install_pack!/1`: pack-shaped rows (full foreign keys) installed as
      `:tenant`, so unstamped;
    * b3 `legacy_definition/1` + `create_definition!/2`: hand-posted rows (an extra tenant field,
      no indexes).

  This module is under `test/support/`, which the `ManagedTypesCallersTest` scan covers: it never
  calls `owner_for!`, builds an `Owner`, or passes a non-`:tenant` Records authority.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.ExamFixtures
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @definitions_dir Path.join([File.cwd!(), "priv", "modules", "exam", "entity_definitions"])
  @pack_path Path.join([File.cwd!(), "priv", "modules", "exam", "pack.json"])

  @runtime_types ~w(certificate session session_answer session_event session_question session_question_score)

  @authoring_types ~w(answer_option category exam exam_manual_question exam_question_rule
                      exam_question_rule_tag exam_section question question_tag tag)

  @exception_version 20_261_024_120_001

  @type tenant :: %{tenant_id: Ecto.UUID.t(), schema_name: String.t()}

  @doc "The six runtime/result type names the exam manifest manages."
  @spec runtime_types() :: [String.t()]
  def runtime_types, do: @runtime_types

  @doc "The ten authoring type names the exam module manages since GH #2680 slice 3."
  @spec authoring_types() :: [String.t()]
  def authoring_types, do: @authoring_types

  @doc "The tenant-schema `schema_migrations` version of `AllowExamAuthoringManagedByStamp` (sixteen names)."
  @spec exception_version() :: pos_integer()
  def exception_version, do: @exception_version

  @doc "b1: legacy FK-stripped rows, active, with the exam `tenant_modules` row inserted directly."
  @spec legacy_tenant!(slug_prefix :: String.t()) :: tenant()
  def legacy_tenant!(slug_prefix) do
    ExamFixtures.provisioned_tenant_with_exam_definitions(slug_prefix)
  end

  @doc """
  A provisioned tenant with NO entity definitions. `exam_row?` inserts the `tenant_modules` row for
  `exam` directly (never via `Installs.install/3`). Registers the global-table cleanup the pack
  install and column promotion need before the tenant row can be deleted.
  """
  @spec bare_tenant!(slug_prefix :: String.t(), exam_row? :: boolean()) :: tenant()
  def bare_tenant!(slug_prefix, exam_row?) when is_boolean(exam_row?) do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    # Registered after the fixture's own on_exit, so it runs FIRST (LIFO).
    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^fixture.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^fixture.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^fixture.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(fixture.schema_name)
    if exam_row?, do: insert_exam_row!(fixture.schema_name)

    %{tenant_id: fixture.tenant_id, schema_name: fixture.schema_name}
  end

  @doc """
  GH #2682 / REQ-511 PR b: like `bare_tenant!(slug, true)`, plus the answer-key field restriction
  rows (`Exam.ensure_answer_key_restrictions/1`) a rolled-out exam tenant holds. A real `Stamp` run
  refuses a tenant without them (`:snapshot_prerequisite_missing`), so every stamp test that builds
  its definitions by hand starts from this tenant; the definitions it creates carry the `session`
  field `exam_snapshot` themselves (`legacy_definition/1` reads the committed definition files).
  """
  @spec stamp_ready_tenant!(slug_prefix :: String.t()) :: tenant()
  def stamp_ready_tenant!(slug_prefix) do
    tenant = bare_tenant!(slug_prefix, true)
    assert {:ok, _added} = Exam.ensure_answer_key_restrictions(tenant.schema_name)
    tenant
  end

  @doc """
  A tenant with the exam `tenant_modules` row and ALL sixteen exam definitions created (legacy,
  FK-stripped, no constraints so no column promotion) and ACTIVE, unstamped, plus the answer-key
  field restrictions `Exam.on_install/2` seeds. The state of an exam tenant installed before the
  stamp, with every type usable through the generic record routes.
  """
  @spec full_tenant!(slug_prefix :: String.t()) :: tenant()
  def full_tenant!(slug_prefix) do
    tenant = bare_tenant!(slug_prefix, true)

    for name <- @authoring_types ++ @runtime_types do
      create_definition!(tenant.schema_name, Map.put(legacy_definition(name), :constraints, []))
      activate!(tenant.schema_name, name)
    end

    :ok = Exam.on_install(tenant.schema_name, %{})
    tenant
  end

  @doc "Inserts an active internal user in the tenant schema (a session candidate or an actor)."
  @spec insert_user!(schema :: String.t()) :: struct()
  def insert_user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2596-user-#{Ecto.UUID.generate()}",
      display_name: "GH2596 User",
      email: "gh2596-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  @doc """
  One certifiable exam with one single-choice question and a random rule drawing it. All AUTHORING
  types (unmanaged), so it works before or after the stamp. Returns the exam record and the
  question and correct-option ids.
  """
  @spec build_exam!(schema :: String.t()) :: %{
          exam: map(),
          question_id: String.t(),
          correct_id: String.t()
        }
  def build_exam!(schema) do
    category_id = Ecto.UUID.generate()

    exam =
      ExamFixtures.create_record!(schema, "exam", %{
        "title" => %{"en" => "GH2596 Exam"},
        "status" => "active",
        "time_limit_minutes" => 30,
        "passing_score_pct" => 60.0,
        "max_attempts" => 5,
        "shuffle_questions" => false,
        "shuffle_options" => false,
        "show_answers" => "never",
        "on_tab_switch" => "log",
        "certificate_enabled" => true
      })

    question =
      ExamFixtures.create_record!(schema, "question", %{
        "category_id" => category_id,
        "difficulty" => "easy",
        "type" => "single",
        "default_locale" => "en",
        "status" => "active",
        "version" => 1,
        "stem" => %{"en" => "Stem?"}
      })

    correct =
      ExamFixtures.create_record!(schema, "answer_option", %{
        "question_id" => question.record_id,
        "sort_order" => 0,
        "is_correct" => true,
        "text" => %{"en" => "Correct"}
      })

    ExamFixtures.create_record!(schema, "answer_option", %{
      "question_id" => question.record_id,
      "sort_order" => 1,
      "is_correct" => false,
      "text" => %{"en" => "Wrong"}
    })

    ExamFixtures.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 1,
      "sort_order" => 0
    })

    %{exam: exam, question_id: question.record_id, correct_id: correct.record_id}
  end

  @doc "Inserts the `tenant_modules` row for `exam` directly (the D5 gate's row)."
  @spec insert_exam_row!(schema :: String.t()) :: :ok
  def insert_exam_row!(schema) do
    %TenantModule{}
    |> TenantModule.insert_changeset(%{
      module_id: "exam",
      version: Exam.manifest().version,
      installed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
      settings: %{}
    })
    |> Repo.insert!(prefix: schema)

    :ok
  end

  @doc "The committed pack document, decoded."
  @spec pack_document() :: map()
  def pack_document, do: @pack_path |> File.read!() |> Jason.decode!()

  @doc "b2: installs the committed pack as `:tenant` (no Owner), so every row is unstamped."
  @spec install_pack!(schema :: String.t()) :: :ok
  def install_pack!(schema) do
    assert {:ok, _result} =
             SolutionPack.install(pack_document(), Ecto.UUID.generate(), prefix: schema)

    :ok
  end

  @doc """
  The pack's own definition of `name` as the atom-keyed shape `Definitions.create_definition/2`
  takes, with foreign keys stripped (as `Letflow.ExamFixtures` builds them).
  """
  @spec legacy_definition(name :: String.t()) :: map()
  def legacy_definition(name) do
    json = @definitions_dir |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()

    %{
      name: Map.fetch!(json, "name"),
      display_name: Map.fetch!(json, "display_name"),
      fields: json |> Map.get("fields", []) |> Enum.map(&to_field/1),
      indexes:
        json
        |> Map.get("indexes", [])
        |> Enum.map(&%{name: Map.fetch!(&1, "name"), fields: Map.fetch!(&1, "fields")}),
      foreign_keys: [],
      constraints: []
    }
  end

  @doc "One field in the atom-keyed shape `legacy_definition/1` uses."
  @spec field(name :: String.t(), type :: atom()) :: map()
  def field(name, type) do
    %{
      name: name,
      type: type,
      required: false,
      queried: false,
      enum_values: nil,
      decimal_precision: nil,
      decimal_scale: nil,
      locales: nil,
      search_strategy: nil
    }
  end

  @doc "Creates (inactive) a definition as `:tenant`, asserting success; returns the row."
  @spec create_definition!(schema :: String.t(), definition :: map()) ::
          Letflow.Entities.EntityDefinition.t()
  def create_definition!(schema, definition) do
    assert {:ok, row} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    row
  end

  @doc "Activates the named definition as `:tenant`."
  @spec activate!(schema :: String.t(), name :: String.t()) :: :ok
  def activate!(schema, name) do
    assert {:ok, _row} =
             Definitions.activate_definition(name, Ecto.UUID.generate(), "gh2596 test", schema)

    :ok
  end

  @doc """
  Inserts a copy of `row` (a name that already has a definition) as a separate version stamped
  `module_id`: the "stamped by another module" state. The BEFORE UPDATE/DELETE triggers do not fire
  on INSERT, so this is the only way a test can plant such a row.
  """
  @spec insert_stamped_copy!(
          schema :: String.t(),
          row :: Letflow.Entities.EntityDefinition.t(),
          module_id :: String.t()
        ) ::
          Letflow.Entities.EntityDefinition.t()
  def insert_stamped_copy!(schema, row, module_id) do
    row
    |> Ecto.put_meta(state: :built)
    |> Map.merge(%{
      id: Ecto.UUID.generate(),
      logical_shape_version: :crypto.strong_rand_bytes(32),
      status: :inactive,
      managed_by: module_id
    })
    |> Repo.insert!(prefix: schema)
  end

  @doc "Every `entity_definitions` row of `names` as a comparable dump (whole row as JSON text)."
  @spec dump(schema :: String.t(), names :: [String.t()]) :: [map()]
  def dump(schema, names) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT id::text, name, managed_by, status::text, to_jsonb(d)::text | <>
          ~s|FROM "#{schema}".entity_definitions d WHERE name = ANY($1) ORDER BY name, id|,
        [names]
      )

    for [id, name, managed_by, status, json] <- rows,
        do: %{id: id, name: name, managed_by: managed_by, status: status, json: json}
  end

  @doc "`%{name => sorted distinct managed_by values}` for every definition of the tenant."
  @spec managed_by_map(schema :: String.t()) :: %{String.t() => [String.t() | nil]}
  def managed_by_map(schema) do
    %{rows: rows} =
      Repo.query!(~s|SELECT name, managed_by FROM "#{schema}".entity_definitions|)

    rows
    |> Enum.group_by(&hd/1, &List.last/1)
    |> Map.new(fn {name, values} -> {name, values |> Enum.uniq() |> Enum.sort()} end)
  end

  @doc "The number of stamp audit entries in the tenant schema."
  @spec stamp_audit_count(schema :: String.t()) :: non_neg_integer()
  def stamp_audit_count(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".audit_entries WHERE action = 'entity_type.managed_by_stamped'|
      )

    n
  end

  @doc "Deletes the tenant schema's `schema_migrations` row of the exception migration."
  @spec forget_exception_migration!(schema :: String.t()) :: :ok
  def forget_exception_migration!(schema) do
    Repo.query!(~s|DELETE FROM "#{schema}".schema_migrations WHERE version = $1|, [
      @exception_version
    ])

    :ok
  end

  @doc "Re-inserts the exception migration's `schema_migrations` row."
  @spec remember_exception_migration!(schema :: String.t()) :: :ok
  def remember_exception_migration!(schema) do
    Repo.query!(
      ~s|INSERT INTO "#{schema}".schema_migrations (version, inserted_at) VALUES ($1, now())|,
      [@exception_version]
    )

    :ok
  end

  defp to_field(field) do
    %{
      name: Map.fetch!(field, "name"),
      type: String.to_atom(Map.fetch!(field, "type")),
      required: Map.get(field, "required", false),
      queried: Map.get(field, "queried", false),
      enum_values: Map.get(field, "enum_values"),
      decimal_precision: Map.get(field, "decimal_precision"),
      decimal_scale: Map.get(field, "decimal_scale"),
      locales: Map.get(field, "locales"),
      search_strategy: field |> Map.get("search_strategy") |> search_strategy_atom()
    }
  end

  defp search_strategy_atom(nil), do: nil
  defp search_strategy_atom(value) when is_binary(value), do: String.to_atom(value)
end
