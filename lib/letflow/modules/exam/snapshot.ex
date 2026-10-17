defmodule Letflow.Modules.Exam.Snapshot do
  @moduledoc """
  GH #2682 / REQ-511 (PR a) -- the exam content snapshot taken when a session starts. Design:
  `lib/letflow/design/req511-exam-content-snapshot.md` (sections 4, 5, 7 and 17.2 are the contract
  for this module). Scoring and the autosave shape check read ONLY this snapshot for an
  `in_progress` session, never the live `exam`, `question` or `answer_option` rows.

  The snapshot is stored in the optional JSON field `session.exam_snapshot` (schema version 1,
  string keys throughout): `v`, `origin`, `taken_at`, `nonce`, `exam` (`exam_id`,
  `passing_score_pct` as a decimal STRING, `certificate_enabled`, `title`, `time_limit_minutes`),
  `order` (question ids in `sort_order`), `questions` (question id -> `type`,
  `correct_option_ids`, `likert_options`) and `digest`.

  ## Digest: accident detection only (design 17.3)

  `digest` is `"sha256:" <> lowercase hex` of `canonical_encode/1` over the snapshot WITHOUT the
  `digest` key. It is unkeyed and stored in the same restricted field as its nonce, so it detects
  accidents (a partial write, a carry-forward bug, a serializer difference). It does NOT detect a
  writer who recomputes it. The digest is computed over the DECODED value read back from the row
  (jsonb reorders keys), so it never depends on stored text.

  ## Typed grading errors

  Every failure is `{:error, {:grading_error, reason}}` (`t:grading_reason/0`): atoms and ids only,
  never values (INV-4/INV-5). Parsers are total: a bad stored string is a typed error, never a
  raise. There is NO default threshold and NO fallback of any kind.

  ## Scope of PR a

  This module has the pure builders and readers only. The late (in-flight) snapshot, the
  certificate facts and the cutover rule are PR b.
  """

  alias Decimal, as: D

  @snapshot_version 1
  @max_encoded_bytes 2_097_152
  @types ~w(single multiple truefalse likert shorttext)
  @origins ~w(start late late_certificate)
  @key_types ~w(single multiple truefalse)

  @type grading_reason ::
          :snapshot_missing
          | :snapshot_corrupt
          | :threshold_missing
          | :threshold_invalid
          | :exam_section_missing
          | {:question_item_missing, String.t()}
          | {:question_type_invalid, String.t()}
          | {:key_missing, String.t()}
          | :certificate_facts_missing
          | :snapshot_too_large

  @type grading_error :: {:grading_error, grading_reason()}

  @typedoc "The decoded snapshot map of design 4.1, string keys."
  @type snapshot :: %{optional(String.t()) => term()}

  @typedoc "One loaded answer option of a question, as read from the live rows at start."
  @type option_source :: %{
          id: String.t(),
          is_correct: term(),
          likert_weight: term(),
          likert_polarity: term()
        }

  @typedoc "One loaded question with its option rows (`type` is the stored string)."
  @type question_source :: %{type: term(), options: [option_source()]}

  @typedoc """
  What `build_from_resolved/4` needs besides the question set. `exam_id` and `taken_at` (the
  session's `started_at`) are passed in because the exam field values carry neither.
  """
  @type build_info :: %{
          required(:origin) => :start,
          required(:exam_id) => String.t(),
          required(:taken_at) => DateTime.t()
        }

  # -----------------------------------------------------------------------
  # Build (pure)
  # -----------------------------------------------------------------------

  @doc """
  Builds the snapshot taken in the create transaction (design 4.3 step 3). Pure: `exam_fv` is the
  exam record's field values, `items` maps question id -> `t:question_source/0` for the resolved
  set, `order` lists the question ids in `sort_order`.

  Validates the threshold and every item (design 7.2), so a broken authoring row fails the START
  instead of a later submit. Deviation from the 4.2 table, recorded in the PR: the fourth argument
  is a `t:build_info/0` map (origin plus the exam id and `taken_at`) instead of the bare origin,
  because those two values cannot be derived from the other arguments.
  """
  @spec build_from_resolved(
          exam_fv :: map(),
          items :: %{String.t() => question_source()},
          order :: [String.t()],
          build_info()
        ) :: {:ok, snapshot()} | {:error, grading_error()}
  def build_from_resolved(exam_fv, items, order, %{
        origin: :start,
        exam_id: exam_id,
        taken_at: %DateTime{} = taken_at
      })
      when is_map(exam_fv) and is_map(items) and is_list(order) do
    with {:ok, threshold} <- threshold_string(Map.get(exam_fv, "passing_score_pct")),
         {:ok, questions} <- build_items(order, items) do
      snapshot =
        %{
          "v" => @snapshot_version,
          "origin" => "start",
          "taken_at" => DateTime.to_iso8601(taken_at),
          "nonce" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          "exam" => exam_section(exam_fv, exam_id, threshold),
          "order" => order,
          "questions" => questions
        }
        |> put_digest()

      if byte_size(canonical_encode(snapshot)) > @max_encoded_bytes do
        grading_error(:snapshot_too_large)
      else
        {:ok, snapshot}
      end
    end
  end

  defp exam_section(exam_fv, exam_id, threshold) do
    %{"exam_id" => exam_id, "passing_score_pct" => threshold}
    |> Map.put("certificate_enabled", Map.get(exam_fv, "certificate_enabled"))
    |> put_present("title", Map.get(exam_fv, "title"))
    |> put_integer("time_limit_minutes", Map.get(exam_fv, "time_limit_minutes"))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_integer(map, key, value) when is_integer(value), do: Map.put(map, key, value)
  defp put_integer(map, _key, _other), do: map

  defp build_items(order, items) do
    order
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn question_id, {:ok, acc} ->
      case Map.fetch(items, question_id) do
        {:ok, source} ->
          case build_item(question_id, source) do
            {:ok, item} -> {:cont, {:ok, Map.put(acc, question_id, item)}}
            {:error, _reason} = error -> {:halt, error}
          end

        :error ->
          {:halt, grading_error({:question_item_missing, question_id})}
      end
    end)
  end

  defp build_item(question_id, %{type: type, options: options}) when is_list(options) do
    if type in @types do
      correct =
        options
        |> Enum.filter(&(&1.is_correct == true))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      with {:ok, likert} <- build_likert(question_id, type, options),
           :ok <- check_key(question_id, type, correct) do
        {:ok, %{"type" => type, "correct_option_ids" => correct, "likert_options" => likert}}
      end
    else
      grading_error({:question_type_invalid, question_id})
    end
  end

  defp build_item(question_id, _malformed), do: grading_error({:key_missing, question_id})

  defp check_key(question_id, type, []) when type in @key_types,
    do: grading_error({:key_missing, question_id})

  defp check_key(_question_id, _type, _correct), do: :ok

  defp build_likert(question_id, "likert", options) do
    if options == [] do
      grading_error({:key_missing, question_id})
    else
      Enum.reduce_while(options, {:ok, %{}}, fn option, {:ok, acc} ->
        with {:ok, weight} <- weight_string(option.likert_weight),
             {:ok, polarity} <- polarity_string(option.likert_polarity) do
          {:cont, {:ok, Map.put(acc, option.id, %{"weight" => weight, "polarity" => polarity})}}
        else
          :error -> {:halt, grading_error({:key_missing, question_id})}
        end
      end)
    end
  end

  defp build_likert(_question_id, _type, _options), do: {:ok, %{}}

  defp weight_string(value) do
    case normalize_number(value) do
      {:ok, decimal} -> {:ok, D.to_string(decimal, :normal)}
      :error -> :error
    end
  end

  defp polarity_string(value) when value in ["positive", "negative"], do: {:ok, value}
  defp polarity_string(_other), do: :error

  defp threshold_string(nil), do: grading_error(:threshold_missing)

  defp threshold_string(value) do
    with {:ok, decimal} <- threshold_decimal(value) do
      {:ok, D.to_string(decimal, :normal)}
    end
  end

  # nil is handled by the caller; everything else unparsable or out of range is :threshold_invalid.
  defp threshold_decimal(value) do
    case normalize_number(value) do
      {:ok, decimal} ->
        if D.compare(decimal, 0) != :lt and D.compare(decimal, 100) != :gt,
          do: {:ok, decimal},
          else: grading_error(:threshold_invalid)

      :error ->
        grading_error(:threshold_invalid)
    end
  end

  @doc """
  The stored-number rule of design 17.2: converts an integer, float, `Decimal` or numeric string
  to a normalised, finite `Decimal` (so `60`, `60.0` and `"60.00"` all become `60`), or `:error`.
  Total: never raises.
  """
  @spec normalize_number(term()) :: {:ok, D.t()} | :error
  def normalize_number(value) do
    case to_decimal(value) do
      {:ok, %D{coef: coef} = decimal} when is_integer(coef) ->
        # Bound the size BEFORE any rendering, so "1e999999999" can never build a huge string.
        if bounded?(decimal) do
          normalized = if D.eq?(decimal, 0), do: D.new(0), else: D.normalize(decimal)
          {:ok, normalized}
        else
          :error
        end

      _non_finite_or_error ->
        :error
    end
  rescue
    _error -> :error
  end

  # At most @max_digits integer digits and @max_digits fractional digits: far beyond any real
  # threshold or likert weight, and small enough that `to_string(:normal)` stays tiny.
  @max_digits 40

  defp bounded?(%D{coef: coef, exp: exp}) do
    digits = coef |> Integer.digits() |> length()
    exp >= -@max_digits and digits + exp <= @max_digits
  end

  defp to_decimal(value) when is_integer(value), do: {:ok, D.new(value)}
  defp to_decimal(value) when is_float(value), do: {:ok, D.from_float(value)}
  defp to_decimal(%D{} = value), do: {:ok, value}

  defp to_decimal(value) when is_binary(value) do
    case D.parse(value) do
      {%D{} = decimal, ""} -> {:ok, decimal}
      _partial_or_error -> :error
    end
  end

  defp to_decimal(_other), do: :error

  # -----------------------------------------------------------------------
  # Read
  # -----------------------------------------------------------------------

  @doc """
  Structural validation plus digest verification. Used by scoring (design 5.1).
  """
  @spec fetch_verified(session_field_values :: map()) ::
          {:ok, snapshot()} | {:error, grading_error()}
  def fetch_verified(session_field_values) when is_map(session_field_values) do
    with {:ok, snapshot} <- fetch_structural(session_field_values) do
      if digest_matches?(snapshot), do: {:ok, snapshot}, else: grading_error(:snapshot_corrupt)
    end
  end

  @doc """
  Structural validation only (no digest recompute). Used by autosave and the candidate state read
  (the hot path).
  """
  @spec fetch_structural(session_field_values :: map()) ::
          {:ok, snapshot()} | {:error, grading_error()}
  def fetch_structural(session_field_values) when is_map(session_field_values) do
    case Map.get(session_field_values, "exam_snapshot") do
      nil -> grading_error(:snapshot_missing)
      %{} = snapshot -> if structural?(snapshot), do: {:ok, snapshot}, else: corrupt()
      _not_an_object -> corrupt()
    end
  end

  defp corrupt, do: grading_error(:snapshot_corrupt)

  defp structural?(snapshot) do
    snapshot["v"] == @snapshot_version and snapshot["origin"] in @origins and
      is_binary(snapshot["nonce"]) and is_binary(snapshot["digest"]) and
      optional?(snapshot, "exam", &is_map/1) and optional?(snapshot, "order", &is_list/1) and
      optional?(snapshot, "questions", &is_map/1)
  end

  defp optional?(map, key, check) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> check.(value)
    end
  end

  defp digest_matches?(%{"digest" => digest} = snapshot) do
    Plug.Crypto.secure_compare(digest, compute_digest(snapshot))
  end

  defp put_digest(snapshot), do: Map.put(snapshot, "digest", compute_digest(snapshot))

  defp compute_digest(snapshot) do
    hash =
      snapshot
      |> Map.delete("digest")
      |> canonical_encode()
      |> then(&:crypto.hash(:sha256, &1))

    "sha256:" <> Base.encode16(hash, case: :lower)
  end

  @doc """
  The snapshot item of `question_id`. A snapshot without question items (`late_certificate`) is
  `:snapshot_corrupt` for scoring and autosave (design 17.1: impossible by construction for an
  `in_progress` session).
  """
  @spec question_item(snapshot(), question_id :: String.t()) ::
          {:ok, map()} | {:error, grading_error()}
  def question_item(snapshot, question_id) when is_map(snapshot) and is_binary(question_id) do
    case Map.get(snapshot, "questions") do
      %{} = questions ->
        case Map.get(questions, question_id) do
          %{} = item -> {:ok, item}
          _absent -> grading_error({:question_item_missing, question_id})
        end

      _no_items ->
        corrupt()
    end
  end

  @doc """
  The question's type as an atom (`:single | :multiple | :true_false | :likert | :short_text`),
  taken from the snapshot item.
  """
  @spec question_type(snapshot(), question_id :: String.t()) ::
          {:ok, Letflow.Modules.Exam.Scoring.question_type()} | {:error, grading_error()}
  def question_type(snapshot, question_id) do
    with {:ok, item} <- question_item(snapshot, question_id) do
      case type_atom(Map.get(item, "type")) do
        {:ok, _type} = ok -> ok
        :error -> grading_error({:question_type_invalid, question_id})
      end
    end
  end

  @doc "The pass threshold as a float in `0.0..100.0` (design 7.2). No default exists."
  @spec threshold(snapshot()) :: {:ok, float()} | {:error, grading_error()}
  def threshold(snapshot) when is_map(snapshot) do
    case Map.get(snapshot, "exam") do
      %{} = exam -> exam |> Map.get("passing_score_pct") |> read_threshold()
      _absent -> grading_error(:exam_section_missing)
    end
  end

  defp read_threshold(nil), do: grading_error(:threshold_missing)

  defp read_threshold(value) when is_binary(value) do
    with {:ok, decimal} <- threshold_decimal(value) do
      decimal_to_float(decimal)
    end
  end

  defp read_threshold(_not_a_string), do: grading_error(:threshold_invalid)

  @doc """
  Maps the items, in snapshot `order`, to the existing `Scoring.question_row()` shape (design
  4.2). `Scoring` itself is unchanged. Validates each item (design 7.2).
  """
  @spec to_scoring_questions(snapshot()) ::
          {:ok, [Letflow.Modules.Exam.Scoring.question_row()]} | {:error, grading_error()}
  def to_scoring_questions(snapshot) when is_map(snapshot) do
    case {Map.get(snapshot, "order"), Map.get(snapshot, "questions")} do
      {order, %{}} when is_list(order) ->
        order
        |> Enum.reduce_while({:ok, []}, fn question_id, {:ok, acc} ->
          case scoring_row(snapshot, question_id) do
            {:ok, row} -> {:cont, {:ok, [row | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, rows} -> {:ok, Enum.reverse(rows)}
          {:error, _reason} = error -> error
        end

      _no_items ->
        corrupt()
    end
  end

  defp scoring_row(snapshot, question_id) when is_binary(question_id) do
    with {:ok, item} <- question_item(snapshot, question_id),
         {:ok, type} <- item_type(item, question_id),
         {:ok, correct} <- correct_option_ids(item, type, question_id),
         {:ok, likert} <- likert_options(item, type, question_id) do
      {:ok,
       %{
         question_id: question_id,
         type: type,
         correct_option_ids: correct,
         likert_options: likert
       }}
    end
  end

  defp scoring_row(_snapshot, _not_an_id), do: corrupt()

  defp item_type(item, question_id) do
    case type_atom(Map.get(item, "type")) do
      {:ok, _type} = ok -> ok
      :error -> grading_error({:question_type_invalid, question_id})
    end
  end

  defp correct_option_ids(item, type, question_id) do
    case Map.get(item, "correct_option_ids") do
      ids when is_list(ids) ->
        cond do
          not Enum.all?(ids, &is_binary/1) ->
            grading_error({:key_missing, question_id})

          ids == [] and type in [:single, :multiple, :true_false] ->
            grading_error({:key_missing, question_id})

          true ->
            {:ok, ids}
        end

      _other ->
        grading_error({:key_missing, question_id})
    end
  end

  defp likert_options(item, :likert, question_id) do
    case Map.get(item, "likert_options") do
      %{} = options when map_size(options) > 0 ->
        Enum.reduce_while(options, {:ok, %{}}, fn {option_id, entry}, {:ok, acc} ->
          case likert_entry(entry) do
            {:ok, parsed} -> {:cont, {:ok, Map.put(acc, option_id, parsed)}}
            :error -> {:halt, grading_error({:key_missing, question_id})}
          end
        end)

      _empty_or_invalid ->
        grading_error({:key_missing, question_id})
    end
  end

  defp likert_options(_item, _type, _question_id), do: {:ok, %{}}

  defp likert_entry(%{"weight" => weight, "polarity" => polarity}) when is_binary(weight) do
    with {:ok, decimal} <- normalize_number(weight),
         {:ok, float} <- float_or_error(decimal),
         {:ok, polarity_atom} <- polarity_atom(polarity) do
      {:ok, %{weight: float, polarity: polarity_atom}}
    end
  end

  defp likert_entry(_other), do: :error

  defp float_or_error(decimal) do
    case decimal_to_float(decimal) do
      {:ok, float} -> {:ok, float}
      {:error, _reason} -> :error
    end
  end

  defp polarity_atom("positive"), do: {:ok, :positive}
  defp polarity_atom("negative"), do: {:ok, :negative}
  defp polarity_atom(_other), do: :error

  defp decimal_to_float(decimal) do
    {:ok, D.to_float(decimal)}
  rescue
    _error -> grading_error(:threshold_invalid)
  end

  defp type_atom("single"), do: {:ok, :single}
  defp type_atom("multiple"), do: {:ok, :multiple}
  defp type_atom("truefalse"), do: {:ok, :true_false}
  defp type_atom("likert"), do: {:ok, :likert}
  defp type_atom("shorttext"), do: {:ok, :short_text}
  defp type_atom(_other), do: :error

  # -----------------------------------------------------------------------
  # Canonical encoding
  # -----------------------------------------------------------------------

  @doc """
  The canonical encoding the digest is taken over: objects with keys sorted lexicographically at
  every level, lists in stored order, UTF-8, no insignificant whitespace. Numbers inside the
  snapshot are decimal strings, so no float formatting is involved.
  """
  @spec canonical_encode(term()) :: binary()
  def canonical_encode(%{} = map) when not is_struct(map) do
    body =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> canonical_encode(value)
      end)

    "{" <> body <> "}"
  end

  def canonical_encode(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_encode/1) <> "]"

  def canonical_encode(scalar), do: Jason.encode!(scalar)

  defp grading_error(reason), do: {:error, {:grading_error, reason}}
end
