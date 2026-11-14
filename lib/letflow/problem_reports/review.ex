defmodule Letflow.ProblemReports.Review do
  @moduledoc """
  T-1963 part A: the owner list in the platform company. An item is a `problem_reports` row of class
  `review` (title in `text`, `owner_ref` O-nnn, no reporting user); its thread is `problem_report_comments`
  and its screenshots `problem_report_comment_images`. Everything is read and written ONLY in the platform
  company's schema (`Letflow.PlatformTenant.platform_prefix/0`, server configuration, never the request).

  ## Rules

    * R1 an owner entry is a `finding` (text 0..4000 and 0..6 PNG/JPEG images, not both empty);
    * R2 an owner entry on a `ready` item starts the next cycle (`cycle + 1`, the entry carries it);
    * R3 after an owner entry the item is `owner_reviewed`;
    * R4 the owner may set `waiting` or `closed` (optional note, stored as an owner `note` entry);
    * R5 a `closed` item is read-only (`{:error, :item_closed}`, HTTP 409);
    * R6 free text that looks like a secret is refused and never echoed.

  The team-side writes, the ready rule and its notification are part B. `owner_transition/2` is the pure
  table of R2..R5. Writes lock the item row (`FOR UPDATE`) so two taps from a phone serialise, and write an
  audit entry with counts only (never text or bytes); an audit failure rolls the write back.

  The import (`import/1`) reads the JSON of the lab list (`format: "letflow-owner-list"`), validates every
  item first and then writes in one transaction; an item whose `owner_ref` exists is skipped untouched.
  """

  import Ecto.Query
  require Logger

  alias Letflow.{Audit, PlatformTenant, Repo, TenantProvisioning}
  alias Letflow.ProblemReports.{Comment, CommentImage, Report}

  @open_states ~w(for_review waiting owner_reviewed in_work ready)
  @all_states @open_states ++ ["closed"]
  @lab_states %{
    "for-review" => "for_review",
    "waiting" => "waiting",
    "owner-reviewed" => "owner_reviewed",
    "in-work" => "in_work",
    "ready" => "ready",
    "closed" => "closed"
  }
  @kinds ~w(review question decision communication subscription)
  @authors ~w(owner operator pm)
  @types ~w(finding answer note ready)
  @max_text 4000
  @max_image 5_242_880
  @max_images 6
  @max_items 500
  @max_thread 500
  @secret ~r/(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S{6,}/i

  @doc "The six states of an item, snake case."
  def states, do: @all_states

  @doc """
  Pure table of R2..R5 for the owner. `action` is `:finding`, `"waiting"` or `"closed"`.
  """
  @spec owner_transition(String.t(), :finding | String.t()) ::
          {:ok, String.t()}
          | {:ok, String.t(), :same_cycle | :next_cycle}
          | {:error, :item_closed | {:invalid, String.t()}}
  def owner_transition("closed", action) when action in [:finding, "waiting", "closed"],
    do: {:error, :item_closed}

  def owner_transition("ready", :finding), do: {:ok, "owner_reviewed", :next_cycle}

  def owner_transition(state, :finding) when state in @open_states,
    do: {:ok, "owner_reviewed", :same_cycle}

  def owner_transition(state, action)
      when state in @open_states and action in ["waiting", "closed"],
      do: {:ok, action}

  def owner_transition(_state, _action), do: {:error, {:invalid, "state"}}

  @doc "True when owner-written text looks like it holds a secret (R6)."
  def secret_shaped?(text) when is_binary(text), do: Regex.match?(@secret, text)
  def secret_shaped?(_), do: false

  # ── Reads ────────────────────────────────────────────────────────────────

  @doc "Newest first, keyset-paged review summaries. `params` are the query params of the list route."
  def list(params) do
    with {:ok, prefix} <- prefix(),
         {:ok, states} <- filter(Map.get(params, "status", "open")),
         {:ok, limit} <- integer(Map.get(params, "limit", "50"), 1, 100),
         {:ok, before} <- before_seq(Map.get(params, "before")) do
      query =
        from(r in Report, where: r.class == "review", order_by: [desc: r.seq], limit: ^limit)

      query = if states == [], do: query, else: from(r in query, where: r.status in ^states)
      query = if before, do: from(r in query, where: r.seq < ^before), else: query
      rows = Repo.all(query, prefix: prefix)
      stats = entry_stats(prefix, Enum.map(rows, & &1.id))
      next = if length(rows) == limit, do: List.last(rows).seq, else: nil

      {:ok, %{"reports" => Enum.map(rows, &summary(&1, stats)), "next_before" => next}}
    end
  rescue
    error -> internal(error)
  end

  defp filter("open"), do: {:ok, @open_states}
  defp filter("closed"), do: {:ok, ["closed"]}
  defp filter("all"), do: {:ok, []}
  defp filter(_), do: {:error, :invalid_query}

  defp before_seq(nil), do: {:ok, nil}
  defp before_seq(value), do: integer(value, 1, 9_223_372_036_854_775_807)

  defp integer(value, low, high) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= low and n <= high -> {:ok, n}
      _ -> {:error, :invalid_query}
    end
  end

  defp integer(_, _, _), do: {:error, :invalid_query}

  @doc "The detail of one review item with its thread. 404 for any other class."
  def get(id) do
    with {:ok, prefix} <- prefix(), {:ok, id} <- cast_id(id) do
      detail(prefix, id)
    end
  rescue
    error -> internal(error)
  end

  @doc "The bytes of one image of one item; one query keyed by item and image (INV-5)."
  def image(id, image_id) do
    with {:ok, prefix} <- prefix(),
         {:ok, id} <- cast_id(id),
         {:ok, image_id} <- cast_id(image_id) do
      query =
        from(i in CommentImage,
          join: r in Report,
          on: r.id == i.report_id,
          where: i.id == ^image_id and i.report_id == ^id and r.class == "review",
          select: %{content_type: i.content_type, bytes: i.bytes}
        )

      case Repo.one(query, prefix: prefix) do
        nil -> {:error, :not_found}
        image -> {:ok, image}
      end
    end
  rescue
    error -> internal(error)
  end

  defp detail(prefix, id) do
    case Repo.one(from(r in Report, where: r.id == ^id and r.class == "review"), prefix: prefix) do
      nil ->
        {:error, :not_found}

      %Report{} = item ->
        comments =
          Repo.all(from(c in Comment, where: c.report_id == ^id, order_by: [asc: c.seq]),
            prefix: prefix
          )

        images =
          from(i in CommentImage,
            where: i.report_id == ^id,
            order_by: [asc: i.position],
            select: %{
              id: i.id,
              comment_id: i.comment_id,
              content_type: i.content_type,
              byte_size: i.byte_size
            }
          )
          |> Repo.all(prefix: prefix)
          |> Enum.group_by(& &1.comment_id)

        stats = %{
          item.id => %{count: length(comments), last: comments |> List.last() |> last_at()}
        }

        {:ok,
         summary(item, stats)
         |> Map.merge(%{
           "steps" => item.steps,
           "why" => item.why,
           "tasks" => item.tasks,
           "recommended" => item.recommended,
           "answer" => item.answer,
           "source" => item.source,
           "thread" => Enum.map(comments, &comment_map(&1, Map.get(images, &1.id, [])))
         })}
    end
  end

  defp last_at(nil), do: nil
  defp last_at(%Comment{inserted_at: at}), do: at

  defp entry_stats(_prefix, []), do: %{}

  defp entry_stats(prefix, ids) do
    from(c in Comment,
      where: c.report_id in ^ids,
      group_by: c.report_id,
      select: {c.report_id, %{count: count(c.id), last: max(c.inserted_at)}}
    )
    |> Repo.all(prefix: prefix)
    |> Map.new()
  end

  defp summary(%Report{} = r, stats) do
    stat = Map.get(stats, r.id, %{count: 0, last: nil})

    %{
      "id" => r.id,
      "number" => r.owner_ref,
      "class" => "review",
      "status" => r.status,
      "kind" => r.kind,
      "title" => r.text,
      "due" => r.due,
      "cycle" => r.cycle,
      "added_at" => r.consented_at,
      "closed_at" => r.closed_at,
      "entries" => stat.count,
      "last_entry_at" => stat.last
    }
  end

  defp comment_map(%Comment{} = c, images) do
    %{
      "id" => c.id,
      "author" => c.author,
      "type" => c.type,
      "text" => c.text,
      "tasks" => c.tasks,
      "lesson" => c.lesson,
      "cycle" => c.cycle,
      "created_at" => c.inserted_at,
      "images" =>
        Enum.map(
          images,
          &%{"id" => &1.id, "content_type" => &1.content_type, "byte_size" => &1.byte_size}
        )
    }
  end

  # ── Owner writes ─────────────────────────────────────────────────────────

  @doc """
  The owner adds a finding (R1..R3). `params` is `%{"text" => ..., "images" => [%Plug.Upload{}]}`.
  """
  def add_owner_entry(id, params, actor_user_id) when is_map(params) do
    with {:ok, prefix} <- prefix(),
         {:ok, id} <- cast_id(id),
         {:ok, text} <- clean(Map.get(params, "text"), "text", @max_text),
         {:ok, images} <- read_uploads(Map.get(params, "images")),
         :ok <- not_empty(text, images) do
      locked(prefix, id, fn item ->
        with {:ok, status, cycle_rule} <- owner_transition(item.status, :finding) do
          cycle = if cycle_rule == :next_cycle, do: item.cycle + 1, else: item.cycle

          stored =
            item
            |> Ecto.Changeset.change(%{status: status, cycle: cycle})
            |> Repo.update!(prefix: prefix)

          insert_entry!(prefix, stored, %{
            author: "owner",
            author_user_id: actor_user_id,
            type: "finding",
            text: text,
            cycle: cycle,
            images: images
          })

          audit!(prefix, actor_user_id, "owner_item.entry_added", item, %{
            "type" => "finding",
            "from_status" => item.status,
            "to_status" => status,
            "cycle" => cycle,
            "text_length" => String.length(text),
            "images" => length(images)
          })

          {:ok, stored}
        end
      end)
    end
  end

  def add_owner_entry(_id, _params, _actor), do: {:error, {:invalid, "text"}}

  @doc "The owner sets `waiting` (\"Not now\") or `closed` (\"Approve / done\") with an optional note (R4)."
  def set_owner_state(id, body, actor_user_id) when is_map(body) do
    state = Map.get(body, "state")

    with {:ok, prefix} <- prefix(),
         {:ok, id} <- cast_id(id),
         :ok <- check_state(state),
         {:ok, text} <- clean(Map.get(body, "text"), "text", @max_text) do
      locked(prefix, id, fn item ->
        with {:ok, status} <- owner_transition(item.status, state) do
          closed_at = if status == "closed", do: DateTime.utc_now(), else: item.closed_at

          stored =
            item
            |> Ecto.Changeset.change(%{status: status, closed_at: closed_at})
            |> Repo.update!(prefix: prefix)

          if text != "" do
            insert_entry!(prefix, stored, %{
              author: "owner",
              author_user_id: actor_user_id,
              type: "note",
              text: text,
              cycle: item.cycle,
              images: []
            })
          end

          audit!(prefix, actor_user_id, "owner_item.state_set", item, %{
            "from_status" => item.status,
            "to_status" => status,
            "cycle" => item.cycle,
            "text_length" => String.length(text),
            "images" => 0
          })

          {:ok, stored}
        end
      end)
    end
  end

  def set_owner_state(_id, _body, _actor), do: {:error, {:invalid, "state"}}

  defp check_state(state) when state in ["waiting", "closed"], do: :ok
  defp check_state(_state), do: {:error, {:invalid, "state"}}

  defp locked(prefix, id, fun) do
    result =
      Repo.transaction(fn ->
        item =
          Repo.one(
            from(r in Report, where: r.id == ^id and r.class == "review", lock: "FOR UPDATE"),
            prefix: prefix
          )

        if is_nil(item), do: Repo.rollback(:not_found)

        case fun.(item) do
          {:ok, stored} -> stored
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, stored} -> detail(prefix, stored.id)
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> internal(error)
  end

  defp insert_entry!(prefix, item, attrs) do
    comment =
      Repo.insert!(
        %Comment{
          tenant_id: item.tenant_id,
          report_id: item.id,
          author: attrs.author,
          author_user_id: Map.get(attrs, :author_user_id),
          type: attrs.type,
          text: attrs.text,
          tasks: Map.get(attrs, :tasks, ""),
          lesson: Map.get(attrs, :lesson, ""),
          cycle: attrs.cycle,
          forwarded: Map.get(attrs, :forwarded, false),
          inserted_at: Map.get(attrs, :at) || DateTime.utc_now()
        },
        prefix: prefix
      )

    attrs.images
    |> Enum.with_index(1)
    |> Enum.each(fn {{type, bytes}, position} ->
      Repo.insert!(
        %CommentImage{
          tenant_id: item.tenant_id,
          report_id: item.id,
          comment_id: comment.id,
          position: position,
          content_type: type,
          byte_size: byte_size(bytes),
          bytes: bytes,
          inserted_at: comment.inserted_at
        },
        prefix: prefix
      )
    end)

    comment
  end

  defp audit!(prefix, actor_id, action, item, after_state) do
    entry = %{
      actor_id: actor_id,
      action: action,
      resource_type: "owner_item",
      resource_id: item.owner_ref,
      before_state: nil,
      after_state: Map.put(after_state, "owner_ref", item.owner_ref)
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> Repo.rollback(:internal)
    end
  end

  # ── Text and images ──────────────────────────────────────────────────────

  @doc false
  def clean(nil, _field, _max), do: {:ok, ""}

  def clean(text, field, max) when is_binary(text) do
    text = String.trim(text)

    cond do
      not String.valid?(text) -> {:error, {:invalid, field}}
      length(String.codepoints(text)) > max -> {:error, {:invalid, field}}
      secret_shaped?(text) -> {:error, :secret}
      true -> {:ok, text}
    end
  end

  def clean(_other, field, _max), do: {:error, {:invalid, field}}

  defp not_empty("", []), do: {:error, {:invalid, "text"}}
  defp not_empty(_text, _images), do: :ok

  defp read_uploads(nil), do: {:ok, []}
  defp read_uploads(%Plug.Upload{} = upload), do: read_uploads([upload])

  defp read_uploads(list) when is_list(list) and length(list) <= @max_images do
    Enum.reduce_while(list, {:ok, []}, fn
      %Plug.Upload{path: path}, {:ok, acc} ->
        case read_image(path) do
          {:ok, image} -> {:cont, {:ok, acc ++ [image]}}
          {:error, _} = error -> {:halt, error}
        end

      _other, _acc ->
        {:halt, {:error, {:invalid, "images"}}}
    end)
  end

  defp read_uploads(_other), do: {:error, {:invalid, "images"}}

  defp read_image(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         true <- size <= @max_image || {:error, :image_too_large},
         {:ok, bytes} <- File.read(path) do
      sniff(bytes)
    else
      {:error, :image_too_large} = error -> error
      _ -> {:error, {:invalid, "images"}}
    end
  end

  # The type comes from the first bytes only; the client's content type and file name are ignored.
  defp sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>> = bytes),
    do: {:ok, {"image/png", bytes}}

  defp sniff(<<0xFF, 0xD8, 0xFF, _::binary>> = bytes), do: {:ok, {"image/jpeg", bytes}}
  defp sniff(_), do: {:error, :bad_image_type}

  # ── Import ───────────────────────────────────────────────────────────────

  @doc """
  Imports the JSON document of the lab list. `{:ok, %{"imported" => [...], "skipped" => [...]}}`,
  `{:error, {:invalid_import, message}}` (path and rule, never a value) or `{:error, :unavailable | :internal}`.
  """
  def import(doc) do
    with {:ok, prefix} <- prefix(),
         {:ok, tenant_id} <- platform_tenant_id(prefix),
         {:ok, items} <- parse_document(doc) do
      write_import(prefix, tenant_id, items)
    end
  rescue
    error -> internal(error)
  end

  defp parse_document(%{"format" => "letflow-owner-list", "version" => 1, "items" => items})
       when is_list(items) and items != [] and length(items) <= @max_items do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case parse_item(raw, index) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, message} -> {:halt, bad(message)}
      end
    end)
    |> case do
      {:ok, parsed} ->
        parsed = Enum.reverse(parsed)
        refs = Enum.map(parsed, & &1.owner_ref)

        if length(refs) == length(Enum.uniq(refs)),
          do: {:ok, Enum.sort_by(parsed, & &1.owner_ref)},
          else: bad("items: id must be unique")

      error ->
        error
    end
  end

  defp parse_document(%{"format" => "letflow-owner-list", "version" => 1}),
    do: bad("items: a list of 1 to #{@max_items} items")

  defp parse_document(_), do: bad("document: format letflow-owner-list, version 1")

  defp bad(message), do: {:error, {:invalid_import, message}}

  defp parse_item(raw, index) when is_map(raw) do
    ref = Map.get(raw, "id")

    label =
      if is_binary(ref) and Regex.match?(~r/\A[ -~]{1,16}\z/, ref),
        do: ref,
        else: "items[#{index}]"

    case parse_item_fields(raw) do
      {:ok, item} -> {:ok, item}
      {:error, message} -> {:error, "#{label} #{message}"}
    end
  end

  defp parse_item(_raw, index), do: {:error, "items[#{index}]: must be an object"}

  defp parse_item_fields(raw) do
    with {:ok, ref} <- match(raw, "id", ~r/\AO-[0-9]{3,6}\z/),
         {:ok, title} <- text_field(raw, "title", 1, 300),
         {:ok, kind} <- one_of(raw, "kind", @kinds),
         {:ok, steps} <- text_field(raw, "steps", 0, 4000),
         {:ok, why} <- text_field(raw, "why", 0, 1000),
         {:ok, recommended} <- text_field(raw, "recommended", 0, 2000),
         {:ok, answer} <- text_field(raw, "answer", 0, 4000),
         {:ok, source} <- text_field(raw, "source", 0, 64),
         {:ok, state} <- lab_state(raw),
         {:ok, added} <- epoch(raw, "added", true),
         {:ok, closed} <- epoch(raw, "closed", false),
         {:ok, due} <- due(raw),
         {:ok, cycle} <- int_range(raw, "cycle", 1, 1000),
         {:ok, tasks} <- tasks(raw),
         {:ok, thread} <- thread(raw, cycle) do
      {:ok,
       %{
         owner_ref: ref,
         title: title,
         kind: kind,
         steps: steps,
         why: why,
         recommended: recommended,
         answer: answer,
         source: source,
         status: state,
         added: added,
         closed: if(state == "closed", do: closed || added),
         due: due,
         cycle: cycle,
         tasks: tasks,
         thread: thread
       }}
    end
  end

  defp match(raw, key, regex) do
    case Map.get(raw, key) do
      v when is_binary(v) ->
        if Regex.match?(regex, v), do: {:ok, v}, else: {:error, "#{key}: wrong shape"}

      _ ->
        {:error, "#{key}: wrong shape"}
    end
  end

  defp text_field(raw, key, min, max, path \\ nil) do
    path = path || key

    case Map.get(raw, key) do
      nil when min == 0 ->
        {:ok, ""}

      v when is_binary(v) ->
        len = length(String.codepoints(v))

        cond do
          not String.valid?(v) -> {:error, "#{path}: must be text"}
          len < min or len > max -> {:error, "#{path}: length #{min}..#{max}"}
          secret_shaped?(v) -> {:error, "#{path}: looks like it holds a secret"}
          true -> {:ok, v}
        end

      _ ->
        {:error, "#{path}: must be text"}
    end
  end

  defp one_of(raw, key, allowed) do
    v = Map.get(raw, key)
    if v in allowed, do: {:ok, v}, else: {:error, "#{key}: not an allowed value"}
  end

  defp lab_state(raw) do
    case Map.fetch(@lab_states, Map.get(raw, "state")) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, "state: not an allowed value"}
    end
  end

  defp epoch(raw, key, required) do
    case Map.get(raw, key) do
      nil when not required -> {:ok, nil}
      n when is_number(n) and n > 0 and n < 4_102_444_800 -> {:ok, from_epoch(n)}
      _ -> {:error, "#{key}: must be epoch seconds"}
    end
  end

  defp from_epoch(n) do
    {:ok, at} = DateTime.from_unix(round(n * 1_000_000), :microsecond)
    at
  end

  defp due(raw) do
    case Map.get(raw, "due") do
      v when v in [nil, ""] ->
        {:ok, nil}

      v when is_binary(v) ->
        case Date.from_iso8601(v) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "due: must be YYYY-MM-DD"}
        end

      _ ->
        {:error, "due: must be YYYY-MM-DD"}
    end
  end

  defp int_range(raw, key, min, max) do
    case Map.get(raw, key) do
      n when is_integer(n) and n >= min and n <= max -> {:ok, n}
      _ -> {:error, "#{key}: integer #{min}..#{max}"}
    end
  end

  defp tasks(raw) do
    case Map.get(raw, "tasks", []) do
      list when is_list(list) and length(list) <= 50 ->
        if Enum.all?(list, &(is_binary(&1) and Regex.match?(~r/\AT-[0-9]+\z/, &1))),
          do: {:ok, list},
          else: {:error, "tasks: each T-number"}

      _ ->
        {:error, "tasks: a list of at most 50 T-numbers"}
    end
  end

  defp thread(raw, item_cycle) do
    case Map.get(raw, "thread", []) do
      list when is_list(list) and length(list) <= @max_thread ->
        list
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
          case entry_fields(entry, item_cycle, index) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, entries} -> {:ok, entries |> Enum.reverse() |> Enum.sort_by(& &1.order)}
          error -> error
        end

      _ ->
        {:error, "thread: a list of at most #{@max_thread} entries"}
    end
  end

  defp entry_fields(entry, item_cycle, index) when is_map(entry) do
    p = "thread[#{index}]"

    with {:ok, author} <- one_of_at(entry, "author", @authors, p),
         {:ok, type} <- one_of_at(entry, "type", @types, p),
         {:ok, text} <- text_field(entry, "text", 0, @max_text, "#{p}.text"),
         {:ok, tasks} <- text_field(entry, "tasks", 0, 500, "#{p}.tasks"),
         {:ok, lesson} <- text_field(entry, "lesson", 0, 2000, "#{p}.lesson"),
         {:ok, ts} <- epoch_at(entry, "ts", p),
         {:ok, cycle} <- cycle_at(entry, item_cycle, p),
         {:ok, images} <- images_at(entry, p) do
      forwarded = Map.get(entry, "forwarded") == true

      {:ok,
       %{
         order: if(is_integer(entry["id"]), do: entry["id"], else: index),
         author: author,
         type: type,
         text: text,
         tasks: tasks,
         lesson: lesson,
         at: ts,
         cycle: cycle,
         forwarded: forwarded,
         images: images
       }}
    end
  end

  defp entry_fields(_entry, _cycle, index), do: {:error, "thread[#{index}]: must be an object"}

  defp one_of_at(entry, key, allowed, p) do
    if Map.get(entry, key) in allowed,
      do: {:ok, Map.get(entry, key)},
      else: {:error, "#{p}.#{key}: not an allowed value"}
  end

  defp epoch_at(entry, key, p) do
    case epoch(entry, key, true) do
      {:ok, v} -> {:ok, v}
      {:error, _} -> {:error, "#{p}.#{key}: must be epoch seconds"}
    end
  end

  defp cycle_at(entry, item_cycle, p) do
    case Map.get(entry, "cycle") do
      n when is_integer(n) and n >= 1 and n <= item_cycle -> {:ok, n}
      _ -> {:error, "#{p}.cycle: integer 1..#{item_cycle}"}
    end
  end

  defp images_at(entry, p) do
    case Map.get(entry, "images", []) do
      list when is_list(list) and length(list) <= @max_images ->
        list
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {img, i}, {:ok, acc} ->
          case decode_image(img) do
            {:ok, image} -> {:cont, {:ok, acc ++ [image]}}
            {:error, rule} -> {:halt, {:error, "#{p}.images[#{i}]: #{rule}"}}
          end
        end)

      _ ->
        {:error, "#{p}.images: at most #{@max_images}"}
    end
  end

  defp decode_image(%{"data_base64" => data}) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, bytes} when byte_size(bytes) > @max_image ->
        {:error, "larger than 5 MiB"}

      {:ok, bytes} ->
        with({:error, :bad_image_type} <- sniff(bytes), do: {:error, "not PNG or JPEG"})

      :error ->
        {:error, "not valid base64"}
    end
  end

  defp decode_image(_), do: {:error, "needs data_base64"}

  defp write_import(prefix, tenant_id, items) do
    refs = Enum.map(items, & &1.owner_ref)

    result =
      Repo.transaction(fn ->
        existing =
          from(r in Report, where: r.owner_ref in ^refs, select: r.owner_ref)
          |> Repo.all(prefix: prefix)
          |> MapSet.new()

        {new, skipped} = Enum.split_with(items, &(not MapSet.member?(existing, &1.owner_ref)))
        Enum.each(new, &insert_item!(prefix, tenant_id, &1))

        counts = %{
          "imported" => length(new),
          "skipped" => length(skipped),
          "entries" => new |> Enum.map(&length(&1.thread)) |> Enum.sum(),
          "images" =>
            new |> Enum.flat_map(& &1.thread) |> Enum.map(&length(&1.images)) |> Enum.sum()
        }

        case Audit.insert_entry(
               Repo,
               %{
                 actor_id: nil,
                 action: "owner_list.imported",
                 resource_type: "owner_item",
                 resource_id: "import",
                 before_state: nil,
                 after_state: counts
               },
               prefix
             ) do
          {:ok, _} -> :ok
          {:error, _} -> Repo.rollback(:internal)
        end

        %{
          "imported" => Enum.map(new, & &1.owner_ref),
          "skipped" => Enum.map(skipped, & &1.owner_ref)
        }
      end)

    case result do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_item!(prefix, tenant_id, item) do
    stored =
      Repo.insert!(
        %Report{
          tenant_id: tenant_id,
          reporter_tenant_id: tenant_id,
          reporter_tenant_name: nil,
          reporter_user_id: nil,
          reporter_name: nil,
          reporter_roles: [],
          reporter_permissions: [],
          text: item.title,
          context: %{},
          consented_at: item.added,
          inserted_at: item.added,
          class: "review",
          owner_ref: item.owner_ref,
          kind: item.kind,
          steps: blank(item.steps),
          why: blank(item.why),
          recommended: blank(item.recommended),
          answer: blank(item.answer),
          source: blank(item.source),
          tasks: item.tasks,
          due: item.due,
          cycle: item.cycle,
          closed_at: item.closed,
          status: item.status
        },
        prefix: prefix
      )

    Enum.each(item.thread, fn entry -> insert_entry!(prefix, stored, entry) end)
  end

  defp blank(""), do: nil
  defp blank(v), do: v

  # ── Shared ───────────────────────────────────────────────────────────────

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp prefix do
    case PlatformTenant.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :unavailable}
    end
  end

  defp platform_tenant_id(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :unavailable}
    end
  end

  defp internal(error) do
    # INV-4/INV-8: the exception module only; a message could carry owner text.
    Logger.error("owner list operation failed: #{inspect(error.__struct__)}")
    {:error, :internal}
  end
end
