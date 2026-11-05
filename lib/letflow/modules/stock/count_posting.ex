defmodule Letflow.Modules.Stock.CountPosting do
  @moduledoc """
  REQ-718 / GH #3763 (assets phase B counts, decision 0079 sections 1, 2 and 8, split plan row C6): the
  posting of a signed count to the stock ledger, the posting record, the posting check on read and the
  reversal of the whole count. The same machinery as the stock documents
  (`Letflow.Modules.Stock.Documents.Posting`, `Letflow.Modules.Stock.Handlers`), applied to the
  `count.differences` document. `Letflow.Modules.Stock.Counts` merges `state_fields/3` into the count view.

    * `post/3`: starts ONE instance of the module definition `stock_count_posting` (one HUMAN_TASK `post`).
      Completing the task runs the write handler `post_count`: one ledger entry (cause `count_difference`,
      sign rule `any`, one leg per difference line) and one `stock_posting_mark` commit together or not at
      all. The command is built ONLY from the issued differences version (never from live records).
    * `reverse/3`: starts one `stock_reversal` instance; completing it reverses the whole entry.
    * `issue_posting_record/3`: the chair issues the `count.posting` document (entry id, posting sequence
      and time) and the count becomes `posted`. Handlers create records only, so the stored status stays
      `signed` until this step; the read shows the posting state from the marks before that.
    * `posting_document/3`: the issued `count.posting` summary.

  Assumption, owner may change at GATE B (D-086): the count FREEZE (decision 0079 section 4, split plan
  row C7) is not built. Postings inside the count scope between the cut-off and the posting are not
  blocked, so a difference is posted as a DELTA (counted minus book at the cut-off, the `difference` of the
  issued line). Known gaps: (a) no freeze; (b) a shortage can exceed the CURRENT balance if goods left
  after the cut-off: the ledger refuses `insufficient_stock` at completion and the count stays `signed`;
  (c) a count posted after later movements reports the delta, not "counted = balance".

  The binding of the posting to the issued content is by workflow order and detection on read
  (`posting_check`, decision 0078 D5), not enforced, until slice L7. The tenant is the `prefix` argument
  only (INV-1); an unknown, other-tenant or out-of-scope count is `{:error, :not_found}` (INV-5). `opts`
  is `%{actor_id, scope}` plus `:activator` and `:authorized` (the ledger read authorization or `nil`).
  """

  alias Letflow.Documents
  alias Letflow.Modules.Stock.CountDifferences
  alias Letflow.Modules.Stock.Counts
  alias Letflow.Modules.Stock.Documents.Posting

  @definition "stock_count_posting"
  @reversal_definition "stock_reversal"
  @type_key "count.differences"
  @cause "count_difference"
  @device_id "stock-count"

  # --- post ---------------------------------------------------------------------------------------

  @doc "Starts the posting instance of a signed count. See the moduledoc."
  @spec post(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def post(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = CountDifferences.opts!(opts)

    with {:ok, header} <- CountDifferences.fetch(prefix, id, scope),
         diff_id = diff_id(header),
         marks = marks(prefix, diff_id),
         :ok <- not_posted(marks),
         :ok <- signed(header),
         :ok <- no_pending_post(prefix, diff_id),
         {:ok, issued} <- issued(prefix, diff_id),
         lines = CountDifferences.content_lines(issued.content),
         :ok <- some_lines(lines),
         :ok <- active(prefix, @definition, Map.get(opts, :activator)),
         {:ok, command} <- command(header, issued, lines),
         {:ok, _instance} <- start_post(prefix, header, issued, diff_id, command, actor) do
      Counts.get(prefix, header["record_id"], opts)
    end
  end

  defp not_posted(marks) do
    if Map.has_key?(marks, "posted"), do: {:error, :count_posted}, else: :ok
  end

  defp signed(%{"status" => "signed", "differences_signed_at" => at})
       when is_binary(at) and at != "",
       do: :ok

  defp signed(_header), do: {:error, :count_state_invalid}

  defp no_pending_post(_prefix, nil), do: :ok

  defp no_pending_post(prefix, diff_id) do
    if Posting.pending(prefix, diff_id).post, do: {:error, :posting_pending}, else: :ok
  end

  defp some_lines([]), do: {:error, :no_differences}
  defp some_lines(_lines), do: :ok

  defp active(prefix, name, activator) do
    case Posting.ensure_active(prefix, name, activator) do
      :ok -> :ok
      :error -> {:error, :definition_not_active}
    end
  end

  defp start_post(prefix, header, issued, diff_id, command, actor) do
    vars = %{
      "document_id" => diff_id,
      "document_type" => @type_key,
      "version_no" => issued.version_no,
      "org_unit_id" => header["org_unit_id"],
      "mark" => "posted",
      "posting" => command
    }

    start(prefix, @definition, "stock-count-post", issued, diff_id, vars, actor)
  end

  defp start(prefix, name, key_prefix, issued, diff_id, vars, actor) do
    case Posting.start(prefix, name, key_prefix, issued.version_id, diff_id, vars, actor) do
      {:ok, instance_id} -> {:ok, instance_id}
      {:error, :definition_not_active} -> {:error, :definition_not_active}
      {:error, _other} -> {:error, :internal}
    end
  end

  # The command, from the issued differences content only. A surplus is a `to` side, a shortage a
  # `from` side; the quantity is the absolute difference, so it is always positive.
  defp command(header, issued, lines) do
    with {:ok, seq} <- Posting.client_seq(issued.period, issued.number),
         {:ok, built} <- build_lines(lines, issued, header["org_unit_id"]) do
      {:ok,
       %{
         "cause" => @cause,
         "document_type" => @type_key,
         "document_id" => header["differences_document_id"],
         "related_document_id" => header["document_id"],
         "correlation_id" => header["record_id"],
         "client_op_id" => issued.version_id,
         "reason_code" => "count",
         "device_id" => @device_id,
         "client_seq" => seq,
         "client_event_time" => header["differences_signed_at"],
         "lines" => built
       }}
    else
      {:error, :number_out_of_range} -> {:error, :count_state_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp build_lines(lines, issued, org_unit) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case leg_line(line, issued, org_unit) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        :error -> {:halt, {:error, :count_state_invalid}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp leg_line(line, issued, org_unit) do
    with {:ok, diff} <- decimal(line["difference"]),
         side when side in [:to, :from] <- side(diff),
         location when is_binary(location) <- line["location_id"],
         line_no when is_integer(line_no) <- line["line_no"] do
      base = %{
        "line_id" => line_id(issued.version_id, line_no),
        "sku" => line["catalog_item_id"],
        "lot" => line["catalog_lot_id"],
        "unit" => line["unit_ref"],
        "quantity" => diff |> Decimal.abs() |> Decimal.to_string(:normal)
      }

      {:ok,
       Map.put(base, Atom.to_string(side), %{
         "org_unit" => org_unit,
         "location" => location,
         "responsible" => line["responsible_employee_id"]
       })}
    else
      _ -> :error
    end
  end

  defp side(diff) do
    case Decimal.compare(diff, 0) do
      :gt -> :to
      :lt -> :from
      :eq -> :zero
    end
  end

  defp decimal(text) when is_binary(text) do
    case Decimal.parse(text) do
      {%Decimal{coef: coef} = d, ""} when is_integer(coef) -> {:ok, d}
      _ -> :error
    end
  end

  defp decimal(_), do: :error

  # A deterministic uuid per (differences version, line): a replay builds the same command.
  defp line_id(version_id, line_no) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(:sha256, "count-diff:#{version_id}:#{line_no}")

    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)
    hex(a, 8) <> "-" <> hex(b, 4) <> "-" <> hex(c, 4) <> "-" <> hex(d, 4) <> "-" <> hex(e, 12)
  end

  defp hex(n, width),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  # --- reverse ------------------------------------------------------------------------------------

  @doc "Starts the reversal of the whole count (`body`: `reason_code`, `reason_text`)."
  @spec reverse(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def reverse(prefix, id, body, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = CountDifferences.opts!(opts)
    authorized = Map.get(opts, :authorized)

    with {:ok, reason_code, reason_text} <- Posting.reversal_reason(body),
         {:ok, header} <- CountDifferences.fetch(prefix, id, scope),
         diff_id = diff_id(header),
         marks = marks(prefix, diff_id),
         :ok <- reversible(prefix, diff_id, marks),
         {:ok, entry_id} <- posting_entry(authorized, diff_id),
         :ok <- active(prefix, @reversal_definition, Map.get(opts, :activator)),
         {:ok, issued} <- issued(prefix, diff_id),
         {:ok, _instance} <-
           start_reversal(
             prefix,
             header,
             issued,
             diff_id,
             marks,
             entry_id,
             {reason_code, reason_text},
             actor
           ) do
      Counts.get(prefix, header["record_id"], opts)
    end
  end

  defp reversible(prefix, diff_id, marks) do
    cond do
      Map.has_key?(marks, "reversed") -> {:error, :count_reversed}
      not Map.has_key?(marks, "posted") -> {:error, :count_not_posted}
      Posting.pending(prefix, diff_id).reverse -> {:error, :reversal_pending}
      true -> :ok
    end
  end

  # Fail closed (INV-5): a caller without a ledger read cannot reverse.
  defp posting_entry(nil, _diff_id), do: {:error, :not_found}

  defp posting_entry(authorized, diff_id) do
    case Posting.entries(authorized, diff_id) do
      {:ok, rows} ->
        case Enum.filter(rows, &(&1.cause == @cause)) do
          [%{entry_id: entry_id}] -> {:ok, entry_id}
          _none_or_many -> {:error, :posting_inconsistent}
        end

      :truncated ->
        {:error, :posting_inconsistent}

      :error ->
        {:error, :internal}
    end
  end

  defp start_reversal(prefix, header, issued, diff_id, marks, entry_id, {code, text}, actor) do
    command = %{
      "cause" => "reversal",
      "reverses_entry_id" => entry_id,
      "reason_code" => code,
      "document_type" => @type_key,
      "document_id" => diff_id,
      "related_document_id" => header["document_id"],
      "client_op_id" => marks["posted"].record_id
    }

    vars = %{
      "document_id" => diff_id,
      "document_type" => @type_key,
      "version_no" => issued.version_no,
      "org_unit_id" => header["org_unit_id"],
      "mark" => "reversed",
      "reason_code" => code,
      "reason_text" => text,
      "posting" => command
    }

    start(prefix, @reversal_definition, "stock-rev", issued, diff_id, vars, actor)
  end

  # --- the posting record -------------------------------------------------------------------------

  @doc "The chair issues the `count.posting` document; the count becomes `posted`."
  @spec issue_posting_record(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def issue_posting_record(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = CountDifferences.opts!(opts)
    authorized = Map.get(opts, :authorized)

    with {:ok, header} <- CountDifferences.fetch(prefix, id, scope),
         :ok <- CountDifferences.chair(prefix, header, actor),
         {:ok, _} <- record_precheck(prefix, header) do
      CountDifferences.run(prefix, header, scope, opts, fn fresh ->
        with {:ok, lines?} <- record_precheck(prefix, fresh),
             {:ok, entry} <- record_entry(authorized, fresh, lines?),
             {:ok, issued} <- issue_document(prefix, fresh, entry, actor),
             fv =
               Map.merge(CountDifferences.base(fresh), %{
                 "status" => "posted",
                 "posting_document_id" => issued.document_id,
                 "posting_number" => issued.number,
                 "posting_issued_at" => issued.issued_at
               }),
             {:ok, _} <- CountDifferences.update_record(prefix, fresh["record_id"], fv, actor),
             :ok <-
               CountDifferences.audit(
                 prefix,
                 actor,
                 "posting_record_issued",
                 fresh,
                 "signed",
                 "posted",
                 nil
               ) do
          :ok
        end
      end)
    end
  end

  # `{:ok, true}` when the sheet has difference lines (a posted mark and no reversed mark are needed),
  # `{:ok, false}` for an empty sheet (no ledger call was made, nothing to wait for).
  defp record_precheck(prefix, header) do
    diff_id = diff_id(header)

    cond do
      present?(header["posting_document_id"]) or header["status"] == "posted" ->
        {:error, :posting_record_exists}

      header["status"] != "signed" or diff_id == nil ->
        {:error, :count_state_invalid}

      true ->
        with {:ok, issued} <- issued(prefix, diff_id) do
          lines? = CountDifferences.content_lines(issued.content) != []
          marks = marks(prefix, diff_id)

          cond do
            not lines? -> {:ok, false}
            Map.has_key?(marks, "reversed") -> {:error, :count_reversed}
            not Map.has_key?(marks, "posted") -> {:error, :count_not_posted}
            true -> {:ok, true}
          end
        end
    end
  end

  defp record_entry(_authorized, _header, false), do: {:ok, nil}
  defp record_entry(nil, _header, true), do: {:error, :not_found}

  defp record_entry(authorized, header, true) do
    case Posting.entries(authorized, diff_id(header)) do
      {:ok, rows} ->
        case Enum.filter(rows, &(&1.cause == @cause)) do
          [entry] -> {:ok, entry}
          _none_or_many -> {:error, :posting_inconsistent}
        end

      :truncated ->
        {:error, :posting_inconsistent}

      :error ->
        {:error, :internal}
    end
  end

  defp issue_document(prefix, order, entry, actor) do
    content = %{
      "count_order_id" => order["record_id"],
      "org_unit_id" => order["org_unit_id"],
      "differences_document_id" => order["differences_document_id"],
      "entry_id" => entry && entry.entry_id,
      "posting_seq" => entry && entry.posting_seq,
      "posting_time" => entry && CountDifferences.iso(entry.posting_time),
      "lines" => []
    }

    with {:ok, %{document: document}} <-
           Documents.create_draft(
             prefix,
             %{
               type_key: "count.posting",
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
         issued_at: CountDifferences.iso(summary.issued_at)
       }}
    else
      {:error, reason} -> {:error, {:document, reason}}
    end
  end

  @doc "The issued `count.posting` summary: number label, version, time and hash; no content."
  @spec posting_document(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def posting_document(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {_actor, scope} = CountDifferences.opts!(opts)

    with {:ok, header} <- CountDifferences.fetch(prefix, id, scope),
         doc_id when is_binary(doc_id) and doc_id != "" <- header["posting_document_id"],
         {:ok, summary} <- Documents.issued_summary(prefix, doc_id) do
      {:ok, Map.put(summary, :document_id, doc_id)}
    else
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, {:unprocessable, :count_not_posted}}
    end
  end

  # --- the read side ------------------------------------------------------------------------------

  @doc """
  The posting fields of a count view, only when the status is `signed` or `posted` (else `%{}`):
  `posting_state` (`none | pending | posted | reversed`), `post_pending`, `reverse_pending`, `entry_id`,
  `posted_at`, `posted_by`, `reversed_at`, `reversed_by`, `posting_check` (`ok | mismatch | nil`, never a
  detail), `posting_document_id`, `posting_number` and `posting_issued_at`. `authorized` is the ledger read authorization or `nil`.
  """
  @spec state_fields(String.t(), map(), term()) :: map()
  def state_fields(prefix, header, authorized) do
    diff_id = diff_id(header)

    if header["status"] in ["signed", "posted"] and diff_id != nil do
      marks = marks(prefix, diff_id)
      pending = Posting.pending(prefix, diff_id)
      rows = if authorized, do: Posting.entries(authorized, diff_id), else: :error

      %{
        "posting_state" => state(marks, pending),
        "post_pending" => pending.post,
        "reverse_pending" => pending.reverse,
        "entry_id" => entry_id(rows),
        "posted_at" => marks |> Map.get("posted") |> mark_at(),
        "posted_by" => if(marks["posted"], do: Posting.completer(prefix, diff_id, "post")),
        "reversed_at" => marks |> Map.get("reversed") |> mark_at(),
        "reversed_by" => if(marks["reversed"], do: Posting.completer(prefix, diff_id, "reverse")),
        "posting_check" => posting_check(prefix, header, diff_id, marks, rows),
        "posting_document_id" => header["posting_document_id"],
        "posting_number" => header["posting_number"],
        "posting_issued_at" => header["posting_issued_at"]
      }
    else
      %{}
    end
  end

  defp state(marks, pending) do
    cond do
      Map.has_key?(marks, "reversed") -> "reversed"
      Map.has_key?(marks, "posted") -> "posted"
      pending.post -> "pending"
      true -> "none"
    end
  end

  defp entry_id({:ok, rows}) do
    case Enum.filter(rows, &(&1.cause == @cause)) do
      [one] -> one.entry_id
      _none_or_many -> nil
    end
  end

  defp entry_id(_unavailable), do: nil

  defp mark_at(nil), do: nil
  defp mark_at(%{at: at}), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp posting_check(_prefix, _header, _diff_id, _marks, :error), do: nil
  defp posting_check(_prefix, _header, _diff_id, _marks, :truncated), do: "mismatch"

  defp posting_check(prefix, header, diff_id, marks, {:ok, rows}) do
    entries = Enum.filter(rows, &(&1.cause == @cause))
    reversals = Enum.filter(rows, &(&1.cause == "reversal"))

    if rows == [] and marks == %{} do
      nil
    else
      if consistent?(prefix, header, diff_id, marks, entries, reversals),
        do: "ok",
        else: "mismatch"
    end
  end

  defp consistent?(prefix, header, diff_id, marks, [entry], reversals) do
    case expected_legs(prefix, diff_id, header["org_unit_id"]) do
      :none ->
        false

      expected ->
        Posting.legs_match?(entry, expected) and Map.has_key?(marks, "posted") and
          entry.document_type == @type_key and
          entry.related_document_id == header["document_id"] and
          reversal_consistent?(marks, entry, reversals)
    end
  end

  defp consistent?(_prefix, _header, _diff_id, _marks, _none_or_many, _reversals), do: false

  defp reversal_consistent?(marks, entry, reversals) do
    case {Map.has_key?(marks, "reversed"), reversals} do
      {true, [reversal]} -> reversal.reverses_entry_id == entry.entry_id
      {false, []} -> true
      _other -> false
    end
  end

  # The legs the issued differences content gives: per line one leg of the signed difference.
  defp expected_legs(prefix, diff_id, org_unit) do
    case issued(prefix, diff_id) do
      {:ok, %{content: content}} ->
        content
        |> CountDifferences.content_lines()
        |> Enum.map(fn line ->
          Posting.leg_key(
            line["catalog_item_id"],
            line["location_id"],
            org_unit,
            line["responsible_employee_id"],
            line["catalog_lot_id"],
            line["unit_ref"],
            line["difference"]
          )
        end)
        |> Enum.sort()

      _none ->
        :none
    end
  end

  # --- shared -------------------------------------------------------------------------------------

  defp diff_id(%{"differences_document_id" => id}) when is_binary(id) and id != "", do: id
  defp diff_id(_header), do: nil

  defp marks(_prefix, nil), do: %{}
  defp marks(prefix, diff_id), do: prefix |> Posting.marks([diff_id]) |> Map.get(diff_id, %{})

  defp issued(_prefix, nil), do: {:error, :count_state_invalid}

  defp issued(prefix, diff_id) do
    case Posting.issued(prefix, diff_id) do
      %{content: %{} = _content} = issued -> {:ok, issued}
      _ -> {:error, :count_state_invalid}
    end
  end

  defp present?(value), do: value not in [nil, ""]
end
