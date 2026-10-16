defmodule Mix.Tasks.Letflow.LoginDirectoryTasksTest do
  @moduledoc """
  REQ-443 -- `mix letflow.login_directory.key_status` and
  `mix letflow.login_directory.retire_key`, end to end.

  Success paths run in-VM with `Mix.Shell.Process` and `capture_log` at `:debug`
  (inside the sandbox, so every deletion rolls back). The tasks call
  `System.halt(1)` on every refusal, which would terminate the test VM, so the
  non-zero-exit branches (missing `--key-id`, invalid options, invalid / current /
  absent id) run the real task in a child `mix` process in the `test` environment
  and assert the exit status and message. Those children only ever REFUSE, so
  they cannot delete a row in the shared test database. See `test/specs/REQ-443.md`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Identity.User
  alias Letflow.LoginDirectory
  alias Letflow.LoginDirectory.Backfill
  alias Letflow.Test.LoginDirectoryFixture, as: Fx
  alias Mix.Tasks.Letflow.LoginDirectory.KeyStatus
  alias Mix.Tasks.Letflow.LoginDirectory.RetireKey

  @id_a "rot443t-a"
  @id_b "rot443t-b"
  @email "task-rot-alice@example.test"

  defp run_task(task, argv) do
    original = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      log = capture_log([level: :debug], fn -> task.run(argv) end)
      {drain_shell([]), log}
    after
      Mix.shell(original)
    end
  end

  defp drain_shell(acc) do
    receive do
      {:mix_shell, level, [text]} -> drain_shell([{level, text} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp infos(lines), do: for({:info, text} <- lines, do: text)

  # Real child `mix` process; returns {output, exit_status}.
  defp mix_task(task, argv) do
    # GH #2630: this child starts the app and opens a Repo pool; cap it (Letflow.Test.NestedMix).
    Letflow.Test.NestedMix.cmd("mix", [task | argv],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true,
      cd: File.cwd!()
    )
  end

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    # Before any swap: the test environment's configured current key id.
    {:ok, original_current} = LoginDirectory.current_key_id()
    tenant = Fx.tenant!()

    %User{}
    |> Ecto.Changeset.change(%{
      username: "trot-#{System.unique_integer([:positive])}",
      display_name: "Task Rotation Person",
      email: @email,
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)

    Fx.swap_keys!({@id_a, Fx.pepper(1)}, nil)

    assert {:ok, {:ok, :inserted}} =
             Repo.transaction(fn -> LoginDirectory.upsert_entry(tenant.tenant_id, @email) end)

    Fx.swap_keys!({@id_b, Fx.pepper(2)}, {@id_a, Fx.pepper(1)})
    assert {:ok, %{key_id: @id_b}} = Backfill.run()

    %{tenant: tenant, original_current: original_current}
  end

  describe "key_status task (in VM)" do
    test "prints one line per key id with counts, marks current/previous, and a summary" do
      {lines, _log} = run_task(KeyStatus, [])
      out = infos(lines)

      assert Enum.any?(out, &(&1 == "key id #{@id_a}: rows=1 (previous)"))
      assert Enum.any?(out, &(&1 =~ ~r/^key id #{@id_b}: rows=\d+ \(current\)$/))
      assert Enum.any?(out, &(&1 =~ ~r/^login directory key status: \d+ key id\(s\) present$/))
      assert Enum.filter(lines, fn {level, _} -> level == :error end) == []
    end

    test "no email, key (hex/base64), pepper or directory query in stdout or the debug log" do
      {lines, log} = run_task(KeyStatus, [])
      output = Enum.map_join(lines, "\n", fn {_l, text} -> text end)
      assert_clean(output, log)
    end
  end

  describe "retire_key task (in VM)" do
    test "--dry-run reports the count and deletes nothing", %{tenant: tenant} do
      before = length(Fx.entries(tenant.tenant_id))
      {lines, log} = run_task(RetireKey, ["--key-id", @id_a, "--dry-run"])

      assert infos(lines) == ["dry run: 1 row(s) would be deleted for key id #{@id_a}"]
      assert length(Fx.entries(tenant.tenant_id)) == before
      assert_clean(Enum.map_join(lines, "\n", &elem(&1, 1)), log)

      {status_lines, _} = run_task(KeyStatus, [])
      assert Enum.any?(infos(status_lines), &(&1 == "key id #{@id_a}: rows=1 (previous)"))
    end

    test "a real run deletes exactly the retired id's rows and prints id and count only", %{
      tenant: tenant
    } do
      {lines, log} = run_task(RetireKey, ["--key-id", @id_a])

      assert infos(lines) == ["retired key id #{@id_a}: 1 row(s) deleted"]
      assert Enum.map(Fx.entries(tenant.tenant_id), & &1.key_id) == [@id_b]
      assert_clean(Enum.map_join(lines, "\n", &elem(&1, 1)), log)

      # key_status now shows no A line.
      {after_lines, _} = run_task(KeyStatus, [])
      refute Enum.any?(infos(after_lines), &(&1 =~ "key id #{@id_a}:"))
      assert Enum.any?(infos(after_lines), &(&1 =~ "key id #{@id_b}:"))

      # The person is still discoverable, under B.
      assert {:ok, [_]} = LoginDirectory.lookup_by_email(@email)
    end
  end

  describe "non-zero exits (child mix process; refusals only)" do
    @describetag timeout: 300_000

    test "missing --key-id exits 1 with the usage line" do
      {out, status} = mix_task("letflow.login_directory.retire_key", [])
      assert status == 1
      assert out =~ "usage: mix letflow.login_directory.retire_key --key-id ID [--dry-run]"
    end

    test "--key-id without a value, and an unknown option, exit 1 with the usage line" do
      for argv <- [["--key-id"], ["--bogus", "x"], ["--key-id", "x", "--bogus"]] do
        {out, status} = mix_task("letflow.login_directory.retire_key", argv)
        assert status == 1, "argv #{inspect(argv)} exited #{status}: #{out}"
        assert out =~ "usage: mix letflow.login_directory.retire_key"
      end
    end

    test "an invalid key id, the current key id and an absent key id each exit 1 with a refusal",
         ctx do
      # The child boots the test env: current key id is the configured test one.
      original_current = ctx.original_current

      cases = [
        {"BAD ID", "refused: the key id must match"},
        {original_current, "refused: that is the current key id"},
        {"rot443-never-present", "refused: no rows carry that key id"}
      ]

      for {id, message} <- cases, dry <- [[], ["--dry-run"]] do
        {out, status} = mix_task("letflow.login_directory.retire_key", ["--key-id", id] ++ dry)
        assert status == 1, "#{inspect(id)} #{inspect(dry)} exited #{status}: #{out}"
        assert out =~ message, "#{inspect(id)}: #{out}"
        refute out =~ "@"
      end
    end

    test "key_status exits 0 and prints ids and counts only" do
      {out, status} = mix_task("letflow.login_directory.key_status", [])
      assert status == 0, out
      assert out =~ "login directory key status:"
      refute out =~ "@"
      refute out =~ ~r/(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])/
    end
  end

  defp assert_clean(output, log) do
    secrets = [
      Fx.key_under(Fx.pepper(1), @email),
      Fx.key_under(Fx.pepper(2), @email),
      Fx.pepper(1),
      Fx.pepper(2)
    ]

    for secret <- secrets, haystack <- [output, log] do
      refute haystack =~ Base.encode16(secret, case: :lower)
      refute haystack =~ Base.encode16(secret, case: :upper)
      refute haystack =~ Base.encode64(secret)
    end

    for haystack <- [output, log] do
      refute haystack =~ "example.test"
      refute haystack =~ "task-rot-alice"
      refute haystack =~ "@"
    end

    refute log =~ "QUERY"
    refute log =~ "tenant_login_directory"
  end
end
