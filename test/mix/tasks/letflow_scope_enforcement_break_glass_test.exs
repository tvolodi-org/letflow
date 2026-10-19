defmodule Mix.Tasks.Letflow.ScopeEnforcement.BreakGlassTest do
  @moduledoc """
  GH #2883 (design `lib/letflow/design/gh2883-scope-enforcement-break-glass.md` section 3.2 and
  test T-BG-27; spec `test/specs/GH2883-break-glass.md`): the dev and CI Mix wrapper of
  `Letflow.Release.ScopeBreakGlass.run/5`.

    * `parse_args!/1` is a pure argv parser: every mandatory switch, exactly one of
      `--confirm <slug>` and `--dry-run`, no unknown switch, no extra positional, no empty value,
      and NO default for the operator (no `$USER`) -- tested without `app.start`;
    * a valid argv reaches `run/5`: the task's `run/1` is called in-process for a dry run and for
      a real run (the success path never halts; the halting error path is covered through
      `exit_code/1` in `ScopeBreakGlassTest`);
    * the moduledoc states, in its first paragraph, that the Mix form is for dev and CI only and
      that `app.start` on a production host boots a second application against the same database
      (SEC F-4).

  `async: false`: it uses a committed `on` tenant and the VM-global OS environment.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureIO

  alias Letflow.Support.BreakGlassFixture, as: BG
  alias Mix.Tasks.Letflow.ScopeEnforcement.BreakGlass

  @reason "INC-2883: identity provider outage"
  @op "ops.handle-2883"

  setup do
    BG.purge_stale!()
    :ok
  end

  defp confirm_argv,
    do: [
      "my-slug",
      "--to",
      "shadow",
      "--reason",
      @reason,
      "--operator",
      @op,
      "--confirm",
      "my-slug"
    ]

  defp dry_argv,
    do: ["my-slug", "--to", "off", "--reason", @reason, "--operator", @op, "--dry-run"]

  defp usage_error!(argv) do
    error = assert_raise Mix.Error, fn -> BreakGlass.parse_args!(argv) end
    assert error.message =~ "usage: mix letflow.scope_enforcement.break_glass"
    error
  end

  describe "T-BG-27 parse_args!/1" do
    test "a valid confirm argv and a valid dry-run argv parse into the run/5 arguments" do
      assert BreakGlass.parse_args!(confirm_argv()) ==
               {"my-slug", "shadow", @reason, @op, [confirm: "my-slug"]}

      assert BreakGlass.parse_args!(dry_argv()) ==
               {"my-slug", "off", @reason, @op, [dry_run: true]}
    end

    test "the switches may come before the slug" do
      assert {"my-slug", "shadow", _reason, _op, [dry_run: true]} =
               BreakGlass.parse_args!([
                 "--to",
                 "shadow",
                 "--reason",
                 @reason,
                 "--operator",
                 @op,
                 "--dry-run",
                 "my-slug"
               ])
    end

    test "a missing --to, --reason or --operator is a usage error" do
      for switch <- ["--to", "--reason", "--operator"] do
        argv = drop_switch(confirm_argv(), switch)
        usage_error!(argv)
      end
    end

    test "both or neither of --confirm and --dry-run is a usage error" do
      usage_error!(drop_switch(confirm_argv(), "--confirm"))
      usage_error!(confirm_argv() ++ ["--dry-run"])
      usage_error!(dry_argv() ++ ["--confirm", "my-slug"])
      usage_error!(dry_argv() ++ ["--no-dry-run"])
    end

    test "an unknown switch, an extra positional and a missing slug are usage errors" do
      usage_error!(confirm_argv() ++ ["--yes"])
      usage_error!(confirm_argv() ++ ["--force", "1"])
      usage_error!(confirm_argv() ++ ["another-slug"])
      usage_error!(Enum.drop(confirm_argv(), 1))
      usage_error!([])
    end

    test "an empty or blank value is a usage error" do
      usage_error!(replace_value(confirm_argv(), "--reason", ""))
      usage_error!(replace_value(confirm_argv(), "--reason", "   "))
      usage_error!(replace_value(confirm_argv(), "--operator", ""))
      usage_error!(replace_value(confirm_argv(), "--to", ""))
      usage_error!(replace_value(confirm_argv(), "--confirm", ""))
      usage_error!(["  " | tl(confirm_argv())])
    end

    test "a repeated switch keeps the LAST value (OptionParser without :keep); run/5 validates it" do
      assert {"my-slug", "off", @reason, "second", [confirm: "my-slug"]} =
               BreakGlass.parse_args!(confirm_argv() ++ ["--operator", "second", "--to", "off"])
    end

    test "there is no default operator: the OS user is never used" do
      original = Map.new(~w(USER USERNAME LOGNAME), &{&1, System.get_env(&1)})
      on_exit(fn -> Enum.each(original, fn {k, v} -> restore_env(k, v) end) end)

      for key <- ~w(USER USERNAME LOGNAME), do: System.put_env(key, "someone-else")

      usage_error!(drop_switch(confirm_argv(), "--operator"))
      usage_error!(drop_switch(dry_argv(), "--operator"))
    end

    test "the parser passes the values through unchanged: validation belongs to run/5" do
      assert {"s", "on", "r", "bad label", [dry_run: true]} =
               BreakGlass.parse_args!([
                 "s",
                 "--to",
                 "on",
                 "--reason",
                 "r",
                 "--operator",
                 "bad label",
                 "--dry-run"
               ])
    end
  end

  describe "T-BG-27 a valid argv reaches run/5" do
    test "the task run/1 does a dry run and then a real run against a throwaway on tenant" do
      fx = BG.on_tenant!("t27")
      slug = fx.tenant.slug
      before = BG.entry_count(fx)

      dry =
        capture_io(fn ->
          assert :ok =
                   BreakGlass.run([
                     slug,
                     "--to",
                     "shadow",
                     "--reason",
                     @reason,
                     "--operator",
                     @op,
                     "--dry-run"
                   ])
        end)

      assert dry =~ "DRYRUN would_change=true"
      assert BG.mode(fx) == "on"
      assert BG.entry_count(fx) == before

      real =
        capture_io(fn ->
          assert :ok =
                   BreakGlass.run([
                     slug,
                     "--to",
                     "shadow",
                     "--reason",
                     @reason,
                     "--operator",
                     @op,
                     "--confirm",
                     slug
                   ])
        end)

      assert real =~ "OK slug=#{inspect(slug)} previous=on mode=shadow"
      assert BG.mode(fx) == "shadow"
      assert BG.entry_count(fx) == before + 1
    end
  end

  describe "T-BG-27 the moduledoc" do
    test "the first paragraph says the Mix form is for dev and CI only and that app.start boots a second application" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(BreakGlass)

      first = moduledoc |> String.split(~r/\n\s*\n/, parts: 2) |> hd() |> flat()

      assert first =~ "The Mix form is for dev and CI hosts ONLY"
      assert first =~ "Do NOT run it on a production host"
      assert first =~ "app.start"
      assert first =~ "a second full Letflow application"
      assert first =~ "against the same database as the running node"
      assert first =~ "rpc"
    end

    test "the moduledoc also states there is no default operator and that only this task halts" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(BreakGlass)

      flat = flat(moduledoc)

      assert flat =~ "There is no default for `--operator` (no `$USER`)"
      assert flat =~ "this task is the only place that halts"
    end
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  # removes `switch` and its value (or the bare switch)
  defp drop_switch(argv, switch) do
    case Enum.find_index(argv, &(&1 == switch)) do
      nil ->
        argv

      index ->
        value? = switch != "--dry-run"
        List.delete_at(argv, index) |> then(&if(value?, do: List.delete_at(&1, index), else: &1))
    end
  end

  defp replace_value(argv, switch, value) do
    index = Enum.find_index(argv, &(&1 == switch))
    List.replace_at(argv, index + 1, value)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
