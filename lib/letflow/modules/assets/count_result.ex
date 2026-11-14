defmodule Letflow.Modules.Assets.CountResult do
  @moduledoc """
  REQ-819 / GH #4372 (asset count slice K4, owner decision D-128, spec `docs/assets/asset-count.md`
  sections 4, 5 and 8): the RESULT of an asset count. It is built from the CONTENT of the issued
  `assets_count.sheet` document only (the live line records are never read), so a later edit of a
  line changes nothing (criterion 2). Module `assets` does not call `stock` (boundary Rule 4).

    * `result/3`: the differences with their proposed and chosen decisions. In `sheet_signed` they are
      computed from the sheet; in `signed` they are read from the issued `assets_count.result`.
    * `decide/5`: the signer records the decision of one result line (stored on the order as the json
      field `result_decisions`, keyed by the sheet `line_no`).
    * `sign/3`: in one transaction under the order lock: one DRAFT asset document per write off, hand
      over, change or commission decision (`Letflow.Modules.Assets.Documents.save/3`), the issued
      `assets_count.result`, the order `signed`. A refused draft rolls everything back and names the
      line. Nothing is posted: the register changes only when an `AssetsPost` holder issues and posts a
      draft.

  Who may decide and sign is `Letflow.Modules.Assets.CountSigner`. Seven kinds of difference are
  classified in a fixed precedence (shortage, low-value excess, location mismatch, responsible
  mismatch, condition; surplus with a card registered elsewhere, surplus with a card not registered,
  surplus without a card); see the spec section 4. A result has at most 200 lines.

  A refusal is an atom, `{:field_invalid | :field_not_allowed, key}` or
  `{:line_refused, reason, extras, line_no}` and stores nothing. `Audit` raises on a database failure
  (INV-8): the raise becomes `{:error, :audit_failed}` and the transaction rolls back.
  """

  alias Letflow.Audit
  alias Letflow.Documents, as: Core
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Ledger
  alias Letflow.Modules.Assets.CountSigner
  alias Letflow.Modules.Assets.Counts
  alias Letflow.Modules.Assets.Documents, as: AssetDocuments
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Modules.Assets.Views
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  import Ecto.Query, only: [from: 2]

  @kept ["record_id", "entity_type"]
  @max_lines 200
  @balance_page 200
  @max_reason 500
  @sheet_decisions ~w(writeoff handover change commission)
  @allowed %{
    "shortage" => ~w(writeoff no_register_change),
    "location_mismatch" => ~w(handover no_register_change),
    "responsible_mismatch" => ~w(change no_register_change),
    "surplus_registered_elsewhere" => ~w(handover no_register_change),
    "surplus_unregistered" => ~w(commission no_register_change),
    "surplus_no_card" => ~w(no_register_change),
    "condition" => ~w(no_register_change writeoff)
  }

  # --- reads ------------------------------------------------------------------------------------

  @doc """
  The result of a `sheet_signed` or `signed` count. `opts` is `%{actor_id, authorized}`, `authorized`
  being the `Letflow.Ledger.Authorized` of the caller (tenant-wide) or `nil`.
  """
  @spec result(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def result(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    actor = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         {:ok, authorized} <- full_reader(prefix, Map.get(opts, :authorized)),
         {:ok, lines} <- read_lines(prefix, header, authorized) do
      {:ok, result_view(prefix, header, actor, lines)}
    end
  end

  defp read_lines(prefix, %{"status" => "sheet_signed"} = header, authorized),
    do: compute(prefix, header, authorized)

  defp read_lines(prefix, %{"status" => "signed", "result_document_id" => doc_id}, _authorized)
       when is_binary(doc_id) do
    case Posting.issued(prefix, doc_id) do
      %{content: %{"lines" => lines}} when is_list(lines) ->
        {:ok, Enum.map(lines, &with_state(prefix, &1))}

      _ ->
        {:error, :count_state_invalid}
    end
  end

  defp read_lines(_prefix, _header, _authorized), do: {:error, :count_state_invalid}

  defp with_state(prefix, %{"document_id" => id} = line) when is_binary(id) do
    state =
      case AssetDocuments.fetch(prefix, id) do
        {:ok, %{state: state}} -> state
        _ -> "discarded"
      end

    Map.put(line, "document_state", state)
  end

  defp with_state(_prefix, line), do: Map.put(line, "document_state", nil)

  defp result_view(prefix, header, actor, lines) do
    %{
      "count_id" => header["record_id"],
      "status" => header["status"],
      "sheet_document_id" => header["sheet_document_id"],
      "sheet_number" => header["sheet_number"],
      "signer_role" => CountSigner.status(prefix, actor),
      "result_document_id" => header["result_document_id"],
      "result_number" => header["result_number"],
      "signed_at" => header["signed_at"],
      "signed_by" => header["signed_by"],
      "line_count" => length(lines),
      "too_large" => length(lines) > @max_lines,
      "lines" => lines
    }
  end

  # --- decisions --------------------------------------------------------------------------------

  @doc """
  Records the decision of the result line `line_no` (the sheet line number). `body` is
  `%{"decision" => ..., "reason_text" => ...}`; `reason_text` is required for `no_register_change`
  and refused for any other decision. Returns the line view.
  """
  @spec decide(String.t(), term(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def decide(prefix, id, line_no, body, opts) when is_binary(prefix) and is_map(opts) do
    actor = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         {:ok, authorized} <- full_reader(prefix, Map.get(opts, :authorized)),
         :ok <- CountSigner.check(prefix, actor),
         :ok <- status(header, "sheet_signed"),
         {:ok, body} <- body_keys(body) do
      Repo.transaction(fn ->
        Counts.lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"]),
             :ok <- status(fresh, "sheet_signed"),
             :ok <- CountSigner.check(prefix, actor),
             {:ok, lines} <- compute(prefix, fresh, authorized),
             :ok <- size(lines),
             {:ok, no} <- parse_line_no(line_no),
             {:ok, line} <- find(lines, no),
             {:ok, decision} <- decision(line, body),
             now = DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :second)),
             stored = decision_entry(decision, actor, now),
             decisions = Map.put(decisions_of(fresh), Integer.to_string(no), stored),
             fv = fresh |> Map.drop(@kept) |> Map.put("result_decisions", decisions),
             {:ok, _} <- update_record(prefix, fresh["record_id"], fv, actor),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "decision_recorded",
                 fresh["record_id"],
                 %{"status" => "sheet_signed", "line_no" => no},
                 %{"status" => "sheet_signed", "line_no" => no}
               ) do
          apply_decision(line, stored)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp body_keys(%{} = body) do
    case Enum.find(Map.keys(body), &(&1 not in ["decision", "reason_text"])) do
      nil -> {:ok, body}
      key -> {:error, {:field_not_allowed, to_string(key)}}
    end
  end

  defp body_keys(_), do: {:error, {:field_invalid, "body"}}

  defp decision(line, body) do
    chosen = Map.get(body, "decision")

    cond do
      not is_binary(chosen) or chosen not in Map.get(@allowed, line["difference"], []) ->
        {:error, :decision_invalid}

      chosen == "no_register_change" ->
        with {:ok, reason} <- reason_text(Map.get(body, "reason_text")),
             do: {:ok, %{"decision" => chosen, "reason_text" => reason}}

      Map.has_key?(body, "reason_text") ->
        {:error, {:field_not_allowed, "reason_text"}}

      true ->
        {:ok, %{"decision" => chosen}}
    end
  end

  defp reason_text(text) when is_binary(text) do
    if String.valid?(text) and not String.contains?(text, <<0>>) and
         String.trim(text) != "" and String.length(text) <= @max_reason,
       do: {:ok, text},
       else: {:error, {:field_invalid, "reason_text"}}
  end

  defp reason_text(_), do: {:error, {:field_invalid, "reason_text"}}

  defp decision_entry(decision, actor, now),
    do: Map.merge(decision, %{"decided_by" => actor, "decided_at" => now})

  defp decisions_of(%{"result_decisions" => %{} = d}), do: d
  defp decisions_of(_), do: %{}

  defp apply_decision(line, stored) do
    Map.merge(line, %{
      "decision" => stored["decision"],
      "reason_text" => stored["reason_text"],
      "decided_by" => stored["decided_by"],
      "decided_at" => stored["decided_at"]
    })
  end

  defp size(lines),
    do: if(length(lines) > @max_lines, do: {:error, :result_too_large}, else: :ok)

  defp find(lines, no) do
    case Enum.find(lines, &(&1["line_no"] == no)) do
      nil -> {:error, :line_not_found}
      line -> {:ok, line}
    end
  end

  defp parse_line_no(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_line_no(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> if Integer.to_string(n) == text, do: {:ok, n}, else: not_a_line()
      _ -> not_a_line()
    end
  end

  defp parse_line_no(_), do: not_a_line()
  defp not_a_line, do: {:error, :line_not_found}

  # --- sign -------------------------------------------------------------------------------------

  @doc """
  Signs the result: drafts, the issued `assets_count.result` and the order `signed`, in one
  transaction. Returns the result view.
  """
  @spec sign(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def sign(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    actor = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         {:ok, authorized} <- full_reader(prefix, Map.get(opts, :authorized)),
         :ok <- CountSigner.check(prefix, actor),
         :ok <- status(header, "sheet_signed") do
      Repo.transaction(fn ->
        Counts.lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"]),
             :ok <- status(fresh, "sheet_signed"),
             :ok <- CountSigner.check(prefix, actor),
             {:ok, lines} <- compute(prefix, fresh, authorized),
             :ok <- size(lines),
             now = DateTime.truncate(DateTime.utc_now(), :second),
             {:ok, lines, draft_ids} <- save_drafts(prefix, fresh, lines, now, actor),
             {:ok, issued} <- issue_result(prefix, fresh, lines, now, actor),
             in_commission = in_commission?(prefix, fresh, actor),
             fv =
               fresh
               |> Map.drop(@kept)
               |> Map.merge(%{
                 "status" => "signed",
                 "result_document_id" => issued.document_id,
                 "result_number" => issued.number_label,
                 "signed_at" => DateTime.to_iso8601(now),
                 "signed_by" => actor
               }),
             {:ok, _} <- update_record(prefix, fresh["record_id"], fv, actor),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "result_signed",
                 fresh["record_id"],
                 %{"status" => "sheet_signed"},
                 %{
                   "status" => "signed",
                   "signer_id" => actor,
                   "draft_ids" => draft_ids,
                   "signer_in_commission" => in_commission
                 }
               ) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, :ok} -> result(prefix, header["record_id"], opts)
        {:error, _} = error -> error
      end
    end
  end

  defp save_drafts(prefix, order, lines, now, actor) do
    event_time = DateTime.to_iso8601(now)

    Enum.reduce_while(lines, {:ok, [], []}, fn line, {:ok, acc, ids} ->
      if line["decision"] in @sheet_decisions do
        body = draft_body(line, order, event_time)

        case AssetDocuments.save(prefix, body, actor) do
          {:ok, %{id: doc_id}} ->
            stamped =
              Map.merge(line, %{"document_kind" => line["decision"], "document_id" => doc_id})

            {:cont, {:ok, [stamped | acc], ids ++ [doc_id]}}

          {:error, {reason, extras}} when is_binary(reason) ->
            {:halt,
             {:error, {:line_refused, reason, Map.take(extras, ["field"]), line["line_no"]}}}

          {:error, :busy} ->
            {:halt, {:error, :busy}}

          {:error, _} ->
            {:halt, {:error, {:line_refused, "draft_save_failed", %{}, line["line_no"]}}}
        end
      else
        {:cont, {:ok, [line | acc], ids}}
      end
    end)
    |> case do
      {:ok, acc, ids} -> {:ok, Enum.reverse(acc), ids}
      {:error, _} = error -> error
    end
  end

  defp draft_body(line, order, event_time) do
    note = "count #{order["sheet_number"]} line #{line["line_no"]}"
    from = line["from"] || %{}
    to = line["to"] || %{}

    base =
      case line["decision"] do
        "writeoff" ->
          %{
            "org_unit_id" => from["org_unit_id"],
            "location_id" => from["location_id"],
            "material_responsible_id" => from["material_responsible_id"],
            "actual_user_id" => from["actual_user_id"],
            "reason_code" => if(line["difference"] == "shortage", do: "lost", else: "broken"),
            "reason_text" => "count #{order["sheet_number"]}"
          }

        "handover" ->
          %{
            "org_unit_id" => from["org_unit_id"],
            "from_location_id" => from["location_id"],
            "from_material_responsible_id" => from["material_responsible_id"],
            "from_actual_user_id" => from["actual_user_id"],
            "to_org_unit_id" => to["org_unit_id"],
            "to_location_id" => to["location_id"],
            "to_material_responsible_id" => to["material_responsible_id"],
            "to_actual_user_id" => to["actual_user_id"]
          }

        "change" ->
          %{
            "org_unit_id" => from["org_unit_id"],
            "location_id" => from["location_id"],
            "from_material_responsible_id" => from["material_responsible_id"],
            "from_actual_user_id" => from["actual_user_id"],
            "to_material_responsible_id" => to["material_responsible_id"],
            "to_actual_user_id" => to["actual_user_id"]
          }

        "commission" ->
          %{
            "org_unit_id" => to["org_unit_id"],
            "location_id" => to["location_id"],
            "material_responsible_id" => to["material_responsible_id"],
            "actual_user_id" => to["actual_user_id"]
          }
      end

    base
    |> Map.merge(%{"kind" => line["decision"], "event_time" => event_time, "note" => note})
    |> Map.put("lines", [%{"asset_id" => line["asset_id"], "quantity" => line["quantity"]}])
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp issue_result(prefix, order, lines, now, actor) do
    employee =
      case Org.employee_for_user(prefix, actor) do
        {:ok, %{"record_id" => id}} -> id
        _ -> nil
      end

    content = %{
      "count_order_id" => order["record_id"],
      "sheet_document_id" => order["sheet_document_id"],
      "sheet_number" => order["sheet_number"],
      "signer_role" => CountSigner.role(prefix),
      "signed_by" => actor,
      "signer_employee_id" => employee,
      "signed_at" => DateTime.to_iso8601(now),
      "lines" => lines
    }

    with {:ok, %{document: document}} <-
           Core.create_draft(
             prefix,
             %{
               type_key: "assets_count.result",
               issuing_org_unit_id: order["org_unit_id"],
               content: content
             },
             actor
           ),
         {:ok, _} <- Core.issue(prefix, %{document_id: document.id, actor_id: actor}),
         {:ok, summary} <- Core.issued_summary(prefix, document.id) do
      {:ok, Map.put(summary, :document_id, document.id)}
    else
      {:error, reason} -> {:error, {:document, reason}}
    end
  end

  defp in_commission?(prefix, order, actor) do
    case Org.employee_for_user(prefix, actor) do
      {:ok, %{"record_id" => employee}} ->
        employee == order["chair_employee_id"] or employee in members(prefix, order)

      _ ->
        false
    end
  end

  # --- differences (pure on the issued sheet, plus one ledger read per surplus card) ------------

  defp compute(prefix, order, authorized) do
    with {:ok, sheet} <- issued_sheet(prefix, order),
         {:ok, cut_off} <- cut_off(sheet.content) do
      ctx = %{
        prefix: prefix,
        authorized: authorized,
        unit: sheet.content["org_unit_id"] || order["org_unit_id"],
        cut_off: cut_off,
        seq: sheet.content["cutoff_seq"]
      }

      decisions = decisions_of(order)

      sheet.content["lines"]
      |> Enum.sort_by(& &1["line_no"])
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        case classify(line, ctx) do
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, result} -> {:cont, {:ok, [with_decision(result, decisions) | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp issued_sheet(prefix, %{"sheet_document_id" => doc_id}) when is_binary(doc_id) do
    case Posting.issued(prefix, doc_id) do
      %{content: %{"lines" => lines}} = sheet when is_list(lines) -> {:ok, sheet}
      _ -> {:error, :count_state_invalid}
    end
  end

  defp issued_sheet(_prefix, _order), do: {:error, :count_state_invalid}

  defp cut_off(content) do
    case DateTime.from_iso8601(to_string(content["cut_off_at"])) do
      {:ok, at, _} -> {:ok, at}
      _ -> {:error, :count_state_invalid}
    end
  end

  defp with_decision(line, decisions) do
    case Map.get(decisions, Integer.to_string(line["line_no"])) do
      %{"decision" => d} = stored when is_binary(d) -> apply_decision(line, stored)
      _ -> line
    end
  end

  defp classify(%{"kind" => "book"} = line, ctx), do: {:ok, classify_book(line, ctx)}
  defp classify(line, ctx), do: classify_surplus(line, ctx)

  defp classify_book(line, ctx) do
    qb = int(line["book_quantity"])
    qc = int(line["counted_quantity"])

    book =
      key(
        ctx.unit,
        line["book_location_id"],
        line["book_material_responsible_id"],
        line["book_actual_user_id"]
      )

    obs_loc = line["observed_location_id"]
    obs_resp = line["observed_material_responsible_id"]
    obs_user = line["observed_actual_user_id"]

    to = fn location ->
      key(
        ctx.unit,
        location,
        obs_resp || line["book_material_responsible_id"],
        obs_user || line["book_actual_user_id"]
      )
    end

    cond do
      qc < qb ->
        build(line, "shortage", "writeoff", qb - qc, book, nil)

      qc > qb and line["asset_kind"] == "low_value" ->
        build(
          line,
          "surplus_unregistered",
          "commission",
          qc - qb,
          nil,
          to.(obs_loc || line["book_location_id"])
        )

      not is_nil(obs_loc) and obs_loc != line["book_location_id"] ->
        build(line, "location_mismatch", "handover", qb, book, to.(obs_loc))

      (not is_nil(obs_resp) and obs_resp != line["book_material_responsible_id"]) or
          (not is_nil(obs_user) and obs_user != line["book_actual_user_id"]) ->
        build(line, "responsible_mismatch", "change", qb, book, to.(line["book_location_id"]))

      line["condition"] in ["damaged", "not_in_use"] ->
        build(line, "condition", "no_register_change", qc, book, nil)

      true ->
        nil
    end
  end

  defp classify_surplus(%{"asset_id" => nil} = line, _ctx),
    do: {:ok, build(line, "surplus_no_card", "no_register_change", nil, nil, nil)}

  defp classify_surplus(%{"asset_id" => asset} = line, ctx) when is_binary(asset) do
    qc = int(line["counted_quantity"])

    observed =
      key(
        ctx.unit,
        line["observed_location_id"],
        line["observed_material_responsible_id"],
        line["observed_actual_user_id"]
      )

    with {:ok, keys} <- positive_keys(ctx, asset) do
      case keys do
        [] ->
          {:ok, build(line, "surplus_unregistered", "commission", qc, nil, observed)}

        [best | _] ->
          from = key(best.org_unit, best.location, best.material_responsible, best.actual_user)

          {:ok,
           build(
             line,
             "surplus_registered_elsewhere",
             "handover",
             min(qc, best.qty),
             from,
             observed
           )}
      end
    end
  end

  defp classify_surplus(line, _ctx),
    do: {:ok, build(line, "surplus_no_card", "no_register_change", nil, nil, nil)}

  defp key(unit, location, responsible, user) do
    %{
      "org_unit_id" => unit,
      "location_id" => location,
      "material_responsible_id" => responsible,
      "actual_user_id" => user
    }
  end

  defp build(line, difference, proposed, quantity, from, to) do
    %{
      "line_no" => line["line_no"],
      "difference" => difference,
      "proposed_decision" => proposed,
      "decision" => proposed,
      "reason_text" => nil,
      "decided_by" => nil,
      "decided_at" => nil,
      "asset_id" => line["asset_id"],
      "asset_kind" => line["asset_kind"],
      "inventory_number" => line["inventory_number"],
      "name" => line["name"],
      "description" => line["description"],
      "book_quantity" => line["book_quantity"],
      "counted_quantity" => line["counted_quantity"],
      "condition" => line["condition"],
      "quantity" => quantity && Integer.to_string(quantity),
      "from" => from,
      "to" => to,
      "document_kind" => nil,
      "document_id" => nil,
      "document_state" => nil
    }
  end

  defp int(text) do
    case Integer.parse(to_string(text)) do
      {n, _} -> n
      :error -> 0
    end
  end

  # The positive balance keys of one card at the cut-off of the sheet, the largest quantity first,
  # ties by the key text. One chain of pages at `{:event_time, cut_off, N}`.
  defp positive_keys(ctx, asset) do
    basis = {:event_time, ctx.cut_off, if(is_integer(ctx.seq), do: ctx.seq, else: :latest)}

    case balance_pages(ctx.authorized, basis, asset, nil, []) do
      {:ok, rows} ->
        keys =
          rows
          |> Enum.map(&Views.asset_balance/1)
          |> Enum.map(&Map.put(&1, :qty, quantity_of(&1.quantity)))
          |> Enum.filter(&(&1.qty > 0))
          |> Enum.sort_by(
            &{-&1.qty,
             {&1.org_unit || "", &1.location || "", &1.material_responsible || "",
              &1.actual_user || ""}}
          )

        {:ok, keys}

      {:error, _} ->
        {:error, :ledger_read_failed}
    end
  end

  defp balance_pages(authorized, basis, asset, cursor, acc) do
    page = if cursor, do: %{limit: @balance_page, cursor: cursor}, else: %{limit: @balance_page}

    case Ledger.balances(authorized, basis, %{"asset" => asset}, page) do
      {:ok, %{rows: rows, next_cursor: next}} ->
        acc = acc ++ rows
        if next, do: balance_pages(authorized, basis, asset, next, acc), else: {:ok, acc}

      {:error, _} = error ->
        error
    end
  end

  defp quantity_of(text) do
    case Decimal.parse(to_string(text)) do
      {d, ""} -> d |> Decimal.round(0, :down) |> Decimal.to_integer()
      _ -> 0
    end
  end

  # --- shared -----------------------------------------------------------------------------------

  defp fetch(prefix, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, header} <- ReadApi.lookup(prefix, uuid, ["assets_count_order"]) do
      {:ok, header}
    else
      _ -> {:error, :not_found}
    end
  end

  defp full_reader(prefix, %{scope: :all, prefix: prefix} = authorized), do: {:ok, authorized}
  defp full_reader(_prefix, _other), do: {:error, :not_found}

  defp status(%{"status" => s}, s), do: :ok
  defp status(_, _), do: {:error, :count_state_invalid}

  defp members(prefix, header) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == "assets_count_member" and l.deleted == false and
            fragment("?->>'count_order_id' = ?", l.field_values, ^header["record_id"]),
        select: fragment("?->>'employee_id'", l.field_values)
      ),
      prefix: prefix
    )
    |> Enum.filter(&is_binary/1)
  end

  defp update_record(prefix, id, fv, actor) do
    attrs = %{
      entity_type: "assets_count_order",
      record_id: id,
      field_values: fv,
      actor_id: actor,
      idempotency_key: "assets.count_result:" <> Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (assets module, own-record system path; the caller passed Assets.Access first)
    case Records.update_record(attrs, prefix, ManagedTypes.owner_for!(Letflow.Modules.Assets)) do
      {:ok, _} -> {:ok, id}
      {:error, _} = error -> error
    end
  end

  # INV-8: Audit raises on a database failure; the rescue turns the raise into a refusal.
  defp audit(prefix, actor, action, order_id, before, after_state) do
    entry = %{
      actor_id: actor,
      action: "assets_count." <> action,
      resource_type: "assets_count_order",
      resource_id: order_id,
      before_state: before,
      after_state: after_state
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  defp actor!(opts) do
    actor = Map.get(opts, :actor_id)

    unless is_binary(actor) and match?({:ok, _}, Ecto.UUID.cast(actor)),
      do: raise(ArgumentError, "opts :actor_id must be a uuid")

    actor
  end
end
