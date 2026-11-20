defmodule Letflow.Modules.Stock.Documents.Posting do
  @moduledoc """
  REQ-713 / GH #3748 (assets B4 part 2): posting, reversal and cancel of an issued stock document.
  Public functions: `ensure_active/3`, `start_post/4`, `post/4`, `reverse/6`, `cancel/5` (the routes'
  work), `state_fields/3` and `states_for/2` (the read side). The tenant is the `prefix` argument
  and nothing else (INV-1); every read and write passes it.

  ## How a document posts

  The issue step (and the retry route `post/4`) starts ONE instance of the module's process
  definition `stock_receipt` (`Letflow.Engine.create/2`, no correlation key: it is unique across
  all statuses and would make a cancelled post unrestartable; the idempotency key
  `stock-post:<version id>:<attempt>` is used instead). Completing its HUMAN_TASK `post` runs the
  write handler `post_document` (`Letflow.Modules.Stock.Handlers`): the ledger entry and the
  `stock_posting_mark` record commit together or not at all. The command is built here ONLY from
  the issued version's frozen content. A receipt's entry carries the offline triple `device_id`,
  `client_seq`, `client_event_time` (derived from the issued number and the header's `event_time`)
  so the core's rule gives the entry the header's event time, not the posting time; a reversal is
  posted online (all three absent), so its event time is its posting time.

  REQ-726: an `opening` document (`Letflow.Modules.Stock.Documents.Kinds`) starts one `stock_opening`
  instance instead: its `submit` task is completed right after the start by the issuing user
  (`Letflow.Engine.complete_task/3`, no credential: the node has no module write), and completing
  `approve` (a second person, `distinct_from ["submit"]`) runs the same `post_document` handler with
  cause `opening`. The opening command has no offline triple, so its event time is its posting time
  (`Letflow.Modules.Stock.Documents.OpeningPosting`). Reversal and cancel are shared with the receipt.

  REQ-854: a `quick_count` document starts one `stock_quick_count` instance in the same way (`submit`
  completed by the counter right after the start, `approve` posts the cause `count_set` with the
  `expected_on_hand` of its line, `Letflow.Modules.Stock.Documents.QuickCountPosting`). A count equal to
  the book starts no instance and posts nothing: `state_fields/3` then derives the state `confirmed`.

  ## Lazy activation

  Install leaves the pack's process definitions as module-stamped drafts. On first use,
  `ensure_active/3` activates an unchanged stock draft with the request's activator when it has
  authority, otherwise with the tenant-local stock process activator. This internal user has no
  password, role, group or login-directory entry. Its authority exists only in this reviewed path,
  after the closed process-name, ownership and body checks; it cannot activate tenant definitions.
  The ordinary `Definitions.activate/2` validators, signed authority and activation audit still run.
  Tenant versions, changed graphs, deprecated definitions and a deactivated system user fail closed.

  ## Read states

  `state_fields/3` derives `posted_at`, `posted_by`, `entry_id`, `reversed_at`, `reversed_by` and
  `posting_check` from the marks, the completed tasks and the ledger entries of the document.
  `posting_check` is `"ok"`, `"mismatch"` or `nil` and never carries a detail (decision 0078 D5:
  the binding of the posting to the issued content is detected here, not enforced, until L7).
  `posted_by` and `reversed_by` come from `tasks.completed_by` (the ledger exposes no subject).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Definitions
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Documents
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Engine
  alias Letflow.Engine.Task
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Ledger
  alias Letflow.Modules.ProcessActivator
  alias Letflow.Modules.Stock.ActorLabel
  alias Letflow.Modules.Stock.Documents.ActionIdempotency
  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Modules.Stock.Documents.Legs
  alias Letflow.Modules.Stock.Documents.OpeningPosting
  alias Letflow.Modules.Stock.Documents.QuickCountPosting
  alias Letflow.Repo
  alias Letflow.SharedStockAccess

  @reversal_definition "stock_reversal"
  @count_definition "stock_count_posting"
  @post_nodes ["post", "submit", "approve"]
  @mark_type "stock_posting_mark"
  @reasons ~w(wrong_document wrong_quantity wrong_master_data other)
  @reason_text_max 500
  @max_number 10_000_000

  @doc "The closed list of reversal reason codes."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  # -- lazy activation ----------------------------------------------------------------------------

  @doc """
  Makes sure the module's process definition `name` is active, activating its stamped draft with
  `activator` when authorized, otherwise the internal stock activator. `:ok` or `:error`; logs reason tags only.
  """
  @spec ensure_active(String.t(), String.t(), map() | nil) :: :ok | :error
  def ensure_active(prefix, name, activator) when is_binary(prefix) and is_binary(name) do
    if name in (Kinds.definition_names() ++ [@reversal_definition, @count_definition]) do
      case Repo.transaction(fn -> ensure_locked(prefix, name, activator) end) do
        {:ok, :ok} -> :ok
        {:error, _reason} -> :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp ensure_locked(prefix, name, activator) do
    rows =
      Repo.all(
        from(d in ProcessDefinition,
          where: d.name == ^name,
          order_by: [desc: d.created_at, desc: d.id],
          lock: "FOR UPDATE"
        ),
        prefix: prefix
      )

    case Enum.find(rows, &(&1.status == :active)) do
      %ProcessDefinition{} = active ->
        if stock_stamped?(active), do: :ok, else: Repo.rollback(:foreign_definition)

      nil ->
        with [draft | _] <- rows,
             :draft <- draft.status,
             true <- Enum.all?(rows, &stock_stamped?/1),
             {:ok, authority} <- activation_authority(prefix, activator),
             {:ok, _activated} <-
               Definitions.activate(draft.id, prefix: prefix, activator: authority) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("stock definition activation refused: #{inspect(tag(reason))}")
            Repo.rollback(:activation_refused)

          _refused ->
            Repo.rollback(:activation_refused)
        end
    end
  end

  defp activation_authority(prefix, activator) do
    if activator?(activator),
      do: {:ok, activator},
      else: ProcessActivator.system_authority(prefix)
  end

  defp activator?(%{permissions: permissions, entities_records_write?: true})
       when is_list(permissions), do: "DefinitionsActivate" in permissions

  defp activator?(_), do: false

  defp stock_stamped?(row) do
    case OwnerStamp.from_row(row) do
      {:ok, %{module_id: "stock", body_hash: hash}} -> OwnerStamp.graph_hash(row.graph) == hash
      _ -> false
    end
  end

  defp tag(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp tag(reason), do: reason

  # -- the issued version -------------------------------------------------------------------------

  @doc """
  The live issued version of document `id` for the posting command: `%{version_id, version_no,
  content, number, period}`, or `nil` when the live version is not issued.
  """
  @spec issued(String.t(), String.t()) :: map() | nil
  def issued(prefix, id) do
    query =
      from(v in DocumentVersion,
        join: d in Document,
        on: d.id == v.document_id,
        where: v.document_id == ^id and v.status == :issued,
        order_by: [desc: v.version_no],
        limit: 1,
        select: %{
          version_id: v.id,
          version_no: v.version_no,
          content: v.content,
          number: d.number,
          period: d.period
        }
      )

    Repo.one(query, prefix: prefix)
  end

  # -- starting the instances ---------------------------------------------------------------------

  @doc """
  Starts one `stock_receipt` instance for the issued document `view` (as `Documents.fetch/2`
  renders it) with `issued` (from `issued/2`). `{:ok, instance_id}` or `{:error, reason}`.
  """
  @spec start_post(String.t(), map(), map(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def start_post(prefix, view, issued, actor, submit_output \\ %{}) do
    spec = Kinds.get(view.kind)

    with :ok <- start_seam(),
         {:ok, command} <- post_command(spec, view, issued) do
      vars = %{
        "document_id" => view.id,
        "document_type" => spec.type_key,
        "version_no" => issued.version_no,
        "org_unit_id" => view.org_unit_id,
        "mark" => "posted",
        "posting" => command
      }

      with {:ok, instance_id} <-
             start(
               prefix,
               spec.definition,
               "stock-post",
               issued.version_id,
               view.id,
               vars,
               actor,
               view.org_unit_id
             ) do
        if view.kind in ["opening", "quick_count"],
          do: complete_submit(prefix, instance_id, actor, submit_output)

        {:ok, instance_id}
      end
    else
      :none -> {:error, :nothing_to_post}
      {:error, _reason} = error -> error
    end
  end

  # REQ-726: the issuing user is the preparer. A failure is logged by tag and is NOT an error of the
  # start: the instance and its pending `submit` task stay (the runbook says whoever completes it
  # becomes the preparer for `distinct_from`).
  defp complete_submit(prefix, instance_id, actor, output) do
    task =
      Repo.one(
        from(t in Task,
          where: t.instance_id == ^instance_id and t.node_id == "submit" and t.status == :pending,
          limit: 1
        ),
        prefix: prefix
      )

    attrs = %{
      output_variables: output,
      actor_id: actor,
      idempotency_key: "stock-submit:#{instance_id}"
    }

    with %Task{id: task_id} <- task,
         {:ok, _result} <- Engine.complete_task(task_id, attrs, prefix: prefix) do
      :ok
    else
      other ->
        Logger.warning("stock opening submit not completed: #{inspect(submit_tag(other))}")
        :error
    end
  end

  defp submit_tag({:error, reason}), do: tag(reason)
  defp submit_tag(other), do: other

  @doc "Starts one `stock_reversal` instance (see the moduledoc)."
  @spec start_reversal(String.t(), map(), map(), map(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def start_reversal(prefix, view, issued, reversal, actor) do
    type_key = Kinds.get(view.kind).type_key

    command = %{
      "cause" => "reversal",
      "reverses_entry_id" => reversal.entry_id,
      "reason_code" => reversal.reason_code,
      "document_type" => type_key,
      "document_id" => view.id,
      "client_op_id" => reversal.mark_id
    }

    vars = %{
      "document_id" => view.id,
      "document_type" => type_key,
      "version_no" => issued.version_no,
      "org_unit_id" => view.org_unit_id,
      "mark" => "reversed",
      "reason_code" => reversal.reason_code,
      "reason_text" => reversal.reason_text,
      "posting" => command
    }

    start(
      prefix,
      @reversal_definition,
      "stock-rev",
      issued.version_id,
      view.id,
      vars,
      actor,
      view.org_unit_id
    )
  end

  # Test seam: forces a start failure after the issue committed. Read here only.
  defp start_seam do
    if Application.get_env(:letflow, :stock_post_start_fail?) == true,
      do: {:error, :forced_start_failure},
      else: :ok
  end

  # Public for `Letflow.Modules.Stock.CountPosting` (REQ-718): the same start for a count.
  @doc false
  def start(prefix, name, key_prefix, version_id, doc_id, vars, actor, scope_node_id \\ nil) do
    attempt(prefix, name, key_prefix, version_id, doc_id, vars, actor, scope_node_id, 2)
  end

  defp attempt(prefix, name, key_prefix, version_id, doc_id, vars, actor, node, tries_left) do
    n = 1 + instance_count(prefix, name, doc_id)

    attrs = %{
      definition_name: name,
      initial_variables: vars,
      actor_id: actor,
      idempotency_key: "#{key_prefix}:#{version_id}:#{n}"
    }

    # REQ-831: the document's org unit is the instance's scope node (nil: an unscoped start).
    attrs = if node, do: Map.put(attrs, :scope_node_id, node), else: attrs

    case Engine.create(attrs, prefix: prefix) do
      {:ok, %{replayed: true, status: status}} when status != :active and tries_left > 1 ->
        attempt(prefix, name, key_prefix, version_id, doc_id, vars, actor, node, tries_left - 1)

      {:ok, %{instance_id: instance_id}} ->
        {:ok, instance_id}

      {:error, :definition_not_active} ->
        {:error, :definition_not_active}

      {:error, reason} ->
        Logger.warning("stock posting start refused: #{inspect(tag(reason))}")
        {:error, :start_failed}
    end
  end

  defp definition_ids(prefix, name) do
    Repo.all(
      from(d in ProcessDefinition,
        where: d.name == ^name and d.owner_module == "stock",
        select: d.id
      ),
      prefix: prefix
    )
  end

  defp instance_count(prefix, name, doc_id) do
    ids = definition_ids(prefix, name)

    Repo.aggregate(
      from(p in InstanceProjection,
        where: p.definition_id in ^ids and fragment("?->>'document_id' = ?", p.variables, ^doc_id)
      ),
      :count,
      prefix: prefix
    )
  end

  # The posting command from the frozen content: the header and lines as issued, plus the line
  # RECORD ids (`view.lines` are the records; nothing changes after issue). The sides of every line
  # come from `Kinds.sides/2` (a receipt has a `to` side only; REQ-721 kinds also a `from` side).
  defp post_command(%{kind: "opening"}, view, issued) do
    OpeningPosting.command(view, issued, Map.new(view.lines, &{&1.line_no, &1.line_id}))
  end

  defp post_command(%{kind: "quick_count"}, view, issued) do
    QuickCountPosting.command(
      view,
      issued,
      Map.new(view.lines, &{&1.line_no, &1.line_id}),
      Map.get(view, :record_zero, false)
    )
  end

  defp post_command(spec, view, %{content: content, number: number, period: period} = issued) do
    header = Map.get(content, "header", %{})
    lines = Map.get(content, "lines", [])
    line_ids = Map.new(view.lines, &{&1.line_no, &1.line_id})

    with {:ok, seq} <- client_seq(period, number),
         {:ok, built} <- build_lines(lines, Kinds.sides(spec, header), line_ids) do
      {:ok,
       %{
         "cause" => spec.cause,
         "document_type" => spec.type_key,
         "document_id" => view.id,
         "client_op_id" => issued.version_id,
         "device_id" => spec.device_id,
         "client_seq" => seq,
         "client_event_time" => Map.get(header, "event_time"),
         "lines" => built
       }
       |> with_reason(spec, header)}
    end
  end

  # A write-off carries its reason code (the ledger cause demands one); other kinds carry none.
  defp with_reason(command, %{kind: "write_off"}, header),
    do: Map.put(command, "reason_code", Map.get(header, "reason_code"))

  defp with_reason(command, _spec, _header), do: command

  @doc false
  def client_seq(period, number) when is_binary(period) and is_integer(number) do
    with {year, ""} <- Integer.parse(period),
         true <- number >= 0 and number < @max_number do
      {:ok, year * @max_number + number}
    else
      _bad -> {:error, :number_out_of_range}
    end
  end

  def client_seq(_period, _number), do: {:error, :number_out_of_range}

  defp build_lines(lines, sides, line_ids) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case Map.fetch(line_ids, Map.get(line, "line_no")) do
        {:ok, line_id} -> {:cont, {:ok, [leg_line(line, line_id, sides) | acc]}}
        :error -> {:halt, {:error, :line_record_missing}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp leg_line(line, line_id, {from, to}) do
    base = %{
      "line_id" => line_id,
      "sku" => Map.get(line, "catalog_item_id"),
      "lot" => Map.get(line, "catalog_lot_id"),
      "unit" => Map.get(line, "catalog_uom_id"),
      "quantity" => Map.get(line, "quantity")
    }

    base = if to, do: Map.put(base, "to", side_map(to)), else: base
    if from, do: Map.put(base, "from", side_map(from)), else: base
  end

  defp side_map(side) do
    %{
      "org_unit" => side.org_unit,
      "location" => side.location,
      "responsible" => side.responsible
    }
  end

  # -- the routes' work ---------------------------------------------------------------------------

  @doc """
  Retry route: starts the posting instance of an issued document that has no mark and no pending
  post task. Returns `{:ok, view}` or `{:error, reason}`, `reason` one of `:not_found`,
  `:document_not_issued`, `:document_cancelled`, `:document_posted`, `:posting_pending`,
  `:definition_not_active`, `:internal`.

  `who[:idempotency_key]` (REQ-847, stored `client:stock_post:<actor>:<K>`, see
  `Letflow.Modules.Stock.Documents.ActionIdempotency`) makes a retry return the document as
  `fetch` shows it now, also after the post task completed: no second instance, nothing posted.
  The same key on another document is `{:error, :idempotency_key_reuse}`; a refused post binds
  nothing.
  """
  @spec post(String.t(), term(), map(), term()) :: {:ok, map()} | {:error, atom()}
  def post(prefix, id, %{actor_id: actor, activator: activator} = who, fetch) do
    ActionIdempotency.run(
      prefix,
      Map.get(who, :idempotency_key),
      id,
      fn -> fetch.(prefix, id) end,
      fn -> post_new(prefix, id, actor, activator, fetch) end
    )
  end

  defp post_new(prefix, id, actor, activator, fetch) do
    with {:ok, view} <- fetch.(prefix, id),
         :ok <- postable(prefix, view),
         :ok <- active(prefix, Kinds.get(view.kind).definition, activator),
         %{} = issued <- issued(prefix, view.id) || {:error, :internal},
         {:ok, _instance} <- start_post(prefix, view, issued, actor) do
      fetch.(prefix, id)
    else
      {:error, :definition_not_active} -> {:error, :definition_not_active}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :internal}
    end
  end

  defp postable(prefix, view) do
    pending = pending(prefix, view.id)

    cond do
      view.state == "draft" -> {:error, :document_not_issued}
      view.state == "cancelled" -> {:error, :document_cancelled}
      view.state in ["posted", "reversed", "confirmed"] -> {:error, :document_posted}
      pending.post -> {:error, :posting_pending}
      true -> :ok
    end
  end

  defp active(prefix, name, activator) do
    case ensure_active(prefix, name, activator) do
      :ok -> :ok
      :error -> {:error, :definition_not_active}
    end
  end

  @doc """
  Reverse route. `body` is the decoded JSON map. Reasons: `:reason_invalid`, `:not_found`,
  `:document_not_posted`, `:document_reversed`, `:reversal_pending`, `:posting_inconsistent`,
  `:definition_not_active`, `:internal`.
  """
  @spec reverse(String.t(), term(), term(), map(), term(), term()) ::
          {:ok, map()} | {:error, atom()}
  def reverse(prefix, id, body, %{actor_id: actor, activator: activator}, authorized, fetch) do
    with {:ok, reason_code, reason_text} <- reversal_reason(body),
         {:ok, view} <- fetch.(prefix, id),
         marks = marks(prefix, [view.id]) |> Map.get(view.id, %{}),
         :ok <- reversible(prefix, view, marks),
         {:ok, entry_id} <- posting_entry(authorized, view),
         :ok <- active(prefix, @reversal_definition, activator),
         %{} = issued <- issued(prefix, view.id) || {:error, :internal},
         reversal = %{
           entry_id: entry_id,
           mark_id: marks["posted"].record_id,
           reason_code: reason_code,
           reason_text: reason_text
         },
         {:ok, _instance} <- start_reversal(prefix, view, issued, reversal, actor) do
      fetch.(prefix, id)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :internal}
    end
  end

  @doc false
  def reversal_reason(%{"reason_code" => code} = body) when code in @reasons do
    text = Map.get(body, "reason_text")

    with true <- text == nil or is_binary(text),
         text = normalize(text),
         true <- text == nil or String.length(text) <= @reason_text_max,
         true <- code != "other" or (is_binary(text) and String.trim(text) != "") do
      {:ok, code, text}
    else
      _bad -> {:error, :reason_invalid}
    end
  end

  def reversal_reason(_body), do: {:error, :reason_invalid}

  defp normalize(nil), do: nil

  defp normalize(text) do
    case :unicode.characters_to_nfc_binary(text) do
      binary when is_binary(binary) -> binary
      _error -> text
    end
  end

  defp reversible(prefix, view, marks) do
    cond do
      Map.has_key?(marks, "reversed") -> {:error, :document_reversed}
      not Map.has_key?(marks, "posted") -> {:error, :document_not_posted}
      pending(prefix, view.id).reverse -> {:error, :reversal_pending}
      true -> :ok
    end
  end

  # The one posting entry (cause of the kind) of the document, read through the caller's
  # tenant-wide authorization.
  defp posting_entry(authorized, view) do
    causes = Kinds.causes(Kinds.get(view.kind))

    case entries(authorized, view.id) do
      {:ok, rows} ->
        case Enum.filter(rows, &(&1.cause in causes)) do
          [%{entry_id: entry_id}] -> {:ok, entry_id}
          _none_or_many -> {:error, :posting_inconsistent}
        end

      :truncated ->
        {:error, :posting_inconsistent}

      :error ->
        {:error, :internal}
    end
  end

  @doc """
  Cancel route: cancels the issued version when the document is reversed, or issued with no mark
  and no pending task. An issued unposted document of a stock-consuming kind (`Kinds.withdrawable?/1`)
  may also be cancelled while its post task is pending: the post instance is withdrawn first (T-1375). Reasons: `:not_found`, `:document_not_issued`, `:posting_pending`,
  `:reversal_pending`, `:document_posted`, `{:unprocessable, atom}`, `:internal`.
  """
  @spec cancel(String.t(), term(), map(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def cancel(prefix, id, body, actor, fetch) do
    with {:ok, view} <- fetch.(prefix, id),
         {:ok, _reason} <- checked_reason(body),
         :ok <- cancellable(prefix, view),
         %{} = issued <- issued(prefix, view.id) || {:error, :internal},
         :ok <- withdraw_post(prefix, view, actor),
         {:ok, reason} <- checked_reason(body),
         {:ok, _version} <- do_cancel(prefix, view, issued, reason, actor) do
      fetch.(prefix, id)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :internal}
    end
  end

  # The reason is checked before anything is changed: a bad request must leave a pending post task alone.
  defp checked_reason(%{} = body), do: Documents.validate_cancel_reason(Map.get(body, "reason"))
  defp checked_reason(_body), do: {:error, :reason_invalid}

  # An issued, unposted document of a kind whose posting the ledger can refuse for stock may be
  # cancelled while its post task is pending (T-1375): the task is withdrawn first.
  defp cancellable(prefix, view) do
    pending = pending(prefix, view.id)

    cond do
      view.state in ["draft", "cancelled"] -> {:error, :document_not_issued}
      pending.post and not Kinds.withdrawable?(view.kind) -> {:error, :posting_pending}
      pending.reverse -> {:error, :reversal_pending}
      view.state == "posted" -> {:error, :document_posted}
      true -> :ok
    end
  end

  defp withdraw_post(prefix, view, actor) do
    ids = pending_post_instance_ids(prefix, view.id)

    Enum.reduce_while(ids, :ok, fn instance_id, :ok ->
      attrs = %{actor_id: actor, idempotency_key: "stock-withdraw:#{instance_id}"}

      case Engine.cancel_instance(instance_id, attrs, prefix: prefix) do
        {:ok, _} -> {:cont, :ok}
        {:error, {:instance_already_terminal, _}} -> {:halt, recheck(prefix, view)}
        {:error, :busy} -> {:halt, {:error, :busy}}
        {:error, other} -> {:halt, {:error, log_internal(other)}}
        _other -> {:halt, {:error, :internal}}
      end
    end)
  end

  # The post finished meanwhile: the mark exists, so cancellable/2 now answers document_posted.
  defp recheck(prefix, view) do
    case cancellable(prefix, view) do
      :ok -> {:error, :document_not_issued}
      {:error, _} = error -> error
    end
  end

  defp pending_post_instance_ids(prefix, id) do
    ids = Enum.flat_map(Kinds.definition_names(), &definition_ids(prefix, &1))

    Repo.all(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.node_id in ^@post_nodes and p.status == :active and
            p.definition_id in ^ids and fragment("?->>'document_id' = ?", p.variables, ^id),
        select: t.instance_id,
        distinct: true
      ),
      prefix: prefix
    )
  end

  defp do_cancel(prefix, view, issued, reason, actor) do
    args = %{document_id: view.id, version_no: issued.version_no, reason: reason}

    case Documents.cancel(prefix, args, actor) do
      {:ok, version} -> {:ok, version}
      {:error, :not_issued} -> {:error, :document_not_issued}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:unprocessable, reason}} -> {:error, {:unprocessable, reason}}
      {:error, :busy} -> {:error, :busy}
      {:error, other} -> {:error, log_internal(other)}
    end
  end

  defp log_internal(reason) do
    Logger.warning("stock cancel refused: #{inspect(tag(reason))}")
    :internal
  end

  # -- marks, tasks, entries ----------------------------------------------------------------------

  @doc "The live marks of the documents `ids`: `%{doc_id => %{\"posted\" => m, \"reversed\" => m}}`."
  @spec marks(String.t(), [String.t()]) :: map()
  def marks(_prefix, []), do: %{}

  def marks(prefix, ids) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^@mark_type and not r.deleted and
            fragment("?->>'document_id' = ANY(?)", r.field_values, type(^ids, {:array, :string})),
        select: {r.record_id, r.field_values, r.inserted_at}
      )

    prefix
    |> then(&Repo.all(query, prefix: &1))
    |> Enum.reduce(%{}, fn {record_id, fv, at}, acc ->
      mark = %{record_id: record_id, at: at}
      Map.update(acc, fv["document_id"], %{fv["mark"] => mark}, &Map.put(&1, fv["mark"], mark))
    end)
  end

  @doc """
  Which post / reverse tasks of the document's active instances are pending (`post` is true while a
  receipt `post`, an opening `submit` or an opening `approve` task is pending).
  """
  @spec pending(String.t(), String.t()) :: %{post: boolean(), reverse: boolean()}
  def pending(prefix, id) do
    ids =
      Enum.flat_map(
        Kinds.definition_names() ++ [@reversal_definition, @count_definition],
        &definition_ids(prefix, &1)
      )

    nodes =
      Repo.all(
        from(t in Task,
          join: p in InstanceProjection,
          on: p.instance_id == t.instance_id,
          where:
            t.status == :pending and t.node_id in ^["reverse" | @post_nodes] and
              p.status == :active and
              p.definition_id in ^ids and fragment("?->>'document_id' = ?", p.variables, ^id),
          select: t.node_id
        ),
        prefix: prefix
      )

    %{post: Enum.any?(@post_nodes, &(&1 in nodes)), reverse: "reverse" in nodes}
  end

  @doc false
  def completer(prefix, id, node) do
    case completer_row(prefix, id, node) do
      {completed_by, _output} -> completed_by
      nil -> nil
    end
  end

  # `{completed_by, output_variables}` of the latest completed task of `node`, or nil.
  defp completer_row(prefix, id, node) do
    Repo.one(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :completed and t.node_id == ^node and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [desc: t.completed_at],
        limit: 1,
        select: {t.completed_by, t.output_variables}
      ),
      prefix: prefix
    )
  end

  @doc """
  REQ-860: cancels the pending reversal instance of document `id` (the shared access calls it when
  the ledger refused the reversal, so a retry is not stuck on `reversal_pending`). `:ok` or `:error`.
  """
  @spec withdraw_reversal(String.t(), String.t(), String.t()) :: :ok | :error
  def withdraw_reversal(prefix, id, actor) do
    ids = definition_ids(prefix, @reversal_definition)
    # bound as `^node`, like `pending_task_id/3`: this function cancels, it never completes a task
    # (the T-SEC-3e scan of this file counts only literal `node_id == "..."` completions)
    node = "reverse"

    instance_ids =
      Repo.all(
        from(t in Task,
          join: p in InstanceProjection,
          on: p.instance_id == t.instance_id,
          where:
            t.status == :pending and t.node_id == ^node and p.status == :active and
              p.definition_id in ^ids and fragment("?->>'document_id' = ?", p.variables, ^id),
          select: t.instance_id,
          distinct: true
        ),
        prefix: prefix
      )

    Enum.reduce_while(instance_ids, :ok, fn instance_id, :ok ->
      attrs = %{actor_id: actor, idempotency_key: "stock-withdraw-rev:#{instance_id}"}

      case Engine.cancel_instance(instance_id, attrs, prefix: prefix) do
        {:ok, _} -> {:cont, :ok}
        _other -> {:halt, :error}
      end
    end)
  end

  @doc """
  REQ-860: the id of the pending task of `node` ("post", "reverse", or REQ-912 "approve" for a quick
  count) of the active instance of document `id`, or nil. The shared access completes it itself
  (`Letflow.Modules.Stock.OldAppWrites`).
  """
  @spec pending_task_id(String.t(), String.t(), String.t()) :: String.t() | nil
  def pending_task_id(prefix, id, node) when node in ["post", "reverse"],
    do: pending_node_task(prefix, id, node, Kinds.definition_names() ++ [@reversal_definition])

  # REQ-912: the approval of the quick count the old address just made, in no other process.
  def pending_task_id(prefix, id, "approve"),
    do: pending_node_task(prefix, id, "approve", [Kinds.get("quick_count").definition])

  @doc """
  T-2410 (owner D-164): the system completes the pending `approve` task of quick count `id`, the
  counter's OWN count, with the counter as the actor and the literal credential `:system_self_approval`.
  `Letflow.Engine.SeparationOfDuties` lets that credential through only on `stock_quick_count` /
  `approve` with the tenant's switch stored OFF (it re-reads the setting under the task lock), and
  the engine audits `task.self_approved`, "self-approved, four-eyes off", exactly as for the old
  Qoimeks address. The caller (`Documents.quick_count/4`) has read the switch and passes only the
  document it just made. `:ok`, `{:error, :no_pending_task}` or the engine's own refusal (a switch
  turned ON in between is `{:error, :separation_of_duties}`).
  """
  @spec self_approve_count(String.t(), String.t(), String.t()) ::
          :ok | {:error, :no_pending_task} | {:error, term()}
  def self_approve_count(prefix, id, actor_id) do
    case pending_task_id(prefix, id, "approve") do
      nil ->
        {:error, :no_pending_task}

      task_id ->
        attrs = %{
          output_variables: %{},
          actor_id: actor_id,
          idempotency_key: "stock-self-approve:#{task_id}"
        }

        case Engine.complete_task(task_id, attrs,
               prefix: prefix,
               credential: :system_self_approval
             ) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp pending_node_task(prefix, id, node, definition_names) do
    ids = Enum.flat_map(definition_names, &definition_ids(prefix, &1))

    Repo.one(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.node_id == ^node and p.status == :active and
            p.definition_id in ^ids and fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [desc: t.inserted_at],
        limit: 1,
        select: t.id
      ),
      prefix: prefix
    )
  end

  @doc """
  REQ-912 (decision 0091, the old app's count rows): `%{document_id => %{content, issued_at}}` of the
  live issued version of each quick count document in `ids` (a document of another type is left out).
  `content` is the frozen content (`"header"`, `"lines"` with `counted_quantity`); the old address shows
  the counted quantity as the `qty` of a count row, and answers a count equal to the book (no ledger
  entry) from it. One query; the tenant is `prefix` only.
  """
  @spec count_contents(String.t(), [String.t()]) :: %{String.t() => map()}
  def count_contents(_prefix, []), do: %{}

  def count_contents(prefix, ids) when is_list(ids) do
    type_key = Kinds.get("quick_count").type_key

    query =
      from(v in DocumentVersion,
        join: d in Document,
        on: d.id == v.document_id,
        where: v.document_id in ^ids and v.status == :issued and d.type_key == ^type_key,
        order_by: [asc: v.version_no],
        select: {v.document_id, %{content: v.content, issued_at: v.issued_at}}
      )

    prefix |> then(&Repo.all(query, prefix: &1)) |> Map.new()
  end

  @doc false
  def entries(authorized, id) do
    case Ledger.entries(authorized, %{"document_id" => id}, %{limit: 100}) do
      {:ok, %{rows: rows, next_cursor: nil}} -> {:ok, rows}
      {:ok, %{rows: _rows}} -> :truncated
      {:error, _reason} -> :error
    end
  end

  # -- read side ----------------------------------------------------------------------------------

  @doc """
  The posting fields of one document view: `posted_at, posted_by, posted_by_label, entry_id,
  reversed_at, reversed_by, reversed_by_label, posting_check` (the `*_label` fields are display-only names, `ActorLabel`), and the derived `state` for a live version status. `authorized` is
  the caller's ledger read authorization (or `nil`: `posting_check` is then `nil`).
  """
  @spec state_fields(String.t(), map(), term()) :: map()
  def state_fields(prefix, base, authorized) do
    marks = marks(prefix, [base.id]) |> Map.get(base.id, %{})
    state = base.state |> derive_state(marks) |> confirmed(base)
    rows = if authorized, do: entries(authorized, base.id), else: :error
    kind = Kinds.get(base.kind)
    receipt = receipt_row(rows, Kinds.causes(kind))
    posted = if(marks["posted"], do: completer_row(prefix, base.id, kind.completion_node))
    reversed = if(marks["reversed"], do: completer_row(prefix, base.id, "reverse"))
    posted_by = posted && elem(posted, 0)
    reversed_by = reversed && elem(reversed, 0)
    shared = SharedStockAccess.shared_actors(prefix, [posted_by, reversed_by])

    %{
      state: state,
      posted_at: marks |> Map.get("posted") |> mark_at(),
      posted_by: posted_by,
      posted_by_label: actor_label(prefix, posted, shared),
      posted_via_shared_access: via_shared?(posted_by, shared),
      entry_id: receipt && receipt.entry_id,
      reversed_at: marks |> Map.get("reversed") |> mark_at(),
      reversed_by: reversed_by,
      reversed_by_label: actor_label(prefix, reversed, shared),
      reversed_via_shared_access: via_shared?(reversed_by, shared),
      posting_check: posting_check(base, state, marks, rows, prefix, kind)
    }
  end

  # REQ-860 (decision 0091 section 5): a step completed through the shared stock access shows the typed
  # operator name in place of a person's name. The name is read only when the completer IS a shared
  # access actor of this tenant; a personal account that sends an `operator` output variable never
  # gets it shown.
  defp actor_label(_prefix, nil, _shared), do: nil

  defp actor_label(prefix, {completed_by, output}, shared) do
    if via_shared?(completed_by, shared),
      do: operator_text(output),
      else: ActorLabel.label(prefix, completed_by)
  end

  defp via_shared?(nil, _shared), do: false
  defp via_shared?(actor, shared), do: MapSet.member?(shared, actor)

  defp operator_text(%{"operator" => name}) when is_binary(name), do: name
  defp operator_text(_output), do: nil

  @doc """
  REQ-860: `%{{document_id, :posted | :reversed} => operator}` for the documents `ids`: the typed
  operator name of the live post and reverse tasks completed by a shared stock access actor of this
  tenant. Documents posted by a personal account have no entry. One query for the tasks and one for
  the actors.
  """
  @spec shared_operators(String.t(), [String.t()]) :: %{
          {String.t(), :posted | :reversed} => String.t()
        }
  def shared_operators(_prefix, []), do: %{}

  def shared_operators(prefix, ids) when is_list(ids) do
    nodes = ["reverse" | @post_nodes]

    rows =
      Repo.all(
        from(t in Task,
          join: p in InstanceProjection,
          on: p.instance_id == t.instance_id,
          where:
            t.status == :completed and t.node_id in ^nodes and
              fragment("?->>'document_id' = ANY(?)", p.variables, type(^ids, {:array, :string})),
          order_by: [asc: t.completed_at],
          select:
            {fragment("?->>'document_id'", p.variables), t.node_id, t.completed_by,
             t.output_variables}
        ),
        prefix: prefix
      )

    shared = SharedStockAccess.shared_actors(prefix, Enum.map(rows, &elem(&1, 2)))

    Enum.reduce(rows, %{}, fn {doc, node, by, output}, acc ->
      with true <- via_shared?(by, shared),
           name when is_binary(name) <- operator_text(output) do
        Map.put(acc, {doc, if(node == "reverse", do: :reversed, else: :posted)}, name)
      else
        _other -> acc
      end
    end)
  end

  defp derive_state("issued", marks) do
    cond do
      Map.has_key?(marks, "reversed") -> "reversed"
      Map.has_key?(marks, "posted") -> "posted"
      true -> "issued"
    end
  end

  defp derive_state(state, _marks), do: state

  # REQ-854: an issued quick count whose difference is zero posts nothing and reads `confirmed`.
  # REQ-885: multi-line quick count (workbook load) confirms only when ALL lines have zero difference.
  defp confirmed("issued", %{kind: "quick_count", lines: lines}) when lines != [] do
    if Enum.all?(lines, &Decimal.eq?(Decimal.new(&1.difference), 0)),
      do: "confirmed",
      else: "issued"
  end

  defp confirmed(state, _base), do: state

  defp mark_at(nil), do: nil

  defp mark_at(%{at: at}), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "The derived state of each document of a page: `%{doc_id => state}` for the given rows."
  @spec states_for(String.t(), [map()]) :: map()
  def states_for(prefix, rows) do
    marks = marks(prefix, Enum.map(rows, & &1.id))
    Map.new(rows, &{&1.id, derive_state(&1.state, Map.get(marks, &1.id, %{}))})
  end

  defp receipt_row({:ok, rows}, causes) do
    case Enum.filter(rows, &(&1.cause in causes)) do
      [one] -> one
      _none_or_many -> nil
    end
  end

  defp receipt_row(_unavailable, _cause), do: nil

  defp posting_check(_base, _state, _marks, :error, _prefix, _kind), do: nil
  # More than one page of entries for one document cannot happen without a flood.
  defp posting_check(_base, _state, _marks, :truncated, _prefix, _kind), do: "mismatch"

  defp posting_check(base, state, marks, {:ok, rows}, prefix, kind) do
    receipts = Enum.filter(rows, &(&1.cause in Kinds.causes(kind)))
    reversals = Enum.filter(rows, &(&1.cause == "reversal"))

    cond do
      state == "cancelled" ->
        if Enum.all?(receipts, fn r ->
             Enum.any?(reversals, &(&1.reverses_entry_id == r.entry_id))
           end),
           do: "ok",
           else: "mismatch"

      rows == [] and marks == %{} ->
        nil

      state == "draft" ->
        "mismatch"

      true ->
        if consistent?(base, state, marks, receipts, reversals, {prefix, kind}),
          do: "ok",
          else: "mismatch"
    end
  end

  defp consistent?(base, state, marks, receipts, reversals, {prefix, kind}) do
    case receipts do
      [receipt] ->
        Legs.ledger_match?(receipt, expected_legs(prefix, base, receipt)) and
          online_time?(kind, receipt) and
          Map.has_key?(marks, "posted") and
          reversal_consistent?(state, marks, receipt, reversals)

      _none_or_many ->
        false
    end
  end

  # REQ-726: an opening has no client time, so its event time IS its posting time.
  defp online_time?(%{kind: kind}, entry) when kind in ["opening", "quick_count"],
    do: same_instant?(Map.get(entry, :event_time), Map.get(entry, :posting_time))

  defp online_time?(_kind, _entry), do: true

  defp same_instant?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_instant?(_a, _b), do: false

  defp reversal_consistent?("reversed", marks, receipt, [reversal]),
    do: Map.has_key?(marks, "reversed") and reversal.reverses_entry_id == receipt.entry_id

  defp reversal_consistent?("reversed", _marks, _receipt, _reversals), do: false

  defp reversal_consistent?(_state, marks, _receipt, reversals),
    do: reversals == [] and not Map.has_key?(marks, "reversed")

  # Expected legs from the frozen content (REQ-903: the comparison lives in `Legs`, which
  # `post_document` calls too, so the read side and the posting check cannot disagree). A zero leg of
  # count_set is the old Qoimeks empty-shelf movement; its expected zero leg is included here too.
  defp expected_legs(prefix, base, receipt) do
    case issued(prefix, base.id) do
      %{content: content} ->
        record_zero =
          base.kind == "quick_count" and receipt.legs != [] and
            Enum.all?(receipt.legs, &Decimal.eq?(&1.quantity, 0))

        Legs.expected(Kinds.get(base.kind), content, record_zero)

      _none ->
        :none
    end
  end
end
