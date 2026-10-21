defmodule Letflow.Scripts.PersonaActorSeedDriftTest do
  @moduledoc """
  ISS-0931 drift guard: the ROLES / PERSONAS tables in
  `scripts/seed_{meridian,vortex}_persona_actors.sh` must equal the `role-*` names the QA
  process definitions route HUMAN_TASKs to, and stay internally consistent. Pure file
  reads plus `bash -n`; no DB, no network. Mutations (M1-M8) are applied to in-memory
  copies of the script text, never to repo files.

  Design: lib/letflow/design/iss0931-meridian-vortex-persona-actor-provisioning.md
  section 6. Spec: test/specs/ISS-0931.md.
  """
  use ExUnit.Case, async: true

  @lib "scripts/lib/seed_persona_actors_base.sh"
  @tenants %{
    "meridian" => %{
      script: "scripts/seed_meridian_persona_actors.sh",
      fixtures: [
        "test/fixtures/qa/meridian_loan_origination_process_definition.json",
        "test/fixtures/qa/meridian_regulatory_compliance_review_process_definition.json"
      ],
      count: 9
    },
    "vortex" => %{
      script: "scripts/seed_vortex_persona_actors.sh",
      fixtures: [
        "test/fixtures/qa/vortex_production_order_release_process_definition.json",
        "test/fixtures/qa/vortex_supplier_quality_deviation_process_definition.json",
        "test/fixtures/qa/vortex_8d_corrective_action_definition.json"
      ],
      count: 6
    }
  }

  # ---------------------------------------------------------------- helpers

  defp launcher, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  defp parse_array(source, name) do
    lines = String.split(source, ~r/\r?\n/)

    case Enum.drop_while(lines, &(&1 != "#{name}=(")) do
      [] ->
        raise "array #{name}=( not found in script (format contract broken)"

      [_open | rest] ->
        rest
        |> Enum.take_while(&(&1 != ")"))
        |> Enum.map(fn line ->
          case Regex.run(~r/^\s*"([^"]*)"\s*$/, line) do
            [_, entry] -> entry
            nil -> raise "unparsable #{name} entry line: #{inspect(line)}"
          end
        end)
    end
  end

  defp parse_personas(entries) do
    Enum.map(entries, fn entry ->
      [user, roles] = String.split(entry, "|", parts: 2)
      {user, String.split(roles, ",", trim: true)}
    end)
  end

  defp collect_roles(%{} = m, acc) do
    Enum.reduce(m, acc, fn
      {"role", "role-" <> _ = v}, a -> MapSet.put(a, v)
      {_k, v}, a -> collect_roles(v, a)
    end)
  end

  defp collect_roles(l, acc) when is_list(l), do: Enum.reduce(l, acc, &collect_roles/2)
  defp collect_roles(_, acc), do: acc

  defp fixture_roles(paths) do
    Enum.reduce(paths, MapSet.new(), fn p, acc ->
      p |> File.read!() |> Jason.decode!() |> collect_roles(acc)
    end)
  end

  # Returns a list of error strings ([] = ok).
  defp roles_errors(source, fixture_set, count) do
    roles = parse_array(source, "ROLES")
    seeded = MapSet.new(roles)
    missing = fixture_set |> MapSet.difference(seeded) |> Enum.sort()
    extra = seeded |> MapSet.difference(fixture_set) |> Enum.sort()

    set_errs =
      if missing == [] and extra == [],
        do: [],
        else: ["missing_in_script=#{inspect(missing)} extra_in_script=#{inspect(extra)}"]

    dup_errs =
      if length(roles) == length(Enum.uniq(roles)), do: [], else: ["ROLES has duplicates"]

    cnt_errs =
      if length(roles) == count, do: [], else: ["ROLES count #{length(roles)} != #{count}"]

    set_errs ++ dup_errs ++ cnt_errs
  end

  defp personas_errors(source, tenant) do
    roles = parse_array(source, "ROLES")
    raw = parse_array(source, "PERSONAS")
    personas = parse_personas(raw)
    users = Enum.map(personas, &elem(&1, 0))
    held = personas |> Enum.flat_map(&elem(&1, 1)) |> MapSet.new()
    prefix = Regex.compile!("^actor-#{tenant}-[a-z]+$")

    checks = [
      {MapSet.subset?(held, MapSet.new(roles)), "persona roles not in ROLES"},
      {Enum.all?(users, &Regex.match?(prefix, &1)), "persona username with wrong tenant prefix"},
      {users == Enum.uniq(users), "duplicate persona usernames"},
      {Enum.all?(roles, &MapSet.member?(held, &1)), "a ROLES entry is held by nobody"},
      {not Enum.any?(roles ++ raw, &String.contains?(&1, "TASK_WORKER")),
       "TASK_WORKER listed explicitly"}
    ]

    for {ok, msg} <- checks, not ok, do: msg
  end

  defp bash_n(path) do
    case launcher() do
      nil -> :skip
      bash -> System.cmd(bash, ["-n", path], stderr_to_stdout: true)
    end
  end

  defp src(tenant), do: File.read!(@tenants[tenant].script)

  defp fx(tenant), do: fixture_roles(@tenants[tenant].fixtures)

  # ---------------------------------------------------------------- real scripts

  for {tenant, _} <- @tenants do
    describe "#{tenant}" do
      test "#{tenant}: seeded ROLES set equals the roles referenced by the QA definitions" do
        t = unquote(tenant)
        assert roles_errors(src(t), fx(t), @tenants[t].count) == []
      end

      test "#{tenant}: every persona role is a seeded role" do
        t = unquote(tenant)
        assert personas_errors(src(t), t) == []
      end

      test "#{tenant}: script passes bash -n" do
        t = unquote(tenant)

        for path <- [@tenants[t].script, @lib] do
          case bash_n(path) do
            :skip -> :ok
            {out, code} -> assert code == 0, "bash -n #{path} failed: #{out}"
          end
        end
      end

      test "#{tenant}: script sources the shared lib and calls persona_run" do
        t = unquote(tenant)
        s = src(t)
        assert s =~ ~r{^source\s+".*lib/seed_persona_actors_base\.sh"}m
        assert s =~ ~r/^persona_run #{t}$/m
      end
    end
  end

  # ---------------------------------------------------------------- mutations (in memory)

  describe "mutation sensitivity (in-memory copies)" do
    test "M1: dropping role-loan-ops from meridian ROLES is detected" do
      s = String.replace(src("meridian"), "  \"role-loan-ops\"\n", "", global: false)
      assert [msg | _] = roles_errors(s, fx("meridian"), 9)
      assert msg =~ "missing_in_script=[\"role-loan-ops\"]"
    end

    test "M2: removing role-procurement-manager from vortex ROLES is detected" do
      s =
        String.replace(src("vortex"), "  \"role-procurement-manager\"\n", "", global: false)

      assert [msg | _] = roles_errors(s, fx("vortex"), 5)
      assert msg =~ "missing_in_script=[\"role-procurement-manager\"]"
    end

    test "M3: persona referencing an unseeded role is detected" do
      s =
        String.replace(
          src("vortex"),
          "actor-vortex-karl|role-quality-manager",
          "actor-vortex-karl|role-qa-lead"
        )

      assert "persona roles not in ROLES" in personas_errors(s, "vortex")
    end

    test "M4: wrong-tenant actor in vortex PERSONAS is detected" do
      s = String.replace(src("vortex"), "actor-vortex-anna|", "actor-meridian-ben|")
      assert "persona username with wrong tenant prefix" in personas_errors(s, "vortex")
    end

    test "M5: dropping role-cro from every meridian persona is detected" do
      s = String.replace(src("meridian"), "thomas|role-cro\"", "thomas|\"")
      assert "a ROLES entry is held by nobody" in personas_errors(s, "meridian")
    end

    test "M6: a new role node in a fixture is detected against unchanged ROLES" do
      extra =
        Path.join(System.tmp_dir!(), "iss0931_m6_#{System.unique_integer([:positive])}.json")

      File.write!(extra, ~s({"nodes":[{"type":"HUMAN_TASK","config":{"role":"role-new-thing"}}]}))
      on_exit(fn -> File.rm(extra) end)
      set = fixture_roles(@tenants["vortex"].fixtures ++ [extra])
      assert [msg | _] = roles_errors(src("vortex"), set, 5)
      assert msg =~ "role-new-thing"
    end

    test "M7: broken shell syntax is detected by bash -n" do
      tmp = Path.join(System.tmp_dir!(), "iss0931_m7_#{System.unique_integer([:positive])}.sh")
      File.write!(tmp, src("vortex") <> "\nif true; then\necho x\n")
      on_exit(fn -> File.rm(tmp) end)

      case bash_n(tmp) do
        :skip -> :ok
        {_out, code} -> assert code != 0
      end
    end

    test "M8: renamed ROLES opener makes parse_array raise" do
      s = String.replace(src("meridian"), "ROLES=(", "ROLE=(", global: false)
      assert_raise RuntimeError, ~r/not found/, fn -> parse_array(s, "ROLES") end
    end
  end
end
