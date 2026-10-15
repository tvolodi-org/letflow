defmodule Letflow.Api.PermissionMatrix do
  @moduledoc """
  The effective role x permission matrix, its golden file, and the diff rule
  that keeps a module version from silently widening what a role holds
  (GH #2586 / REQ-498; decision 0055 D7 / D12 step 2a; design
  `lib/letflow/design/gh2586-permission-matrix-golden.md`).

  Pure: every function here takes its inputs as arguments (or reads only
  compiled code: `Letflow.Api.Authorization` and `Letflow.Modules.Catalog`).
  Environment, files, git and the exit status belong to
  `Mix.Tasks.Letflow.PermissionMatrix`. Nothing at request time calls this
  module; it is not an access decision.

  ## Two checks (design D4)

    * FRESHNESS (`freshness/2`): the committed golden equals the matrix the
      code computes, two-way. Every matrix change, core included, shows up as
      a reviewable golden diff.
    * CLASSIFICATION (`classify/3`): the TRUSTED baseline (the golden as
      committed at the base commit, read from git, never the working tree)
      against the computed matrix. A widening contributed by a module
      manifest fails with no override; a narrowing must be matched exactly by
      a `widens_grants` declaration; a core change is reported for review.

  A row's `via` is `:core` when it is true without any `Catalog.role_grants/1`
  contribution (`Authorization.role_allows_without_module_grants?/2`),
  `:grant` when only a manifest's `role_grants` makes it true, and `:none`
  when it is false. That per-row split is how a module widening is told
  apart from a core change (design D5).

  `core_policy_atoms` in the classification context is
  `Authorization.core_permissions/0`, a fail-closed superset of the atoms
  core route policies use (design D7, section 6); no separate list is kept.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Modules.Catalog

  @format 1
  @title "# letflow effective permission matrix"
  @regenerate "# regenerate: MIX_ENV=dev mix letflow.permission_matrix --write"
  @columns "# columns: role permission allowed owner via"
  @admin_roles ["PLATFORM_ADMIN", "TENANT_ADMIN"]

  # Exam's six atoms: their presence proves the matrix was computed over the
  # production module list (design 4.4, 0055 AC26).
  @sentinel_atoms [
    "ExamSessionStart",
    "ExamSessionRead",
    "ExamSessionSave",
    "ExamSessionSubmit",
    "ExamSessionReportEvent",
    "ExamCertificateIssue"
  ]

  # The only files that may set `config :letflow, :modules` (design 4.4a, D20).
  @modules_config_files ["config/config.exs", "config/test.exs"]

  @marker_prefix "PERMISSION-MATRIX-REPORT v1"
  @core_change_banner "CORE MATRIX CHANGE: mandatory SECURITY-REVIEWER trigger (section 9a)"

  @type role_name :: String.t()
  @type perm_name :: String.t()
  @type module_id :: String.t()
  @type owner :: :core | {:module, module_id()}
  @type via :: :core | :grant | :none
  @type row :: %{allowed: boolean(), owner: owner(), via: via()}
  @type t :: %{
          format: 1,
          modules: %{module_id() => String.t()},
          roles: [role_name()],
          permissions: [perm_name()],
          rows: %{{role_name(), perm_name()} => row()}
        }
  @type build_inputs :: %{
          allows?: (atom(), atom() -> boolean()),
          core_allows?: (atom(), atom() -> boolean()),
          module_permissions: [{module_id(), [atom()]}],
          modules: %{module_id() => String.t()}
        }
  @type context :: %{
          core_policy_atoms: MapSet.t(perm_name()),
          route_refs: %{perm_name() => [module_id()]},
          declarations: %{module_id() => [{role_name(), perm_name()}]},
          module_dirs_present: MapSet.t(module_id())
        }
  @type row_ref :: {role_name(), perm_name()}
  @type widening_reason ::
          :module_grant
          | :new_atom_non_admin_role
          | :core_policy_atom
          | :referenced_by_other_module
          | :not_routed_by_owner
          | :core_rule_on_module_atom
  @type failure ::
          {:widening, role_name(), perm_name(), widening_reason()}
          | {:unmatched_narrowing, role_name(), perm_name(), module_id()}
          | {:unattributable_narrowing, role_name(), perm_name()}
          | {:module_unregistered_but_present, module_id()}
          | {:unmatched_declaration, module_id(), role_name(), perm_name()}
          | {:declaration_authorises_widening, module_id(), role_name(), perm_name()}
  @type core_change ::
          {:added, role_name(), perm_name()}
          | {:removed, role_name(), perm_name()}
          | {:owner_changed, perm_name(), owner(), owner()}
          | {:module_removed, module_id()}
  @type report :: %{
          labels: [:pre_approved | :narrowing | :core_change | :bootstrap],
          evaluated_modules: [module_id()],
          pre_approved: [{role_name(), perm_name(), module_id()}],
          narrowings: [{role_name(), perm_name(), module_id()}],
          core_changes: [core_change()],
          inert_declarations: [{module_id(), role_name(), perm_name()}],
          failures: [failure()]
        }
  @type production_error ::
          {:wrong_env, atom()}
          | {:production_atoms_missing, [perm_name()]}
          | {:fixture_atoms_present, [perm_name()]}
  @type module_list_error ::
          {:config_modules_mismatch, :prod | :dev, [module()], [module()]}
          | {:modules_set_outside_allowed_files, Path.t(), pos_integer()}
          | {:unscannable_config, Path.t()}
  @type build_error ::
          {:duplicate_permission, atom()}
          | {:duplicate_role, atom()}
          | {:duplicate_module_permission, atom(), [module_id()]}
  @type scan_error ::
          {:unscannable_fixture_manifest, Path.t(), pos_integer()}
          | {:fixture_parse_error, Path.t()}
          | :no_fixture_sources

  # ---------------------------------------------------------------------------
  # Building the matrix
  # ---------------------------------------------------------------------------

  @doc """
  One row per (role, permission) in the injected lists. `allowed` is
  `allows?.(role, permission)`; `via` uses `core_allows?`; `owner` is the one
  module id whose RAW `module_permissions` entry lists the atom, else `:core`.
  Duplicates in either list, or one atom listed by two module ids, are errors.
  """
  @spec build([atom()], [atom()], build_inputs()) :: {:ok, t()} | {:error, build_error()}
  def build(roles, permissions, inputs) do
    with :ok <- no_duplicates(roles, :duplicate_role),
         :ok <- no_duplicates(permissions, :duplicate_permission),
         {:ok, owners} <- module_owners(inputs.module_permissions) do
      rows =
        for role <- roles, permission <- permissions, into: %{} do
          allowed = inputs.allows?.(role, permission) == true

          via =
            cond do
              not allowed -> :none
              inputs.core_allows?.(role, permission) == true -> :core
              true -> :grant
            end

          {{Atom.to_string(role), Atom.to_string(permission)},
           %{allowed: allowed, owner: Map.get(owners, permission, :core), via: via}}
        end

      {:ok,
       %{
         format: @format,
         modules: inputs.modules,
         roles: roles |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
         permissions: permissions |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
         rows: rows
       }}
    end
  end

  defp no_duplicates(list, tag) do
    case list -- Enum.uniq(list) do
      [] -> :ok
      [first | _] -> {:error, {tag, first}}
    end
  end

  defp module_owners(module_permissions) do
    by_atom =
      Enum.reduce(module_permissions, %{}, fn {id, atoms}, acc ->
        Enum.reduce(atoms, acc, fn atom, inner -> Map.update(inner, atom, [id], &[id | &1]) end)
      end)

    duplicated =
      by_atom
      |> Enum.map(fn {atom, ids} -> {atom, ids |> Enum.uniq() |> Enum.sort()} end)
      |> Enum.filter(fn {_atom, ids} -> length(ids) > 1 end)
      |> Enum.sort_by(fn {atom, _ids} -> Atom.to_string(atom) end)

    case duplicated do
      [] -> {:ok, Map.new(by_atom, fn {atom, [id | _]} -> {atom, {:module, id}} end)}
      [{atom, ids} | _] -> {:error, {:duplicate_module_permission, atom, ids}}
    end
  end

  @doc "The live matrix: `build/3` over `Authorization.roles/0` x `Authorization.permissions/0`."
  @spec current() :: {:ok, t()} | {:error, term()}
  def current do
    manifests = Catalog.all_manifests()

    build(Authorization.roles(), Authorization.permissions(), %{
      allows?: &Authorization.role_allows?/2,
      core_allows?: &Authorization.role_allows_without_module_grants?/2,
      module_permissions: Enum.map(manifests, &{&1.id, &1.permissions}),
      modules: Map.new(manifests, &{&1.id, &1.version})
    })
  end

  @doc """
  The classification context from the registered manifests. `module_dirs_present`
  is supplied by the task (ids from the BASELINE header whose
  `lib/letflow/modules/<id>/` directory exists).
  """
  @spec current_context(module_dirs_present :: MapSet.t(module_id())) :: context()
  def current_context(module_dirs_present) do
    manifests = Catalog.all_manifests()

    route_refs =
      manifests
      |> Enum.flat_map(fn manifest ->
        for {_method, _path, permission} <- manifest.route_policies,
            do: {Atom.to_string(permission), manifest.id}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {permission, ids} -> {permission, ids |> Enum.uniq() |> Enum.sort()} end)

    # Malformed entries are reported by Catalog.validate/1 (the task runs it on
    # every production manifest and fails the run); only well-formed ones are
    # classified.
    declarations =
      Map.new(manifests, fn manifest ->
        entries =
          for {role, permission} <- Map.get(manifest, :widens_grants, []),
              is_atom(role) and is_atom(permission),
              do: {Atom.to_string(role), Atom.to_string(permission)}

        {manifest.id, entries}
      end)

    %{
      core_policy_atoms: MapSet.new(Authorization.core_permissions(), &Atom.to_string/1),
      route_refs: route_refs,
      declarations: declarations,
      module_dirs_present: module_dirs_present
    }
  end

  # ---------------------------------------------------------------------------
  # Golden file format 1 (design section 2)
  # ---------------------------------------------------------------------------

  @doc "Renders `matrix` in golden format 1 (deterministic, LF only, one trailing LF)."
  @spec render(t()) :: String.t()
  def render(matrix) do
    data =
      for role <- matrix.roles, permission <- matrix.permissions do
        render_row(role, permission, Map.fetch!(matrix.rows, {role, permission}))
      end

    Enum.join(header_lines(matrix) ++ data, "\n") <> "\n"
  end

  @doc "The eight header lines of `render/1` (the task prints them as the module-list proof)."
  @spec header_lines(t()) :: [String.t()]
  def header_lines(matrix) do
    [
      @title,
      "# format: #{matrix.format}",
      @regenerate,
      "# modules: " <> render_modules(matrix.modules),
      "# roles: #{length(matrix.roles)}",
      "# permissions: #{length(matrix.permissions)}",
      "# rows: #{map_size(matrix.rows)}",
      @columns
    ]
  end

  defp render_modules(modules) when map_size(modules) == 0, do: "-"

  defp render_modules(modules) do
    modules
    |> Enum.sort()
    |> Enum.map_join(",", fn {id, version} -> "#{id}@#{version}" end)
  end

  defp render_row(role, permission, row) do
    Enum.join(
      [role, permission, to_string(row.allowed), render_owner(row.owner), render_via(row.via)],
      " "
    )
  end

  defp render_owner(:core), do: "core"
  defp render_owner({:module, id}), do: "module:" <> id

  defp render_via(:core), do: "core"
  defp render_via(:grant), do: "grant"
  defp render_via(:none), do: "-"

  @doc """
  Parses golden format 1 strictly. Roles and permissions stay strings (no
  atom is created from file input). A trailing `\\r` on a line is stripped.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> drop_final_empty()
      |> Enum.map(&String.trim_trailing(&1, "\r"))

    {header, data} = Enum.split(lines, 8)

    with {:ok, head} <- parse_header(header),
         {:ok, rows} <- parse_rows(data),
         :ok <- check_counts(head, rows) do
      {:ok,
       %{
         format: @format,
         modules: head.modules,
         roles: rows |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort(),
         permissions: rows |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort(),
         rows: rows
       }}
    end
  end

  defp drop_final_empty(lines) do
    case List.last(lines) do
      "" -> List.delete_at(lines, -1)
      _ -> lines
    end
  end

  defp parse_header(header) do
    padded = header ++ List.duplicate(nil, 8 - length(header))

    with :ok <- expect_line(Enum.at(padded, 0), @title, 1),
         :ok <- parse_format(Enum.at(padded, 1)),
         :ok <- expect_line(Enum.at(padded, 2), @regenerate, 3),
         {:ok, modules} <- parse_modules_line(Enum.at(padded, 3)),
         {:ok, roles} <- parse_count_line(Enum.at(padded, 4), "# roles: ", 5),
         {:ok, permissions} <- parse_count_line(Enum.at(padded, 5), "# permissions: ", 6),
         {:ok, rows} <- parse_count_line(Enum.at(padded, 6), "# rows: ", 7),
         :ok <- expect_line(Enum.at(padded, 7), @columns, 8) do
      {:ok, %{modules: modules, roles: roles, permissions: permissions, rows: rows}}
    end
  end

  defp expect_line(line, line, _line_no), do: :ok
  defp expect_line(_other, _expected, line_no), do: {:error, {:malformed_header, line_no}}

  defp parse_format("# format: 1"), do: :ok
  defp parse_format("# format: " <> value), do: {:error, {:unsupported_format, value}}
  defp parse_format(_other), do: {:error, {:malformed_header, 2}}

  defp parse_modules_line("# modules: -"), do: {:ok, %{}}

  defp parse_modules_line("# modules: " <> value) do
    pairs = value |> String.split(",") |> Enum.map(&String.split(&1, "@", parts: 2))

    if Enum.all?(pairs, &match?([id, version] when id != "" and version != "", &1)) and
         length(Enum.uniq_by(pairs, &hd/1)) == length(pairs) do
      {:ok, Map.new(pairs, fn [id, version] -> {id, version} end)}
    else
      {:error, {:malformed_header, 4}}
    end
  end

  defp parse_modules_line(_other), do: {:error, {:malformed_header, 4}}

  defp parse_count_line(line, prefix, line_no) when is_binary(line) do
    with true <- String.starts_with?(line, prefix),
         digits = String.replace_prefix(line, prefix, ""),
         true <- Regex.match?(~r/^(0|[1-9][0-9]*)$/, digits) do
      {:ok, String.to_integer(digits)}
    else
      _ -> {:error, {:malformed_header, line_no}}
    end
  end

  defp parse_count_line(_line, _prefix, line_no), do: {:error, {:malformed_header, line_no}}

  defp parse_rows(data) do
    data
    |> Enum.with_index(9)
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {line, line_no}, {:ok, rows, owners} ->
      with {:ok, role, permission, row} <- parse_row(line, line_no),
           :ok <- no_duplicate_row(rows, role, permission),
           :ok <- consistent_owner(owners, permission, row.owner, line_no) do
        {:cont,
         {:ok, Map.put(rows, {role, permission}, row), Map.put(owners, permission, row.owner)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows, _owners} -> {:ok, rows}
      error -> error
    end
  end

  defp parse_row(line, line_no) do
    with [role, permission, allowed, owner, via] <- String.split(line, " "),
         true <- role != "" and permission != "",
         {:ok, allowed?} <- parse_allowed(allowed),
         {:ok, owner} <- parse_owner(owner),
         {:ok, via} <- parse_via(via),
         true <- via_consistent?(allowed?, via) do
      {:ok, role, permission, %{allowed: allowed?, owner: owner, via: via}}
    else
      _ -> {:error, {:malformed_row, line_no}}
    end
  end

  defp parse_allowed("true"), do: {:ok, true}
  defp parse_allowed("false"), do: {:ok, false}
  defp parse_allowed(_other), do: :error

  defp parse_owner("core"), do: {:ok, :core}
  defp parse_owner("module:" <> id) when id != "", do: {:ok, {:module, id}}
  defp parse_owner(_other), do: :error

  defp parse_via("core"), do: {:ok, :core}
  defp parse_via("grant"), do: {:ok, :grant}
  defp parse_via("-"), do: {:ok, :none}
  defp parse_via(_other), do: :error

  defp via_consistent?(false, :none), do: true
  defp via_consistent?(true, via) when via in [:core, :grant], do: true
  defp via_consistent?(_allowed, _via), do: false

  defp no_duplicate_row(rows, role, permission) do
    if Map.has_key?(rows, {role, permission}),
      do: {:error, {:duplicate_row, role, permission}},
      else: :ok
  end

  # The owner is a property of the atom: every row of one permission must agree.
  defp consistent_owner(owners, permission, owner, line_no) do
    case Map.fetch(owners, permission) do
      {:ok, ^owner} -> :ok
      :error -> :ok
      {:ok, _other} -> {:error, {:malformed_row, line_no}}
    end
  end

  defp check_counts(head, rows) do
    keys = Map.keys(rows)
    role_count = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()
    permission_count = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length()

    cond do
      map_size(rows) != head.rows ->
        {:error, {:count_mismatch, head.rows, map_size(rows)}}

      role_count != head.roles ->
        {:error, {:count_mismatch, head.roles, role_count}}

      permission_count != head.permissions ->
        {:error, {:count_mismatch, head.permissions, permission_count}}

      role_count * permission_count != head.rows ->
        {:error, {:count_mismatch, role_count * permission_count, head.rows}}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Freshness and the true-row diff
  # ---------------------------------------------------------------------------

  @doc """
  `:ok` when the working-tree golden and the computed matrix are equal
  (parsed values, not bytes); otherwise the two-way diff as rendered row lines
  (`added` = computed only, `removed` = golden only) plus differing header fields.
  """
  @spec freshness(golden :: t(), computed :: t()) ::
          :ok
          | {:error,
             {:golden_stale,
              %{added: [String.t()], removed: [String.t()], header: [{atom(), term(), term()}]}}}
  def freshness(golden, computed) when golden == computed, do: :ok

  def freshness(golden, computed) do
    golden_lines = MapSet.new(row_lines(golden))
    computed_lines = MapSet.new(row_lines(computed))

    header =
      for {field, fun} <- [
            format: & &1.format,
            modules: & &1.modules,
            roles: &length(&1.roles),
            permissions: &length(&1.permissions),
            rows: &map_size(&1.rows)
          ],
          fun.(golden) != fun.(computed),
          do: {field, fun.(golden), fun.(computed)}

    {:error,
     {:golden_stale,
      %{
        added: computed_lines |> MapSet.difference(golden_lines) |> Enum.sort(),
        removed: golden_lines |> MapSet.difference(computed_lines) |> Enum.sort(),
        header: header
      }}}
  end

  defp row_lines(matrix) do
    for {{role, permission}, row} <- matrix.rows, do: render_row(role, permission, row)
  end

  @doc """
  Rows `allowed` in `computed` but not in `baseline` (`added`) and the
  reverse (`removed`). False rows appearing or disappearing are not diff rows.
  """
  @spec true_set_diff(baseline :: t(), computed :: t()) :: %{
          added: [row_ref()],
          removed: [row_ref()]
        }
  def true_set_diff(baseline, computed) do
    %{added: true_only(computed, baseline), removed: true_only(baseline, computed)}
  end

  defp true_only(left, right) do
    Enum.sort(for {key, %{allowed: true}} <- left.rows, not allowed?(right, key), do: key)
  end

  defp allowed?(matrix, key) do
    match?(%{allowed: true}, Map.get(matrix.rows, key))
  end

  # ---------------------------------------------------------------------------
  # Classification (design section 4.3, normative)
  # ---------------------------------------------------------------------------

  @doc """
  Classifies the change from the trusted `baseline` (or `:absent`) to
  `computed` (design section 4.3, steps 0 to 8). Never reads the
  working-tree golden.
  """
  @spec classify(baseline :: t() | :absent, computed :: t(), context()) :: report()
  def classify(:absent, _computed, _ctx) do
    %{empty_report() | labels: [:bootstrap]}
  end

  def classify(baseline, computed, ctx) do
    # Step 1: evaluated modules (new, or version changed).
    evaluated =
      for {id, version} <- computed.modules,
          Map.get(baseline.modules, id) != version,
          into: MapSet.new(),
          do: id

    # Step 2.
    %{added: added, removed: removed} = true_set_diff(baseline, computed)
    baseline_atoms = MapSet.new(baseline.permissions)
    computed_atoms = MapSet.new(computed.permissions)

    # Step 3: widening candidates.
    step3 =
      Enum.reduce(added, %{failures: [], pre_approved: [], core_changes: []}, fn {role, perm},
                                                                                 acc ->
        row = Map.fetch!(computed.rows, {role, perm})

        case classify_added(role, perm, row, baseline_atoms, ctx) do
          {:failure, failure} -> %{acc | failures: [failure | acc.failures]}
          {:pre_approved, entry} -> %{acc | pre_approved: [entry | acc.pre_approved]}
          {:core_change, change} -> %{acc | core_changes: [change | acc.core_changes]}
        end
      end)

    # Step 4: narrowing candidates.
    step4 =
      Enum.reduce(removed, %{failures: [], core_changes: [], narrowings: []}, fn {role, perm},
                                                                                 acc ->
        row = Map.fetch!(baseline.rows, {role, perm})

        case classify_removed(role, perm, row, computed, computed_atoms, ctx) do
          {:failure, failure} -> %{acc | failures: [failure | acc.failures]}
          {:core_change, change} -> %{acc | core_changes: [change | acc.core_changes]}
          {:narrowing, entry} -> %{acc | narrowings: [entry | acc.narrowings]}
        end
      end)

    # Step 5: owner changes.
    baseline_owners = owners_of(baseline)
    computed_owners = owners_of(computed)

    owner_changes =
      for perm <- MapSet.intersection(baseline_atoms, computed_atoms),
          baseline_owners[perm] != computed_owners[perm],
          do: {:owner_changed, perm, baseline_owners[perm], computed_owners[perm]}

    # Step 6: declarations.
    added_set = MapSet.new(added)
    narrowing_set = MapSet.new(step4.narrowings)

    step6 =
      ctx.declarations
      |> Enum.sort()
      |> Enum.flat_map(fn {id, entries} -> Enum.map(entries, &{id, &1}) end)
      |> Enum.reduce(%{failures: [], inert: [], matched: []}, fn {id, {role, perm}}, acc ->
        cond do
          MapSet.member?(added_set, {role, perm}) ->
            %{acc | failures: [{:declaration_authorises_widening, id, role, perm} | acc.failures]}

          not MapSet.member?(evaluated, id) ->
            %{acc | inert: [{id, role, perm} | acc.inert]}

          MapSet.member?(narrowing_set, {role, perm, id}) ->
            %{acc | matched: [{role, perm, id} | acc.matched]}

          true ->
            %{acc | failures: [{:unmatched_declaration, id, role, perm} | acc.failures]}
        end
      end)

    # Step 7: every module narrowing not matched by a declaration fails.
    matched_set = MapSet.new(step6.matched)

    unmatched =
      for {role, perm, id} = narrowing <- step4.narrowings,
          not MapSet.member?(matched_set, narrowing),
          do: {:unmatched_narrowing, role, perm, id}

    core_changes = sorted_unique(step3.core_changes ++ step4.core_changes ++ owner_changes)
    pre_approved = sorted_unique(step3.pre_approved)
    narrowings = sorted_unique(step6.matched)

    # Step 8.
    labels =
      [
        {:core_change, core_changes != []},
        {:narrowing, narrowings != []},
        {:pre_approved, pre_approved != []}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    %{
      labels: labels,
      evaluated_modules: evaluated |> MapSet.to_list() |> Enum.sort(),
      pre_approved: pre_approved,
      narrowings: narrowings,
      core_changes: core_changes,
      inert_declarations: sorted_unique(step6.inert),
      failures: sorted_unique(step3.failures ++ step4.failures ++ step6.failures ++ unmatched)
    }
  end

  defp empty_report do
    %{
      labels: [],
      evaluated_modules: [],
      pre_approved: [],
      narrowings: [],
      core_changes: [],
      inert_declarations: [],
      failures: []
    }
  end

  # Step 3.1: true only through a manifest's role_grants -- refused, no override.
  defp classify_added(role, perm, %{via: :grant}, _baseline_atoms, ctx) do
    reason =
      if MapSet.member?(ctx.core_policy_atoms, perm), do: :core_policy_atom, else: :module_grant

    {:failure, {:widening, role, perm, reason}}
  end

  # Step 3.2: a NEW module atom, true through a core rule.
  defp classify_added(role, perm, %{via: :core, owner: {:module, id}}, baseline_atoms, ctx)
       when is_binary(id) do
    if MapSet.member?(baseline_atoms, perm) do
      classify_added_existing_module_atom(role, perm)
    else
      classify_new_module_atom(role, perm, id, ctx)
    end
  end

  # Step 3.4: a core rule on a core atom.
  defp classify_added(role, perm, %{via: :core}, _baseline_atoms, _ctx) do
    {:core_change, {:added, role, perm}}
  end

  # Step 3.3 (F3) and 3.4 for an atom that already existed in the baseline.
  defp classify_added_existing_module_atom(role, perm) do
    if role in @admin_roles do
      {:core_change, {:added, role, perm}}
    else
      {:failure, {:widening, role, perm, :core_rule_on_module_atom}}
    end
  end

  defp classify_new_module_atom(role, perm, id, ctx) do
    refs = Map.get(ctx.route_refs, perm, [])

    cond do
      role not in @admin_roles ->
        {:failure, {:widening, role, perm, :new_atom_non_admin_role}}

      MapSet.member?(ctx.core_policy_atoms, perm) ->
        {:failure, {:widening, role, perm, :core_policy_atom}}

      refs -- [id] != [] ->
        {:failure, {:widening, role, perm, :referenced_by_other_module}}

      id not in refs ->
        {:failure, {:widening, role, perm, :not_routed_by_owner}}

      true ->
        {:pre_approved, {role, perm, id}}
    end
  end

  # Step 4.1: a module-owned baseline row.
  defp classify_removed(role, perm, %{owner: {:module, id}} = row, computed, computed_atoms, ctx) do
    cond do
      MapSet.member?(computed_atoms, perm) and row.via == :core ->
        {:core_change, {:removed, role, perm}}

      not Map.has_key?(computed.modules, id) ->
        if MapSet.member?(ctx.module_dirs_present, id),
          do: {:failure, {:module_unregistered_but_present, id}},
          else: {:core_change, {:module_removed, id}}

      true ->
        {:narrowing, {role, perm, id}}
    end
  end

  # Step 4.2: a core-owned baseline row (F4: a `grant` row here is never matchable).
  defp classify_removed(role, perm, %{owner: :core, via: :grant}, _computed, _atoms, _ctx) do
    {:failure, {:unattributable_narrowing, role, perm}}
  end

  defp classify_removed(role, perm, %{owner: :core}, _computed, _atoms, _ctx) do
    {:core_change, {:removed, role, perm}}
  end

  defp owners_of(matrix) do
    for {{_role, perm}, row} <- matrix.rows, into: %{}, do: {perm, row.owner}
  end

  defp sorted_unique(list), do: list |> Enum.uniq() |> Enum.sort()

  # ---------------------------------------------------------------------------
  # Production-list proof (design 4.4, 4.4a, 4.5)
  # ---------------------------------------------------------------------------

  @doc """
  Collects every applicable error, in order: the env is not `:dev`/`:prod`;
  an Exam sentinel atom is missing; a fixture atom is present.
  """
  @spec check_production_list(t(), fixture_atoms :: MapSet.t(perm_name()), env :: atom()) ::
          :ok | {:error, [production_error()]}
  def check_production_list(matrix, fixture_atoms, env) do
    permissions = MapSet.new(matrix.permissions)
    missing = Enum.reject(@sentinel_atoms, &MapSet.member?(permissions, &1))
    present = fixture_atoms |> MapSet.intersection(permissions) |> Enum.sort()

    errors =
      [
        {env not in [:dev, :prod], {:wrong_env, env}},
        {missing != [], {:production_atoms_missing, Enum.sort(missing)}},
        {present != [], {:fixture_atoms_present, present}}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  The module-list proof (design D20): `configured.prod` and `configured.dev`
  (each from `Config.Reader`) must equal `compiled` exactly, order included;
  and no `config/*.exs` other than `config/config.exs` / `config/test.exs` may
  contain a `config(:letflow, :modules, _)` call or a `config(:letflow, kw)`
  call whose keyword list names `:modules` (or is not a literal list). The
  scan matches the literal `config(...)` / `Config.config(...)` call forms only.
  """
  @spec check_module_list(
          compiled :: [module()],
          configured :: %{prod: [module()], dev: [module()]},
          config_sources :: [{Path.t(), String.t()}]
        ) :: :ok | {:error, [module_list_error()]}
  def check_module_list(compiled, configured, config_sources) do
    value_errors =
      for env <- [:prod, :dev],
          Map.fetch!(configured, env) != compiled,
          do: {:config_modules_mismatch, env, Map.fetch!(configured, env), compiled}

    source_errors =
      config_sources
      |> Enum.sort()
      |> Enum.flat_map(fn {path, source} -> scan_config_source(path, source) end)

    case value_errors ++ source_errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp scan_config_source(path, source) do
    normalized = String.replace(path, "\\", "/")

    case Code.string_to_quoted(source, file: path, columns: true) do
      {:error, _} ->
        [{:unscannable_config, path}]

      {:ok, ast} ->
        if normalized in @modules_config_files do
          []
        else
          ast
          |> modules_setting_lines()
          |> Enum.map(&{:modules_set_outside_allowed_files, path, &1})
        end
    end
  end

  defp modules_setting_lines(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, acc ->
        case config_call(node) do
          {:ok, meta, args} ->
            if sets_modules?(args),
              do: {node, [Keyword.get(meta, :line, 1) | acc]},
              else: {node, acc}

          :error ->
            {node, acc}
        end
      end)

    lines |> Enum.uniq() |> Enum.sort()
  end

  defp config_call({:config, meta, [:letflow | _] = args}), do: {:ok, meta, args}

  defp config_call(
         {{:., _, [{:__aliases__, _, [:Config]}, :config]}, meta, [:letflow | _] = args}
       ),
       do: {:ok, meta, args}

  defp config_call(_node), do: :error

  defp sets_modules?([:letflow, :modules, _value]), do: true

  defp sets_modules?([:letflow, keyword]) when is_list(keyword) do
    Enum.any?(keyword, fn
      {:modules, _value} -> true
      {key, _value} when is_atom(key) -> false
      _non_keyword_element -> true
    end)
  end

  # A non-literal keyword argument may set :modules.
  defp sets_modules?([:letflow, _non_literal]), do: true
  defp sets_modules?(_args), do: false

  @doc """
  The fixture atoms, by a static AST scan of `test/support/modules/**` sources
  (no compile of test support under dev). Every `:permissions` key/value pair
  must hold a literal atom list; anything else is an error. Over-approximates
  by design (a `permissions:` key in non-manifest fixture code also counts).
  """
  @spec fixture_permissions([{Path.t(), String.t()}]) ::
          {:ok, MapSet.t(perm_name())} | {:error, scan_error()}
  def fixture_permissions([]), do: {:error, :no_fixture_sources}

  def fixture_permissions(sources) do
    sources
    |> Enum.sort()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {path, source}, {:ok, acc} ->
      with {:ok, ast} <- parse_fixture(path, source),
           {:ok, atoms} <- permissions_in(ast, path) do
        {:cont, {:ok, MapSet.union(acc, atoms)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp parse_fixture(path, source) do
    case Code.string_to_quoted(source, file: path, columns: true) do
      {:ok, ast} -> {:ok, ast}
      {:error, _} -> {:error, {:fixture_parse_error, path}}
    end
  end

  defp permissions_in(ast, path) do
    case collect_permissions(ast, 1, []) do
      {:ok, atoms} -> {:ok, MapSet.new(atoms, &Atom.to_string/1)}
      {:bad, line} -> {:error, {:unscannable_fixture_manifest, path, line}}
    end
  end

  # Walks the AST carrying the nearest enclosing line (a 2-tuple has no meta).
  defp collect_permissions({:permissions, value}, line, acc) do
    if is_list(value) and Enum.all?(value, &is_atom/1),
      do: {:ok, value ++ acc},
      else: {:bad, node_line(value, line)}
  end

  defp collect_permissions({left, right}, line, acc) do
    with {:ok, acc} <- collect_permissions(left, line, acc) do
      collect_permissions(right, line, acc)
    end
  end

  defp collect_permissions({callee, meta, args}, line, acc) when is_list(meta) do
    line = Keyword.get(meta, :line, line)

    with {:ok, acc} <- collect_permissions(callee, line, acc) do
      if is_list(args), do: collect_permissions(args, line, acc), else: {:ok, acc}
    end
  end

  defp collect_permissions(list, line, acc) when is_list(list) do
    Enum.reduce_while(list, {:ok, acc}, fn element, {:ok, inner} ->
      case collect_permissions(element, line, inner) do
        {:ok, next} -> {:cont, {:ok, next}}
        bad -> {:halt, bad}
      end
    end)
  end

  defp collect_permissions(_leaf, _line, acc), do: {:ok, acc}

  defp node_line({_callee, meta, _args}, line) when is_list(meta),
    do: Keyword.get(meta, :line, line)

  defp node_line(_value, line), do: line

  # ---------------------------------------------------------------------------
  # Baseline, bootstrap, marker, report
  # ---------------------------------------------------------------------------

  @doc """
  The baseline ref must not be HEAD and must be an ancestor of the ANCHOR
  (HEAD's first parent when HEAD has two or more parents, else HEAD); the
  caller computes `ancestor_of_anchor?` with git (design section 5 step 7).
  """
  @spec check_baseline_ref(
          ref_sha :: String.t(),
          head_sha :: String.t(),
          head_parent_count :: non_neg_integer(),
          ancestor_of_anchor? :: boolean()
        ) :: :ok | {:error, :baseline_is_head | :baseline_not_ancestor}
  def check_baseline_ref(sha, sha, _head_parent_count, _ancestor_of_anchor?),
    do: {:error, :baseline_is_head}

  def check_baseline_ref(_ref_sha, _head_sha, _head_parent_count, true), do: :ok

  def check_baseline_ref(_ref_sha, _head_sha, _head_parent_count, false),
    do: {:error, :baseline_not_ancestor}

  @doc "The git rev that is the ancestry anchor for a HEAD with `head_parent_count` parents."
  @spec baseline_anchor(head_parent_count :: non_neg_integer()) :: String.t()
  def baseline_anchor(head_parent_count) when head_parent_count >= 2, do: "HEAD^1"
  def baseline_anchor(_head_parent_count), do: "HEAD"

  @doc """
  No baseline golden is acceptable only when the base commit also lacks the
  task file (the introducing change, design D18).
  """
  @spec bootstrap_allowed?(
          baseline_golden_present? :: boolean(),
          baseline_task_present? :: boolean()
        ) ::
          boolean()
  def bootstrap_allowed?(false, false), do: true
  def bootstrap_allowed?(_golden_present?, _task_present?), do: false

  @doc """
  The single pass line: `PERMISSION-MATRIX-REPORT v1 baseline=<ref> head=<head>
  labels=<comma list or -> result=pass`.
  """
  @spec report_marker(ref_sha :: String.t(), head_sha :: String.t(), report()) :: String.t()
  def report_marker(ref_sha, head_sha, report) do
    labels =
      case report.labels do
        [] -> "-"
        labels -> Enum.map_join(labels, ",", &Atom.to_string/1)
      end

    "#{@marker_prefix} baseline=#{ref_sha} head=#{head_sha} labels=#{labels} result=pass"
  end

  @doc """
  Human-readable classification report. When `labels` contains
  `:core_change`, the FIRST line is the mandatory SECURITY-REVIEWER banner.
  """
  @spec format_report(report()) :: String.t()
  def format_report(report) do
    banner = if :core_change in report.labels, do: [@core_change_banner], else: []

    labels =
      case report.labels do
        [] -> "-"
        labels -> Enum.map_join(labels, ",", &Atom.to_string/1)
      end

    sections = [
      "permission matrix classification: labels=#{labels}",
      section(
        "modules evaluated (new or version changed)",
        report.evaluated_modules,
        & &1
      ),
      section(
        "pre-approved rows (new module atom, PLATFORM_ADMIN/TENANT_ADMIN)",
        report.pre_approved,
        fn {r, p, id} ->
          "#{r} #{p} (module #{id})"
        end
      ),
      section("matched narrowings (widens_grants)", report.narrowings, fn {r, p, id} ->
        "#{r} #{p} (module #{id})"
      end),
      section("core matrix changes", report.core_changes, &format_core_change/1),
      section("inert declarations (module version unchanged)", report.inert_declarations, fn {id,
                                                                                              r,
                                                                                              p} ->
        "#{id}: {#{r}, #{p}}"
      end),
      section("failures", report.failures, &format_failure(&1, report.evaluated_modules))
    ]

    Enum.join(banner ++ sections, "\n") <> "\n"
  end

  defp section(title, [], _fun), do: "#{title}: none"

  defp section(title, items, fun) do
    Enum.join(["#{title}:" | Enum.map(items, &("  " <> fun.(&1)))], "\n")
  end

  defp format_core_change({:added, r, p}), do: "added #{r} #{p}"
  defp format_core_change({:removed, r, p}), do: "removed #{r} #{p}"

  defp format_core_change({:owner_changed, p, from, to}),
    do: "owner of #{p}: #{render_owner(from)} -> #{render_owner(to)}"

  defp format_core_change({:module_removed, id}), do: "module #{id} removed"

  defp format_failure({:unmatched_narrowing, _r, _p, id} = failure, evaluated) do
    hint =
      if id in evaluated,
        do: "declare it in module #{id}'s widens_grants",
        else: "bump the module version and declare it in `widens_grants`"

    describe(failure) <> " -- " <> hint
  end

  defp format_failure(failure, _evaluated), do: describe(failure)

  @doc "One line describing any failure or error term this module or the task produces."
  @spec describe(term()) :: String.t()
  def describe({:wrong_env, :test}) do
    "letflow.permission_matrix refuses MIX_ENV=test: config/test.exs registers the " <>
      "test/support/modules fixtures, so this would not be the production matrix. Run " <>
      "MIX_ENV=dev mix letflow.permission_matrix --check"
  end

  def describe({:wrong_env, env}),
    do:
      "letflow.permission_matrix runs only under MIX_ENV=dev or MIX_ENV=prod (got #{env}); " <>
        "run MIX_ENV=dev mix letflow.permission_matrix --check"

  def describe({:production_atoms_missing, atoms}),
    do:
      "production atoms missing from the matrix (not the production module list?): #{Enum.join(atoms, ", ")}"

  def describe({:fixture_atoms_present, atoms}),
    do:
      "test fixture atoms present in the matrix (not the production module list): #{Enum.join(atoms, ", ")}"

  def describe({:widening, r, p, reason}),
    do:
      "widening refused (#{reason}): #{r} gains #{p}; no override until per-tenant grant snapshots exist"

  def describe({:unmatched_narrowing, r, p, id}),
    do: "unmatched narrowing: #{r} loses #{p} (module #{id}) without an exact widens_grants entry"

  def describe({:unattributable_narrowing, r, p}),
    do: "unattributable narrowing: #{r} loses #{p}, a core atom that was granted by a module"

  def describe({:module_unregistered_but_present, id}),
    do: "module #{id} dropped from the module list while lib/letflow/modules/#{id}/ still exists"

  def describe({:unmatched_declaration, id, r, p}),
    do: "widens_grants entry {#{r}, #{p}} of module #{id} matches no narrowing row"

  def describe({:declaration_authorises_widening, id, r, p}),
    do:
      "widens_grants entry {#{r}, #{p}} of module #{id} names a WIDENING row; widening is refused, not signed off"

  def describe({:golden_stale, %{added: added, removed: removed, header: header}}) do
    lines =
      Enum.map(header, fn {field, golden, computed} ->
        "  header #{field}: golden #{inspect(golden)}, computed #{inspect(computed)}"
      end) ++
        Enum.map(added, &("  + " <> &1)) ++ Enum.map(removed, &("  - " <> &1))

    # The task's final message ends with the regenerate command (design section 5 step 10).
    Enum.join(
      ["golden stale: priv/permission_matrix/effective.golden differs from the computed matrix:"] ++
        lines,
      "\n"
    )
  end

  def describe(other), do: inspect(other)
end
