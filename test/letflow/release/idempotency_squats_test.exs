defmodule Letflow.Release.IdempotencySquatsTest do
  @moduledoc """
  GH #2597 -- the operator wrappers (`Letflow.Release.IdempotencySquats`), the exit-code helpers
  the Mix tasks use, and the runbook. Test T7. Spec: `test/specs/GH-2597.md`.

  The wrappers are called in-process: a `System.halt` inside them would kill the test VM, so
  every test that returns is itself proof they do not halt. The Mix tasks' halt is tested only
  through the exit-code mapping functions (`audit_exit_code/1`, `remediate_exit_code/1`).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureIO

  alias Letflow.Release.IdempotencySquats
  alias Letflow.Repo
  alias Letflow.SquatFixtures, as: F
  alias Letflow.TenantFixture

  defp tenant!(prefix \\ "gh2597-wrap"),
    do: TenantFixture.provisioned_tenant!(slug_prefix: prefix)

  defp lines(out), do: String.split(out, "\n", trim: true)

  describe "audit/0" do
    test "prints a FLAG line per flagged row, a TENANT count line and a SUMMARY line; returns the summary" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:flagged", actor_id: Ecto.UUID.generate())
      F.insert_squat!(s, "sys:reserved", actor_id: Ecto.UUID.generate())
      F.insert_squat!(s, "script_run:legit", actor_id: F.platform_actor())

      {result, out} = with_io(fn -> IdempotencySquats.audit() end)

      assert {:ok, %{scanned: scanned, flagged: flagged, report_only: ro, errored: []}} = result
      assert scanned >= 3 and flagged >= 1 and ro >= 1

      ls = lines(out)

      assert Enum.any?(ls, fn l ->
               String.starts_with?(l, "FLAG ") and l =~ ~s(key="script_run:flagged") and
                 l =~ "reason=actor_not_platform" and l =~ ~s(tenant="#{tid}") and
                 l =~ ~s(schema="#{s}")
             end)

      # report-only lines are labelled FINDING, not FLAG
      assert Enum.any?(
               ls,
               &(String.starts_with?(&1, "FINDING ") and &1 =~ ~s(key="sys:reserved"))
             )

      refute Enum.any?(ls, &(&1 =~ "script_run:legit"))

      assert Enum.any?(
               ls,
               &(&1 =~
                   "TENANT tenant=#{tid} schema=#{s} scanned=3 flagged=1 report_only=1 errored=0")
             )

      assert List.last(ls) =~
               ~r/^SUMMARY tenants=\d+ scanned=\d+ flagged=\d+ report_only=\d+ errored=0$/
    end

    test "writes nothing" do
      %{schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:flagged", actor_id: Ecto.UUID.generate())
      before = F.counts(s)

      capture_io(fn -> assert {:ok, _} = IdempotencySquats.audit() end)
      assert F.counts(s) == before
    end

    test "never prints payload or field_values content" do
      %{schema_name: s} = tenant!()
      marker = "PAYLOAD-SECRET-#{System.unique_integer([:positive])}"

      F.insert_squat!(s, "script_run:p",
        actor_id: Ecto.UUID.generate(),
        payload: %{
          "entity_type" => "widget",
          "record_id" => Ecto.UUID.generate(),
          "field_values" => %{"title" => marker, "session_id" => marker}
        }
      )

      out = capture_io(fn -> IdempotencySquats.audit() end)
      assert out =~ "script_run:p"
      refute out =~ marker
      refute out =~ "field_values"
      refute out =~ "payload"
    end

    test "control characters in a squatter-chosen key are escaped: one line, no raw control byte" do
      %{schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:a\nFLAG injected\e[31m\x01b", actor_id: Ecto.UUID.generate())

      out = capture_io(fn -> IdempotencySquats.audit() end)

      refute out =~ "\nFLAG injected"
      refute String.contains?(out, <<27>>)
      refute String.contains?(out, <<1>>)
      refute Enum.any?(lines(out), &String.starts_with?(&1, "FLAG injected"))
      # still reported, on one FLAG line (inspect/1 may render a key with control bytes as a
      # byte list, which is still free of raw control characters)
      assert Enum.any?(lines(out), &(String.starts_with?(&1, "FLAG ") and &1 =~ "key="))
    end

    test "a tenant whose scan errors is listed in errored, printed with the SQLSTATE atom only, and the others still run" do
      %{tenant_id: good, schema_name: sg} = tenant!("gh2597-wrap-good")
      %{tenant_id: bad, schema_name: sb} = tenant!("gh2597-wrap-bad")
      F.insert_squat!(sg, "script_run:g", actor_id: Ecto.UUID.generate())
      Repo.query!(~s(DROP SCHEMA "#{sb}" CASCADE))

      {{:ok, summary}, out} = with_io(fn -> IdempotencySquats.audit() end)

      assert bad in summary.errored
      refute good in summary.errored

      assert out =~
               "TENANT tenant=#{bad} schema=#{sb} errored=1 error=query_failed:undefined_table"

      assert out =~ "TENANT tenant=#{good} schema=#{sg} scanned=1 flagged=1"
      assert List.last(lines(out)) =~ ~r/errored=[1-9]/
      # a Postgrex message may quote data: it is never printed
      refute out =~ "does not exist"
    end
  end

  describe "remediate/3" do
    test "prints the resolved tenant and schema before acting, then OK; returns {:ok, _}" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:x", actor_id: Ecto.UUID.generate())

      {result, out} = with_io(fn -> IdempotencySquats.remediate(tid, "script_run:x", "op") end)

      assert {:ok, %{outcome: :removed, key: "script_run:x"}} = result
      assert [target, ok] = lines(out)
      assert target == ~s(TARGET tenant=#{tid} schema=#{s} key="script_run:x")
      assert ok == ~s(OK outcome=removed key="script_run:x")
      assert F.key_rows(s, "script_run:x") == 0
    end

    test "a refusal prints ERROR not_flagged with the finding and returns {:error, _}" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:ok", actor_id: F.platform_actor())

      {result, out} = with_io(fn -> IdempotencySquats.remediate(tid, "script_run:ok", "op") end)

      assert {:error, {:not_flagged, %{verdict: :clear}}} = result
      assert out =~ ~r/^TARGET /
      assert out =~ "ERROR not_flagged FINDING "
      assert F.key_rows(s, "script_run:ok") == 1
    end

    test "unknown or malformed tenant, invalid key/operator: ERROR line, {:error, _}, no TARGET line" do
      {r1, o1} = with_io(fn -> IdempotencySquats.remediate(Ecto.UUID.generate(), "k", "op") end)
      assert r1 == {:error, :unknown_tenant}
      assert o1 == "ERROR unknown_tenant\n"

      {r2, o2} = with_io(fn -> IdempotencySquats.remediate("junk", "k", "op") end)
      assert r2 == {:error, :unknown_tenant}
      assert o2 == "ERROR unknown_tenant\n"

      {r3, _} = with_io(fn -> IdempotencySquats.remediate(nil, "k", "op") end)
      assert r3 == {:error, :unknown_tenant}

      %{tenant_id: tid} = tenant!()
      {r4, o4} = with_io(fn -> IdempotencySquats.remediate(tid, "", "op") end)
      assert r4 == {:error, :invalid_key}
      assert o4 =~ "ERROR invalid_key"

      {r5, o5} = with_io(fn -> IdempotencySquats.remediate(tid, "script_run:x", "") end)
      assert r5 == {:error, :invalid_operator}
      assert o5 =~ "ERROR invalid_operator"
    end

    test "a key with control characters is printed escaped on one line" do
      %{tenant_id: tid} = tenant!()
      key = "script_run:a\nOK injected\x01"

      out = capture_io(fn -> IdempotencySquats.remediate(tid, key, "op") end)

      assert [target, ok] = lines(out)
      assert String.starts_with?(target, "TARGET ")
      assert String.starts_with?(ok, "OK outcome=already_clear")
      refute String.contains?(out, <<1>>)
    end

    test "lock conflict is printed and returned as an error value, not raised" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:l", actor_id: Ecto.UUID.generate())
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s(SELECT 1 FROM "#{s}".event_idempotency WHERE idempotency_key = $1 FOR UPDATE),
              ["script_run:l"]
            )

            send(parent, :locked)

            receive do
              :release -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)

      assert_receive :locked, 5_000
      {result, out} = with_io(fn -> IdempotencySquats.remediate(tid, "script_run:l", "op") end)
      send(holder.pid, :release)
      Task.await(holder, 10_000)

      assert result == {:error, :lock_conflict}
      assert out =~ "ERROR lock_conflict"
    end
  end

  describe "exit codes (the only thing the Mix tasks halt on)" do
    test "audit_exit_code/1: 0 with no errored tenant, 1 with any" do
      assert IdempotencySquats.audit_exit_code(
               {:ok, %{scanned: 0, flagged: 5, report_only: 2, errored: []}}
             ) == 0

      assert IdempotencySquats.audit_exit_code(
               {:ok, %{scanned: 0, flagged: 0, report_only: 0, errored: ["t"]}}
             ) == 1
    end

    test "remediate_exit_code/1: 0 for any {:ok, _} (incl. already_clear), 1 for any {:error, _}" do
      assert IdempotencySquats.remediate_exit_code({:ok, %{outcome: :removed, key: "k"}}) == 0

      assert IdempotencySquats.remediate_exit_code({:ok, %{outcome: :already_clear, key: "k"}}) ==
               0

      assert IdempotencySquats.remediate_exit_code({:error, :unknown_tenant}) == 1
      assert IdempotencySquats.remediate_exit_code({:error, :lock_conflict}) == 1
      assert IdempotencySquats.remediate_exit_code({:error, {:not_flagged, %{}}}) == 1
    end

    test "end to end: the codes derived from real results" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:x", actor_id: Ecto.UUID.generate())
      F.insert_squat!(s, "script_run:ok", actor_id: F.platform_actor())

      {codes, _out} =
        with_io(fn ->
          for {t, k} <- [
                {tid, "script_run:x"},
                {tid, "script_run:x"},
                {tid, "script_run:ok"},
                {Ecto.UUID.generate(), "k"}
              ] do
            t |> IdempotencySquats.remediate(k, "op") |> IdempotencySquats.remediate_exit_code()
          end
        end)

      assert codes == [0, 0, 1, 1]
    end

    test "the Mix tasks halt only through the exit-code helpers and the wrapper never halts" do
      # AST, not text: the moduledoc says "never calls System.halt" and must not trip this.
      {_, halts} =
        "lib/letflow/release/idempotency_squats.ex"
        |> File.read!()
        |> Code.string_to_quoted!()
        |> Macro.prewalk([], fn
          {{:., _, [{:__aliases__, _, [:System]}, fun]}, _, _} = n, acc
          when fun in [:halt, :stop] ->
            {n, [fun | acc]}

          {{:., _, [:erlang, :halt]}, _, _} = n, acc ->
            {n, [:halt | acc]}

          n, acc ->
            {n, acc}
        end)

      assert halts == []

      for t <- [
            "lib/mix/tasks/letflow.audit_idempotency_squats.ex",
            "lib/mix/tasks/letflow.remediate_idempotency_squat.ex"
          ] do
        src = File.read!(t)
        assert src =~ "_exit_code("
        assert src =~ "System.halt(code)"
      end

      for mod <- [
            Mix.Tasks.Letflow.AuditIdempotencySquats,
            Mix.Tasks.Letflow.RemediateIdempotencySquat
          ] do
        assert Code.ensure_loaded?(mod)
        assert function_exported?(mod, :run, 1)
      end
    end

    test "the remediate task refuses wrong arity with a usage error instead of acting" do
      assert_raise Mix.Error, ~r/usage: mix letflow.remediate_idempotency_squat/, fn ->
        Mix.Tasks.Letflow.RemediateIdempotencySquat.run(["only-one-arg"])
      end
    end
  end

  describe "runbook" do
    test "exists and names both operator entry points and both Mix tasks" do
      path = "docs/runbooks/idempotency-key-squat-audit.md"
      assert File.exists?(path)
      doc = File.read!(path)

      assert doc =~ "Letflow.Release.IdempotencySquats.audit()"
      assert doc =~ "Letflow.Release.IdempotencySquats.remediate("
      assert doc =~ "mix letflow.audit_idempotency_squats"
      assert doc =~ "mix letflow.remediate_idempotency_squat"
      assert doc =~ "rpc"
    end
  end
end
