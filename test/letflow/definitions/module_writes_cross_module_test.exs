defmodule Letflow.Definitions.ModuleWritesCrossModuleTest do
  @moduledoc """
  REQ-758 / GH #3903 (decision 0082): a definition stamped by module M may carry a posting line of
  a module N in M's compiled `depends_on` when N's handler registers `posts_ledger`, the same node
  carries a posting line of M, and N is installed with its installed hash equal to its compiled
  hash. M is the test module `fixture_xpost_owner`, N the existing `fixture_ledger_post`.

  X1 decision record, X2 activation accepted, X3a..X3j activation refused (one code each, nothing
  activated), X4a..X4e the run time (completion through `Engine.complete_task/3`), X5 the files
  the change does not touch. Rows X4a..X4d of the run time were written first against the unchanged
  `HandlerWrites.owner_recheck/3` (red proof in the PR).

  `async: false`: tenant provisioning switches the sandbox, the module installs run DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.CrossPostFixture, as: X
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @decision "docs/migration/decisions/0082-cross-module-posting-lines.md"

  defp doc(doc_id \\ "d1"), do: %{"document_id" => doc_id}

  defp own(extra \\ %{}),
    do: X.own_post_line(X.posting("receipt", "a", "5", Map.merge(doc(), extra)))

  defp n_alpha(extra \\ %{}),
    do: X.n_line(X.posting("receipt", "b", "7", Map.merge(doc(), extra)))

  defp n_beta,
    do: Letflow.LedgerPostFixture.post_line("post_beta", X.posting("receipt", "c", "1", doc()))

  defp refused(ctx, lines, opts \\ []) do
    assert {:error, {:entity_writes_invalid, violations}} = X.try_activate(ctx, lines, opts)
    violations |> Enum.map(&{&1.index, &1.code}) |> Enum.sort()
  end

  defp set_n!(schema, changes) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "fixture_ledger_post"),
        [set: changes],
        prefix: schema
      )
  end

  describe "X1 decision record" do
    test "X1 names the refusals, options A and B and what it amends" do
      text = File.read!(@decision)

      for needle <- [
            "module_write_stamp_mismatch",
            "write_handler_ledger_missing",
            "Option A",
            "Option B",
            "0054",
            "D6",
            "0073",
            "A2",
            "owner_recheck"
          ] do
        assert text =~ needle, "decision record lacks #{needle}"
      end
    end
  end

  describe "X2 activation accepted" do
    test "X2 the pair M + N activates with both installed and hashes matching" do
      ctx = X.case!("x2", [own(), n_alpha()])
      assert ctx.definition.status == :active
    end
  end

  describe "X3 activation refused" do
    setup do
      %{ctx: X.case!("x3", [])}
    end

    test "X3a N not in M's depends_on is module_write_stamp_mismatch", %{ctx: ctx} do
      other = %{"module" => "fixture_ledger_other", "handler" => "post_entry", "args" => %{}}
      assert [{1, :module_write_stamp_mismatch}] == refused(ctx, [own(), other])
    end

    test "X3b a line of N whose handler has no posts_ledger is stamp_mismatch", %{ctx: ctx} do
      plain = Letflow.LedgerPostFixture.line("plain")
      assert [{1, :module_write_stamp_mismatch}] == refused(ctx, [own(), plain])
    end

    test "X3c a line of N alone on the node is stamp_mismatch", %{ctx: ctx} do
      assert [{0, :module_write_stamp_mismatch}] == refused(ctx, [n_alpha()])
    end

    test "X3d N not installed is module_write_module_not_installed", %{ctx: ctx} do
      Repo.delete_all(from(m in TenantModule, where: m.module_id == "fixture_ledger_post"),
        prefix: ctx.schema
      )

      assert [{1, :module_write_module_not_installed}] == refused(ctx, [own(), n_alpha()])
    end

    test "X3e N's installed hash differing from its compiled hash is hash_mismatch", %{ctx: ctx} do
      set_n!(ctx.schema, manifest_hash: String.duplicate("d", 64))
      assert [{1, :module_write_hash_mismatch}] == refused(ctx, [own(), n_alpha()])
    end

    test "X3f three posting lines is module_writes_too_many_ledger_postings", %{ctx: ctx} do
      assert [{2, :module_writes_too_many_ledger_postings}] ==
               refused(ctx, [own(), n_alpha(), n_beta()])
    end

    test "X3g a repeated ledger id is module_writes_duplicate_ledger_posting", %{ctx: ctx} do
      # M and N cannot name one ledger id with two real registrations (M's id is fixture_xpost_owner,
      # N's are fixture_ledger_post and fixture_ledger_post:beta), so the duplicate is N with itself.
      # With no line of M, rule (c) refuses both lines as well; the duplicate code is the one pinned.
      codes = ctx |> refused([n_alpha(), n_alpha()]) |> Enum.map(&elem(&1, 1))
      assert :module_writes_duplicate_ledger_posting in codes
    end

    test "X3h the pair on a SERVICE_TASK without consent is ledger_on_service_task", %{ctx: ctx} do
      assert [
               {0, :module_writes_ledger_on_service_task},
               {1, :module_writes_ledger_on_service_task}
             ] ==
               refused(ctx, [own(), n_alpha()], node: :service, consent: false)
    end

    test "X3i an edited body refuses both lines with module_write_body_changed", %{ctx: ctx} do
      assert [{0, :module_write_body_changed}, {1, :module_write_body_changed}] ==
               refused(ctx, [own(), n_alpha()], tamper: true)
    end

    test "X3j a copy without a stamp refuses both lines with module_write_stamp_missing", %{
      ctx: ctx
    } do
      assert [{0, :module_write_stamp_missing}, {1, :module_write_stamp_missing}] ==
               refused(ctx, [own(), n_alpha()], stamp: :none)
    end

    test "X3k a refusal activates nothing", %{ctx: ctx} do
      active = fn ->
        Repo.aggregate(from(d in ProcessDefinition, where: d.status == :active), :count,
          prefix: ctx.schema
        )
      end

      before = active.()
      refused(ctx, [n_alpha()])
      assert active.() == before
    end
  end

  describe "X4 run time" do
    defp entries(schema) do
      %{rows: rows} =
        Repo.query!(
          ~s|SELECT ledger_id, document_type, document_id, posting_seq FROM "#{schema}"."ledger_entry" ORDER BY ledger_id|
        )

      rows
    end

    defp notes(schema) do
      for table <- ~w(fxlp_note fxxp_note) do
        %{rows: [[n]]} =
          Repo.query!(
            ~s|SELECT count(*) FROM "#{schema}"."entity_record_latest" WHERE entity_type = '#{table}'|
          )

        n
      end
    end

    defp pair, do: [own(), n_alpha()]

    test "X4a completion commits both postings in one transaction under their own ledger ids" do
      ctx = X.case!("x4a", pair())
      assert {:ok, _} = X.complete(ctx)
      assert {2, 2, 2, 2} = X.ledger_counts(ctx.schema)

      assert [
               ["fixture_ledger_post", "doc", "d1", 1],
               ["fixture_xpost_owner", "doc", "d1", 1]
             ] = entries(ctx.schema)
    end

    test "X4b a holder of M's post permission only gets N's refusal and nothing commits" do
      ctx = X.case!("x4b", pair(), holder_roles: ["TASK_WORKER"])
      result = X.complete(ctx)
      # The refusal is the opaque write refusal of line 1 (N's posting): line 0 (M's) passed.
      assert {:error, {:entity_write_refused, 1, :write_not_permitted}} = result
      assert {0, 0, 0, 0} = X.ledger_counts(ctx.schema)
      assert [0, 0] = notes(ctx.schema)
    end

    test "X4c a refused posting of N (insufficient balance) commits neither" do
      issue = X.n_line(X.posting("issue", "b", "-3", doc()))
      ctx = X.case!("x4c", [own(), issue])
      result = X.complete(ctx)
      refute match?({:ok, _}, result)
      assert inspect(result) =~ "insufficient_balance"
      assert {0, 0, 0, 0} = X.ledger_counts(ctx.schema)
      assert [0, 0] = notes(ctx.schema)
    end

    test "X4d N re-hashed between activation and completion is refused, nothing written" do
      ctx = X.case!("x4d", pair())
      set_n!(ctx.schema, manifest_hash: String.duplicate("e", 64))
      result = X.complete(ctx)
      # owner_recheck of N's line fails (hash_mismatch is mapped to the opaque write refusal).
      assert {:error, {:entity_write_refused, 1, :write_not_permitted}} = result
      assert {0, 0, 0, 0} = X.ledger_counts(ctx.schema)
      assert [0, 0] = notes(ctx.schema)
    end

    test "X4e INV-10: another tenant's principal cannot complete this tenant's task" do
      a = X.case!("x4ea", pair())
      b = X.case!("x4eb", pair())

      result =
        Letflow.Engine.complete_task(
          a.task.id,
          %{
            output_variables: %{},
            actor_id: b.completer.id,
            idempotency_key: Letflow.EntityWritesFixture.unique("x4e")
          },
          prefix: b.schema,
          credential: :oidc
        )

      refute match?({:ok, _}, result)
      assert {0, 0, 0, 0} = X.ledger_counts(a.schema)
      assert {0, 0, 0, 0} = X.ledger_counts(b.schema)
    end
  end

  describe "X5 files the change leaves alone" do
    test "X5 ModuleWrites names no ledger module" do
      source = File.read!("lib/letflow/definitions/module_writes.ex")
      refute source =~ "Letflow.Ledger"
    end
  end
end
