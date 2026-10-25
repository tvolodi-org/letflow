defmodule Letflow.NotificationTemplates.Template do
  @moduledoc """
  Persistence shape of a `notification_templates` row (REQ-563, GH #3199): the subject and body of
  one registered template key for one locale, unique on `(template_key, locale)`. The only writer
  is `Letflow.NotificationTemplates`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "notification_templates" do
    field(:tenant_id, :binary_id)
    field(:template_key, :string)
    field(:locale, :string)
    field(:subject, :string)
    field(:body, :string)
    field(:updated_by, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
