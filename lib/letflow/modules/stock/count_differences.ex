defmodule Letflow.Modules.Stock.CountDifferences do
  @moduledoc """
  REQ-717 / GH #3764 (assets phase B counts, decision 0079 sections 3, 6 and 9): the signing of the
  count sheet, the differences sheet built from it, and the signing of the differences sheet.
  `Letflow.Modules.Stock.Counts` delegates here, so callers use `Counts.mark_sheet_signed/4`,
  `issue_differences/3`, `mark_differences_signed/4`, `differences/3` and `signatures/3`.

    * `mark_sheet_signed/4`: the chair records that the exact set of required signers signed the
      printout of the issued `count.sheet` (chair, every commission member, every responsible employee
      of a sheet line). One `count_signature` row per signer; the count stays `counted`.
    * `issue_differences/3`: needs the signed sheet. The differences are computed from the CONTENT of
      the issued sheet version (never from live line records): one item per line whose counted quantity
      differs from the book quantity, `difference` = counted - book as a decimal string, `direction` =
      `surplus` or `shortage`. The `count.differences` document is created and issued in the same
      transaction. More than 200 lines (the leg cap of `Letflow.Ledger.Validate`) is refused before any
      document call, so no number is taken. A count with no difference gets an issued document with
      an empty `lines`.
    * `mark_differences_signed/4`: the same for the differences sheet (chair, members, responsible
      employees of the difference lines only); refused 96 hours after the cut-off; the count becomes
      `signed`. A `signed` count can no longer be cancelled (`Counts.cancel/3`).

  This module makes no ledger call: the posting is REQ-718 (`Letflow.Modules.Stock.CountPosting`,
  built without the count freeze, assumption D-086). Its transaction shell and field helpers are
  public (`@doc false`) for that module.

  Assumptions, owner may change at GATE B (D-086/D-087): "signed" is a paper signature on the printout,
  recorded by the chair as an acknowledgement (the system does not verify it); a signer without a user
  link is accepted; an empty differences sheet is allowed; the times are UTC.

  Every write is one transaction whose FIRST statement is the per-order advisory lock
  (`CountSheet.lock_order!/2`, also taken by `Counts.cancel/3`); the state is re-checked after the
  lock. A refusal stores nothing. Each write audits one entry with the order id, the statuses and (for
  the two marks) the signer ids; no quantity. `Audit` raises on a database failure (INV-8): the raise
  becomes `{:error, :audit_failed}` and rolls the transaction back. `opts` is `%{actor_id, scope}`
  (plus `:now` in tests only; the router never copies a request value into it).
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Documents
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Modules.Stock.CountSheet
  alias Letflow.Modules.Stock.Counts
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Repo

  @kept ["record_id", "entity_type"]
  # Same number as `@max_legs` of `lib/letflow/ledger/validate.ex`: REQ-718 posts one document's lines.
  @max_lines 200
  @max_list 500
  @window_seconds 96 * 3600

  # --- sheet signing ----------------------------------------------------------------------------

  @doc "The chair records the signers of the issued `count.sheet`. `signer_ids` must be the exact required set."
  @spec mark_sheet_signed(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def mark_sheet_signed(prefix, id, signer_ids, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)
    now = now(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         :ok <- chair(prefix, header, actor),
         :ok <- counted(header),
         :ok <- sheet_unsigned(header),
         {:ok, ids} <- signer_input(signer_ids) do
      run(prefix, header, scope, opts, fn fresh ->
        with :ok <- counted(fresh),
             :ok <- sheet_unsigned(fresh),
             {:ok, sheet} <- issued_sheet(prefix, fresh),
             required = required_signers(prefix, fresh, sheet_lines(sheet)),
             :ok <- exact_set(ids, required),
             :ok <-
               append_rows(
                 prefix,
                 fresh,
                 "sheet",
                 fresh["sheet_document_id"],
                 sheet.version_no,
                 required,
                 actor,
                 now
               ),
             fv = Map.merge(base(fresh), %{"sheet_signed_at" => DateTime.to_iso8601(now)}),
             {:ok, _} <- update_record(prefix, fresh["record_id"], fv, actor),
             :ok <- audit(prefix, actor, "sheet_signed", fresh, "counted", "counted", ids) do
          :ok
        end
      end)
    end
  end

  # --- differences ------------------------------------------------------------------------------

  @doc "Builds and issues the `count.differences` document from the issued, signed sheet."
  @spec issue_differences(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def issue_differences(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         :ok <- chair(prefix, header, actor),
         :ok <- counted(header),
         :ok <- sheet_signed(header),
         :ok <- differences_not_issued(header) do
      run(prefix, header, scope, opts, fn fresh ->
        with :ok <- counted(fresh),
             :ok <- sheet_signed(fresh),
             :ok <- differences_not_issued(fresh),
             {:ok, sheet} <- issued_sheet(prefix, fresh),
             {:ok, lines} <- difference_lines(sheet_lines(sheet)),
             :ok <- cap(lines),
             {:ok, issued} <- issue_document(prefix, fresh, sheet, lines, actor),
             fv =
               Map.merge(base(fresh), %{
                 "differences_document_id" => issued.document_id,
                 "differences_number" => issued.number,
                 "differences_issued_at" => issued.issued_at
               }),
             {:ok, _} <- update_record(prefix, fresh["record_id"], fv, actor),
             :ok <- audit(prefix, actor, "differences_issued", fresh, "counted", "counted", nil) do
          :ok
        end
      end)
    end
  end

  @doc "The chair records the signers of the issued `count.differences`; the count becomes `signed`."
  @spec mark_differences_signed(String.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_differences_signed(prefix, id, signer_ids, opts)
      when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)
    now = now(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         :ok <- chair(prefix, header, actor),
         :ok <- counted(header),
         :ok <- differences_issued(header),
         {:ok, ids} <- signer_input(signer_ids),
         :ok <- window(header, now) do
      run(prefix, header, scope, opts, fn fresh ->
        with :ok <- counted(fresh),
             :ok <- differences_issued(fresh),
             :ok <- window(fresh, now),
             {:ok, diff} <- issued_differences(prefix, fresh),
             required = required_signers(prefix, fresh, content_lines(diff.content)),
             :ok <- exact_set(ids, required),
             :ok <-
               append_rows(
                 prefix,
                 fresh,
                 "differences",
                 fresh["differences_document_id"],
                 diff.version_no,
                 required,
                 actor,
                 now
               ),
             fv =
               Map.merge(base(fresh), %{
                 "status" => "signed",
                 "differences_signed_at" => DateTime.to_iso8601(now)
               }),
             {:ok, _} <- update_record(prefix, fresh["record_id"], fv, actor),
             :ok <- audit(prefix, actor, "differences_signed", fresh, "counted", "signed", ids) do
          :ok
        end
      end)
    end
  end

  # --- reads ------------------------------------------------------------------------------------

  @doc "The issued differences sheet: number, version, time, hash and the difference lines."
  @spec differences(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def differences(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {_actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         :ok <- differences_issued(header),
         doc_id = header["differences_document_id"],
         {:ok, summary} <- Documents.issued_summary(prefix, doc_id),
         {:ok, %{content: content}} <- issued(prefix, doc_id) do
      {:ok,
       %{
         "number" => header["differences_number"] || summary.number_label,
         "version_no" => summary.version_no,
         "issued_at" => iso(summary.issued_at),
         "content_hash" => summary.content_hash,
         "lines" => content_lines(content)
       }}
    end
  end

  @doc "The signature rows of the count, ordered by `marked_at` then employee."
  @spec signatures(String.t(), term(), map()) :: {:ok, map()} | {:error, :not_found}
  def signatures(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {_actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope) do
      rows =
        signature_rows(prefix, header["record_id"])
        |> Enum.sort_by(&{&1["marked_at"], &1["employee_id"], &1["document_kind"]})
        |> Enum.map(
          &Map.take(
            &1,
            ~w(document_kind document_id version_no employee_id signer_role marked_by marked_at)
          )
        )

      {:ok, %{"rows" => rows}}
    end
  end

  # --- transaction shell ------------------------------------------------------------------------

  @doc false
  def run(prefix, header, scope, opts, fun) do
    Repo.transaction(fn ->
      CountSheet.lock_order!(prefix, header["record_id"])

      with {:ok, fresh} <- fetch(prefix, header["record_id"], scope),
           :ok <- fun.(fresh) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, _} -> Counts.get(prefix, header["record_id"], opts)
      {:error, _} = error -> error
    end
  end

  # --- the issued documents ---------------------------------------------------------------------

  # INV-8: a counted count without an issued sheet answers count_state_invalid, no crash.
  defp issued_sheet(prefix, header) do
    case header["sheet_document_id"] do
      id when is_binary(id) and id != "" -> issued(prefix, id)
      _ -> {:error, :count_state_invalid}
    end
  end

  defp issued_differences(prefix, header) do
    case header["differences_document_id"] do
      id when is_binary(id) and id != "" -> issued(prefix, id)
      _ -> {:error, :count_state_invalid}
    end
  end

  defp issued(prefix, doc_id) do
    case Posting.issued(prefix, doc_id) do
      %{content: %{} = content, version_no: version_no} ->
        {:ok, %{content: content, version_no: version_no}}

      _ ->
        {:error, :count_state_invalid}
    end
  end

  defp sheet_lines(%{content: content}), do: content_lines(content)

  @doc false
  def content_lines(%{"lines" => lines}) when is_list(lines), do: Enum.filter(lines, &is_map/1)
  def content_lines(_), do: []

  defp difference_lines(lines) do
    lines
    |> Enum.sort_by(&(&1["line_no"] || 0))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      with {:ok, book} <- decimal(line["book_quantity"]),
           {:ok, counted} <- decimal(line["counted_quantity"]) do
        diff = Decimal.sub(counted, book)

        case Decimal.compare(diff, 0) do
          :eq -> {:cont, {:ok, acc}}
          :gt -> {:cont, {:ok, [difference_line(line, diff, "surplus") | acc]}}
          :lt -> {:cont, {:ok, [difference_line(line, diff, "shortage") | acc]}}
        end
      else
        _ -> {:halt, {:error, :count_state_invalid}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # A malformed or missing quantity is a refusal, never a crash (INV-8).
  defp decimal(text) when is_binary(text) do
    case Decimal.parse(text) do
      {%Decimal{coef: coef} = d, ""} when is_integer(coef) -> {:ok, d}
      _ -> :error
    end
  end

  defp decimal(_), do: :error

  defp difference_line(line, diff, direction) do
    base =
      Map.take(
        line,
        ~w(line_no kind location_id catalog_item_id unit_ref book_quantity counted_quantity)
      )

    base
    |> Map.put("difference", Decimal.to_string(diff, :normal))
    |> Map.put("direction", direction)
    |> put_present("catalog_lot_id", line["catalog_lot_id"])
    |> put_present("responsible_employee_id", line["responsible_employee_id"])
  end

  defp cap(lines) when length(lines) > @max_lines, do: {:error, :differences_too_many}
  defp cap(_), do: :ok

  defp issue_document(prefix, order, sheet, lines, actor) do
    content = %{
      "count_order_id" => order["record_id"],
      "org_unit_id" => order["org_unit_id"],
      "cut_off_at" => order["cut_off_at"],
      "cutoff_seq" => order["cutoff_seq"],
      "sheet_document_id" => order["sheet_document_id"],
      "sheet_version_no" => sheet.version_no,
      "lines" => lines
    }

    with {:ok, %{document: document}} <-
           Documents.create_draft(
             prefix,
             %{
               type_key: "count.differences",
               issuing_org_unit_id: order["org_unit_id"],
               content: content
             },
             actor
           ),
         {:ok, _} <- Documents.issue(prefix, %{document_id: document.id, actor_id: actor}),
         {:ok, summary} <- Documents.issued_summary(prefix, document.id) do
      {:ok,
       %{
         document_id: document.id,
         number: summary.number_label,
         issued_at: iso(summary.issued_at)
       }}
    else
      {:error, reason} -> {:error, {:document, reason}}
    end
  end

  # --- signers ----------------------------------------------------------------------------------

  # Returns the required set as `[{employee_id, role}]` in a fixed order: chair, members, responsibles.
  defp required_signers(prefix, header, lines) do
    chair = header["chair_employee_id"]

    members =
      prefix
      |> child_values("count_commission_member", header["record_id"], "employee_id")
      |> Enum.reject(&(is_nil(&1) or &1 == chair))
      |> Enum.uniq()
      |> Enum.sort()

    responsibles =
      lines
      |> Enum.map(& &1["responsible_employee_id"])
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == "" or &1 == chair or &1 in members))
      |> Enum.uniq()
      |> Enum.sort()

    [{chair, "chair"}] ++
      Enum.map(members, &{&1, "member"}) ++ Enum.map(responsibles, &{&1, "responsible"})
  end

  defp signer_input(ids) when is_list(ids) and length(ids) <= @max_list do
    cast = Enum.map(ids, &cast_uuid/1)

    cond do
      Enum.any?(cast, &(&1 == :error)) -> invalid()
      length(Enum.uniq(cast)) != length(cast) -> invalid()
      true -> {:ok, cast}
    end
  end

  defp signer_input(_), do: invalid()

  defp cast_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> :error
    end
  end

  defp cast_uuid(_), do: :error

  defp invalid, do: {:error, {:field_invalid, "signer_employee_ids"}}

  defp exact_set(ids, required) do
    wanted = Enum.map(required, &elem(&1, 0))

    cond do
      Enum.any?(ids, &(&1 not in wanted)) -> invalid()
      Enum.any?(wanted, &(&1 not in ids)) -> {:error, :signers_incomplete}
      true -> :ok
    end
  end

  defp append_rows(prefix, order, kind, document_id, version_no, required, actor, now) do
    Enum.reduce_while(required, :ok, fn {employee, role}, :ok ->
      fv = %{
        "count_order_id" => order["record_id"],
        "document_kind" => kind,
        "document_id" => document_id,
        "version_no" => version_no,
        "employee_id" => employee,
        "signer_role" => role,
        "org_unit_id" => order["org_unit_id"],
        "marked_by" => actor,
        "marked_at" => DateTime.to_iso8601(now)
      }

      case create_record(prefix, "count_signature", fv, actor) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp signature_rows(prefix, order_id) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == "count_signature" and l.deleted == false and
            fragment("?->>'count_order_id' = ?", l.field_values, ^order_id),
        select: l.field_values
      ),
      prefix: prefix
    )
  end

  defp child_values(prefix, type, order_id, field) do
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

  # --- state checks -----------------------------------------------------------------------------

  defp counted(%{"status" => "counted"}), do: :ok
  defp counted(_), do: {:error, :count_state_invalid}

  defp sheet_unsigned(header),
    do: if(blank?(header["sheet_signed_at"]), do: :ok, else: {:error, :sheet_already_signed})

  defp sheet_signed(header),
    do: if(blank?(header["sheet_signed_at"]), do: {:error, :sheet_not_signed}, else: :ok)

  defp differences_not_issued(header),
    do:
      if(blank?(header["differences_document_id"]),
        do: :ok,
        else: {:error, :differences_already_issued}
      )

  defp differences_issued(header),
    do:
      if(blank?(header["differences_document_id"]),
        do: {:error, :differences_not_issued},
        else: :ok
      )

  defp window(header, now) do
    case DateTime.from_iso8601(to_string(header["cut_off_at"])) do
      {:ok, cut_off, _} ->
        if DateTime.diff(now, cut_off) > @window_seconds,
          do: {:error, :count_window_expired},
          else: :ok

      _ ->
        {:error, :count_state_invalid}
    end
  end

  defp blank?(value), do: value in [nil, ""]

  # --- shared -----------------------------------------------------------------------------------

  defp now(opts) do
    case Map.get(opts, :now) do
      %DateTime{} = now -> DateTime.truncate(now, :microsecond)
      _ -> DateTime.truncate(DateTime.utc_now(), :microsecond)
    end
  end

  @doc false
  def iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def iso(other), do: other

  # Whole-document replace: every loaded field is sent back.
  @doc false
  def base(fresh), do: Map.drop(fresh, @kept)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc false
  def fetch(prefix, id, scope) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, header} <- ReadApi.lookup(prefix, uuid, ["count_order"]),
         :ok <- in_scope(scope, header["org_unit_id"]) do
      {:ok, header}
    else
      _ -> {:error, :not_found}
    end
  end

  defp in_scope(:all, _unit), do: :ok

  defp in_scope({:nodes, ids}, unit) when is_list(ids),
    do: if(unit in ids, do: :ok, else: {:error, :not_found})

  defp in_scope(_, _), do: {:error, :not_found}

  @doc false
  def chair(prefix, header, actor) do
    chair = header["chair_employee_id"]

    case Org.employee_for_user(prefix, actor) do
      {:ok, %{"record_id" => ^chair}} -> :ok
      _ -> {:error, :not_chair}
    end
  end

  defp create_record(prefix, type, fv, actor) do
    attrs = %{entity_type: type, field_values: fv, actor_id: actor, idempotency_key: key()}

    # scope-all: SEC-518-R1 (stock module, own-record system path; the caller's scope was checked first)
    case Records.create_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = error -> error
    end
  end

  @doc false
  def update_record(prefix, id, fv, actor) do
    attrs = %{
      entity_type: "count_order",
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

  defp key, do: "stock.count_differences:" <> Ecto.UUID.generate()

  # INV-8: Audit raises on a database failure; the rescue turns the raise into a refusal.
  @doc false
  def audit(prefix, actor, action, order, before, after_status, signer_ids) do
    after_state = %{"status" => after_status}

    after_state =
      if signer_ids,
        do: Map.put(after_state, "signer_employee_ids", signer_ids),
        else: after_state

    entry = %{
      actor_id: actor,
      action: "stock.count." <> action,
      resource_type: "count_order",
      resource_id: order["record_id"],
      before_state: %{"status" => before},
      after_state: after_state
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  @doc false
  def opts!(opts) do
    actor = Map.get(opts, :actor_id)
    scope = Map.get(opts, :scope)

    unless is_binary(actor) and match?({:ok, _}, Ecto.UUID.cast(actor)),
      do: raise(ArgumentError, "opts :actor_id must be a uuid")

    unless scope == :all or scope == :none or match?({:nodes, l} when is_list(l), scope),
      do: raise(ArgumentError, "opts :scope must be :all, :none or {:nodes, ids}")

    {actor, scope}
  end
end
