defmodule Mix.Tasks.Letflow.CheckToolchainTest do
  @moduledoc """
  Regression coverage for ISS-0106 Part A: `mix letflow.check_toolchain`
  (`lib/mix/tasks/letflow.check_toolchain.ex`).

  Spec: `test/specs/ISS-0106.md`. Design:
  `lib/letflow/design/iss0106-toolchain-pin-and-format-fix.md`. Authority:
  `docs/migration/decisions/0005-pin-formatting-toolchain.md`.

  ## Why the tests are shaped this way

  The task's only public function is `run/1`; every helper is private, and
  the pin file is read from the *current working directory*. There is no
  seam to inject a path or to call the parser or the comparison rule
  directly. So every test here drives the whole task for real, against a
  fixture `.tool-versions` written into a fresh temp directory that is made
  the working directory for the duration of the call, and asserts on the
  captured output. Nothing about the module is mocked, stubbed, or
  refactored -- adding a seam would be a design change and is not this
  file's to make.

  Two consequences follow and are deliberate:

    * `async: false`, because `File.cd!/2` changes the working directory for
      the whole VM, not for one process. The cd window is kept to the single
      `run/1` call for that reason.
    * Warning output is captured with `ExUnit.CaptureIO.capture_io(:stderr,
      ...)`, because the task writes warnings to `:stderr` on purpose (it
      must survive a caller that pipes stdout elsewhere, and must not be
      silenceable through Mix's replaceable shell).

  ## No test asserts what this host's toolchain happens to be

  ISS-0106 is a cross-host toolchain-drift issue, so a test that only passes
  on Elixir 1.20.3 / OTP 29 would be a new instance of the very problem
  being fixed. There is not one hardcoded version string in this file.
  Every fixture is *generated at run time* from `System.version/0` and
  `:erlang.system_info(:otp_release)` -- the same two sources the task
  itself reads -- and every off-pin fixture is derived from the running
  value by `off_pin/1`, which appends a digit and therefore yields a string
  that differs from the running one by construction on any host, because it
  is longer.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Letflow.CheckToolchain

  @pin_file ".tool-versions"
  @module_source "lib/mix/tasks/letflow.check_toolchain.ex"
  @project_root Path.expand("../../..", __DIR__)

  # ------------------------------------------------------------------
  # Runtime-derived toolchain facts. Functions, not module attributes, so
  # they are read when the test runs rather than when it was compiled.
  # ------------------------------------------------------------------

  defp running_elixir, do: System.version()

  defp running_otp, do: List.to_string(:erlang.system_info(:otp_release))

  # Same "read it the way the task itself reads it" discipline as
  # running_elixir/0 and running_otp/0 above, extended to Rust for
  # REQ-165's F9 coverage: shells out to `rustc --version` exactly like
  # `running_rust_version/0` in the task does, so no version is hardcoded.
  defp running_rust_raw do
    case System.cmd("rustc", ["--version"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp running_rust_version do
    case running_rust_raw() do
      nil -> nil
      raw -> raw |> String.split(~r/\s+/, trim: true) |> Enum.at(1)
    end
  end

  # Yields a version string that CANNOT equal `version` on any host: it is
  # `version` plus one more character, so it differs in length. This is how
  # "off pin" is expressed without naming a version.
  defp off_pin(version), do: version <> "9"

  # A pin file that matches this host. The erlang pin is deliberately a
  # FULL version (major plus a minor/patch that no `otp_release` can ever
  # report) so that the major-only comparison rule is exercised, not
  # bypassed.
  defp matching_pin do
    "elixir #{running_elixir()}-otp-#{running_otp()}\nerlang #{running_otp()}.7.13\n"
  end

  # ------------------------------------------------------------------
  # Driver
  # ------------------------------------------------------------------

  defp fresh_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "letflow_toolchain_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Runs the real `run/1` with `dir` as the working directory, capturing
  # stdout and stderr separately. Returns {result, stdout, stderr}.
  defp run_in(dir, args \\ []) do
    capture_both(fn -> File.cd!(dir, fn -> CheckToolchain.run(args) end) end)
  end

  # Writes `contents` as the pin file in a fresh directory and runs there.
  defp run_with_pin(contents, args \\ []) do
    dir = fresh_dir()
    File.write!(Path.join(dir, @pin_file), contents)
    run_in(dir, args)
  end

  defp capture_both(fun) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn -> send(parent, {:capture_result, fun.()}) end)
        |> then(&send(parent, {:capture_stdout, &1}))
      end)

    result =
      receive do
        {:capture_result, value} -> value
      after
        0 -> :no_result_captured
      end

    stdout =
      receive do
        {:capture_stdout, value} -> value
      after
        0 -> :no_stdout_captured
      end

    {result, stdout, stderr}
  end

  # The module's own source with every `\"""`-delimited doc block removed,
  # so structural checks below inspect code rather than prose about code.
  defp module_code do
    @project_root
    |> Path.join(@module_source)
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {kept, in_doc?} ->
      cond do
        String.contains?(line, ~s(""")) -> {kept, not in_doc?}
        in_doc? -> {kept, in_doc?}
        true -> {[line | kept], in_doc?}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # A process that speaks the Erlang IO protocol and answers every request
  # with an error reply, which makes IO.puts/1 raise in whatever process
  # has it as its group leader. Used only by the F8 test.
  defp refusing_io_device do
    device =
      spawn(fn ->
        loop = fn loop ->
          receive do
            {:io_request, from, reply_as, _request} ->
              send(from, {:io_reply, reply_as, {:error, :enotsup}})
              loop.(loop)

            :stop ->
              :ok
          end
        end

        loop.(loop)
      end)

    on_exit(fn -> send(device, :stop) end)
    device
  end

  defp elixir_row(expected, running, verdict) do
    "  Elixir  expected #{expected}   running #{running}   #{verdict}"
  end

  defp otp_row(expected, token, running, verdict) do
    "  OTP     expected #{expected} (from erlang #{token})   running #{running}   #{verdict}"
  end

  defp rust_row_match(expected, running, verdict) do
    "  Rust    expected #{expected}   running #{running}   #{verdict}"
  end

  # ==================================================================

  describe "matching pin" do
    # Spec T-M1. The MATCH path: no warning at all, and an affirmative OK
    # line on stdout. Fixture is generated from the running toolchain, so
    # this passes on every host rather than on this one.
    test "prints an OK line to stdout and warns nothing" do
      {result, stdout, stderr} = run_with_pin(matching_pin())

      assert result == :ok
      assert stdout =~ "letflow.check_toolchain: OK"
      assert stdout =~ "Elixir #{running_elixir()} / OTP #{running_otp()}"
      assert stdout =~ "matches #{@pin_file}."
      assert stderr == ""
    end

    # Spec T-M2, and the subtle rule of the whole module. `.tool-versions`
    # must pin a FULL erlang version (asdf requires one) but
    # :erlang.system_info(:otp_release) reports only the major. This
    # fixture pins "<major>.7.13" against a running release of "<major>".
    #
    # HOW THIS FAILS UNDER A NAIVE FULL-STRING COMPARISON: the expected
    # value would be the whole token "<major>.7.13", which can never equal
    # the running "<major>", so the task would emit a TOOLCHAIN OFF PIN
    # block on a correctly-pinned host -- permanently, on every run. This
    # test then fails on `assert stderr == ""` above and on the two
    # assertions below, which is exactly the false positive the rule
    # exists to prevent. Verified by mutation, see test/specs/ISS-0106.md.
    test "a full erlang pin matches a major-only OTP release" do
      pin = "elixir #{running_elixir()}\nerlang #{running_otp()}.7.13\n"
      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr == ""
      assert stdout =~ "letflow.check_toolchain: OK"
      refute stdout =~ "MISMATCH"
    end

    # Spec T-M3. The `-otp-NN` suffix names the OTP major asdf's Elixir
    # build was compiled against, not the runtime, and the design says it
    # is parsed off and DISCARDED. Here the suffix names an OTP major that
    # is NOT running while the erlang line names the one that is: the
    # verdict must follow the erlang line, so this still matches. If the
    # suffix participated in the OTP verdict this would report a mismatch.
    test "the -otp-NN suffix is discarded and never compared" do
      pin =
        "elixir #{running_elixir()}-otp-#{off_pin(running_otp())}\n" <>
          "erlang #{running_otp()}.7.13\n"

      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr == ""
      assert stdout =~ "letflow.check_toolchain: OK"
    end
  end

  # REQ-165: mutation-testing gap found by TEST-DESIGNER (test/specs/REQ-165.md
  # findings table). This whole `describe` block did not previously exist --
  # zero tests in this file exercised the `rust` row at all (match, mismatch,
  # or F9 not-found), even though `lib/mix/tasks/letflow.check_toolchain.ex`
  # already implemented all three. Confirmed by mutating
  # `running_rust_version/0` to swallow a `System.cmd/2` failure into
  # `{:ok, ""}` instead of `:not_found`: the full 30-test suite still passed.
  describe "rust pin (REQ-165)" do
    # A matching rust pin, generated at run time from the same `rustc
    # --version` shell-out the task itself performs, so this passes on any
    # host with a pinned-and-matching Rust toolchain (which every host that
    # runs this suite has, per .tool-versions + CI's Rust setup step).
    test "a matching rust pin reports OK with no mismatch" do
      version = running_rust_version()
      assert is_binary(version), "expected `rustc` to be on PATH while running this suite"

      pin = "elixir #{running_elixir()}\nerlang #{running_otp()}.7.13\nrust #{version}\n"
      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr == ""
      assert stdout =~ "letflow.check_toolchain: OK"
      assert stdout =~ "Rust #{running_rust_raw()}"
    end

    # off_pin/1 makes an expected value that cannot equal the running one on
    # any host (see its own doc), so this is host-independent too.
    test "a mismatched rust pin reports a MISMATCH row naming expected and running" do
      version = running_rust_version()
      assert is_binary(version), "expected `rustc` to be on PATH while running this suite"

      expected = off_pin(version)
      pin = "elixir #{running_elixir()}\nerlang #{running_otp()}.7.13\nrust #{expected}\n"
      {result, _stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"
      assert stderr =~ rust_row_match(expected, running_rust_raw(), "<-- MISMATCH")
    end

    # No `rust` line at all is the existing "not pinned" shape, reusing
    # F3/F4's row -- and must not, by itself, turn an otherwise-matching
    # pin into a warning.
    test "no rust pin is treated as not-pinned and still reports OK" do
      pin = "elixir #{running_elixir()}\nerlang #{running_otp()}.7.13\n"
      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr == ""
      assert stdout =~ "letflow.check_toolchain: OK"
    end

    # F9: rustc pinned but not found/not runnable on PATH. Induced for real
    # by emptying PATH for the duration of the call (restored via on_exit),
    # which makes `System.cmd("rustc", ...)` raise :enoent -- exactly the
    # failure `running_rust_version/0`'s rescue/catch clauses exist for.
    # This is the exact regression the F9 mutation above slipped past every
    # other test in this file.
    test "F9 rustc not found on PATH reports a NOT FOUND row and still returns ok" do
      original_path = System.get_env("PATH")

      on_exit(fn ->
        case original_path do
          nil -> System.delete_env("PATH")
          value -> System.put_env("PATH", value)
        end
      end)

      System.put_env("PATH", "")

      pin = "elixir #{running_elixir()}\nerlang #{running_otp()}.7.13\nrust 1.97.1\n"
      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"

      assert stderr =~
               "  Rust    expected 1.97.1   running (rustc not found or not runnable)   <-- NOT FOUND"

      refute stdout =~ "TOOLCHAIN"
    end
  end

  describe "mismatch" do
    # Spec T-X1. Elixir off pin, OTP on pin. Decision 0005 requires the
    # warning to name BOTH the expected and the running version, so the
    # assertion is on the whole rendered row, not on either version alone
    # (the running version is a prefix of the off-pin one, so a bare
    # `=~ running` would pass vacuously).
    test "elixir alone off pin names expected and running" do
      expected = off_pin(running_elixir())
      pin = "elixir #{expected}\nerlang #{running_otp()}.7.13\n"
      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"
      assert stderr =~ elixir_row(expected, running_elixir(), "<-- MISMATCH")
      assert stderr =~ otp_row(running_otp(), "#{running_otp()}.7.13", running_otp(), "matches")
      refute stdout =~ "TOOLCHAIN"
    end

    # Spec T-X2. OTP off pin, Elixir on pin. Both rows are always emitted,
    # so the reader never has to infer which comparison was silent.
    test "otp alone off pin names expected and running" do
      major = off_pin(running_otp())
      token = "#{major}.7.13"
      pin = "elixir #{running_elixir()}-otp-#{running_otp()}\nerlang #{token}\n"
      {result, _stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"
      assert stderr =~ otp_row(major, token, running_otp(), "<-- MISMATCH")
      assert stderr =~ elixir_row(running_elixir(), running_elixir(), "matches")
    end

    # Spec T-X3. Both off pin: both rows carry the mismatch marker and
    # both name their expected and running values.
    test "both off pin mark both rows" do
      exp_elixir = off_pin(running_elixir())
      major = off_pin(running_otp())
      token = "#{major}.7.13"
      pin = "elixir #{exp_elixir}\nerlang #{token}\n"
      {result, _stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ elixir_row(exp_elixir, running_elixir(), "<-- MISMATCH")
      assert stderr =~ otp_row(major, token, running_otp(), "<-- MISMATCH")
    end

    # Spec T-X4. The warning is actionable only if it says where the pin
    # lives, which record authorises it, and that it is not a failure.
    test "the block cites the pin file and the record" do
      pin = "elixir #{off_pin(running_elixir())}\nerlang #{running_otp()}.7.13\n"
      {result, _stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ "  Pin file: #{@pin_file}"
      assert stderr =~ "  Record:   docs/migration/decisions/0005-pin-formatting-toolchain.md"
      assert stderr =~ "does NOT fail the build"
    end

    # Spec T-X5. A version token that "does not parse" is NOT an error
    # path: both comparisons are string equality on split results, so a
    # nonsense token is an ordinary mismatch and still returns :ok.
    test "a nonsense version token is an ordinary mismatch" do
      pin = "elixir not-a-version\nerlang also-not-a-version\n"
      {result, _stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"
      assert stderr =~ elixir_row("not-a-version", running_elixir(), "<-- MISMATCH")
      refute stderr =~ "Internal error"
    end
  end

  describe "parse contract" do
    # Spec T-P1. The design says comment lines, blank lines and other
    # tools' lines are ignored SILENTLY -- ignored means no malformed-line
    # report and no effect on the verdict. Only a recognised tool name
    # with no version token is reported (that is F5, covered separately).
    test "comments blanks and other tools are ignored" do
      pin = """
      # asdf pins for this repo

      nodejs 22.1.0
      elixir #{running_elixir()}-otp-#{running_otp()}

      python 3.12.1
      erlang #{running_otp()}.7.13
      """

      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr == ""
      assert stdout =~ "letflow.check_toolchain: OK"
    end

    # Spec T-P2. A trailing comment on a pinned line is stripped before
    # tokenising, so the version is still read correctly.
    test "a trailing comment is stripped from a pinned line" do
      pin =
        "elixir #{running_elixir()}-otp-#{running_otp()}  # pinned by ISS-0106\n" <>
          "erlang #{running_otp()}.7.13 # ditto\n"

      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr == ""
      assert stdout =~ "letflow.check_toolchain: OK"
    end

    # Spec T-P3. asdf resolves a duplicated tool to its first occurrence;
    # the task matches that. The off-pin duplicate below must be ignored,
    # so the run still matches.
    test "the first occurrence of a tool wins" do
      pin =
        "elixir #{running_elixir()}\nerlang #{running_otp()}.7.13\n" <>
          "elixir #{off_pin(running_elixir())}\nerlang #{off_pin(running_otp())}.0.0\n"

      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr == ""
      assert stdout =~ "letflow.check_toolchain: OK"
    end

    # Spec T-P4. asdf allows fallback versions after the first token; the
    # task reads the first and ignores the rest.
    test "tokens after the version are ignored" do
      pin =
        "elixir #{running_elixir()} #{off_pin(running_elixir())}\n" <>
          "erlang #{running_otp()}.7.13 #{off_pin(running_otp())}.0.0\n"

      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr == ""
      assert stdout =~ "letflow.check_toolchain: OK"
    end

    # Spec T-P5. CRLF line endings must not leave a stray \r glued to the
    # version token, which would turn every pin on a Windows checkout into
    # a permanent false mismatch.
    test "CRLF line endings do not corrupt the version" do
      pin = "elixir #{running_elixir()}\r\nerlang #{running_otp()}.7.13\r\n"
      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr == ""
      assert stdout =~ "letflow.check_toolchain: OK"
    end
  end

  describe "failure modes" do
    # Spec T-F1. Pin file missing. Block title is TOOLCHAIN PIN NOT
    # CHECKED (no comparison was possible), the running versions are still
    # reported, and run/1 returns :ok without raising.
    test "F1 missing pin file warns and returns ok" do
      dir = fresh_dir()
      {result, stdout, stderr} = run_in(dir)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN PIN NOT CHECKED"
      assert stderr =~ "#{@pin_file} not found at"
      assert stderr =~ "  Running: Elixir #{running_elixir()} / OTP #{running_otp()}"
      refute stdout =~ "TOOLCHAIN"
    end

    # Spec T-F2a. Zero-byte pin file.
    test "F2 an empty pin file warns and returns ok" do
      {result, _stdout, stderr} = run_with_pin("")

      assert result == :ok
      assert stderr =~ "TOOLCHAIN PIN NOT CHECKED"
      assert stderr =~ "#{@pin_file} contains no elixir pin and no erlang pin."
      assert stderr =~ "  Running: Elixir #{running_elixir()} / OTP #{running_otp()}"
    end

    # Spec T-F2b. Present, non-empty, but nothing pinnable in it.
    test "F2 blanks and comments only warn and return ok" do
      {result, _stdout, stderr} = run_with_pin("# nothing here\n\n\n   \n# still nothing\n")

      assert result == :ok
      assert stderr =~ "TOOLCHAIN PIN NOT CHECKED"
      assert stderr =~ "contains no elixir pin and no erlang pin."
    end

    # Spec T-F3. No elixir line. The Elixir row reads NOT PINNED and the
    # block is emitted even though the OTP comparison matched -- an
    # unpinned tool is itself the thing worth reporting.
    test "F3 no elixir line reports NOT PINNED and returns ok" do
      {result, _stdout, stderr} = run_with_pin("erlang #{running_otp()}.7.13\n")

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"

      assert stderr =~
               "  Elixir  expected (no elixir pin in #{@pin_file})   " <>
                 "running #{running_elixir()}   <-- NOT PINNED"

      assert stderr =~ otp_row(running_otp(), "#{running_otp()}.7.13", running_otp(), "matches")
    end

    # Spec T-F4. Symmetric to F3.
    test "F4 no erlang line reports NOT PINNED and returns ok" do
      {result, _stdout, stderr} = run_with_pin("elixir #{running_elixir()}\n")

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"

      assert stderr =~
               "  OTP     expected (no erlang pin in #{@pin_file})   " <>
                 "running #{running_otp()}   <-- NOT PINNED"

      assert stderr =~ elixir_row(running_elixir(), running_elixir(), "matches")
    end

    # Spec T-F5a. A recognised tool name with no version token: treated as
    # unpinned AND the raw line is quoted verbatim.
    test "F5 an elixir line with no version is quoted" do
      {result, _stdout, stderr} = run_with_pin("elixir\nerlang #{running_otp()}.7.13\n")

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"
      assert stderr =~ "<-- NOT PINNED"
      assert stderr =~ "  Malformed line in #{@pin_file}, ignored: elixir"
    end

    # Spec T-F5b. Same for erlang, and the raw line is quoted with its
    # original leading whitespace intact.
    test "F5 an erlang line with no version is quoted" do
      {result, _stdout, stderr} = run_with_pin("elixir #{running_elixir()}\n  erlang\n")

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"
      assert stderr =~ "  Malformed line in #{@pin_file}, ignored:   erlang"
    end

    # Spec T-F5c. Both recognised lines malformed: no comparison is
    # possible at all, so the title falls back to NOT CHECKED and both raw
    # lines are quoted.
    test "F5 both lines malformed falls back to NOT CHECKED" do
      {result, _stdout, stderr} = run_with_pin("elixir\nerlang\n")

      assert result == :ok
      assert stderr =~ "TOOLCHAIN PIN NOT CHECKED"
      assert stderr =~ "  Malformed line in #{@pin_file}, ignored: elixir"
      assert stderr =~ "  Malformed line in #{@pin_file}, ignored: erlang"
    end

    # Spec T-F6. Unreadable for a reason other than :enoent. A directory
    # named `.tool-versions` makes File.read/1 return {:error, :eisdir} on
    # both POSIX and Windows (measured on this host before the test was
    # written), which is a real unreadable-file path rather than a
    # simulated one.
    test "F6 an unreadable pin file warns and returns ok" do
      dir = fresh_dir()
      File.mkdir_p!(Path.join(dir, @pin_file))
      {result, _stdout, stderr} = run_in(dir)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN PIN NOT CHECKED"
      assert stderr =~ "Could not read #{@pin_file} (:eisdir)"
      assert stderr =~ "  Running: Elixir #{running_elixir()} / OTP #{running_otp()}"
    end

    # Spec T-F7. The one failure mode with no portable external trigger:
    # File.cwd/0 fails when the working directory ceases to exist, which a
    # process can arrange on POSIX by deleting its own cwd but which
    # Windows refuses (measured: File.rm_rf on the cwd returns
    # {:error, :eacces}). So the test performs the real induction and
    # asserts the F7 block wherever the OS permits it; where it does not,
    # it asserts the structural guarantee the branch rests on -- that the
    # cwd is obtained with the non-raising File.cwd/0, never File.cwd!/0,
    # and that the F7 branch exists. Either way it asserts something that
    # a regression would break. See the TEST-DESIGNER finding in
    # test/specs/ISS-0106.md.
    test "F7 an unavailable working directory warns and returns ok" do
      dir = fresh_dir()
      File.write!(Path.join(dir, @pin_file), matching_pin())
      outer = File.cwd!()

      induction =
        try do
          File.cd!(dir)
          File.rm_rf(dir)

          case File.cwd() do
            {:error, _reason} -> {:induced, capture_both(fn -> CheckToolchain.run([]) end)}
            {:ok, _cwd} -> :not_induced
          end
        after
          File.cd!(outer)
        end

      case induction do
        {:induced, {result, _stdout, stderr}} ->
          assert result == :ok
          assert stderr =~ "TOOLCHAIN PIN NOT CHECKED"
          assert stderr =~ "Could not determine the project directory"

        :not_induced ->
          code = module_code()
          assert code =~ "File.cwd()"
          refute code =~ "File.cwd!"
          assert code =~ "Could not determine the project directory"
      end
    end

    # Spec T-F8. The outer guard on run/1. Induced without touching the
    # module and without stubbing anything in it: the MATCH path is the
    # only path that writes to stdout, and IO.puts/1 raises ArgumentError
    # when the group leader answers the Erlang IO protocol with an error
    # reply. So a matching fixture plus a group leader that refuses every
    # request makes check/0 raise for real, from inside, on a line that
    # ships in the module. The guard must catch it, report F8 on :stderr
    # (a device registered by name, so unaffected by the group leader),
    # and still return :ok. Run in a spawned process so the test process
    # keeps its own working group leader.
    test "F8 an internal error is caught and reported" do
      dir = fresh_dir()
      File.write!(Path.join(dir, @pin_file), matching_pin())
      parent = self()
      device = refusing_io_device()

      stderr =
        capture_io(:stderr, fn ->
          spawn(fn ->
            Process.group_leader(self(), device)
            send(parent, {:f8, File.cd!(dir, fn -> CheckToolchain.run([]) end)})
          end)

          assert_receive {:f8, :ok}, 5_000
        end)

      assert stderr =~ "TOOLCHAIN PIN NOT CHECKED"
      assert stderr =~ "Internal error in letflow.check_toolchain"
      assert stderr =~ "This never fails the build."
    end
  end

  describe "invariants" do
    # Spec T-I1. Warnings go to stderr, never to stdout. This is what lets
    # the warning survive a caller that pipes stdout into grep or tee,
    # which is how the gate output is read here.
    test "warning output goes to stderr not stdout" do
      pin = "elixir #{off_pin(running_elixir())}\nerlang #{off_pin(running_otp())}.0.0\n"
      {result, stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"
      assert stdout == ""
    end

    # Spec T-I2. run/1 accepts an argument list and ignores it entirely --
    # there is no option parsing and therefore no suppression switch. A
    # switch that LOOKS like one must change nothing.
    test "arguments are accepted and ignored" do
      pin = "elixir #{off_pin(running_elixir())}\nerlang #{running_otp()}.7.13\n"
      {plain, _out_a, stderr_plain} = run_with_pin(pin)
      {switched, _out_b, stderr_switched} = run_with_pin(pin, ["--quiet", "--no-warn", "junk"])

      assert plain == :ok
      assert switched == :ok
      assert stderr_switched =~ "TOOLCHAIN OFF PIN"
      assert stderr_plain =~ "TOOLCHAIN OFF PIN"
    end

    # Spec T-I3. The warning bypasses Mix's replaceable shell on purpose,
    # so swapping in the quiet shell -- the global switch that silences
    # ordinary Mix output -- must not silence it.
    test "a quiet Mix shell does not suppress the warning" do
      original_shell = Mix.shell()
      on_exit(fn -> Mix.shell(original_shell) end)
      Mix.shell(Mix.Shell.Quiet)

      pin = "elixir #{off_pin(running_elixir())}\nerlang #{running_otp()}.7.13\n"
      {result, _stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"
    end

    # Spec T-I4. The task reads no environment variable, so MIX_QUIET --
    # the other global way to quieten Mix -- has no effect either.
    test "MIX_QUIET does not suppress the warning" do
      previous = System.get_env("MIX_QUIET")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("MIX_QUIET")
          value -> System.put_env("MIX_QUIET", value)
        end
      end)

      System.put_env("MIX_QUIET", "1")

      pin = "elixir #{off_pin(running_elixir())}\nerlang #{running_otp()}.7.13\n"
      {result, _stdout, stderr} = run_with_pin(pin)

      assert result == :ok
      assert stderr =~ "TOOLCHAIN OFF PIN"
    end

    # Spec T-I5. The design states that the absence of any build-aborting
    # construct is checkable by grep over this file, and that the presence
    # of one would be a defect regardless of the surrounding logic. This
    # is that grep, run over the code with the doc blocks stripped out
    # (the moduledoc names several of these APIs in prose precisely to say
    # it does not call them). It guards the "never fails the build"
    # property against a future edit that no behavioural test would catch
    # on a path it did not think to exercise.
    test "the module contains no build-aborting construct" do
      code = module_code()

      refute code =~ ~r/\braise\b/
      refute code =~ ~r/\bthrow\b/
      refute code =~ "System.halt"
      refute code =~ "System.stop"
      refute code =~ "File.read!"
      refute code =~ "File.cwd!"
      refute code =~ "Mix.raise"
      assert code =~ "File.cwd()"
      assert code =~ "File.read(path)"
    end

    # Spec T-I6. The task must never abort, so no fixture in this file may
    # make it return anything but :ok. Re-asserted here as a single
    # explicit sweep over the whole fixture range rather than left as a
    # by-product of the individual cases.
    test "run/1 returns ok for every fixture shape" do
      fixtures = [
        matching_pin(),
        "",
        "# only a comment\n",
        "erlang #{running_otp()}.7.13\n",
        "elixir #{running_elixir()}\n",
        "elixir\nerlang\n",
        "elixir #{off_pin(running_elixir())}\nerlang #{off_pin(running_otp())}.0.0\n",
        "garbage\n\t\t\n!!!\n",
        "elixir 0\nerlang 0\n"
      ]

      for fixture <- fixtures do
        {result, _stdout, _stderr} = run_with_pin(fixture)
        assert result == :ok, "run/1 did not return :ok for fixture #{inspect(fixture)}"
      end
    end
  end
end
