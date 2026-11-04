defmodule Mix.Tasks.Letflow.CheckBoundaries do
  @shortdoc "Enforces D3 module boundary rules (0039) via xref file-level edges"

  @moduledoc """
  Implements REQ-405 — the xref-based module boundary check mandated by
  `docs/migration/decisions/0039-platform-module-solution-layering.md` §D3.

  Shells out to `mix xref graph --format plain`, parses the file-level
  dependency edges it emits, and classifies each edge against seven rules
  (see §2 of the design artefact `lib/letflow/design/req405-check-boundaries.md`).

  ## What it checks

  Two classes of violation are detected:

  * **Rule 5 — outsider imports module subdir file.** A file outside every
    `lib/letflow/modules/<id>/` subdirectory (including core mechanism files
    like `lib/letflow/modules/catalog.ex` itself — which is one permitted
    exception, see below) may not reference a file inside any module
    subdirectory.
  * **Rule 4 — unauthorized cross-module reference.** A file in
    `lib/letflow/modules/a/` may reference a file in
    `lib/letflow/modules/b/` only if `b` appears in module `a`'s
    manifest `depends_on` list (as read from
    `Letflow.Modules.Catalog.all_manifests/0`).
  * **Rule 6 — layer rule (GH 2534 PR 7c-2, decision 0053 F10).** A
    declarative table (`layer_rules/0`) of forbidden source -> target path
    prefixes, evaluated BEFORE Rule 0. Today it holds three rows. Row 0: the engine
    (`lib/letflow/engine.ex`, `lib/letflow/engine/**`) may not reference the
    entities context (`lib/letflow/entities.ex`, `lib/letflow/entities/**`);
    entity records reach the engine only through the engine-defined
    `Letflow.Engine.EntityPort` (0054 D2; it subsumed 0053's `ScriptReadPort`), whose
    implementation is selected from `config :letflow, :entity_port` at run time (a config value, not a
    file edge). Rows 1 and 2 (SEC F8, GH 2632): the scripts namespace may not reference the
    engine, the port, the write-callback holders or the entities write API, and the script
    task dispatcher may not reference `Letflow.Definitions` or the write-callback holders
    (it keeps `engine.ex` for `apply_script_task_result/3` and `engine/entity_port.ex` for
    the one `prefetch` read).

    **Rule 6 checks DIRECT file edges ONLY.** `mix xref graph --format plain`
    lists each file with the files it references itself; Rule 6 classifies
    exactly those edges and never computes a transitive closure. An INDIRECT
    path through a third layer is therefore not a Rule 6 violation. One such
    path exists and is accepted under F10's reading ("the engine names no
    entities module"), as signed at the 7c-1 gate: engine ->
    `Letflow.Scripts.Runtime` -> `Letflow.Scripts.Policy` ->
    `Letflow.Entities.Definitions` (definition METADATA for the run-time
    `check_reads` re-check; entity RECORDS are read only through the port).
    A transitive reading of F10 would need a different check, not this rule.

  ## Ledger vocabulary rules (REQ-620 criterion 10, Rules 7 and 7b)

  The ledger is domain-neutral. `ledger_scan_paths/0` names the files it covers (today the two
  ledger migrations, `priv/repo/migrations/*_create_ledger_*.exs`, plus `lib/letflow/ledger/**`
  and `lib/letflow/modules/ledger_registration.ex` once they exist). Each is parsed with
  `Code.string_to_quoted/2` and walked; comments and the arguments of `@moduledoc`, `@doc`
  and `@typedoc` are not part of the scan.

  * **Rule 7 — neutral vocabulary.** No atom, variable or function name, alias part or string
    literal contains a whole word of the denylist (stock, item, location, warehouse, site, lot,
    serial, sku, material, inventory, bin, pallet; plural `s`/`es` too). Identifiers are split on
    `_`, non-alphanumerics and camelCase, so `binary` and `website` pass. A reviewed exception is
    a `{file, word}` pair in `@neutral_vocabulary_allowlist`.
  * **Rule 7b — no module reference.** The only `Letflow.Modules.*` name the ledger files may
    use is `Letflow.Modules.LedgerRegistration`.

  ## Ledger call-site rule and policy allowlist (REQ-684, slice L3a)

  Both are pure functions over `[{path, source}]` parsed with `Code.string_to_quoted/2`; comments and
  strings never match because only AST nodes are inspected, and `alias` directives (plain, `as:` and
  the `A.{B, C}` form) are resolved file-wide before the scan.

  * **Rule 8 — single call site, no forgery** (`rule_8_violations/1`, files from `rule_8_paths/0`:
    `lib/letflow/modules/<id>/**`, `lib/letflow/scripts/**`, `lib/letflow/engine/wasm/**`; the
    registration module and `lib/letflow/ledger/**` are exempt by construction). Clause `:a`: a call
    of `Letflow.Ledger.post` or `Letflow.Ledger.Capability.mint`. `:b`: any other `Letflow.Ledger`
    function than the reads `authorize`, `balances`, `entries`, `reconcile`, any call on another
    `Letflow.Ledger.*` module except `Letflow.Ledger.Policy`, and an `import`/`use`/`require` of
    them. `:c`: an alias, struct literal, struct pattern or `%{__struct__: ...}` map of
    `Letflow.Ledger.Capability`, `Letflow.Ledger.Authorized` or `Letflow.Api.Scope.Principal`.
    `:d`: `apply`, `Kernel.apply`, `:erlang.apply`, `Module.concat`, `Module.safe_concat`,
    `String.to_existing_atom` (a name could be built at run time). `:e`: a policy file (under
    `ledger_policy/`) naming a `Letflow.*` module other than `Letflow.Ledger.Policy` and the modules
    its own files define. `@rule_8_exemptions` is the reviewed list of real-tree `:d` sites whose
    argument is a closed value; `run/1` applies it, the pure function does not.
  * **Policy allowlist** (`policy_violations/1`, files from `policy_paths/0`, i.e.
    `lib/letflow/modules/<id>/ledger_policy/**`): a posting policy is pure, so only `Enum`, `Map`,
    `List`, `String`, `Integer`, `Keyword`, `MapSet`, `Tuple`, `Access`, `Decimal`,
    `Letflow.Ledger.Policy` and modules defined in the same files are allowed (by omission, so
    `Repo`, `Process`, `Regex`, `DateTime`, `Kernel.*` remote calls and every Erlang module are
    refused), plus no atom creation from text, no `send`/`spawn`/`self`/`apply`/`receive` and no
    call on a non-literal module.

  ## Permitted exceptions (Rules 0–3)

  * Rule 0: any edge whose target is NOT inside a `lib/letflow/modules/<id>/`
    subdirectory is always `:ok` — only module-subdir targets are boundary-checked.
  * Rule 1: `lib/letflow/modules/catalog.ex` is the one sanctioned importer
    allowed to reference module-subdir files (D3 explicit exception).
  * Rule 2: intra-module references (`lib/letflow/modules/a/x.ex` →
    `lib/letflow/modules/a/y.ex`) are always `:ok`.
  * Rule 3: authorized cross-module references (target's id is in source
    module's `depends_on`) are `:ok`.

  Rule 6 is evaluated before Rule 0, so its targets are checked even though
  they are not module-subdir files.

  ## Scope gate

  Edges whose source does NOT start with `"lib/"` are skipped entirely.
  Edges whose source starts with `"test/support/"` are excluded.
  (Test code in `test/support/` commonly imports module files for fixture
  purposes; that is intentional and not a boundary violation.)

  ## Exit codes

  * `0` — no violations found; prints OK summary.
  * Non-zero (via `Mix.raise/1`) — at least one violation; prints every
    offending edge in `VIOLATION: <source> -> <target> (<reason>)` format.

  ## No new dependencies

  `mix xref graph --format plain` is a built-in Mix command. `System.cmd/3`
  is Erlang/OTP stdlib. `Letflow.Modules.Catalog` is an existing module in
  this codebase (REQ-400). `mix.lock` is unchanged by this requirement.

  ## Usage

      mix letflow.check_boundaries

  Wired into the `letflow.check` alias after `compile --warnings-as-errors`
  and before `letflow.check.test` so boundary violations surface in seconds
  without waiting for the full test run.
  """

  use Mix.Task

  @typedoc "Module-id → list of dependency module-ids the module declares."
  @type depends_on_map :: %{String.t() => [String.t()]}

  @typedoc "Override shape for the injectable xref-runner seam (test-only)."
  @type xref_runner :: (-> {String.t(), non_neg_integer()})

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_argv) do
    {output, exit_code} = run_xref()

    if exit_code != 0 do
      Mix.raise(
        "mix letflow.check_boundaries: mix xref exited #{exit_code} -- " <>
          "cannot check boundaries without a valid xref graph.\n#{output}"
      )
    end

    edges = parse_xref_output(output)
    depends_on_map = build_depends_on_map(Letflow.Modules.Catalog.all_manifests())
    results = classify_edges(edges, depends_on_map)

    violations =
      Enum.flat_map(Enum.zip(edges, results), fn
        {{src, tgt}, {:violation, reason}} -> [{src, tgt, reason}]
        _ -> []
      end)

    ledger_paths = ledger_scan_paths()

    ledger_violations =
      ledger_paths
      |> Enum.map(&{&1, File.read!(&1)})
      |> ledger_rule_violations()

    for {path, rule, detail} <- ledger_violations do
      IO.puts("VIOLATION: #{path} (#{rule}: #{detail})")
    end

    rule_8_files = Enum.map(rule_8_paths(), &{&1, File.read!(&1)})
    policy_files = Enum.map(policy_paths(), &{&1, File.read!(&1)})

    call_site_violations =
      apply_rule_8_exemptions(rule_8_violations(rule_8_files)) ++ policy_violations(policy_files)

    for {path, rule, detail} <- call_site_violations do
      IO.puts("VIOLATION: #{path} (#{rule}: #{inspect(detail)})")
    end

    ledger_violations = ledger_violations ++ call_site_violations

    if violations == [] and ledger_violations == [] do
      IO.puts("mix letflow.check_boundaries: OK -- #{length(edges)} edges checked, 0 violations")

      IO.puts(
        "mix letflow.check_boundaries: ledger rules 7/7b OK -- #{length(ledger_paths)} files; " <>
          "rule 8 -- #{length(rule_8_files)} files; policy allowlist -- #{length(policy_files)} files"
      )

      :ok
    else
      for {src, tgt, reason} <- violations do
        IO.puts("VIOLATION: #{src} -> #{tgt} (#{reason})")
      end

      Mix.raise(
        "mix letflow.check_boundaries: FAILED -- #{length(violations) + length(ledger_violations)} violation(s) found"
      )
    end
  end

  @doc """
  Parses the plain-text output of `mix xref graph --format plain` into a
  flat list of `{source, target}` pairs.

  The format emitted by Mix uses tree characters for target lines:

      lib/a.ex
      |-- lib/b.ex (compile)
      `-- lib/c.ex

  Non-prefixed lines (no leading `|-- ` or `` `-- ``) are source file paths.
  Lines prefixed with `|-- ` or `` `-- `` are target paths for the most recent
  source. Suffix annotations like `" (compile)"` or `" (runtime)"` are stripped
  from target paths. Blank or whitespace-only lines are skipped. Returns `[]`
  on empty or blank input; never raises.
  """
  @spec parse_xref_output(String.t()) :: [{String.t(), String.t()}]
  def parse_xref_output(output) when is_binary(output) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce({nil, []}, fn line, {current_source, acc} ->
      cond do
        String.starts_with?(line, "|-- ") or String.starts_with?(line, "`-- ") ->
          # Target line: strip the prefix and any annotation
          target =
            line
            |> String.slice(4..-1//1)
            |> strip_annotation()

          if current_source != nil do
            {current_source, [{current_source, target} | acc]}
          else
            {nil, acc}
          end

        String.starts_with?(line, " ") ->
          # Indented line (alternative format or older Elixir version) — also a target
          target =
            line
            |> String.trim_leading()
            |> strip_annotation()

          if current_source != nil do
            {current_source, [{current_source, target} | acc]}
          else
            {nil, acc}
          end

        true ->
          # Non-prefixed line — new source
          {line, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc """
  Builds a `depends_on_map` from a list of module manifests.

  Maps `manifest.id → manifest.depends_on` for every manifest in the list.
  Used by `classify_edge/2` to decide whether a cross-module reference is
  authorized.
  """
  @spec build_depends_on_map([Letflow.Modules.Module.manifest()]) :: depends_on_map()
  def build_depends_on_map(manifests) when is_list(manifests) do
    Map.new(manifests, fn manifest -> {manifest.id, manifest.depends_on} end)
  end

  @doc """
  Classifies a single xref edge against the D3 boundary rules.

  Takes one `{source_path, target_path}` edge and a pre-built `depends_on_map`
  (from `build_depends_on_map/1`). Returns `:ok` or `{:violation, reason}`.

  Rules are applied in first-match order:

  * **Scope gate** — source not starting with `"lib/"` or starting with
    `"test/support/"` → `:ok` (out of scope).
  * **Rule 6** — the edge's source and target match one row of
    `layer_rules/0` → `{:violation, ...}` naming the row's reason. A DIRECT
    edge only: this function sees one edge, never a path.
  * **Rule 0** — target not in a `lib/letflow/modules/<id>/` subdir → `:ok`.
  * **Rule 1** — source is `"lib/letflow/modules/catalog.ex"` → `:ok`
    (sanctioned importer).
  * **Rule 2** — source and target in the same module subdir → `:ok`
    (intra-module reference).
  * **Rule 3** — source in module subdir `a`, target in `b`, and `b` is
    in `a`'s `depends_on` → `:ok` (authorized cross-module reference).
  * **Rule 4** — source in module subdir `a`, target in `b`, `b` NOT in
    `a`'s `depends_on` → `{:violation, ...}` (unauthorized cross-module).
  * **Rule 5** — source outside all module subdirs, target inside one →
    `{:violation, ...}` (outsider imports module).

  This function is pure (stateless, no I/O) and unit-testable with synthetic
  edge lists.
  """
  @spec classify_edge({String.t(), String.t()}, depends_on_map()) ::
          :ok | {:violation, String.t()}
  def classify_edge({source, target} = edge, depends_on_map) do
    # Rule 6 is computed once per edge (nil = no layer rule broken).
    layer_reason = layer_violation(edge)

    cond do
      # Scope gate: source not under lib/ → out of scope
      not String.starts_with?(source, "lib/") ->
        :ok

      # Scope gate: test/support/ sources are excluded
      String.starts_with?(source, "test/support/") ->
        :ok

      # Rule 6: a forbidden layer edge (DIRECT edges only), before Rule 0
      layer_reason != nil ->
        {:violation, layer_reason}

      # Rule 0: target not in a module subdir → always OK
      not path_in_module_subdir?(target) ->
        :ok

      # Rule 1: catalog.ex is the sanctioned importer
      source == "lib/letflow/modules/catalog.ex" ->
        :ok

      # Rule 2: source and target in the same module subdir (intra-module)
      path_in_module_subdir?(source) and
          module_id_from_path(source) == module_id_from_path(target) ->
        :ok

      # Rule 3: source in module subdir, target is an authorized dependency
      path_in_module_subdir?(source) and
          module_id_from_path(target) in Map.get(depends_on_map, module_id_from_path(source), []) ->
        :ok

      # Rule 4: source in module subdir, target not authorized
      path_in_module_subdir?(source) ->
        src_id = module_id_from_path(source)
        tgt_id = module_id_from_path(target)

        {:violation,
         "unauthorized cross-module: lib/letflow/modules/#{src_id}/ → " <>
           "lib/letflow/modules/#{tgt_id}/ (#{tgt_id} not in #{src_id}'s depends_on)"}

      # Rule 5: source outside all module subdirs, target inside one
      true ->
        {:violation,
         "boundary violation: #{source} → #{target} " <>
           "(only lib/letflow/modules/catalog.ex may reference module-subdir files)"}
    end
  end

  @neutral_words ~w(stock item location warehouse site lot serial sku material inventory bin pallet)
  @neutral_regex Regex.compile!("\\A(" <> Enum.join(@neutral_words, "|") <> ")(s|es)?\\z")

  # A new `{file, word}` pair here is a reviewed diff; it starts empty.
  @neutral_vocabulary_allowlist []

  @doc """
  The files Rules 7 and 7b scan: the ledger migrations, the ledger namespace and the one
  registration module, kept only where they exist.
  """
  @spec ledger_scan_paths() :: [String.t()]
  def ledger_scan_paths do
    fixed =
      Enum.filter(
        [
          "lib/letflow/ledger.ex",
          "lib/letflow/modules/ledger_registration.ex",
          "lib/letflow/ledger/handler_post.ex",
          "lib/letflow/ledger/failure.ex",
          "lib/letflow/ledger/codes.ex"
        ],
        &File.regular?/1
      )

    Enum.sort(
      Enum.uniq(
        Path.wildcard("lib/letflow/ledger/**/*.ex") ++
          Path.wildcard("priv/repo/migrations/*_create_ledger_*.exs") ++
          Path.wildcard("priv/repo/migrations/*_move_ledger_*.exs") ++ fixed
      )
    )
  end

  @doc """
  Rules 7 and 7b over `[{path, source}]`: `[{path, rule, detail}]` (empty when clean). Pure.
  A source that does not parse is a violation, never a raise.
  """
  @spec ledger_rule_violations([{String.t(), String.t()}]) ::
          [{String.t(), :rule_7 | :rule_7b | :parse_error, String.t()}]
  def ledger_rule_violations(files) when is_list(files) do
    check_neutral_vocabulary(files) ++ check_module_references(files)
  end

  @doc "Rule 7: denylisted whole words in identifiers, alias parts and string literals."
  @spec check_neutral_vocabulary([{String.t(), String.t()}]) :: [{String.t(), atom(), String.t()}]
  def check_neutral_vocabulary(files) do
    Enum.flat_map(files, fn {path, source} ->
      case scan_tokens(source) do
        {:error, detail} ->
          [{path, :parse_error, detail}]

        {:ok, tokens, _aliases} ->
          tokens
          |> Enum.flat_map(&token_words/1)
          |> Enum.filter(&Regex.match?(@neutral_regex, &1))
          |> Enum.uniq()
          |> Enum.reject(&({Path.basename(path), &1} in @neutral_vocabulary_allowlist))
          |> Enum.map(&{path, :rule_7, "denylisted word #{inspect(&1)}"})
      end
    end)
  end

  @doc "Rule 7b: any `Letflow.Modules.*` reference other than `Letflow.Modules.LedgerRegistration`."
  @spec check_module_references([{String.t(), String.t()}]) ::
          [{String.t(), atom(), String.t()}]
  def check_module_references(files) do
    Enum.flat_map(files, fn {path, source} ->
      case scan_tokens(source) do
        # the parse error is reported once, by Rule 7
        {:error, _detail} ->
          []

        {:ok, tokens, aliases} ->
          alias_hits =
            for [:Letflow, :Modules | rest] = parts <- aliases, rest != [:LedgerRegistration] do
              {path, :rule_7b, "module reference " <> Enum.join(parts, ".")}
            end

          string_hits =
            for t <- tokens,
                is_binary(t),
                String.starts_with?(t, "Elixir.Letflow.Modules.") do
              {path, :rule_7b, "module reference string " <> inspect(t)}
            end

          Enum.uniq(alias_hits ++ string_hits)
      end
    end)
  end

  # ── Rule 8 and the policy allowlist (REQ-684) ──────────────────────────────────────────────

  @rule_8_reads [:authorize, :balances, :entries, :reconcile]
  @rule_8_forged [
    "Letflow.Ledger.Capability",
    "Letflow.Ledger.Authorized",
    "Letflow.Api.Scope.Principal"
  ]
  @policy_module "Letflow.Ledger.Policy"

  # Reviewed `{path, {clause, detail}}` pairs of the real tree that clause :d flags and that are
  # allowed because the argument is a closed value, read at implement time (REQ-684):
  #   * procurement/decisions.ex: String.to_existing_atom(input.decision), after the decision
  #     text was matched against a fixed list of names;
  #   * procurement/router.ex: apply(LineEvents, operation, ...) with a literal module alias and an
  #     operation chosen from a fixed list of function names in the same file;
  #   * scripts/policy.ex: String.to_existing_atom(sod), after the value was matched against a fixed
  #     list of names.
  # A new pair is a reviewed diff; a test pins this list and that each pair still raw-violates.
  @rule_8_exemptions [
    {"lib/letflow/modules/procurement/decisions.ex", {:d, "String.to_existing_atom"}},
    {"lib/letflow/modules/procurement/router.ex", {:d, "apply"}},
    {"lib/letflow/scripts/policy.ex", {:d, "String.to_existing_atom"}}
  ]

  @doc "The reviewed exemptions of Rule 8 clause d (see the comment above the attribute)."
  @spec rule_8_exemptions() :: [{String.t(), {atom(), String.t()}}]
  def rule_8_exemptions, do: @rule_8_exemptions

  @doc "Drops the Rule 8 violations that `rule_8_exemptions/0` lists. Pure."
  @spec apply_rule_8_exemptions([{String.t(), atom(), term()}]) :: [{String.t(), atom(), term()}]
  def apply_rule_8_exemptions(violations) do
    Enum.reject(violations, fn
      {path, :rule_8, form} -> {path, form} in @rule_8_exemptions
      _other -> false
    end)
  end

  @doc "The files Rule 8 scans: module subdirectories, scripts and the WASM host code."
  @spec rule_8_paths() :: [String.t()]
  def rule_8_paths do
    Enum.sort(
      Path.wildcard("lib/letflow/modules/*/**/*.ex") ++
        Path.wildcard("lib/letflow/scripts/**/*.ex") ++
        Path.wildcard("lib/letflow/engine/wasm/**/*.ex")
    )
  end

  @doc "The files the policy allowlist scans: every file under a module's `ledger_policy/`."
  @spec policy_paths() :: [String.t()]
  def policy_paths,
    do: Enum.sort(Path.wildcard("lib/letflow/modules/*/ledger_policy/**/*.ex"))

  @doc """
  Rule 8 over `[{path, source}]`: `[{path, :rule_8, {clause, detail}}]`, clause `:a` to `:e`, or
  `{path, :parse_error, detail}`. Pure. A file under `lib/letflow/ledger/` and the registration
  module are skipped (exempt by construction).
  """
  @spec rule_8_violations([{String.t(), String.t()}]) :: [{String.t(), atom(), term()}]
  def rule_8_violations(files) when is_list(files) do
    files = Enum.reject(files, fn {path, _} -> rule_8_exempt_path?(path) end)
    parsed = Enum.map(files, fn {path, source} -> {path, parse_source(source)} end)

    defined =
      for {path, {:ok, ast}} <- parsed, policy_file?(path), name <- defined_modules(ast), do: name

    Enum.flat_map(parsed, fn
      {path, {:error, detail}} ->
        [{path, :parse_error, detail}]

      {path, {:ok, ast}} ->
        env = alias_env(ast)
        {_, hits} = Macro.prewalk(ast, [], &rule_8_node(&1, &2, env))

        hits =
          if policy_file?(path),
            do: hits ++ policy_reference_hits(ast, env, defined),
            else: hits

        hits |> Enum.uniq() |> Enum.map(&{path, :rule_8, &1})
    end)
  end

  defp rule_8_exempt_path?(path) do
    String.starts_with?(path, "lib/letflow/ledger/") or
      path == "lib/letflow/modules/ledger_registration.ex"
  end

  defp policy_file?(path) do
    case Path.split(path) do
      ["lib", "letflow", "modules", _id, "ledger_policy" | _] -> true
      _ -> false
    end
  end

  defp parse_source(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line), else: meta
        {:error, "cannot parse (line #{inspect(line)}): #{inspect(message)}#{inspect(token)}"}
    end
  end

  # File-wide alias table `short => [full parts]` (not lexically scoped: it can only flag more).
  defp alias_env(ast) do
    {_, env} = Macro.prewalk(ast, %{}, &collect_alias/2)
    env
  end

  defp collect_alias({:alias, _, [{:__aliases__, _, parts} | rest]} = node, env) do
    if Enum.all?(parts, &is_atom/1) do
      short =
        case rest do
          [[as: {:__aliases__, _, [as]}]] when is_atom(as) -> as
          _ -> List.last(parts)
        end

      {node, Map.put(env, short, parts)}
    else
      {node, env}
    end
  end

  defp collect_alias(
         {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, subs}]} = node,
         env
       ) do
    env =
      Enum.reduce(subs, env, fn
        {:__aliases__, _, sub}, acc ->
          if Enum.all?(prefix ++ sub, &is_atom/1),
            do: Map.put(acc, List.last(sub), prefix ++ sub),
            else: acc

        _other, acc ->
          acc
      end)

    {node, env}
  end

  defp collect_alias(node, env), do: {node, env}

  # The full dotted name of an alias node, or nil when a part is not a plain atom.
  defp resolve_alias([first | rest] = parts, env) do
    if Enum.all?(parts, &is_atom/1) do
      full = Map.get(env, first, [first]) ++ rest
      Enum.map_join(full, ".", &Atom.to_string/1)
    end
  end

  defp resolve_alias(_parts, _env), do: nil

  defp defined_modules(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          name = resolve_alias(parts, %{})
          {node, if(name, do: [name | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # Clauses a to d.
  defp rule_8_node({:__aliases__, _, parts} = node, acc, env) do
    name = resolve_alias(parts, env)
    {node, if(name in @rule_8_forged, do: [{:c, name} | acc], else: acc)}
  end

  defp rule_8_node({:%{}, _, kv} = node, acc, _env) when is_list(kv) do
    # A bare variable as the value only binds a module in a pattern (exception tagging in the real
    # tree); a literal or computed value builds or matches a chosen struct, which is refused.
    forged_map? =
      Enum.any?(kv, fn
        {:__struct__, {name, _, ctx}} when is_atom(name) and is_atom(ctx) -> false
        {:__struct__, _value} -> true
        _other -> false
      end)

    {node, if(forged_map?, do: [{:c, "%{__struct__: ...}"} | acc], else: acc)}
  end

  # The same names written as atoms, `:"Elixir.Letflow.Ledger.Capability"`.
  defp rule_8_node(atom, acc, _env) when is_atom(atom) and not is_nil(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> name when name in @rule_8_forged -> {atom, [{:c, name} | acc]}
      _other -> {atom, acc}
    end
  end

  defp rule_8_node({kind, _, [{:__aliases__, _, parts} | _]} = node, acc, env)
       when kind in [:import, :use, :require] do
    name = resolve_alias(parts, env)

    hit? =
      is_binary(name) and name != @policy_module and
        (name == "Letflow.Ledger" or String.starts_with?(name, "Letflow.Ledger."))

    {node, if(hit?, do: [{:b, "#{kind} #{name}"} | acc], else: acc)}
  end

  defp rule_8_node({:apply, _, args} = node, acc, _env)
       when is_list(args) and length(args) in [2, 3],
       do: {node, [{:d, "apply"} | acc]}

  defp rule_8_node({{:., _, [target, fun]}, _, _args} = node, acc, env) when is_atom(fun) do
    {node, remote_hits(target, fun, env) ++ acc}
  end

  defp rule_8_node(node, acc, _env), do: {node, acc}

  defp remote_hits(target, fun, env) do
    case remote_module(target, env) do
      nil -> remote_erlang_hits(target, fun)
      name -> module_hits(name, fun)
    end
  end

  # The dotted name of a call target written as an alias or as an Elixir module atom (the parser
  # turns `x[:a]` into a call on the atom `Access`); nil for anything else.
  defp remote_module({:__aliases__, _, parts}, env), do: resolve_alias(parts, env)

  defp remote_module(atom, _env) when is_atom(atom) and not is_nil(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> name -> name
      _erlang -> nil
    end
  end

  defp remote_module(_target, _env), do: nil

  defp module_hits(name, fun) do
    case name do
      "Letflow.Ledger" ->
        cond do
          fun == :post -> [{:a, "Letflow.Ledger.post"}]
          fun in @rule_8_reads -> []
          true -> [{:b, "Letflow.Ledger.#{fun}"}]
        end

      "Letflow.Ledger.Capability" when fun == :mint ->
        [{:a, "Letflow.Ledger.Capability.mint"}]

      @policy_module ->
        []

      "Letflow.Ledger." <> _ = name ->
        [{:b, "#{name}.#{fun}"}]

      "Kernel" when fun == :apply ->
        [{:d, "Kernel.apply"}]

      "Module" when fun in [:concat, :safe_concat] ->
        [{:d, "Module.#{fun}"}]

      "String" when fun == :to_existing_atom ->
        [{:d, "String.to_existing_atom"}]

      _other ->
        []
    end
  end

  defp remote_erlang_hits(:erlang, :apply), do: [{:d, ":erlang.apply"}]
  defp remote_erlang_hits(_target, _fun), do: []

  # Clause e: a policy file may name only Letflow.Ledger.Policy and the modules its files define.
  defp policy_reference_hits(ast, env, defined) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _, parts} = node, acc ->
          name = resolve_alias(parts, env)

          if is_binary(name) and String.starts_with?(name, "Letflow.") and name != @policy_module and
               not defined_here?(name, defined),
             do: {node, [{:e, name} | acc]},
             else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    hits
  end

  defp defined_here?(name, defined),
    do: Enum.any?(defined, &(name == &1 or String.starts_with?(name, &1 <> ".")))

  @policy_allowed ~w(Enum Map List String Integer Keyword MapSet Tuple Access Decimal) ++
                    [@policy_module]
  @policy_banned_calls [
    {"String", :to_atom},
    {"String", :to_existing_atom},
    {"List", :to_atom},
    {"List", :to_existing_atom}
  ]
  @policy_banned_locals [
    :send,
    :spawn,
    :spawn_link,
    :spawn_monitor,
    :self,
    :make_ref,
    :node,
    :apply
  ]

  @doc """
  The policy allowlist over `[{path, source}]` (the caller selects the files, normally
  `policy_paths/0`): `[{path, :policy_allowlist, detail}]` or `{path, :parse_error, detail}`. Pure.
  Detail is `{:module, name}`, `{:erlang, atom}`, `{:call, "String.to_atom"}`, `{:local, name}` or
  `:dynamic_call`.
  """
  @spec policy_violations([{String.t(), String.t()}]) :: [{String.t(), atom(), term()}]
  def policy_violations(files) when is_list(files) do
    parsed = Enum.map(files, fn {path, source} -> {path, parse_source(source)} end)
    defined = for {_path, {:ok, ast}} <- parsed, name <- defined_modules(ast), do: name

    Enum.flat_map(parsed, fn
      {path, {:error, detail}} ->
        [{path, :parse_error, detail}]

      {path, {:ok, ast}} ->
        env = alias_env(ast)
        {_, hits} = Macro.prewalk(ast, [], &policy_node(&1, &2, env, defined))
        hits |> Enum.uniq() |> Enum.map(&{path, :policy_allowlist, &1})
    end)
  end

  defp policy_node({:__aliases__, _, parts} = node, acc, env, defined) do
    name = resolve_alias(parts, env)

    if is_binary(name) and name not in @policy_allowed and not defined_here?(name, defined),
      do: {node, [{:module, name} | acc]},
      else: {node, acc}
  end

  defp policy_node({:receive, _, _} = node, acc, _env, _defined),
    do: {node, [{:local, :receive} | acc]}

  defp policy_node({name, _, args} = node, acc, _env, _defined)
       when name in @policy_banned_locals and is_list(args),
       do: {node, [{:local, name} | acc]}

  defp policy_node({:&, _, [{:/, _, [{name, _, ctx}, _arity]}]} = node, acc, _env, _defined)
       when name in @policy_banned_locals and is_atom(ctx),
       do: {node, [{:local, name} | acc]}

  defp policy_node({{:., _, [target, fun]}, meta, _args} = node, acc, env, defined)
       when is_atom(fun) do
    {node, policy_remote(target, fun, meta, env, defined) ++ acc}
  end

  defp policy_node(node, acc, _env, _defined), do: {node, acc}

  defp policy_remote({:__MODULE__, _, _}, _fun, _meta, _env, _defined), do: []

  defp policy_remote(target, fun, meta, env, defined) do
    case {remote_module(target, env), target} do
      {name, _} when is_binary(name) ->
        cond do
          {name, fun} in @policy_banned_calls -> [{:call, "#{name}.#{fun}"}]
          # an Elixir module atom (for example the `Access` of `x[:a]`) is judged like an alias
          name in @policy_allowed or defined_here?(name, defined) -> []
          true -> [{:module, name}]
        end

      {nil, atom} when is_atom(atom) and atom not in [nil, true, false] ->
        [{:erlang, atom}]

      _dynamic ->
        # `map.field` carries no_parens: true; anything else is a call on a computed module.
        if Keyword.get(meta, :no_parens, false), do: [], else: [:dynamic_call]
    end
  end

  defp scan_tokens(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, ast} ->
        {_, {tokens, aliases}} = Macro.prewalk(ast, {[], []}, &collect_token/2)
        {:ok, tokens, aliases}

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line), else: meta
        {:error, "cannot parse (line #{inspect(line)}): #{inspect(message)}#{inspect(token)}"}
    end
  end

  # Doc attributes are prose: replaced by nil so their arguments are never collected.
  defp collect_token({:@, _, [{attr, _, [_]}]}, acc) when attr in [:moduledoc, :doc, :typedoc],
    do: {nil, acc}

  defp collect_token({:__aliases__, _, parts} = node, {tokens, aliases}) do
    parts = Enum.filter(parts, &is_atom/1)
    {node, {Enum.map(parts, &Atom.to_string/1) ++ tokens, [parts | aliases]}}
  end

  defp collect_token({name, _, ctx} = node, {tokens, aliases})
       when is_atom(name) and is_atom(ctx),
       do: {node, {[Atom.to_string(name) | tokens], aliases}}

  defp collect_token({name, _, args} = node, {tokens, aliases})
       when is_atom(name) and is_list(args),
       do: {node, {[Atom.to_string(name) | tokens], aliases}}

  defp collect_token(atom, {tokens, aliases}) when is_atom(atom) and not is_nil(atom),
    do: {atom, {[Atom.to_string(atom) | tokens], aliases}}

  defp collect_token(bin, {tokens, aliases}) when is_binary(bin),
    do: {bin, {[bin | tokens], aliases}}

  defp collect_token(node, acc), do: {node, acc}

  defp token_words(token) when is_binary(token) do
    ~r/[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+/
    |> Regex.scan(token)
    |> Enum.map(fn [w] -> String.downcase(w) end)
  end

  @layer_rules [
    %{
      source_prefixes: ["lib/letflow/engine.ex", "lib/letflow/engine/"],
      forbidden_target_prefixes: ["lib/letflow/entities.ex", "lib/letflow/entities/"],
      reason: "engine -> entities only via Letflow.Engine.EntityPort (0053 F10, 0054 D2)"
    },
    # SEC F8 (GH 2632): the scripts namespace never reaches the write-callback holders or the
    # entities context's own write API, nor the engine that runs the port writes.
    %{
      source_prefixes: ["lib/letflow/scripts.ex", "lib/letflow/scripts/"],
      forbidden_target_prefixes: [
        "lib/letflow/engine.ex",
        "lib/letflow/engine/entity_port.ex",
        "lib/letflow/entities.ex",
        "lib/letflow/entities/entity_port_impl.ex",
        "lib/letflow/entities/step_writes.ex",
        "lib/letflow/entities/handler_writes.ex",
        "lib/letflow/entities/records.ex"
      ],
      reason:
        "scripts call no entity port write callback and no entity write API (SEC F8, 0054 D2)"
    },
    # SEC F8 (GH 2632): the dispatcher keeps its edges to engine.ex (apply_script_task_result/3,
    # the sanctioned apply path) and engine/entity_port.ex (the one prefetch read) only.
    %{
      source_prefixes: [
        "lib/letflow/engine/script_task_dispatcher.ex",
        "lib/letflow/engine/script_task_dispatcher/"
      ],
      forbidden_target_prefixes: [
        "lib/letflow/definitions.ex",
        "lib/letflow/entities/step_writes.ex",
        "lib/letflow/entities/entity_port_impl.ex",
        "lib/letflow/entities/handler_writes.ex"
      ],
      reason: "the script task dispatcher calls no port write callback (SEC F8, 0054 D2)"
    }
  ]

  @doc """
  Rule 6's declarative table: each row forbids a DIRECT file edge from a file
  under one of `source_prefixes` to a file under one of
  `forbidden_target_prefixes`. Indirect paths are out of this rule's scope
  (see the moduledoc).
  """
  @spec layer_rules() :: [
          %{
            source_prefixes: [String.t()],
            forbidden_target_prefixes: [String.t()],
            reason: String.t()
          }
        ]
  def layer_rules, do: @layer_rules

  # Rule 6: the reason of the first layer rule the DIRECT edge breaks, or nil.
  @spec layer_violation({String.t(), String.t()}) :: String.t() | nil
  defp layer_violation({source, target}) do
    Enum.find_value(@layer_rules, fn rule ->
      if prefixed?(source, rule.source_prefixes) and
           prefixed?(target, rule.forbidden_target_prefixes) do
        "layer violation: #{source} → #{target} (#{rule.reason})"
      end
    end)
  end

  defp prefixed?(path, prefixes), do: Enum.any?(prefixes, &String.starts_with?(path, &1))

  @doc """
  Maps `classify_edge/2` over a list of edges; returns results in the same order.

  Convenience wrapper used by `run/1` to collect all violations in one pass
  before printing. Each element is `:ok` or `{:violation, reason}`.
  """
  @spec classify_edges([{String.t(), String.t()}], depends_on_map()) ::
          [:ok | {:violation, String.t()}]
  def classify_edges(edges, depends_on_map) when is_list(edges) and is_map(depends_on_map) do
    Enum.map(edges, &classify_edge(&1, depends_on_map))
  end

  # Returns true iff path matches lib/letflow/modules/<id>/<rest> where <id>
  # is a non-empty path component and <rest> is at least one more component.
  # Returns false for files directly at lib/letflow/modules/<name>.ex (one level,
  # e.g., lib/letflow/modules/catalog.ex or lib/letflow/modules/module.ex).
  @spec path_in_module_subdir?(String.t()) :: boolean()
  defp path_in_module_subdir?(path) do
    case Path.split(path) do
      ["lib", "letflow", "modules", _id, _ | _] -> true
      _ -> false
    end
  end

  # Extracts the module id (first path component after lib/letflow/modules/).
  # Pre-condition: path_in_module_subdir?(path) is true.
  # Example: "lib/letflow/modules/exam/session.ex" → "exam"
  @spec module_id_from_path(String.t()) :: String.t()
  defp module_id_from_path(path) do
    path
    |> Path.split()
    |> Enum.at(3)
  end

  # Strips the type-annotation suffix from a target path, e.g.
  # "lib/b.ex (compile)" → "lib/b.ex".
  @spec strip_annotation(String.t()) :: String.t()
  defp strip_annotation(path) do
    case String.split(path, " (", parts: 2) do
      [clean, _rest] -> clean
      [clean] -> clean
    end
  end

  # ISS-0831: the single seam through which this module runs `mix xref`. Consults
  # the {:letflow, :check_boundaries_xref_runner} Application env key -- unset in
  # every real (non-test) invocation, so the default here (the real System.cmd/3
  # call) is what actually runs -- falling back to whatever 0-arity runner a test
  # has installed there. This is the ONLY place in this module that may call
  # System.cmd/3 directly; run/1 goes through this function instead (design doc
  # lib/letflow/design/iss0831-check-boundaries-exit-code.md §1-2).
  @spec run_xref() :: {String.t(), non_neg_integer()}
  defp run_xref() do
    runner =
      Application.get_env(:letflow, :check_boundaries_xref_runner, fn ->
        System.cmd("mix", ["xref", "graph", "--format", "plain"], stderr_to_stdout: false)
      end)

    runner.()
  end
end
