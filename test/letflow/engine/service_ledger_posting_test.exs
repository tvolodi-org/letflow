defmodule Letflow.Engine.ServiceLedgerPostingTest do
  @moduledoc """
  REQ-688 / GH #3705 (slice L5, decision 0073 D-L12): a consented SERVICE_TASK node posts to the
  ledger through the real service apply (`Engine.advance_after_service_task_outcome/4`).

    * T-SV-1 the apply posts: entry, legs, balances, counter, one `ledger.posted` audit with the
      platform sentinel as actor; T-SV-1b a replay writes exactly one entry;
    * P-1 the step order: `:pre_ledger_lock` after the type-lock group and before the first token
      insert; a node without a posting line has none;
    * P-5 / S-7 / S-8 the refusals (an api_token activation, a node missing from the signed consent
      list) go through the real apply WITH the pre-step, and its empty rows roll back;
    * P-6 the dry build reads nothing.

  `async: false`: module installs, DDL and the application env test seam.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.ActivatedBy
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.HandlerWrites
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore
  alias Letflow.LedgerPostFixture, as: PFx
  alias Letflow.Repo

  defp posting_line(extra \\ %{}),
    do: PFx.post_line("post_alpha", PFx.posting("receipt", "a", "5"), extra)

  defp svc_case(slug, opts \\ []), do: PFx.service_case!(slug, [posting_line()], opts)

  defp probe_names(ctx) do
    Application.put_env(:letflow, :service_multi_probe, self())
    on_exit(fn -> Application.delete_env(:letflow, :service_multi_probe) end)
    result = Fx.apply_http(ctx, %{"label" => "x"})
    assert_receive {:service_multi_names, names}, 5_000
    {result, names}
  end

  defp posted_audits(schema), do: Fx.audit_rows(schema, "ledger.posted")

  defp refusal_detail(schema) do
    [entry] = Fx.audit_rows(schema, "entity_write.refused")
    entry.after_state["detail"]
  end

  defp dlq_count(schema), do: length(Fx.dlq_entries(schema))

  describe "T-SV-1 the consented SERVICE posting" do
    test "posts entry, legs, balances, counter and one ledger.posted audit by the sentinel" do
      ctx = svc_case("req688-sv1")

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "x"})
      assert {1, 1, 1, 1} = PFx.ledger_counts(ctx.schema)
      assert [audit] = posted_audits(ctx.schema)
      assert audit.actor_id == EventStore.platform_actor_id()
      assert dlq_count(ctx.schema) == 0
    end

    test "T-SV-1b a replay of the apply writes exactly one entry" do
      ctx = svc_case("req688-sv1b")

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "x"})
      _second = Fx.apply_http(ctx, %{"label" => "x"})
      assert {1, 1, 1, 1} = PFx.ledger_counts(ctx.schema)
      assert [_one] = posted_audits(ctx.schema)
    end
  end

  describe "P-1 the step order" do
    test "the pre-step sits after the type-lock group and before the token inserts" do
      ctx = svc_case("req688-p1")
      {result, names} = probe_names(ctx)
      assert {:ok, :advanced} = result

      pre = Enum.find_index(names, &(&1 == :pre_ledger_lock))
      assert is_integer(pre)
      assert Enum.find_index(names, &(&1 == :lock_ancestors)) < pre

      type_locks =
        for {{:pre_type_lock, _}, i} <- Enum.with_index(names), do: i

      assert Enum.all?(type_locks, &(&1 < pre))
      first_token = Enum.find_index(names, &match?({:hop_chain_token_records, _}, &1))
      assert pre < first_token
    end

    test "a node without a posting line has no :pre_ledger_lock" do
      ctx = PFx.service_case!("req688-p1b", [PFx.line("plain")])
      {_result, names} = probe_names(ctx)
      refute :pre_ledger_lock in names
    end
  end

  describe "refusals through the real apply" do
    test "S-7 an api_token activation is write_not_permitted, nothing written, rows rolled back" do
      ctx = svc_case("req688-s7", credential: :api_token)

      _result = Fx.apply_http(ctx, %{"label" => "x"})
      assert {0, 0, 0, 0} = PFx.ledger_counts(ctx.schema)
      assert posted_audits(ctx.schema) == []
      assert dlq_count(ctx.schema) == 1
      assert refusal_detail(ctx.schema) == "credential_unsupported"
    end

    test "S-8 a node missing from the signed consent list is refused, nothing written" do
      ctx = svc_case("req688-s8")
      resign_without_consent!(ctx)

      _result = Fx.apply_http(ctx, %{"label" => "x"})
      assert {0, 0, 0, 0} = PFx.ledger_counts(ctx.schema)
      assert dlq_count(ctx.schema) == 1
      assert refusal_detail(ctx.schema) == "ledger_consent_missing"
    end

    test "S-8b an activation without the flag cannot be activated" do
      assert_raise MatchError, fn -> svc_case("req688-s8b", consent: false) end
    end
  end

  describe "T-SV-4 outcomes of the service posting" do
    test "insufficient_balance lands in ERROR with exactly one DLQ entry, nothing written" do
      line = PFx.post_line("post_beta", PFx.posting("issue", "b", "-3"))
      ctx = PFx.service_case!("req688-sv4", [line])

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "x"})
      assert dlq_count(ctx.schema) == 1
      assert [entry] = Fx.dlq_entries(ctx.schema)
      # the service landing has a closed public code set: a typed ledger refusal is the closed
      # `entity_write_failed`, its core code only in the tenant audit (INV-5)
      assert entry.error_detail["code"] == "entity_write_failed"
      assert entry.error_detail["dispatch_id"] == ctx.dispatch.id
      # no entry, leg, balance or counter row, and no ledger.posted audit
      assert {0, 0, 0, 0} = PFx.ledger_counts(ctx.schema)
      assert posted_audits(ctx.schema) == []
      refute inspect(entry.error_detail) =~ "3.000"
    end

    test "T-SV-3 the refusal audit carries the neutral code only" do
      line = PFx.post_line("post_beta", PFx.posting("issue", "b", "-3"))
      ctx = PFx.service_case!("req688-sv3", [line])
      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "x"})

      assert [audit] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert audit.after_state["code"] == "entity_write_failed"
      assert audit.after_state["detail"] == "insufficient_balance"
      refute inspect(audit.after_state) =~ "available"
    end
  end

  describe "P-6 the dry build" do
    test "issues no query" do
      ctx = svc_case("req688-p6")
      line = posting_line()

      attrs = %{
        prefix: ctx.schema,
        instance_id: ctx.instance_id,
        origin: {:dispatch, ctx.dispatch.id},
        node_id: "svc",
        definition_id: ctx.definition.id,
        definition_version: ctx.definition.version,
        line_index: 0,
        actor_id: EventStore.platform_actor_id(),
        subject_id: ctx.completer.id,
        credential: :oidc,
        activator_id: ctx.completer.id,
        manifest_hash: manifest_hash(),
        variable_labels: %{},
        ledger_consent: true
      }

      handler_id = "letflow-test-dry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measure, _meta, _config -> send(test_pid, :query) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, [cap]} = HandlerWrites.dry_postings(attrs, line, %{}, [])
      assert cap.consented == true
      assert is_map(cap.posting)
      refute_received :query
    end
  end

  defp manifest_hash do
    {:ok, hash} = Letflow.Modules.Catalog.manifest_hash(Letflow.Modules.FixtureLedgerPost)
    hash
  end

  # Re-signs the stored activated_by document of the case's definition WITHOUT the consent list.
  defp resign_without_consent!(ctx) do
    row = Repo.get!(ProcessDefinition, ctx.definition.id, prefix: ctx.schema)

    record =
      row.activated_by
      |> Map.drop(["signature", "ledger_consent_nodes"])

    {:ok, signed} = ActivatedBy.sign(record, row, ctx.schema)

    Repo.query!(~s(ALTER TABLE "#{ctx.schema}"."process_definitions" DISABLE TRIGGER USER))

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^row.id),
        [set: [activated_by: signed]],
        prefix: ctx.schema
      )

    Repo.query!(~s(ALTER TABLE "#{ctx.schema}"."process_definitions" ENABLE TRIGGER USER))
    :ok
  end
end
