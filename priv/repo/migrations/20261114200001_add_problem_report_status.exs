defmodule Letflow.Repo.Migrations.AddProblemReportStatus do
  use Ecto.Migration

  # T-1949: existing QA reports become received; no customer data is copied or rewritten.
  def change do
    if prefix() do
      alter table(:problem_reports) do
        add :status, :string, size: 16, null: false, default: "received"
        add :last_action, :string, size: 16
        add :reply_text, :text
        add :dev_summary, :text
        add :decided_by_user_id, :binary_id
        add :decided_at, :utc_datetime_usec
      end

      create index(:problem_reports, [:status, :seq])

      create constraint(:problem_reports, :problem_reports_status,
               check: "status IN ('received','in_work','answered','fixed','not_done')"
             )

      create constraint(:problem_reports, :problem_reports_action,
               check:
                 "last_action IS NULL OR last_action IN ('answer','develop','reject','ask','fixed')"
             )

      create constraint(:problem_reports, :problem_reports_reply_len,
               check: "reply_text IS NULL OR char_length(reply_text) BETWEEN 1 AND 4000"
             )

      create constraint(:problem_reports, :problem_reports_summary_len,
               check: "dev_summary IS NULL OR char_length(dev_summary) BETWEEN 1 AND 2000"
             )
    end
  end
end
