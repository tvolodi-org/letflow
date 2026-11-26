defmodule Letflow.QoimeksMoveP7RunbookTest do
  @moduledoc """
  T-2858: `docs/runbooks/qoimeks-move-p7.md` (en) and `.ru.md` order the Client 1 move (phase P7): twelve
  steps 0..11 with who acts, six checks, ROLLBACK, a tick list, route 3 for the production tenant and route 4
  for the owner's own tenant, the owner's single go (D-118). The dry-run scenario named in the runbook exists,
  its step ids are the ones the runbook cites, and every file and script the runbook cites exists. No database.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @en Path.join(@root, "docs/runbooks/qoimeks-move-p7.md")
  @ru Path.join(@root, "docs/runbooks/qoimeks-move-p7.ru.md")
  @scenario Path.join(@root, "test/uat/processes/BP-QOIMEKS-P7-dry-run.json")

  defp step_numbers(md) do
    md
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\| (\d+) \| \*\*/, line) do
        [_, n] -> [String.to_integer(n)]
        _ -> []
      end
    end)
  end

  defp check_numbers(md) do
    md
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\| (\d) \| [^*]/, line) do
        [_, n] -> [String.to_integer(n)]
        _ -> []
      end
    end)
  end

  for {name, path} <- [en: @en, ru: @ru] do
    describe "#{name} runbook" do
      @path path

      test "steps 0..11 in order, each with an actor column" do
        md = File.read!(@path)
        assert step_numbers(md) == Enum.to_list(0..11)
      end

      test "the six checks are rows 1..6 of their table" do
        md = File.read!(@path)
        assert Enum.take(check_numbers(md), -6) == Enum.to_list(1..6)
      end

      test "names the owner's go, route 3, route 4, rollback, the tick list and the scenario" do
        md = File.read!(@path)
        assert md =~ "D-118"
        assert md =~ "POST /admin/v1/tenants"
        assert md =~ "Signup.Provisioning.create_tenant/2"
        assert md =~ "ROLLBACK" or md =~ "ОТКАТ"
        assert md =~ "MAINTENANCE_MODE"
        assert md =~ "ANALYZE;"
        assert md =~ "BP-QOIMEKS-P7-dry-run"
        assert length(Regex.scan(~r/^- \[ \] /m, md)) == 13
      end

      test "every cited script, runbook and doc exists" do
        md = File.read!(@path)

        paths =
          Regex.scan(~r/`((?:docs|scripts|test)\/[A-Za-z0-9_.\/-]+\.(?:md|py|sh|exs|json))`/, md)
          |> Enum.map(fn [_, p] -> p end)
          |> Enum.uniq()

        assert paths != []
        assert Enum.filter(paths, &(not File.exists?(Path.join(@root, &1)))) == []
      end
    end
  end

  test "the scenario's step ids are the ones the runbook cites, and it writes nothing" do
    scenario = @scenario |> File.read!() |> Jason.decode!()
    ids = Enum.map(scenario["steps"], & &1["id"])

    for id <- ~w(q1 q2 q3 q4 q5 q6 q7 q8 q9 q10), do: assert(id in ids)

    assert scenario["cleanup"] == []
    assert scenario["id"] == "BP-QOIMEKS-P7-dry-run"
    # nothing is written: every call is a read, or a call the scenario expects to be refused
    for s <- scenario["steps"] do
      assert s["do"]["api"] == "GET" or Map.has_key?(s, "expect_refused"),
             "step #{s["id"]} writes"
    end

    en = File.read!(@en)
    for id <- ~w(q1 q6 q7 q8 q9 q10), do: assert(en =~ id)
  end
end
