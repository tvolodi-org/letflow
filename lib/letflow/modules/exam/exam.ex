defmodule Letflow.Modules.Exam do
  @moduledoc """
  The first real tenant-installable module extracted from the platform's exam
  domain, added in REQ-408. It owns the candidate-facing exam-session grant
  set and the route-policy mapping for the exam endpoints.

  REQ-410 completes the extraction: the runtime logic and HTTP router are now
  co-located under `lib/letflow/modules/exam/`, served at
  `/api/v1/modules/exam/exam-sessions/…` via the D4/D5 gate in
  `Letflow.Routers.Modules` (REQ-404).

  REQ-411 moves the bilimbaga pack from `priv/packs/bilimbaga/` to
  `priv/modules/exam/` (the exam module owns it) and ports the answer-key
  `entity_field_restrictions` seeding that previously lived in the deleted
  `Letflow.Packs.Bilimbaga` module into `on_install/2` here.  The pack's
  `pack_id` is `"bilimbaga-question-bank"` (unchanged); see
  `priv/modules/exam/pack.json`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.Exam.ParentRollout
  alias Letflow.Modules.Exam.Snapshot.Rollout
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  # The five `(entity_type, field_name)` pairs whose values a TASK_WORKER-
  # scoped caller must never read in clear via the generic
  # POST /entities/query or POST /entities/query/aggregate routes.
  # Mirrors the list that used to live in `Letflow.Packs.Bilimbaga`
  # (deleted in REQ-411), plus (GH #2682 / REQ-511) `session.exam_snapshot`, the
  # per-session copy of the answer key.  `Letflow.Modules.Exam.Session.get_session_state_for_user/3`'s
  # own hand-assembled response allowlist is kept as complementary defense-
  # in-depth (see its moduledoc); these rows guard the GENERIC routes.
  @answer_key_fields [
    {"question", "explanation"},
    {"answer_option", "is_correct"},
    {"answer_option", "likert_weight"},
    {"answer_option", "likert_polarity"},
    {"session", "exam_snapshot"}
  ]

  @impl true
  defmanifest(
    id: "exam",
    version: "0.1.0",
    depends_on: [],
    pack: "modules/exam/pack.json",
    permissions: [
      :ExamSessionStart,
      :ExamSessionRead,
      :ExamSessionSave,
      :ExamSessionSubmit,
      :ExamSessionReportEvent,
      :ExamCertificateIssue,
      :ExamAuthoringWrite,
      :ExamGradingRead,
      :ExamGradingWrite
    ],
    role_grants: %{
      CANDIDATE: [
        :ExamSessionStart,
        :ExamSessionRead,
        :ExamSessionSave,
        :ExamSessionSubmit,
        :ExamSessionReportEvent,
        :ExamCertificateIssue
      ]
    },
    required_roles: [],
    # GH #2596: the six runtime/result types. GH #2680 slice 3: the ten authoring types too; the
    # module's own authoring surface (`Letflow.Modules.Exam.Authoring`) is their only writer.
    # REQ-582: exam_assignment (who an exam is assigned to), written only with the exam module's authority.
    manages_entity_types: [
      "certificate",
      "session",
      "session_answer",
      "session_event",
      "session_question",
      "session_question_score",
      "exam",
      "exam_section",
      "exam_question_rule",
      "exam_question_rule_tag",
      "exam_manual_question",
      "question",
      "answer_option",
      "question_tag",
      "tag",
      "category",
      "exam_assignment"
    ],
    settings_schema: nil,
    route_policies: [
      {"POST", "/exam-sessions", :ExamSessionStart},
      {"GET", "/exam-sessions/available", :ExamSessionStart},
      {"GET", "/exam-sessions/:id", :ExamSessionRead},
      {"PUT", "/exam-sessions/:id/answers/:question_id", :ExamSessionSave},
      {"POST", "/exam-sessions/:id/submit", :ExamSessionSubmit},
      {"POST", "/exam-sessions/:id/events", :ExamSessionReportEvent},
      {"POST", "/exam-sessions/:id/certificate", :ExamCertificateIssue},
      {"GET", "/exam-sessions/:id/certificate/download", :ExamCertificateIssue},
      {"POST", "/authoring/:entity_type", :ExamAuthoringWrite},
      {"PUT", "/authoring/:entity_type/:record_id", :ExamAuthoringWrite},
      {"DELETE", "/authoring/:entity_type/:record_id", :ExamAuthoringWrite},
      {"GET", "/grading-queue", :ExamGradingRead},
      {"GET", "/grading-queue/:session_id/:question_id", :ExamGradingRead},
      {"POST", "/grading-queue/:session_id/:question_id/grade", :ExamGradingWrite}
    ]
  )

  @impl true
  def router, do: Letflow.Modules.Exam.Router

  @doc """
  Seeds the `entity_field_restrictions` rows that prevent TASK_WORKER-scoped
  callers from reading answer-key fields via the generic
  `POST /entities/query` / `POST /entities/query/aggregate` routes (ISS-0647,
  REQ-411).

  Idempotent: `on_conflict: :nothing` against
  `entity_field_restrictions_entity_type_field_name_idx`, so calling this
  more than once against the same tenant schema is a safe no-op for rows
  that already exist.

  This callback is invoked by `Letflow.Modules.Installs.install/3` inside
  the install transaction, after the pack is installed (D5).
  """
  @impl true
  @spec on_install(prefix :: String.t(), settings :: map()) :: :ok
  def on_install(prefix, _settings) when is_binary(prefix) do
    _added = insert_missing_restrictions(prefix)
    :ok
  end

  @doc """
  Idempotently inserts every pair of `answer_key_fields/0` that has no
  `entity_field_restrictions` row in the tenant schema `prefix` (GH #2682 / REQ-511, design
  8.5): `on_install/2` runs once, so a tenant installed before REQ-411 (or before the
  `session.exam_snapshot` pair existed) can lack rows. Returns the number of rows added.
  """
  @spec ensure_answer_key_restrictions(prefix :: String.t()) ::
          {:ok, added :: non_neg_integer()} | {:error, :invalid_schema_name}
  def ensure_answer_key_restrictions(prefix) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, insert_missing_restrictions(prefix)}
    end
  end

  defp insert_missing_restrictions(prefix) do
    now = NaiveDateTime.utc_now()

    rows =
      Enum.map(@answer_key_fields, fn {entity_type, field_name} ->
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: now,
          updated_at: now
        }
      end)

    {added, _} =
      Repo.insert_all(
        "entity_field_restrictions",
        rows,
        prefix: prefix,
        on_conflict: :nothing,
        conflict_target: [:entity_type, :field_name]
      )

    added
  end

  @doc """
  GH #2682 / REQ-511: runs the exam snapshot rollout (`Letflow.Modules.Exam.Snapshot.Rollout.run/1`).
  Code outside this module's directory reaches it only through `Letflow.Modules.Catalog` (the
  module-boundary rule), which is how `Letflow.Release.ExamSnapshot` calls it.
  """
  @spec snapshot_rollout(opts :: keyword()) :: {:ok, Rollout.report()}
  def snapshot_rollout(opts) when is_list(opts), do: Rollout.run(opts)

  @doc "The read-only rollout readiness check (`Letflow.Modules.Exam.Snapshot.Rollout.verify/0`)."
  @spec snapshot_verify() :: %{ready: boolean(), tenants: [Rollout.tenant_check()]}
  def snapshot_verify, do: Rollout.verify()

  @doc """
  GH #3315 / REQ-586 part C: runs the `parent_id` rollout for tenants that installed the pack before
  part A (`Letflow.Modules.Exam.ParentRollout.run/1`); reached from outside this directory only
  through `Letflow.Modules.Catalog`, as `Letflow.Release.ExamParentId` does.
  """
  @spec parent_rollout(opts :: keyword()) :: {:ok, ParentRollout.report()}
  def parent_rollout(opts) when is_list(opts), do: ParentRollout.run(opts)

  @doc "The read-only readiness check of the `parent_id` rollout (`ParentRollout.verify/0`)."
  @spec parent_rollout_verify() :: %{ready: boolean(), tenants: [ParentRollout.tenant_check()]}
  def parent_rollout_verify, do: ParentRollout.verify()

  @doc "The `(entity_type, field_name)` pairs this module restricts — exposed for tests."
  @spec answer_key_fields() :: [{String.t(), String.t()}]
  def answer_key_fields, do: @answer_key_fields
end
