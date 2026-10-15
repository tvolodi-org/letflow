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
    prefixes, evaluated BEFORE Rule 0. Today it holds one row: the engine
    (`lib/letflow/engine.ex`, `lib/letflow/engine/**`) may not reference the
    entities context (`lib/letflow/entities.ex`, `lib/letflow/entities/**`);
    entity records reach the engine only through the engine-defined
    `Letflow.Engine.EntityPort` (0054 D2; it subsumed 0053's `ScriptReadPort`), whose
    implementation is selected from `config :letflow, :entity_port` at run time (a config value, not a
    file edge).

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

    if violations == [] do
      IO.puts("mix letflow.check_boundaries: OK -- #{length(edges)} edges checked, 0 violations")
      :ok
    else
      for {src, tgt, reason} <- violations do
        IO.puts("VIOLATION: #{src} -> #{tgt} (#{reason})")
      end

      Mix.raise(
        "mix letflow.check_boundaries: FAILED -- #{length(violations)} violation(s) found"
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

  @layer_rules [
    %{
      source_prefixes: ["lib/letflow/engine.ex", "lib/letflow/engine/"],
      forbidden_target_prefixes: ["lib/letflow/entities.ex", "lib/letflow/entities/"],
      reason: "engine -> entities only via Letflow.Engine.EntityPort (0053 F10, 0054 D2)"
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
