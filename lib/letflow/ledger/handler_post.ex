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

  ## Failure channel (REQ-686)

  A refusal of the plan step keeps its typed shape; a refusal of the lock or write step is wrapped
  as `{:ledger_at, step_key, refusal}` so `Letflow.Ledger.Failure.map/2` can give it a line index,
  with the module's alias applied to the wire code (the core code stays the audit code).

  This is the only module outside `Letflow.Ledger` that names `lock_postings` / `write_posting`.
  """

  alias Ecto.Multi
  alias Letflow.Entities.HandlerContext
  alias Letflow.Entities.HandlerWrites
  alias Letflow.Entities.StepSource
  alias Letflow.Ledger
  alias Letflow.Ledger.Authority
  alias Letflow.Ledger.Capability
  alias Letflow.Ledger.Failure
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
    with {:ok, read?} <- authority(cap),
         :ok <- release(cap) do
      {:ok, {:planned, %{cap | read_disclosed: read?}}}
    end
  end

  defp run_plan_step(_cap), do: {:error, {:ledger_denied, :ledger_origin_not_supported}}

  defp authority(cap) do
    case Authority.check_with_read(cap) do
      {:ok, read?} -> {:ok, read?}
      {:error, detail} -> {:error, {:ledger_denied, detail}}
    end
  end

  defp release(%{deferred_refusal: nil}), do: :ok
  defp release(%{deferred_refusal: {:typed, refusal}} = cap), do: {:error, aliased(refusal, cap)}

  defp release(%{deferred_refusal: {:forbidden, _}}),
    do: {:error, {:ledger_denied, :declare_refused}}

  defp release(%{deferred_refusal: {:contract, code}}), do: {:error, {:ledger_contract, code}}

  # REQ-686 (note 12.2): the wire code is the module's alias for an aliasable core code, else the
  # core code itself. The status, the audit entry, the log and any metric follow the core code.
  defp aliased({:ledger_refused, code, _wire, details}, cap) do
    core = Atom.to_string(code)
    wire = Map.get(Map.get(cap.registration, :error_aliases) || %{}, core, core)
    {:ledger_refused, code, wire, details}
  end

  defp aliased(other, _cap), do: other

  # A refusal of the lock or write step carries no line index of its own: the step key of the
  # posting line is added (`{:ledger_at, key, refusal}`) and the alias applied. Assumption
  # (REQ-686 F5): a plan-wide refusal uses the LOWEST posting line.
  defp keyed_error({:error, {:ledger_refused, _, _, _} = refusal}, key, cap),
    do: {:error, {:ledger_at, key, aliased(refusal, cap)}}

  defp keyed_error({:error, {:ledger_contract, _} = contract}, key, _cap),
    do: {:error, {:ledger_at, key, contract}}

  defp keyed_error(other, _key, _cap), do: other

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

        keyed ->
          caps = Enum.map(keyed, &elem(&1, 1))
          {first_key, first_cap} = hd(keyed)

          Multi.new()
          |> Multi.run({:ledger_lock, :all}, fn _repo, _changes ->
            caps |> Ledger.lock_postings() |> keyed_error(first_key, first_cap)
          end)
          |> Multi.run({:ledger_write, :all}, fn _repo, %{{:ledger_lock, :all} => plan} ->
            write_all(plan, keyed)
          end)
      end
    end)
  end

  # `[{step key, capability}]` ascending by key.
  defp planned(changes) do
    for({{:line, key, :ledger_post}, {:planned, cap}} <- changes, do: {key, cap})
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp write_all(plan, keyed) do
    plan.postings
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn ledger_id, {:ok, acc} ->
      case Ledger.write_posting(plan, ledger_id) do
        {:ok, posted} ->
          {:cont, {:ok, Map.put(acc, ledger_id, posted)}}

        {:error, _} = error ->
          {key, cap} = cap_for(keyed, ledger_id)
          {:halt, keyed_error(error, key, cap)}
      end
    end)
  end

  defp cap_for(keyed, ledger_id) do
    Enum.find(keyed, hd(keyed), fn {_key, cap} ->
      is_map(cap.posting) and Map.get(cap.posting, :ledger_id) == ledger_id
    end)
  end

  @doc """
  Maps a failed ledger step's reason to the engine's failure channel
  (`Letflow.Ledger.Failure.map/2`); `StepWrites` names only this module.
  """
  @spec failure(non_neg_integer(), term()) :: Letflow.Engine.EntityPort.failure()
  def failure(index, reason), do: Failure.map(index, reason)

  @doc """
  The `ledger.posted` audit summaries of a node's posted entries (REQ-686), read from the changes
  of the lock merge: ascending by ledger id, one per entry actually written (a duplicate replay
  writes nothing and has none). Ids, the cause, a count and the chain hash only.
  """
  @spec posted_summaries(map()) :: [map()]
  def posted_summaries(changes) when is_map(changes) do
    with %{} = written <- Map.get(changes, {:ledger_write, :all}),
         %{postings: postings} <- Map.get(changes, {:ledger_lock, :all}) do
      for {ledger_id, %{duplicate: false} = posted} <- Enum.sort(written),
          %{posting: posting} <- [Map.get(postings, ledger_id)] do
        %{
          entry_id: posted.entry_id,
          ledger_id: ledger_id,
          posting_seq: posted.posting_seq,
          cause: posting.cause,
          leg_count: length(posting.legs),
          chain_hash: posted.chain_hash
        }
      end
    else
      _none -> []
    end
  end
end
