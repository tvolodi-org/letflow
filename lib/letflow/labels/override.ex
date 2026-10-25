defmodule Letflow.Labels.Override do
  @moduledoc """
  Persistence shape of a `label_overrides` row (REQ-551, GH #3180): the replacement text of one
  overridable message id for one locale, unique on `(message_id, locale)`. The only writer is
  `Letflow.Labels`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "label_overrides" do
    field(:tenant_id, :binary_id)
    field(:message_id, :string)
    field(:locale, :string)
    field(:text, :string)
    field(:updated_by, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
