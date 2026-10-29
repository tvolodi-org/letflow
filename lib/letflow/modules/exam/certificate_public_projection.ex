defmodule Letflow.Modules.Exam.CertificatePublicProjection do
  @moduledoc """
  REQ-357 -- the `Letflow.PublicRead.Projection` for the `"certificate"`
  kind (design `lib/letflow/design/req357-certificate-public-projection.md`
  §2). Colocated with the rest of `Letflow.Modules.Exam.*` deliberately (per that
  design's §2.1) -- `Letflow.PublicRead.*` is REQ-323/0028's own
  vocabulary-neutral platform namespace and must stay free of
  vertical-specific modules.

  ## `schema/0` and the `resource_id`/primary-key substitution (design §2.2)

  Returns `Letflow.Entities.Record.Latest` -- the bucket-A current-state
  table `Letflow.Modules.Exam.Certificate` (REQ-355) writes `certificate` entity
  records into. This is only correct because `Letflow.PublicRead.resolve/2`
  calls `Repo.get(schema(), handle.resource_id, prefix: prefix)`, and
  `Repo.get/3` matches on the Ecto PRIMARY KEY -- `Letflow.Entities.
  Record.Latest`'s own `id`, NOT its `record_id` column (a distinct,
  non-key field every OTHER surface in this vertical uses instead, e.g.
  `Letflow.Modules.Exam.Certificate.certificate_view/1`'s own `"id"` field). The
  wiring in `Letflow.Modules.Exam.Certificate`/`Letflow.Modules.Exam.Router` MUST
  pass `record.id` -- never `record.record_id` -- as `issue_handle/4`'s
  `resource_id` argument, or resolution silently 404s forever. See the
  design doc for the full reasoning (this module does not re-derive it).

  ## Purity (behaviour contract, `Letflow.PublicRead.Projection`)

  `project/2` reads only `resource.field_values` (already captured in full
  at issuance time by `Letflow.Modules.Exam.Certificate`) and literal constants --
  no `Repo` call, no `Application` read, no clock read. Nothing here needs
  a second lookup of anything.

  ## Publishability predicate (design §2.3)

  `:skip` when `resource.deleted == true` (soft-deleted certificate
  records) -- otherwise `{:ok, data}`. No write path in this vertical sets
  `deleted` on a certificate today, but `Letflow.Entities.Record.Latest`
  carries the field generically and a future admin/retraction path could,
  so the predicate holds regardless.

  ## Field set (design §2.3's justification table -- not restated here)

  Exactly `candidate_name`, `exam_title`, `score_pct`, `issued_on`,
  `branding_snapshot`. Deliberately excludes `session_id`, any record
  identifier (`id`/`record_id`), `tenant_id`, and any candidate
  `user_id`/email -- see the design doc's exclusion table for the
  per-field reasoning.

  `branding_snapshot` is returned whole. Since REQ-595 it may contain
  `signatory_name` and `signatory_title`: tenant-set strings printed on the
  paper certificate, visible on this unauthenticated verify endpoint for
  certificates issued after REQ-595. They are absent for older certificates
  and when the tenant had not set them.
  """

  @behaviour Letflow.PublicRead.Projection

  alias Letflow.Entities.Record.Latest

  @impl true
  @spec schema() :: module()
  def schema, do: Latest

  @impl true
  @spec project(Latest.t(), Letflow.PublicRead.Projection.handle_meta()) ::
          {:ok, %{String.t() => term()}} | :skip
  def project(%Latest{deleted: true}, _handle_meta), do: :skip

  def project(%Latest{field_values: field_values}, _handle_meta) do
    {:ok,
     %{
       "candidate_name" => Map.get(field_values, "candidate_name"),
       "exam_title" => Map.get(field_values, "exam_title"),
       "score_pct" => to_float(Map.get(field_values, "score_pct")),
       "issued_on" => Map.get(field_values, "issued_at"),
       "branding_snapshot" => Map.get(field_values, "branding_snapshot")
     }}
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(nil), do: nil
end
