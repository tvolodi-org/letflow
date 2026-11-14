defmodule Letflow.ProblemReports.Report do
  @moduledoc """
  Persistence shape of a `problem_reports` row (T-1948). Written only in the platform company's schema
  (see `Letflow.ProblemReports`); `tenant_id` is the platform tenant, `reporter_tenant_id` the company
  of the user who sent the report. `seq` is the number shown as `SR-<seq>` and the export cursor.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "problem_reports" do
    field(:seq, :integer, read_after_writes: true)
    field(:tenant_id, :binary_id)
    field(:reporter_tenant_id, :binary_id)
    field(:reporter_tenant_name, :string)
    field(:reporter_user_id, :binary_id)
    field(:reporter_name, :string)
    field(:reporter_roles, {:array, :string}, default: [])
    field(:reporter_permissions, {:array, :string}, default: [])
    field(:text, :string)
    field(:context, :map, default: %{})
    field(:server_version, :string)
    field(:trace_id, :string)
    field(:consented_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
