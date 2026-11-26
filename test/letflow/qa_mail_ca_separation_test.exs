defmodule Letflow.QaMailCaSeparationTest do
  @moduledoc """
  The QA mail trap's CA reaches the QA image through a build-arg gate, and through
  nothing else.

  Specification: ai-dala-infra run `2026-11-22-qa-mail-adapter-001`, step
  `step-04c-tracked-change.md` ("Exact diffs", items 1-4). The tracked change is the
  product's half of that step; infra owns the host half (the trap, the CA file on the
  QA host, the window).

  The shape is the one already used for the QA-only demo module: a build argument that
  defaults to false, a single gated build step, and exactly one script that passes
  true. The difference here is that the gated step installs a certificate into the
  image's trust store, so the gate has to hold for a stronger reason than "a demo
  module is absent": a build without the argument must contain no copy of the CA and
  no entry for it in the trust store.

  T1-T5 are static reads of the tracked files (no docker, no database).
  T6 builds the image and reads the trust store inside it; it is tagged `:docker` and
  skips itself where docker, buildx or openssl are absent.

  The certificate itself never enters the repository: `deploy/qa-mail-ca/` is ignored
  except for its `.gitkeep` placeholder, and the CA private key never enters a build
  context at all (T5).
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @var "LETFLOW_QA_MAIL_CA"
  @dockerfile "deploy/Dockerfile"
  @qa_script "deploy/redeploy-qa.sh"
  @ca_dir "deploy/qa-mail-ca"
  @ca_subject "Letflow QA local mail CA"

  describe "T1: the build argument" do
    test "T1: declared exactly once, in the runtime stage, after the apt layer and before the release copy" do
      instructions = instructions(dockerfile_lines())

      args =
        Enum.filter(instructions, fn {_i, text} -> String.starts_with?(text, "ARG #{@var}") end)

      assert [{arg_index, arg_text}] = args
      assert arg_text == "ARG #{@var}=false"

      # the runtime stage: the last FROM in the file
      froms = for {i, text} <- instructions, String.match?(text, ~r/^FROM\s/), do: i
      assert froms != []
      assert arg_index > List.last(froms)

      apt = Enum.find(instructions, fn {_i, text} -> String.contains?(text, "apt-get") end)
      user = Enum.find(instructions, fn {_i, text} -> text == "USER letflow" end)

      copy =
        Enum.find(instructions, fn {_i, text} ->
          String.starts_with?(text, "COPY --from=builder")
        end)

      assert apt, "no apt-get instruction in the runtime stage"
      assert user, "no `USER letflow` in the runtime stage"
      assert copy, "no `COPY --from=builder` in the runtime stage"

      {apt_index, _} = apt
      {user_index, _} = user
      {copy_index, _} = copy

      # after the apt layer (the cached layers survive a new commit), before the
      # release copy (so the app layers stay cached) and before the image drops root
      assert apt_index < arg_index
      assert arg_index < copy_index
      assert arg_index < user_index
    end
  end

  describe "T2: the trust store is touched only inside the one gated instruction" do
    test "T2: `update-ca-certificates` and the CA file name appear only inside the guarded RUN" do
      lines = dockerfile_lines()
      {start, finish} = gated_run_range(lines)

      gated = Enum.join(Enum.slice(lines, start..finish), "\n")

      assert gated =~ ~S|if [ "$LETFLOW_QA_MAIL_CA" = "true" ]; then|
      assert gated =~ "update-ca-certificates"
      assert gated =~ "letflow-qa-mail-ca"

      outside =
        lines
        |> Enum.with_index()
        |> Enum.reject(fn {_line, i} -> i >= start and i <= finish end)
        |> Enum.map(&elem(&1, 0))

      for line <- outside do
        refute line =~ "update-ca-certificates",
               "the trust store is written outside the gated RUN: #{line}"

        refute line =~ "letflow-qa-mail-ca",
               "the CA file is named outside the gated RUN: #{line}"
      end
    end
  end

  describe "T3: no image layer ever carries the certificate" do
    test "T3: only the scratch stage's own COPY names the CA directory, and it is never COPYed into an image" do
      instructions = instructions(dockerfile_lines())
      staged = with_stages(instructions)

      copies =
        Enum.filter(staged, fn {_i, text, _stage} ->
          String.starts_with?(text, "COPY ") or String.starts_with?(text, "ADD ")
        end)

      assert copies != []

      for {_i, text, stage} <- copies do
        if text == "COPY #{@ca_dir}/ /" do
          # the one allowed case: the scratch stage's own COPY, whose content is
          # bind-mounted into a single RUN and never lands in an image layer
          assert stage == "qa-mail-ca"
        else
          refute text =~ "qa-mail-ca", "a COPY names the CA directory: #{text}"
          refute text =~ ~r/\.(crt|pem)\b/, "a COPY names a certificate: #{text}"
        end
      end

      refute Enum.any?(instructions, fn {_i, text} -> text =~ "COPY --from=qa-mail-ca" end),
             "the CA stage is COPYed into an image"

      assert Enum.any?(instructions, fn {_i, text} ->
               text =~ "--mount=type=bind,from=qa-mail-ca"
             end),
             "the CA stage is not bind-mounted into the gated RUN"
    end
  end

  describe "T4: only the QA deploy script passes the argument" do
    test "T4: redeploy-qa.sh passes it true; no other deploy script, workflow or compose file names it" do
      assert File.read!(path(@qa_script)) =~ "--build-arg #{@var}=true"

      others =
        (Path.wildcard("deploy/**/*", match_dot: true) ++ Path.wildcard(".github/workflows/*"))
        |> Enum.map(&path/1)
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&(&1 in [path(@dockerfile), path(@qa_script)]))
        |> Enum.filter(&(File.read!(&1) =~ @var))

      assert others == [],
             "only deploy/redeploy-qa.sh may name #{@var}, but these files do: #{inspect(others)}"
    end
  end

  describe "T5: no certificate, key or PEM is committed" do
    test "T5: the CA directory holds only its tracked placeholder, and the ignore rules keep it that way" do
      effective = git_ls_files(["--cached", "--others", "--exclude-standard", "--", @ca_dir])

      assert effective == ["#{@ca_dir}/.gitkeep"],
             "the CA directory would commit something else: #{inspect(effective)}"

      tracked = git_ls_files(["--cached", "--", @ca_dir])

      assert Enum.all?(tracked, &String.ends_with?(&1, ".gitkeep")),
             "a tracked file sits in the CA directory: #{inspect(tracked)}"

      for scope <- [@ca_dir, "deploy"] do
        files = git_ls_files(["--cached", "--others", "--exclude-standard", "--", scope])

        refute Enum.any?(files, &Regex.match?(~r/\.(crt|pem|key)$/i, &1)),
               "a certificate, key or PEM would be committed under #{scope}: #{inspect(files)}"
      end

      gitignore = File.read!(path(".gitignore"))

      assert gitignore =~ "#{@ca_dir}/*"
      assert gitignore =~ "!#{@ca_dir}/.gitkeep"
    end
  end

  describe "T6: the gate, proven on a built image" do
    @tag :docker
    @tag timeout: 600_000
    test "T6: no argument means no CA and no trust-store entry; the argument means both; the argument without the file fails the build" do
      unless docker_ready?() do
        IO.puts("qa_mail_ca_separation: T6 skipped (docker, buildx or openssl is absent here)")
        :ok
      else
        case pull_base_image() do
          :ok ->
            run_image_gate_check()

          {:skip, reason} ->
            IO.puts("qa_mail_ca_separation: T6 skipped (#{reason})")
            :ok
        end
      end
    end
  end

  # ── T6 helpers ─────────────────────────────────────────────────────────────

  defp run_image_gate_check do
    tmp = Path.join(System.tmp_dir!(), "letflow-qa-mail-ca-#{System.unique_integer([:positive])}")
    context = Path.join(tmp, "context")
    empty_context = Path.join(tmp, "context-without-certificate")
    keys = Path.join(tmp, "keys")

    for dir <- [context, empty_context] do
      File.mkdir_p!(Path.join(dir, @ca_dir))
      # the placeholder the tracked directory carries: the COPY of the CA stage must
      # never fail because the directory is empty
      File.write!(Path.join(dir, "#{@ca_dir}/.gitkeep"), "")
      File.write!(Path.join(dir, "Dockerfile"), ca_gate_dockerfile())
    end

    File.mkdir_p!(keys)
    on_exit(fn -> File.rm_rf(tmp) end)

    suffix = System.unique_integer([:positive])
    tag_noarg = "letflow-qa-mail-ca-test:noarg-#{suffix}"
    tag_arg = "letflow-qa-mail-ca-test:arg-#{suffix}"
    tag_missing = "letflow-qa-mail-ca-test:missing-#{suffix}"

    on_exit(fn ->
      for tag <- [tag_noarg, tag_arg, tag_missing],
          do: System.cmd("docker", ["rmi", "-f", tag], stderr_to_stdout: true)
    end)

    # A throwaway CA with the subject the QA host's CA carries. Its PRIVATE KEY is
    # written outside the build context: only the public certificate may ever be
    # inside one.
    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          Path.join(keys, "ca.key"),
          "-out",
          Path.join(context, "#{@ca_dir}/letflow-qa-mail-ca.crt"),
          "-days",
          "1",
          "-subj",
          "/CN=#{@ca_subject}"
        ],
        stderr_to_stdout: true
      )

    # 1. the production-like build: no argument, so no CA and no trust-store entry
    {out, code} = build_image(context, tag_noarg, [])
    assert code == 0, "the build without #{@var} failed:\n#{out}"

    {out, code} = image_paths_absent(tag_noarg)
    assert code == 0, "the image built without #{@var} carries the CA:\n#{out}"

    {subjects, code} = bundle_subjects(tag_noarg)
    assert code == 0, subjects
    refute subjects =~ @ca_subject, "the image built without #{@var} trusts the QA CA"

    # 2. the QA build: the argument is true, so the CA is trusted
    {out, code} = build_image(context, tag_arg, ["--build-arg", "#{@var}=true"])
    assert code == 0, "the build with #{@var}=true failed:\n#{out}"

    {out, code} = image_paths_present(tag_arg)
    assert code == 0, "the image built with #{@var}=true does not carry the CA:\n#{out}"

    {subjects, code} = bundle_subjects(tag_arg)
    assert code == 0, subjects
    assert subjects =~ @ca_subject, "the image built with #{@var}=true does not trust the QA CA"

    # 3. the argument is true but the certificate is not there: the build FAILS
    {out, code} = build_image(empty_context, tag_missing, ["--build-arg", "#{@var}=true"])
    assert code != 0, "the build silently skipped a missing certificate:\n#{out}"
  end

  # The image under test is the REAL Dockerfile with the builder stage dropped and
  # everything after the gated RUN cut away: the CA stage, the runtime base, the
  # apt layer that installs ca-certificates and the gated RUN itself, verbatim. The
  # Elixir release is not built -- it needs the network and minutes of compile time,
  # and it says nothing about the trust store -- so the check stays fast and only
  # ever exercises the real instruction text.
  defp ca_gate_dockerfile do
    lines = dockerfile_lines()

    ca_from = Enum.find_index(lines, &String.starts_with?(&1, "FROM scratch AS qa-mail-ca"))

    run_start =
      Enum.find_index(lines, &String.starts_with?(&1, "RUN --mount=type=bind,from=qa-mail-ca"))

    assert is_integer(ca_from), "no `FROM scratch AS qa-mail-ca` stage in #{@dockerfile}"
    assert is_integer(run_start), "no gated CA RUN in #{@dockerfile}"

    lines
    |> Enum.slice(ca_from..instruction_end(lines, run_start))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp build_image(context, tag, args) do
    System.cmd(
      "docker",
      ["build", "-f", "Dockerfile", "--tag", tag] ++ args ++ ["."],
      cd: context,
      stderr_to_stdout: true
    )
  end

  defp image_paths_absent(tag) do
    System.cmd(
      "docker",
      [
        "run",
        "--rm",
        "--entrypoint",
        "sh",
        tag,
        "-c",
        "test ! -e /usr/local/share/ca-certificates/letflow-qa-mail-ca.crt && test ! -e /etc/ssl/certs/letflow-qa-mail-ca.pem"
      ],
      stderr_to_stdout: true
    )
  end

  defp image_paths_present(tag) do
    System.cmd(
      "docker",
      [
        "run",
        "--rm",
        "--entrypoint",
        "sh",
        tag,
        "-c",
        "test -f /usr/local/share/ca-certificates/letflow-qa-mail-ca.crt && test -f /etc/ssl/certs/letflow-qa-mail-ca.pem"
      ],
      stderr_to_stdout: true
    )
  end

  # The subject of every certificate in the image's trust-store bundle, one line
  # each (the bundle is split into single certificates first).
  defp bundle_subjects(tag) do
    script =
      "awk 'BEGIN {n=0} /-----BEGIN CERTIFICATE-----/ {n++} {print > (\"/tmp/letflow-cert-\" n \".pem\")}' /etc/ssl/certs/ca-certificates.crt; " <>
        "for f in /tmp/letflow-cert-*.pem; do openssl x509 -in \"$f\" -noout -subject 2>/dev/null || true; done"

    System.cmd(
      "docker",
      ["run", "--rm", "--entrypoint", "sh", tag, "-c", script],
      stderr_to_stdout: true
    )
  end

  defp docker_ready? do
    System.find_executable("docker") != nil and
      System.find_executable("openssl") != nil and
      match?({_, 0}, System.cmd("docker", ["info"], stderr_to_stdout: true)) and
      match?({_, 0}, System.cmd("docker", ["buildx", "version"], stderr_to_stdout: true))
  end

  # The base image is pulled before the builds: a registry that cannot serve it is an
  # environment fact, not a fault of the gate, and the check says so instead of
  # reporting a build failure.
  defp pull_base_image do
    case System.cmd("docker", ["pull", "--quiet", runtime_base()], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:skip, "the runtime base image could not be pulled: #{String.trim(out)}"}
    end
  end

  defp runtime_base do
    dockerfile_lines()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^FROM\s+(\S+)\s+AS\s+runtime\s*$/i, line) do
        [_, base] -> base
        _ -> nil
      end
    end)
  end

  # ── file helpers ───────────────────────────────────────────────────────────

  defp path(relative), do: Path.join(@root, relative)

  defp dockerfile_lines do
    path(@dockerfile) |> File.read!() |> String.split("\n")
  end

  defp git_ls_files(args) do
    {out, 0} = System.cmd("git", ["ls-files" | args], cd: @root, stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
  end

  # The Dockerfile as a list of {first line index, instruction text}: a line ending
  # in a backslash continues the instruction on the next line.
  defp instructions(lines) do
    do_instructions(Enum.with_index(lines), [], nil, nil)
  end

  defp do_instructions([], acc, nil, _start), do: Enum.reverse(acc)
  defp do_instructions([], acc, text, start), do: Enum.reverse([{start, text} | acc])

  defp do_instructions([{line, index} | rest], acc, text, start) do
    trimmed = String.trim_trailing(line)

    cond do
      trimmed == "" ->
        do_instructions(rest, acc, text, start)

      text == nil ->
        if String.ends_with?(trimmed, "\\") do
          do_instructions(rest, acc, String.trim_trailing(trimmed, "\\"), index)
        else
          do_instructions(rest, [{index, trimmed} | acc], nil, nil)
        end

      String.ends_with?(trimmed, "\\") ->
        do_instructions(rest, acc, text <> " " <> String.trim_trailing(trimmed, "\\"), start)

      true ->
        do_instructions(rest, [{start, text <> " " <> trimmed} | acc], nil, nil)
    end
  end

  # The line index of the last line of the instruction that starts at `start`.
  defp instruction_end(lines, start) do
    Enum.reduce_while((start + 1)..(length(lines) - 1), start, fn i, _acc ->
      if String.ends_with?(String.trim_trailing(Enum.at(lines, i)), "\\"),
        do: {:cont, i},
        else: {:halt, i}
    end)
  end

  # The line range of the single gated CA RUN.
  defp gated_run_range(lines) do
    start =
      Enum.find_index(lines, &String.starts_with?(&1, "RUN --mount=type=bind,from=qa-mail-ca"))

    assert is_integer(start), "no gated CA RUN in #{@dockerfile}"

    {start, instruction_end(lines, start)}
  end

  # Each instruction with the stage it belongs to (the stage name of the last FROM
  # before it).
  defp with_stages(instructions) do
    {staged, _stage} =
      Enum.reduce(instructions, {[], nil}, fn {index, text}, {acc, stage} ->
        stage =
          case Regex.run(~r/^FROM\s+(\S+)(?:\s+AS\s+(\S+))?/i, text) do
            [_, base, name] -> name || base
            _ -> stage
          end

        {[{index, text, stage} | acc], stage}
      end)

    Enum.reverse(staged)
  end
end
