defmodule Letflow.Entities.Query.Cursor do
  @moduledoc """
  `cursor.zig`-equivalent (REQ-231 §2) -- a keyset-pagination cursor codec
  for entity query results, generalizing `Letflow.Entities.Definitions`'
  `list_definitions/3` fixed two-column (`inserted_at desc, id desc`)
  cursor shape to an arbitrary, caller-chosen `sort` clause list produced by
  `Letflow.Entities.Query.Compiler.compile/2`. See
  `lib/letflow/design/req231-entity-query-cursor-field-grants.md` §2 for the
  full design this module implements.

  Reuses `Letflow.Api.Pagination`'s outer envelope verbatim --
  `encode_cursor/1`, `decode_cursor/4`'s prefix+expiry check, `Cursor.t()`'s
  single-`inner`-field opacity guarantee (INV-1/INV-5), and
  `Page.t()`/`page_response/2` -- only the *domain-payload* format inside
  `Cursor.inner`'s tail is new (design §2.1). Nothing about REQ-067's
  security contract changes here.

  `cursor_prefix/0` returns the fixed literal `"EQ:"` (Entity Query), a
  sibling of `list_definitions/3`'s `"ED:"`, distinct so a cursor minted by
  one listing can never decode successfully against the other (design
  §2.2).

  ## Owns both the codec and the query-composition step (design §2.4)

  This module owns both the cursor codec (encode/decode the resume key) and
  the query-composition step that consumes `Compiler.compile/2`'s output --
  mirroring `list_definitions/3`'s own undivided responsibility. It never
  changes `Letflow.Entities.Query.Types`, `Allowlist`, or `Compiler`
  (REQ-230, already reviewed and merged) -- it only consumes their existing,
  unchanged output types.

  ## Why field name/type never travel inside the cursor (design §2.3)

  The decoded resume values are positionally re-paired against the
  *caller's own resent* `sort` list on the next request -- position `i` in
  the decoded resume-key array always corresponds to position `i` in that
  request's `sort`. A caller who submits a different `sort` order/length
  than the one that minted the cursor produces
  `{:error, :resume_key_arity_mismatch}` rather than a silently wrong resume
  point.

  ## The `record_id` tiebreaker (design §2.3, revised by ISS-0651)

  `record_id` (the entity's own UUID identity column) is appended as an
  implicit final ascending sort key to every compiled query this module
  executes, in addition to whatever `sort` the caller specified -- this is
  `Cursor`'s own addition on top of `Compiler.compile/2`'s returned query,
  not a change to `Compiler`/`Allowlist`.

  This was originally `entity_record_latest.id` (that table's own surrogate
  binary-UUID primary key), which does the job for an unpromoted entity
  type's `%Letflow.Entities.Record.Latest{}` rows. ISS-0651 found that a
  promoted entity type's per-type table query (`Compiler.entity_row()`'s
  plain-map shape) is a *schemaless* `from(table_name)` binding whose
  `select_entity_row/1` projection never includes `:id` at all -- so while
  the physical `"id"` column exists on both table shapes (per
  `Letflow.Entities.Definition.DDL`'s `PRIMARY KEY ("id")`), a per-type-table
  result row has no way to report its own `id` value back to
  `build_next_cursor/2` without `Compiler` selecting an extra column this
  design does not touch. `record_id` is used instead of `id` for both
  shapes uniformly: it is present in `entity_row()`'s fixed field set
  (unlike `id`), it is a real `Ecto.UUID`-typed column on both table shapes
  (so the same `maybe_dump/2` dump-before-comparison handling applies
  unchanged), and it is unique within the scope every compiled query here
  already guarantees -- `compile_plain/5`'s `:latest` branch always adds a
  `where(entity_type == ^entity_type)` filter (`entity_record_latest`'s own
  unique constraint is `(entity_type, record_id)`, so `record_id` alone is
  unique once that filter is in place), and a per-type table carries its own
  `UNIQUE (record_id)` constraint table-wide. `record_id` therefore satisfies
  the same total-order/stability requirement `id` did, for both row shapes,
  with no `Compiler`/`Allowlist` change.
  """

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.Record.Latest
  alias Letflow.Repo

  @cursor_prefix "EQ:"

  @doc "The fixed cursor prefix literal for this endpoint, `\"EQ:\"` (design §2.2)."
  @spec cursor_prefix() :: String.t()
  def cursor_prefix, do: @cursor_prefix

  @typedoc """
  The decoded, positionally-ordered list of `length(sort) + 1` JSON-native
  values described in design §2.2 -- still in raw decoded form (no
  type-casting against `Allowlist` field types performed yet).
  """
  @type resume_key :: [term()]

  # A decoded resume key with its binding (GH #2698): the `[entity_type | sort]`
  # binding a minted cursor carries, or `:unbound` for a legacy bare list.
  @type bound_resume_key :: {[term()] | :unbound, resume_key()}

  @typedoc "`paginate/5`'s `opts` shape (design §2.4)."
  @type paginate_opts :: %{
          optional(:cursor) => String.t() | nil,
          optional(:page_size) => pos_integer() | nil
        }

  @typedoc "One resolved sort clause -- the field's allowlist entry plus its dynamic reference."
  @type resolved_sort_term :: %{
          name: String.t(),
          dir: Types.sort_dir(),
          source: Allowlist.field_source(),
          type: term(),
          dyn: Ecto.Query.dynamic_expr()
        }

  @doc """
  Paginates `compiled_query` (already produced by
  `Letflow.Entities.Query.Compiler.compile/2` for `request`) using a keyset
  cursor generalized to `request`'s own `sort` clause list (design §2.4).

  Step order, mirroring `list_definitions/3`'s own `with` chain:

    1. `Pagination.validate_page_size/1` on `opts.page_size`.
    2. Decode `opts.cursor` via `Pagination.decode_cursor/4` with this
       module's own `cursor_prefix/0`, then JSON-parse the tail into a
       `resume_key()`.
    3. Re-resolve every `sort_clause().field` against `allowlist` to learn
       each field's `type()`/`source()` for the typed resume-filter
       comparison.
    4. If a decoded `resume_key()` is present, check its length equals
       `length(sort) + 1` -- `{:error, :resume_key_arity_mismatch}`
       otherwise.
    5. A cursor minted by this module binds its `entity_type` and sort
       clause (`binding/2`, GH #2698); a bound cursor replayed under another
       entity type or sort is `{:error, :invalid_cursor}`. A legacy cursor
       without a binding is accepted as before.
    6. Build the row-wise resume filter and add it to `compiled_query`, add
       the implicit `record_id` ascending tiebreak order (ISS-0651: was
       `id`), add `limit(page_size + 1)`.
    7. `Repo.all(query, prefix: prefix)`, split off the possible extra row,
       and -- if a next page exists -- mint the next cursor.
  """
  @spec paginate(
          request :: Types.query_request(),
          compiled_query :: Ecto.Query.t(),
          allowlist :: Allowlist.allowlist(),
          opts :: paginate_opts(),
          prefix :: String.t()
        ) ::
          {:ok, Pagination.Page.t(Latest.t() | Letflow.Entities.Query.Compiler.entity_row())}
          | {:error, :page_size_too_large}
          | {:error, :invalid_cursor}
          | {:error, :wrong_endpoint}
          | {:error, :expired}
          | {:error, :resume_key_arity_mismatch}
          | {:error, {:field_not_allowed, String.t()}}
  def paginate(request, %Ecto.Query{} = compiled_query, allowlist, opts, prefix)
      when is_map(request) and is_map(allowlist) and is_map(opts) and is_binary(prefix) do
    sort = Map.get(request, :sort, [])

    with {:ok, page_size} <- Pagination.validate_page_size(Map.get(opts, :page_size)),
         {:ok, bound_resume_key} <- decode_resume_key(Map.get(opts, :cursor)),
         {:ok, resolved_sort} <- resolve_sort(sort, allowlist),
         {:ok, resume_terms} <-
           build_resume_terms(resume_list(bound_resume_key), resolved_sort),
         :ok <- check_binding(bound_resume_key, request.entity_type, resolved_sort) do
      rows =
        compiled_query
        |> apply_resume_filter(resume_terms)
        |> order_by([r], asc: r.record_id)
        |> limit(^(page_size + 1))
        |> Repo.all(prefix: prefix)

      {page_rows, extra?} = split_page(rows, page_size)

      next_cursor =
        if extra? do
          build_next_cursor(List.last(page_rows), request.entity_type, resolved_sort)
        else
          nil
        end

      {:ok, Pagination.page_response(page_rows, next_cursor)}
    end
  end

  # ── Step 2 -- decode the opaque cursor into a raw resume_key() (design §2.2) ──

  @spec decode_resume_key(String.t() | nil) ::
          {:ok, bound_resume_key() | nil}
          | {:error, :invalid_cursor}
          | {:error, :wrong_endpoint}
          | {:error, :expired}
  defp decode_resume_key(nil), do: {:ok, nil}

  defp decode_resume_key(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @cursor_prefix, byte_size(@cursor_prefix)) do
      {:ok, %Pagination.Cursor{inner: inner}} -> parse_resume_key_json(inner)
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is `"EQ:<mint_time_us>:<resume_key_json>"` -- the first slot
  # after the prefix is always the mint-time timestamp `decode_cursor/4`'s
  # own expiry check already read, never a domain value (same idiom
  # `list_definitions/3`'s cursor helpers use). The JSON tail may itself
  # legitimately contain colons (e.g. an ISO-8601 datetime string), so this
  # splits on the FIRST colon only.
  defp parse_resume_key_json(inner) do
    prefix_len = byte_size(@cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)

    case String.split(rest, ":", parts: 2) do
      [_mint_time_us_str, resume_key_json] ->
        case Jason.decode(resume_key_json) do
          {:ok, %{"bind" => binding, "key" => list}} when is_list(list) -> {:ok, {binding, list}}
          {:ok, list} when is_list(list) -> {:ok, {:unbound, list}}
          _ -> {:error, :invalid_cursor}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  end

  # ── Step 2b -- the binding of a minted cursor (GH #2698) ─────────────────────

  # A next cursor carries the sort values of its last row. Those values are
  # only meaningful for the entity type and sort clause that produced them;
  # replayed under another sort they become a threshold on a field the
  # replaying caller may not read (the walker checks only the replayed
  # request's own clauses). So a minted key names both, and a replay must
  # match. A key without a binding is a legacy cursor and is accepted as
  # before; the walker still checks its sort.
  @spec binding(String.t(), [resolved_sort_term()]) :: [term()]
  defp binding(entity_type, resolved_sort) do
    [entity_type | Enum.map(resolved_sort, &[&1.name, to_string(&1.dir)])]
  end

  @spec check_binding(bound_resume_key() | nil, String.t(), [resolved_sort_term()]) ::
          :ok | {:error, :invalid_cursor}
  defp check_binding(nil, _entity_type, _resolved_sort), do: :ok
  defp check_binding({:unbound, _key}, _entity_type, _resolved_sort), do: :ok

  defp check_binding({bound, _key}, entity_type, resolved_sort) do
    if bound == binding(entity_type, resolved_sort),
      do: :ok,
      else: {:error, :invalid_cursor}
  end

  defp resume_list(nil), do: nil
  defp resume_list({_binding_or_unbound, key}), do: key

  # ── Step 3 -- resolve every sort clause against the allowlist ──────────────

  @spec resolve_sort([Types.sort_clause()], Allowlist.allowlist()) ::
          {:ok, [resolved_sort_term()]} | {:error, {:field_not_allowed, String.t()}}
  defp resolve_sort(sort, allowlist) do
    Enum.reduce_while(sort, {:ok, []}, fn clause, {:ok, acc} ->
      case Allowlist.resolve_field(allowlist, clause.field) do
        {:ok, field} -> {:cont, {:ok, [resolved_sort_term(clause, field) | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = error -> error
    end
  end

  # ISS-0653: `name` is either one of `Allowlist.typed_columns/0`'s fixed
  # structural-7 entries (present on both row shapes, and on `Latest`'s own
  # `Ecto.Schema` declaration) or a genuinely promoted business column
  # (`Allowlist.load/2` only ever marks a non-fixed-7 name `:typed_column`
  # once its own per-type table AND that specific column physically exist --
  # see that function's own moduledoc). A promoted name can never reach here
  # for a `:latest`-bound primary (same gating `Compiler.build_filter_dynamic/3`'s
  # own moduledoc note relies on), so the fragment path below is only ever
  # exercised against a schemaless per-type-table query. Mirrors
  # `Compiler.build_order_by/3`'s own `:typed_column` dispatch exactly --
  # same `Map.fetch(Allowlist.typed_columns(), field_name)` split, same
  # `fragment("?", literal(^field_name))` reference for the promoted branch
  # -- rather than inventing a fourth pattern in this module.
  defp resolved_sort_term(%{dir: dir}, %{source: :typed_column, name: name} = field) do
    case Map.fetch(Allowlist.typed_columns(), name) do
      {:ok, {column_atom, _type}} ->
        %{
          name: name,
          dir: dir,
          source: :typed_column,
          type: field.type,
          ecto_type: Latest.__schema__(:type, column_atom),
          dyn: dynamic([r], field(r, ^column_atom))
        }

      :error ->
        # No `Ecto.Schema` declaration exists for a promoted column (the
        # per-type table is a schemaless `from(table_name)` binding), so
        # there is no `Latest.__schema__(:type, ...)`-equivalent lookup
        # available here -- `ecto_type: nil` (the same "no dump needed"
        # value `:json_field` terms already use) matches
        # `Compiler.promoted_column_dynamic/3`'s own established precedent
        # of comparing the raw decoded value against the fragment-referenced
        # column with no `Ecto.UUID.dump!/1`-style pre-dump step, for every
        # promoted field type this design considered (REQ-300 does not special
        # -case an FK-promoted column's physical `uuid` type for filter
        # comparisons either -- see `Compiler`'s own `fk_column_pg_type/2`
        # note; this module does not re-decide that here).
        %{
          name: name,
          dir: dir,
          source: :typed_column,
          type: field.type,
          ecto_type: nil,
          dyn: dynamic([r], fragment("?", literal(^name)))
        }
    end
  end

  defp resolved_sort_term(%{dir: dir}, %{source: :json_field, name: name, type: type}) do
    %{
      name: name,
      dir: dir,
      source: :json_field,
      type: type,
      ecto_type: nil,
      dyn: json_cast_dynamic(type, name)
    }
  end

  # ── Step 4 -- arity check + typed-value casting of the decoded resume key ──

  @spec build_resume_terms(resume_key() | nil, [resolved_sort_term()]) ::
          {:ok, [map()] | nil}
          | {:error, :resume_key_arity_mismatch}
          | {:error, :invalid_cursor}
  defp build_resume_terms(nil, _resolved_sort), do: {:ok, nil}

  defp build_resume_terms(raw_resume_key, resolved_sort) when is_list(raw_resume_key) do
    if length(raw_resume_key) != length(resolved_sort) + 1 do
      {:error, :resume_key_arity_mismatch}
    else
      {sort_values, [id_value]} = Enum.split(raw_resume_key, length(resolved_sort))

      with {:ok, casted_values} <- cast_all(resolved_sort, sort_values),
           {:ok, id_str} <- Pagination.cast_binary_id_component(id_value) do
        sort_terms =
          resolved_sort
          |> Enum.zip(casted_values)
          |> Enum.map(fn {term, value} -> Map.put(term, :value, value) end)

        id_term = %{
          dir: :asc,
          value: id_str,
          ecto_type: :binary_id,
          dyn: dynamic([r], r.record_id)
        }

        {:ok, sort_terms ++ [id_term]}
      else
        :error -> {:error, :invalid_cursor}
        {:error, :invalid_cursor} -> {:error, :invalid_cursor}
      end
    end
  end

  defp cast_all(resolved_sort, raw_values) do
    resolved_sort
    |> Enum.zip(raw_values)
    |> Enum.reduce_while({:ok, []}, fn {term, raw_value}, {:ok, acc} ->
      case decode_component(term.type, raw_value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  # Casts one JSON-decoded resume-key component back into the Elixir term
  # its `Allowlist.allowlisted_field().type` expects for query comparison
  # (design §2.4's "type-casting... happens when the resume filter is
  # built" note) -- the same per-`field_type()` dispatch idea
  # `Compiler.build_filter_dynamic/2` already uses for JSON-field
  # comparisons, reimplemented here rather than reused directly since those
  # functions are private to `Compiler` (which this design does not touch).
  #
  # GH #2844: an integer (or a float's truncation) outside int64 is a cursor error -- Postgrex
  # raises `DBConnection.EncodeError` on it. A string component must be valid UTF-8 without NUL
  # (`Pagination.valid_seek_string?/1`), and a binary/boolean is accepted only for the field
  # types that compare against one (no string for an integer, no boolean for a string/decimal).
  defp decode_component(:integer, v) when is_integer(v), do: int64_component(v)
  defp decode_component(:integer, v) when is_float(v), do: int64_component(trunc(v))

  # GH #2654: strict parse for EVERY decimal field. `Decimal.new/1` raised `Decimal.Error` on a
  # tampered component (a crash instead of the cursor error); a valid component (a string from a
  # strict field, a number or its shortest-float text from a legacy one) decodes as before. A
  # non-finite or over-long component is a cursor error too. The parse limits are lifted to
  # match the write path (`Decimals`): Decimal's default 34-digit cap would reject a legitimate
  # strict value of up to 1000 digits; the 1100-byte and exponent bounds below replace it.
  defp decode_component(:decimal, v) when is_binary(v) or is_number(v) do
    text = to_string(v)

    with true <- byte_size(text) <= 1100,
         {%Decimal{coef: coef, exp: exp} = decimal, ""}
         when is_integer(coef) and exp >= -1100 and exp <= 1100 <-
           Decimal.parse(text, max_digits: :infinity, max_exponent: :infinity) do
      {:ok, decimal}
    else
      _malformed -> :error
    end
  end

  defp decode_component(:date, v) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp decode_component(:datetime, v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp decode_component(:boolean, v) when is_boolean(v), do: {:ok, v}

  defp decode_component(type, v)
       when type in [:string, :enum, :json, :localized_text] and is_binary(v) do
    if Pagination.valid_seek_string?(v), do: {:ok, v}, else: :error
  end

  defp decode_component(_type, _v), do: :error

  defp int64_component(v), do: if(Pagination.int64?(v), do: {:ok, v}, else: :error)

  # ── Step 5 -- resume-filter composition (design §2.3) ──────────────────────

  defp apply_resume_filter(query, nil), do: query

  defp apply_resume_filter(query, resume_terms) do
    where(query, [r], ^build_row_dynamic(resume_terms))
  end

  # Row-wise (lexicographic) keyset comparison, composed left-to-right via
  # nested `dynamic/2` rather than a literal Postgres row-tuple, since
  # Ecto's fragment syntax cannot itself parameterize over a
  # runtime-variable tuple arity (design §2.3):
  #
  #   (f1 </> v1) OR (f1 == v1 AND ((f2 </> v2) OR (f2 == v2 AND (...))))
  #
  # built here by folding the term list from the last (least significant)
  # term back to the first (most significant).
  defp build_row_dynamic(resume_terms) do
    resume_terms
    |> Enum.reverse()
    |> Enum.reduce(nil, fn term, acc ->
      cmp = field_cmp(term.dyn, term.dir, term.value, term.ecto_type)

      case acc do
        nil -> cmp
        _ -> dynamic(^cmp or (^field_eq(term.dyn, term.value, term.ecto_type) and ^acc))
      end
    end)
  end

  # `ecto_type` is `nil` for `:json_field` sort terms (the fragment cast
  # already gives Postgres a native-typed comparison side) and the actual
  # schema `Ecto.Type` for `:typed_column`/`id` terms. `term.dyn` is a
  # field-reference built at runtime and composed into this dynamic via `^`
  # interpolation rather than written inline, so Ecto's own compile-time
  # dump-on-cast step (the one that would normally turn a UUID string into
  # the raw 16-byte binary Postgrex requires for a `:binary_id`/`Ecto.UUID`
  # column) never runs for `^value` here -- confirmed empirically: the
  # `record_id` tiebreak comparison reached Postgrex as an un-dumped string without
  # this. `maybe_dump/2` performs that dump explicitly wherever it matters.
  defp field_eq(dyn, value, ecto_type), do: dynamic(^dyn == ^maybe_dump(ecto_type, value))
  defp field_cmp(dyn, :desc, value, ecto_type), do: dynamic(^dyn < ^maybe_dump(ecto_type, value))
  defp field_cmp(dyn, :asc, value, ecto_type), do: dynamic(^dyn > ^maybe_dump(ecto_type, value))

  defp maybe_dump(nil, value), do: value
  defp maybe_dump(:binary_id, value), do: Ecto.UUID.dump!(value)
  defp maybe_dump(Ecto.UUID, value), do: Ecto.UUID.dump!(value)
  defp maybe_dump(_ecto_type, value), do: value

  # ── Step 6 -- page split + next-cursor minting ──────────────────────────────

  defp split_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, true}
  end

  defp split_page(rows, _page_size), do: {rows, false}

  # ISS-0651: `row` reaches here as either a `%Latest{}` struct
  # (unpromoted entity type) or a `Compiler.entity_row()` plain map
  # (promoted, per-type-table entity type) -- the same two shapes
  # `FieldGrants.redact_item/2` and `Letflow.Routers.Entities`'s
  # `query_item_map/1` already branch on. `record_id` (not `id`; see this
  # module's moduledoc "The `record_id` tiebreaker") is read via the exact
  # same two-clause idiom those functions use, rather than inventing a
  # third pattern.
  defp build_next_cursor(row, entity_type, resolved_sort) do
    mint_time_us = System.system_time(:microsecond)
    record_id = read_record_id(row)

    resume_values =
      Enum.map(resolved_sort, fn term ->
        term
        |> read_sort_value(row)
        |> encode_component(term.type)
      end)

    resume_key_json =
      Jason.encode!(%{
        "bind" => binding(entity_type, resolved_sort),
        "key" => resume_values ++ [record_id]
      })

    @cursor_prefix
    |> Pagination.build_raw_cursor(mint_time_us, resume_key_json)
    |> Pagination.encode_cursor()
  end

  defp read_record_id(%Latest{record_id: record_id}), do: record_id
  defp read_record_id(%{record_id: record_id} = row) when is_map(row), do: record_id

  # ISS-0653: a promoted business column's own value is never selected onto
  # the row by `Compiler.select_entity_row/1` (which projects only the
  # fixed structural-7 field set for a per-type-table query) -- it is,
  # however, always readable from `field_values`, since
  # `Letflow.Entities.Definition.DDL.promoted_columns/1` emits every
  # ordinary promoted column as `GENERATED ALWAYS AS (...) STORED` computed
  # FROM `field_values` (never the reverse), so the two never disagree.
  # Falls through to the same `field_values`-keyed read `:json_field` terms
  # already use just below, rather than inventing a third read strategy.
  defp read_sort_value(%{source: :typed_column, name: name}, row) do
    case Map.fetch(Allowlist.typed_columns(), name) do
      {:ok, {column_atom, _type}} -> Map.fetch!(row, column_atom)
      :error -> read_promoted_column_value(name, row)
    end
  end

  defp read_sort_value(%{source: :json_field, name: name}, %Latest{field_values: field_values}) do
    Map.fetch!(field_values, name)
  end

  defp read_sort_value(%{source: :json_field, name: name}, %{field_values: field_values} = row)
       when is_map(row) do
    Map.fetch!(field_values, name)
  end

  defp read_promoted_column_value(name, %Latest{field_values: field_values}) do
    Map.fetch!(field_values, name)
  end

  defp read_promoted_column_value(name, %{field_values: field_values} = row) when is_map(row) do
    Map.fetch!(field_values, name)
  end

  defp encode_component(%DateTime{} = v, _type), do: DateTime.to_iso8601(v)
  defp encode_component(%Date{} = v, _type), do: Date.to_iso8601(v)
  defp encode_component(%Decimal{} = v, _type), do: Decimal.to_string(v)
  defp encode_component(v, _type), do: v

  # ── JSONB per-type cast fragments (design §2.3, mirroring Compiler §5.2) ──
  # Duplicated here rather than exposed from `Compiler` (which this design
  # does not touch) -- each clause has its own distinct, compile-time-literal
  # first `fragment/1` argument, never assembled at runtime.

  @string_fragment "?->>?"
  @integer_fragment "(?->>?)::bigint"
  @decimal_fragment "(?->>?)::numeric"
  @boolean_fragment "(?->>?)::boolean"
  @date_fragment "(?->>?)::date"
  @datetime_fragment "(?->>?)::timestamp"

  defp json_cast_dynamic(:string, field_name),
    do: dynamic([r], fragment(@string_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:enum, field_name),
    do: dynamic([r], fragment(@string_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:integer, field_name),
    do: dynamic([r], fragment(@integer_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:decimal, field_name),
    do: dynamic([r], fragment(@decimal_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:boolean, field_name),
    do: dynamic([r], fragment(@boolean_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:date, field_name),
    do: dynamic([r], fragment(@date_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:datetime, field_name),
    do: dynamic([r], fragment(@datetime_fragment, r.field_values, ^field_name))
end
