defmodule Letflow.Scripts.SeedScriptsNoArgvPayloadTest do
  @moduledoc """
  ISS-1036 / Q-1018 (GH #2328): the QA seed scripts must never pass a request body
  to `curl` as an argv payload variable.

  On Windows git-bash a ~29 KB definition passed as `curl -d "${payload}"` exceeds the
  process argument limit (`Argument list too long`) and no request is sent. Bodies must
  go through stdin (`--data-binary @-`) or a temp file (`--data-binary @"$tmp"`).

  ## Lint rule (`violations/2`)

  Every `scripts/seed_*.sh` and `scripts/lib/seed_*.sh` (globs, so new seed scripts and
  sourced helper libraries are covered automatically) is scanned as follows. The lib
  helpers matter: `seed_persona_actors_base.sh` is sourced by the meridian and vortex
  persona scripts and holds their `curl` calls.

    1. Backslash line-continuations are joined into one logical line. A comment line
       never continues (bash comments do not).
    2. Logical lines that are comments are skipped. A line whose first word is `echo` or
       `printf` (help text) is skipped too, UNLESS a `curl` word follows an unquoted
       `|`, `||`, `&&` or `;` operator token (the stdin form `printf '%s' "$p" | curl ...`
       is a real invocation and is scanned).
    3. A logical line containing the word `curl` is tokenized (whitespace-split,
       respecting single and double quotes). For every `-d`, `--data`, `--data-raw`,
       `--data-urlencode`, `--data-ascii` flag (or the `--flag=value` form) the
       argument token is classified. Short-flag clusters ending in `d` (`-sfd "${p}"`,
       `-fsSd`) take the next token as the argument, and glued forms (`-d"${p}"`,
       `-sfd"${p}"`, `-d@-`) take the remainder of the token:

         * starts with `@` (optionally quoted): file / stdin body, allowed
         * a pure expansion (`"${var}"`, `$var`, `"$(...)"`): VIOLATION (payload variable)
         * any other token containing `$`: VIOLATION unless the exact `{script, token}`
           pair is in `@allowed_literal_expansions` below (each with a justification)
         * a fixed literal longer than #{300} characters: VIOLATION (not "short")
         * otherwise a short fixed literal: allowed

  `--data-binary` is deliberately NOT a flagged flag (it is the fix), but
  `--data-binary "${var}"` would still ship an argv payload; it is therefore also
  checked with the same classification.

  ## Positive check (`body_modes/1`)

  Per curl call (not per file): every curl invocation carrying a
  `Content-Type: application/json` header is a body-bearing POST and is classified
  `:stdin` (`--data-binary @-`), `:file` (`@file` body) or `:literal` (short inline body).
  The 3 definition scripts must each have exactly one call and it must be `:stdin`;
  `seed_vortex_entities.sh` must have exactly three `:stdin` calls (restrictions import,
  entity query, record-chunk import) plus the two explicitly named exceptions: one `:file`
  (`-d "@${REPO_ROOT}/${fixture_path}"`, the entity definition create) and one `:literal`
  (the short activation rationale, allow-listed above).

  ## Blind spots (documented, not detected)

    * a payload hidden in an array or built into a variable of curl args, then expanded
      (`curl "${args[@]}"`), or `eval "curl ..."`
    * here-docs, and curl calls wrapped in a function whose caller passes the payload
    * scripts under `scripts/` or `scripts/lib/` not named `seed_*.sh` (for example
      `uat_preflight.sh`, `test_parallel.sh`, `timed_test.sh`), and any other directory
    * `eval`-wrapped or `bash -c "curl ..."` strings (the inner command is one token)
    * a literal body that is short today but could grow (only the 300-char cap guards it)
    * `curl` invoked via a variable (`$CURL`) or a path (`/usr/bin/curl` is caught,
      `$CURL` is not)

  ## End-to-end scope

  Beyond body delivery, the e2e tests check the unchanged request shape of each
  definition POST (AC3): method POST, the `-sf` fail flag, `Content-Type:
  application/json` and an `Authorization: Bearer` header (pattern only, the token value is
  never printed). One failure-path test makes the stub answer the definition POST with exit
  22 (what `curl -f` does on an HTTP error) and checks the meridian script exits 1 with its
  `ERROR: POST /api/v1/definitions failed` message; the same code shape is in the other two
  definition scripts, so it is exercised once, for meridian only.

  The end-to-end tests below run ONLY the three definition scripts
  (`seed_meridian_definition.sh`, `seed_vortex_definition.sh`,
  `seed_swiftroute_definition.sh`) against a stub `curl` that records how each body
  arrived; that backstops several blind spots for those scripts. The 3 payload sites in
  `seed_vortex_entities.sh` and the persona-actor scripts/helpers are covered by the
  static lint ONLY (plus the positive `--data-binary` check for entities), not e2e.

  No database, no HTTP, no network: the stub `curl` never leaves the machine.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @root Path.expand("../../..", __DIR__)

  @max_literal 300

  @data_flags ~w(-d --data --data-raw --data-urlencode --data-ascii --data-binary)

  @known_scripts ~w(
    seed_meridian_definition.sh
    seed_meridian_persona_actors.sh
    seed_swiftroute_definition.sh
    seed_swiftroute_incident_definition.sh
    seed_swiftroute_persona_actors.sh
    seed_vortex_definition.sh
    seed_vortex_entities.sh
    seed_vortex_persona_actors.sh
    seed_persona_actors_base.sh
    seed_service_task_base.sh
  )

  # Literal bodies that interpolate a variable but are small and bounded (a handful of
  # short identifier/name fields), so the argv limit cannot be reached. Keyed by exact
  # script basename and exact argument token; anything else containing `$` is flagged.
  @allowed_literal_expansions [
    # seed_vortex_entities.sh activation rationale: fixed sentence plus one entity
    # definition name (a short slug such as "ProductionBatch").
    {"seed_vortex_entities.sh",
     ~S|"{\"rationale\":\"UAT seed: activate ${name} entity definition (seed_vortex_entities.sh)\"}"|},
    # scripts/lib/seed_persona_actors_base.sh: shared helper sourced by the swiftroute, meridian and
    # vortex persona scripts (swiftroute migrated by ISS-1011); same three small bodies (short persona names + UUIDs),
    # sent with --data-ascii. Bounded, so the argv limit cannot be reached.
    {"seed_persona_actors_base.sh",
     ~S|"{\"name\":\"${name}\",\"display_name\":\"${display_name}\",\"description\":\"${description}\"}"|},
    {"seed_persona_actors_base.sh",
     ~S|"{\"name\":\"${name}\",\"kind\":\"process_routing_role\",\"group_id\":\"${group_id}\"}"|},
    {"seed_persona_actors_base.sh", ~S|"{\"user_id\":\"${user_id}\"}"|}
  ]

  # ---------------------------------------------------------------------------
  # Lint implementation
  # ---------------------------------------------------------------------------

  @doc false
  def violations(source, opts \\ []) do
    script = Keyword.get(opts, :script, "inline")
    allowed = Keyword.get(opts, :allowed, [])

    source
    |> curl_lines()
    |> Enum.flat_map(fn {n, line} ->
      line
      |> tokenize()
      |> data_args()
      |> Enum.flat_map(fn {flag, arg} ->
        case classify(arg) do
          :ok ->
            []

          :literal_with_expansion ->
            if {script, arg} in allowed,
              do: [],
              else: [%{line: n, flag: flag, arg: arg, reason: :literal_with_expansion}]

          reason ->
            [%{line: n, flag: flag, arg: arg, reason: reason}]
        end
      end)
    end)
  end

  defp curl_lines(source) do
    source
    |> logical_lines()
    |> Enum.reject(fn {_n, line} -> skippable?(line) end)
    |> Enum.filter(fn {_n, line} -> Regex.match?(~r/(^|[\s\/(`|&;])curl(\s|$)/, line) end)
  end

  @doc false
  # One entry per body-bearing curl call (carries a `Content-Type: application/json`
  # header): %{line: n, mode: :stdin | :file | :literal | :none}.
  def body_modes(source) do
    for {n, line} <- curl_lines(source),
        tokens = tokenize(line),
        Enum.any?(tokens, &String.contains?(&1, "Content-Type: application/json")) do
      %{line: n, mode: body_mode(data_args(tokens))}
    end
  end

  defp body_mode(args) do
    cond do
      Enum.any?(args, fn {f, a} -> f == "--data-binary" and a == "@-" end) -> :stdin
      Enum.any?(args, fn {_f, a} -> file_arg?(a) end) -> :file
      args != [] -> :literal
      true -> :none
    end
  end

  defp file_arg?(a), do: String.starts_with?(String.replace(a, ~r/^["']+/, ""), "@")

  # Joins backslash continuations; returns [{first_physical_lineno, logical_line}].
  defp logical_lines(source) do
    source
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, fn {phys, n}, {done, pending} ->
      case pending do
        nil ->
          start_line(phys, n, done)

        {pn, acc} ->
          joined = acc <> " " <> String.trim_leading(phys)
          continue_or_close(joined, pn, done)
      end
    end)
    |> then(fn {done, pending} ->
      done = if pending, do: [{elem(pending, 0), elem(pending, 1)} | done], else: done
      Enum.reverse(done)
    end)
  end

  defp start_line(phys, n, done) do
    if String.starts_with?(String.trim_leading(phys), "#") do
      {[{n, phys} | done], nil}
    else
      continue_or_close(phys, n, done)
    end
  end

  defp continue_or_close(text, n, done) do
    if String.ends_with?(text, "\\") do
      {done, {n, String.slice(text, 0, String.length(text) - 1)}}
    else
      {[{n, text} | done], nil}
    end
  end

  defp skippable?(line) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "#") ->
        true

      Regex.match?(~r/^(echo|printf)(\s|$)/, trimmed) ->
        not curl_after_operator?(tokenize(trimmed))

      true ->
        false
    end
  end

  # True when a `curl` word follows an unquoted pipe/list operator token, i.e. an echo or
  # printf line that actually feeds a real curl invocation.
  defp curl_after_operator?(tokens) do
    case Enum.drop_while(tokens, &(&1 not in ["|", "||", "&&", ";"])) do
      [] -> false
      [_op | rest] -> Enum.any?(rest, &(&1 == "curl" or String.ends_with?(&1, "/curl")))
    end
  end

  # Whitespace tokenizer respecting '...' and "..." (backslash escapes inside "...").
  defp tokenize(line), do: tok(line, nil, "", [])

  defp tok(<<>>, _q, cur, acc), do: Enum.reverse(push(cur, acc))

  defp tok(<<?\\, c, rest::binary>>, q, cur, acc) when q != ?',
    do: tok(rest, q, cur <> <<?\\, c>>, acc)

  defp tok(<<c, rest::binary>>, nil, cur, acc) when c in [?", ?'],
    do: tok(rest, c, cur <> <<c>>, acc)

  defp tok(<<c, rest::binary>>, q, cur, acc) when c == q,
    do: tok(rest, nil, cur <> <<c>>, acc)

  defp tok(<<c, rest::binary>>, nil, cur, acc) when c in [?\s, ?\t],
    do: tok(rest, nil, "", push(cur, acc))

  defp tok(<<c, rest::binary>>, q, cur, acc), do: tok(rest, q, cur <> <<c>>, acc)

  defp push("", acc), do: acc
  defp push(cur, acc), do: [cur | acc]

  defp data_args(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.flat_map(fn {tok, i} ->
      cond do
        tok in @data_flags or Regex.match?(~r/^-[A-Za-z]*d$/, tok) ->
          case Enum.at(tokens, i + 1) do
            nil -> []
            arg -> [{tok, arg}]
          end

        glued = Regex.run(~r/^-[A-Za-z]*d(["'$@{].*)$/s, tok, capture: :all_but_first) ->
          [{"-d(glued)", hd(glued)}]

        match?([_, _], eq_split(tok)) ->
          [flag, arg] = eq_split(tok)
          [{flag, arg}]

        true ->
          []
      end
    end)
  end

  defp eq_split("--" <> _ = tok) do
    case String.split(tok, "=", parts: 2) do
      [flag, _] = parts -> if flag in @data_flags, do: parts, else: []
      _ -> []
    end
  end

  defp eq_split(_), do: []

  defp classify(arg) do
    bare = String.replace(arg, ~r/^["']+/, "")

    cond do
      String.starts_with?(bare, "@") ->
        :ok

      Regex.match?(~r/^"?\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"?$/, arg) ->
        :payload_variable

      Regex.match?(~r/^"?\$\(/, arg) ->
        :payload_variable

      String.contains?(arg, "$") and not String.starts_with?(arg, "'") ->
        :literal_with_expansion

      String.length(arg) > @max_literal ->
        :literal_too_long

      true ->
        :ok
    end
  end

  defp seed_scripts,
    do:
      Path.wildcard(Path.join(@root, "scripts/seed_*.sh")) ++
        Path.wildcard(Path.join(@root, "scripts/lib/seed_*.sh"))

  defp script_path(name) do
    Enum.find(seed_scripts(), &(Path.basename(&1) == name)) ||
      flunk("seed script #{name} not found under scripts/ or scripts/lib/")
  end

  # ---------------------------------------------------------------------------
  # Repo scripts
  # ---------------------------------------------------------------------------

  describe "scripts/seed_*.sh + scripts/lib/seed_*.sh glob" do
    test "is non-empty and includes the known seed scripts" do
      names = Enum.map(seed_scripts(), &Path.basename/1)
      assert names != []
      missing = @known_scripts -- names
      assert missing == [], "known seed scripts missing from glob: #{inspect(missing)}"
    end
  end

  describe "no seed script passes a payload variable via curl argv" do
    for script <- @known_scripts do
      test "#{script} has no argv payload" do
        path = script_path(unquote(script))

        found =
          violations(File.read!(path),
            script: unquote(script),
            allowed: @allowed_literal_expansions
          )

        assert found == [],
               "#{unquote(script)} passes a curl body through argv (breaks on Windows git-bash, " <>
                 "'Argument list too long'); use --data-binary @- or @file: #{inspect(found)}"
      end
    end

    test "every glob-discovered seed script is clean (covers new scripts)" do
      bad =
        for path <- seed_scripts(),
            v =
              violations(File.read!(path),
                script: Path.basename(path),
                allowed: @allowed_literal_expansions
              ),
            v != [],
            do: {Path.basename(path), v}

      assert bad == []
    end
  end

  describe "positive check: every body-bearing curl call sends its body via stdin/file" do
    for script <-
          ~w(seed_meridian_definition.sh seed_swiftroute_definition.sh seed_swiftroute_incident_definition.sh seed_vortex_definition.sh) do
      test "#{script}: exactly one body call, and it is --data-binary @-" do
        modes = body_modes(File.read!(Path.join(@root, "scripts/#{unquote(script)}")))
        assert Enum.map(modes, & &1.mode) == [:stdin], inspect(modes)
      end
    end

    test "seed_vortex_entities.sh: 3 stdin calls plus the named @file and literal-rationale exceptions" do
      modes = body_modes(File.read!(Path.join(@root, "scripts/seed_vortex_entities.sh")))

      assert modes |> Enum.map(& &1.mode) |> Enum.sort() ==
               [:file, :literal, :stdin, :stdin, :stdin],
             inspect(modes)
    end
  end

  # ---------------------------------------------------------------------------
  # Detector self-tests (independent of repo scripts)
  # ---------------------------------------------------------------------------

  describe "detector self-tests" do
    test "flags curl -d with a quoted payload variable" do
      src = ~S|curl -sf -X POST -H "x: y" -d "${payload}" "${API}/definitions"|
      assert [%{reason: :payload_variable, flag: "-d"}] = violations(src)
    end

    test "flags unbraced variable and uppercase var" do
      assert [%{reason: :payload_variable}] = violations(~S|curl -d $body http://x|)
      assert [%{reason: :payload_variable}] = violations(~S|curl --data "$PAYLOAD" http://x|)
    end

    test "flags other data flags and the = form" do
      for flag <- ~w(--data --data-raw --data-urlencode --data-ascii) do
        assert [%{reason: :payload_variable}] = violations(~s|curl #{flag} "${p}" http://x|)
      end

      assert [%{reason: :payload_variable}] = violations(~S|curl --data-raw="${p}" http://x|)
    end

    test "flags command substitution body and --data-binary with a variable" do
      assert [%{reason: :payload_variable}] = violations(~S|curl -d "$(cat f.json)" http://x|)
      assert [%{reason: :payload_variable}] = violations(~S|curl --data-binary "${p}" http://x|)
    end

    test "flags a payload variable on a backslash-continued line and reports the first line" do
      src = """
      x=1
      resp=$(curl -sf \\
        -X POST \\
        -H "Content-Type: application/json" \\
        -d "${payload}" \\
        "${API}/definitions")
      """

      assert [%{reason: :payload_variable, line: 2}] = violations(src)
    end

    test "flags an expansion-bearing literal unless allow-listed by script and exact token" do
      tok = ~S|"{\"a\":\"${x}\"}"|
      src = ~s|curl -d #{tok} http://x|
      assert [%{reason: :literal_with_expansion}] = violations(src, script: "s.sh")
      assert violations(src, script: "s.sh", allowed: [{"s.sh", tok}]) == []

      assert [%{reason: :literal_with_expansion}] =
               violations(src, script: "other.sh", allowed: [{"s.sh", tok}])
    end

    test "flags an over-long fixed literal" do
      long = String.duplicate("a", 400)
      assert [%{reason: :literal_too_long}] = violations(~s|curl -d '#{long}' http://x|)
    end

    test "does not flag @-, @file, quoted @file, or --data-binary @-" do
      assert violations(~S|curl -d @- http://x|) == []
      assert violations(~S|curl -d @body.json http://x|) == []
      assert violations(~S|curl -d "@${ROOT}/f.json" http://x|) == []
      assert violations(~S|curl --data-binary @- http://x|) == []
      assert violations(~S|curl --data-binary @"$tmp" http://x|) == []
      assert violations(~S<printf '%s' "${p}" | curl --data-binary @- http://x>) == []
    end

    test "does not flag a short fixed literal or single-quoted body" do
      assert violations(~S|curl -d '{"a":1}' http://x|) == []
      assert violations(~S|curl -d "{\"a\":1}" http://x|) == []
    end

    test "does not flag comments, echo or printf help text" do
      src = ~S"""
      # curl -d "${payload}" http://x
      #   curl -sf -d "${PAYLOAD}" \
      echo "Run: curl -sf -X POST \\"
      echo "  -d '{\"definition_id\":\"${DEFINITION_ID}\"}' \\"
      printf 'curl -d "${p}"\n'
      """

      assert violations(src) == []
    end

    test "a comment line ending in a backslash does not swallow the next real curl line" do
      src = ~S"""
      # note \
      curl -d "${payload}" http://x
      """

      assert [%{reason: :payload_variable, line: 2}] = violations(src)
    end

    test "echo/printf feeding a real curl is scanned, plain help text is not" do
      assert [%{reason: :payload_variable}] =
               violations(~S<printf '%s' "$p" | curl -sf -d "$p" http://x>)

      assert [%{reason: :payload_variable}] =
               violations(~S<echo "$p" | curl -sf -d "${p}" http://x>)

      assert violations(~S<printf '%s' "$p" | curl -sf --data-binary @- http://x>) == []
      assert violations(~S|echo "  -d '{\"a\":\"${x}\"}'"|) == []
    end

    test "flags combined and glued short flags" do
      assert [%{reason: :payload_variable}] = violations(~S|curl -sfd "${p}" http://x|)
      assert [%{reason: :payload_variable}] = violations(~S|curl -fsSd "${p}" http://x|)
      assert [%{reason: :payload_variable}] = violations(~S|curl -d"${p}" http://x|)
      assert [%{reason: :payload_variable}] = violations(~S|curl -sfd"${p}" http://x|)
      assert [%{reason: :payload_variable}] = violations(~S|curl --data="${p}" http://x|)
      assert violations(~S|curl -sfd @- http://x|) == []
      assert violations(~S|curl -d@- http://x|) == []
      assert violations(~S|curl -sf -H "x: y" http://x|) == []
    end

    test "body_modes classifies each body-bearing call" do
      src = """
      a=$(printf '%s' "$p" | curl -sf -H "Content-Type: application/json" --data-binary @- u)
      curl -sf -H "Content-Type: application/json" -d "@f.json" u
      curl -s -H "Content-Type: application/json" -d '{"a":1}' u
      curl -sf -H "Content-Type: application/json" u
      curl -sf u
      """

      assert Enum.map(body_modes(src), & &1.mode) == [:stdin, :file, :literal, :none]
    end

    test "non-curl lines with -d are ignored" do
      assert violations(~S|sort -d "${x}"|) == []
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end: run the real scripts against a stub `curl` (no network)
  # ---------------------------------------------------------------------------

  describe "end-to-end with a stub curl" do
    @e2e_cases [
      {"seed_meridian_definition.sh",
       [
         "test/fixtures/qa/meridian_loan_origination_process_definition.json",
         "test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json"
       ]},
      {"seed_vortex_definition.sh",
       [
         "test/fixtures/qa/vortex_production_order_release_process_definition.json",
         "test/fixtures/qa/vortex_8d_corrective_action_definition.json",
         "test/fixtures/qa/vortex_supplier_quality_deviation_process_definition.json"
       ]},
      {"seed_swiftroute_definition.sh", ["test/fixtures/qa/swiftroute_process_definition.json"]},
      {"seed_swiftroute_incident_definition.sh",
       ["test/fixtures/qa/swiftroute_incident_process_definition.json"]}
    ]

    # Stub curl: records, per invocation N, the argv byte length, the last argument (URL),
    # whether a body was passed inline in argv (`inline_N` marker) and the body bytes
    # (`body_N`, read from stdin for `@-` or from the file for `@file`). Answers every
    # call deterministically: GET -> no existing definition, POST .../activate -> ACTIVE,
    # other POST -> a created DRAFT with an id.
    @stub ~S"""
    #!/usr/bin/env bash
    dir="${STUB_CURL_DIR}"
    n=$(( $(cat "${dir}/count" 2>/dev/null || echo 0) + 1 ))
    echo "${n}" > "${dir}/count"
    printf '%s\0' "$@" | wc -c | tr -d ' \r' > "${dir}/argv_len_${n}"
    args=("$@")
    last="${args[$(( ${#args[@]} - 1 ))]}"
    printf '%s' "${last}" > "${dir}/url_${n}"
    printf '%s\n' "$@" > "${dir}/args_${n}"
    method=GET
    i=0
    while [[ ${i} -lt ${#args[@]} ]]; do
      a="${args[${i}]}"
      case "${a}" in
        -X) method="${args[$(( i + 1 ))]}" ;;
        -d|--data|--data-raw|--data-binary|--data-ascii)
          v="${args[$(( i + 1 ))]}"
          [[ "${method}" == GET ]] && method=POST
          if [[ "${v}" == "@-" ]]; then
            cat > "${dir}/body_${n}"
          elif [[ "${v}" == @* ]]; then
            cat "${v:1}" > "${dir}/body_${n}"
          else
            printf '%s' "${v}" > "${dir}/body_${n}"
            : > "${dir}/inline_${n}"
          fi
          ;;
      esac
      i=$(( i + 1 ))
    done
    if [[ "${method}" == POST && "${last}" != */activate && -n "${STUB_CURL_FAIL_POST:-}" ]]; then
      exit 22
    fi
    if [[ "${last}" == */me/access ]]; then
      printf '%s' '{"permissions":["DefinitionsRead","DefinitionsWrite"]}'
    elif [[ "${last}" == */activate ]]; then
      printf '%s' '{"id":"def-stub-1","name":"Stub","version":"1","status":"ACTIVE"}'
    elif [[ "${method}" == POST ]]; then
      printf '%s' '{"id":"def-stub-1","name":"Stub","version":"1","status":"DRAFT"}'
    else
      printf '%s' '{"items":[]}'
    fi
    """

    setup do
      case find_bash() do
        nil ->
          flunk(
            "bash not found (on Windows install Git for Windows; the WSL launcher " <>
              "bash.exe is deliberately ignored); the end-to-end seed-script tests cannot run"
          )

        bash ->
          if System.find_executable("jq") == nil,
            do: flunk("jq not found on PATH; the seed scripts require jq")

          dir =
            Path.join(
              System.tmp_dir!(),
              "seed_stub_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
            )

          File.mkdir_p!(dir)
          on_exit(fn -> File.rm_rf(dir) end)
          File.write!(Path.join(dir, "curl"), String.replace(@stub, "\r\n", "\n"))
          File.chmod!(Path.join(dir, "curl"), 0o755)
          {:ok, bash: bash, dir: dir}
      end
    end

    for {script, fixtures} <- @e2e_cases do
      test "#{script}: bodies reach curl intact via stdin/file, never argv", %{
        bash: bash,
        dir: dir
      } do
        script = unquote(script)
        fixtures = unquote(fixtures)
        {out, status} = run_seed(bash, dir, script, [])

        assert status == 0, "#{script} exited #{status}: #{String.slice(out, 0, 1500)}"

        calls = String.to_integer(String.trim(File.read!(Path.join(dir, "count"))))

        posts =
          for n <- 1..calls,
              File.exists?(Path.join(dir, "body_#{n}")),
              not String.ends_with?(File.read!(Path.join(dir, "url_#{n}")), "/activate"),
              do: n

        assert posts != [], "no definition POST body was recorded by the stub curl"

        assert Enum.all?(posts, &(not File.exists?(Path.join(dir, "inline_#{&1}")))),
               "a definition body was passed inline in curl argv"

        # AC3: request shape unchanged -- POST, -sf fail flag, JSON content type, bearer auth.
        for n <- posts do
          args =
            dir |> Path.join("args_#{n}") |> File.read!() |> String.split(~r/\r?\n/, trim: true)

          assert "-sf" in args, "definition POST #{n} lost the -sf fail flag"

          assert ["-X", "POST"] in Enum.chunk_every(args, 2, 1, :discard),
                 "POST #{n} is not -X POST"

          assert "Content-Type: application/json" in args, "POST #{n} lost the JSON content type"

          assert Enum.any?(args, &Regex.match?(~r/^Authorization: Bearer \S+$/, &1)),
                 "POST #{n} has no Authorization: Bearer header"
        end

        recorded = Enum.map(posts, &File.read!(Path.join(dir, "body_#{&1}")))

        # Exact bytes: the scripts capture the payload with `$(...)`, which strips only
        # trailing newlines, so the fixture is compared after stripping exactly those
        # (not other whitespace) and the recorded body is NOT trimmed at all.
        expected =
          Enum.map(fixtures, &(@root |> Path.join(&1) |> File.read!() |> String.trim_trailing("
")))

        assert recorded == expected,
               "recorded request bodies differ byte-for-byte from the fixtures"

        min = if script == "seed_meridian_definition.sh", do: 29_000, else: 1000
        assert hd(recorded) |> byte_size() > min

        for n <- 1..calls do
          len =
            dir
            |> Path.join("argv_len_#{n}")
            |> File.read!()
            |> String.trim()
            |> String.to_integer()

          assert len < 2000, "curl call #{n} had #{len} bytes of argv (body leaked into argv?)"
        end
      end
    end

    test "seed_meridian_definition.sh: a failing definition POST (curl -f exit 22) exits 1 with its ERROR message",
         %{bash: bash, dir: dir} do
      {out, status} =
        run_seed(bash, dir, "seed_meridian_definition.sh", [{"STUB_CURL_FAIL_POST", "1"}])

      assert status == 1, "expected exit 1, got #{status}: #{String.slice(out, 0, 1500)}"
      assert out =~ "ERROR: POST /api/v1/definitions failed"
      refute out =~ "Activated"
    end

    # No default argument on purpose (ISS-0069): every caller passes extra_env explicitly.
    defp run_seed(bash, dir, script, extra_env) do
      fwd = String.replace(dir, "\\", "/")
      sep = if match?({:win32, _}, :os.type()), do: ";", else: ":"

      System.cmd(bash, ["scripts/#{script}"],
        cd: @root,
        stderr_to_stdout: true,
        env:
          [
            {"PATH", dir <> sep <> System.get_env("PATH", "")},
            {"STUB_CURL_DIR", fwd},
            {"QA_AUTH_TOKEN", "stub-token"},
            {"QA_URL", "https://stub.invalid"}
          ] ++ extra_env
      )
    end

    defp find_bash do
      case :os.type() do
        {:win32, _} ->
          git = System.find_executable("git")

          # usr/bin/bash.exe, not bin/bash.exe: the latter re-runs the Git profile, which
          # prepends /mingw64/bin (the real curl) ahead of our stub on PATH.
          roots =
            if(git,
              do: [Path.dirname(Path.dirname(git)), Path.dirname(Path.dirname(Path.dirname(git)))],
              else: []
            ) ++
              ["C:/Program Files/Git", "C:/Program Files (x86)/Git"]

          candidates = Enum.map(roots, &Path.join([&1, "usr", "bin", "bash.exe"]))

          Enum.find(candidates, &File.exists?/1)

        _ ->
          System.find_executable("bash")
      end
    end
  end
end
