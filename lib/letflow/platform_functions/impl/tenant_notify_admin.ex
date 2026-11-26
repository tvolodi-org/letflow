defmodule Letflow.PlatformFunctions.Impl.TenantNotifyAdmin do
  @moduledoc """
  The body of `tenant.notify_admin` (T-2727, finding V8; design
  `docs/design/provision-realm-and-invite-paths.md` rows N2..N7).

  The registration notice of `platform.register_tenant` v2. v1 carries the same
  notice as a SERVICE_TASK with a `notify` attribute, and the engine has no
  runtime for that node kind: entering it ends the instance in ERROR. v2's every
  other step is a platform step, run by the platform step worker (lease, crash
  takeover, step log, DLQ retry), so the notice is one too.

  The body sends v1's declaration UNCHANGED -- the registered template
  `tenant_registered` to the address in `admin_email`, with the tenant's name and
  slug -- through the ONE notification dispatcher
  (`Letflow.NotificationSteps.Dispatcher.retry/3`), so the rules of a
  notification step hold here exactly: the platform tenant's outbound allow-list
  is read at dispatch (G14), the tenant's send cap is reserved before the send,
  and the delivery row holds no address and no body (INV-4).

  ## The idempotency

  The dispatcher's call key is the tenant id: one notice per tenant. A run that
  crashed after the send and before its result was recorded is run again by the
  next claim; the body asks the delivery log FIRST (`retry/3`: a `sent` row of
  this template for this instance) and sends nothing the second time.

  ## The outcomes

    * `sent`, `already_done`, and `skipped` with `adapter_noop` (no mail adapter
      is configured, so nothing a retry can change) -> `{:ok, %{}}`;
    * any other `skipped` or `failed` delivery -> `:platform_call_notify_failed`
      (retryable through the DLQ);
    * a refusal before the send (the allow-list, a labelled value, a template or
      value the declaration cannot resolve) -> `:platform_call_notify_refused`.

  It never raises and never logs the address (INV-8, INV-4).
  """

  alias Letflow.NotificationSteps.Dispatcher
  alias Letflow.PlatformFunctions.Impl.SystemCaller

  # The byte cap of the address: the RFC's limit in octets (SF-01).
  @max_email_bytes 254

  # v1's `notify` declaration, unchanged (`Letflow.PlatformProcesses.Definition`).
  @declaration %{
    "template_key" => "tenant_registered",
    "recipient" => %{"var" => "admin_email"},
    "values" => %{
      "tenant_name" => %{"var" => "name"},
      "tenant_slug" => %{"var" => "slug"},
      "registered_by" => %{"var" => "admin_email"}
    }
  }

  @typedoc "The stable code of a refused notice."
  @type refusal ::
          :platform_call_arg_invalid
          | :platform_call_invalid_email
          | :platform_call_notify_refused
          | :platform_call_notify_failed

  @doc """
  Runs the step. `context` carries the resolved `inputs` and the `dispatch`
  (the instance id is the delivery row's trigger reference).
  """
  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs, dispatch: %{instance_id: instance_id}}) when is_map(inputs) do
    with {:ok, _tenant_id} <- cast_uuid(Map.get(inputs, "tenant_id")),
         {:ok, trigger_ref} <- cast_uuid(instance_id),
         :ok <- check_email(Map.get(inputs, "admin_email")),
         {:ok, prefix} <- platform_prefix() do
      variables = Map.take(inputs, ["admin_email", "name", "slug"])

      Dispatcher.retry(@declaration, variables,
        prefix: prefix,
        trigger_ref: trigger_ref,
        labels: %{}
      )
      |> outcome()
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp outcome({:ok, %{status: status}}) when status in ["sent", "already_done"], do: {:ok, %{}}
  defp outcome({:ok, %{status: "skipped", reason: "adapter_noop"}}), do: {:ok, %{}}
  defp outcome({:ok, %{status: _other}}), do: {:error, :platform_call_notify_failed}
  defp outcome({:error, _code}), do: {:error, :platform_call_notify_refused}

  # The byte bound comes first (SF-01); the dispatcher checks the address itself.
  defp check_email(value) when is_binary(value) and byte_size(value) <= @max_email_bytes, do: :ok
  defp check_email(_value), do: {:error, :platform_call_invalid_email}

  defp platform_prefix do
    case SystemCaller.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :platform_call_notify_refused}
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :platform_call_arg_invalid}
    end
  end

  defp cast_uuid(_value), do: {:error, :platform_call_arg_invalid}
end
