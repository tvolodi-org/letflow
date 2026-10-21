defmodule Letflow.Engine.ScriptRunRecordTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC12 (design `lib/letflow/design/gh2534-7c-script-handler.md` 7.1, 7.2, C12,
  C14; SEC S3): the `SCRIPT_RUN_RECORDED` payload has exactly the 7.1 key set and carries no
  value; the input HMAC recomputes under the tenant key; principal and triggering user; a
  crypto fault inside the HMAC closure and a raise inside the per-row pipeline log only ids,
  the tenant schema and a tag.

  Log assertions capture at `:info` (the production level); Ecto's own `:debug` query log is
  outside this code's control.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Engine.ScriptTaskDispatcher.RunRecord
  alias Letflow.Repository.Canonicaliser
  alias Letflow.Scripts.HmacSecret
  alias Letflow.Secrets
  alias Letflow.Support.ScriptTaskFixture, as: F

  @metadata [:component, :dispatch_id, :tenant_schema, :tag, :detail, :trigger, :count]

  setup do
    %{t: F.tenant!("gh2534-7c-rec")}
  end

  defp echo_manifest do
    F.closed_manifest()
    |> put_in(["input_schema", "properties", "note"], %{"type" => "string"})
    |> put_in(["output_schema", "properties"], %{"echo" => %{"type" => "string"}})
    |> put_in(["output_schema", "required"], ["echo"])
  end

  @echo "return { echo = ctx.input.note .. '-OUT' }"

  test "exact key set", %{t: t} do
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 1})
    {_row, {:ok, :applied}} = F.run_next!(t.schema_name)
    [record] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")

    assert Enum.sort(Map.keys(record)) == Enum.sort(RunRecord.keys())
    assert length(RunRecord.keys()) == 18
    assert is_integer(record["duration_us"]) and is_integer(record["heap_words"])
  end

  test "sentinels absent from the record, the row and the logs", %{t: t} do
    sentinel = "SENTINEL_#{System.unique_integer([:positive])}"

    log =
      capture_log([level: :info, metadata: @metadata], fn ->
        b = F.bound!(t, @echo, echo_manifest(), %{"amount" => 1, "note" => sentinel})
        {row, {:ok, :applied}} = F.run_next!(t.schema_name)
        send(self(), {:ran, b, row})
      end)

    assert_received {:ran, b, row}
    # the variables did receive the output (it is instance data, the replay source) ...
    assert F.projection(t.schema_name, b.instance_id).variables["echo"] == sentinel <> "-OUT"
    # ... but the per-run record, the dispatch row and the logs carry no value
    [record] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")
    refute Jason.encode!(record) =~ "SENTINEL"
    refute inspect(F.reload(t.schema_name, row), limit: :infinity) =~ "SENTINEL"
    refute log =~ "SENTINEL"
  end

  test "hmac recomputes under the tenant key, key_version is the secret's key_id", %{t: t} do
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 3, "ignored" => "x"})
    {row, {:ok, :applied}} = F.run_next!(t.schema_name)
    [record] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")

    {:ok, tenant} = Letflow.Identity.get_tenant(t.tenant_id)

    {:ok, %{plaintext: key, key_id: key_id}} =
      Secrets.resolve("sec://tenant/#{tenant.slug}/platform/script-input-hmac",
        tenant_id: t.tenant_id,
        consumer: :script_runner,
        platform: true
      )

    ctx = %{
      "instance_id" => row.instance_id,
      "node_id" => row.node_id,
      "token_id" => row.token_id,
      "now" => DateTime.to_iso8601(row.event_time)
    }

    # field-minimal: only the declared input ("amount") enters, never "ignored"
    document = Jason.encode!(%{"ctx" => ctx, "input" => %{"amount" => 3}})
    {:ok, canonical} = Canonicaliser.canonicalize_content("application/json", document)
    expected = :crypto.mac(:hmac, :sha256, key, canonical) |> Base.encode16(case: :lower)

    assert record["input_hmac"] == expected
    assert record["input_hmac_key_version"] == key_id
  end

  test "principal and user: starter, completing user, NULL on a platform hop", %{t: t} do
    # create/2 starts the run: the starting actor
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 1})
    assert F.row!(t.schema_name, b.instance_id).triggering_user_id == b.actor_id
    {_row, {:ok, :applied}} = F.run_next!(t.schema_name)
    [record] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")
    assert record["principal"] == "script:#{b.rule.key}@#{b.rule.version}"
    assert record["triggering_user_id"] == b.actor_id

    # complete_task/3 reaches the script node: the completing user
    h =
      F.bound_graph!(
        t,
        F.doubling_source(),
        F.closed_manifest(),
        %{"amount" => 1},
        &F.human_then_script_graph/2,
        []
      )

    task =
      Repo.one!(
        from(x in Letflow.Engine.Task,
          where: x.instance_id == ^h.instance_id and x.status == :pending
        ),
        prefix: t.schema_name
      )

    completer = Ecto.UUID.generate()

    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{output_variables: %{}, actor_id: completer, idempotency_key: "ct-#{completer}"},
               prefix: t.schema_name
             )

    assert F.row!(t.schema_name, h.instance_id).triggering_user_id == completer

    # a platform hop (the script-advance hop svc1 -> svc2, like a timer hop): NULL (R8)
    key2 = "k2#{System.unique_integer([:positive])}"
    rule2 = F.published!(t.schema_name, key2, F.doubling_source(), F.closed_manifest())

    two =
      F.bound_graph!(
        t,
        F.doubling_source(),
        F.closed_manifest(),
        %{"amount" => 1},
        fn key, version -> F.two_script_graph(key, version, key2, rule2.version) end,
        []
      )

    {_ok_row, {:ok, _}} = run_instance_row!(t, two.instance_id)
    rows = F.rows(t.schema_name, two.instance_id)

    assert [
             %{node_id: "svc1", triggering_user_id: starter},
             %{node_id: "svc2", triggering_user_id: nil}
           ] = rows

    assert starter == two.actor_id
  end

  # Runs this instance's due row (other instances of the tenant may also be due).
  defp run_instance_row!(t, instance_id) do
    row = Enum.find(F.rows(t.schema_name, instance_id), &(&1.status == :pending))
    F.make_due!(t.schema_name, row)

    Stream.repeatedly(fn -> ScriptTaskDispatcher.claim_next(t.schema_name) end)
    |> Enum.reduce_while(nil, fn
      {:ok, %{id: id} = claimed}, _ when id == row.id ->
        {:halt, {claimed, ScriptTaskDispatcher.run_claimed(claimed, t.schema_name)}}

      {:ok, other}, _ ->
        ScriptTaskDispatcher.run_claimed(other, t.schema_name)
        {:cont, nil}

      :none, _ ->
        flunk("row not claimable")
    end)
  end

  test "T-crypto-fault: a raising :crypto.mac inside the closure is hmac_failed, nothing leaks",
       %{t: t} do
    key_sentinel = "KEYBYTES_SENTINEL_#{System.unique_integer([:positive])}"

    F.put_env!(:script_task_hmac_fun_override, fn _tenant_id ->
      {:ok, HmacSecret.build_hmac_fun({:not_a_binary_key, key_sentinel}, 1)}
    end)

    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 1})

    log =
      capture_log([level: :debug, metadata: @metadata], fn ->
        {row, result} = F.run_next!(t.schema_name)
        send(self(), {:ran, row, result})
      end)

    assert_received {:ran, row, {:ok, :failed}}
    done = F.reload(t.schema_name, row)
    assert {done.outcome, done.outcome_detail} == {"script_rejected", "hmac_failed"}

    [record] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")
    assert record["phase"] == "rejected" and record["input_hmac"] == nil
    refute Jason.encode!(record) =~ key_sentinel
    refute log =~ key_sentinel
    refute log =~ "ArgumentError"
    refute log =~ "stacktrace"
    refute log =~ "** ("
  end

  test "raise logs tag only", %{t: t} do
    raise_sentinel = "RAISE_SENTINEL_#{System.unique_integer([:positive])}"
    F.put_env!(:script_task_runner, F.RaisingRunner)
    F.put_env!(:script_task_raise_message, raise_sentinel)
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 1})

    log =
      capture_log([level: :info, metadata: @metadata], fn ->
        {summary, _} = ScriptTaskDispatcher.run_tick([t.schema_name], 0)
        send(self(), {:summary, summary})
      end)

    assert_received {:summary, %{ran: 1}}
    assert log =~ "script task step caught"
    assert log =~ "tag=raised"
    assert log =~ "dispatch_id=#{b.row.id}"
    assert log =~ "tenant_schema=#{t.schema_name}"
    refute log =~ raise_sentinel
    refute log =~ "RuntimeError"
    refute log =~ "** ("
    # the row stays running for the lease sweep (never re-run)
    assert F.reload(t.schema_name, b.row).status == :running
  end

  test "T4: the platform actor is stored as NULL triggering user", %{t: t} do
    rule = F.published!(t.schema_name, "plat_k", F.doubling_source(), F.closed_manifest())
    definition = F.definition!(t.schema_name, F.script_graph("plat_k", rule.version), [])

    instance_id =
      F.start!(
        t.schema_name,
        definition,
        %{"amount" => 1},
        Letflow.EventStore.platform_actor_id()
      )

    assert F.row!(t.schema_name, instance_id).triggering_user_id == nil
  end
end
