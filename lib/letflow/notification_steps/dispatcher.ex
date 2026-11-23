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
       decision 0062 R12, the one the HTTP service task obeys). The labels are
       REQUIRED: a step that cannot see them cannot refuse a sensitive value,
       so a missing map is a refusal;
    3. refuses a missing or malformed TRIGGER REFERENCE: the delivery row
       carries it, and a step that cannot write its row cannot account for
       its send, so the reference is checked before anything is sent. A
       missing and a malformed reference answer with the same code;
    4. resolves the RECIPIENT from the instance variables and checks it
       (`Letflow.Notifications.Address`);
    5. resolves the declared values from the instance variables (or from the
       step's own constants);
    6. hands the send to `Letflow.Notifications.deliver_to_address/6`, which
       RESERVES the tenant's send cap, calls the Notifier adapter and writes
       the one delivery row. The reservation is taken before the adapter is
       called, so a send is counted whether or not the row can be written
       afterwards. The row's tenant is DERIVED from the `:prefix` the
       step runs in, never taken from the caller (INV-1 (c)).

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

  # The bound on the DIGITS of a number the step turns into text. The
  # conversion materialises the whole number, so the bound is on the NUMBER
  # itself and not on the text it becomes (SF-01: the bound comes first). A
  # jsonb column holds a numeric of up to ~131072 digits, so an unbounded
  # conversion is a bounded-by-nothing allocation on the send path.
  @max_numeric_magnitude 1_000_000_000_000_000_000_000_000_000_000

  @doc """
  Runs one notification step.

  `raw` is the node's `notify` attribute, `variables` the instance variables
  (a plain map) and `opts` the context:

    * `:prefix` -- the tenant schema the step runs in (required). The tenant of
      the delivery row is DERIVED from it, never passed in: a row physically
      sits in ONE tenant's schema, so the tenant it claims to belong to comes
      from that schema (decision 0003's addendum, INV-1 (c));
    * `:trigger_ref` -- the reference the delivery row carries (the instance
      id). REQUIRED, and it must be a UUID: a row that cannot be written is a
      send that cannot be accounted for, so the reference is checked before
      anything is sent;
    * `:labels` -- the instance's variable labels (a map of variable name to
      the labels it carries). REQUIRED: a step that cannot see the labels
      cannot refuse a sensitive value, so a missing map is a refusal.

  Never raises.
  """
  @spec run(term(), map(), keyword()) ::
          {:ok, String.t(), String.t() | nil} | {:error, atom()}
  def run(raw, variables, opts) when is_list(opts) and is_map(variables) do
    with {:ok, declaration} <- NotifyCalls.parse(raw),
         {:ok, labels} <- labels(opts),
         {:ok, trigger_ref} <- trigger_ref(opts),
         :ok <- refuse_restricted(declaration, labels),
         {:ok, address} <- recipient(declaration, variables),
         {:ok, values} <- values(declaration, variables) do
      case Notifications.deliver_to_address(
             declaration.template_key,
             address,
             trigger_ref,
             values,
             prefix(opts)
           ) do
        {:error, :invalid_schema_name} -> {:error, :notify_invalid_schema}
        {status, reason} -> {:ok, status, reason}
      end
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

      {:ok, value} when is_integer(value) ->
        # The bound comes BEFORE the conversion: `to_string/1` materialises the
        # whole number, so a bignum is bounded by its magnitude, not by the
        # length of the text it becomes (SF-01).
        if abs(value) <= @max_numeric_magnitude do
          {:ok, to_string(value)}
        else
          {:error, :notify_value_invalid}
        end

      {:ok, value} when is_float(value) ->
        # A float is bounded by its IEEE representation (at most a couple of
        # dozen characters), so the conversion cannot run away.
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

  # The labels are REQUIRED. A step that cannot see them cannot refuse a
  # sensitive value, so an absent map is a refusal (decision 0062 R12): the
  # engine wiring must pass the instance's variable labels, and a caller that
  # forgets them gets no send at all.
  defp labels(opts) do
    case Keyword.get(opts, :labels) do
      labels when is_map(labels) -> {:ok, labels}
      _other -> {:error, :notify_labels_missing}
    end
  end

  defp prefix(opts), do: Keyword.get(opts, :prefix)

  # The trigger reference is REQUIRED, exactly like the labels, and it must be
  # a UUID: it is the `trigger_ref` column of the delivery row, and a row that
  # cannot be written is a send that cannot be accounted for. The delivery log
  # is not the cap's counter any more (the counter is reserved before the
  # send), but a row that does not fit still loses the record of the send, so
  # the reference is checked before anything leaves the platform. A missing and
  # a malformed reference answer with the SAME code: the caller learns that the
  # step cannot run, not which mistake it made.
  defp trigger_ref(opts) do
    case Keyword.get(opts, :trigger_ref) do
      ref when is_binary(ref) ->
        case Ecto.UUID.cast(ref) do
          {:ok, _uuid} -> {:ok, ref}
          :error -> {:error, :notify_trigger_ref_missing}
        end

      _other ->
        {:error, :notify_trigger_ref_missing}
    end
  end
end
