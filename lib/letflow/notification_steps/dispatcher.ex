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
  alias Letflow.OutboundDestinations

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

  The CHANNEL of the declaration says where the notification goes: the mail
  channel sends to the address of the recipient variable, the file channel
  (T-2596, pilot gap G12) renders the same template into the tenant's own
  file area -- there is no address to send a file to, so the file channel
  carries no recipient.

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
         :ok <- allow_destination(declaration, address, opts),
         {:ok, values} <- values(declaration, variables) do
      deliver(declaration, address, values, trigger_ref, opts)
    end
  rescue
    _exception -> {:error, :notify_step_failed}
  catch
    _kind, _reason -> {:error, :notify_step_failed}
  end

  @doc """
  Retries a notification step that failed (pilot gap G7: a step failure is
  visible AND retryable).

  A notification step is NOT idempotent by nature: it SENDS. So the retry
  asks the delivery log first whether the step already did its work: a mail
  that was SENT, or a file that was written, for this template and this
  trigger reference. Such a step is NOT sent again -- the retry answers
  `{:ok, %{status: "already_done"}}` and nothing leaves the platform. A step
  whose send FAILED (or that never got a row) is sent again.

  The arguments are the step's own (`raw` the node's `notify` attribute,
  `variables` the instance variables) and the context (`opts`: `:prefix`,
  `:trigger_ref`, `:labels`) -- the SAME context `run/3` takes, so the retry
  cannot read the step differently than the run did.

  Never raises.
  """
  @spec retry(term(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def retry(raw, variables, opts) when is_list(opts) and is_map(variables) do
    with {:ok, declaration} <- NotifyCalls.parse(raw),
         {:ok, trigger_ref} <- trigger_ref(opts) do
      if Notifications.already_delivered?(
           declaration.channel,
           declaration.template_key,
           trigger_ref,
           prefix: prefix(opts)
         ) do
        {:ok, %{status: "already_done", reason: nil}}
      else
        case run(raw, variables, opts) do
          {:ok, status, reason} -> {:ok, %{status: status, reason: reason}}
          {:error, code} -> {:error, code}
        end
      end
    end
  end

  # The two channels. The mail channel leaves the platform; the file channel
  # writes into the tenant's own file area (`Letflow.Notifications.Files`).
  # Both reserve the tenant's send cap BEFORE they do anything, and both
  # answer with the same vocabulary, so the engine records one kind of step
  # result.
  defp deliver(%{channel: "email"} = declaration, address, values, trigger_ref, opts) do
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

  defp deliver(%{channel: "file"} = declaration, _address, values, trigger_ref, opts) do
    case Notifications.deliver_to_file(
           declaration.template_key,
           values,
           trigger_ref,
           prefix(opts),
           declared_name: declaration.file_name
         ) do
      {:error, :invalid_schema_name} -> {:error, :notify_invalid_schema}
      {status, reason} -> {:ok, status, reason}
    end
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

  # The per-tenant OUTBOUND ALLOW-LIST (T-2597, pilot gap G14): the CHANNEL of
  # the declaration must be on the tenant's list, and so must the DESTINATION
  # it reaches -- the DOMAIN of the recipient on the mail channel. The file
  # channel writes into the tenant's own area, so it has no external
  # destination.
  #
  # The list is read HERE, at dispatch, and not only at activation: the list
  # can shrink after a version was switched on, and a step that would reach a
  # destination that is no longer allowed must stop (decision record G2 S7).
  #
  # ONE code for every refusal: the caller learns that the step cannot run,
  # not which part of the list it missed.
  defp allow_destination(declaration, address, opts) do
    with {:ok, destination} <- destination(declaration, address) do
      case OutboundDestinations.check(prefix(opts), channel(declaration), destination) do
        :ok ->
          :ok

        {:error, :invalid_schema_name} ->
          # The prefix names no tenant: the same answer the send itself gives.
          {:error, :notify_invalid_schema}

        {:error, _code} ->
          {:error, :notify_destination_not_allowed}
      end
    else
      {:error, _code} -> {:error, :notify_destination_not_allowed}
    end
  end

  # The channel of the declaration: the ONE function of the allow-list module.
  defp channel(declaration), do: OutboundDestinations.notify_channel(declaration)

  # The destination the step reaches: the recipient's DOMAIN on the mail
  # channel, nothing on the file channel. A domain that cannot be read is a
  # refusal: a send nobody can account for is a send nobody may make.
  defp destination(%{channel: "file"}, _address), do: {:ok, nil}

  defp destination(_declaration, address) do
    case Address.domain(address) do
      {:ok, domain} -> {:ok, domain}
      :error -> {:error, :notify_destination_not_allowed}
    end
  end

  # The address of the MAIL channel. The file channel has no recipient (the
  # declaration refuses one), so there is no address to check: it answers with
  # the same `{:ok, nil}` the file path ignores.
  defp recipient(%{channel: "file"}, _variables), do: {:ok, nil}

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
