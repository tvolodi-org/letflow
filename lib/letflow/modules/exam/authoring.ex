defmodule Letflow.Modules.Exam.Authoring do
  @moduledoc """
  GH #2680 / REQ-510 slice 1: the exam module's own write surface for its ten authoring types
  (`exam`, `exam_section`, `exam_question_rule`, `exam_question_rule_tag`, `exam_manual_question`,
  `question`, `answer_option`, `question_tag`, `tag`, `category`).

  Domain side of `POST/PUT/DELETE /api/v1/modules/exam/authoring/...` (the routes, the body
  schemas and the response rendering are in `Letflow.Modules.Exam.Router`). Every write goes
  through `Letflow.Entities.Records.*_record/3` with the exam module's own Owner
  (`ManagedTypes.owner_for!/1`, the same as `Letflow.Modules.Exam.Session`). The manifest's
  `manages_entity_types` declares these ten types (GH #2680 slice 3), so the generic `/records`
  routes refuse them with `entity_type_managed`; this surface is the only writer that is left.

  `access/3` is the module counterpart of `Letflow.Entities.RecordAccess.write/3` WITHOUT its
  managed-type refusal: that function answers `:managed` for a stamped type, and this surface is
  the managing module's own path. It keeps the other three reads (per-user type access, active
  definition, restricted fields), so INV-2 parity with the generic route holds. Total and fail
  closed: a denied type, an absent definition or a failed read is the one `:hidden`.

  The type list is a closed allow-list: any other type (a runtime type such as `session`, an
  unknown name) is `:not_authoring`, which the router answers with the constant 404.
  """

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.Entities.TypeAccess
  alias Letflow.Modules.Exam

  @authoring_types [
    "exam",
    "exam_section",
    "exam_question_rule",
    "exam_question_rule_tag",
    "exam_manual_question",
    "question",
    "answer_option",
    "question_tag",
    "tag",
    "category"
  ]

  @type access :: :not_authoring | :hidden | {:open, MapSet.t(String.t())}

  @doc "The ten authoring entity types this surface writes."
  @spec authoring_types() :: [String.t()]
  def authoring_types, do: @authoring_types

  @doc """
  Decides what the caller may do with `entity_type`: `:not_authoring` (not one of
  `authoring_types/0`), `:hidden` (denied, no active definition, or a failed read), or
  `{:open, restricted}` with the caller's restricted field set.
  """
  @spec access(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) :: access()
  def access(user_id, entity_type, prefix)
      when is_binary(user_id) and is_binary(entity_type) and is_binary(prefix) do
    if entity_type in @authoring_types do
      type_access = TypeAccess.authorized?(user_id, entity_type, prefix)
      definition = Definitions.get_active_definition_by_name(entity_type, prefix)
      restrictions = FieldGrants.load_restrictions(user_id, entity_type, prefix)

      decide(type_access, definition, restrictions)
    else
      :not_authoring
    end
  end

  def access(_user_id, _entity_type, _prefix), do: :not_authoring

  defp decide({:ok, :allowed}, {:ok, _definition}, {:ok, restricted}), do: {:open, restricted}
  defp decide(_type_access, _definition, _restrictions), do: :hidden

  @doc "Creates a record of an authoring type; `attrs` as `Records.create_record/3`."
  @spec create(Records.create_attrs(), prefix :: String.t()) ::
          {:ok, Records.command_result()} | Records.command_error()
  def create(%{entity_type: entity_type} = attrs, prefix) when entity_type in @authoring_types,
    # scope-all: SEC-518-R1 (exam module, tenant-wide route; own-record system path)
    do: Records.create_record(attrs, prefix, exam_owner())

  @doc "Replaces the `field_values` of a record of an authoring type (`Records.update_record/3`)."
  @spec update(Records.update_attrs(), prefix :: String.t()) ::
          {:ok, Records.command_result()} | Records.command_error()
  def update(%{entity_type: entity_type} = attrs, prefix) when entity_type in @authoring_types,
    # scope-all: SEC-518-R1 (exam module, tenant-wide route; own-record system path)
    do: Records.update_record(attrs, prefix, exam_owner())

  @doc "Soft-deletes a record of an authoring type (`Records.delete_record/3`)."
  @spec delete(Records.delete_attrs(), prefix :: String.t()) ::
          {:ok, Records.command_result()} | Records.command_error()
  def delete(%{entity_type: entity_type} = attrs, prefix) when entity_type in @authoring_types,
    # scope-all: SEC-518-R1 (exam module, tenant-wide route; own-record system path)
    do: Records.delete_record(attrs, prefix, exam_owner())

  @doc """
  Creates an `exam_assignment` record with the exam module's own authority (REQ-582). The type is
  not an authoring type and no route writes it yet; this is the system path for the mix seed task.
  """
  @spec create_assignment(Records.create_attrs(), prefix :: String.t()) ::
          {:ok, Records.command_result()} | Records.command_error()
  def create_assignment(%{entity_type: "exam_assignment"} = attrs, prefix),
    # scope-all: REQ-582 seed task, own-record system path (no HTTP user)
    do: Records.create_record(attrs, prefix, exam_owner())

  # Built per call, never stored (as `Session.exam_owner/0`).
  @spec exam_owner() :: ManagedTypes.Owner.t()
  defp exam_owner, do: ManagedTypes.owner_for!(Exam)
end
