defmodule Letflow.SandboxPool.FixtureLoader do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Loads a fixed list of fixture rows into a claimed sandbox schema's allowlisted tables,
  TRUNCATE-ing each distinct target table first (ports R-Co's
  `src/definition/fixture_loader.zig` per PRM-06 §3 — see
  `src/design/prm-batch1-promotion-assertion-rerun.md`).

  The allowlist is the SQL-injection boundary: a fixture's `table_name` is checked
  against a hardcoded list (`process_definitions`, `instance_definition_snapshots`)
  before any SQL is issued for it — see `lib/letflow/design/
  req039-sandbox-pool-fixture-loader.md` §5.2 for why this list diverges from R-Co's own
  (two of R-Co's three allowlisted tables have no Letflow equivalent yet), and §11 OQ-1
  for how a future requirement extends it. `sandbox_schema` is independently validated
  against the exact shape `Letflow.SandboxPool.claim/1` always produces before any
  interpolation, closing the same injection class on the schema-name dimension (design
  doc §5.5 INV-FL-1) — nothing in this module's own call graph guarantees a caller
  passes an already-valid schema name before this point, so it is validated
  explicitly here rather than assumed safe.
  """

  alias Letflow.Repo

  defmodule FixtureRow do
    @moduledoc """
    One fixture row to load: its target table name and raw JSON row content.
    `row_json` is bound as a `$1::jsonb` parameter — never decoded into an Elixir map
    by this module and never string-interpolated into SQL (design doc §5.1).
    """

    @enforce_keys [:table_name, :row_json]
    defstruct [:table_name, :row_json]

    @type t :: %__MODULE__{table_name: String.t(), row_json: String.t()}
  end

  # The SQL-injection boundary (INV-FL-2): no table name reaches a TRUNCATE or
  # INSERT statement unless it appears verbatim here. Extend only when a
  # concrete future consumer needs another table (design doc §5.2, §11 OQ-1) --
  # not speculatively.
  @allowlist ["process_definitions", "instance_definition_snapshots"]

  # The exact shape Letflow.SandboxPool's provisioning sequence always
  # produces ("sandbox_" <> a 32-hex-digit UUID with hyphens stripped) --
  # INV-FL-1: this function has no caller-trust guarantee enforced by the
  # type system (security-invariants.md INV-7), so the schema-name shape is
  # validated explicitly here rather than assumed safe from caller position
  # alone.
  @schema_name_pattern ~r/^sandbox_[0-9a-f]{32}\z/

  @doc """
  Loads `fixtures` into `sandbox_schema`, TRUNCATE-ing each distinct target table
  immediately before (re-)inserting its rows, all inside one transaction. An empty
  `fixtures` list is a no-op that issues no SQL at all. `opts` is currently unused (a
  forward-compatible extension point).
  """
  @spec load_fixtures_only(
          sandbox_schema :: String.t(),
          fixtures :: [FixtureRow.t()],
          opts :: keyword()
        ) ::
          :ok
          | {:error, :invalid_table_name}
          | {:error, :invalid_schema_name}
          | {:error, :insert_failed}
          | {:error, term()}
  def load_fixtures_only(sandbox_schema, fixtures, opts \\ [])

  def load_fixtures_only(_sandbox_schema, [], _opts), do: :ok

  def load_fixtures_only(sandbox_schema, fixtures, _opts) do
    table_names = distinct_table_names(fixtures)

    with :ok <- validate_schema_name(sandbox_schema),
         :ok <- validate_table_names(table_names) do
      apply_fixtures(sandbox_schema, table_names, fixtures)
    end
  end

  defp validate_schema_name(sandbox_schema) do
    if Regex.match?(@schema_name_pattern, sandbox_schema) do
      :ok
    else
      {:error, :invalid_schema_name}
    end
  end

  # PROVENANCE (historical, not current decision authority):
  # First-seen order preserved, matching fixture_loader.zig:71-85.
  defp distinct_table_names(fixtures) do
    fixtures
    |> Enum.map(& &1.table_name)
    |> Enum.uniq()
  end

  # A full validation pass over every distinct table completes before any
  # mutating statement is issued for any of them (INV-FL-2) -- the first
  # non-allowlisted name found short-circuits the whole load.
  defp validate_table_names(table_names) do
    if Enum.all?(table_names, &(&1 in @allowlist)) do
      :ok
    else
      {:error, :invalid_table_name}
    end
  end

  # Both identifiers interpolated below are already validated by this point:
  # sandbox_schema passed validate_schema_name/1's fixed-shape check, every
  # table_name passed validate_table_names/1's allowlist check -- neither is
  # raw, unvalidated caller input at the point of interpolation (INV-7).
  # row_json is always bound as $1, never interpolated (INV-FL-3).
  #
  # Wrapped in the whole call's own try/rescue, not a {:error, _} match on
  # Repo.transaction/1's return: a Repo.query!/2 failure inside the
  # transaction function *raises*, which Repo.transaction/1 rolls back and
  # then re-raises to its caller (it does not convert the exception into an
  # {:error, _} return on its own) -- design doc §5.4 step 5c/§5.6.
  defp apply_fixtures(sandbox_schema, table_names, fixtures) do
    Repo.transaction(fn ->
      Enum.each(table_names, fn table_name ->
        Repo.query!(~s(TRUNCATE "#{sandbox_schema}"."#{table_name}" CASCADE))
      end)

      # Computed once per distinct table, not once per row (jsonb_populate_record/2's
      # base composite is the same for every row of a given table) -- see
      # default_base_row/2's own moduledoc-comment for why this exists at all.
      base_rows = Map.new(table_names, &{&1, default_base_row(sandbox_schema, &1)})

      Enum.each(fixtures, fn %FixtureRow{table_name: table_name, row_json: row_json} ->
        base_row = Map.fetch!(base_rows, table_name)

        # A plain double-quoted string, not ~s(...): this toolchain's sigil
        # parser does not treat raw parens inside a ~s(...) sigil's own
        # content as nestable (verified directly -- `~s(a(b)c)` alone fails
        # to parse with "unexpected token: )" here), so the literal
        # `jsonb_populate_record(...)` call below cannot be written inside a
        # ~s()-delimited sigil. table_name/sandbox_schema are interpolated
        # (not concatenated) here, identically safe to the TRUNCATE statement
        # above: both already passed validate_schema_name/1 and
        # validate_table_names/1 by this point (INV-7). row_json is always
        # bound as a parameter, never interpolated (INV-FL-3). base_row is
        # never user input either -- see default_base_row/2.
        #
        # `($1::text)::jsonb`, not the design doc's literal `$1::jsonb`
        # (verified empirically, not a stylistic choice): when a bound
        # parameter's immediately-annotated cast is `::jsonb`, Postgrex's
        # jsonb type extension infers the parameter is a native Elixir term
        # to be JSON-*encoded* client-side (via Jason) before sending -- since
        # row_json here is already-encoded JSON *text*, that produces double
        # encoding (the object becomes a JSON *string* literal wrapping the
        # original text), which Postgres then rejects from
        # jsonb_populate_record with "cannot call populate_composite on a
        # scalar". Casting to `::text` first makes Postgrex bind the
        # already-correct text verbatim; the `::jsonb` cast then happens
        # server-side in Postgres, which parses it correctly. row_json is
        # still bound as a parameter either way -- never interpolated.
        sql =
          "INSERT INTO \"#{sandbox_schema}\".\"#{table_name}\" SELECT * FROM " <>
            "jsonb_populate_record(#{base_row}, ($1::text)::jsonb)"

        Repo.query!(sql, [row_json])
      end)
    end)

    :ok
  rescue
    _exception -> {:error, :insert_failed}
  end

  # jsonb_populate_record/2's base-composite argument. Was `NULL::"schema"."table"`
  # until WF02-REQ125-20260823's rework: jsonb_populate_record fills every JSON key
  # *absent* from row_json with whatever the base composite holds at that column --
  # NULL, if the base is NULL::type. It does NOT know about the target TABLE's
  # column-level DEFAULTs (populate_record operates purely on the composite TYPE),
  # so a fixture's JSON omitting a NOT NULL column with a table-level default (e.g.
  # `sequence_number bigint NOT NULL DEFAULT 0`, added by
  # 20260823000003_add_sequence_number_to_process_definitions.exs) inserted a real
  # NULL and violated the constraint, breaking every existing fixture builder that
  # (reasonably) never anticipated needing to know about a column added after it was
  # written. Fixed generically, once, at this level -- rather than patching each
  # fixture JSON builder to name `sequence_number` explicitly -- so the NEXT NOT NULL
  # column added anywhere on the allowlist with a table-level default does not
  # re-break every fixture builder the same way again.
  #
  # Builds `ROW(<default-or-NULL per column, in attnum order>)::"schema"."table"` by
  # reading each column's own DEFAULT expression straight out of Postgres's catalogs
  # (pg_attrdef via pg_get_expr) -- the same canonical rendering `pg_dump` itself
  # uses, already fully typed/cast, and already validated by Postgres at
  # CREATE/ALTER TABLE time. Interpolated into the SQL text below at the same trust
  # level as table_name/sandbox_schema elsewhere in this module: not user input, and
  # sandbox_schema/table_name were already validated (INV-FL-1/INV-FL-2) before this
  # is ever called. A column with no table-level default renders as 'NULL', identical
  # to this function's pre-fix behavior for that column.
  defp default_base_row(sandbox_schema, table_name) do
    # `($1::text)::regclass`, not a bare `$1::regclass` -- the same reason
    # apply_fixtures/3's own `($1::text)::jsonb` isn't just `$1::jsonb` (see that
    # comment): a parameter whose only annotation is `::regclass` makes Postgrex
    # infer the wire type is regclass's own OID representation and bind an integer,
    # raising "you tried to use a binary for an oid type" for the text this module
    # actually has (verified empirically). Casting from `::text` first keeps the
    # parameter bound as plain text; the `::regclass` cast then happens server-side.
    %Postgrex.Result{rows: [[defaults_csv]]} =
      Repo.query!(
        """
        SELECT string_agg(COALESCE(pg_get_expr(d.adbin, d.adrelid), 'NULL'), ',' ORDER BY a.attnum)
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = ($1::text)::regclass
          AND a.attnum > 0
          AND NOT a.attisdropped
        """,
        ["\"#{sandbox_schema}\".\"#{table_name}\""]
      )

    "ROW(#{defaults_csv})::\"#{sandbox_schema}\".\"#{table_name}\""
  end
end
