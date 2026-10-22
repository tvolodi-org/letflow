defmodule Mix.Tasks.Letflow.CheckAsyncSandboxReachability do
  @shortdoc "Fails when an async:true test file reaches Ecto.Adapters.SQL.Sandbox.mode/2"

  @moduledoc """
  Implements ISS-0481 (queue task 512, GH#1000 -- the GH issue's own title says
  "ISS-0512", a pre-filing numbering slip; docs/issues/ISS-0481.yaml is the
  canonical record, see its own header note): mechanically enforces the
  invariant that only discipline protected before -- an `async: true` ExUnit
  test file must never (directly or transitively, via
  `Letflow.TenantFixture.provisioned_tenant!/1`) reach
  `Ecto.Adapters.SQL.Sandbox.mode/2`. `Sandbox.mode/2` checks in every connection
  in the pool when the mode changes, so a bystander `async: true` file reaching
  it corrupts concurrently-running async tests. This is the third recurrence in
  this family (ISS-0113 OQ-5 flagged the general risk but only guarded a file
  that itself calls `mode/2` directly, never a bystander file reached
  transitively; ISS-0480 restored the invariant by construction for two files
  but nothing prevented recurrence). Design authority:
  `lib/letflow/design/iss0481-async-sandbox-mode-check.md`, independently
  validated (`handoffs/WF03-ISS0512-20260905/step-02b-code-design-validator.json`
  -- that run's own id, WF03-ISS0512-20260905, was dispatched under queue task
  512 before the ISS-0481/ISS-0512 numbering collision was discovered; left
  unchanged as a historical identifier).

  Mirrors `lib/mix/tasks/letflow.lint_handoffs.ex`'s own shape: a plain static
  textual scan over files already on disk, with a small, closed, named
  allowlist (`@verified_safe` below) instead of a wildcard/pattern exemption --
  same discipline `lint_handoffs.ex`'s own `@grandfathered` comment insists on:
  every entry is one exact file, a NEW file hitting the same rule is never
  covered by an existing entry.

  ## What counts as a real `async: true` declaration (design §2)

  Anchored per physical line: `^\\s*use\\s+[A-Za-z0-9_.]+\\s*,.*\\basync:\\s*true\\b`
  -- the line's first non-whitespace token must be the literal token `use`.
  This alone rejects every moduledoc-prose and `#`-comment false positive found
  in this codebase (none of them start the line with a bare `use` token). A
  file is a real async:true file iff at least one line matches this anchor.

  ## What counts as a real call site reaching `Sandbox.mode/2` (design §3)

  Two independent per-line patterns, evaluated only inside a real async:true
  file, each excluding matches inside a `@moduledoc \"\"\"..\"\"\"` span or on a
  `#`-comment line:

    * §3(a) -- `provisioned_tenant!\\s*\\(` (unqualified: no other module in
      this codebase defines a same-named function).
    * §3(b) -- `(Ecto\\.Adapters\\.SQL\\.)?Sandbox\\.mode\\s*\\(` -- a bare or
      fully-qualified `Sandbox.mode(` call directly in the test file.

  `provisioned_tenant!/1`'s own body calls `Sandbox.mode/2` unconditionally as
  its literal first statement, before any `template:` option is even read, so
  detecting a call to it is already sufficient to prove the file reaches
  `mode/2` -- the checker never needs to model the second hop to
  `Letflow.TenantTemplate.ensure_template!/0` or parse the `template:` option.

  ## The `@verified_safe` allowlist (design §5)

  Exactly two entries, each an exact file path citing the issue that verified
  it. A candidate violation whose path is on this list is reported
  (informationally) but does not fail the build; a candidate violation whose
  path is NOT on this list fails the build. No wildcard, no directory-prefix,
  no rule-level blanket exemption -- adding a 3rd entry requires a deliberate
  commit that also performs (and cites, in that file's own moduledoc) ISS-0113
  §3's three-mechanism verification procedure.

  ## What this task deliberately does NOT check

  General Elixir call-graph analysis, macro expansion, `apply/3`, following
  into arbitrary `lib/letflow/` application code (zero `Sandbox.mode` hits
  there today), or a direct, `provisioned_tenant!/1`-free call to
  `Letflow.TenantTemplate.ensure_template!/0` (no such call site exists in this
  codebase today; if one is ever added, the fix is a third pattern,
  `ensure_template!\\s*\\(`, with the same two exclusions -- not added
  proactively since it would have zero effect against the current corpus).
  Multi-line `use` declarations are also not handled (none exist in this
  codebase today) -- a future wrapped `use Foo,\\n  async: true` would silently
  fail to be classified as async:true.

  `test/support/tenant_schema_reaper.ex` and `test/support/tenant_template.ex`
  are legitimate `Sandbox.mode/2` callers and are never the SUBJECT of this
  check -- excluded structurally by the file-selection step (they don't match
  `test/**/*_test.exs`, and even if scanned, neither contains a real
  `use ..., async: true` line).

  ## Usage

      mix letflow.check_async_sandbox_reachability
      mix letflow.check_async_sandbox_reachability --dir <path>

  Exits non-zero (`Mix.raise/1`) iff at least one new (non-allowlisted)
  violation exists.

  ### `--dir <path>`

  Following `letflow.lint_handoffs.ex`'s own `--dir <path>` precedent
  (ISS-0440) exactly: overrides the `test` root the `test/**/*_test.exs`
  wildcard is rooted at. With no `--dir`, behavior is unchanged from the
  hardcoded default (CI's own invocation, via the `letflow.check` alias). An
  explicitly-supplied `--dir` that discovers zero matching files is a hard
  usage error (`Mix.raise/1`), never a silent clean pass -- this exists so a
  regression test can point the checker at a scratch directory holding a
  synthetic fixture without ever placing that fixture under the real `test/`
  tree (which would itself be picked up and executed by a plain `mix test`).
  """

  use Mix.Task

  @default_dir "test"
  @rule String.duplicate("=", 72)

  # Design §5 -- exactly two entries, each an exact file path, each citing the
  # issue that verified it. No wildcard, no directory-prefix. A NEW file
  # hitting this rule is NOT covered by this list and fails the build.
  @verified_safe [
    {"test/letflow/secrets_test.exs",
     "ISS-0113/ISS-0423 -- three-mechanism procedure passed, see the file's own moduledoc"},
    {"test/letflow/webhooks_test.exs",
     "ISS-0113/ISS-0423 -- three-mechanism procedure passed, see the file's own moduledoc"}
  ]

  # GH #2424 (decision on GH #2415): the inline `Sandbox.mode(_, :auto)` convention
  # is kept; this frozen list is the files that use it today. A new file with an
  # inline `:auto` fails the build; it reaches `:auto` through
  # `Letflow.Test.SandboxAutoMode` instead. Entries may only be removed.
  @inline_auto_allowlist ~w(
    test/letflow/audit_capture_test.exs
    test/letflow/audit_dispositions_test.exs
    test/letflow/audit_test.exs
    test/letflow/definitions/req462_shipped_required_outputs_adoption_test.exs
    test/letflow/engine/lua_script_audit_retired_test.exs
    test/letflow/engine/meridian_loan_escalation_timer_test.exs
    test/letflow/engine/migrations_test.exs
    test/letflow/engine/regulatory_review_timer_path_test.exs
    test/letflow/engine/service_task_subprocess_cascade_test.exs
    test/letflow/engine/shipped_definition_variable_schemas_engine_test.exs
    test/letflow/engine/sub_process_child_pins_test.exs
    test/letflow/engine/sub_process_service_task_after_test.exs
    test/letflow/engine/swiftroute_escalation_timer_test.exs
    test/letflow/engine/vortex_escalation_timer_test.exs
    test/letflow/engine_catalog_service_task_test.exs
    test/letflow/engine_pin_resolver_catalog_test.exs
    test/letflow/entities/records_test.exs
    test/letflow/event_store/migrations_test.exs
    test/letflow/event_store/retention_operations_test.exs
    test/letflow/identity/group_test.exs
    test/letflow/identity/role_scope_grants_writers_test.exs
    test/letflow/identity/tenant_admin_seeding_test.exs
    test/letflow/identity/tenant_auditor_seeding_test.exs
    test/letflow/identity/tenant_role_test.exs
    test/letflow/identity/user_test.exs
    test/letflow/identity_migration_test.exs
    test/letflow/identity_test.exs
    test/letflow/integration/keycloak_auth_pipeline_test.exs
    test/letflow/login_directory_test.exs
    test/letflow/migrations/add_catalog_endpoint_url_reserved_ref_guard_test.exs
    test/letflow/modules/exam/exam_sessions_test.exs
    test/letflow/platform/migration_rollout_test.exs
    test/letflow/plugs/iss0778_platform_role_seeding_e2e_test.exs
    test/letflow/repository/gh2718_attachments_delete_event_test.exs
    test/letflow/repository_test.exs
    test/letflow/role_registry_test.exs
    test/letflow/routers/admin_services_publish_retire_test.exs
    test/letflow/routers/admin_services_reserved_endpoint_test.exs
    test/letflow/routers/admin_services_test.exs
    test/letflow/routers/event_retention_test.exs
    test/letflow/routers/gh2564_deactivation_revokes_tokens_test.exs
    test/letflow/routers/onboarding_client_config_test.exs
    test/letflow/routers/onboarding_test.exs
    test/letflow/routers/platform_migrations_test.exs
    test/letflow/routers/req077_promotion_pipeline_test.exs
    test/letflow/sandbox_pool/fixture_loader_test.exs
    test/letflow/sandbox_pool_test.exs
    test/letflow/scheduler/poller_test.exs
    test/letflow/scripts/swiftroute_decision_forms_fixture_test.exs
    test/letflow/service_catalog/endpoint_url_db_guard_changeset_test.exs
    test/letflow/service_catalog/endpoint_url_db_guard_parity_test.exs
    test/letflow/service_catalog/endpoint_url_reserved_test.exs
    test/letflow/service_catalog/endpoint_url_validation_test.exs
    test/letflow/service_catalog_delete_pinned_instances_test.exs
    test/letflow/service_catalog_resolve_pinned_version_test.exs
    test/letflow/service_catalog_test.exs
    test/letflow/simulation/req206_swiftroute_test.exs
    test/letflow/simulation/req207_vortex_test.exs
    test/letflow/simulation/req208_meridian_test.exs
    test/letflow/simulation/runner_template_and_outcomes_test.exs
    test/letflow/simulation/runner_test.exs
    test/letflow/simulation/seed_idempotency_test.exs
    test/letflow/support/tenant_fixture_pool_test.exs
    test/letflow/tenant_onboarding_test.exs
    test/letflow/tenant_provisioning/backfill_test.exs
    test/letflow/tenant_provisioning/column_promotion_test.exs
    test/letflow/tenant_provisioning/entity_event_type_seeding_test.exs
    test/letflow/tenant_provisioning/task_completed_backfill_test.exs
    test/letflow/tenant_provisioning_test.exs
    test/mix/tasks/letflow.seed.exam_fixtures_test.exs
    test/mix/tasks/letflow.seed_test.exs
    test/support/bpm_default_realm_displacement_gate_test.exs
    test/support/bpm_default_realm_displacement_test.exs
    test/support/fake_invocation_connection_test.exs
    test/support/service_catalog_reaper_test.exs
    test/support/template_build_reaper_test.exs
    test/support/tenant_fixture_dispatch_test.exs
    test/support/tenant_schema_reaper_test.exs
    test/support/tenant_template_retry_test.exs
    test/support/tenant_template_test.exs
  )

  @async_true_re ~r/^\s*use\s+[A-Za-z0-9_.]+\s*,.*\basync:\s*true\b/
  @provisioned_tenant_re ~r/provisioned_tenant!\s*\(/
  @sandbox_mode_re ~r/(Ecto\.Adapters\.SQL\.)?Sandbox\.mode\s*\(/

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    dir = resolve_dir(args)

    files = test_files(dir)

    guard_empty_scope(dir, files)

    contents = Map.new(files, &{&1, File.read!(&1)})

    async_true_files = Enum.filter(files, &async_true_file?(Map.fetch!(contents, &1)))

    findings =
      async_true_files
      |> Enum.map(&scan_file(&1, Map.fetch!(contents, &1)))
      |> Enum.reject(&is_nil/1)

    {new, permitted} = Enum.split_with(findings, &(&1.verified_safe_citation == nil))

    new_auto =
      files
      |> Enum.flat_map(fn path ->
        case inline_auto_sites(Map.fetch!(contents, path)) do
          [] -> []
          sites -> [%{path: path, matches: sites}]
        end
      end)
      |> Enum.reject(&(&1.path in @inline_auto_allowlist))

    modeless = Enum.filter(files, &modeless_repo_file?(Map.fetch!(contents, &1)))

    print_report(findings, new, permitted)
    print_victim_report(new_auto, modeless)

    total_new = length(new) + length(new_auto) + length(modeless)

    IO.puts(@rule)

    if total_new > 0 do
      IO.puts("letflow.check_async_sandbox_reachability: FAIL -- #{total_new} new violation(s).")

      IO.puts(@rule)

      Mix.raise(
        "letflow.check_async_sandbox_reachability found #{total_new} new violation(s) -- " <>
          "see output above"
      )
    else
      IO.puts(
        "letflow.check_async_sandbox_reachability: OK -- #{length(async_true_files)} " <>
          "async:true test file(s) scanned under #{inspect(dir)}, #{length(findings)} reach " <>
          "Sandbox.mode/2 (#{length(permitted)} permitted, verified exceptions), 0 new violations."
      )

      IO.puts(@rule)
      :ok
    end
  end

  # -- GH #2424: victim-side rules ----------------------------------------------
  #
  # Both rules read "code lines": comment lines, `@moduledoc`/`@doc` and any other
  # heredoc body are dropped and double-quoted string literals are blanked, so
  # prose and fixture text never count as a call.

  @inline_auto_re ~r/Sandbox\.mode\s*\([^)]*:auto\b/
  @repo_use_re ~r/\bRepo\.(?!config\b)[a-z_]+[!?]?\s*[(\s]|\bRepo\.[a-z_]+[!?]?$/
  @mode_evidence_re ~r/\buse\s+Letflow\.DataCase\b|Sandbox\.(mode|checkout|start_owner!)\s*\(|SandboxAutoMode/

  @doc false
  @spec code_lines(content :: String.t()) :: [{pos_integer(), String.t()}]
  def code_lines(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, line_number}, {in_heredoc?, acc} ->
      toggles? = rem(length(Regex.scan(~r/"""|'''/, line)), 2) == 1

      cond do
        in_heredoc? -> {not toggles?, acc}
        toggles? -> {true, acc}
        comment_line?(line) -> {false, acc}
        true -> {false, [{line_number, blank_strings(line)} | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp blank_strings(line) do
    line
    |> then(&Regex.replace(~r/~[rsRS]([|\/'"]).*?\1/, &1, "\"\""))
    |> then(&Regex.replace(~r/"(?:[^"\x5C]|\x5C.)*"/, &1, "\"\""))
  end

  @doc false
  @spec inline_auto_sites(content :: String.t()) :: [map()]
  def inline_auto_sites(content) do
    for {line_number, line} <- code_lines(content), Regex.match?(@inline_auto_re, line) do
      %{pattern: :inline_auto, line_number: line_number, line_text: String.trim(line)}
    end
  end

  # An async:false (or undeclared) file that calls the Repo and neither uses
  # Letflow.DataCase nor sets/checks out a sandbox mode itself: it runs in
  # whatever mode the previous file left behind.
  @doc false
  @spec modeless_repo_file?(content :: String.t()) :: boolean()
  def modeless_repo_file?(content) do
    lines = code_lines(content)

    not async_true_file?(content) and
      Enum.any?(lines, fn {_n, l} -> Regex.match?(@repo_use_re, l) end) and
      not Enum.any?(lines, fn {_n, l} -> Regex.match?(@mode_evidence_re, l) end)
  end

  # -- CLI flag parsing (mirrors letflow.lint_handoffs.ex's --dir handling) --

  @spec resolve_dir([String.t()]) :: String.t()
  def resolve_dir(args) do
    case find_dir_flag(args) do
      :not_present ->
        @default_dir

      {:ok, value} ->
        value

      :missing_value ->
        Mix.raise("letflow.check_async_sandbox_reachability: --dir given with no path argument")
    end
  end

  defp find_dir_flag(["--dir", value | _rest]), do: {:ok, value}
  defp find_dir_flag(["--dir"]), do: :missing_value
  defp find_dir_flag([_other | rest]), do: find_dir_flag(rest)
  defp find_dir_flag([]), do: :not_present

  # An explicitly-supplied --dir that discovers zero files is a hard usage
  # error, not a silent clean pass -- never let a scoped run masquerade as a
  # full-corpus green result. Does not apply to the default @default_dir
  # itself (a genuinely empty real test/ tree is a separate, pre-existing
  # edge case, not a --dir misuse symptom).
  @spec guard_empty_scope(dir :: String.t(), files :: [String.t()]) :: :ok | no_return()
  def guard_empty_scope(dir, files) do
    if files == [] and dir != @default_dir do
      Mix.raise(
        "letflow.check_async_sandbox_reachability: --dir #{inspect(dir)} discovered 0 files -- " <>
          "refusing to report success for an empty or non-existent scan target"
      )
    else
      :ok
    end
  end

  # -- discovery --------------------------------------------------------------

  @spec test_files(dir :: String.t()) :: [String.t()]
  def test_files(dir \\ @default_dir) do
    Path.wildcard(Path.join(dir, "**/*_test.exs"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  # -- classification (design §2/§3) -------------------------------------------

  # Pure: takes file content as a string, returns whether it's a real
  # async:true file. Exposed as a public function so it is directly testable
  # against synthetic in-memory strings (design §8.1) without touching the
  # filesystem.
  @spec async_true_file?(content :: String.t()) :: boolean()
  def async_true_file?(content) do
    content
    |> String.split("\n")
    |> Enum.any?(&Regex.match?(@async_true_re, &1))
  end

  # Pure: takes file content, returns the list of real §3(a)/§3(b) matches, as
  # `%{pattern: :provisioned_tenant | :sandbox_mode, line_number: pos_integer(),
  # line_text: String.t()}`. Excludes matches inside a `@moduledoc """..."""`
  # span or on a `#`-comment line.
  @spec real_call_sites(content :: String.t()) :: [map()]
  def real_call_sites(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, line_number}, {in_moduledoc?, acc} ->
      cond do
        moduledoc_open?(line) ->
          {true, acc}

        in_moduledoc? and moduledoc_close?(line) ->
          {false, acc}

        in_moduledoc? ->
          {true, acc}

        comment_line?(line) ->
          {false, acc}

        true ->
          {false, acc ++ line_matches(line, line_number)}
      end
    end)
    |> elem(1)
  end

  defp moduledoc_open?(line), do: Regex.match?(~r/^\s*@moduledoc\s+"""\s*$/, line)
  defp moduledoc_close?(line), do: Regex.match?(~r/^\s*"""\s*$/, line)
  defp comment_line?(line), do: Regex.match?(~r/^\s*#/, line)

  defp line_matches(line, line_number) do
    []
    |> maybe_add_match(line, line_number, @provisioned_tenant_re, :provisioned_tenant)
    |> maybe_add_match(line, line_number, @sandbox_mode_re, :sandbox_mode)
  end

  defp maybe_add_match(acc, line, line_number, regex, pattern) do
    if Regex.match?(regex, line) do
      [%{pattern: pattern, line_number: line_number, line_text: String.trim(line)} | acc]
    else
      acc
    end
  end

  # -- per-file scan ------------------------------------------------------------

  # Called only on files already confirmed async:true by the caller. Returns
  # nil when the file has no real call site, or a finding map for a candidate
  # violation: `%{path: ..., matches: [...], verified_safe_citation: String.t() | nil}`.
  defp scan_file(path, content) do
    case real_call_sites(content) do
      [] ->
        nil

      matches ->
        %{path: path, matches: matches, verified_safe_citation: verified_safe_citation(path)}
    end
  end

  defp verified_safe_citation(path) do
    Enum.find_value(@verified_safe, fn {safe_path, citation} ->
      if safe_path == path, do: citation
    end)
  end

  # -- output -------------------------------------------------------------------

  defp print_report(_findings, new, permitted) do
    if new != [] do
      IO.puts(@rule)
      IO.puts("NEW VIOLATIONS (fail the build):")

      Enum.each(new, fn finding ->
        Enum.each(finding.matches, fn match ->
          IO.puts(
            "  [ASYNC-SANDBOX] #{finding.path}:#{match.line_number}: async:true file " <>
              "#{pattern_description(match.pattern)} without a @verified_safe entry -- " <>
              "either (a) revert to async: false, or (b) run ISS-0113 §3's three-mechanism " <>
              "verification procedure and add a named @verified_safe entry citing it."
          )

          IO.puts("      #{match.line_text}")
        end)
      end)
    end

    if permitted != [] do
      IO.puts(@rule)
      IO.puts("PERMITTED, VERIFIED EXCEPTIONS (do not fail the build):")

      Enum.each(permitted, fn finding ->
        IO.puts("  #{finding.path}: #{finding.verified_safe_citation}")
      end)
    end
  end

  defp pattern_description(:provisioned_tenant), do: "calls `provisioned_tenant!(`"
  defp pattern_description(:sandbox_mode), do: "calls `Sandbox.mode(`"

  defp print_victim_report(new_auto, modeless) do
    if new_auto != [] do
      IO.puts(@rule)
      IO.puts("NEW INLINE Sandbox.mode(_, :auto) (fail the build):")

      Enum.each(new_auto, fn finding ->
        Enum.each(finding.matches, fn match ->
          IO.puts(
            "  [INLINE-AUTO] #{finding.path}:#{match.line_number}: inline `:auto` outside the " <>
              "frozen @inline_auto_allowlist -- reach :auto through " <>
              "Letflow.Test.SandboxAutoMode (test/support/sandbox_auto_mode.ex) instead."
          )

          IO.puts("      #{match.line_text}")
        end)
      end)
    end

    if modeless != [] do
      IO.puts(@rule)
      IO.puts("MODELESS REPO FILES (fail the build):")

      Enum.each(modeless, fn path ->
        IO.puts(
          "  [NO-SANDBOX-MODE] #{path}: not async:true, calls the Repo, and neither uses " <>
            "Letflow.DataCase nor sets a sandbox mode/checkout (Sandbox.mode, " <>
            "Sandbox.checkout, SandboxAutoMode) -- it runs in whatever mode the previous " <>
            "file left behind."
        )
      end)
    end
  end
end
