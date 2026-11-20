defmodule Letflow.Modules.Maintenance.Requests do
  @moduledoc """
  REQ-894 / GH #4806 (CMMS slice 1 part 2, `docs/cmms/scope-draft.md`): the work requests of module
  `maintenance`: `create/3`, `list/3`, `get/2` and `reject/4`. The record type answers 403
  `entity_type_managed` on the generic routes, so this module is its only writer; it writes through
  `Letflow.Entities.Records` with the module authority, in the shape of `Letflow.Modules.Assets.Cards`.

  ## Create

  Rules, in this order, nothing written on a refusal: the body keys (`asset_card_id`, `description`,
  `urgency`; another key is `{:field_not_allowed, key}`); the card is an `assets_card` found through
  `Letflow.Modules.ReadApi.lookup/3` (`:asset_card_not_found` for an unknown, malformed or other
  tenant's id) and active (`:asset_card_inactive`); `description` trimmed is not blank
  (`:description_required`) and at most 2000 characters (`:description_too_long`, the byte size is
  bounded first); `urgency` is `low`, `normal` or `urgent` (`:invalid_urgency`). A card without an org
  unit is `:asset_card_no_org_unit` (the request's scope column and the document's issuing unit are
  the card's unit; a card written through the card routes has none until the register gives it one).
  One transaction then writes the record (status `new`, `reported_by` the caller, `org_unit_id` copied
  from the card), the `maintenance_request` document (`Letflow.Documents.create_draft/3`, then
  `issue/2`, as `Letflow.Modules.Stock.CountDifferences` does) and sets `document_id` on the record;
  the number (`WR-<year>-<6 digits>`) is the document's label.

  ## Idempotency

  The record is created first with the fixed `document_id` placeholder `"pending"`, so the create
  event is a pure function of the request and `Records` answers a replay with the original and the
  same key with another body as `:idempotency_key_reuse`. A claimed key skips the checks and the
  document (a replay writes nothing), as the asset card writers do.

  ## Reject

  Only a `new` request; another status is `:request_not_new`. `reason` (trimmed) is 1 to 500
  characters (`:reason_required`). The check is repeated under a per-request advisory lock, so two
  rejects serialize and the second is refused.

  The tenant is `prefix`, derived from the token on the server, never from attrs or opts. `opts`:
  `:actor_id` (uuid) and, for `create/3`, `:idempotency_key` (text). Each accepted write appends one
  audit entry (`maintenance_work_request.created`, `.rejected`) in its transaction; a database
  failure of the entry rolls the write back as `{:error, :audit_failed}`.

  Reads return the request view only: of the card only `inventory_number` and `name` (never its
  cost, depreciation or other fields; the card is read through a link, not copied).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Attachments.Link
  alias Letflow.Audit
  alias Letflow.Documents
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @type_name "maintenance_work_request"
  @allowed ~w(asset_card_id description urgency)
  @urgencies ~w(low normal urgent)
  @statuses ~w(new ordered rejected)
  @max_description 2000
  @max_reason 500
  @default_limit 50
  @max_limit 200
  @pending "pending"

  @doc "The urgencies a request may carry."
  @spec urgencies() :: [String.t()]
  def urgencies, do: @urgencies

  # --- create -----------------------------------------------------------------------------------

  @doc "Creates a request (and its issued WR document) and returns its view."
  @spec create(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create(prefix, attrs, opts) when is_binary(prefix) and is_map(attrs) and is_map(opts) do
    actor = Map.fetch!(opts, :actor_id)
    key = Map.fetch!(opts, :idempotency_key)

    with :ok <- check_keys(attrs),
         {:ok, card} <- find_card(prefix, attrs["asset_card_id"]),
         replay? = replay?(prefix, key),
         :ok <- if(replay?, do: :ok, else: check_active(card)),
         {:ok, description} <- check_description(attrs["description"]),
         {:ok, urgency} <- check_urgency(attrs["urgency"]),
         {:ok, unit} <- check_unit(card) do
      fv = %{
        "asset_card_id" => card["record_id"],
        "org_unit_id" => unit,
        "description" => description,
        "urgency" => urgency,
        "status" => "new",
        "reported_by" => actor,
        "document_id" => @pending
      }

      if replay?,
        do: replay(prefix, fv, actor, key),
        else: write(prefix, fv, actor, key)
    end
  end

  defp replay(prefix, fv, actor, key) do
    with {:ok, record_id} <- create_doc(prefix, fv, actor, key),
         {:ok, row} <- fetch(prefix, record_id) do
      {:ok, view(prefix, row)}
    end
  end

  defp write(prefix, fv, actor, key) do
    Repo.transaction(fn ->
      with {:ok, record_id} <- create_doc(prefix, fv, actor, key),
           {:ok, issued} <- issue_document(prefix, record_id, fv, actor),
           {:ok, _} <-
             update_doc(prefix, record_id, Map.put(fv, "document_id", issued.document_id), actor),
           {:ok, row} <- fetch(prefix, record_id),
           :ok <-
             audit(prefix, actor, "maintenance_work_request.created", record_id, nil, row) do
        view(prefix, row)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp issue_document(prefix, record_id, fv, actor) do
    content = %{
      "request_id" => record_id,
      "asset_card_id" => fv["asset_card_id"],
      "description" => fv["description"],
      "urgency" => fv["urgency"],
      "reported_by" => actor
    }

    with {:ok, %{document: document}} <-
           Documents.create_draft(
             prefix,
             %{
               type_key: "maintenance_request",
               issuing_org_unit_id: fv["org_unit_id"],
               content: content
             },
             actor
           ),
         {:ok, _} <- Documents.issue(prefix, %{document_id: document.id, actor_id: actor}) do
      {:ok, %{document_id: document.id}}
    else
      {:error, reason} -> {:error, {:document, reason}}
    end
  end

  defp check_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @allowed)) do
      nil -> :ok
      key -> {:error, {:field_not_allowed, to_string(key)}}
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

  # The byte size is bounded before any per-character work (a character is at most 4 bytes).
  defp check_description(text) when is_binary(text) do
    cond do
      byte_size(text) > @max_description * 4 + 64 -> {:error, :description_too_long}
      not String.valid?(text) -> {:error, :description_required}
      String.trim(text) == "" -> {:error, :description_required}
      String.length(String.trim(text)) > @max_description -> {:error, :description_too_long}
      true -> {:ok, String.trim(text)}
    end
  end

  defp check_description(_other), do: {:error, :description_required}

  defp check_urgency(urgency) when urgency in @urgencies, do: {:ok, urgency}
  defp check_urgency(_other), do: {:error, :invalid_urgency}

  # --- reads ------------------------------------------------------------------------------------

  @doc """
  The requests newest first. `params` (string keys): `status`, `limit` (1..#{@max_limit}, default
  #{@default_limit}) and `cursor` (opaque); any other key or value is `{:error, :invalid_filter}`.
  """
  @spec list(String.t(), map()) ::
          {:ok, %{rows: [map()], next_cursor: String.t() | nil}} | {:error, :invalid_filter}
  def list(prefix, params) when is_binary(prefix) and is_map(params) do
    with {:ok, filter} <- list_params(params) do
      rows =
        from(l in Latest,
          where: l.entity_type == @type_name and l.deleted == false,
          order_by: [desc: l.inserted_at, desc: l.record_id],
          limit: ^(filter.limit + 1)
        )
        |> where_status(filter.status)
        |> where_cursor(filter.cursor)
        |> Repo.all(prefix: prefix)

      {page, rest} = Enum.split(rows, filter.limit)

      {:ok,
       %{
         rows: Enum.map(page, &view(prefix, &1)),
         next_cursor: if(rest == [], do: nil, else: cursor_of(List.last(page)))
       }}
    end
  end

  @doc "One request view; an unknown, malformed or other tenant's id is `{:error, :not_found}`."
  @spec get(String.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def get(prefix, id) when is_binary(prefix) do
    with {:ok, row} <- fetch(prefix, id), do: {:ok, view(prefix, row)}
  end

  @doc """
  REQ-895: the attachment owner of a request and whether it is still `new`. An unknown, malformed
  or other tenant's id is `{:error, :not_found}`, as `get/2`.
  """
  @spec photo_owner(String.t(), term()) ::
          {:ok, %{owner: %{kind: String.t(), id: String.t()}, new?: boolean()}}
          | {:error, :not_found}
  def photo_owner(prefix, id) when is_binary(prefix) do
    with {:ok, row} <- fetch(prefix, id) do
      {:ok,
       %{
         owner: %{kind: @type_name, id: row.record_id},
         new?: row.field_values["status"] == "new"
       }}
    end
  end

  defp list_params(params) do
    with :ok <- only_keys(params, ~w(status limit cursor)),
         {:ok, status} <- status_param(params),
         {:ok, limit} <- limit_param(params),
         {:ok, cursor} <- cursor_param(params) do
      {:ok, %{status: status, limit: limit, cursor: cursor}}
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

  defp where_status(q, nil), do: q

  defp where_status(q, status),
    do: from(l in q, where: fragment("?->>'status' = ?", l.field_values, ^status))

  defp where_cursor(q, nil), do: q

  defp where_cursor(q, {at, rid}) do
    from(l in q,
      where: l.inserted_at < ^at or (l.inserted_at == ^at and l.record_id < ^rid)
    )
  end

  defp cursor_of(%Latest{inserted_at: at, record_id: rid}),
    do: Base.url_encode64(DateTime.to_iso8601(at) <> "|" <> rid, padding: false)

  # --- reject -----------------------------------------------------------------------------------

  @doc "Rejects a `new` request with a reason and returns its view."
  @spec reject(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def reject(prefix, id, reason, opts) when is_binary(prefix) and is_map(opts) do
    actor = Map.fetch!(opts, :actor_id)

    with {:ok, row} <- fetch(prefix, id),
         {:ok, text} <- check_reason(reason) do
      Repo.transaction(fn ->
        with :ok <- lock!(prefix, row.record_id),
             {:ok, fresh} <- fetch(prefix, row.record_id),
             :ok <- check_new(fresh),
             fv =
               Map.merge(fresh.field_values, %{"status" => "rejected", "reject_reason" => text}),
             {:ok, _} <- update_doc(prefix, fresh.record_id, fv, actor),
             {:ok, after_row} <- fetch(prefix, fresh.record_id),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "maintenance_work_request.rejected",
                 fresh.record_id,
                 fresh,
                 after_row
               ) do
          view(prefix, after_row)
        else
          {:error, error} -> Repo.rollback(error)
        end
      end)
    end
  end

  defp check_new(%Latest{field_values: %{"status" => "new"}}), do: :ok
  defp check_new(_row), do: {:error, :request_not_new}

  defp check_reason(text) when is_binary(text) do
    cond do
      byte_size(text) > @max_reason * 4 + 64 -> {:error, :reason_required}
      not String.valid?(text) -> {:error, :reason_required}
      String.trim(text) == "" -> {:error, :reason_required}
      String.length(String.trim(text)) > @max_reason -> {:error, :reason_required}
      true -> {:ok, String.trim(text)}
    end
  end

  defp check_reason(_other), do: {:error, :reason_required}

  defp lock!(prefix, record_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":" <> @type_name <> ":" <> record_id
    ])

    :ok
  end

  # --- storage ----------------------------------------------------------------------------------

  defp fetch(prefix, id) do
    with {:ok, record_id} <- Ecto.UUID.cast(id),
         %Latest{} = row <-
           Repo.one(
             from(l in Latest,
               where: l.entity_type == @type_name and l.record_id == ^record_id and not l.deleted
             ),
             prefix: prefix
           ) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  # Records detects a replay by failing its own multi, which a surrounding transaction cannot
  # survive: a claimed key goes to Records alone (see the moduledoc).
  defp replay?(prefix, key),
    do:
      Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^key), prefix: prefix)

  defp create_doc(prefix, fv, actor, key) do
    attrs = %{
      entity_type: @type_name,
      field_values: fv,
      actor_id: actor,
      idempotency_key: key
    }

    # scope-all: SEC-518-R1 (maintenance module, own-record system path; the caller is checked tenant-wide by Maintenance.Access)
    case Records.create_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = error -> error
    end
  end

  defp update_doc(prefix, record_id, fv, actor) do
    attrs = %{
      entity_type: @type_name,
      record_id: record_id,
      field_values: fv,
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (maintenance module, own-record system path; the caller is checked tenant-wide by Maintenance.Access)
    case Records.update_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = error -> error
    end
  end

  defp owner, do: ManagedTypes.owner_for!(Letflow.Modules.Maintenance)

  defp audit(prefix, actor, action, record_id, before_row, after_row) do
    entry = %{
      actor_id: actor,
      action: action,
      resource_type: @type_name,
      resource_id: record_id,
      before_state: before_row && audited(before_row),
      after_state: audited(after_row)
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  # Status and ids only: no description text in the audit entry.
  defp audited(%Latest{field_values: fv}),
    do: Map.take(fv, ["status", "asset_card_id", "urgency", "document_id"])

  # --- view -------------------------------------------------------------------------------------

  defp view(prefix, %Latest{field_values: fv} = row) do
    %{
      "id" => row.record_id,
      "number" => number(prefix, fv["document_id"]),
      "status" => fv["status"],
      "asset" => asset(prefix, fv["asset_card_id"]),
      "description" => fv["description"],
      "urgency" => fv["urgency"],
      "reported_by" => fv["reported_by"],
      "reject_reason" => fv["reject_reason"],
      "order" => order_ref(prefix, fv["order_id"]),
      "photo_count" => photo_count(prefix, row.record_id),
      "created_at" => DateTime.to_iso8601(row.inserted_at)
    }
  end

  # REQ-896: the order made from the request, once ordered.
  defp order_ref(_prefix, nil), do: nil

  defp order_ref(prefix, id) do
    with {:ok, order_id} <- Ecto.UUID.cast(id),
         %Latest{} = row <-
           Repo.one(
             from(l in Latest,
               where:
                 l.entity_type == "maintenance_work_order" and l.record_id == ^order_id and
                   not l.deleted
             ),
             prefix: prefix
           ) do
      %{"id" => row.record_id, "number" => number(prefix, row.field_values["document_id"])}
    else
      _ -> nil
    end
  end

  defp photo_count(prefix, record_id) do
    Repo.aggregate(
      from(l in Link,
        where: l.owner_kind == @type_name and l.owner_id == ^record_id and l.purpose == "photo"
      ),
      :count,
      prefix: prefix
    )
  end

  defp number(prefix, document_id) do
    case Documents.issued_summary(prefix, document_id) do
      {:ok, %{number_label: label}} -> label
      _ -> nil
    end
  end

  # Only the two fields of the card the view may show.
  defp asset(prefix, card_id) do
    case ReadApi.lookup(prefix, card_id, ["assets_card"]) do
      {:ok, card} ->
        %{
          "id" => card["record_id"],
          "inventory_number" => card["inventory_number"],
          "name" => card["name"]
        }

      {:error, :not_found} ->
        %{"id" => card_id, "inventory_number" => nil, "name" => nil}
    end
  end
end
