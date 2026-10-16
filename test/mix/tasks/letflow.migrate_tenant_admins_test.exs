defmodule Mix.Tasks.Letflow.MigrateTenantAdminsTest do
  @moduledoc """
  REQ-447 PR 1, PART B: `mix letflow.migrate_tenant_admins` (spec `test/specs/REQ-447-PR1.md`).

  Two layers, because the task ends in `System.halt(1)` on a refusal or a failed tenant and that
  would terminate the test VM:

    * IN-PROCESS describe: every path that does not halt (a dry run with no failed tenant, a real
      run that converts). Output is captured through `Mix.Shell.Process`.
    * SUBPROCESS describe: every path that exits 1 (and a few that exit 0, for symmetry) runs the
      real task in a child `mix` process against the same test database. Pinned through the child's
      `LETFLOW_PLATFORM_TENANT_ID`, exactly as production does. The child sees this test's tenants
      because the tenant fixture commits (sandbox `:auto` mode).

  Both use `Letflow.Support.TenantAdminMigrationFixture.operator_tenant!/0`, which removes every
  other registration for the test's duration (a committed leftover tenant would fail the sweep and
  make every run exit 1) and restores it afterwards.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Letflow.Support.TenantAdminMigrationFixture

  alias Letflow.Identity.TenantAdminMigration
  alias Letflow.Identity.TenantRole
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Mix.Tasks.Letflow.MigrateTenantAdmins, as: MigrateTask

  # --- in-process -------------------------------------------------------------------

  defp run_task(argv) do
    original = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      MigrateTask.run(argv)
      drain_shell([])
    after
      Mix.shell(original)
    end
  end

  defp drain_shell(acc) do
    receive do
      {:mix_shell, :info, [text]} -> drain_shell([text | acc])
      {:mix_shell, _level, [text]} -> drain_shell(["OTHER:" <> text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp setup_world do
    p = operator_tenant!()
    a = tenant!("req447-task-a")
    %{users: users} = legacy!(a, 2)
    token!(a.schema_name, hd(users), ["PLATFORM_ADMIN"])

    # The task halts the VM when ANY registered tenant fails: refuse to run it in that state.
    assert {:ok, %{failed: []}} = TenantAdminMigration.run(dry_run: true)

    %{p: p, a: a, users: users}
  end

  describe "in-process (paths that do not halt)" do
    setup do
      setup_world()
    end

    test "--dry-run: pinned-tenant line first, then SUMMARY and one line per tenant; writes nothing; dry runs never refuse",
         %{p: p, a: a} do
      before = snapshot([p, a])

      lines = run_task(["--dry-run"])

      assert [first, summary | tenant_lines] = lines

      assert first ==
               "pinned slug=#{p.slug} realm=#{p.realm} operators=1 members_to_copy=2 tokens_to_rewrite=1 would_refuse="

      assert summary == "SUMMARY dry_run=true migrated=1 unchanged=0 failed=0"

      assert tenant_lines == [
               "tenant #{a.tenant_id} slug=#{a.slug} realm=#{a.realm} binding_created=true members_copied=2 binding_removed=true tokens=1 admins_after=2"
             ]

      assert snapshot([p, a]) == before
    end

    test "--dry-run with a pin problem prints would_refuse=<tag> and returns normally (no halt)",
         %{
           p: p,
           a: a
         } do
      before = snapshot([p, a])

      Fixture.unpin!()
      assert [first | _] = run_task(["--dry-run"])
      assert first =~ "would_refuse=platform_tenant_not_configured"

      Fixture.pin!(p.tenant_id)
      assert [first | _] = run_task(["--dry-run", "--platform-tenant=nope"])
      assert first =~ "would_refuse=platform_tenant_slug_mismatch"

      assert [first | _] = run_task(["--dry-run", "--expected-realm-id", "nope"])
      assert first =~ "would_refuse=platform_tenant_realm_mismatch"

      assert snapshot([p, a]) == before
    end

    test "a real run with both flags (= and space forms) converts, prints the tenant line, and a second run reports migrated=0",
         %{p: p, a: a, users: users} do
      lines = run_task(["--platform-tenant=#{p.slug}", "--expected-realm-id", p.realm])

      assert lines == [
               "SUMMARY dry_run=false migrated=1 unchanged=0 failed=0",
               "tenant #{a.tenant_id} slug=#{a.slug} realm=#{a.realm} binding_created=true members_copied=2 binding_removed=true tokens=1 admins_after=2"
             ]

      refute "PLATFORM_ADMIN" in Repo.all(from(r in TenantRole, select: r.name),
               prefix: a.schema_name
             )

      assert group_member_ids(a.schema_name, "TENANT_ADMIN") ==
               Enum.sort(Enum.map(users, & &1.id))

      again = run_task(["--platform-tenant=#{p.slug}", "--expected-realm-id=#{p.realm}"])
      assert again == ["SUMMARY dry_run=false migrated=0 unchanged=1 failed=0"]
    end

    test "output carries only ids, slugs, realm ids, atoms and counts: no email, username, display name, token hash or exception text",
         %{p: p, a: a, users: users} do
      dry = run_task(["--dry-run"])
      real = run_task(["--platform-tenant=#{p.slug}", "--expected-realm-id=#{p.realm}"])
      output = Enum.join(dry ++ real, "\n")

      for u <- users do
        refute output =~ u.email
        refute output =~ u.username
        refute output =~ u.display_name
        refute output =~ u.id
      end

      assert output =~ a.tenant_id
      refute output =~ "hash-"
      refute output =~ "Postgrex"
      refute output =~ "Ecto"
      refute output =~ "%{"
      assert Enum.all?(dry ++ real, &(not String.starts_with?(&1, "OTHER:")))
    end
  end

  defp group_member_ids(schema, group_name) do
    Repo.all(
      from(m in Letflow.Identity.GroupMember,
        join: g in Letflow.Identity.Group,
        on: g.id == m.group_id,
        where: g.name == ^group_name,
        select: m.user_id
      ),
      prefix: schema
    )
    |> Enum.sort()
  end

  # --- subprocess -------------------------------------------------------------------

  # Runs `mix letflow.migrate_tenant_admins <args>` in a child VM against the same test database.
  # `pin` is the child's LETFLOW_PLATFORM_TENANT_ID (nil unsets it). Returns {lines, exit_status}.
  defp mix_task(args, pin) do
    mix = System.find_executable("mix") || flunk("mix executable not found")

    env = [
      {"MIX_ENV", "test"},
      {"MIX_TEST_PARTITION", System.get_env("MIX_TEST_PARTITION")},
      {"LETFLOW_PLATFORM_TENANT_ID", pin}
    ]

    # GH #2630: the task runs `app.start` (a Repo pool); cap it (Letflow.Test.NestedMix).
    {output, status} =
      Letflow.Test.NestedMix.cmd(mix, ["letflow.migrate_tenant_admins" | args],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    {output |> String.split(~r/\R/) |> Enum.map(&String.trim/1), status}
  end

  describe "subprocess (paths that exit)" do
    @describetag timeout: 600_000

    test "an unknown or misspelt flag, and a positional argument: REFUSED invalid_option, exit 1, before anything runs" do
      for args <- [["--dry-runn"], ["--bogus=1"], ["--dry-run", "extra"], ["extra"]] do
        {lines, status} = mix_task(args, nil)

        assert status == 1, "args #{inspect(args)} exited #{status}"
        assert "REFUSED invalid_option" in lines
        refute Enum.any?(lines, &String.starts_with?(&1, "SUMMARY"))
      end
    end

    test "every refusal prints REFUSED <tag> and exits 1, and writes nothing" do
      p = operator_tenant!()
      a = tenant!("req447-task-refuse")
      %{users: [u]} = legacy!(a, 1)
      token!(a.schema_name, u, ["PLATFORM_ADMIN"])
      before = snapshot([p, a])

      cases = [
        {nil, [], "platform_tenant_not_configured"},
        {Ecto.UUID.generate(), ["--platform-tenant=#{p.slug}", "--expected-realm-id=#{p.realm}"],
         "platform_tenant_not_registered"},
        {p.tenant_id, [], "platform_tenant_slug_required"},
        {p.tenant_id, ["--platform-tenant=wrong", "--expected-realm-id=#{p.realm}"],
         "platform_tenant_slug_mismatch"},
        {p.tenant_id, ["--platform-tenant=#{p.slug}"], "platform_tenant_realm_required"},
        {p.tenant_id, ["--platform-tenant=#{p.slug}", "--expected-realm-id=wrong"],
         "platform_tenant_realm_mismatch"},
        {a.tenant_id, ["--platform-tenant=#{p.slug}", "--expected-realm-id=#{p.realm}"],
         "platform_tenant_slug_mismatch"}
      ]

      for {pin, args, tag} <- cases do
        {lines, status} = mix_task(args, pin)
        assert status == 1, "#{tag}: exit #{status}"
        assert "REFUSED #{tag}" in lines
        refute Enum.any?(lines, &String.starts_with?(&1, "SUMMARY"))
        assert snapshot([p, a]) == before, "#{tag}: rows changed"
      end
    end

    test "a pinned tenant without an operator is refused (platform_tenant_has_no_operator)" do
      p = operator_tenant!()
      q = tenant!("req447-task-noop")
      before = snapshot([p, q])

      {lines, status} =
        mix_task(["--platform-tenant=#{q.slug}", "--expected-realm-id=#{q.realm}"], q.tenant_id)

      assert status == 1
      assert "REFUSED platform_tenant_has_no_operator" in lines
      assert snapshot([p, q]) == before
    end

    test "--dry-run with a pin problem prints would_refuse and exits 0; --dry-run with a FAILED tenant exits 1 (the two cases pinned)" do
      p = operator_tenant!()
      a = tenant!("req447-task-dry")
      legacy!(a, 1)
      before = snapshot([p, a])

      # would_refuse only: exit 0.
      {lines, status} = mix_task(["--dry-run"], nil)
      assert status == 0
      assert Enum.any?(lines, &(&1 =~ "would_refuse=platform_tenant_not_configured"))
      # With no pin nobody is the platform tenant, so the dry run counts BOTH tenants as ordinary
      # (which is exactly what the would_refuse tag warns about).
      assert Enum.any?(lines, &(&1 == "SUMMARY dry_run=true migrated=2 unchanged=0 failed=0"))
      assert snapshot([p, a]) == before

      # A failed tenant: exit 1, with the failure printed as an atom tag only.
      f = tenant!("req447-task-dry-fail")
      routing = group!(f.schema_name, "routing-task")
      bind!(f.schema_name, "TENANT_ADMIN", :process_routing_role, routing)
      before_f = snapshot([p, a, f])

      {lines, status} = mix_task(["--dry-run"], p.tenant_id)
      assert status == 1

      assert "tenant #{f.tenant_id}: FAILED reason=role_name_taken_by_routing_role" in lines
      assert Enum.any?(lines, &(&1 == "SUMMARY dry_run=true migrated=1 unchanged=0 failed=1"))
      assert snapshot([p, a, f]) == before_f
    end

    test "a real run in a child process converts the tenant, exits 0, and the converted state is in the database; a failed tenant still exits 1 and the rest converts" do
      p = operator_tenant!()
      f = tenant!("req447-task-real-fail")
      a = tenant!("req447-task-real")
      %{users: users} = legacy!(a, 2)
      token!(a.schema_name, hd(users), ["PLATFORM_ADMIN"])

      args = ["--platform-tenant=#{p.slug}", "--expected-realm-id=#{p.realm}"]

      # Success first (f is still a plain empty tenant, so it converts too): exit 0.
      {lines, status} = mix_task(args, p.tenant_id)
      assert status == 0

      assert "SUMMARY dry_run=false migrated=2 unchanged=0 failed=0" in lines

      assert Enum.any?(
               lines,
               &(&1 ==
                   "tenant #{a.tenant_id} slug=#{a.slug} realm=#{a.realm} binding_created=true members_copied=2 binding_removed=true tokens=1 admins_after=2")
             )

      names = Repo.all(from(r in TenantRole, select: r.name), prefix: a.schema_name)
      assert "TENANT_ADMIN" in names
      refute "PLATFORM_ADMIN" in names

      # Second child run on converted data: nothing migrated, exit 0.
      {lines2, status2} = mix_task(args, p.tenant_id)
      assert status2 == 0
      assert "SUMMARY dry_run=false migrated=0 unchanged=2 failed=0" in lines2

      # Now make f fail: the run exits 1, the other tenant stays unchanged.
      routing = group!(f.schema_name, "routing-real")

      Repo.delete_all(from(r in TenantRole, where: r.name == "TENANT_ADMIN"),
        prefix: f.schema_name
      )

      bind!(f.schema_name, "TENANT_ADMIN", :process_routing_role, routing)

      {lines3, status3} = mix_task(args, p.tenant_id)
      assert status3 == 1
      assert "tenant #{f.tenant_id}: FAILED reason=role_name_taken_by_routing_role" in lines3
      assert "SUMMARY dry_run=false migrated=0 unchanged=1 failed=1" in lines3

      all = Enum.join(lines ++ lines2 ++ lines3, "\n")

      for u <- users do
        refute all =~ u.email
        refute all =~ u.username
      end
    end
  end
end
