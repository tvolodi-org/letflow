defmodule Letflow.ProblemReports.ReportImage do
  @moduledoc """
  Legacy T-2015 screenshot storage. New reports use `Letflow.Attachments` (T-2043); existing rows
  remain readable here until the hourly screenshot expiry purges them at 30 days. `bytes` is never
  selected by list or detail queries; only the image route reads it.
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
