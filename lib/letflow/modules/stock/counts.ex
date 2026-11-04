defmodule Letflow.Modules.Stock.Counts do
  @moduledoc """
  REQ-700 / GH #3737 (assets phase B, decision 0079 sections 1 to 4 and 9): the count order of module
  `stock`. A count order is issued by a clerk for ONE org unit: a kind (`full` or `selective`), a set of
  root locations (the order covers each root and everything below it), a planned period and a
  commission (a chair and members, all employees). This module only keeps the order; the cut-off, the
  book quantities and the count sheet are REQ-701, posting is a later slice. No ledger call is made.

  Three module-managed record types (pack `priv/modules/stock/pack.json`): `count_order` (header),
  `count_order_scope` (one row per root) and `count_commission_member` (one row per member), all
  scoped by the column `org_unit_id` (decision 0076 R7, D-067). Four document types are registered
  at install (`count.order`, `count.sheet`, `count.differences`, `count.posting`); only `count.order`
  is issued here. Assumptions, owner may change at GATE B: one org unit per order; the chair must be
  linked to a user; at most 96 hours from planned start to planned end; the document number
  prefixes CO, CS, CD and CP; no client idempotency key (a retried create makes a second draft, which
  cancel removes); the default tenant time zone Asia/Almaty is a paperwork concern and not used here
  (times are stored in UTC).

  `opts` of every function is `%{actor_id: uuid, scope: :all | {:nodes, [org_unit_id]}}`. The caller
  has already checked the permission; `scope` is the caller's allowed set of org unit ids. An order of
  another unit, an unknown id, a malformed id and another tenant's id are all `{:error, :not_found}`
  and nothing about the order is read beyond its org unit (INV-5).

  ## Writes

  Each write is one transaction. A refusal stores nothing. An accepted write audits one entry
  (`stock.count_order.created|updated|issued|cancelled`) with ids and status only. `Audit` raises on a
  database failure (INV-8): the raise becomes `{:error, :audit_failed}` and the transaction rolls back.

  `issue/3` takes a per-tenant, per-org-unit advisory lock as the FIRST statement of its transaction
  (a bound parameter, INV-7), then re-checks the state and the overlap against the other open orders of
  the unit, so two overlapping orders issued at once give exactly one winner. After the lock only the
  Records type locks and the Documents row and sequence locks are taken, always Records first; no
  ledger, engine or instance lock is taken (decision 0061 lock classes are not touched).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Documents
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Locations.Tree
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @input_keys ~w(org_unit_id kind planned_start planned_end chair_employee_id member_employee_ids location_ids note)
  @kinds ~w(full selective)
  @statuses ~w(draft ordered counting counted signed posted cancelled)
  @blocking ~w(ordered counting counted signed)
  @cancellable ~w(draft ordered counting counted)
  @max_seconds 96 * 3600
  @max_note 1000
  @max_list 500
  @kept ["record_id", "entity_type"]
  @list_keys ~w(status org_unit_id limit cursor)

  # --- create / update --------------------------------------------------------------------------

  @doc "Creates a draft order with its scope and commission rows. Returns the order view."
  @spec create(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def create(prefix, input, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)

    with {:ok, input} <- check_keys(input),
         {:ok, unit} <- uuid_field(input, "org_unit_id"),
         :ok <- in_scope(scope, unit),
         {:ok, doc} <- parse(input, unit),
         :ok <- check_people(prefix, doc) do
      Repo.transaction(fn ->
        with {:ok, id} <- write_new(prefix, doc, actor),
             :ok <- audit(prefix, actor, "created", id, nil, "draft") do
          view!(prefix, id)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Replaces a draft order (the header, the roots and the members). Whole-document replace."
  @spec update(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def update(prefix, id, input, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         {:ok, input} <- check_keys(input),
         {:ok, unit} <- uuid_field(input, "org_unit_id"),
         :ok <- in_scope(scope, unit),
         :ok <- draft?(header),
         {:ok, doc} <- parse(input, unit),
         :ok <- check_people(prefix, doc) do
      Repo.transaction(fn ->
        with {:ok, fresh} <- fetch(prefix, header["record_id"], scope),
             :ok <- draft?(fresh),
             :ok <- delete_children(prefix, fresh["record_id"], actor),
             {:ok, _} <- rewrite_header(prefix, fresh, doc, actor),
             :ok <- write_children(prefix, fresh["record_id"], doc, actor),
             :ok <- audit(prefix, actor, "updated", fresh["record_id"], "draft", "draft") do
          view!(prefix, fresh["record_id"])
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # --- issue ------------------------------------------------------------------------------------

  @doc """
  Issues a draft order: the pre-checks (employees, org unit, linked roots, overlap inside the order,
  completeness of a full count, duration), then under the org-unit lock the overlap against the other
  open orders, the document `count.order` is created and issued, and the order becomes `ordered`.
  """
  @spec issue(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def issue(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         :ok <- draft?(header),
         doc = doc_of(prefix, header),
         :ok <- check_people(prefix, doc),
         :ok <- check_linked(prefix, doc),
         :ok <- check_inside(prefix, doc),
         :ok <- check_complete(prefix, doc),
         :ok <- check_duration(doc) do
      Repo.transaction(fn ->
        lock!(prefix, doc.org_unit_id)

        with {:ok, fresh} <- fetch(prefix, header["record_id"], scope),
             :ok <- draft?(fresh),
             :ok <- check_overlap(prefix, fresh["record_id"], doc),
             {:ok, issued} <- issue_document(prefix, fresh, doc, actor),
             {:ok, _} <- mark_ordered(prefix, fresh, issued, actor),
             :ok <- audit(prefix, actor, "issued", fresh["record_id"], "draft", "ordered") do
          view!(prefix, fresh["record_id"])
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp issue_document(prefix, header, doc, actor) do
    content = %{
      "count_order_id" => header["record_id"],
      "org_unit_id" => doc.org_unit_id,
      "kind" => doc.kind,
      "planned_start" => doc.planned_start,
      "planned_end" => doc.planned_end,
      "chair_employee_id" => doc.chair_employee_id,
      "member_employee_ids" => doc.member_employee_ids,
      "location_ids" => doc.location_ids,
      "note" => doc.note || ""
    }

    with {:ok, %{document: document}} <-
           Documents.create_draft(
             prefix,
             %{type_key: "count.order", issuing_org_unit_id: doc.org_unit_id, content: content},
             actor
           ),
         {:ok, _} <- Documents.issue(prefix, %{document_id: document.id, actor_id: actor}),
         {:ok, summary} <- Documents.issued_summary(prefix, document.id) do
      {:ok, Map.put(summary, :document_id, document.id)}
    else
      {:error, reason} -> {:error, {:document, reason}}
    end
  end

  defp mark_ordered(prefix, header, issued, actor) do
    fv =
      header
      |> Map.drop(@kept)
      |> Map.merge(%{
        "status" => "ordered",
        "document_id" => issued.document_id,
        "number" => issued.number_label,
        "issued_at" => iso(issued.issued_at),
        "issued_by" => actor
      })

    update_record(prefix, header["record_id"], "count_order", fv, actor)
  end

  # --- cancel -----------------------------------------------------------------------------------

  @doc "Cancels an order (draft, ordered, counting or counted). Only the chair may. The issued document stays."
  @spec cancel(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def cancel(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         :ok <- chair?(prefix, header, actor),
         :ok <- cancellable?(header) do
      Repo.transaction(fn ->
        with {:ok, fresh} <- fetch(prefix, header["record_id"], scope),
             :ok <- cancellable?(fresh),
             fv =
               fresh
               |> Map.drop(@kept)
               |> Map.merge(%{
                 "status" => "cancelled",
                 "cancelled_at" => iso(DateTime.utc_now()),
                 "cancelled_by" => actor
               }),
             {:ok, _} <- update_record(prefix, fresh["record_id"], "count_order", fv, actor),
             :ok <-
               audit(prefix, actor, "cancelled", fresh["record_id"], fresh["status"], "cancelled") do
          view!(prefix, fresh["record_id"])
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp chair?(prefix, header, actor) do
    chair = header["chair_employee_id"]

    case Org.employee_for_user(prefix, actor) do
      {:ok, %{"record_id" => ^chair}} -> :ok
      _ -> {:error, :not_chair}
    end
  end

  defp cancellable?(%{"status" => s}) when s in @cancellable, do: :ok
  defp cancellable?(_), do: {:error, :count_state_invalid}

  # --- reads ------------------------------------------------------------------------------------

  @doc "One order view, or `{:error, :not_found}` (unknown, malformed, other tenant, other scope)."
  @spec get(String.t(), term(), map()) :: {:ok, map()} | {:error, :not_found}
  def get(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {_actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope), do: {:ok, view(prefix, header)}
  end

  @doc """
  The orders visible to the caller, newest planned start first (then record id). `params` (string
  keys): `status`, `org_unit_id`, `limit` (1..200, default 50) and `cursor`; any other key is
  `{:field_not_allowed, key}`. Returns `{:ok, %{rows: [view], next_cursor: text | nil}}`.
  """
  @spec list(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def list(prefix, params, opts) when is_binary(prefix) and is_map(opts) do
    {_actor, scope} = opts!(opts)

    with {:ok, params} <- list_params(params) do
      case scope do
        :none -> {:ok, %{rows: [], next_cursor: nil}}
        _ -> {:ok, run_list(prefix, params, scope)}
      end
    end
  end

  defp list_params(params) when is_map(params) do
    with :ok <- no_extra(params, @list_keys),
         {:ok, status} <- opt_enum(params, "status", @statuses),
         {:ok, unit} <- opt_uuid(params, "org_unit_id"),
         {:ok, limit} <- opt_limit(params),
         {:ok, cursor} <- opt_cursor(params) do
      {:ok, %{status: status, unit: unit, limit: limit, cursor: cursor}}
    end
  end

  defp list_params(_), do: {:error, {:field_invalid, "params"}}

  defp no_extra(map, allowed) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, {:field_not_allowed, to_string(key)}}
    end
  end

  defp opt_enum(params, key, allowed) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, nil}

      {:ok, v} when is_binary(v) ->
        if v in allowed, do: {:ok, v}, else: {:error, {:field_invalid, key}}

      _ ->
        {:error, {:field_invalid, key}}
    end
  end

  defp opt_uuid(params, key) do
    case Map.fetch(params, key) do
      :error -> {:ok, nil}
      {:ok, v} -> cast_uuid(v, key)
    end
  end

  defp opt_limit(params) do
    case Map.fetch(params, "limit") do
      :error ->
        {:ok, 50}

      {:ok, v} when is_integer(v) and v in 1..200 ->
        {:ok, v}

      {:ok, v} when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n in 1..200 -> {:ok, n}
          _ -> {:error, {:field_invalid, "limit"}}
        end

      _ ->
        {:error, {:field_invalid, "limit"}}
    end
  end

  defp opt_cursor(params) do
    case Map.fetch(params, "cursor") do
      :error ->
        {:ok, nil}

      {:ok, v} when is_binary(v) ->
        with {:ok, raw} <- Base.url_decode64(v, padding: false),
             [start, rid] <- String.split(raw, "|", parts: 2),
             {:ok, rid} <- Ecto.UUID.cast(rid),
             true <- String.valid?(start) and byte_size(start) <= 40 do
          {:ok, {start, rid}}
        else
          _ -> {:error, {:field_invalid, "cursor"}}
        end

      _ ->
        {:error, {:field_invalid, "cursor"}}
    end
  end

  defp run_list(prefix, p, scope) do
    base =
      from(l in Latest,
        where: l.entity_type == "count_order" and l.deleted == false,
        order_by: [
          desc: fragment("?->>'planned_start'", l.field_values),
          asc: l.record_id
        ],
        limit: ^(p.limit + 1)
      )

    rows =
      base
      |> where_status(p.status)
      |> where_unit(p.unit)
      |> where_scope(scope)
      |> where_cursor(p.cursor)
      |> Repo.all(prefix: prefix)

    {page, rest} = Enum.split(rows, p.limit)

    %{
      rows: Enum.map(page, &view(prefix, to_header(&1))),
      next_cursor: if(rest == [], do: nil, else: cursor_of(List.last(page)))
    }
  end

  defp where_status(q, nil), do: q

  defp where_status(q, status),
    do: from(l in q, where: fragment("?->>'status' = ?", l.field_values, ^status))

  defp where_unit(q, nil), do: q

  defp where_unit(q, unit),
    do: from(l in q, where: fragment("?->>'org_unit_id' = ?", l.field_values, ^unit))

  # Text on both sides: `org_unit_id` is a text field and scope node ids are text strings.
  defp where_scope(q, :all), do: q

  defp where_scope(q, {:nodes, ids}),
    do:
      from(l in q,
        where:
          fragment("?->>'org_unit_id' = ANY(?)", l.field_values, type(^ids, {:array, :string}))
      )

  defp where_cursor(q, nil), do: q

  defp where_cursor(q, {start, rid}) do
    from(l in q,
      where:
        fragment("?->>'planned_start'", l.field_values) < ^start or
          (fragment("?->>'planned_start'", l.field_values) == ^start and l.record_id > ^rid)
    )
  end

  defp cursor_of(%{record_id: rid, field_values: fv}),
    do: Base.url_encode64(fv["planned_start"] <> "|" <> rid, padding: false)

  @doc "The issued document summary of an order (`number_label`, `version_no`, `issued_at`, `content_hash`)."
  @spec document(String.t(), term(), map()) :: {:ok, map()} | {:error, :not_found}
  def document(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {_actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         doc_id when is_binary(doc_id) <- header["document_id"],
         {:ok, summary} <- Documents.issued_summary(prefix, doc_id) do
      {:ok, Map.put(summary, :document_id, doc_id)}
    else
      _ -> {:error, :not_found}
    end
  end

  # --- input ------------------------------------------------------------------------------------

  defp check_keys(input) when is_map(input) do
    case no_extra(input, @input_keys) do
      :ok -> {:ok, input}
      error -> error
    end
  end

  defp check_keys(_), do: {:error, {:field_invalid, "body"}}

  defp uuid_field(input, key) do
    case Map.fetch(input, key) do
      {:ok, v} -> cast_uuid(v, key)
      :error -> {:error, {:field_invalid, key}}
    end
  end

  defp cast_uuid(v, key) when is_binary(v) do
    case Ecto.UUID.cast(v) do
      {:ok, u} -> {:ok, u}
      :error -> {:error, {:field_invalid, key}}
    end
  end

  defp cast_uuid(_, key), do: {:error, {:field_invalid, key}}

  defp in_scope(:all, _unit), do: :ok

  defp in_scope({:nodes, ids}, unit) when is_list(ids),
    do: if(unit in ids, do: :ok, else: {:error, :not_found})

  defp in_scope(_, _), do: {:error, :not_found}

  defp parse(input, unit) do
    with {:ok, kind} <- kind(input),
         {:ok, start} <- time(input, "planned_start"),
         {:ok, stop} <- time(input, "planned_end"),
         {:ok, chair} <- uuid_field(input, "chair_employee_id"),
         {:ok, members} <- uuid_list(input, "member_employee_ids", true),
         {:ok, roots} <- uuid_list(input, "location_ids", false),
         :ok <- chair_not_member(chair, members),
         {:ok, note} <- note(input) do
      {:ok,
       %{
         org_unit_id: unit,
         kind: kind,
         planned_start: start,
         planned_end: stop,
         chair_employee_id: chair,
         member_employee_ids: members,
         location_ids: roots,
         note: note
       }}
    end
  end

  defp kind(input) do
    case Map.get(input, "kind") do
      k when k in @kinds -> {:ok, k}
      _ -> {:error, {:field_invalid, "kind"}}
    end
  end

  defp time(input, key) do
    with v when is_binary(v) <- Map.get(input, key),
         {:ok, at, _offset} <- DateTime.from_iso8601(v) do
      {:ok, at |> DateTime.shift_zone!("Etc/UTC") |> iso()}
    else
      _ -> {:error, {:field_invalid, key}}
    end
  end

  defp uuid_list(input, key, may_be_empty) do
    with {:ok, list} when is_list(list) <- Map.fetch(input, key) |> or_invalid(key),
         true <- length(list) <= @max_list and (may_be_empty or list != []),
         {:ok, ids} <- cast_all(list, key),
         true <- length(Enum.uniq(ids)) == length(ids) do
      {:ok, ids}
    else
      _ -> {:error, {:field_invalid, key}}
    end
  end

  defp or_invalid({:ok, v}, _key), do: {:ok, v}
  defp or_invalid(:error, key), do: {:error, {:field_invalid, key}}

  defp cast_all(list, key) do
    Enum.reduce_while(list, {:ok, []}, fn v, {:ok, acc} ->
      case cast_uuid(v, key) do
        {:ok, u} -> {:cont, {:ok, [u | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp chair_not_member(chair, members),
    do: if(chair in members, do: {:error, {:field_invalid, "member_employee_ids"}}, else: :ok)

  defp note(input) do
    case Map.get(input, "note") do
      nil ->
        {:ok, nil}

      n when is_binary(n) ->
        if String.length(n) <= @max_note and String.valid?(n) and not String.contains?(n, <<0>>),
          do: {:ok, n},
          else: {:error, {:field_invalid, "note"}}

      _ ->
        {:error, {:field_invalid, "note"}}
    end
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # --- master checks (decision 0076 R6: record ids checked in code) -----------------------------

  defp check_people(prefix, doc) do
    with :ok <- unit_active(prefix, doc.org_unit_id),
         :ok <- employees_active(prefix, [doc.chair_employee_id | doc.member_employee_ids]),
         :ok <- chair_user(prefix, doc.chair_employee_id) do
      :ok
    end
  end

  defp unit_active(prefix, unit) do
    case Org.lookup(prefix, unit) do
      {:ok, %{"entity_type" => "org_unit", "active" => true}} -> :ok
      _ -> {:error, :org_unit_inactive}
    end
  end

  defp employees_active(prefix, ids),
    do:
      if(Enum.all?(ids, &Org.active_employee?(prefix, &1)),
        do: :ok,
        else: {:error, :employee_inactive}
      )

  defp chair_user(prefix, chair) do
    case Org.lookup(prefix, chair) do
      {:ok, %{"user_id" => u}} when is_binary(u) and u != "" -> :ok
      _ -> {:error, :chair_without_user}
    end
  end

  # --- issue checks -----------------------------------------------------------------------------

  defp check_linked(prefix, doc) do
    if Enum.all?(doc.location_ids, &Locations.linked?(prefix, doc.org_unit_id, &1)),
      do: :ok,
      else: {:error, :count_scope_not_linked}
  end

  # No root lies inside the subtree of another root of the same order.
  defp check_inside(prefix, doc) do
    inside? =
      Enum.any?(doc.location_ids, fn root ->
        below = Tree.descendant_ids(prefix, root)
        Enum.any?(doc.location_ids, &(&1 != root and &1 in below))
      end)

    if inside?, do: {:error, :count_scope_overlaps}, else: :ok
  end

  defp check_complete(_prefix, %{kind: "selective"}), do: :ok

  defp check_complete(prefix, doc) do
    covered = prefix |> subtree(doc.location_ids)
    all = Locations.location_ids_for_org_unit(prefix, doc.org_unit_id)

    if Enum.all?(all, &MapSet.member?(covered, &1)),
      do: :ok,
      else: {:error, :count_scope_incomplete}
  end

  defp check_duration(doc) do
    with {:ok, a, _} <- DateTime.from_iso8601(doc.planned_start),
         {:ok, b, _} <- DateTime.from_iso8601(doc.planned_end),
         diff = DateTime.diff(b, a),
         true <- diff > 0 and diff <= @max_seconds do
      :ok
    else
      _ -> {:error, :count_too_long}
    end
  end

  # The roots and everything below them. `Tree.descendant_ids/2` lists descendants only.
  defp subtree(prefix, roots) do
    Enum.reduce(roots, MapSet.new(), fn root, acc ->
      acc |> MapSet.put(root) |> MapSet.union(MapSet.new(Tree.descendant_ids(prefix, root)))
    end)
  end

  defp check_overlap(prefix, self_id, doc) do
    mine = subtree(prefix, doc.location_ids)
    my_roots = MapSet.new(doc.location_ids)

    others =
      Repo.all(
        from(l in Latest,
          where:
            l.entity_type == "count_order" and l.deleted == false and l.record_id != ^self_id and
              fragment("?->>'org_unit_id' = ?", l.field_values, ^doc.org_unit_id) and
              fragment(
                "?->>'status' = ANY(?)",
                l.field_values,
                type(^@blocking, {:array, :string})
              )
        ),
        prefix: prefix
      )

    clash? =
      Enum.any?(others, fn other ->
        roots =
          prefix |> child_ids("count_order_scope", other.record_id, "location_id") |> MapSet.new()

        theirs = subtree(prefix, MapSet.to_list(roots))

        not MapSet.disjoint?(my_roots, theirs) or not MapSet.disjoint?(roots, mine)
      end)

    if clash?, do: {:error, :count_scope_overlaps}, else: :ok
  end

  # --- storage ----------------------------------------------------------------------------------

  defp write_new(prefix, doc, actor) do
    fv =
      %{
        "org_unit_id" => doc.org_unit_id,
        "kind" => doc.kind,
        "planned_start" => doc.planned_start,
        "planned_end" => doc.planned_end,
        "chair_employee_id" => doc.chair_employee_id,
        "status" => "draft"
      }
      |> put_note(doc.note)

    with {:ok, id} <- create_record(prefix, "count_order", fv, actor),
         :ok <- write_children(prefix, id, doc, actor) do
      {:ok, id}
    end
  end

  defp rewrite_header(prefix, fresh, doc, actor) do
    fv =
      fresh
      |> Map.drop(@kept ++ ["note"])
      |> Map.merge(%{
        "org_unit_id" => doc.org_unit_id,
        "kind" => doc.kind,
        "planned_start" => doc.planned_start,
        "planned_end" => doc.planned_end,
        "chair_employee_id" => doc.chair_employee_id
      })
      |> put_note(doc.note)

    update_record(prefix, fresh["record_id"], "count_order", fv, actor)
  end

  defp put_note(fv, nil), do: fv
  defp put_note(fv, note), do: Map.put(fv, "note", note)

  defp write_children(prefix, id, doc, actor) do
    rows =
      Enum.map(doc.location_ids, fn loc ->
        {"count_order_scope",
         %{"count_order_id" => id, "location_id" => loc, "org_unit_id" => doc.org_unit_id}}
      end) ++
        Enum.map(doc.member_employee_ids, fn emp ->
          {"count_commission_member",
           %{"count_order_id" => id, "employee_id" => emp, "org_unit_id" => doc.org_unit_id}}
        end)

    Enum.reduce_while(rows, :ok, fn {type, fv}, :ok ->
      case create_record(prefix, type, fv, actor) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp delete_children(prefix, id, actor) do
    ids =
      child_rows(prefix, "count_order_scope", id) ++
        child_rows(prefix, "count_commission_member", id)

    Enum.reduce_while(ids, :ok, fn {type, rid}, :ok ->
      attrs = %{
        entity_type: type,
        record_id: rid,
        actor_id: actor,
        idempotency_key: key()
      }

      # scope-all: SEC-518-R1 (stock module, own-record system path; the caller's scope was checked first)
      case Records.delete_record(attrs, prefix, owner()) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp child_rows(prefix, type, order_id) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == ^type and l.deleted == false and
            fragment("?->>'count_order_id' = ?", l.field_values, ^order_id),
        select: l.record_id
      ),
      prefix: prefix
    )
    |> Enum.map(&{type, &1})
  end

  defp child_ids(prefix, type, order_id, field) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == ^type and l.deleted == false and
            fragment("?->>'count_order_id' = ?", l.field_values, ^order_id),
        select: fragment("?->>?", l.field_values, ^field)
      ),
      prefix: prefix
    )
  end

  defp create_record(prefix, type, fv, actor) do
    attrs = %{entity_type: type, field_values: fv, actor_id: actor, idempotency_key: key()}

    # scope-all: SEC-518-R1 (stock module, own-record system path; the caller's scope was checked first)
    case Records.create_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = error -> error
    end
  end

  defp update_record(prefix, id, type, fv, actor) do
    attrs = %{
      entity_type: type,
      record_id: id,
      field_values: fv,
      actor_id: actor,
      idempotency_key: key()
    }

    # scope-all: SEC-518-R1 (stock module, own-record system path; the caller's scope was checked first)
    case Records.update_record(attrs, prefix, owner()) do
      {:ok, _} -> {:ok, id}
      {:error, _} = error -> error
    end
  end

  defp owner, do: ManagedTypes.owner_for!(Letflow.Modules.Stock)

  # A server key per Records write: the routes take no client key (assumption in the moduledoc).
  defp key, do: "stock.count:" <> Ecto.UUID.generate()

  defp lock!(prefix, unit) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":stock_count:" <> unit
    ])

    :ok
  end

  # INV-8: Audit raises on a database failure; the rescue turns the raise into a refusal.
  defp audit(prefix, actor, action, record_id, before, after_status) do
    entry = %{
      actor_id: actor,
      action: "stock.count_order." <> action,
      resource_type: "count_order",
      resource_id: record_id,
      before_state: before && %{"status" => before},
      after_state: %{"status" => after_status}
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  # --- reads of one order -----------------------------------------------------------------------

  defp fetch(prefix, id, scope) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, header} <- ReadApi.lookup(prefix, uuid, ["count_order"]),
         :ok <- in_scope(scope, header["org_unit_id"]) do
      {:ok, header}
    else
      _ -> {:error, :not_found}
    end
  end

  defp draft?(%{"status" => "draft"}), do: :ok
  defp draft?(_), do: {:error, :count_state_invalid}

  defp doc_of(prefix, header) do
    id = header["record_id"]

    %{
      org_unit_id: header["org_unit_id"],
      kind: header["kind"],
      planned_start: header["planned_start"],
      planned_end: header["planned_end"],
      chair_employee_id: header["chair_employee_id"],
      member_employee_ids:
        prefix |> child_ids("count_commission_member", id, "employee_id") |> Enum.sort(),
      location_ids: prefix |> child_ids("count_order_scope", id, "location_id") |> Enum.sort(),
      note: header["note"]
    }
  end

  defp to_header(%{record_id: rid, field_values: fv}), do: Map.put(fv, "record_id", rid)

  defp view!(prefix, id) do
    {:ok, header} = ReadApi.lookup(prefix, id, ["count_order"])
    view(prefix, header)
  end

  defp view(prefix, header) do
    doc = doc_of(prefix, header)

    %{
      "id" => header["record_id"],
      "org_unit_id" => header["org_unit_id"],
      "kind" => header["kind"],
      "status" => header["status"],
      "planned_start" => header["planned_start"],
      "planned_end" => header["planned_end"],
      "chair_employee_id" => header["chair_employee_id"],
      "member_employee_ids" => doc.member_employee_ids,
      "location_ids" => doc.location_ids,
      "note" => header["note"],
      "document_id" => header["document_id"],
      "number" => header["number"],
      "issued_at" => header["issued_at"],
      "issued_by" => header["issued_by"],
      "cancelled_at" => header["cancelled_at"],
      "cancelled_by" => header["cancelled_by"]
    }
  end

  defp opts!(opts) do
    actor = Map.get(opts, :actor_id)
    scope = Map.get(opts, :scope)

    unless is_binary(actor) and match?({:ok, _}, Ecto.UUID.cast(actor)),
      do: raise(ArgumentError, "opts :actor_id must be a uuid")

    unless scope == :all or scope == :none or match?({:nodes, l} when is_list(l), scope),
      do: raise(ArgumentError, "opts :scope must be :all, :none or {:nodes, ids}")

    {actor, scope}
  end
end
