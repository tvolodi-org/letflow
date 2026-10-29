defmodule Letflow.Notifications.Delivery do
  @moduledoc """
  Persistence shape of a `notification_deliveries` row (REQ-584, GH #3310): one send attempt of
  one notification. It holds no subject, body, recipient address or error text (INV-4). The only
  writer is `Letflow.Notifications`. `status` and `reason` are closed sets, enforced here and by
  CHECK constraints; `sent` has no reason, the others have one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(sent failed skipped)
  @reasons ~w(no_email adapter_noop adapter_error)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "notification_deliveries" do
    field(:tenant_id, :binary_id)
    field(:template_key, :string)
    field(:locale, :string)
    field(:recipient_user_id, :binary_id)
    field(:status, :string)
    field(:reason, :string)
    field(:trigger_ref, :binary_id)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The closed set of statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The closed set of reasons."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(delivery \\ %__MODULE__{}, attrs) do
    delivery
    |> cast(attrs, [
      :tenant_id,
      :template_key,
      :locale,
      :recipient_user_id,
      :status,
      :reason,
      :trigger_ref
    ])
    |> validate_required([:tenant_id, :template_key, :locale, :status, :trigger_ref])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:reason, @reasons)
    |> validate_reason_matches_status()
    |> check_constraint(:status, name: :notification_deliveries_status_reason_chk)
  end

  defp validate_reason_matches_status(changeset) do
    status = get_field(changeset, :status)
    reason = get_field(changeset, :reason)

    cond do
      status == "sent" and not is_nil(reason) ->
        add_error(changeset, :reason, "must be empty for a sent delivery")

      status in ["failed", "skipped"] and is_nil(reason) ->
        add_error(changeset, :reason, "is required unless the delivery was sent")

      true ->
        changeset
    end
  end
end
