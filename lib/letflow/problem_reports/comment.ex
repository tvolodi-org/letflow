defmodule Letflow.ProblemReports.Comment do
  @moduledoc """
  T-1963: one entry of the thread of an owner-list item (`problem_reports` row of class `review`).
  Written only in the platform company's schema. `seq` orders the thread; `author_user_id` is set for
  owner entries written through the API and NULL for imported and team entries.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "problem_report_comments" do
    field(:seq, :integer, read_after_writes: true)
    field(:tenant_id, :binary_id)
    field(:report_id, :binary_id)
    field(:author, :string)
    field(:author_user_id, :binary_id)
    field(:type, :string)
    field(:text, :string, default: "")
    field(:tasks, :string, default: "")
    field(:lesson, :string, default: "")
    field(:cycle, :integer)
    field(:forwarded, :boolean, default: false)
    field(:inserted_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
