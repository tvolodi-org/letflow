Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.RemindersTest do
  @moduledoc """
  C12 expiry reminder of intangible assets (tests R-WIN, R-DUP, R-REC, R-ISO, R-NEVER, R-SET, R-POL).
  `async: false`: real committed tenants. `now` is passed explicitly (fake clock).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Assets.Cards
  alias Letflow.Modules.Assets.Reminders
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Org.People
  alias Letflow.Notifications.Delivery
  alias Letflow.Support.TokenMintFixture

  @now ~U[2026-11-10 08:00:00Z]

  setup do
    old = Application.get_env(:letflow, :asset_notifications_enabled)
    Application.put_env(:letflow, :asset_notifications_enabled, true)

    on_exit(fn ->
      if old == nil,
        do: Application.delete_env(:letflow, :asset_notifications_enabled),
        else: Application.put_env(:letflow, :asset_notifications_enabled, old)
    end)

    fx = Fx.installed_tenant!("c12-rem")
    {:ok, fx: fx, schema: fx.schema_name}
  end

  defp lead!(schema, days) do
    {:ok, _} =
      Installs.put_settings("assets", %{"expiry_reminder_lead_days" => days}, prefix: schema)
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp unit!(schema), do: Letflow.OrgFixture.unit_id!(schema)

  defp card!(schema, n, extra) do
    attrs =
      Map.merge(
        %{
          "inventory_number" => "C12-#{n}",
          "name" => "Licence #{n}",
          "kind" => "intangible",
          "org_unit_id" => unit!(schema)
        },
        extra
      )

    {:ok, card} = Cards.create_card(schema, attrs, opts())
    card
  end

  defp employee!(schema, user_id) do
    attrs = %{
      "code" => "E#{System.unique_integer([:positive])}",
      "full_name" => "Resp Person",
      "org_unit_id" => unit!(schema)
    }

    attrs = if user_id, do: Map.put(attrs, "user_id", user_id), else: attrs
    {:ok, e} = People.create_employee(schema, attrs, opts())
    e["record_id"]
  end

  defp user!(schema), do: TokenMintFixture.role_holder!(schema, ["TASK_WORKER"]).id

  defp rows(schema),
    do:
      Repo.all(from(d in Delivery, where: d.template_key == "asset_expiry_reminder"),
        prefix: schema
      )

  defp resp(map), do: fn _prefix, card_id -> Map.get(map, card_id, :none) end

  defp all_to(employee), do: fn _prefix, _card_id -> {:ok, employee} end

  defp date(offset), do: @now |> DateTime.to_date() |> Date.add(offset) |> Date.to_iso8601()

  test "R-WIN-1: window is today..today+lead, inclusive", %{schema: s} do
    lead!(s, 30)
    emp = employee!(s, user!(s))
    due0 = card!(s, 1, %{"valid_until" => date(0)})
    due30 = card!(s, 2, %{"valid_until" => date(30)})
    _late = card!(s, 3, %{"valid_until" => date(31)})
    _past = card!(s, 4, %{"valid_until" => date(-1)})

    assert :ok = Reminders.send_reminders(s, @now, responsible_fun: all_to(emp))
    refs = rows(s) |> Enum.map(& &1.trigger_ref) |> Enum.sort()

    expected =
      Enum.sort([
        Reminders.trigger_ref(due0["record_id"], Date.add(~D[2026-11-10], 0)),
        Reminders.trigger_ref(due30["record_id"], Date.add(~D[2026-11-10], 30))
      ])

    assert refs == expected
  end

  test "R-WIN-2: other kinds, retired and undated cards are never due", %{schema: s} do
    lead!(s, 30)
    emp = employee!(s, user!(s))
    card!(s, 1, %{"kind" => "fixed"})
    card!(s, 2, %{"kind" => "low_value"})
    card!(s, 3, %{})
    retired = card!(s, 4, %{"valid_until" => date(5)})
    {:ok, _} = Cards.retire_card(s, retired["record_id"], opts())

    Reminders.send_reminders(s, @now, responsible_fun: all_to(emp))
    assert rows(s) == []
  end

  test "R-WIN-3: no lead setting or flag off sends nothing", %{schema: s} do
    emp = employee!(s, user!(s))
    card!(s, 1, %{"valid_until" => date(1)})
    Reminders.send_reminders(s, @now, responsible_fun: all_to(emp))
    assert rows(s) == []

    lead!(s, 30)
    Application.put_env(:letflow, :asset_notifications_enabled, false)
    Reminders.send_reminders(s, @now, responsible_fun: all_to(emp))
    assert rows(s) == []
  end

  test "R-DUP-1: repeated calls send once; R-DUP-2: a renewed date sends again", %{schema: s} do
    lead!(s, 30)
    emp = employee!(s, user!(s))
    card = card!(s, 1, %{"valid_until" => date(3)})
    o = [responsible_fun: all_to(emp)]

    Reminders.send_reminders(s, @now, o)
    Reminders.send_reminders(s, @now, o)
    Reminders.send_reminders(s, DateTime.add(@now, 86_400), o)
    assert [%{status: "sent"}] = rows(s)

    {:ok, _} = Cards.update_card(s, card["record_id"], %{"valid_until" => date(10)}, opts())
    Reminders.send_reminders(s, @now, o)
    assert length(rows(s)) == 2
    assert rows(s) |> Enum.map(& &1.trigger_ref) |> Enum.uniq() |> length() == 2
  end

  test "R-REC-1: no employee, inactive, or no user sends nothing and writes no row", %{schema: s} do
    lead!(s, 30)
    card = card!(s, 1, %{"valid_until" => date(3)})
    id = card["record_id"]

    Reminders.send_reminders(s, @now, responsible_fun: resp(%{}))
    no_user = employee!(s, nil)
    Reminders.send_reminders(s, @now, responsible_fun: resp(%{id => {:ok, no_user}}))

    inactive = employee!(s, user!(s))
    {:ok, _} = People.retire_employee(s, inactive, opts())
    Reminders.send_reminders(s, @now, responsible_fun: resp(%{id => {:ok, inactive}}))

    Reminders.send_reminders(s, @now, responsible_fun: resp(%{id => {:ok, Ecto.UUID.generate()}}))
    assert rows(s) == []
  end

  test "R-REC-2: the recipient is the employee's user; the default seam gives none", %{schema: s} do
    lead!(s, 30)
    uid = user!(s)
    emp = employee!(s, uid)
    card = card!(s, 1, %{"valid_until" => date(3)})

    Reminders.send_reminders(s, @now)
    assert rows(s) == []

    Reminders.send_reminders(s, @now, responsible_fun: resp(%{card["record_id"] => {:ok, emp}}))
    assert [row] = rows(s)
    assert row.recipient_user_id == uid
    assert row.template_key == "asset_expiry_reminder"
  end

  test "R-ISO-1: a sweep of tenant A touches only A", %{schema: a} do
    b = Fx.installed_tenant!("c12-remb").schema_name
    for s <- [a, b], do: lead!(s, 30)
    emp_a = employee!(a, user!(a))
    emp_b = employee!(b, user!(b))
    card!(a, 1, %{"valid_until" => date(3)})
    card!(b, 1, %{"valid_until" => date(3)})

    Reminders.send_reminders(a, @now, responsible_fun: all_to(emp_a))
    assert length(rows(a)) == 1
    assert rows(b) == []

    # an employee id of A looked up while sweeping B is not found there: nothing is sent
    Reminders.send_reminders(b, @now, responsible_fun: all_to(emp_a))
    assert rows(b) == []
    Reminders.send_reminders(b, @now, responsible_fun: all_to(emp_b))
    assert length(rows(b)) == 1
  end

  test "R-NEVER-1: garbage prefix and a raising resolver return :ok", %{schema: s} do
    lead!(s, 30)
    card!(s, 1, %{"valid_until" => date(3)})
    assert :ok = Reminders.send_reminders("no_such_schema", @now)
    assert :ok = Reminders.send_reminders(s, @now, responsible_fun: fn _, _ -> raise "boom" end)
    assert :ok = Reminders.sweep("no_such_schema")
  end

  test "R-SET-1: the lead-time setting is validated and read", %{schema: s} do
    assert Assets.expiry_lead_days(s) == nil

    for d <- [1, 3650],
        do:
          assert(
            {:ok, _} =
              Installs.put_settings("assets", %{"expiry_reminder_lead_days" => d}, prefix: s)
          )

    assert Assets.expiry_lead_days(s) == 3650

    for bad <- [0, 3651, "30", 1.5] do
      assert {:error, {:settings_validation_failed, _}} =
               Installs.put_settings("assets", %{"expiry_reminder_lead_days" => bad}, prefix: s)
    end

    assert {:error, {:settings_validation_failed, _}} =
             Installs.put_settings("assets", %{"other" => 1}, prefix: s)
  end

  test "R-POL-1: sweep/1 needs the flag and an assets install", %{schema: s} do
    lead!(s, 30)
    card!(s, 1, %{"valid_until" => date(3)})
    # default resolver is the :none seam, so the wiring is proven by a no-raise, no-row result
    assert :ok = Reminders.sweep(s)
    assert rows(s) == []
    plain = Fx.provisioned_tenant!("c12-plain").schema_name
    assert :ok = Reminders.sweep(plain)
  end
end
