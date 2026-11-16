defmodule Letflow.ProblemReports.ReportImage do
  @moduledoc """
  T-2015: one PNG or JPEG screenshot attached to a problem report. `content_type` is set from the
  first bytes, never from the client. `bytes` is never selected by list or detail queries; only the
  image route reads it.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "problem_report_images" do
    field(:report_id, :binary_id)
    field(:position, :integer)
    field(:content_type, :string)
    field(:size, :integer)
    field(:bytes, :binary)
    field(:inserted_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
