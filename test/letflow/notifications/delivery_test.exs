defmodule Letflow.Notifications.DeliveryTest do
  @moduledoc """
  REQ-584 part 1: the closed status and reason sets of `notification_deliveries`, by changeset
  and by CHECK (D1, D2), and the column list without any content column (D3).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Notifications.Delivery
  alias Letflow.Repo
  alias Letflow.Support.TaskScopeFixture, as: T

  @valid %{
    tenant_id: "00000000-0000-0000-0000-000000000001",
    template_key: "task_assigned",
    locale: "en",
    trigger_ref: "00000000-0000-0000-0000-000000000002"
  }

  test "D1 the changeset refuses values outside the sets and mismatched reasons" do
    refute Delivery.changeset(Map.merge(@valid, %{status: "bogus"})).valid?
    refute Delivery.changeset(Map.merge(@valid, %{status: "failed", reason: "bogus"})).valid?
    refute Delivery.changeset(Map.merge(@valid, %{status: "sent", reason: "no_email"})).valid?
    refute Delivery.changeset(Map.merge(@valid, %{status: "failed"})).valid?
    assert Delivery.changeset(Map.merge(@valid, %{status: "sent"})).valid?

    assert Delivery.changeset(Map.merge(@valid, %{status: "skipped", reason: "adapter_noop"})).valid?

    assert Delivery.statuses() == ~w(sent failed skipped)
    assert Delivery.reasons() == ~w(no_email adapter_noop adapter_error)
  end

  test "D2 the CHECK constraints refuse the same rows" do
    fx = T.provision!("r584-delivery")

    insert = fn status, reason ->
      Repo.query(
        ~s|INSERT INTO "#{fx.schema_name}".notification_deliveries (id, tenant_id, template_key, locale, status, reason, trigger_ref, inserted_at) VALUES (gen_random_uuid(), gen_random_uuid(), 'task_assigned', 'en', $1, $2, gen_random_uuid(), now())|,
        [status, reason]
      )
    end

    assert {:error, %Postgrex.Error{}} = insert.("bogus", nil)
    assert {:error, %Postgrex.Error{}} = insert.("failed", "bogus")
    assert {:error, %Postgrex.Error{}} = insert.("sent", "no_email")
    assert {:error, %Postgrex.Error{}} = insert.("failed", nil)
    assert {:ok, _} = insert.("sent", nil)
    assert {:ok, _} = insert.("failed", "adapter_error")
  end

  test "D3 the table holds no subject, body, address or error column" do
    fx = T.provision!("r584-columns")

    {:ok, %{rows: rows}} =
      Repo.query(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'notification_deliveries'",
        [fx.schema_name]
      )

    assert rows |> List.flatten() |> Enum.sort() ==
             ~w(id inserted_at locale reason recipient_user_id status template_key tenant_id trigger_ref)
  end
end
