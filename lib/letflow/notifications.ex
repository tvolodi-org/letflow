defmodule Letflow.Notifications do
  @moduledoc """
  Notification delivery (REQ-584, GH #3310), part 1: the `task_assigned` mail sent after
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
  @template_key "task_assigned"
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
  Renders, sends and logs one `task_assigned` mail; writes exactly one log row. Runs inside the
  delivery task; public for tests. Never raises.
  """
  @spec deliver_task_assigned(EngineTask.t(), term(), String.t(), String.t()) :: :ok
  def deliver_task_assigned(task, user_id, prefix, tenant_id) do
    tenant = safe(fn -> Repo.get(Tenant, tenant_id) end)
    locale = locale_of(tenant)

    {status, reason} = outcome(task, user_id, prefix, tenant, locale)

    log(
      %{
        tenant_id: tenant_id,
        template_key: @template_key,
        locale: locale_string(locale),
        recipient_user_id: cast_uuid(user_id),
        status: status,
        reason: reason,
        trigger_ref: task.id
      },
      prefix
    )
  rescue
    _exception -> warn_write_failed()
  catch
    _kind, _reason -> warn_write_failed()
  end

  defp outcome(task, user_id, prefix, tenant, locale) do
    case recipient(user_id, prefix) do
      {:ok, user} -> render_and_send(task, user, prefix, tenant, locale)
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

  defp render_and_send(task, user, prefix, tenant, locale) do
    values = values(task, user, prefix, tenant)

    case NotificationTemplates.preview(prefix, @template_key, locale, nil, nil, values) do
      {:ok, %{subject: subject, body: body}} ->
        send_message(%{to: user.email, subject: subject, body: body})

      _error ->
        {"failed", "adapter_error"}
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

  defp text(value) when is_binary(value), do: String.slice(value, 0, @max_value_chars)
  defp text(_other), do: ""

  defp locale_of(%Tenant{settings: %{"default_locale" => locale}}) when not is_nil(locale),
    do: locale

  defp locale_of(_tenant), do: @default_locale

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
