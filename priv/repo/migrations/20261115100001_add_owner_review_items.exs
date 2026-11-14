defmodule Letflow.Repo.Migrations.AddOwnerReviewItems do
  @moduledoc """
  T-1963 part A: the owner list (review items and their thread) as a second class of `problem_reports`.

  `problem_reports` gains `class` (`problem` | `review`) and the item fields; the status CHECK becomes
  class-aware (the six lab states in snake case for `review`); `reporter_user_id` may be NULL for review
  rows only (an item is addressed to the holders of the `ProblemReportsManage` atom). Two new tables:
  `problem_report_comments` (the thread) and `problem_report_comment_images` (PNG/JPEG bytes, at most 6
  per entry by a unique position).

  TENANT-SCOPED MIGRATION (the `if prefix() do` guard is mandatory; registered last in
  `Letflow.TenantProvisioning`'s manifest). Written only in the platform company's schema, like
  `problem_reports`. Existing rows become `class = 'problem'` through the column default; nothing is
  rewritten. No SQL interpolates request data (INV-7): the only interpolated value is the schema name
  from `prefix()`.

  `down` deletes every `review` row (its comments and images go by cascade), drops the new tables, and
  restores the previous column shape and status CHECK.
  """
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()
      q = "\"#{schema}\".problem_reports"

      alter table(:problem_reports) do
        add :class, :string, size: 16, null: false, default: "problem"
        add :owner_ref, :string, size: 16
        add :kind, :string, size: 16
        add :steps, :text
        add :why, :text
        add :recommended, :text
        add :answer, :text
        add :source, :string, size: 64
        add :tasks, {:array, :string}, null: false, default: []
        add :due, :date
        add :cycle, :integer, null: false, default: 1
        add :closed_at, :utc_datetime_usec
      end

      execute("ALTER TABLE #{q} ALTER COLUMN reporter_user_id DROP NOT NULL")
      drop constraint(:problem_reports, :problem_reports_status)

      create constraint(:problem_reports, :problem_reports_class,
               check: "class IN ('problem','review')"
             )

      create constraint(:problem_reports, :problem_reports_status,
               check:
                 "(class = 'problem' AND status IN ('received','in_work','answered','fixed','not_done')) OR " <>
                   "(class = 'review' AND status IN ('for_review','waiting','owner_reviewed','in_work','ready','closed'))"
             )

      create constraint(:problem_reports, :problem_reports_owner_ref,
               check:
                 "((class = 'review') = (owner_ref IS NOT NULL)) AND " <>
                   "(owner_ref IS NULL OR owner_ref ~ '^O-[0-9]{3,6}$')"
             )

      create constraint(:problem_reports, :problem_reports_kind,
               check:
                 "(class = 'problem' AND kind IS NULL) OR " <>
                   "(class = 'review' AND kind IN ('review','question','decision','communication','subscription'))"
             )

      create constraint(:problem_reports, :problem_reports_reporter,
               check: "class = 'review' OR reporter_user_id IS NOT NULL"
             )

      create constraint(:problem_reports, :problem_reports_item_len,
               check:
                 "(steps IS NULL OR char_length(steps) <= 4000) AND (why IS NULL OR char_length(why) <= 1000) AND " <>
                   "(recommended IS NULL OR char_length(recommended) <= 2000) AND " <>
                   "(answer IS NULL OR char_length(answer) <= 4000) AND cycle >= 1"
             )

      create unique_index(:problem_reports, [:owner_ref], where: "owner_ref IS NOT NULL")
      create index(:problem_reports, [:class, :status, :seq])

      create table(:problem_report_comments, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :seq, :bigserial, null: false
        add :tenant_id, :binary_id, null: false

        add :report_id, references(:problem_reports, type: :binary_id, on_delete: :delete_all),
          null: false

        add :author, :string, size: 16, null: false
        add :author_user_id, :binary_id
        add :type, :string, size: 16, null: false
        add :text, :text, null: false, default: ""
        add :tasks, :string, size: 500, null: false, default: ""
        add :lesson, :string, size: 2000, null: false, default: ""
        add :cycle, :integer, null: false
        add :forwarded, :boolean, null: false, default: false
        add :inserted_at, :utc_datetime_usec, null: false
      end

      create unique_index(:problem_report_comments, [:seq])
      create index(:problem_report_comments, [:report_id, :seq])

      create constraint(:problem_report_comments, :problem_report_comments_author,
               check: "author IN ('owner','operator','pm')"
             )

      create constraint(:problem_report_comments, :problem_report_comments_type,
               check: "type IN ('finding','answer','note','ready')"
             )

      create constraint(:problem_report_comments, :problem_report_comments_text_len,
               check: "char_length(text) <= 4000 AND cycle >= 1"
             )

      create table(:problem_report_comment_images, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :report_id, references(:problem_reports, type: :binary_id, on_delete: :delete_all),
          null: false

        add :comment_id,
            references(:problem_report_comments, type: :binary_id, on_delete: :delete_all),
            null: false

        add :position, :smallint, null: false
        add :content_type, :string, size: 16, null: false
        add :byte_size, :integer, null: false
        add :bytes, :binary, null: false
        add :inserted_at, :utc_datetime_usec, null: false
      end

      create unique_index(:problem_report_comment_images, [:comment_id, :position])
      create index(:problem_report_comment_images, [:report_id])

      create constraint(:problem_report_comment_images, :problem_report_images_position,
               check: "position BETWEEN 1 AND 6"
             )

      create constraint(:problem_report_comment_images, :problem_report_images_type,
               check: "content_type IN ('image/png','image/jpeg')"
             )

      create constraint(:problem_report_comment_images, :problem_report_images_size,
               check: "byte_size BETWEEN 1 AND 5242880"
             )
    end
  end

  def down do
    if prefix() do
      schema = prefix()
      q = "\"#{schema}\".problem_reports"

      drop table(:problem_report_comment_images)
      drop table(:problem_report_comments)
      execute("DELETE FROM #{q} WHERE class = 'review'")

      drop constraint(:problem_reports, :problem_reports_status)
      drop constraint(:problem_reports, :problem_reports_reporter)
      drop constraint(:problem_reports, :problem_reports_item_len)
      drop constraint(:problem_reports, :problem_reports_kind)
      drop constraint(:problem_reports, :problem_reports_owner_ref)
      drop constraint(:problem_reports, :problem_reports_class)
      drop index(:problem_reports, [:class, :status, :seq])
      drop index(:problem_reports, [:owner_ref])

      alter table(:problem_reports) do
        remove :class
        remove :owner_ref
        remove :kind
        remove :steps
        remove :why
        remove :recommended
        remove :answer
        remove :source
        remove :tasks
        remove :due
        remove :cycle
        remove :closed_at
      end

      execute("ALTER TABLE #{q} ALTER COLUMN reporter_user_id SET NOT NULL")

      create constraint(:problem_reports, :problem_reports_status,
               check: "status IN ('received','in_work','answered','fixed','not_done')"
             )
    end
  end
end
