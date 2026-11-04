defmodule Letflow.Ledger.HandlerPost do
  @moduledoc """
  REQ-685 / GH #3697 (slice L3b, decision 0073 A2/A3, design note 7.1): the engine side of
  `Letflow.Entities.HandlerWrites.post/3`.

  ## Build time (`build/3`, inside a handler call; no lock, no write)

    * B1 the per-call token and the context (as `create/3`; absent or forged is `:invalid_context`);
    * B2 the size caps (256 KiB command, 200 legs), BEFORE the policy is called;
    * B3 the registration's `declare/2` through `Catalog.declare_posting/2` (zero queries; a raise,
      exit or throw keeps no text);
    * B4 the core re-validation (`Validate.posting/3`, the call `Ledger` makes at run time) plus the
      handler's ledger-id and event-window checks;
    * B5 the per-transaction posting plan (the postings planned by the calls built before this one);
    * B6 `Capability.mint/4`; B7 ONE step `{:line, key, :ledger_post}` that shares the call's 49
      write slots with `create/3`.

  The problems of B2 to B5 are never raised at build time: the FIRST one found is stored as the
  capability's `deferred_refusal` and released at run time, after the origin and authority checks.

  ## Run time

    1. `{:line, key, :ledger_post}` PLANS only: origin (`{:task, _}` only), `Authority.check/1`
       (credential, roles from the database, scope), then the deferred refusal, then
       `{:ok, {:planned, capability}}`. It locks nothing and writes nothing.
    2. `lock_steps/1`, appended once by `StepWrites` after the LAST handler call, takes the ONE lock
       step of decision 0073 A3 over the union of all planned postings (`Ledger.lock_postings/1`:
       insert-if-absent ascending, `FOR UPDATE` ascending, counters ascending by ledger id) and then
       writes each posting in ascending ledger-id order (`Ledger.write_posting/2`). A node without a
       posting line adds nothing (an empty sub-multi).

  This is the only module outside `Letflow.Ledger` that names `lock_postings` / `write_posting`.
  """

  alias Ecto.Multi
  alias Letflow.Entities.HandlerContext
  alias Letflow.Entities.HandlerWrites
  alias Letflow.Entities.StepSource
  alias Letflow.Ledger
  alias Letflow.Ledger.Authority
  alias Letflow.Ledger.Capability
  alias Letflow.Ledger.Validate

  @max_command_bytes 262_144
  @max_legs 200
  @max_postings 2
  @origin_key_node ~r/\A[A-Za-z0-9._-]{1,64}\z/

  # ---------------------------------------------------------------------
  # Build time
  # ---------------------------------------------------------------------

  @spec build(Multi.t(), HandlerContext.t(), term()) ::
          {:ok, Multi.t()} | {:error, :invalid_context | :too_many_writes}
  def build(%Multi{} = multi, ctx, command) when is_struct(ctx, HandlerContext) do
    with {:ok, token} <- HandlerWrites.__token__(ctx),
         {:ok, name, registration} <- registration(ctx),
         {:ok, ordinal} <- HandlerWrites.__next_ordinal__(token) do
      key = StepSource.call_key(ctx.line_index) + ordinal
      build = check_command(command, registration, token)

      case Capability.mint(ctx, name, build, origin_key(ctx.origin, ctx.node_id, key)) do
        {:ok, cap} ->
          step = {:line, key, :ledger_post}
          appended = Multi.run(multi, step, fn _repo, _changes -> run_plan_step(cap) end)
          HandlerWrites.__record__(token, Multi.to_list(appended) -- Multi.to_list(multi))
          {:ok, appended}

        {:error, :invalid_context} ->
          {:error, :invalid_context}
      end
    else
      :error -> {:error, :invalid_context}
      {:error, :too_many_writes} = error -> error
    end
  end

  def build(_multi, _ctx, _command), do: {:error, :invalid_context}

  # The handler's `posts_ledger` name and its plain registration, from the compiled manifest.
  defp registration(%{handler: %{module_id: module_id, name: handler_name}}) do
    with {:ok, name} <- HandlerWrites.__posts_ledger__(module_id, handler_name),
         {:ok, registration} <- HandlerWrites.__registration__(module_id, name) do
      {:ok, name, registration}
    else
      _unresolved -> :error
    end
  end

  # B2..B5. Returns the build result map for `Capability.mint/4`.
  defp check_command(command, registration, token) do
    cond do
      not capped?(command) ->
        %{posting: nil, command: %{}, deferred_refusal: shape_refusal()}

      true ->
        {posting, refusal} = declare_and_validate(command, registration)
        refusal = refusal || plan_refusal(posting, token)
        %{posting: posting, command: command, deferred_refusal: refusal}
    end
  end

  defp capped?(command) when is_map(command) and not is_struct(command) do
    byte_size(:erlang.term_to_binary(command)) <= @max_command_bytes and
      legs_within_cap?(Map.get(command, :legs, Map.get(command, "legs")))
  end

  defp capped?(_command), do: false

  defp legs_within_cap?(legs) when is_list(legs), do: length(legs) <= @max_legs
  defp legs_within_cap?(_legs), do: true

  defp shape_refusal, do: typed(:invalid_posting, %{leg_no: nil, reason: :posting_shape})

  defp typed(code, details),
    do: {:typed, {:ledger_refused, code, Atom.to_string(code), details}}

  defp declare_and_validate(command, registration) do
    case HandlerWrites.__declare__(registration, command) do
      {:ok, posting} ->
        {posting, revalidate(posting, command, registration)}

      {:error, {:invalid_posting, details}} ->
        {nil, typed(:invalid_posting, declared_details(details))}

      {:error, _other} ->
        {nil, {:forbidden, :declare_refused}}
    end
  end

  # The details of an `invalid_posting` the policy returned, reduced to the closed shape.
  defp declared_details(details) do
    leg_no = Map.get(details, :leg_no)
    reason = Map.get(details, :reason)

    %{
      leg_no: if(is_integer(leg_no), do: leg_no, else: nil),
      reason: if(reason in Validate.reasons(), do: reason, else: :unspecified)
    }
  end

  defp revalidate(posting, command, registration) do
    case validate(posting, command, registration) do
      {:ok, normalised} -> check_window(normalised, registration)
      {:error, {:ledger_refused, code, _wire, details}} -> typed(code, details)
      {:error, _other} -> shape_refusal()
    end
  end

  # `Validate.posting/3` is pure; a policy that returned a malformed map must not crash the build.
  defp validate(posting, command, registration) do
    Validate.posting(posting, command, registration)
  rescue
    _exception -> Validate.refuse(:invalid_posting, %{leg_no: nil, reason: :posting_shape})
  end

  defp check_window(normalised, registration) do
    cond do
      normalised.ledger_id not in registration.ledger_ids ->
        typed(:invalid_posting, %{leg_no: nil, reason: :ledger_id_invalid})

      match?(%DateTime{}, Map.get(normalised, :client_event_time)) ->
        case Validate.check_event_window(
               normalised.client_event_time,
               DateTime.utc_now(),
               registration
             ) do
          :ok -> nil
          {:error, {:ledger_refused, code, _wire, details}} -> typed(code, details)
        end

      true ->
        nil
    end
  end

  # B5, in this order (decision 0073 A2): a second `post/3` of this call, then the plan.
  defp plan_refusal(posting, %{plan: plan, produced: produced}) do
    cond do
      Enum.any?(produced, &match?({{:line, _, :ledger_post}, _}, &1)) ->
        {:contract, :too_many_postings}

      length(plan) >= @max_postings ->
        {:contract, :ledger_too_many_postings}

      not is_map(posting) ->
        nil

      Enum.any?(plan, &(&1.ledger_id == Map.get(posting, :ledger_id))) ->
        {:contract, :ledger_duplicate_ledger_in_transaction}

      plan != [] and not same_document?(plan, posting) ->
        {:contract, :ledger_document_mismatch}

      true ->
        nil
    end
  end

  defp same_document?(plan, posting) do
    type = Map.get(posting, :document_type)
    id = Map.get(posting, :document_id)

    present?(type) and present?(id) and
      Enum.all?(plan, &(&1.document_type == type and &1.document_id == id))
  end

  defp present?(value), do: is_binary(value) and value != ""

  # Server-built, deterministic per call and never taken from the command.
  defp origin_key({tag, id}, node_id, key) do
    node =
      if is_binary(node_id) and Regex.match?(@origin_key_node, node_id),
        do: node_id,
        else: hash(node_id)

    "#{tag}:#{id}:#{node}:#{key}"
  end

  defp hash(value) do
    :sha256 |> :crypto.hash(:erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------
  # Run time
  # ---------------------------------------------------------------------

  defp run_plan_step(%{origin: {:task, _}} = cap) do
    with :ok <- authority(cap),
         :ok <- release(cap.deferred_refusal) do
      {:ok, {:planned, cap}}
    end
  end

  defp run_plan_step(_cap), do: {:error, {:ledger_denied, :ledger_origin_not_supported}}

  defp authority(cap) do
    case Authority.check(cap) do
      :ok -> :ok
      {:error, detail} -> {:error, {:ledger_denied, detail}}
    end
  end

  defp release(nil), do: :ok
  defp release({:typed, refusal}), do: {:error, refusal}
  defp release({:forbidden, _}), do: {:error, {:ledger_denied, :declare_refused}}
  defp release({:contract, code}), do: {:error, {:ledger_contract, code}}

  @doc """
  Appends the one lock step (decision 0073 A3) after the last handler call of a node: a single
  `Multi.merge` that reads the planned capabilities from the changes. A node none of whose lines
  names a handler that posts to a ledger gets no extra step at all (its Multi is unchanged).
  """
  @spec lock_steps(Multi.t(), [map()]) :: Multi.t()
  def lock_steps(%Multi{} = multi, module_lines) when is_list(module_lines) do
    if Enum.any?(module_lines, &posts_ledger?/1), do: lock_merge(multi), else: multi
  end

  defp posts_ledger?(%{"module" => module_id, "handler" => name}) do
    match?({:ok, _ledger}, HandlerWrites.__posts_ledger__(module_id, name))
  end

  defp posts_ledger?(_line), do: false

  defp lock_merge(multi) do
    Multi.merge(multi, fn changes ->
      case planned(changes) do
        [] ->
          Multi.new()

        caps ->
          Multi.new()
          |> Multi.run({:ledger_lock, :all}, fn _repo, _changes -> Ledger.lock_postings(caps) end)
          |> Multi.run({:ledger_write, :all}, fn _repo, %{{:ledger_lock, :all} => plan} ->
            write_all(plan)
          end)
      end
    end)
  end

  defp planned(changes) do
    for({{:line, key, :ledger_post}, {:planned, cap}} <- changes, do: {key, cap})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp write_all(plan) do
    plan.postings
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn ledger_id, {:ok, acc} ->
      case Ledger.write_posting(plan, ledger_id) do
        {:ok, posted} -> {:cont, {:ok, Map.put(acc, ledger_id, posted)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
