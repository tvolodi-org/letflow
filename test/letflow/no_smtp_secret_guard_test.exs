defmodule Letflow.NoSmtpSecretGuardTest do
  @moduledoc """
  REQ-441 AC6 (spec `test/specs/REQ-441.md`; SECURITY-REVIEWER step 02c finding 10):
  NO SECRET IN THE REPOSITORY.

  A content scan over the TRACKED tree (`git ls-files`) finds no value assigned to
  the SMTP username or password variable: not as a `NAME=value` environment assignment,
  not as a quoted `NAME: "value"` / `"NAME": "value"` mapping entry, and not as a literal
  value in a `put_env("NAME", "value")` call. Names, blank assignments (`NAME=`) and
  assignments whose value is a variable are fine -- that is exactly how `.env.example`,
  the docs and the tests refer to them.

  The scan is not vacuous: the patterns are first proven against known-bad and
  known-good samples, and the variable names ARE found in tracked files. The patterns
  are built from pieces so this file does not trip its own scan. The two `.env.example`
  files must carry every REQ-441 variable as a bare `NAME=` line with nothing after it.

  Tests need no `NAME=value` text: they use `System.put_env/2` with names held in module
  attributes and values built at compile time (`Letflow.Test.SmtpHelpers`).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  # Built from pieces, at run time (a compiled regex does not belong in a module
  # attribute on current OTP), so the literal assignment text never appears in this file.
  defp patterns do
    names = "LETFLOW_SMTP_" <> "(?:PASS" <> "WORD|USER" <> "NAME)"

    [
      env_assignment:
        Regex.compile!(names <> ~S{=(?:"[^"\s]+"|'[^'\s]+'|[A-Za-z0-9_/+$@%!~^&?-][^\s`]*)}),
      mapping_entry: Regex.compile!(names <> ~S{["']?\s*:\s*["'][^"'\s]+["']}),
      put_env_literal: Regex.compile!(~S{["']} <> names <> ~S{["']\s*,\s*["'][^"']+["']})
    ]
  end

  defp flagged?(line), do: Enum.any?(patterns(), fn {_kind, re} -> Regex.match?(re, line) end)

  @max_bytes 4_000_000

  @mail_variables ~w(LETFLOW_MAIL_ADAPTER LETFLOW_SMTP_HOST LETFLOW_SMTP_PORT
                     LETFLOW_SMTP_USERNAME LETFLOW_SMTP_PASSWORD LETFLOW_SMTP_TLS
                     LETFLOW_MAIL_FROM LETFLOW_PUBLIC_BASE_URL LETFLOW_MAIL_TIMEOUT_MS)

  @needle "LETFLOW_SMTP_"

  defp tracked_files(root) do
    {out, 0} = System.cmd("git", ["ls-files", "-z"], cd: root)
    out |> String.split(<<0>>, trim: true)
  end

  # One `git grep` narrows ~7k tracked files to the few that mention the variable
  # prefix at all (no `-I`: binary files are decided by the String.valid? check below,
  # exactly as before). `-z` keeps paths unquoted; stderr is not merged into the paths.
  defp candidate_files(root) do
    case System.cmd("git", ["grep", "-l", "-z", "-F", "-e", @needle], cd: root) do
      {_out, 1} -> []
      {out, 0} -> String.split(out, <<0>>, trim: true)
      {out, code} -> raise "git grep exited #{code}: #{out}"
    end
  end

  @doc false
  # Scans the tracked tree under `root` for a value assigned to an SMTP credential
  # variable. Returns `%{hits: [...], scanned_paths: [...]}`; `hits` are
  # "path:number (kind)" strings in sorted-path then line order.
  def scan_tracked(root) do
    scanned =
      for path <- Enum.sort(candidate_files(root)),
          full = Path.join(root, path),
          File.regular?(full),
          %File.Stat{size: size} = File.stat!(full),
          size <= @max_bytes,
          content = File.read!(full),
          String.valid?(content),
          :binary.match(content, @needle) != :nomatch,
          do: {path, content}

    # every pattern needs the literal prefix, so a line without it cannot match
    hits =
      for {path, content} <- scanned,
          {line, number} <- content |> String.split("\n") |> Enum.with_index(1),
          String.contains?(line, @needle),
          {kind, re} <- patterns(),
          Regex.match?(re, line),
          do: "#{path}:#{number} (#{kind})"

    %{hits: hits, scanned_paths: Enum.map(scanned, &elem(&1, 0))}
  end

  describe "the scan patterns" do
    # samples are assembled from pieces for the same reason as the patterns
    @user "LETFLOW_SMTP_" <> "USERNAME"
    @pass "LETFLOW_SMTP_" <> "PASSWORD"

    test "catch every shape of an assigned value" do
      for sample <- [
            @pass <> "=hunter2",
            @user <> "=alice@example.org",
            "export " <> @pass <> "=hunter2",
            "  - " <> @pass <> "=hunter2",
            @pass <> ~S|="hunter2"|,
            @pass <> "='hunter2'",
            @pass <> ~S|: "hunter2"|,
            ~s|"#{@pass}": "hunter2"|,
            ~s|System.put_env("#{@pass}", "hunter2")|,
            @pass <> "=changeme"
          ] do
        assert flagged?(sample), "pattern set missed: #{sample}"
      end
    end

    test "do not flag names, blank assignments or variable references" do
      for sample <- [
            @pass <> "=",
            @user <> "=   ",
            "`" <> @pass <> "=` and `" <> @user <> "=` with nothing after",
            @pass <> "= and the next word",
            ~s|@pass_var "#{@pass}"|,
            ~s|System.put_env("#{@pass}", value)|,
            ~s|System.put_env(@pass_var, @pass)|,
            @pass <> ~S|=""|,
            "LETFLOW_MAIL_FROM=noreply@example.org",
            "the " <> @pass <> " variable is read at the point of use"
          ] do
        refute flagged?(sample), "pattern set flagged a non-assignment: #{sample}"
      end
    end
  end

  describe "AC6: the tracked tree" do
    @tag timeout: 300_000
    test "no tracked file assigns a value to the SMTP username or password variable" do
      root = File.cwd!()
      files = tracked_files(root)
      assert length(files) > 1_000, "git ls-files returned #{length(files)} files"

      %{hits: hits, scanned_paths: scanned_paths} = scan_tracked(root)

      assert hits == [],
             "a value is assigned to an SMTP credential variable:\n" <> Enum.join(hits, "\n")

      # not vacuous: the variable NAMES are present in tracked files (the example env files)
      assert ".env.example" in scanned_paths
      assert "deploy/.env.example" in scanned_paths
      assert "config/runtime.exs" in scanned_paths
    end

    test ".env.example and deploy/.env.example name every REQ-441 variable with NO value" do
      for path <- [".env.example", "deploy/.env.example"] do
        lines = path |> File.read!() |> String.split(~r/\r?\n/)

        for name <- @mail_variables do
          assignments = Enum.filter(lines, &String.starts_with?(&1, name <> "="))

          assert assignments == [name <> "="],
                 "#{path}: expected exactly the bare line #{name}= , got #{inspect(assignments)}"
        end
      end
    end

    test "the two credential lines are exactly 'NAME=' (quoted)" do
      for path <- [".env.example", "deploy/.env.example"] do
        lines = path |> File.read!() |> String.split(~r/\r?\n/)
        assert (@user <> "=") in lines
        assert (@pass <> "=") in lines
      end
    end

    test "config/runtime.exs and the adapter never default a credential" do
      for path <- ["config/runtime.exs", "lib/letflow/login_discovery/notifier/smtp.ex"] do
        src = File.read!(path)

        # no `System.get_env(name, default)` and no `|| "literal"` fallback on the credentials
        refute src =~ ~r/System\.get_env\(\s*"#{@user}"\s*,/
        refute src =~ ~r/System\.get_env\(\s*"#{@pass}"\s*,/
        refute src =~ ~r/System\.get_env\(\s*"#{@pass}"\s*\)\s*\|\|/
        refute src =~ ~r/System\.get_env\(\s*"#{@user}"\s*\)\s*\|\|/
      end
    end
  end

  # The ORIGINAL scan (before the git-grep prefilter), kept here test-only as the oracle
  # that `scan_tracked/1` must equal on every fixture below.
  defp old_scan(root) do
    {out, 0} = System.cmd("git", ["ls-files", "-z"], cd: root)

    scanned =
      for path <- out |> String.split(<<0>>, trim: true) |> Enum.sort(),
          full = Path.join(root, path),
          File.regular?(full),
          %File.Stat{size: size} = File.stat!(full),
          size <= @max_bytes,
          content = File.read!(full),
          String.valid?(content),
          :binary.match(content, @needle) != :nomatch,
          do: {path, content}

    hits =
      for {path, content} <- scanned,
          {line, number} <- content |> String.split("\n") |> Enum.with_index(1),
          {kind, re} <- patterns(),
          Regex.match?(re, line),
          do: "#{path}:#{number} (#{kind})"

    %{hits: hits, scanned_paths: Enum.map(scanned, &elem(&1, 0))}
  end

  defp git!(dir, args) do
    {out, code} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    if code != 0, do: raise("git #{Enum.join(args, " ")} exited #{code}: #{out}")
    out
  end

  # Builds a throwaway repo; `tracked` files are `git add`ed, `untracked` are only written.
  defp make_repo(tracked, untracked \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "smtp_guard_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "guard@example.org"])
    git!(dir, ["config", "user.name", "guard"])
    git!(dir, ["config", "core.autocrlf", "false"])
    for {name, data} <- tracked ++ untracked, do: File.write!(Path.join(dir, name), data)
    git!(dir, ["add", "--"] ++ Enum.map(tracked, &elem(&1, 0)))
    dir
  end

  describe "scan_tracked/1 against a fixture repo" do
    @tag timeout: 300_000
    test "equals the old scan and yields exactly the expected hits and scanned set" do
      user = "LETFLOW_SMTP_" <> "USERNAME"
      pass = "LETFLOW_SMTP_" <> "PASSWORD"
      filler = :binary.copy("a", 69) <> "\n"

      root =
        make_repo(
          [
            {"small.env", pass <> "=hunter2\n"},
            {"shapes.txt",
             pass <> ~S|: "hunter2"| <> "\n" <> ~s|System.put_env("#{pass}", "hunter2")\n|},
            {"large.txt",
             :binary.copy(filler, 39_990) <> pass <> "=hunter2\n" <> :binary.copy(filler, 9)},
            {"longline.txt",
             "clean line\n" <> String.duplicate("x ", 6_500) <> user <> "=alice\nclean again\n"},
            {"nulbytes.bin", <<0, 0>> <> "\n" <> pass <> "=hunter2\n"},
            {"toobig.txt", pass <> "=hunter2\n" <> :binary.copy("z", 4_000_001)},
            {"bad.bin", <<0xFF, 0xFE>> <> "\n" <> pass <> "=hunter2\n"},
            {"clean.txt", pass <> "=\n" <> ~s|System.put_env("#{pass}", value)\n|}
          ],
          [{"untracked.env", pass <> "=hunter2\n"}]
        )

      new = scan_tracked(root)
      old = old_scan(root)

      assert new.hits == old.hits
      assert new.scanned_paths == old.scanned_paths

      # non-vacuous: the old scan itself finds the planted violations
      assert old.hits != []
      assert new.hits != []

      assert new.hits == [
               "large.txt:39991 (env_assignment)",
               "longline.txt:2 (env_assignment)",
               "nulbytes.bin:2 (env_assignment)",
               "shapes.txt:1 (mapping_entry)",
               "shapes.txt:2 (put_env_literal)",
               "small.env:1 (env_assignment)"
             ]

      # scanned: tracked, regular, <= @max_bytes, valid UTF-8, mentions the prefix
      assert new.scanned_paths ==
               [
                 "clean.txt",
                 "large.txt",
                 "longline.txt",
                 "nulbytes.bin",
                 "shapes.txt",
                 "small.env"
               ]

      refute "toobig.txt" in new.scanned_paths
      refute "bad.bin" in new.scanned_paths
      refute "untracked.env" in new.scanned_paths
      assert File.stat!(Path.join(root, "large.txt")).size > 2_500_000
      assert File.stat!(Path.join(root, "toobig.txt")).size > @max_bytes
    end

    test "a repo whose only mentions are blank or variable forms has no hits" do
      root = make_repo([{"clean.txt", "LETFLOW_SMTP_" <> "PASSWORD" <> "=\n"}])
      new = scan_tracked(root)
      assert new == old_scan(root)
      assert new.hits == []
      assert new.scanned_paths == ["clean.txt"]
    end

    test "a repo where no file mentions the prefix (git grep exit 1) scans nothing" do
      root = make_repo([{"other.txt", "nothing to see here\n"}])
      new = scan_tracked(root)
      assert new == old_scan(root)
      assert new.hits == []
      assert new.scanned_paths == []
    end
  end
end
