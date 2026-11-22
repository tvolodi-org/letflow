defmodule Letflow.NotificationSteps.Dispatcher do
  @moduledoc """
  The runner of a NOTIFICATION STEP (T-2592, pilot gap G4 -- the "Register a
  tenant" pilot): it reads the step's declaration out of the definition, resolves
  the address and the values from the variables of the running instance, and
  sends the registered template through the existing Notifier adapter.

  ## What it does, in order

    1. reads the declaration with `Letflow.Definitions.NotifyCalls.parse/1` --
       the SAME parse the activation rule uses, so a step that was switched on
       cannot be read differently here;
    2. refuses a variable that carries a LABEL (a sensitive value the engine
       marked): a labelled variable never leaves the process (the rule of
       decision 0062 R12, the one the HTTP service task obeys);
    3. resolves the RECIPIENT from the instance variables and checks it
       (`Letflow.Notifications.Address`);
    4. resolves the declared values from the instance variables (or from the
       step's own constants);
    5. hands the send to `Letflow.Notifications.deliver_to_address/7`, which
       holds the tenant's send cap, calls the Notifier adapter and writes the
       one delivery row.

  ## What it never does

  It never stores the address or the body: the delivery row holds the template
  key, the locale, the status, the reason and the trigger reference, and
  nothing else (INV-4). It never raises -- every failure is an error tuple or
  an outcome, so the caller (the engine) records the step's result instead of
  crashing.

  ## The outcome

  `{:ok, status, reason}` when the send was attempted (the status and the
  reason are the ones the delivery row carries: `sent`, `skipped` with a
  reason, or `failed`), and `{:error, code}` when the step itself was refused
  before anything was sent.
  """

  alias Letflow.Definitions.NotifyCalls
  alias Letflow.Notifications
  alias Letflow.Notifications.Address

  # The byte cap of ONE resolved value. The template renderer walks the value
  # (it counts its codepoints), so the value is bounded in bytes BEFORE it is
  # handed over: the value comes from the variables of the instance, which a
  # person may have typed (SF-01: the byte bound comes first). Four times the
  # template's own 500-codepoint rule -- a safety bound, not a tighter rule.
  @max_value_bytes 2048

  @doc """
  Runs one notification step.

  `raw` is the node's `notify` attribute, `variables` the instance variables
  (a plain map) and `opts` the context:

    * `:prefix` -- the tenant schema the step runs in (required);
    * `:tenant_id` -- the tenant the step belongs to (required);
    * `:trigger_ref` -- the reference the delivery row carries (the instance
      id); required;
    * `:labels` -- the instance's variable labels (a map of variable name to
      the labels it carries); the default is an empty map.

  Never raises.
  """
  @spec run(term(), map(), keyword()) ::
          {:ok, String.t(), String.t() | nil} | {:error, atom()}
  def run(raw, variables, opts) when is_list(opts) and is_map(variables) do
    with {:ok, declaration} <- NotifyCalls.parse(raw),
         :ok <- refuse_restricted(declaration, labels(opts)),
         {:ok, address} <- recipient(declaration, variables),
         {:ok, values} <- values(declaration, variables) do
      {status, reason} =
        Notifications.deliver_to_address(
          declaration.template_key,
          address,
          trigger_ref(opts),
          values,
          prefix(opts),
          tenant_id(opts)
        )

      {:ok, status, reason}
    end
  rescue
    _exception -> {:error, :notify_step_failed}
  catch
    _kind, _reason -> {:error, :notify_step_failed}
  end

  # A variable that carries a label is a sensitive value: the engine marked it
  # as one, and a marked value never leaves the process. The HTTP service task
  # obeys the same rule (decision 0062 R12).
  defp refuse_restricted(declaration, labels) do
    read =
      [declaration.recipient_var] ++
        Enum.map(declaration.values, fn {_name, source} -> source_var(source) end)

    read = Enum.reject(read, &is_nil/1)

    if Enum.any?(read, &(Map.get(labels, &1, []) != [])) do
      {:error, :notify_restricted_variable}
    else
      :ok
    end
  end

  defp recipient(declaration, variables) do
    case Map.get(variables, declaration.recipient_var) do
      address when is_binary(address) ->
        if Address.valid?(address) do
          {:ok, address}
        else
          {:error, :notify_recipient_invalid}
        end

      _other ->
        {:error, :notify_recipient_missing}
    end
  end

  defp values(declaration, variables) do
    Enum.reduce_while(declaration.values, {:ok, %{}}, fn {name, source}, {:ok, acc} ->
      case resolve(source, variables) do
        {:ok, text} -> {:cont, {:ok, Map.put(acc, name, text)}}
        {:error, code} -> {:halt, {:error, code}}
      end
    end)
  end

  defp resolve({:var, var}, variables) do
    case Map.fetch(variables, var) do
      {:ok, value} when is_binary(value) ->
        if byte_size(value) <= @max_value_bytes do
          {:ok, value}
        else
          {:error, :notify_value_invalid}
        end

      {:ok, value} when is_integer(value) or is_float(value) ->
        {:ok, to_string(value)}

      {:ok, _other} ->
        {:error, :notify_value_invalid}

      :error ->
        {:error, :notify_value_missing}
    end
  end

  defp resolve({:const, const}, _variables), do: {:ok, const}

  defp source_var({:var, var}), do: var
  defp source_var({:const, _const}), do: nil

  defp labels(opts), do: Keyword.get(opts, :labels) || %{}
  defp prefix(opts), do: Keyword.get(opts, :prefix)
  defp tenant_id(opts), do: Keyword.get(opts, :tenant_id)
  defp trigger_ref(opts), do: Keyword.get(opts, :trigger_ref)
end
