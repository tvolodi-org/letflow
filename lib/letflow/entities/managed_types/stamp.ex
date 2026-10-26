defmodule Letflow.Entities.ManagedTypes.Stamp do
  @moduledoc """
  The platform stamp of the exam module's six runtime entity types on installs that predate the
  exam manifest's `manages_entity_types` (GH #2596; design
  `lib/letflow/design/gh2596-exam-managed-types.md` section 6). It is the ONLY writer allowed to
  set `entity_definitions.managed_by` after insert: the single documented exception to REQ-496
  D3 immutability (decision 0050 D7), opened in the database by the migration
  `AllowExamManagedByStamp` (GH #2596) and `AllowExamAuthoringManagedByStamp` (GH #2680 slice 3),
  and by a transaction-local setting that only this module sets.

  Frozen names (`stamp_names/0`, equal to the migrations' literal array): the six runtime types
  `certificate`, `session`, `session_answer`, `session_event`, `session_question`,
  `session_question_score` (GH #2596) and the ten exam authoring types `exam`, `exam_section`,
  `exam_question_rule`, `exam_question_rule_tag`, `exam_manual_question`, `question`,
  `answer_option`, `question_tag`, `tag`, `category` (GH #2680 slice 3).
  REQ-582 `exam_assignment` is managed by the exam module but deliberately NOT stamped: it is supplied
  by `Letflow.Entities.ManagedTypes.AssignmentDefinition`.
  Both sets are candidates only through the exam module's own `manages_entity_types`; no other
  name can be stamped.

  Shape follows `Letflow.Identity.RoleScopeGrants.Backfill`: sequential over
  `Letflow.TenantProvisioning.list_registrations/0`, ONE transaction per tenant, none across
  tenants. A per-tenant failure is recorded in the report (a tag or exception module only,
  INV-4/INV-5) and the sweep continues. Idempotent: a re-run finds every frozen-name row stamped
  and issues no UPDATE and no audit entry.

  ## Conflict rule (design 6.2)

  A name is stampable only when its JUDGED `entity_definitions` row is field-compatible with the
  exam pack's own definition: each pack `(field name, type)` pair is present on the row. The
  judged row is the ACTIVE version of the name (when none is active, the newest by `inserted_at`),
  not every version (GH #2682 / REQ-511, design 10.2: adding a field creates a new version and
  leaves the old row, so judging every version would make any upgraded name a permanent
  conflict). Every `managed_by IS NULL` row of a stampable name is still stamped, old inactive
  versions included. Extra fields are allowed; `required`, enum values, indexes, foreign keys
  and constraints are not compared (they are listed by name in `differences` for infra to read).
  All-or-nothing per name. A name with a row stamped by another module, or an incompatible row,
  is a named conflict: nothing of it is stamped or overwritten, the tenant's other names are.

  ## Classification happens under the locks (design 6.1, SECURITY F-4)

  An advisory pre-pass (outside any transaction) feeds the dry run and skips tenants with nothing
  to do. The real run NEVER stamps from it: inside the transaction it takes the name create-locks
  and the row locks, then classifies again from the locked rows and acts only on that.

  ## Entry guard (SECURITY F-1)

  `run_tenant/2` returns `status: :failed, error: :nested_transaction` when it is called inside
  an open transaction (the setting is reset at the OUTERMOST transaction's end, so it would
  otherwise outlive this module's own writes). The last statement of the stamp transaction also
  clears the setting.

  ## Snapshot gate (GH #2682 / REQ-511, design 10 and 18.3)

  A REAL run (not `dry_run: true`) is refused while
  `Application.get_env(:letflow, :exam_snapshot_complete, false)` is not `true`: `run/1` returns
  `{:error, :snapshot_not_complete}` and `run_tenant/2` returns a report with
  `status: :snapshot_not_complete` and writes nothing (no stamp, no audit entry). The flag means
  "the code that scores from the per-session exam snapshot has shipped"; it is set ONLY in
  `config/config.exs` and `config/test.exs` (both `true` since PR b), never from the environment,
  and the fail-closed default (key absent) is `false`. A dry run is always allowed.

  ## Per-tenant prerequisites (GH #2682 / REQ-511 PR b, design 10.1)

  With the flag open, a REAL run stamps a tenant only if (i) its ACTIVE `session` definition declares
  the json field `exam_snapshot` and (ii) every pair of `Exam.answer_key_fields/0` has an
  `entity_field_restrictions` row (the exam rollout, `Letflow.Release.ExamSnapshot`). Otherwise the
  tenant report has `status: :snapshot_prerequisite_missing` and
  `prerequisites_missing: [:session_definition | :answer_key_restrictions]`, nothing of it is
  stamped, and the sweep continues. The check runs only when the tenant still has an unstamped row,
  so a fully stamped tenant stays `:nothing_to_stamp`; it is repeated under the row locks. A dry run
  never has a blocked tenant.

  ## Tripwire, not a boundary

  The test scan that pins `managed_by_stamp` to this file and the two migrations makes a new
  opener a reviewed test change. It is NOT a defence against raw SQL run as the application DB
  role, exactly as before GH #2596.

  In a release (no Mix), through the wrapper:
  `bin/letflow rpc "IO.inspect(Letflow.Release.ManagedTypes.stamp(dry_run: true))"`.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Identity.AuditContext
  alias Letflow.Modules.Catalog
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # Equal to `AllowExamAuthoringManagedByStamp.stamp_names/0` (test T-10).
  @stamp_names ~w(certificate session session_answer session_event session_question session_question_score exam exam_section exam_question_rule exam_question_rule_tag exam_manual_question question answer_option question_tag tag category)

  # The tenant-schema `schema_migrations` version of `AllowExamAuthoringManagedByStamp` (it opens
  # all sixteen names; a tenant with only the #2596 six-name migration is not stamp-ready).
  @exception_version 20_261_024_120_001

  @default_lock_timeout_ms 3_000
  @statement_timeout_ms 30_000

  @compared_keys [:required, :enum_values, :decimal_strict, :constraints, :indexes]

  @type opts :: [
          module: String.t(),
          dry_run: boolean(),
          lock_timeout_ms: pos_integer(),
          after_precheck: (schema_name :: String.t() -> :ok)
        ]

  @type conflict :: %{
          type: String.t(),
          rows: pos_integer(),
          reason: :shape_not_compatible | :stamped_by_other_module
        }

  @type difference :: %{type: String.t(), extra_fields: [String.t()], differing: [atom()]}

  @type tenant_status ::
          :stamped
          | :nothing_to_stamp
          | :exam_not_installed
          | :exception_not_installed
          | :snapshot_not_complete
          | :snapshot_prerequisite_missing
          | :skipped_schema_missing
          | :failed

  @type tenant_report :: %{
          tenant_id: Ecto.UUID.t() | nil,
          schema_name: String.t(),
          status: tenant_status(),
          rows_stamped: non_neg_integer(),
          rows_already_stamped: non_neg_integer(),
          types_stamped: [String.t()],
          types_absent: [String.t()],
          conflicts: [conflict()],
          differences: [difference()],
          exam_named_types_present: [String.t()],
          prerequisites_missing: [:session_definition | :answer_key_restrictions],
          error:
            nil
            | :nested_transaction
            | :lock_timeout
            | :gap_remains
            | {:audit_failed, atom()}
            | {:unexpected_exception, module()}
        }

  @type report :: %{
          dry_run: boolean(),
          module: String.t(),
          tenants: [tenant_report()],
          rows_stamped_total: non_neg_integer(),
          conflict_total: non_neg_integer(),
          failed_total: non_neg_integer(),
          gate_blocked_total: non_neg_integer()
        }

  @typep row :: %{
           id: Ecto.UUID.t(),
           name: String.t(),
           managed_by: String.t() | nil,
           status: :active | :inactive | nil,
           inserted_at: DateTime.t() | nil,
           definition_json: map()
         }

  @typep classification :: %{
           stampable: [String.t()],
           null_ids: [Ecto.UUID.t()],
           rows_to_stamp: non_neg_integer(),
           rows_already_stamped: non_neg_integer(),
           absent: [String.t()],
           conflicts: [conflict()],
           differences: [difference()]
         }

  @doc "The frozen runtime type names the stamp can ever touch (the migration's literal array)."
  @spec stamp_names() :: [String.t()]
  def stamp_names, do: @stamp_names

  @doc """
  Sweeps every registered tenant with `run_tenant/2` under one trace id. Only `module: "exam"`
  (the default) is supported. Never halts on one tenant's failure.
  """
  @spec run(opts()) :: {:ok, report()} | {:error, :unsupported_module | :snapshot_not_complete}
  def run(opts) do
    module = Keyword.get(opts, :module, "exam")
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    cond do
      module != "exam" -> {:error, :unsupported_module}
      gate_closed?(dry_run?) -> {:error, :snapshot_not_complete}
      true -> {:ok, sweep(module, dry_run?, opts)}
    end
  end

  # `gate_blocked_total` counts the tenants a real run did not stamp because of the snapshot gate:
  # `:snapshot_prerequisite_missing` (the tenant was not rolled out) and, only if the flag flips
  # from true to false in the middle of a sweep (it is checked once in `run/1` and again per
  # tenant), `:snapshot_not_complete`. The mix task exits non-zero for either.
  defp sweep(module, dry_run?, opts) do
    tenants =
      Letflow.Obs.Logger.with_trace(fn ->
        for %Registration{schema_name: schema} <- TenantProvisioning.list_registrations() do
          run_tenant(schema, opts)
        end
      end)

    %{
      dry_run: dry_run?,
      module: module,
      tenants: tenants,
      rows_stamped_total: tenants |> Enum.map(& &1.rows_stamped) |> Enum.sum(),
      conflict_total: tenants |> Enum.map(&length(&1.conflicts)) |> Enum.sum(),
      failed_total: Enum.count(tenants, &(&1.status == :failed)),
      gate_blocked_total:
        Enum.count(
          tenants,
          &(&1.status in [:snapshot_not_complete, :snapshot_prerequisite_missing])
        )
    }
  end

  # GH #2682 / REQ-511: closed unless the flag is exactly `true`; a dry run is never blocked.
  defp gate_closed?(true = _dry_run?), do: false

  defp gate_closed?(false = _dry_run?),
    do: Application.get_env(:letflow, :exam_snapshot_complete, false) != true

  @doc """
  Stamps (or, with `dry_run: true`, only reports) one tenant schema. Never raises: any failure is
  a `status: :failed` report carrying a tag or an exception module (never a message).
  """
  @spec run_tenant(schema_name :: String.t(), opts()) :: tenant_report()
  def run_tenant(schema_name, opts) when is_binary(schema_name) do
    tenant_id = tenant_id_or_nil(schema_name)
    report = base_report(tenant_id, schema_name)

    cond do
      gate_closed?(Keyword.get(opts, :dry_run, false) == true) ->
        %{report | status: :snapshot_not_complete}

      Repo.in_transaction?() ->
        %{report | status: :failed, error: :nested_transaction}

      tenant_id == nil ->
        %{report | status: :skipped_schema_missing}

      true ->
        guarded_run(report, tenant_id, schema_name, opts)
    end
  end

  # --- per tenant -----------------------------------------------------------------------------

  defp guarded_run(report, tenant_id, schema, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true
    lock_timeout = Keyword.get(opts, :lock_timeout_ms, @default_lock_timeout_ms)

    with {:ok, candidates, pack_fields} <- reference(),
         :ok <- exam_installed(schema),
         :ok <- exception_installed(schema) do
      rows = fetch_rows(schema, tenant_id, candidates, false)
      advisory = classify(rows, candidates, pack_fields)

      missing = if dry_run?, do: [], else: prerequisites_missing(rows, schema)

      cond do
        dry_run? ->
          finish(report, advisory, advisory.rows_to_stamp)

        missing != [] ->
          prerequisite_report(report, missing)

        advisory.null_ids == [] ->
          finish(report, advisory, 0)

        true ->
          maybe_after_precheck(opts, schema)
          real_run(report, tenant_id, schema, candidates, pack_fields, lock_timeout)
      end
    else
      {:status, status} -> status_report(report, schema, status)
    end
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}}
        when code in [:undefined_table, :invalid_schema_name] ->
          %{report | status: :skipped_schema_missing}

        _other ->
          %{report | status: :failed, error: {:unexpected_exception, Postgrex.Error}}
      end

    exception ->
      %{report | status: :failed, error: {:unexpected_exception, exception.__struct__}}
  end

  defp status_report(report, schema, :exam_not_installed) do
    present =
      from(d in "entity_definitions",
        where: d.name in ^@stamp_names,
        distinct: true,
        select: d.name
      )
      |> Repo.all(prefix: schema)
      |> Enum.sort()

    %{report | status: :exam_not_installed, exam_named_types_present: present}
  end

  defp status_report(report, _schema, status), do: %{report | status: status}

  # The real run: one transaction per tenant, classification from the LOCKED rows.
  defp real_run(report, tenant_id, schema, candidates, pack_fields, lock_timeout) do
    result =
      Repo.transaction(
        fn ->
          Repo.query!("SELECT set_config('lock_timeout', $1, true)", ["#{lock_timeout}ms"])

          Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
            "#{@statement_timeout_ms}ms"
          ])

          :ok = ManagedTypes.lock_names(candidates, schema)

          rows = fetch_rows(schema, tenant_id, candidates, true)

          # Design 10.1: the prerequisites are judged again from the LOCKED rows.
          case prerequisites_missing(rows, schema) do
            [] -> :ok
            missing -> Repo.rollback({:prerequisites_missing, missing})
          end

          classification = classify(rows, candidates, pack_fields)

          stamped = stamp_rows(classification, schema, tenant_id)
          verify_stamped(schema, tenant_id, classification, stamped)

          if stamped > 0 do
            audit!(schema, tenant_id, classification, stamped)
          end

          # LAST statement: the setting is cleared even if an outer transaction were joined.
          Repo.query!("SELECT set_config('letflow.managed_by_stamp', '', true)")

          {classification, stamped}
        end,
        prefix: schema
      )

    case result do
      {:ok, {classification, stamped}} -> finish(report, classification, stamped)
      {:error, {:prerequisites_missing, missing}} -> prerequisite_report(report, missing)
      {:error, :gap_remains} -> %{report | status: :failed, error: :gap_remains}
      {:error, {:audit_failed, _tag} = error} -> %{report | status: :failed, error: error}
    end
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :lock_not_available}} ->
          %{report | status: :failed, error: :lock_timeout}

        _other ->
          %{report | status: :failed, error: {:unexpected_exception, Postgrex.Error}}
      end
  end

  # Opens the exception immediately before the single UPDATE of `managed_by` only.
  defp stamp_rows(%{null_ids: []}, _schema, _tenant_id), do: 0

  defp stamp_rows(%{null_ids: ids}, schema, tenant_id) do
    Repo.query!("SELECT set_config('letflow.managed_by_stamp', $1, true)", ["exam"])

    {count, _} =
      from(d in EntityDefinition,
        where: d.tenant_id == ^tenant_id and d.id in ^ids and is_nil(d.managed_by)
      )
      |> Repo.update_all([set: [managed_by: "exam"]], prefix: schema)

    count
  end

  defp verify_stamped(schema, tenant_id, classification, stamped) do
    expected = length(classification.null_ids)

    unstamped =
      from(d in EntityDefinition,
        where:
          d.tenant_id == ^tenant_id and d.name in ^classification.stampable and
            (is_nil(d.managed_by) or d.managed_by != "exam"),
        select: count(d.id)
      )
      |> Repo.one(prefix: schema)

    if stamped != expected or unstamped != 0 do
      Repo.rollback(:gap_remains)
    end

    :ok
  end

  defp audit!(schema, tenant_id, classification, stamped) do
    attrs = %{
      actor_id: nil,
      action: "entity_type.managed_by_stamped",
      resource_type: "entity_definitions",
      resource_id: tenant_id || schema,
      before_state: nil,
      after_state: %{
        "module" => "exam",
        "rows_stamped" => stamped,
        "types_stamped" => Enum.sort(classification.stampable),
        "conflicts" =>
          Enum.map(classification.conflicts, fn c ->
            %{"type" => c.type, "reason" => Atom.to_string(c.reason)}
          end),
        "source" => "release_stamp"
      },
      trace_id: AuditContext.current_trace_id()
    }

    case Audit.insert_entry(Repo, attrs, schema) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason_tag(reason)})
    end
  end

  # A tag or the exception module only, never the raw reason term (INV-4).
  defp reason_tag(%{__exception__: true, __struct__: module}), do: module
  defp reason_tag(%Ecto.Changeset{}), do: :invalid_changeset
  defp reason_tag(tag) when is_atom(tag), do: tag
  defp reason_tag({tag, _detail}) when is_atom(tag), do: tag
  defp reason_tag(_other), do: :unexpected_error

  defp maybe_after_precheck(opts, schema) do
    case Keyword.get(opts, :after_precheck) do
      fun when is_function(fun, 1) -> fun.(schema)
      _none -> :ok
    end
  end

  # --- pre-checks (read-only, explicit prefix, INV-1) ---------------------------------------------

  # Candidate names = the frozen six INTERSECT the exam manifest's managed set, plus the
  # pack's own definition fields for each candidate (the compatibility reference).
  defp reference do
    case Catalog.fetch("exam") do
      {:ok, entry} ->
        manifest = entry.manifest()
        managed = Map.get(manifest, :manages_entity_types, [])
        candidates = Enum.filter(@stamp_names, &(&1 in managed))
        {:ok, candidates, pack_fields(manifest.pack, candidates)}

      {:error, :not_found} ->
        {:status, :exam_not_installed}
    end
  end

  defp pack_fields(pack_path, candidates) do
    document =
      Application.app_dir(:letflow, "priv")
      |> Path.join(pack_path)
      |> File.read!()
      |> Jason.decode!()

    for %{"name" => name, "definition_json" => definition} <- document["entity_definitions"],
        name in candidates,
        into: %{},
        do: {name, definition}
  end

  defp exam_installed(schema) do
    installed? =
      Repo.exists?(from(m in "tenant_modules", where: m.module_id == "exam"), prefix: schema)

    if installed?, do: :ok, else: {:status, :exam_not_installed}
  end

  defp exception_installed(schema) do
    # The TENANT schema's own schema_migrations (not public's).
    applied? =
      Repo.exists?(from(m in "schema_migrations", where: m.version == ^@exception_version),
        prefix: schema
      )

    if applied?, do: :ok, else: {:status, :exception_not_installed}
  end

  defp fetch_rows(schema, tenant_id, names, lock?) do
    query =
      from(d in EntityDefinition,
        where: d.tenant_id == ^tenant_id and d.name in ^names,
        order_by: [asc: d.name, asc: d.id],
        select: %{
          id: d.id,
          name: d.name,
          managed_by: d.managed_by,
          status: d.status,
          inserted_at: d.inserted_at,
          definition_json: d.definition_json
        }
      )

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query
    Repo.all(query, prefix: schema)
  end

  # --- classification -------------------------------------------------------------------------

  @spec classify([row()], [String.t()], %{String.t() => map()}) :: classification()
  defp classify(rows, candidates, pack_defs) do
    by_name = Enum.group_by(rows, & &1.name)

    initial = %{
      stampable: [],
      null_ids: [],
      rows_to_stamp: 0,
      rows_already_stamped: 0,
      absent: [],
      conflicts: [],
      differences: []
    }

    candidates
    |> Enum.sort()
    |> Enum.reduce(initial, fn name, acc ->
      classify_name(name, Map.get(by_name, name, []), Map.fetch!(pack_defs, name), acc)
    end)
    |> then(fn acc ->
      %{
        acc
        | stampable: Enum.reverse(acc.stampable),
          absent: Enum.reverse(acc.absent),
          conflicts: Enum.reverse(acc.conflicts),
          differences: Enum.reverse(acc.differences)
      }
    end)
  end

  defp classify_name(name, [], _pack_def, acc), do: %{acc | absent: [name | acc.absent]}

  defp classify_name(name, rows, pack_def, acc) do
    others = Enum.filter(rows, &(&1.managed_by not in [nil, "exam"]))
    null_rows = Enum.filter(rows, &is_nil(&1.managed_by))
    incompatible = incompatible_judged_rows(rows, pack_def)

    cond do
      null_rows == [] and others == [] ->
        %{acc | rows_already_stamped: acc.rows_already_stamped + length(rows)}

      others != [] ->
        add_conflict(acc, name, length(others), :stamped_by_other_module)

      incompatible != [] ->
        add_conflict(acc, name, length(incompatible), :shape_not_compatible)

      true ->
        %{
          acc
          | stampable: [name | acc.stampable],
            null_ids: acc.null_ids ++ Enum.map(null_rows, & &1.id),
            rows_to_stamp: acc.rows_to_stamp + length(null_rows),
            rows_already_stamped: acc.rows_already_stamped + length(rows) - length(null_rows),
            differences: add_difference(acc.differences, name, rows, pack_def)
        }
    end
  end

  # Design 10.2: only the ACTIVE row of a name is judged (none active: the newest by inserted_at).
  defp incompatible_judged_rows(rows, pack_def) do
    judged = judged_row(rows)
    if compatible?(judged.definition_json, pack_def), do: [], else: [judged]
  end

  defp judged_row(rows) do
    Enum.find(rows, &(&1.status == :active)) ||
      Enum.max_by(rows, & &1.inserted_at, DateTime)
  end

  defp add_conflict(acc, name, count, reason) do
    %{acc | conflicts: [%{type: name, rows: count, reason: reason} | acc.conflicts]}
  end

  # Every pack `(field name, type)` pair is present on the row (extras allowed), and
  # for a `decimal` field the pack and the row agree on `decimal_strict` (absent =
  # false). GH #2654 / decision 0060: adopting a row whose strictness differs would
  # bypass the flag's immutability once records exist, so a mismatch is a shape
  # mismatch (also for a zero-record type: conservative, adoption is of the row's
  # definition).
  @spec compatible?(row_definition :: term(), pack_definition :: map()) :: boolean()
  @doc false
  def compatible?(row_definition, pack_definition) do
    row_fields = fields_of(row_definition)

    Enum.all?(fields_of(pack_definition), fn %{"name" => name, "type" => type} = pack_field ->
      Enum.any?(
        row_fields,
        &(&1["name"] == name and &1["type"] == type and same_strictness?(type, &1, pack_field))
      )
    end)
  end

  defp same_strictness?("decimal", row_field, pack_field),
    do: strict?(row_field) == strict?(pack_field)

  defp same_strictness?(_type, _row_field, _pack_field), do: true

  defp strict?(field), do: Map.get(field, "decimal_strict") == true

  defp fields_of(%{"fields" => fields}) when is_list(fields), do: Enum.filter(fields, &is_map/1)
  defp fields_of(_other), do: []

  # Names only, never values: which fields the tenant added and which compared attributes differ.
  @doc false
  @spec add_difference([map()], String.t(), [map()], map()) :: [map()]
  def add_difference(differences, name, rows, pack_def) do
    pack_fields = fields_of(pack_def)
    pack_names = MapSet.new(pack_fields, & &1["name"])

    extra =
      rows
      |> Enum.flat_map(&fields_of(&1.definition_json))
      |> Enum.map(& &1["name"])
      |> Enum.reject(&MapSet.member?(pack_names, &1))
      |> Enum.uniq()
      |> Enum.sort()

    differing =
      Enum.filter(@compared_keys, fn key ->
        Enum.any?(rows, &differs?(key, &1.definition_json, pack_def, pack_fields))
      end)

    if extra == [] and differing == [] do
      differences
    else
      [%{type: name, extra_fields: extra, differing: differing} | differences]
    end
  end

  defp differs?(key, row_def, _pack_def, pack_fields) when key in [:required, :enum_values] do
    row_fields = fields_of(row_def)
    attr = Atom.to_string(key)

    Enum.any?(pack_fields, fn pack_field ->
      case Enum.find(row_fields, &(&1["name"] == pack_field["name"])) do
        nil -> false
        row_field -> Map.get(row_field, attr) != Map.get(pack_field, attr)
      end
    end)
  end

  defp differs?(:decimal_strict, row_def, _pack_def, pack_fields) do
    row_fields = fields_of(row_def)

    Enum.any?(pack_fields, fn pack_field ->
      case Enum.find(row_fields, &(&1["name"] == pack_field["name"])) do
        nil -> false
        row_field -> strict?(row_field) != strict?(pack_field)
      end
    end)
  end

  defp differs?(key, row_def, pack_def, _pack_fields) do
    attr = Atom.to_string(key)
    list_of(row_def, attr) != list_of(pack_def, attr)
  end

  defp list_of(%{} = definition, attr), do: Map.get(definition, attr) || []
  defp list_of(_other, _attr), do: []

  # --- snapshot prerequisites (GH #2682 / REQ-511 PR b, design 10.1) ---------------------------------

  # [] when the tenant has nothing left to stamp or both prerequisites hold; otherwise the missing
  # ones, in a fixed order. Reads only, explicit prefix (INV-1).
  @spec prerequisites_missing([row()], String.t()) ::
          [:session_definition | :answer_key_restrictions]
  defp prerequisites_missing(rows, schema) do
    if Enum.any?(rows, &is_nil(&1.managed_by)) do
      [
        if(session_definition_current?(rows), do: nil, else: :session_definition),
        if(answer_key_restrictions_present?(schema), do: nil, else: :answer_key_restrictions)
      ]
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp session_definition_current?(rows) do
    case Enum.filter(rows, &(&1.name == "session")) do
      [] ->
        false

      session_rows ->
        session_rows
        |> judged_row()
        |> Map.fetch!(:definition_json)
        |> fields_of()
        |> Enum.any?(&(&1["name"] == "exam_snapshot" and &1["type"] == "json"))
    end
  end

  defp answer_key_restrictions_present?(schema) do
    present =
      from(r in "entity_field_restrictions", select: {r.entity_type, r.field_name})
      |> Repo.all(prefix: schema)
      |> MapSet.new()

    {:ok, exam} = Catalog.fetch("exam")
    Enum.all?(exam.answer_key_fields(), &MapSet.member?(present, &1))
  end

  defp prerequisite_report(report, missing),
    do: %{report | status: :snapshot_prerequisite_missing, prerequisites_missing: missing}

  # --- reports ----------------------------------------------------------------------------------

  defp finish(report, classification, rows_stamped) do
    stamped_names = if rows_stamped > 0, do: classification.stampable, else: []

    %{
      report
      | status: if(rows_stamped > 0, do: :stamped, else: :nothing_to_stamp),
        rows_stamped: rows_stamped,
        rows_already_stamped: classification.rows_already_stamped,
        types_stamped: stamped_names,
        types_absent: classification.absent,
        conflicts: classification.conflicts,
        differences: classification.differences
    }
  end

  defp base_report(tenant_id, schema_name) do
    %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      status: :nothing_to_stamp,
      rows_stamped: 0,
      rows_already_stamped: 0,
      types_stamped: [],
      types_absent: [],
      conflicts: [],
      differences: [],
      exam_named_types_present: [],
      prerequisites_missing: [],
      error: nil
    }
  end

  defp tenant_id_or_nil(schema) do
    case TenantProvisioning.tenant_id_for_schema_name(schema) do
      {:ok, tenant_id} -> tenant_id
      {:error, _reason} -> nil
    end
  end
end
