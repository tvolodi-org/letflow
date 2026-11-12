Code.require_file("../../modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.Proof.MesP1.HashUpgradeTest do
  @moduledoc """
  MES PROOF P1 (T-1829), REMOVABLE: H1..H3 and U1a..U4 of the design. The manifest hash of the COPY against the real
  stock manifest, and what the real upgrade chain (U1 plan, U2 apply, rollback, 409 `upgrade_required`) does with a
  tenant whose installed stock row looks like it was built from the copy. The catalog is compile-time, so the copy cannot
  be handed to the real code; the installed row is aged to the copy's hash instead (the technique of
  `stock/upgrade_http_test.exs`). Committed tenant, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.LedgerRegistration
  alias Letflow.Modules.ManifestHash
  alias Letflow.Modules.Stock
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Proof.MesP1.StockCopy
  alias Letflow.Repo
  alias Letflow.StockPostingFixture, as: P

  @why "T-1829 proof: apply"

  # ── H: the manifest hash (pure) ───────────────────────────────────────────────────────

  describe "the manifest hash" do
    test "H1 the copy has another hash than the real stock manifest" do
      real = ManifestHash.compute(Stock.manifest())
      copy = ManifestHash.compute(StockCopy.manifest())
      assert real != copy
    end

    test "H2 which parts of the change move the hash" do
      real = ManifestHash.compute(Stock.manifest())

      moved =
        for part <- [:version, :policy, :causes, :guard, :all], into: %{} do
          {part, ManifestHash.compute(StockCopy.manifest_variant(part)) != real}
        end

      assert Enum.all?(moved, fn {_part, moves?} -> moves? end)

      # the same manifest hashes the same (a policy body edit with the registration map unchanged cannot move it)
      assert ManifestHash.compute(Stock.manifest()) == real
    end

    test "H3 the copy passes the ledger registration rules (rule 18: nested policy and guard)" do
      manifest = StockCopy.manifest()
      result = LedgerRegistration.validate(manifest, [manifest], StockCopy)
      assert result == :ok

      # the real stock manifest under its own entry module still passes
      real = Stock.manifest()
      assert LedgerRegistration.validate(real, [real], Stock) == :ok
    end
  end

  # ── U: the real upgrade chain on a tenant that looks built from the copy ──────────────

  describe "a tenant whose stock row carries the copy's hash" do
    setup do
      ctx = P.setup!([:a])
      {:ok, entry} = Catalog.fetch("stock")
      {:ok, hash} = Catalog.manifest_hash("stock")

      Map.merge(ctx, %{
        compiled_version: entry.manifest().version,
        compiled_hash: hash,
        copy_hash: ManifestHash.compute(StockCopy.manifest())
      })
    end

    defp post_json(path, tok, body) do
      Plug.Test.conn(:post, path, Jason.encode!(body))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Letflow.Router.call(Letflow.Router.init([]))
    end

    defp plan(tok, module \\ "stock"),
      do: post_json("/api/v1/tenant/modules/#{module}/upgrade/plan", tok, %{})

    defp upgrade(tok, plan_hash),
      do:
        post_json("/api/v1/tenant/modules/stock/upgrade", tok, %{
          "plan_hash" => plan_hash,
          "rationale" => @why
        })

    defp rollback(tok, target, extra \\ %{}),
      do:
        post_json(
          "/api/v1/tenant/modules/stock/rollback",
          tok,
          Map.merge(
            %{"rationale" => "T-1829 proof: roll back", "target_version" => target},
            extra
          )
        )

    defp body(conn), do: Jason.decode!(conn.resp_body)

    defp age!(schema, version, hash) do
      {1, _} =
        Repo.update_all(
          from(m in TenantModule, where: m.module_id == "stock"),
          [set: [version: version, manifest_hash: hash]],
          prefix: schema
        )

      Repo.query!(~s(ALTER TABLE "#{schema}"."process_definitions" DISABLE TRIGGER USER))

      try do
        {n, _} =
          Repo.update_all(
            from(d in ProcessDefinition, where: not is_nil(d.owner_manifest_hash)),
            [set: [owner_manifest_hash: hash]],
            prefix: schema
          )

        assert n >= 1
      after
        Repo.query!(~s(ALTER TABLE "#{schema}"."process_definitions" ENABLE TRIGGER USER))
      end
    end

    defp row(schema, module \\ "stock"),
      do: Repo.get_by!(TenantModule, [module_id: module], prefix: schema)

    defp other_rows(schema) do
      Repo.all(
        from(m in TenantModule, where: m.module_id != "stock", order_by: m.module_id),
        prefix: schema
      )
      |> Enum.map(&{&1.module_id, &1.version, &1.manifest_hash})
    end

    defp journal(schema, kind, state),
      do:
        Repo.all(from(u in TenantModuleUpgrade, where: u.kind == ^kind and u.state == ^state),
          prefix: schema
        )

    defp audit_count(schema, action) do
      %{rows: [[n]]} =
        Repo.query!(~s|SELECT count(*) FROM "#{schema}".audit_entries WHERE action = $1|, [action])

      n
    end

    @plan_keys ~w(up_to_date from_version to_version steps missing_ledger_storage information
                  fits_one_transaction upgrade_path_available path_error)

    defp observe(label, conn) do
      b = body(conn)
      shown = Map.take(b, @plan_keys ++ ["code", "state"])
      assert is_map(shown), label
      b
    end

    test "U1a the hash alone differs, the version is the compiled one", ctx do
      age!(ctx.schema, ctx.compiled_version, ctx.copy_hash)
      report = observe("U1a plan", plan(ctx.tok_a))
      assert report["up_to_date"] == false

      assert {report["from_version"], report["to_version"]} ==
               {ctx.compiled_version, ctx.compiled_version}

      assert report["steps"] == []
      assert is_binary(report["plan_hash"])
      assert row(ctx.schema).manifest_hash == ctx.copy_hash
    end

    test "U1b U2 U3 the older version plans, applies, and the other modules stay as they were",
         ctx do
      doc = P.issue!(ctx)
      task = P.pending_task(ctx, doc["id"], "post")
      age!(ctx.schema, "0.16.0", ctx.copy_hash)
      others = other_rows(ctx.schema)

      # U3a: while drifted, the posting task is refused with upgrade_required and nothing is posted
      assert {:error, :module_upgrade_required} = P.complete(ctx, task)
      assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}

      # U3b: another installed module is not drifted: its own plan says up to date
      org = observe("U3b plan org", plan(ctx.tok_a, "org"))
      assert org["up_to_date"] == true

      # U1b: the plan
      report = observe("U1b plan", plan(ctx.tok_a))
      assert report["up_to_date"] == false
      assert report["from_version"] == "0.16.0"
      assert report["to_version"] == ctx.compiled_version
      assert report["steps"] == []

      # U2: apply
      applied = observe("U2 apply", upgrade(ctx.tok_a, report["plan_hash"]))
      assert %{"state" => "done"} = applied
      assert row(ctx.schema).version == ctx.compiled_version
      assert row(ctx.schema).manifest_hash == ctx.compiled_hash
      assert row(ctx.schema).accepted_manifest_hashes == [ctx.copy_hash]
      assert [_one] = journal(ctx.schema, :upgrade, :done)
      assert audit_count(ctx.schema, "module.upgrade") == 1
      assert other_rows(ctx.schema) == others

      assert plan(ctx.tok_a) |> body() |> Map.fetch!("up_to_date") == true

      # U3a after: the same task now completes
      assert {:ok, _} = P.complete(ctx, task)
      assert P.counts(ctx, doc["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
    end

    test "U4 the upgrade is rolled back to the previous stamp", ctx do
      age!(ctx.schema, "0.16.0", ctx.copy_hash)
      report = plan(ctx.tok_a) |> body()
      assert %{"state" => "done"} = upgrade(ctx.tok_a, report["plan_hash"]) |> body()

      dry = observe("U4 dry", rollback(ctx.tok_a, "0.16.0", %{"dry_run" => true}))
      assert dry["rollback_possible"] == true

      done = observe("U4 rollback", rollback(ctx.tok_a, "0.16.0"))
      assert %{"state" => "done", "rollback_possible" => true} = done
      assert row(ctx.schema).version == "0.16.0"
      assert row(ctx.schema).manifest_hash == ctx.copy_hash
      assert [_one] = journal(ctx.schema, :rollback, :done)
      assert audit_count(ctx.schema, "module.rollback") == 1
    end
  end
end
