defmodule Letflow.MixProject do
  use Mix.Project

  def project do
    [
      app: :letflow,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # Shared fixtures (`*_fixture.exs`) are loaded by Code.require_file/2 from the tests
      # that use them; they are not test files and must not trip the filter warning.
      test_ignore_filters: [~r/_fixture\.exs$/],
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [
        "letflow.check": :test,
        "letflow.check.static": :test,
        "letflow.check.test": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :inets and :ssl: REQ-183's deliver/3 uses :httpc.request/4 for
      # outbound webhook delivery -- both are required started for :httpc to
      # work, neither was needed before this requirement (the project's
      # first outbound-HTTP-call requirement, design
      # req183-webhook-delivery-dispatch.md §5).
      extra_applications: [:logger, :inets, :ssl],
      mod: {Letflow.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.17"},
      {:plug, "~> 1.15"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      # REQ-194 (design req194-prometheus-metrics.md §10): promotes an ALREADY-PRESENT
      # transitive dependency (mix.lock already resolves telemetry v1.4.2 via bandit,
      # db_connection, ecto, ecto_sql, plug) to a direct one -- zero new bytes, zero new
      # transitive tree, zero new license surface. Needed because lib/letflow/metrics/,
      # lib/letflow/plugs/http_metrics.ex, engine.ex and event_store.ex now call
      # :telemetry.execute/3 / :telemetry.attach_many/4 / :telemetry.span/3 directly for
      # the first time -- standard Elixir hygiene pins a directly-called library rather
      # than borrowing it off another dependency's transitive graph. Flagged for
      # REVIEWER sign-off per this requirement's own AC3 (see the design's §10 and the
      # CODE-DESIGN-VALIDATOR's dependency_promotion_flag_for_reviewer note on the
      # step-02a handoff) -- REVIEWER sign-off must be recorded before this merges.
      {:telemetry, "~> 1.4"},
      {:stream_data, "~> 0.6", only: :test},
      # REQ-205 (design lib/letflow/design/req205-simulation-harness-foundation.md
      # §4): pure-Elixir YAML 1.1 parser (wraps :yamerl) for the S7 simulation
      # harness's business-fixture YAML (test/fixtures/simulation/). Test-only --
      # nothing under lib/letflow/ (production code) ever parses YAML -- mirrors
      # stream_data's own `only: :test` entry, not wasmex/lua's unconditional
      # runtime-engine entries. Flagged for REVIEWER sign-off per REQ-205's AC7,
      # same procedural precedent as REQ-148/REQ-165's own new top-level deps.
      {:yaml_elixir, "~> 2.11", only: [:dev, :test]},
      {:ueberauth_oidcc, "~> 0.4"},
      {:lua, "~> 1.0"},
      {:wasmex, "~> 0.15.1"},
      # REQ-356 (decision docs/migration/decisions/0033-pdf-qr-rendering-dependencies.md):
      # pure-Elixir, MIT-licensed PDF byte generator -- chosen over chromic_pdf
      # (rejected: requires a Chrome/Chromium binary in every runtime
      # environment for a document that does not need an HTML/CSS layout
      # engine) and over hand-rolling PDF bytes (rejected: the PDF object
      # graph/xref table/stream machinery is exactly what this library exists
      # to absorb, at no transitive-dependency cost). Renders the certificate
      # document `lib/letflow/exam/certificate_document.ex` produces.
      # Flagged for REVIEWER sign-off per this requirement's own AC1 --
      # REVIEWER sign-off must be recorded before this merges.
      {:pdf, "~> 0.8"},
      # REQ-356 (decision docs/migration/decisions/0033-pdf-qr-rendering-dependencies.md):
      # pure-Elixir, MIT-licensed QR-code module-matrix encoder -- chosen over
      # qr_code (rejected: BSD-4-Clause's advertising-clause obligation is an
      # avoidable licence-review burden an MIT alternative sidesteps for the
      # same one-thing-done-well encoding this gap needs) and over shelling
      # out to an external `qrencode` binary (rejected: an operational
      # dependency added to remove a dependency that costs nothing to keep).
      # Exposes the raw QR module matrix `certificate_document.ex` draws
      # directly into the PDF, avoiding a round trip through a rasterised
      # image format. Flagged for REVIEWER sign-off per this requirement's
      # own AC1 -- REVIEWER sign-off must be recorded before this merges.
      {:eqrcode, "~> 0.2"},
      # REQ-364 (decision docs/migration/decisions/0036-earmark-parser-markdown-
      # sanitization-dependency.md): pure-Elixir, Apache-2.0, zero-runtime-deps
      # CommonMark parser, used only for `EarmarkParser.as_ast/2` -- the
      # `help_content`/`platform_help_content` write-path changeset validator
      # (lib/letflow/help/help_content.ex) walks the resulting AST to reject raw
      # HTML (meta[:verbatim] == true) and disallowed-scheme link/image
      # destinations. Replaces a regex-based validator REVIEWER found
      # structurally bypassable (5 confirmed/constructed bypasses across 3
      # rounds) -- see the design's §5.4 for the full mechanism. Chosen over the
      # full `earmark` renderer (retired on hex.pm, carries a security advisory,
      # and this requirement never needs rendered HTML) per the design's own
      # §5.4.1. REVIEWER sign-off recorded in decision 0036 before this merges.
      {:earmark_parser, "~> 1.4"},
      # REQ-441 (decision docs/migration/decisions/0045-mail-library-choice.md): gen_smtp
      # ALONE (adds gen_smtp + ranch only; not Swoosh, not Mua) -- the SMTP client behind
      # Letflow.LoginDiscovery.Notifier.Smtp.Transport, the only module that names it.
      {:gen_smtp, "~> 1.3"}
    ]
  end

  # The `letflow.check` steps up to and including the boundary check -- everything
  # except the test run. See the `letflow.check.static` / `letflow.check` aliases.
  #
  # GH #2586 / REQ-498: `mix letflow.permission_matrix --check` is deliberately NOT a
  # step here. These aliases are pinned to MIX_ENV=test (`cli/0` above), where
  # config/test.exs registers the test fixture modules, and the task refuses
  # MIX_ENV=test by design (it must see the PRODUCTION module list). CI runs it as its
  # own `backend_static` step under MIX_ENV=dev; locally run
  # `MIX_ENV=dev mix letflow.permission_matrix --check`.
  @check_static_steps [
    "letflow.check_toolchain",
    "letflow.check_requirements_registration",
    # ISS-0613: shares a parse of docs/requirements.yaml and the same "id" concept
    # as check_requirements_registration immediately above, so it is slotted right
    # after it -- cheap, no compile step, catches a REQ-NNN id collision with
    # origin/main before a full compile+test cycle. See
    # lib/letflow/design/iss0613-req-id-collision-check.md section 3.4.
    "letflow.check_req_id_collision",
    # ISS-0258: positioned immediately after the registration check per design
    # D5 -- it shares a parse of docs/requirements.yaml with that check, so a
    # stale deferral is reported in a second rather than after a full
    # compile+test cycle. T-ALIAS-SLOT asserts this ordering.
    "letflow.check_deferral_staleness",
    # ISS-0257: wired in as a hard gate, matching check_requirements_registration's
    # own precedent ("a check nobody runs is not a check") -- verified green on
    # main and against both open PRs' own new content before landing (neither adds
    # a handoffs/ file at all), so this addition does not retroactively fail any
    # currently in-flight branch. See HANDOFF_PROTOCOL.md's Enforcement note for
    # what "hard" and "advisory" mean for this task's own findings.
    "letflow.lint_handoffs",
    # ISS-0481: a pure static/textual scan over test/**/*_test.exs, like
    # lint_handoffs above and check_requirements_registration -- no
    # compile step, no shared parse target with any neighbor, so it has
    # no ordering dependency either direction. Placed with the other
    # fast, non-compiling checks so a violation surfaces in seconds, not
    # after a full compile+test cycle.
    "letflow.check_async_sandbox_reachability",
    # 2026-09-09: enforces ISSUE_QUEUE.md's "Numbering schema" -- three
    # registries (local ISS-NNNN, queue Q-N, GitHub GH-N) number
    # independently from 1, so an unprefixed cross-reference is ambiguous.
    # A pure column-0 textual scan over docs/issues/*.yaml: no compile step
    # and no shared parse target with any neighbour, so it has no ordering
    # dependency either direction. Placed with the other fast,
    # non-compiling checks so a violation surfaces in seconds. It exists as
    # a gate because the rule it replaces ("ISS-0187 is queue task 187") was
    # documented too, and decayed to 172/305 with nothing re-checking it.
    "letflow.check_issue_refs",
    # REQ-358: validates test/fixtures/uat/scenarios/**/*.yaml against the schema
    # documented in docs/agents/uat-scenario-schema.md -- placed with the other
    # fast, non-compiling structural scans (no shared parse target with any
    # neighbor, so no ordering dependency either direction).
    "letflow.check_uat_scenario_schema",
    # REQ-496 (design lib/letflow/design/req496-managed-by-and-scope-node-paths.md
    # §7): non-compiling textual scan, same class as check_issue_refs -- module
    # code may not name the scope_node_paths table or its internal modules.
    "letflow.check_scope_node_paths_writers",
    # REQ-517 (design req517-scoped-grants-admin-plane.md 3.13; SEC rule #2612): only
    # Letflow.Identity.RoleScopeGrants may write the role grants table. Same class of scan.
    "letflow.check_role_scope_grants_writers",
    # GH #2787: a non-compiling textual scan of config/*.exs -- the compile-time test-seam flag
    # `engine_test_seams` may be set only in config/test.exs, so no release config can ship the
    # seams or the zero retry backoff. Same class as the scans above.
    "letflow.check_engine_test_seams_config",
    "format --check-formatted",
    "compile --warnings-as-errors",
    # REQ-405: D3 backend boundary check (xref-based module boundary enforcement).
    # Must run after compile (xref needs fully compiled call graph) and before
    # check.test (fail fast on boundary violations without waiting for the test run).
    "letflow.check_boundaries"
  ]

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # ISS-0698 (design lib/letflow/design/iss0698-test-parallel-create-burst-fix.md
      # §3): function-based alias, not a static list, so scripts/test_parallel.sh's
      # new Step 1.7 can pre-run ecto.create/ecto.migrate itself (capped-concurrency,
      # see that script) and tell Step 2's `mix test` invocations to skip redoing it
      # (which would otherwise re-trigger the exact synchronized N-way pool-open
      # burst this fix exists to eliminate) via LETFLOW_SKIP_ECTO_SETUP=1. Default
      # (env var unset) is byte-for-byte the same three steps, same order, as the
      # static list this replaced -- every existing caller (plain `mix test`, CI, an
      # editor's test runner, `iex -S mix test`) is unaffected.
      #
      # Must call Mix.Task.run/2 directly for side effects -- must NOT return a list
      # of task-strings. Verified live (design doc §3/§7 OQ-1): a function alias's
      # return value is discarded by Mix's run_alias/6 (mix/lib/mix/task.ex
      # ~568-609); only a list-based alias's return value is walked as task-strings.
      # The trailing `Mix.Task.run("test", args)` call does not recurse back into
      # this alias -- Mix.TasksServer's alias-already-running guard (task.ex
      # ~424-425) runs the underlying `test` task directly once it sees `test`
      # requested again from inside this alias's own resolution.
      test: &test_alias/1,
      # `mix.exs` alias, not a `lib/mix/tasks/` custom task: REQ-003's
      # task-discovery-forces-compile problem (`docs/status/requirement_status.yaml`)
      # applied only to a module Mix must load from `lib/mix/tasks/` before running it,
      # and only broke a *timing measurement* that needed a genuinely-first compile to
      # measure — this alias needs neither (it wants `mix compile` to run as one of its
      # own steps regardless, and reads from `mix.exs` data, never from a compiled
      # `lib/` module), so the concern doesn't apply.
      #
      # ISS-0106 update: the alias's *first step* now IS such a `lib/mix/tasks/` task
      # (`letflow.check_toolchain`), so Mix must load that module before running it and
      # the alias therefore forces a project compile before the format check. The
      # hazard that raises is whether the later `compile --warnings-as-errors` step is
      # weakened by finding nothing left to recompile. It is not: measured (design
      # doc M5, re-verified as V4/V5) that an already-compiled project still exits 1
      # from that step, with the warnings re-emitted from the compile manifest.
      # Q-1037 / GH #2364: the static (everything-but-the-test-run) steps are shared
      # by `letflow.check.static` (a CI job that does not run the suite) and
      # `letflow.check` (this list followed by the test step, so the local alias is
      # the same flat step list as before; see @check_static_steps).
      "letflow.check.static": @check_static_steps,
      "letflow.check": @check_static_steps ++ ["letflow.check.test"]
    ]
  end

  # ISS-0698 (design lib/letflow/design/iss0698-test-parallel-create-burst-fix.md
  # §3): resolution function for the `test:` alias above. LETFLOW_SKIP_ECTO_SETUP=1
  # is set only by scripts/test_parallel.sh's Step 2, after its own new Step 1.7
  # has already run ecto.create/ecto.migrate for every partition under a
  # concurrency cap -- everyone else (env var unset) gets exactly today's
  # three-step behavior.
  defp test_alias(args) do
    if System.get_env("LETFLOW_SKIP_ECTO_SETUP") == "1" do
      Mix.Task.run("test", args)
    else
      Mix.Task.run("ecto.create", ["--quiet"])
      Mix.Task.run("ecto.migrate", ["--quiet"])
      Mix.Task.run("test", args)
    end
  end
end
