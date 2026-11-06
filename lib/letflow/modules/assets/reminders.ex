defmodule Letflow.Modules.Assets.Reminders do
  @moduledoc """
  Expiry reminder of intangible assets (phase C item C12; spec
  `docs/assets/asset-workflow-documents.md` section 9).

  `send_reminders/3` writes one `asset_expiry_reminder` mail for every active intangible card whose
  `valid_until` lies in `today .. today + lead_days` (UTC dates, inclusive at both ends), to the
  Letflow user of the material responsible employee. The lead time is the module setting
  `expiry_reminder_lead_days` (`Letflow.Modules.Assets.expiry_lead_days/1`); with no setting
  nothing is sent. The responsible employee comes from `Letflow.Modules.Assets.Responsible`
  (`responsible_fun:` option); no employee, an inactive one, or one without `user_id` sends nothing
  and writes no log row.

  Dedupe: the `trigger_ref` is a UUID derived from the card id and its `valid_until`; a delivery-log
  row with that `template_key` and `trigger_ref` (any status) stops a second mail for the same date,
  a renewed date sends again. The sweep calls the synchronous `Letflow.Notifications.deliver/6`, so
  the log row exists before the next candidate and the next tick (`start_delivery/5` is async and
  could double send). Two nodes sweeping one tenant at the same instant are not guarded.

  Default off: `config :letflow, :asset_notifications_enabled` (`enabled?/0`, boolean `true` only).
  Never raises (INV-8). Cards are read by the tenant `:prefix` only (INV-1), all values bound (INV-7).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets.Responsible
  alias Letflow.Modules.Org
  alias Letflow.Modules.TenantModule
  alias Letflow.Notifications
  alias Letflow.Notifications.Delivery
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @template "asset_expiry_reminder"
  @batch 200

  @doc "True only when the flag is the boolean `true`."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:letflow, :asset_notifications_enabled, false) == true

  @doc """
  The Poller's per-tenant entry: nothing unless the flag is on and the tenant has an active `assets`
  install; then `send_reminders/3` with the current time. Never raises.
  """
  @spec sweep(String.t()) :: :ok
  def sweep(prefix) do
    if enabled?() and installed?(prefix), do: send_reminders(prefix, DateTime.utc_now())
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp installed?(prefix),
    do:
      match?(
        %TenantModule{},
        Repo.get_by(TenantModule, [module_id: "assets", status: :active], prefix: prefix)
      )

  @doc """
  Sends the due reminders of tenant schema `prefix` as of `now` (a `DateTime`, the fake clock of
  tests). Options: `responsible_fun:` `(prefix, card_id -> {:ok, employee_id} | :none)`.
  """
  @spec send_reminders(String.t(), DateTime.t(), keyword()) :: :ok
  def send_reminders(prefix, %DateTime{} = now, opts \\ []) when is_binary(prefix) do
    with true <- enabled?(),
         lead when is_integer(lead) <- Letflow.Modules.Assets.expiry_lead_days(prefix),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      today = DateTime.to_date(now)
      fun = Keyword.get(opts, :responsible_fun, &Responsible.employee_id/2)

      prefix
      |> due_cards(today, Date.add(today, lead))
      |> Enum.each(&remind(prefix, tenant_id, &1, fun))
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp due_cards(prefix, from_date, to_date) do
    low = Date.to_iso8601(from_date)
    high = Date.to_iso8601(to_date)

    from(r in Latest,
      where:
        r.entity_type == "assets_card" and r.deleted == false and
          fragment("?->>'kind' = 'intangible'", r.field_values) and
          fragment("?->'active' = 'true'::jsonb", r.field_values) and
          fragment("?->>'valid_until' BETWEEN ? AND ?", r.field_values, ^low, ^high),
      order_by: [asc: fragment("?->>'valid_until'", r.field_values), asc: r.record_id],
      limit: ^@batch
    )
    |> Repo.all(prefix: prefix)
  end

  defp remind(prefix, tenant_id, %{record_id: card_id, field_values: fields}, responsible_fun) do
    with {:ok, date} <- Date.from_iso8601(to_string(fields["valid_until"])),
         ref = trigger_ref(card_id, date),
         false <- reminded?(prefix, ref),
         {:ok, employee_id} <- responsible_fun.(prefix, card_id),
         {:ok, %{"active" => true, "user_id" => user_id} = employee}
         when is_binary(user_id) and user_id != "" <- Org.lookup(prefix, employee_id) do
      Notifications.deliver(
        @template,
        user_id,
        ref,
        fn _user, prefix, tenant -> values(fields, date, employee, prefix, tenant) end,
        prefix,
        tenant_id
      )
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp reminded?(prefix, ref),
    do:
      Repo.exists?(
        from(d in Delivery, where: d.template_key == @template and d.trigger_ref == ^ref),
        prefix: prefix
      )

  @doc false
  @spec trigger_ref(String.t(), Date.t()) :: String.t()
  def trigger_ref(card_id, %Date{} = date) do
    <<a::48, _::4, b::12, _::2, c::62>> =
      binary_part(
        :crypto.hash(:sha256, "asset_expiry_reminder:#{card_id}:#{Date.to_iso8601(date)}"),
        0,
        16
      )

    {:ok, uuid} = Ecto.UUID.load(<<a::48, 4::4, b::12, 2::2, c::62>>)
    uuid
  end

  defp values(fields, date, employee, _prefix, tenant) do
    %{
      "asset_name" => Notifications.text(fields["name"]),
      "asset_code" => Notifications.text(fields["inventory_number"]),
      "expiry_date" => Date.to_iso8601(date),
      "responsible_name" => Notifications.text(employee["full_name"]),
      "tenant_name" => Notifications.text(tenant && tenant.display_name)
    }
  end
end
