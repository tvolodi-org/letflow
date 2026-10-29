defmodule Letflow.Notifications do
  @moduledoc """
  Notification delivery (REQ-584, GH #3310), part 1 (part 2 adds `list_deliveries/2`, read by
  `GET /notification-deliveries`): the `task_assigned` mail sent after
  `Letflow.Tasks.assign_task/3` / `reassign_task/3` commit, and the per-tenant
  `notification_deliveries` log (one send attempt, one row).

  `after_assignment/3` is the only entry point of the assignment path. It never raises and
  returns `:ok`, so the assignment result is never changed (INV-8). It starts ONE delivery on
  `Letflow.Notifications.TaskSupervisor`; a refused start (`max_children`) writes no row, a
  documented best-effort limit. The delivery renders the stored template of the tenant's
  `default_locale` (fallback `"en"`) through `Letflow.NotificationTemplates.preview/6` and calls
  the configured `Letflow.LoginDiscovery.Notifier` adapter's `deliver_message/1` inside an
  isolated, time-limited task (`Dispatch.timeout_ms/0`).

  Outcome rows: `sent` (no reason); `skipped` / `no_email` (no user row or an empty address, no
  adapter call); `skipped` / `adapter_noop` (the Noop adapter is configured, not called);
  `failed` / `adapter_error` (an adapter error, raise, exit or timeout, or a template that does
  not render, e.g. an invalid `default_locale`, with no adapter call). A subject over 200
  codepoints after rendering is refused by the Smtp adapter (`:invalid_message`) and so logs
  `failed` / `adapter_error`; it is not truncated.

  The log holds no subject, body, recipient address or error text, and this module never
  logs or inspects them: only fixed log lines (INV-4). Tenant data is reached with the
  tenant's `:prefix` only (INV-1). There is no retry and no queue.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.LoginDiscovery.Dispatch
  alias Letflow.LoginDiscovery.Notifier.Noop
  alias Letflow.NotificationTemplates
  alias Letflow.Notifications.Delivery
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @supervisor Letflow.Notifications.TaskSupervisor
  @default_locale "en"
  @max_value_chars 500

  @doc """
  Starts the `task_assigned` delivery for a committed (re)assignment. Never raises; returns `:ok`.
  """
  @spec after_assignment(EngineTask.t(), String.t(), String.t()) :: :ok
  def after_assignment(%EngineTask{} = task, user_id, prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, _pid} <-
           Task.Supervisor.start_child(@supervisor, fn ->
             deliver_task_assigned(task, user_id, prefix, tenant_id)
           end) do
      :ok
    else
      _other ->
        Logger.warning("notifications: delivery not started")
        :ok
    end
  rescue
    _exception ->
      Logger.warning("notifications: delivery not started")
      :ok
  catch
    _kind, _reason ->
      Logger.warning("notifications: delivery not started")
      :ok
  end

  def after_assignment(_task, _user_id, _prefix), do: :ok

  @doc """
  Starts ONE delivery of any registered template on the delivery supervisor; the generic form
  of `after_assignment/3`. `values_fun` is `(User.t(), prefix, Tenant.t() | nil -> %{String.t() =>
  String.t()})`; it runs inside the delivery task, so any lookup it makes is off the caller's
  path, and a raise there logs `failed` / `adapter_error`. `trigger_ref` must be a UUID. Never
  raises; returns `:ok` (a refused start writes no row).
  """
  @spec start_delivery(String.t(), term(), term(), function(), String.t()) :: :ok
  def start_delivery(template_key, user_id, trigger_ref, values_fun, prefix)
      when is_binary(template_key) and is_function(values_fun, 3) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, _pid} <-
           Task.Supervisor.start_child(@supervisor, fn ->
             deliver(template_key, user_id, trigger_ref, values_fun, prefix, tenant_id)
           end) do
      :ok
    else
      _other ->
        Logger.warning("notifications: delivery not started")
        :ok
    end
  rescue
    _exception ->
      Logger.warning("notifications: delivery not started")
      :ok
  catch
    _kind, _reason ->
      Logger.warning("notifications: delivery not started")
      :ok
  end

  def start_delivery(_template_key, _user_id, _trigger_ref, _values_fun, _prefix), do: :ok

  @doc """
  Renders, sends and logs one `task_assigned` mail; writes exactly one log row. Runs inside the
  delivery task; public for tests. Never raises.
  """
  @spec deliver_task_assigned(EngineTask.t(), term(), String.t(), String.t()) :: :ok
  def deliver_task_assigned(task, user_id, prefix, tenant_id) do
    deliver(
      "task_assigned",
      user_id,
      task.id,
      fn user, prefix, tenant -> values(task, user, prefix, tenant) end,
      prefix,
      tenant_id
    )
  end

  @doc false
  @spec deliver(String.t(), term(), term(), function(), String.t(), String.t()) :: :ok
  def deliver(template_key, user_id, trigger_ref, values_fun, prefix, tenant_id) do
    tenant = safe(fn -> Repo.get(Tenant, tenant_id) end)
    locale = locale_of(tenant)

    {status, reason} = outcome(template_key, values_fun, user_id, prefix, tenant, locale)

    log(
      %{
        tenant_id: tenant_id,
        template_key: template_key,
        locale: locale_string(locale),
        recipient_user_id: cast_uuid(user_id),
        status: status,
        reason: reason,
        trigger_ref: trigger_ref
      },
      prefix
    )
  rescue
    _exception -> warn_write_failed()
  catch
    _kind, _reason -> warn_write_failed()
  end

  defp outcome(template_key, values_fun, user_id, prefix, tenant, locale) do
    case recipient(user_id, prefix) do
      {:ok, user} -> render_and_send(template_key, values_fun, user, prefix, tenant, locale)
      :none -> {"skipped", "no_email"}
    end
  end

  defp recipient(user_id, prefix) do
    with {:ok, id} <- Ecto.UUID.cast(user_id),
         %User{email: email} = user when is_binary(email) and email != "" <-
           safe(fn -> Repo.get(User, id, prefix: prefix) end) do
      {:ok, user}
    else
      _other -> :none
    end
  end

  defp render_and_send(template_key, values_fun, user, prefix, tenant, locale) do
    with values when is_map(values) <- safe(fn -> values_fun.(user, prefix, tenant) end),
         {:ok, %{subject: subject, body: body}} <-
           NotificationTemplates.preview(prefix, template_key, locale, nil, nil, values) do
      send_message(%{to: user.email, subject: subject, body: body})
    else
      _error -> {"failed", "adapter_error"}
    end
  end

  defp send_message(message) do
    adapter = Dispatch.adapter()

    if adapter == Noop do
      {"skipped", "adapter_noop"}
    else
      case run_adapter(adapter, message) do
        :ok -> {"sent", nil}
        _failure -> {"failed", "adapter_error"}
      end
    end
  end

  defp run_adapter(adapter, message) do
    task =
      Task.Supervisor.async_nolink(@supervisor, fn ->
        try do
          adapter.deliver_message(message)
        rescue
          _exception -> {:error, :failed}
        catch
          _kind, _reason -> {:error, :failed}
        end
      end)

    case Task.yield(task, Dispatch.timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout_or_exit -> {:error, :failed}
    end
  rescue
    _exception -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  defp values(task, user, prefix, tenant) do
    %{
      "task_name" => text(task.node_name),
      "process_name" => text(process_name(task, prefix)),
      "assignee_name" =>
        text(if(user.display_name in [nil, ""], do: user.username, else: user.display_name)),
      "due_date" => "",
      "tenant_name" => text(tenant && tenant.display_name)
    }
  end

  defp process_name(task, prefix) do
    safe(fn ->
      Repo.one(
        from(s in InstanceDefinitionSnapshot,
          where: s.instance_id == ^task.instance_id,
          select: s.definition_name
        ),
        prefix: prefix
      )
    end)
  end

  @doc false
  @spec text(term()) :: String.t()
  def text(value) when is_binary(value), do: String.slice(value, 0, @max_value_chars)
  def text(_other), do: ""

  @doc false
  def locale_of(%Tenant{settings: %{"default_locale" => locale}}) when not is_nil(locale),
    do: locale

  def locale_of(_tenant), do: @default_locale

  # The row's locale column is text NOT NULL: a non-binary stored value (raw write only) is
  # logged as the default locale name after the template render refused it.
  defp locale_string(locale) when is_binary(locale), do: locale
  defp locale_string(_other), do: @default_locale

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _exception -> nil
  end

  @doc """
  The tenant's delivery log, newest first, at most 100 rows (REQ-584 part 2). `status` is nil (no
  filter) or one of `Delivery.statuses/0`; any other value is `{:error, :invalid_status}`. The
  tenant is the `:prefix` only (INV-1).
  """
  @spec list_deliveries(String.t(), term()) :: {:ok, [Delivery.t()]} | {:error, :invalid_status}
  def list_deliveries(prefix, status \\ nil)

  def list_deliveries(prefix, nil), do: {:ok, query_deliveries(from(d in Delivery, []), prefix)}

  def list_deliveries(prefix, status) when is_binary(status) do
    if status in Delivery.statuses() do
      {:ok, query_deliveries(from(d in Delivery, where: d.status == ^status), prefix)}
    else
      {:error, :invalid_status}
    end
  end

  def list_deliveries(_prefix, _status), do: {:error, :invalid_status}

  defp query_deliveries(query, prefix) do
    query
    |> Ecto.Query.order_by([d], desc: d.inserted_at, desc: d.id)
    |> Ecto.Query.limit(100)
    |> Repo.all(prefix: prefix)
  end

  defp log(attrs, prefix) do
    case Repo.insert(Delivery.changeset(attrs), prefix: prefix) do
      {:ok, _row} -> :ok
      {:error, _changeset} -> warn_write_failed()
    end
  end

  defp warn_write_failed do
    Logger.warning("notifications: delivery log write failed")
    :ok
  end
end
