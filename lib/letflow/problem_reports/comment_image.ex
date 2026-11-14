defmodule Letflow.ProblemReports.CommentImage do
  @moduledoc """
  T-1963: one PNG or JPEG screenshot of a thread entry. `content_type` is set from the first bytes,
  never from the client. `bytes` is never selected by list or detail queries (see
  `Letflow.ProblemReports.Review`); only the image route reads it.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "problem_report_comment_images" do
    field(:tenant_id, :binary_id)
    field(:report_id, :binary_id)
    field(:comment_id, :binary_id)
    field(:position, :integer)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:bytes, :binary)
    field(:inserted_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
