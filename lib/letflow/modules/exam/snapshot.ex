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

  ## Scope of PR b: the late (in-flight) snapshot, certificate facts and the cutover rule

  A session that was `in_progress` before the snapshot code shipped has no snapshot. At its first
  touch (state read, autosave, submit, deadline auto-submit) one is built from the live authoring
  rows under the session row lock, marked `origin: "late"` and recorded by a hash-chained
  `exam.session_snapshot_late` audit entry in the same transaction (design 9, 17.6, 18.5, 18.6):

    * `ensure/3` is the candidate touch (own transaction, owner check first, writes at once);
    * `ensure_locked/2` is the submit/finalize variant: it only BUILDS (reads) and returns the
      session row with the snapshot merged in memory. The caller persists it in its single
      `session` update after scoring, then calls `record_late/4` as the LAST statement. This keeps
      the lock order identical to a plain submit (session row, score sequence, session sequence)
      with the audit chain lock last (writing the snapshot first would invert the score/session
      sequence order against concurrent plain submits);
    * `ensure_certificate_facts/3` gives a legacy `submitted` session certificate-only facts
      (`origin: "late_certificate"`), once.

  A snapshot that is present but corrupt is NEVER replaced. A late snapshot is allowed only when
  the session RECORD's server-set `inserted_at` is earlier than `cutover/1` (the first activation
  of a `session` definition declaring `exam_snapshot`); otherwise `:snapshot_missing`, no write.
  Terminal sessions never get a snapshot except the `late_certificate` facts at certificate time.
  """

  import Ecto.Query, only: [from: 2]

  alias Decimal, as: D
  alias Letflow.Audit
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Identity.AuditContext
  alias Letflow.Modules.Exam
  alias Letflow.Repo
  alias Letflow.Repository.ActivationHistory
  alias Letflow.TenantProvisioning

  require Logger

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

  @typedoc """
  The snapshot could not be prepared because the rollout has not run for the tenant, or a late
  write / audit failed (HTTP 503). Tags only (INV-4).
  """
  @type snapshot_error ::
          {:snapshot_error,
           :definition_missing | :restrictions_missing | :audit_failed | :write_failed}

  @typedoc "How a locked session's snapshot was obtained: already stored, or built just now."
  @type provenance :: :existing | :late

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
          required(:origin) => :start | :late,
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
        origin: origin,
        exam_id: exam_id,
        taken_at: %DateTime{} = taken_at
      })
      when is_map(exam_fv) and is_map(items) and is_list(order) and origin in [:start, :late] do
    with {:ok, threshold} <- threshold_string(Map.get(exam_fv, "passing_score_pct")),
         {:ok, questions} <- build_items(order, items) do
      snapshot =
        %{
          "v" => @snapshot_version,
          "origin" => Atom.to_string(origin),
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
  # Certificate facts (PR b)
  # -----------------------------------------------------------------------

  @doc """
  The two facts the certificate path reads: `certificate_enabled` (must be a boolean) and
  `title` (must be present), both from the snapshot's `exam` object (design 6, 7.2). The
  certificate path never reads the live exam row.
  """
  @spec certificate_facts(snapshot()) ::
          {:ok, %{certificate_enabled: boolean(), title: term()}} | {:error, grading_error()}
  def certificate_facts(snapshot) when is_map(snapshot) do
    with %{} = exam <- Map.get(snapshot, "exam"),
         enabled when is_boolean(enabled) <- Map.get(exam, "certificate_enabled"),
         title when not is_nil(title) <- Map.get(exam, "title") do
      {:ok, %{certificate_enabled: enabled, title: title}}
    else
      _missing -> grading_error(:certificate_facts_missing)
    end
  end

  # -----------------------------------------------------------------------
  # Prerequisites and cutover (PR b)
  # -----------------------------------------------------------------------

  @doc """
  Fail-closed precondition shared by the session start and every late snapshot (design 4.3 step 1,
  9.2): the tenant's ACTIVE `session` definition declares the json field `exam_snapshot` and its
  restriction row exists. Two indexed reads, explicit prefix.
  """
  @spec check_prerequisites(prefix :: String.t()) ::
          :ok | {:error, {:snapshot_error, :definition_missing | :restrictions_missing}}
  def check_prerequisites(prefix) when is_binary(prefix) do
    with :ok <- check_definition(prefix) do
      check_restriction(prefix)
    end
  end

  defp check_definition(prefix) do
    case Definitions.get_active_definition_by_name("session", prefix) do
      {:ok, %{definition_json: %{"fields" => fields}}} when is_list(fields) ->
        if Enum.any?(
             fields,
             &(is_map(&1) and &1["name"] == "exam_snapshot" and &1["type"] == "json")
           ),
           do: :ok,
           else: {:error, {:snapshot_error, :definition_missing}}

      {:ok, _definition} ->
        {:error, {:snapshot_error, :definition_missing}}

      {:error, _reason} ->
        {:error, {:snapshot_error, :definition_missing}}
    end
  end

  defp check_restriction(prefix) do
    restricted? =
      Repo.exists?(
        from(r in "entity_field_restrictions",
          where: r.entity_type == "session" and r.field_name == "exam_snapshot"
        ),
        prefix: prefix
      )

    if restricted?, do: :ok, else: {:error, {:snapshot_error, :restrictions_missing}}
  end

  @doc """
  The cutover instant of a tenant (design 18.5): the MINIMUM `activated_at` in
  `artifact_activation_history` for the `session` entity over the definition versions that
  declare a field named `exam_snapshot`. Pack install and the rollout both activate through
  `Definitions.activate_definition/4`, so every such activation has a row; the table is
  append-only. No such version -> `{:error, :definition_missing}`. There is no other source.
  The field match is a bound-parameter jsonb containment (INV-7).
  """
  @spec cutover(prefix :: String.t()) ::
          {:ok, DateTime.t()} | {:error, :definition_missing | :invalid_schema_name}
  def cutover(prefix) when is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      containment = %{"fields" => [%{"name" => "exam_snapshot"}]}

      query =
        from(h in ActivationHistory,
          join: e in EntityDefinition,
          on: e.artifact_version_id == h.new_version_id and e.tenant_id == h.tenant_id,
          where:
            h.tenant_id == ^tenant_id and h.artifact_kind == :entity and
              h.artifact_name == "session" and e.name == "session" and
              fragment("? @> ?", e.definition_json, type(^containment, :map)),
          select: min(h.activated_at)
        )

      case Repo.one(query, prefix: prefix) do
        %DateTime{} = activated_at -> {:ok, activated_at}
        nil -> {:error, :definition_missing}
      end
    end
  end

  # SEC A3: compared against the session RECORD's server-set `inserted_at` (set on insert, not
  # castable, never rewritten by an update), NOT the writable `started_at` field.
  defp check_before_cutover(%Latest{inserted_at: %DateTime{} = inserted_at}, prefix) do
    case cutover(prefix) do
      {:ok, cutover_at} ->
        if DateTime.compare(inserted_at, cutover_at) == :lt,
          do: :ok,
          else: grading_error(:snapshot_missing)

      {:error, :definition_missing} ->
        {:error, {:snapshot_error, :definition_missing}}

      {:error, :invalid_schema_name} = error ->
        error
    end
  end

  defp check_before_cutover(%Latest{}, _prefix), do: grading_error(:snapshot_missing)

  # -----------------------------------------------------------------------
  # Late snapshot (PR b)
  # -----------------------------------------------------------------------

  @doc """
  The candidate touch (design 9.2): own transaction, session row lock, ownership FIRST, then the
  stored snapshot (verified) or - only for an `in_progress` session started before the cutover - a
  late one, written in the same transaction together with its audit entry. A non-owner and a
  nonexistent session get the same `:session_not_found`/`:not_owner` pair the caller renders as
  one 404, after exactly one query; no prerequisite is probed for them.
  """
  @spec ensure(session_id :: String.t(), user_id :: String.t(), prefix :: String.t()) ::
          {:ok, snapshot()}
          | {:error,
             :session_not_found
             | :not_owner
             | :invalid_schema_name
             | grading_error()
             | snapshot_error()}
  def ensure(session_id, user_id, prefix)
      when is_binary(session_id) and is_binary(user_id) and is_binary(prefix) do
    Repo.transaction(fn ->
      with {:ok, session} <- lock_session(session_id, prefix),
           :ok <- check_owner(session, user_id),
           {:ok, snapshot, session_after, provenance} <- ensure_locked(session, prefix),
           :ok <- persist_late(provenance, session, session_after, snapshot, user_id, prefix) do
        snapshot
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp persist_late(:existing, _session, _after, _snapshot, _actor, _prefix), do: :ok

  defp persist_late(:late, session, session_after, snapshot, actor_id, prefix) do
    with :ok <- write_session(session, session_after, prefix) do
      record_late(session, snapshot, actor_id, prefix)
    end
  end

  @doc """
  Submit/finalize variant (design 17.2): the caller holds the transaction and the session row lock.
  Returns `{:ok, snapshot, session_after, provenance}`. For `:existing` the stored snapshot is
  returned verified and `session_after` is the row unchanged. For `:late` the snapshot is only
  BUILT (reads): `session_after.field_values` carries it, nothing is written yet. The caller MUST
  write `session_after.field_values` in its single `session` update (so the later update cannot
  drop the snapshot) and then call `record_late/4` as its last statement. Deviation from the 17.2
  table (return shape and deferred write) is recorded in the PR: it keeps the lock order the same
  as a plain submit.
  """
  @spec ensure_locked(session :: Latest.t(), prefix :: String.t()) ::
          {:ok, snapshot(), session_after :: Latest.t(), provenance()}
          | {:error, grading_error() | snapshot_error() | :invalid_schema_name}
  def ensure_locked(%Latest{} = session, prefix) when is_binary(prefix) do
    case fetch_structural(session.field_values) do
      {:ok, _snapshot} ->
        with {:ok, snapshot} <- fetch_verified(session.field_values) do
          {:ok, snapshot, session, :existing}
        end

      {:error, {:grading_error, :snapshot_missing}} ->
        build_missing(session, prefix)

      {:error, _corrupt} = error ->
        # A present-but-bad snapshot is NEVER replaced (design 9.1).
        error
    end
  end

  defp build_missing(%Latest{} = session, prefix) do
    with :ok <- require_status(session, "in_progress"),
         :ok <- check_prerequisites(prefix),
         :ok <- check_before_cutover(session, prefix),
         {:ok, snapshot} <- build_late(session, prefix, now()) do
      {:ok, snapshot, put_snapshot(session, snapshot), :late}
    end
  end

  defp require_status(session, status) do
    if fv(session, "status") == status, do: :ok, else: grading_error(:snapshot_missing)
  end

  defp put_snapshot(%Latest{} = session, snapshot),
    do: %{session | field_values: Map.put(session.field_values, "exam_snapshot", snapshot)}

  @doc """
  Builds the late snapshot (`origin: "late"`) of a locked `in_progress` session from the LIVE exam,
  the session's `session_question` rows, their questions and option rows (design 17.2). Reads
  only. A missing or invalid live key is the same typed grading error the start path raises; no
  fallback value exists.
  """
  @spec build_late(session :: Latest.t(), prefix :: String.t(), now :: DateTime.t()) ::
          {:ok, snapshot()} | {:error, grading_error() | :invalid_schema_name}
  def build_late(%Latest{} = session, prefix, %DateTime{} = now) when is_binary(prefix) do
    exam_id = fv(session, "exam_id")

    with {:ok, exam} <- live_exam(exam_id, prefix),
         {:ok, session_questions} <-
           query_all(
             "session_question",
             [eq("session_id", session.record_id), eq("deleted", false)],
             prefix
           ),
         order = ordered_question_ids(session_questions),
         {:ok, items} <- load_items(order, prefix) do
      build_from_resolved(exam.field_values, items, order, %{
        origin: :late,
        exam_id: exam_id,
        taken_at: now
      })
    end
  end

  defp ordered_question_ids(session_questions) do
    session_questions
    |> Enum.sort_by(&fv(&1, "sort_order"))
    |> Enum.map(&fv(&1, "question_id"))
  end

  defp live_exam(exam_id, prefix) do
    case fetch_live(exam_id, "exam", prefix) do
      {:ok, exam} -> {:ok, exam}
      :not_found -> grading_error(:exam_section_missing)
      {:error, :invalid_schema_name} = error -> error
    end
  end

  defp load_items(order, prefix) do
    order
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn question_id, {:ok, acc} ->
      case load_item(question_id, prefix) do
        {:ok, source} -> {:cont, {:ok, Map.put(acc, question_id, source)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp load_item(question_id, prefix) do
    case fetch_live(question_id, "question", prefix) do
      {:ok, question} ->
        type = fv(question, "type")

        # All option rows are read: a soft-deleted one must be seen to know whether it was
        # key-bearing (GH #2734). A deleted key-bearing option refuses; other deleted ones drop.
        with {:ok, options} <-
               query_all("answer_option", [eq("question_id", question_id)], prefix) do
          {deleted, live} = Enum.split_with(options, &(&1.deleted == true))

          if Enum.any?(deleted, &key_bearing?(type, &1)) do
            grading_error({:key_missing, to_string(question_id)})
          else
            {:ok,
             %{
               type: type,
               options:
                 Enum.map(live, fn option ->
                   %{
                     id: normalize_record_id(option.record_id),
                     is_correct: fv(option, "is_correct"),
                     likert_weight: fv(option, "likert_weight"),
                     likert_polarity: fv(option, "likert_polarity")
                   }
                 end)
             }}
          end
        end

      :not_found ->
        grading_error({:question_item_missing, to_string(question_id)})

      {:error, :invalid_schema_name} = error ->
        error
    end
  end

  # Would this option have carried answer-key content in `build_item/2`/`build_likert/3`?
  defp key_bearing?(type, option) when type in ~w(single multiple truefalse),
    do: fv(option, "is_correct") == true

  defp key_bearing?("likert", option),
    do: fv(option, "likert_weight") != nil or fv(option, "is_correct") == true

  defp key_bearing?(_type, _option), do: false

  # `Latest.get_live/3` raises on a non-UUID id; a stored id that is not one is simply "not found".
  # A soft-deleted row is "not found" too (GH #2734).
  defp fetch_live(id, entity_type, prefix) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Latest.get_live(uuid, entity_type, prefix) do
          {:ok, row} -> {:ok, row}
          {:error, :not_found} -> :not_found
          {:error, :invalid_schema_name} = error -> error
        end

      :error ->
        :not_found
    end
  end

  defp fetch_live(_id, _entity_type, _prefix), do: :not_found

  @doc """
  The audit entry of a late snapshot (design 17.6): one hash-chained `exam.session_snapshot_late`
  entry, ids/names/timestamps only (INV-4/INV-5), in the caller's transaction. Call it as the LAST
  statement of that transaction (the audit chain lock is the last lock). `actor_id` is the touching
  user, or `nil` for the system sweep. A failure is `{:snapshot_error, :audit_failed}`; the caller
  rolls its transaction back, so a late snapshot that cannot be recorded is not taken.
  """
  @spec record_late(
          session :: Latest.t(),
          snapshot(),
          actor_id :: String.t() | nil,
          prefix :: String.t()
        ) :: :ok | {:error, {:snapshot_error, :audit_failed}}
  def record_late(%Latest{} = session, snapshot, actor_id, prefix) when is_binary(prefix) do
    attrs = %{
      actor_id: actor_id,
      action: "exam.session_snapshot_late",
      resource_type: "session",
      resource_id: session.record_id,
      before_state: nil,
      after_state: %{
        "origin" => Map.get(snapshot, "origin"),
        "taken_at" => Map.get(snapshot, "taken_at"),
        "exam_id" => get_in(snapshot, ["exam", "exam_id"]),
        "started_at" => fv(session, "started_at")
      },
      trace_id: AuditContext.current_trace_id()
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} ->
        Logger.info(
          "exam session snapshot taken late: origin=#{Map.get(snapshot, "origin")} " <>
            "session_id=#{session.record_id}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "exam late snapshot audit entry failed: reason=#{inspect(error_tag(reason))} " <>
            "session_id=#{session.record_id}"
        )

        {:error, {:snapshot_error, :audit_failed}}
    end
  end

  # One `Records` update of the session through the exam module's Owner. The full replacement
  # `field_values` is the locked row's own values plus the snapshot (invariant I-1).
  defp write_session(%Latest{} = session, %Latest{} = session_after, prefix) do
    result =
      Records.update_record(
        %{
          entity_type: "session",
          record_id: session.record_id,
          field_values: session_after.field_values,
          actor_id: fv(session, "user_id"),
          idempotency_key: Ecto.UUID.generate()
        },
        prefix,
        ManagedTypes.owner_for!(Exam)
      )

    case result do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "exam late snapshot write failed: reason=#{inspect(error_tag(reason))} " <>
            "session_id=#{session.record_id}"
        )

        {:error, {:snapshot_error, :write_failed}}
    end
  end

  # Tags and exception modules only; never the raw term (INV-4).
  defp error_tag(%{__exception__: true, __struct__: module}), do: module
  defp error_tag(%Ecto.Changeset{}), do: :invalid_changeset
  defp error_tag(tag) when is_atom(tag), do: tag
  defp error_tag({tag, _detail}) when is_atom(tag), do: tag
  defp error_tag(_other), do: :unexpected_error

  # -----------------------------------------------------------------------
  # Late certificate facts (PR b)
  # -----------------------------------------------------------------------

  @doc """
  Builds the certificate-only snapshot (`origin: "late_certificate"`) of a locked `submitted`
  session from the LIVE exam: `exam` holds only `exam_id`, `certificate_enabled` and `title`; no
  `order`, `questions` or threshold (design 17.2).
  """
  @spec build_certificate_only(session :: Latest.t(), prefix :: String.t(), now :: DateTime.t()) ::
          {:ok, snapshot()} | {:error, grading_error() | :invalid_schema_name}
  def build_certificate_only(%Latest{} = session, prefix, %DateTime{} = now)
      when is_binary(prefix) do
    exam_id = fv(session, "exam_id")

    with {:ok, exam} <- live_exam(exam_id, prefix) do
      enabled = Map.get(exam.field_values, "certificate_enabled")
      title = Map.get(exam.field_values, "title")

      if is_boolean(enabled) and not is_nil(title) do
        snapshot =
          %{
            "v" => @snapshot_version,
            "origin" => "late_certificate",
            "taken_at" => DateTime.to_iso8601(now),
            "nonce" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
            "exam" => %{"exam_id" => exam_id, "certificate_enabled" => enabled, "title" => title}
          }
          |> put_digest()

        if byte_size(canonical_encode(snapshot)) > @max_encoded_bytes,
          do: grading_error(:snapshot_too_large),
          else: {:ok, snapshot}
      else
        grading_error(:certificate_facts_missing)
      end
    end
  end

  @doc """
  The certificate-time touch (design 6, 17.2): own transaction, session row lock, ownership FIRST.
  An existing snapshot is returned (verified) untouched. A session with none gets
  `late_certificate` facts ONLY when it is `submitted` and its record was inserted before the
  cutover; the write and its audit entry share the transaction, and the facts are taken once.
  """
  @spec ensure_certificate_facts(
          session_id :: String.t(),
          user_id :: String.t(),
          prefix :: String.t()
        ) ::
          {:ok, snapshot()}
          | {:error,
             :session_not_found
             | :not_owner
             | :invalid_schema_name
             | grading_error()
             | snapshot_error()}
  def ensure_certificate_facts(session_id, user_id, prefix)
      when is_binary(session_id) and is_binary(user_id) and is_binary(prefix) do
    Repo.transaction(fn ->
      with {:ok, session} <- lock_session(session_id, prefix),
           :ok <- check_owner(session, user_id),
           {:ok, snapshot} <- certificate_snapshot(session, user_id, prefix) do
        snapshot
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp certificate_snapshot(%Latest{} = session, user_id, prefix) do
    case fetch_structural(session.field_values) do
      {:ok, _snapshot} ->
        fetch_verified(session.field_values)

      {:error, {:grading_error, :snapshot_missing}} ->
        with :ok <- require_status(session, "submitted"),
             :ok <- check_prerequisites(prefix),
             :ok <- check_before_cutover(session, prefix),
             {:ok, snapshot} <- build_certificate_only(session, prefix, now()),
             :ok <- write_session(session, put_snapshot(session, snapshot), prefix),
             :ok <- record_late(session, snapshot, user_id, prefix) do
          {:ok, snapshot}
        end

      {:error, _corrupt} = error ->
        error
    end
  end

  # -----------------------------------------------------------------------
  # Reporting helper (PR b)
  # -----------------------------------------------------------------------

  @doc """
  Counts the sessions of a tenant whose snapshot was taken late, by origin (design 17.6): a
  read-only helper for the post-deploy checklist. The full report stays in REQ-512.
  """
  @spec late_origin_counts(prefix :: String.t()) ::
          {:ok, %{late: non_neg_integer(), late_certificate: non_neg_integer()}}
          | {:error, :invalid_schema_name}
  def late_origin_counts(prefix) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      counts =
        from(r in Latest,
          where: r.entity_type == "session" and r.deleted == false,
          group_by: fragment("?->'exam_snapshot'->>'origin'", r.field_values),
          select: {fragment("?->'exam_snapshot'->>'origin'", r.field_values), count(r.id)}
        )
        |> Repo.all(prefix: prefix)
        |> Map.new()

      {:ok,
       %{
         late: Map.get(counts, "late", 0),
         late_certificate: Map.get(counts, "late_certificate", 0)
       }}
    end
  end

  # -----------------------------------------------------------------------
  # Shared plumbing (PR b)
  # -----------------------------------------------------------------------

  defp lock_session(session_id, prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query = from(r in Latest, where: r.entity_type == "session" and r.record_id == ^session_id)

      case query |> Ecto.Query.lock("FOR UPDATE") |> Repo.one(prefix: prefix) do
        nil -> {:error, :session_not_found}
        row -> {:ok, row}
      end
    end
  end

  defp check_owner(session, user_id),
    do: if(fv(session, "user_id") == user_id, do: :ok, else: {:error, :not_owner})

  defp fv(%{field_values: field_values}, key), do: Map.get(field_values, key)

  defp eq(field, value), do: %{field: field, op: :eq, value: value}

  defp query_all(entity_type, filters, prefix) do
    with {:ok, query} <- Compiler.compile(%{entity_type: entity_type, filters: filters}, prefix) do
      {:ok, Repo.all(query, prefix: prefix)}
    end
  end

  # A promoted per-type table returns the raw 16-byte UUID (same normalisation as Session).
  defp normalize_record_id(<<_::binary-size(16)>> = raw), do: Ecto.UUID.load!(raw)
  defp normalize_record_id(record_id) when is_binary(record_id), do: record_id

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

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
