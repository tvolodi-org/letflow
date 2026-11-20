defmodule Letflow.Modules.Maintenance.Orders do
  @moduledoc """
  REQ-896 / GH #4804 (CMMS slice 1 part 4, `docs/cmms/scope-draft.md`): the work orders of module
  `maintenance`: `create/3`, `assign/4`, `list/2` and `get/2`. The record type answers 403
  `entity_type_managed` on the generic routes, so this module is its only writer (with `Requests`
  for the request it orders); it writes through `Letflow.Entities.Records` with the module authority.

  ## Create

  Two sources, exactly one: `request_id` (a `new` request, else `:request_not_new`; the order copies
  its card, unit, description and urgency) or `asset_card_id`, `description` and `urgency` (the rules
  of `Requests.create/3`); anything else is `:order_source_invalid`. An optional `assignee_user_id`
  must be an active user of the tenant (`:assignee_not_found`). Rules run before any write. One
  transaction then writes the order record, its issued `maintenance_order` document (WO), the
  request's change (`ordered`, `order_id`) and the instance of the process `maintenance_work_order`
  (`Letflow.Engine.create/2`, activated lazily with the request's activator: `:definition_not_active`
  when that fails); a failure of any of them leaves none. The record is created first with the
  placeholders `"pending"` (document, instance), as `Requests` does, so a replay of the same
  idempotency key is answered with the original.

  After the commit an assignee is applied with `Letflow.Tasks.reassign_task/3` (the `task_assigned`
  mail and bell). A refusal there is logged by tag and leaves the order open: the planner assigns
  again through `assign/4`.

  ## Status

  Never stored. Derived from the order's instance (`status/2`): `cancelled` when the instance was
  cancelled; `open` when `maintenance_work` is pending and routed to a role; `in_work` when it is
  pending and addressed to a user; `done` when it is completed and `maintenance_close` is pending;
  `closed` when `maintenance_close` is completed; `unknown` for any other state (INV-8).

  ## What was done (REQ-897)

  The view carries the done and close record of the order: `work_done`, `done_by`, `done_at`,
  `closed_by` and `closed_at`. They are fields of the order record, written by the two write
  handlers of the module (`Letflow.Modules.Maintenance.Handlers`) when the `maintenance_work` and
  the `maintenance_close` tasks are completed, and they are null until then. A closed order is
  never changed again: no route of the module updates or deletes an order (assign on a closed
  order is `order_not_assignable`), and a correction is a new order.

  The tenant is `prefix`, derived from the token on the server (INV-1). `opts`: `:actor_id`,
  `:actor_roles`, `:activator`, and for `create/3` `:idempotency_key`.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Documents
  alias Letflow.Engine
  alias Letflow.Engine.Task
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.User
  alias Letflow.Modules.Maintenance.Requests
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo
  alias Letflow.Tasks

  @order_type "maintenance_work_order"
  @request_type "maintenance_work_request"
  @definition "maintenance_work_order"
  @work_node "maintenance_work"
  @close_node "maintenance_close"
  @allowed ~w(request_id asset_card_id description urgency assignee_user_id)
  @statuses ~w(open in_work done closed cancelled)
  @default_limit 50
  @max_limit 200
  @chunk 200
  @pending "pending"

  @doc "The statuses a list filter accepts."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  # --- create -----------------------------------------------------------------------------------

  @doc "Creates an order (document, instance, request change) and returns its view."
  @spec create(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create(prefix, attrs, opts) when is_binary(prefix) and is_map(attrs) and is_map(opts) do
    actor = Map.fetch!(opts, :actor_id)
    key = Map.fetch!(opts, :idempotency_key)

    with :ok <- check_keys(attrs),
         {:ok, source} <- source(attrs),
         {:ok, assignee} <- check_assignee(prefix, Map.get(attrs, "assignee_user_id")) do
      replay? = replay?(prefix, key)

      with {:ok, fv} <- build_fields(prefix, source, attrs, actor, replay?) do
        result =
          if replay?,
            do: replay(prefix, fv, actor, key),
            else: write(prefix, fv, actor, key, opts)

        with {:ok, view} <- result do
          {:ok, apply_assignee(prefix, view, assignee, opts)}
        end
      end
    end
  end

  defp check_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @allowed)) do
      nil -> :ok
      key -> {:error, {:field_not_allowed, to_string(key)}}
    end
  end

  defp source(attrs) do
    from_request? = Map.has_key?(attrs, "request_id")
    direct? = Enum.any?(~w(asset_card_id description urgency), &Map.has_key?(attrs, &1))

    cond do
      from_request? and not direct? -> {:ok, {:request, attrs["request_id"]}}
      direct? and not from_request? and Map.has_key?(attrs, "asset_card_id") -> {:ok, :direct}
      true -> {:error, :order_source_invalid}
    end
  end

  defp check_assignee(_prefix, nil), do: {:ok, nil}

  defp check_assignee(prefix, id) do
    case active_user(prefix, id) do
      true -> {:ok, id}
      false -> {:error, :assignee_not_found}
    end
  end

  defp active_user(prefix, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.exists?(from(u in User, where: u.id == ^uuid and u.status == :active),
          prefix: prefix
        )

      :error ->
        false
    end
  end

  defp active_user(_prefix, _other), do: false

  defp build_fields(prefix, {:request, id}, _attrs, _actor, _replay?) do
    with {:ok, row} <- fetch_request(prefix, id) do
      fv = row.field_values

      {:ok,
       %{
         "asset_card_id" => fv["asset_card_id"],
         "org_unit_id" => fv["org_unit_id"],
         "description" => fv["description"],
         "urgency" => fv["urgency"],
         "request_id" => row.record_id,
         "document_id" => @pending,
         "instance_id" => @pending
       }}
    end
  end

  defp build_fields(prefix, :direct, attrs, _actor, replay?) do
    with {:ok, card} <- find_card(prefix, attrs["asset_card_id"]),
         :ok <- if(replay?, do: :ok, else: check_active(card)),
         {:ok, description} <- check_description(attrs["description"]),
         {:ok, urgency} <- check_urgency(attrs["urgency"]),
         {:ok, unit} <- check_unit(card) do
      {:ok,
       %{
         "asset_card_id" => card["record_id"],
         "org_unit_id" => unit,
         "description" => description,
         "urgency" => urgency,
         "document_id" => @pending,
         "instance_id" => @pending
       }}
    end
  end

  defp find_card(prefix, id) do
    case ReadApi.lookup(prefix, id, ["assets_card"]) do
      {:ok, card} -> {:ok, card}
      {:error, :not_found} -> {:error, :asset_card_not_found}
    end
  end

  defp check_active(%{"active" => true}), do: :ok
  defp check_active(_card), do: {:error, :asset_card_inactive}

  defp check_unit(%{"org_unit_id" => unit}) when is_binary(unit) and unit != "", do: {:ok, unit}
  defp check_unit(_card), do: {:error, :asset_card_no_org_unit}

  defp check_description(text) when is_binary(text) do
    cond do
      byte_size(text) > 2000 * 4 + 64 -> {:error, :description_too_long}
      not String.valid?(text) -> {:error, :description_required}
      String.trim(text) == "" -> {:error, :description_required}
      String.length(String.trim(text)) > 2000 -> {:error, :description_too_long}
      true -> {:ok, String.trim(text)}
    end
  end

  defp check_description(_other), do: {:error, :description_required}

  defp check_urgency(urgency) do
    if urgency in Requests.urgencies(), do: {:ok, urgency}, else: {:error, :invalid_urgency}
  end

  # Records detects a replay by failing its own multi, which a surrounding transaction cannot
  # survive: a claimed key goes to Records alone.
  defp replay?(prefix, key),
    do:
      Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^key), prefix: prefix)

  defp replay(prefix, fv, actor, key) do
    with {:ok, record_id} <- create_order(prefix, fv, actor, key),
         {:ok, row} <- fetch(prefix, record_id) do
      {:ok, view(prefix, row)}
    end
  end

  defp write(prefix, fv, actor, key, opts) do
    Repo.transaction(fn ->
      with :ok <- ensure_active(prefix, Map.get(opts, :activator)),
           {:ok, fv} <- lock_request(prefix, fv),
           {:ok, record_id} <- create_order(prefix, fv, actor, key),
           {:ok, document_id} <- issue_document(prefix, record_id, fv, actor),
           {:ok, instance_id} <- start_instance(prefix, record_id, document_id, fv, actor),
           fv = Map.merge(fv, %{"document_id" => document_id, "instance_id" => instance_id}),
           {:ok, _} <- update_order(prefix, record_id, fv, actor),
           :ok <- mark_ordered(prefix, fv, record_id, actor),
           {:ok, row} <- fetch(prefix, record_id),
           :ok <- audit(prefix, actor, "maintenance_work_order.created", record_id, row) do
        view(prefix, row)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The request must still be new under its advisory lock (two orders from one request serialize).
  defp lock_request(prefix, %{"request_id" => request_id} = fv) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":" <> @request_type <> ":" <> request_id
    ])

    case fetch_request(prefix, request_id) do
      {:ok, %Latest{field_values: %{"status" => "new"}}} -> {:ok, fv}
      {:ok, _row} -> {:error, :request_not_new}
      {:error, _} = error -> error
    end
  end

  defp lock_request(_prefix, fv), do: {:ok, fv}

  defp mark_ordered(prefix, %{"request_id" => request_id}, order_id, actor) do
    with {:ok, row} <- fetch_request(prefix, request_id),
         fv = Map.merge(row.field_values, %{"status" => "ordered", "order_id" => order_id}),
         {:ok, _} <-
           write_record(
             :update,
             prefix,
             @request_type,
             request_id,
             fv,
             actor,
             Ecto.UUID.generate()
           ) do
      :ok
    end
  end

  defp mark_ordered(_prefix, _fv, _order_id, _actor), do: :ok

  defp issue_document(prefix, record_id, fv, actor) do
    content = %{
      "order_id" => record_id,
      "request_id" => fv["request_id"],
      "asset_card_id" => fv["asset_card_id"],
      "description" => fv["description"],
      "urgency" => fv["urgency"]
    }

    with {:ok, %{document: document}} <-
           Documents.create_draft(
             prefix,
             %{
               type_key: "maintenance_order",
               issuing_org_unit_id: fv["org_unit_id"],
               content: content
             },
             actor
           ),
         {:ok, _} <- Documents.issue(prefix, %{document_id: document.id, actor_id: actor}) do
      {:ok, document.id}
    else
      {:error, reason} -> {:error, {:document, reason}}
    end
  end

  # The variables carry the card's inventory number and name only, never a cost field.
  defp start_instance(prefix, order_id, document_id, fv, actor) do
    card = lookup_card(prefix, fv["asset_card_id"])

    attrs = %{
      definition_name: @definition,
      initial_variables: %{
        "maintenance_order_id" => order_id,
        "maintenance_order_number" => number(prefix, document_id),
        "asset_inventory_number" => card["inventory_number"],
        "asset_name" => card["name"],
        "description" => fv["description"],
        "urgency" => fv["urgency"]
      },
      actor_id: actor,
      idempotency_key: "maintenance-order:" <> order_id
    }

    with :ok <- start_seam(),
         {:ok, %{instance_id: instance_id}} <- Engine.create(attrs, prefix: prefix) do
      {:ok, instance_id}
    else
      {:error, :definition_not_active} ->
        {:error, :definition_not_active}

      {:error, reason} ->
        Logger.warning("maintenance order start refused: #{inspect(tag(reason))}")
        {:error, :start_failed}
    end
  end

  # Test seam: forces a start failure inside the transaction. Read here only.
  defp start_seam do
    if Application.get_env(:letflow, :maintenance_order_start_fail?) == true,
      do: {:error, :forced_start_failure},
      else: :ok
  end

  # --- lazy activation --------------------------------------------------------------------------

  defp ensure_active(prefix, activator) do
    case Definitions.get_active_by_name(@definition, prefix: prefix) do
      {:ok, row} -> if stamped?(row), do: :ok, else: {:error, :definition_not_active}
      {:error, :not_found} -> activate_draft(prefix, activator)
      _other -> {:error, :definition_not_active}
    end
  end

  defp activate_draft(prefix, activator) do
    with true <- activator?(activator),
         %ProcessDefinition{id: id} <- stamped_draft(prefix),
         {:ok, _activated} <- Definitions.activate(id, prefix: prefix, activator: activator) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("maintenance definition activation refused: #{inspect(tag(reason))}")
        {:error, :definition_not_active}

      _refused ->
        {:error, :definition_not_active}
    end
  end

  defp activator?(%{permissions: permissions, entities_records_write?: true})
       when is_list(permissions),
       do: "DefinitionsActivate" in permissions

  defp activator?(_other), do: false

  defp stamped_draft(prefix) do
    Repo.one(
      from(d in ProcessDefinition,
        where: d.name == ^@definition and d.status == :draft and d.owner_module == "maintenance",
        order_by: [desc: d.created_at],
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp stamped?(row), do: match?({:ok, %{module_id: "maintenance"}}, OwnerStamp.from_row(row))

  defp tag(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp tag(reason), do: reason

  # --- assign -----------------------------------------------------------------------------------

  # After the commit of a create: an assignee is applied like `assign/4`; a refusal is logged only.
  defp apply_assignee(_prefix, view, nil, _opts), do: view

  defp apply_assignee(prefix, view, user_id, opts) do
    case readdress(prefix, view["id"], user_id, opts) do
      :ok ->
        {:ok, row} = fetch(prefix, view["id"])
        view(prefix, row)

      {:error, reason} ->
        Logger.warning("maintenance order assignment refused: #{inspect(tag(reason))}")
        view
    end
  end

  @doc "Readdresses the work task of an open or in-work order to `user_id` and returns the view."
  @spec assign(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def assign(prefix, id, user_id, opts) when is_binary(prefix) and is_map(opts) do
    actor = Map.fetch!(opts, :actor_id)

    with {:ok, row} <- fetch(prefix, id),
         {:ok, user_id} <- check_assignee(prefix, user_id),
         :ok <- readdress(prefix, row.record_id, user_id, opts),
         {:ok, fresh} <- fetch(prefix, row.record_id),
         :ok <- audit(prefix, actor, "maintenance_work_order.assigned", row.record_id, fresh) do
      {:ok, view(prefix, fresh)}
    end
  end

  defp readdress(prefix, order_id, user_id, opts) do
    with {:ok, row} <- fetch(prefix, order_id),
         {:ok, task} <- pending_work_task(prefix, row) do
      attrs = %{
        user_id: user_id,
        actor_id: Map.fetch!(opts, :actor_id),
        actor_roles: Map.get(opts, :actor_roles, [])
      }

      case Tasks.reassign_task(task.id, attrs, prefix: prefix) do
        {:ok, _task} -> :ok
        {:error, {:task_not_pending, _}} -> {:error, :order_not_assignable}
        {:error, reason} -> {:error, {:reassign, reason}}
      end
    end
  end

  defp pending_work_task(prefix, %Latest{field_values: fv}) do
    case instance_id(fv) do
      nil ->
        {:error, :order_not_assignable}

      instance_id ->
        task =
          Repo.one(
            from(t in Task,
              where:
                t.instance_id == ^instance_id and t.node_id == @work_node and
                  t.status == :pending,
              limit: 1
            ),
            prefix: prefix
          )

        if task, do: {:ok, task}, else: {:error, :order_not_assignable}
    end
  end

  # --- reads ------------------------------------------------------------------------------------

  @doc "One order view; an unknown, malformed or other tenant's id is `{:error, :not_found}`."
  @spec get(String.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def get(prefix, id) when is_binary(prefix) do
    with {:ok, row} <- fetch(prefix, id), do: {:ok, view(prefix, row)}
  end

  @doc """
  The orders newest first. `params` (string keys): `status` (#{Enum.join(@statuses, ", ")}),
  `asset_card_id`, `limit` (1..#{@max_limit}, default #{@default_limit}) and `cursor` (opaque); any
  other key or value is `{:error, :invalid_filter}`. The status is derived, so the page is filled by
  reading the newest rows in chunks and keeping the matching ones.
  """
  @spec list(String.t(), map()) ::
          {:ok, %{rows: [map()], next_cursor: String.t() | nil}} | {:error, :invalid_filter}
  def list(prefix, params) when is_binary(prefix) and is_map(params) do
    with {:ok, filter} <- list_params(params) do
      {:ok, collect(prefix, filter, filter.cursor, [])}
    end
  end

  defp collect(prefix, filter, cursor, acc) do
    rows =
      from(l in Latest,
        where: l.entity_type == @order_type and l.deleted == false,
        order_by: [desc: l.inserted_at, desc: l.record_id],
        limit: @chunk
      )
      |> where_card(filter.asset_card_id)
      |> where_cursor(cursor)
      |> Repo.all(prefix: prefix)

    statuses = statuses_of(prefix, rows)

    matching =
      rows
      |> Enum.map(&{&1, Map.fetch!(statuses, &1.record_id)})
      |> Enum.filter(fn {_row, st} -> filter.status in [nil, st.status] end)

    take = filter.limit + 1 - length(acc)
    {page, _} = Enum.split(matching, take)
    acc = acc ++ page

    cond do
      length(acc) > filter.limit ->
        {shown, _} = Enum.split(acc, filter.limit)
        {last, _} = List.last(shown)
        %{rows: render_rows(prefix, shown), next_cursor: cursor_of(last)}

      length(rows) < @chunk ->
        %{rows: render_rows(prefix, acc), next_cursor: nil}

      true ->
        last = List.last(rows)
        collect(prefix, filter, {last.inserted_at, last.record_id}, acc)
    end
  end

  defp render_rows(prefix, pairs), do: Enum.map(pairs, fn {row, st} -> view(prefix, row, st) end)

  defp list_params(params) do
    with :ok <- only_keys(params, ~w(status asset_card_id limit cursor)),
         {:ok, status} <- status_param(params),
         {:ok, card} <- card_param(params),
         {:ok, limit} <- limit_param(params),
         {:ok, cursor} <- cursor_param(params) do
      {:ok, %{status: status, asset_card_id: card, limit: limit, cursor: cursor}}
    end
  end

  defp only_keys(params, allowed),
    do:
      if(Enum.all?(Map.keys(params), &(&1 in allowed)), do: :ok, else: {:error, :invalid_filter})

  defp status_param(params) do
    case Map.fetch(params, "status") do
      :error -> {:ok, nil}
      {:ok, status} when status in @statuses -> {:ok, status}
      _ -> {:error, :invalid_filter}
    end
  end

  defp card_param(params) do
    case Map.fetch(params, "asset_card_id") do
      :error ->
        {:ok, nil}

      {:ok, text} when is_binary(text) ->
        case Ecto.UUID.cast(text) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, :invalid_filter}
        end

      _ ->
        {:error, :invalid_filter}
    end
  end

  defp limit_param(params) do
    case Map.fetch(params, "limit") do
      :error ->
        {:ok, @default_limit}

      {:ok, text} when is_binary(text) ->
        case Integer.parse(text) do
          {n, ""} when n in 1..@max_limit -> {:ok, n}
          _ -> {:error, :invalid_filter}
        end

      _ ->
        {:error, :invalid_filter}
    end
  end

  defp cursor_param(params) do
    case Map.fetch(params, "cursor") do
      :error ->
        {:ok, nil}

      {:ok, text} when is_binary(text) and byte_size(text) <= 200 ->
        with {:ok, raw} <- Base.url_decode64(text, padding: false),
             [at, rid] <- String.split(raw, "|", parts: 2),
             {:ok, at, 0} <- DateTime.from_iso8601(at),
             {:ok, rid} <- Ecto.UUID.cast(rid) do
          {:ok, {at, rid}}
        else
          _ -> {:error, :invalid_filter}
        end

      _ ->
        {:error, :invalid_filter}
    end
  end

  defp where_card(q, nil), do: q

  defp where_card(q, card),
    do: from(l in q, where: fragment("?->>'asset_card_id' = ?", l.field_values, ^card))

  defp where_cursor(q, nil), do: q

  defp where_cursor(q, {at, rid}) do
    from(l in q, where: l.inserted_at < ^at or (l.inserted_at == ^at and l.record_id < ^rid))
  end

  defp cursor_of(%Latest{inserted_at: at, record_id: rid}),
    do: Base.url_encode64(DateTime.to_iso8601(at) <> "|" <> rid, padding: false)

  # --- status -----------------------------------------------------------------------------------

  @doc """
  The derived status of the orders `rows`: a map of record id to `%{status: s, assignee: user_id | nil}`
  from two reads (the instance projections and the work and close tasks).
  """
  @spec statuses_of(String.t(), [Latest.t()]) :: %{String.t() => map()}
  def statuses_of(_prefix, []), do: %{}

  def statuses_of(prefix, rows) do
    ids = rows |> Enum.map(&instance_id(&1.field_values)) |> Enum.reject(&is_nil/1)

    projections =
      Repo.all(
        from(p in InstanceProjection,
          where: p.instance_id in ^ids,
          select: {p.instance_id, p.status}
        ),
        prefix: prefix
      )
      |> Map.new()

    tasks =
      Repo.all(
        from(t in Task,
          where: t.instance_id in ^ids and t.node_id in [@work_node, @close_node],
          select: %{
            instance_id: t.instance_id,
            node_id: t.node_id,
            status: t.status,
            assignee_type: t.assignee_type,
            assignee_ref: t.assignee_ref,
            completed_by: t.completed_by
          }
        ),
        prefix: prefix
      )
      |> Enum.group_by(& &1.instance_id)

    Map.new(rows, fn row ->
      id = instance_id(row.field_values)
      {row.record_id, derive(Map.get(projections, id), Map.get(tasks, id, []))}
    end)
  end

  defp derive(:cancelled, _tasks), do: %{status: "cancelled", assignee: nil}

  defp derive(_projection, tasks) do
    work = Enum.find(tasks, &(&1.node_id == @work_node))
    close = Enum.find(tasks, &(&1.node_id == @close_node))

    case {work, close} do
      {%{status: :pending, assignee_type: "USER", assignee_ref: user}, _} ->
        %{status: "in_work", assignee: user}

      {%{status: :pending}, _} ->
        %{status: "open", assignee: nil}

      {%{status: :completed} = w, %{status: :pending}} ->
        %{status: "done", assignee: worker(w)}

      {%{status: :completed} = w, %{status: :completed}} ->
        %{status: "closed", assignee: worker(w)}

      _other ->
        %{status: "unknown", assignee: nil}
    end
  end

  defp worker(%{assignee_type: "USER", assignee_ref: user}), do: user
  defp worker(%{completed_by: user}), do: user

  defp instance_id(%{"instance_id" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp instance_id(_fv), do: nil

  # --- storage ----------------------------------------------------------------------------------

  defp fetch(prefix, id), do: fetch_type(prefix, @order_type, id)
  defp fetch_request(prefix, id), do: fetch_type(prefix, @request_type, id)

  defp fetch_type(prefix, type, id) do
    with {:ok, record_id} <- Ecto.UUID.cast(id),
         %Latest{} = row <-
           Repo.one(
             from(l in Latest,
               where: l.entity_type == ^type and l.record_id == ^record_id and not l.deleted
             ),
             prefix: prefix
           ) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  defp create_order(prefix, fv, actor, key),
    do: write_record(:create, prefix, @order_type, nil, fv, actor, key)

  defp update_order(prefix, record_id, fv, actor),
    do: write_record(:update, prefix, @order_type, record_id, fv, actor, Ecto.UUID.generate())

  defp write_record(:create, prefix, type, _id, fv, actor, key) do
    attrs = %{entity_type: type, field_values: fv, actor_id: actor, idempotency_key: key}

    # scope-all: SEC-518-R1 (maintenance module, own-record system path; the caller is checked tenant-wide by Maintenance.Access)
    case Records.create_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = error -> error
    end
  end

  defp write_record(:update, prefix, type, record_id, fv, actor, key) do
    attrs = %{
      entity_type: type,
      record_id: record_id,
      field_values: fv,
      actor_id: actor,
      idempotency_key: key
    }

    # scope-all: SEC-518-R1 (maintenance module, own-record system path; the caller is checked tenant-wide by Maintenance.Access)
    case Records.update_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = error -> error
    end
  end

  defp owner, do: ManagedTypes.owner_for!(Letflow.Modules.Maintenance)

  defp audit(prefix, actor, action, record_id, row) do
    entry = %{
      actor_id: actor,
      action: action,
      resource_type: @order_type,
      resource_id: record_id,
      before_state: nil,
      after_state:
        Map.take(row.field_values, ["asset_card_id", "request_id", "urgency", "document_id"])
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  # --- view -------------------------------------------------------------------------------------

  defp view(prefix, row), do: view(prefix, row, statuses_of(prefix, [row])[row.record_id])

  defp view(prefix, %Latest{field_values: fv} = row, %{status: status, assignee: assignee}) do
    %{
      "id" => row.record_id,
      "number" => number(prefix, fv["document_id"]),
      "status" => status,
      "assignee_user_id" => assignee,
      "asset" => asset(prefix, fv["asset_card_id"]),
      "request" => request_ref(prefix, fv["request_id"]),
      "description" => fv["description"],
      "urgency" => fv["urgency"],
      # REQ-897: what was done and who closed the order. The five fields are null until the
      # task that fills them is completed; the handlers of the module write them on the record.
      "work_done" => fv["work_done"],
      "done_by" => fv["done_by"],
      "done_at" => fv["done_at"],
      "closed_by" => fv["closed_by"],
      "closed_at" => fv["closed_at"],
      "created_at" => DateTime.to_iso8601(row.inserted_at)
    }
  end

  defp request_ref(_prefix, nil), do: nil

  defp request_ref(prefix, id) do
    case fetch_request(prefix, id) do
      {:ok, row} ->
        %{"id" => row.record_id, "number" => number(prefix, row.field_values["document_id"])}

      _ ->
        nil
    end
  end

  defp number(prefix, document_id) do
    case Documents.issued_summary(prefix, document_id) do
      {:ok, %{number_label: label}} -> label
      _ -> nil
    end
  end

  defp lookup_card(prefix, card_id) do
    case ReadApi.lookup(prefix, card_id, ["assets_card"]) do
      {:ok, card} -> card
      {:error, :not_found} -> %{}
    end
  end

  # Only the two fields of the card the view may show.
  defp asset(prefix, card_id) do
    card = lookup_card(prefix, card_id)

    %{
      "id" => card["record_id"] || card_id,
      "inventory_number" => card["inventory_number"],
      "name" => card["name"]
    }
  end
end
