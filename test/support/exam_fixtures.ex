defmodule Letflow.ExamFixtures do
  @moduledoc """
  Shared REQ-332/REQ-333 test fixture: provisions a real tenant schema and
  installs just enough of the bilimbaga entity definitions (`exam`,
  `question`, `answer_option`, `exam_question_rule`, `exam_manual_question`,
  `session`, `session_question`, `session_answer`, `session_question_score`,
  `session_event`) for
  `Letflow.Modules.Exam.Session`/`Letflow.Modules.Exam.QuestionSetResolver`/
  `Letflow.Modules.Exam.Scoring`/`Letflow.Modules.Exam.AntiCheat` integration tests, without a full
  `Letflow.Definitions.SolutionPack.install/3` (no column promotion, no
  per-type table -- every field this suite filters on is already
  `queried: true` in the real `priv/packs/bilimbaga/entity_definitions/*.json`
  documents, so `Letflow.Entities.Query.Compiler` reads them straight off
  `entity_record_latest`'s JSONB `field_values`). Mirrors
  `test/letflow/entities/query_joins_test.exs`'s own hand-rolled
  tenant-fixture pattern (DIRECTIVE T-4).

  REQ-410: `provisioned_tenant_with_exam_definitions/1` also installs the
  `"exam"` module (`Letflow.Modules.Installs.install/3`) so the D5 gate in
  `Letflow.Routers.Modules` admits exam-session requests for this tenant.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Identity.Tenant
  alias Letflow.Modules.Exam
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.Registration

  @definitions_dir Path.join([File.cwd!(), "priv", "modules", "exam", "entity_definitions"])

  @entity_types ~w(exam question answer_option exam_question_rule exam_manual_question
                    session session_question session_answer session_question_score
                    session_event certificate)

  # `category` is deliberately NOT in `@entity_types` above: every EXISTING
  # caller of `provisioned_tenant_with_exam_definitions/1`
  # (`session_test.exs`, `query_joins_test.exs`, `exam_sessions_test.exs`'s
  # own `build_minimal_exam!/2`) passes a bare `Ecto.UUID.generate()` as a
  # question's `category_id` field value -- a raw, never-activated,
  # never-dereferenced foreign value -- and none of those suites ever writes
  # a real `category` entity record. `activate_exam_definitions!/1` below
  # DOES need it activated: `Mix.Tasks.Letflow.Seed.ExamFixtures` creates
  # real `category` entity records via `Letflow.Entities.Records.create_record/2`,
  # which requires an ACTIVE `category` definition to exist first
  # (`{:definition_not_found, "category"}` otherwise -- confirmed empirically
  # while writing `letflow.seed.exam_fixtures_test.exs`). Kept as a separate
  # list, not folded into `@entity_types`, so this addition cannot change
  # behavior for any of `provisioned_tenant_with_exam_definitions/1`'s
  # existing callers.
  @extra_entity_types_for_exam_fixtures_task ~w(category)

  # GH #2596: the six runtime/result types the exam manifest manages. A real
  # `Installs.install("exam", ...)` stamps their pack rows `managed_by = 'exam'`, after which a
  # `:tenant` `Definitions.create_definition/2` of the same name is refused
  # (`:entity_type_managed`); `activate_exam_definitions_after_pack_install!/1` below therefore
  # ACTIVATES the pack's own stamped rows instead of creating fixture versions of them.
  @runtime_entity_types ~w(session session_question session_answer session_question_score
                           session_event certificate)

  @doc """
  Provisions a fresh tenant schema, seeds event types, and activates every
  entity definition this suite needs -- real definitions read directly from
  `priv/packs/bilimbaga/entity_definitions/*.json` (converted to
  `Letflow.Entities.Definition.t()`'s atom-keyed shape), not hand-abbreviated
  copies. Sets `Ecto.Adapters.SQL.Sandbox` to `:auto` mode -- provisioning
  commits real DDL outside any sandboxed transaction, and the concurrent-
  submit test needs genuinely concurrent connections.
  """
  @spec provisioned_tenant_with_exam_definitions(slug_prefix :: String.t()) :: %{
          tenant_id: Ecto.UUID.t(),
          schema_name: String.t()
        }
  def provisioned_tenant_with_exam_definitions(slug_prefix) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!(slug_prefix)

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))

      # ISS-0648 fix note: `session_question` (and any other entity type in
      # this fixture's list that declares a `constraints` entry) is now
      # auto-promoted on activation, which inserts a real
      # `entity_column_promotions` row -- a GLOBAL table with an FK to
      # `tenants` (same class of cleanup gap
      # `test/letflow/entities/iss0648_column_promotion_trigger_test.exs`'s
      # own `provisioned_tenant/0` and
      # `test/letflow/packs/bilimbaga_pack_install_test.exs`'s own tenant
      # fixture already guard against). Without this, deleting the `tenants`
      # row below raises a `foreign_key_violation` in `on_exit` for every
      # test using this fixture, once any of its entity types has a
      # constraint.
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.id))

      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)
    assert {:ok, _seed_result} = Letflow.Entities.EventTypes.seed!(schema_name)

    activate_exam_definitions!(schema_name)

    # REQ-411: insert the tenant_modules row for the exam module directly,
    # bypassing `Letflow.Modules.Installs.install/3`'s pack-install step.
    # After REQ-411 the exam manifest's `pack` field is set, so `Installs.install/3`
    # would also attempt `SolutionPack.install` — which conflicts with the
    # entity definitions activate_exam_definitions!/1 just created inline
    # (different logical_shape_version due to FK-stripping). This fixture's
    # purpose is lightweight exam-session testing, not pack-install testing;
    # the restriction seeding was already done by activate_exam_definitions!/1
    # (via Exam.on_install/2). Inserting the TenantModule row directly gives
    # the D5 gate the row it needs without a redundant pack install.
    %TenantModule{}
    |> TenantModule.insert_changeset(%{
      module_id: "exam",
      version: Exam.manifest().version,
      installed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
      settings: %{}
    })
    |> Repo.insert!(prefix: schema_name)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  @doc """
  REQ-410 AC3 fixture: provisions a fresh tenant schema with exam definitions
  but WITHOUT installing the exam module. Use this to test that the D5 gate
  in `Letflow.Routers.Modules` returns 404 for requests when no
  `tenant_modules` row for the exam module exists.
  """
  @spec provisioned_tenant_without_module_install(slug_prefix :: String.t()) :: %{
          tenant_id: Ecto.UUID.t(),
          schema_name: String.t()
        }
  def provisioned_tenant_without_module_install(slug_prefix) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!(slug_prefix)

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)
    assert {:ok, _seed_result} = Letflow.Entities.EventTypes.seed!(schema_name)

    activate_exam_definitions!(schema_name)

    # Deliberately do NOT install the exam module here -- this fixture is
    # specifically for testing the D5 gate's 404 response when no
    # tenant_modules row exists.

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  @doc """
  GH #2581: records the exam module as installed in `schema_name` (a `tenant_modules` row,
  no pack install). A tenant that has not installed exam cannot create the exam module's
  managed type names through the tenant path; a test that installs the exam pack with
  `SolutionPack.install/3` directly calls this first.
  """
  @spec mark_exam_installed!(schema_name :: String.t()) :: TenantModule.t()
  def mark_exam_installed!(schema_name) do
    %TenantModule{}
    |> TenantModule.insert_changeset(%{
      module_id: "exam",
      version: Exam.manifest().version,
      installed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
      settings: %{}
    })
    |> Repo.insert!(prefix: schema_name)
  end

  @doc """
  Activates this fixture's full exam entity-definition set (`@entity_types`)
  into an ALREADY-provisioned tenant schema named `schema_name`.

  Unlike `provisioned_tenant_with_exam_definitions/1`, this does not create a
  tenant, provision a schema, seed event types, or set
  `Ecto.Adapters.SQL.Sandbox` mode -- the caller owns tenant/schema lifecycle
  and Sandbox mode itself. Added for
  `test/mix/tasks/letflow.seed.exam_fixtures_test.exs` (REQ-345), which needs
  the SPECIFIC `bpm-default` tenant/schema `mix letflow.seed` provisions (a
  fixed, hardcoded realm, not one `Letflow.TenantFixture`/this module's own
  `insert_tenant!/1` can produce -- both mint a fixture-generated unique
  slug), so it cannot use `provisioned_tenant_with_exam_definitions/1`
  wholesale but still needs the exact same real
  `priv/modules/exam/entity_definitions/*.json` definitions activated
  before `Mix.Tasks.Letflow.Seed.ExamFixtures.run/1` can write any exam
  content -- `mix letflow.seed` alone provisions the tenant schema and
  replays its migrations only; it installs no entity definition at all
  (its own `@moduledoc` says so plainly). Reuses the exact same
  `create_active_definition!/2`/`load_definition!/1` machinery
  `provisioned_tenant_with_exam_definitions/1` itself uses, so both callers
  get byte-identical real pack definitions, not two independently
  hand-maintained copies.
  """
  @spec activate_exam_definitions!(schema_name :: String.t()) :: :ok
  def activate_exam_definitions!(schema_name) do
    for entity_type <- @entity_types ++ @extra_entity_types_for_exam_fixtures_task do
      create_active_definition!(schema_name, load_definition!(entity_type))
    end

    # ISS-0647 / REQ-411: seed the answer-key field restrictions via the
    # exam module's on_install/2 callback. Without this, every exam-suite
    # test built on this fixture would exercise a tenant where
    # `is_correct`/`likert_weight`/`likert_polarity`/`explanation` are
    # reachable in clear via the generic `POST /entities/query` route for
    # any TASK_WORKER-scoped caller.
    :ok = Exam.on_install(schema_name, %{})

    :ok
  end

  @doc """
  GH #2596: like `activate_exam_definitions!/1`, for a tenant that went through the REAL
  `Installs.install("exam", ...)`: the six managed runtime types (`session`, `session_question`,
  `session_answer`, `session_question_score`, `session_event`, `certificate`) already exist from the
  pack, stamped `managed_by = 'exam'`, so they are ACTIVATED as installed (a `:tenant`
  `create_definition/2` of those names is refused). The authoring types (and `category`) are created
  and activated from `priv/modules/exam/entity_definitions/*.json` exactly as in
  `activate_exam_definitions!/1`. `Exam.on_install/2` is not called again (the install ran it).
  """
  @spec activate_exam_definitions_after_pack_install!(schema_name :: String.t()) :: :ok
  def activate_exam_definitions_after_pack_install!(schema_name) do
    authoring =
      (@entity_types -- @runtime_entity_types) ++ @extra_entity_types_for_exam_fixtures_task

    for entity_type <- authoring do
      create_active_definition!(schema_name, load_definition!(entity_type))
    end

    for entity_type <- @runtime_entity_types do
      assert {:ok, _activated} =
               Definitions.activate_definition(
                 entity_type,
                 Ecto.UUID.generate(),
                 "go-live",
                 schema_name
               )
    end

    :ok
  end

  @doc """
  GH #2680: activates the authoring types `provisioned_tenant_with_exam_definitions/1` leaves out
  (`exam_section`, `exam_question_rule_tag`, `question_tag`, `tag`), from the same pack
  definitions, so the whole authoring surface of the exam module can be written in a test tenant.
  Kept separate so no existing caller of the provisioning function changes behaviour.
  """
  @spec activate_remaining_authoring_definitions!(schema_name :: String.t()) :: :ok
  def activate_remaining_authoring_definitions!(schema_name) do
    for entity_type <- ~w(exam_section exam_question_rule_tag question_tag tag) do
      create_active_definition!(schema_name, load_definition!(entity_type))
    end

    :ok
  end

  @doc "Creates a record via `Letflow.Entities.Records.create_record/2`, asserting success."
  @spec create_record!(String.t(), String.t(), map(), Ecto.UUID.t()) ::
          Letflow.Entities.Record.Latest.t()
  def create_record!(schema, entity_type, field_values, actor_id \\ Ecto.UUID.generate()) do
    assert {:ok, %{record: record}} =
             Records.create_record(
               %{
                 entity_type: entity_type,
                 field_values: field_values,
                 actor_id: actor_id,
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    record
  end

  # ---------------------------------------------------------------------
  # GH #2682 / REQ-511 snapshot helpers (tests only)
  # ---------------------------------------------------------------------

  @doc """
  The digest `Letflow.Modules.Exam.Snapshot` stores: `"sha256:"` plus the lowercase hex of the
  SHA-256 of the canonical encoding of the snapshot WITHOUT its `"digest"` key. Computed here, in
  the test support, from `Snapshot.canonical_encode/1` only, so a test can forge a structurally
  valid snapshot (for example one with no `exam` object) that the production builder refuses to
  produce.
  """
  @spec snapshot_digest(map()) :: String.t()
  def snapshot_digest(snapshot) when is_map(snapshot) do
    hash =
      snapshot
      |> Map.delete("digest")
      |> Exam.Snapshot.canonical_encode()
      |> then(&:crypto.hash(:sha256, &1))

    "sha256:" <> Base.encode16(hash, case: :lower)
  end

  @doc "`snapshot` with its `\"digest\"` recomputed over the current content."
  @spec with_digest(map()) :: map()
  def with_digest(snapshot) when is_map(snapshot),
    do: Map.put(snapshot, "digest", snapshot_digest(snapshot))

  @doc """
  A valid start-origin snapshot with NO questions (threshold `"60"`), built by the production
  builder. For a hand-built session that is submitted without ever having a question set.
  """
  @spec empty_snapshot!(exam_id :: String.t()) :: map()
  def empty_snapshot!(exam_id) when is_binary(exam_id) do
    assert {:ok, snapshot} =
             Exam.Snapshot.build_from_resolved(
               %{
                 "passing_score_pct" => 60.0,
                 "certificate_enabled" => false,
                 "title" => %{"en" => "Exam"},
                 "time_limit_minutes" => 30
               },
               %{},
               [],
               %{origin: :start, exam_id: exam_id, taken_at: DateTime.utc_now()}
             )

    snapshot
  end

  @doc """
  Merges `changes` into the CURRENT field values of a record through the ordinary
  `Records.update_record/2` write path (full replacement of the merged map), asserting success.
  Returns the updated record.
  """
  @spec update_record!(String.t(), String.t(), Ecto.UUID.t(), map()) ::
          Letflow.Entities.Record.Latest.t()
  def update_record!(schema, entity_type, record_id, changes) when is_map(changes) do
    assert {:ok, current} = Latest.get(record_id, entity_type, schema)

    assert {:ok, %{record: record}} =
             Records.update_record(
               %{
                 entity_type: entity_type,
                 record_id: record_id,
                 field_values: Map.merge(current.field_values, changes),
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    record
  end

  @doc """
  Soft-deletes a record through `Records.delete_record/2`, asserting success.
  """
  @spec delete_record!(String.t(), String.t(), Ecto.UUID.t()) :: :ok
  def delete_record!(schema, entity_type, record_id) do
    assert {:ok, _result} =
             Records.delete_record(
               %{
                 entity_type: entity_type,
                 record_id: record_id,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    :ok
  end

  @doc """
  Writes one field of a record's `entity_record_latest` projection DIRECTLY (no validation, no
  event), the way `session_test.exs` seeds a corrupted status. `{:put, value}` sets it, `:delete`
  removes the key. For states the validated write path refuses (a nil required threshold, a
  tampered snapshot whose digest was left stale).
  """
  @spec force_field!(String.t(), String.t(), Ecto.UUID.t(), String.t(), {:put, term()} | :delete) ::
          :ok
  def force_field!(schema, entity_type, record_id, key, change) do
    assert {:ok, row} = Latest.get(record_id, entity_type, schema)

    field_values =
      case change do
        {:put, value} -> Map.put(row.field_values, key, value)
        :delete -> Map.delete(row.field_values, key)
      end

    assert {:ok, _updated} =
             row
             |> Latest.update_changeset(%{field_values: field_values})
             |> Repo.update(prefix: schema)

    :ok
  end

  @doc """
  GH #2682 / REQ-511 PR b: turns a session into a LEGACY (pre-ship) one, design 18.5 fixture rule
  (the one helper every legacy-session test uses). The fixtures carry `exam_snapshot` from install,
  so a plain session is "after the cutover"; this makes it look like a session started before the
  rollout:

    * removes `exam_snapshot` from the stored `field_values` (a direct test-support write, not a
      production path),
    * moves the session RECORD's `entity_record_latest.inserted_at` one hour before the tenant's
      `Snapshot.cutover/1` (the cutover itself cannot be edited: the activation history is
      append-only, so the session side is moved),
    * sets the `started_at` field before the cutover and `expires_at` one hour in the future (so a
      deadline check does not interfere).

  Works for any status (a submitted session is made a legacy submitted one the same way). Returns
  `:ok`.
  """
  @spec legacy_session!(String.t(), Ecto.UUID.t()) :: :ok
  def legacy_session!(schema, session_id) do
    assert {:ok, cutover} = Exam.Snapshot.cutover(schema)
    inserted_at = DateTime.add(cutover, -3600, :second)
    started_at = DateTime.add(cutover, -3000, :second)
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    assert {:ok, row} = Latest.get(session_id, "session", schema)

    field_values =
      row.field_values
      |> Map.delete("exam_snapshot")
      |> Map.merge(%{
        "started_at" => DateTime.to_iso8601(started_at),
        "expires_at" => DateTime.to_iso8601(expires_at)
      })

    assert {:ok, _updated} =
             row
             |> Latest.update_changeset(%{field_values: field_values})
             |> Repo.update(prefix: schema)

    assert {1, _} =
             Repo.update_all(
               from(l in Latest, where: l.id == ^row.id),
               [set: [inserted_at: inserted_at]],
               prefix: schema
             )

    :ok
  end

  @doc "The stored `exam_snapshot` of a session (decoded map), or nil when the field is absent."
  @spec session_snapshot(String.t(), Ecto.UUID.t()) :: map() | nil
  def session_snapshot(schema, session_id) do
    assert {:ok, row} = Latest.get(session_id, "session", schema)
    Map.get(row.field_values, "exam_snapshot")
  end

  @doc """
  Applies `fun` (snapshot map -> snapshot map, string keys) to a session's stored snapshot,
  recomputes the digest and writes it back through `Records.update_record/2`. For forging a
  structurally valid snapshot (a missing threshold, an extra question item).
  """
  @spec rewrite_snapshot!(String.t(), Ecto.UUID.t(), (map() -> map())) :: map()
  def rewrite_snapshot!(schema, session_id, fun) when is_function(fun, 1) do
    rewritten = schema |> session_snapshot(session_id) |> fun.() |> with_digest()
    update_record!(schema, "session", session_id, %{"exam_snapshot" => rewritten})
    rewritten
  end

  @doc """
  Replaces the tenant's ACTIVE `session` definition with a new version that does NOT declare
  `exam_snapshot` (the shape of a tenant installed before GH #2682): a tenant the rollout has not
  reached yet.
  """
  @spec downgrade_session_definition!(schema_name :: String.t()) :: :ok
  def downgrade_session_definition!(schema_name) do
    definition = load_definition!("session")

    create_active_definition!(
      schema_name,
      Map.update!(definition, :fields, fn fields ->
        Enum.reject(fields, &(&1.name == "exam_snapshot"))
      end)
    )

    :ok
  end

  @doc """
  Like `downgrade_session_definition!/1`, but the new version carries NO nil-valued optional field
  keys (`search_strategy`, `enum_values`, `locales`, `decimal_*` are left out instead of being
  stored as JSON null): the shape of a definition posted as a plain JSON document rather than
  built from the pack files.
  """
  @spec downgrade_session_definition_without_nils!(schema_name :: String.t()) :: :ok
  def downgrade_session_definition_without_nils!(schema_name) do
    definition = load_definition!("session")

    create_active_definition!(
      schema_name,
      Map.update!(definition, :fields, fn fields ->
        fields
        |> Enum.reject(&(&1.name == "exam_snapshot"))
        |> Enum.map(fn field -> Map.reject(field, fn {_key, value} -> is_nil(value) end) end)
      end)
    )

    :ok
  end

  @doc "Removes the restriction rows of every `answer_key_fields/0` pair from the tenant schema."
  @spec delete_answer_key_restrictions!(schema_name :: String.t()) :: non_neg_integer()
  def delete_answer_key_restrictions!(schema_name) do
    {count, _} = Repo.delete_all("entity_field_restrictions", prefix: schema_name)
    count
  end

  # ---------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------

  defp insert_tenant!(slug_prefix) do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug(slug_prefix),
        display_name: "REQ-332 Exam Session Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp create_active_definition!(schema, definition) do
    # GH #2581: the tenant path refuses module-managed names of a module not installed yet.
    entity_definition = Letflow.ManagedTypesSupport.plant_legacy_definition!(schema, definition)

    assert {:ok, activated} =
             Definitions.activate_definition(
               entity_definition.name,
               Ecto.UUID.generate(),
               "go-live",
               schema
             )

    activated
  end

  defp load_definition!(entity_type) do
    @definitions_dir
    |> Path.join("#{entity_type}.json")
    |> File.read!()
    |> Jason.decode!()
    |> to_definition()
  end

  defp to_definition(json) do
    %{
      name: Map.fetch!(json, "name"),
      display_name: Map.fetch!(json, "display_name"),
      fields: json |> Map.get("fields", []) |> Enum.map(&to_field/1),
      indexes: json |> Map.get("indexes", []) |> Enum.map(&to_index/1),
      foreign_keys: [],
      constraints: json |> Map.get("constraints", []) |> Enum.map(&to_constraint/1)
    }
  end

  # foreign_keys are deliberately dropped: this fixture never promotes a
  # column, so a real Postgres FK is never emitted for these definitions --
  # keeping fk_def entries would be dead configuration, and REQ-300 joins are
  # not exercised by this suite (Session resolves relations via plain
  # Query.Compiler filters, not Compiler joins).
  defp to_field(field) do
    %{
      name: Map.fetch!(field, "name"),
      # `String.to_atom/1`, not `to_existing_atom/1`: this fixture can run
      # before any production code path has referenced e.g. `:localized_text`
      # as a literal, so the atom may not exist in the VM's atom table yet.
      # The field-type vocabulary is a small, fixed, closed set either way
      # (`Letflow.Entities.Definition.field_type()`), so this carries none of
      # the unbounded-atom-creation risk `to_existing_atom/1` guards against
      # in production code paths that see caller-controlled strings.
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

  defp to_index(index) do
    %{name: Map.fetch!(index, "name"), fields: Map.fetch!(index, "fields")}
  end

  defp to_constraint(constraint) do
    %{
      name: Map.fetch!(constraint, "name"),
      type: String.to_atom(Map.fetch!(constraint, "type")),
      fields: Map.fetch!(constraint, "fields")
    }
  end
end
