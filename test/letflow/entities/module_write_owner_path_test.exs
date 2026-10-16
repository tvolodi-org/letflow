defmodule Letflow.Entities.ModuleWriteOwnerPathTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4a (design `lib/letflow/design/gh2590-req501-module-write-handlers.md`
  sections 4.4, 4.6, 6.1, 7, 8, 11 rows "Owner path", "A handler cannot widen privilege",
  "No I/O", "Audit and event shape", "Idempotency key"): the write path BELOW the engine.
  `HandlerWrites.build_call/4` and `create/3` run inside a plain `Repo.transaction/1` here; no
  engine step exists yet (R4b), so these tests build the Multi themselves.

  The tenant has `fixture_ledger` INSTALLED (its `on_install/3` activates the managed types
  `fxl_ledger`, `fxl_balance`) and, per test, `fixture_ledger_rogue` where a misbehaving
  handler is needed. `async: false`: the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Multi
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.HandlerContext
  alias Letflow.Entities.HandlerWrites
  alias Letflow.Entities.Records
  alias Letflow.Entities.StepSource
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.ModuleWritesFixture, as: Mw

  setup do
    base = Mw.tenant!("gh2590-r4a-op")

    for type <- ["fxl_ledger", "fxl_balance"],
        do: {:ok, _} = EntityTypeInstance.get_or_create(type, base.schema)

    {:ok, hash} = Catalog.manifest_hash("fixture_ledger")
    task = Ecto.UUID.generate()

    attrs = %{
      prefix: base.schema,
      instance_id: Ecto.UUID.generate(),
      origin: {:task, task},
      node_id: "ht",
      definition_id: Ecto.UUID.generate(),
      definition_version: "1.0.0",
      line_index: 0,
      actor_id: base.user.id,
      activator_id: base.user.id,
      manifest_hash: hash
    }

    Map.merge(base, %{attrs: attrs, task: task, hash: hash})
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp line(handler, args, module \\ "fixture_ledger"),
    do: %{"module" => module, "handler" => handler, "args" => args}

  defp entry_line,
    do: line("post_entry", %{"item" => %{"var" => "label"}, "quantity" => %{"const" => 3}})

  defp run(ctx, line, variables \\ %{"label" => "L1"}, attrs_override \\ %{}) do
    ctx.attrs
    |> Map.merge(attrs_override)
    |> then(&HandlerWrites.build_call(Multi.new(), &1, line, variables))
    |> Repo.transaction()
  end

  defp context(ctx, handler \\ "post_entry", overrides \\ %{}) do
    {:ok, registered} = Catalog.write_handler("fixture_ledger", handler)
    a = ctx.attrs

    base = %HandlerContext{
      prefix: a.prefix,
      instance_id: a.instance_id,
      origin: a.origin,
      node_id: a.node_id,
      definition_id: a.definition_id,
      definition_version: a.definition_version,
      line_index: a.line_index,
      actor_id: a.actor_id,
      subject_id: a.actor_id,
      activator_id: a.activator_id,
      handler: %{module_id: "fixture_ledger", name: handler, targets: registered.targets}
    }

    context = struct!(base, overrides)

    # The per-call token the platform sets around a handler call (see HandlerWrites): a test that
    # calls create/3 directly plays the platform and sets it for the context it built.
    Process.put({HandlerWrites, :call}, %{ctx: context, produced: []})
    context
  end

  defp written(ctx) do
    {length(Fx.all_records(ctx.schema)), length(Fx.entity_events(ctx.schema)),
     Fx.step_idempotency_count(ctx.schema)}
  end

  defp step_keys(ctx) do
    from(i in "event_idempotency",
      where: like(i.idempotency_key, "sys:step:%"),
      select: i.idempotency_key
    )
    |> Repo.all(prefix: ctx.schema)
    |> Enum.sort()
  end

  defp create_command(type, values), do: %{entity_type: type, field_values: values}

  # ── the happy path and its provenance ───────────────────────────────────────────────────────

  describe "a registered handler writes its module's managed types" do
    test "post_entry writes both targets; keys, metadata, actor and step names are exact", ctx do
      assert {:ok, changes} = run(ctx, entry_line())

      assert [ledger] = Fx.records(ctx.schema, "fxl_ledger")
      assert [balance] = Fx.records(ctx.schema, "fxl_balance")
      assert ledger.record_id != balance.record_id

      events = Fx.entity_events(ctx.schema)
      assert length(events) == 2
      by_ordinal = Enum.sort_by(events, & &1.metadata["source.write_ordinal"])

      for {event, ordinal} <- Enum.zip(by_ordinal, ["1", "2"]) do
        assert event.actor_id == ctx.user.id

        assert event.metadata == %{
                 "source.kind" => "process_step",
                 "source.instance_id" => ctx.attrs.instance_id,
                 "source.task_id" => ctx.task,
                 "source.node_id" => "ht",
                 "source.definition_id" => ctx.attrs.definition_id,
                 "source.definition_version" => "1.0.0",
                 "source.line_index" => "0",
                 "source.activator_id" => ctx.user.id,
                 "source.handler_module" => "fixture_ledger",
                 "source.handler_name" => "post_entry",
                 "source.write_ordinal" => ordinal
               }
      end

      assert step_keys(ctx) == ["sys:step:#{ctx.task}:0:1", "sys:step:#{ctx.task}:0:2"]

      # call-level steps use ordinal 0 (key 20), the writes keys 21 and 22
      assert Map.has_key?(changes, {:line, 20, :owner_recheck})
      assert Map.has_key?(changes, {:line, 21, :policy})
      assert Map.has_key?(changes, {:line, 22, :policy})
      refute Enum.any?(Map.keys(changes), &match?({:line, key, _} when key < 20, &1))
    end

    test "a later declared line index shifts the whole key range", ctx do
      assert {:ok, changes} = run(ctx, entry_line(), %{"label" => "L2"}, %{line_index: 3})

      # 20 + 3 * 50 = 170
      assert Map.has_key?(changes, {:line, 170, :owner_recheck})
      assert Map.has_key?(changes, {:line, 171, :policy})
      assert Map.has_key?(changes, {:line, 172, :policy})
      assert step_keys(ctx) == ["sys:step:#{ctx.task}:3:1", "sys:step:#{ctx.task}:3:2"]
    end

    test "post_balance_only writes only fxl_balance", ctx do
      line = line("post_balance_only", %{"item" => %{"const" => "only"}})
      assert {:ok, _changes} = run(ctx, line)
      assert length(Fx.records(ctx.schema, "fxl_balance")) == 1
      assert Fx.records(ctx.schema, "fxl_ledger") == []
    end

    test "a second run of the same call is idempotency_conflict and rolls back (T-4)", ctx do
      assert {:ok, _} = run(ctx, entry_line())
      before = written(ctx)

      assert {:error, {:line, 21, step}, reason, _changes} = run(ctx, entry_line())

      assert Records.interpret_in_multi({:error, {:line, 21, step}, reason, %{}}) ==
               {:entity_write_refused, 21, :idempotency_conflict}

      assert written(ctx) == before
    end
  end

  # ── the owner path: who may write a managed type ────────────────────────────────────────────

  describe "the Owner is derived by the platform" do
    test "a declarative (:tenant) caller and a plain core caller are refused on a managed type",
         ctx do
      {:ok, source} =
        StepSource.new(%{
          instance_id: ctx.attrs.instance_id,
          task_id: ctx.task,
          node_id: "ht",
          definition_id: ctx.attrs.definition_id,
          definition_version: "1.0.0",
          line_index: 0,
          activator_id: ctx.user.id
        })

      command = %{
        kind: :create,
        entity_type: "fxl_balance",
        field_values: %{"item" => "x"},
        actor_id: ctx.user.id,
        source: source
      }

      assert {:error, :entity_type_managed} = Records.command_multi(command, ctx.schema, :tenant)
      assert written(ctx) == {0, 0, 0}
    end

    test "create/3 refuses an unmanaged type, another module's type and an unknown type", ctx do
      multi = Multi.new()

      for type <- ["stock_move", "fxo_other", "no_such_type"] do
        assert HandlerWrites.create(multi, context(ctx), create_command(type, %{"item" => "x"})) ==
                 {:error, :target_not_registered},
               type
      end
    end

    test "a handler of another module cannot write fxl_ledger, even with a forged context", ctx do
      # post_balance_only's context widened to a type outside its registered targets: the Owner
      # re-derived from the Catalog is narrowed to fxl_balance
      widened =
        context(ctx, "post_balance_only", %{
          handler: %{
            module_id: "fixture_ledger",
            name: "post_balance_only",
            targets: ["fxl_balance", "fxl_ledger"]
          }
        })

      assert HandlerWrites.create(
               Multi.new(),
               widened,
               create_command("fxl_ledger", %{"item" => "x"})
             ) == {:error, :target_not_registered}

      # a context naming ANOTHER module's handler and claiming fxl_ledger as a target
      forged =
        context(ctx, "post_entry", %{
          handler: %{
            module_id: "fixture_ledger_other",
            name: "post_other",
            targets: ["fxl_ledger"]
          }
        })

      assert HandlerWrites.create(
               Multi.new(),
               forged,
               create_command("fxl_ledger", %{"item" => "x"})
             ) == {:error, :target_not_registered}

      # a context naming an unknown handler fails closed the same way
      ghost =
        context(ctx, "post_entry", %{
          handler: %{module_id: "fixture_ledger", name: "ghost", targets: ["fxl_ledger"]}
        })

      assert HandlerWrites.create(Multi.new(), ghost, create_command("fxl_ledger", %{})) ==
               {:error, :target_not_registered}

      assert written(ctx) == {0, 0, 0}
    end

    test "a malformed context or command is :invalid_write_command, never a raise", ctx do
      multi = Multi.new()
      good = create_command("fxl_balance", %{"item" => "x"})

      assert HandlerWrites.create(multi, %{}, good) == {:error, :invalid_write_command}
      assert HandlerWrites.create(multi, context(ctx), %{}) == {:error, :invalid_write_command}

      for bad <- [
            Map.put(good, :record_id, "x"),
            Map.put(good, :idempotency_key, "sys:step:x"),
            %{good | entity_type: :fxl_balance},
            %{good | field_values: [{"item", "x"}]},
            Map.delete(good, :field_values)
          ] do
        assert HandlerWrites.create(multi, context(ctx), bad) == {:error, :invalid_write_command},
               inspect(bad)
      end

      assert HandlerWrites.create(
               multi,
               context(ctx, "post_entry", %{origin: {:nope, "x"}}),
               good
             ) ==
               {:error, :invalid_write_command}
    end

    test "a context that is not the one built for the running call is refused (S1)", ctx do
      good = context(ctx)
      command = create_command("fxl_balance", %{"item" => "x"})

      assert {:ok, _} = HandlerWrites.create(Multi.new(), good, command)

      # a forged copy: any changed field, including the tenant prefix and the handler
      for forged <- [
            %{good | prefix: "tenant_other"},
            %{good | actor_id: Ecto.UUID.generate()},
            %{good | line_index: 1},
            %{
              good
              | handler: %{
                  module_id: "fixture_ledger",
                  name: "post_entry",
                  targets: ["fxl_ledger"]
                }
            }
          ] do
        assert HandlerWrites.create(Multi.new(), forged, command) ==
                 {:error, :invalid_write_command},
               inspect(forged)
      end

      # outside a handler call there is no token at all
      Process.delete({HandlerWrites, :call})
      assert HandlerWrites.create(Multi.new(), good, command) == {:error, :invalid_write_command}
    end

    test "scoped type: the :policy step refuses it and nothing is written (T3)", ctx do
      Repo.query!(~s(ALTER TABLE "#{ctx.schema}".entity_definitions DISABLE TRIGGER USER))

      Repo.query!(
        ~s(UPDATE "#{ctx.schema}".entity_definitions SET definition_json = definition_json || '{"scoped": true}'::jsonb WHERE name = 'fxl_balance')
      )

      previous = Application.get_env(:letflow, :entity_writes_scope_keys)
      Application.put_env(:letflow, :entity_writes_scope_keys, ["scoped"])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:letflow, :entity_writes_scope_keys, previous),
          else: Application.delete_env(:letflow, :entity_writes_scope_keys)
      end)

      assert {:ok, multi} =
               HandlerWrites.create(
                 Multi.new(),
                 context(ctx, "post_balance_only"),
                 create_command("fxl_balance", %{"item" => "x"})
               )

      assert {:error, {:line, 21, :policy}, :scoped_type, _} = Repo.transaction(multi)
      assert written(ctx) == {0, 0, 0}
    end

    test "the 50th create in one call is :too_many_writes; the 49 before it are accepted", ctx do
      ctx_balance = context(ctx, "post_balance_only")

      {multi, count} =
        Enum.reduce(1..49, {Multi.new(), 0}, fn n, {multi, count} ->
          assert {:ok, multi} =
                   HandlerWrites.create(
                     multi,
                     ctx_balance,
                     create_command("fxl_balance", %{"item" => "i#{n}"})
                   )

          {multi, count + 1}
        end)

      assert count == 49

      assert HandlerWrites.create(
               multi,
               ctx_balance,
               create_command("fxl_balance", %{"item" => "one too many"})
             ) == {:error, :too_many_writes}
    end
  end

  # ── a handler cannot widen privilege (F-2, F-7, restrictions, validity) ─────────────────────

  describe "the writer's own checks" do
    test "a restricted field of the subject is refused and nothing is written", ctx do
      Repo.insert_all(
        "entity_field_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: "fxl_balance",
            field_name: "quantity",
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )

      assert {:ok, multi} =
               HandlerWrites.create(
                 Multi.new(),
                 context(ctx, "post_balance_only"),
                 create_command("fxl_balance", %{"item" => "x", "quantity" => 5})
               )

      assert {:error, {:line, 21, :build}, :field_restricted, _} = Repo.transaction(multi)
      assert written(ctx) == {0, 0, 0}

      # the unrestricted field of the same type is accepted
      assert {:ok, multi} =
               HandlerWrites.create(
                 Multi.new(),
                 context(ctx, "post_balance_only"),
                 create_command("fxl_balance", %{"item" => "x"})
               )

      assert {:ok, _} = Repo.transaction(multi)
    end

    test "invalid field values fail the transaction with the payload reason", ctx do
      assert {:ok, multi} =
               HandlerWrites.create(
                 Multi.new(),
                 context(ctx, "post_balance_only"),
                 create_command("fxl_balance", %{"item" => 5})
               )

      assert {:error, {:line, 21, :build}, {:record_payload_invalid, _}, _} =
               Repo.transaction(multi)

      assert written(ctx) == {0, 0, 0}
    end

    test "F-7: a registered target whose tenant row is not managed by the module is refused",
         ctx do
      # The manifest names the type; the tenant row is what the :policy step re-reads under the
      # sequence lock. The managed_by immutability trigger is disabled in THIS test's own
      # tenant schema (one fresh tenant per test, rolled back with the sandbox); it is not
      # re-enabled and no other test shares the schema.
      Repo.query!(~s(ALTER TABLE "#{ctx.schema}".entity_definitions DISABLE TRIGGER USER))

      Repo.query!(
        ~s(UPDATE "#{ctx.schema}".entity_definitions SET managed_by = NULL WHERE name = 'fxl_balance')
      )

      assert {:ok, multi} =
               HandlerWrites.create(
                 Multi.new(),
                 context(ctx, "post_balance_only"),
                 create_command("fxl_balance", %{"item" => "x"})
               )

      assert {:error, {:line, 21, :policy}, :target_not_managed_by_module, _} =
               Repo.transaction(multi)

      assert written(ctx) == {0, 0, 0}

      # ... and another module's stamp is refused the same way
      Repo.query!(
        ~s(UPDATE "#{ctx.schema}".entity_definitions SET managed_by = 'fixture_ledger_other' WHERE name = 'fxl_balance')
      )

      assert {:ok, multi} =
               HandlerWrites.create(
                 Multi.new(),
                 context(ctx, "post_balance_only"),
                 create_command("fxl_balance", %{"item" => "x"})
               )

      # the managed type of ANOTHER module is refused already by Records (Owner mismatch)
      assert {:error, {:line, 21, :build}, :entity_type_managed, _} = Repo.transaction(multi)
      assert written(ctx) == {0, 0, 0}
    end
  end

  # ── build_call/4: the run-time recheck, arguments and the handler's return ──────────────────

  describe "build_call/4" do
    test "the install row and both hashes are re-verified at execution time, with no lock",
         ctx do
      # a stamp hash that is not the compiled one
      assert {:error, {:line, 20, :owner_recheck}, :hash_mismatch, _} =
               run(ctx, entry_line(), %{"label" => "L"}, %{
                 manifest_hash: String.duplicate("a", 64)
               })

      # the install row's recorded hash tampered with after activation
      Repo.query!(
        ~s(UPDATE "#{ctx.schema}".tenant_modules SET manifest_hash = '#{String.duplicate("b", 64)}' WHERE module_id = 'fixture_ledger')
      )

      assert {:error, {:line, 20, :owner_recheck}, :hash_mismatch, _} = run(ctx, entry_line())

      # installed == stamp but != compiled: the stamp is passed as the tampered install hash, so
      # only the installed-vs-compiled conjunct can refuse
      tampered = String.duplicate("b", 64)

      assert {:error, {:line, 20, :owner_recheck}, :hash_mismatch, _} =
               run(ctx, entry_line(), %{"label" => "L"}, %{manifest_hash: tampered})

      # no recorded hash at all (a pre-R2 install)
      Repo.query!(
        ~s(UPDATE "#{ctx.schema}".tenant_modules SET manifest_hash = NULL WHERE module_id = 'fixture_ledger')
      )

      assert {:error, {:line, 20, :owner_recheck}, :hash_mismatch, _} = run(ctx, entry_line())

      # the module is no longer installed
      Repo.query!(
        ~s(DELETE FROM "#{ctx.schema}".tenant_modules WHERE module_id = 'fixture_ledger')
      )

      assert {:error, {:line, 20, :owner_recheck}, :hash_mismatch, _} = run(ctx, entry_line())

      assert written(ctx) == {0, 0, 0}
    end

    test "an unknown handler, a foreign module and a line without a module fail closed", ctx do
      assert {:error, {:line, 20, :build}, :handler_unknown, _} =
               run(ctx, line("ghost", %{}))

      # a line with a module (matching hash) but no handler name resolves to nothing
      assert {:error, {:line, 20, :build}, :handler_unknown, _} =
               run(ctx, %{"module" => "fixture_ledger"})

      # the handler exists, but under a module the stamp's hash does not describe: the recheck
      # refuses it first (fixture_ledger_other is not installed)
      assert {:error, {:line, 20, :owner_recheck}, :hash_mismatch, _} =
               run(ctx, line("post_other", %{}, "fixture_ledger_other"))

      assert {:error, {:line, 20, :owner_recheck}, :hash_mismatch, _} = run(ctx, %{})
      assert written(ctx) == {0, 0, 0}
    end

    test "arguments are checked against the CURRENT registration; `_sys` never resolves", ctx do
      # undeclared name
      assert {:error, {:line, 20, :build}, :handler_invalid_arguments, _} =
               run(
                 ctx,
                 line("post_entry", %{
                   "item" => %{"const" => "a"},
                   "quantity" => %{"const" => 1},
                   "extra" => %{"const" => 1}
                 })
               )

      # required argument missing
      assert {:error, {:line, 20, :build}, :handler_invalid_arguments, _} =
               run(ctx, line("post_entry", %{"item" => %{"const" => "a"}}))

      # a var absent from the variables resolves to nothing, so the required arg is missing
      assert {:error, {:line, 20, :build}, :handler_invalid_arguments, _} =
               run(ctx, entry_line(), %{})

      # a reserved `_sys` var is never read
      sys_line =
        line("post_entry", %{"item" => %{"var" => "_sys.r"}, "quantity" => %{"const" => 1}})

      assert {:error, {:line, 20, :build}, :handler_invalid_arguments, _} =
               run(ctx, sys_line, %{"_sys.r" => "secret"})

      # the handler's own validation (quantity must be an integer)
      bad_type =
        line("post_entry", %{"item" => %{"const" => "a"}, "quantity" => %{"const" => "1"}})

      assert {:error, {:line, 20, :build}, :handler_invalid_arguments, _} = run(ctx, bad_type)

      assert written(ctx) == {0, 0, 0}
    end

    test "lock_types/3 appends ascending type locks that really lock; a missing instance fails",
         ctx do
      multi =
        HandlerWrites.lock_types(
          Multi.new(),
          ["fxl_ledger", "fxl_balance", "fxl_ledger"],
          ctx.schema
        )

      assert Enum.map(Multi.to_list(multi), &elem(&1, 0)) ==
               [{:type_lock, "fxl_balance"}, {:type_lock, "fxl_ledger"}]

      assert {:ok,
              %{{:type_lock, "fxl_balance"} => :locked, {:type_lock, "fxl_ledger"} => :locked}} =
               Repo.transaction(multi)

      missing = HandlerWrites.lock_types(Multi.new(), ["no_such_type"], ctx.schema)

      assert {:error, {:type_lock, "no_such_type"},
              {:entity_type_instance_missing, "no_such_type"}, _} = Repo.transaction(missing)
    end
  end

  # ── R4b platform helpers: targets and run-time authorization ────────────────────────────────

  describe "registered_targets/1, prepare_targets/2, authorize_module_writes/2" do
    test "registered_targets/1 resolves through the Catalog and ignores what it cannot resolve" do
      assert HandlerWrites.registered_targets([
               line("post_entry", %{}),
               line("post_balance_only", %{}),
               line("ghost", %{}),
               %{"nothing" => 1}
             ]) == ["fxl_balance", "fxl_ledger"]

      assert HandlerWrites.registered_targets([]) == []
    end

    test "prepare_targets/2 keeps only targets whose CURRENT row is managed by the module", ctx do
      assert HandlerWrites.prepare_targets([line("post_entry", %{})], ctx.schema) ==
               ["fxl_balance", "fxl_ledger"]

      # a target whose active row is absent (the rogue module is not installed here)
      assert HandlerWrites.prepare_targets(
               [line("denies", %{}, "fixture_ledger_rogue")],
               ctx.schema
             ) == []

      assert HandlerWrites.prepare_targets([line("ghost", %{})], ctx.schema) == []
    end

    test "authorize_module_writes/2 refuses a missing stamp with the declared index", ctx do
      assert {:error, {0, :stamp_missing}} =
               HandlerWrites.authorize_module_writes([entry_line()], %{
                 prefix: ctx.schema,
                 owner: nil,
                 snapshot_graph: %{"nodes" => [], "edges" => []}
               })

      assert {:error, {3, :stamp_missing}} =
               HandlerWrites.authorize_module_writes([entry_line()], %{
                 prefix: ctx.schema,
                 owner: nil,
                 snapshot_graph: %{"nodes" => [], "edges" => []},
                 entity_write_count: 3
               })
    end
  end

  # ── a misbehaving handler (negative control module) ─────────────────────────────────────────

  describe "a misbehaving handler is contained" do
    setup ctx do
      {:ok, _} =
        Installs.install("fixture_ledger_rogue", Ecto.UUID.generate(),
          prefix: ctx.schema,
          rationale: "GH 2590 R4a rogue"
        )

      {:ok, _} = EntityTypeInstance.get_or_create("fxr_thing", ctx.schema)
      {:ok, rogue_hash} = Catalog.manifest_hash("fixture_ledger_rogue")
      %{rogue_attrs: %{manifest_hash: rogue_hash}}
    end

    defp rogue(ctx, handler),
      do: run(ctx, line(handler, %{}, "fixture_ledger_rogue"), %{}, ctx.rogue_attrs)

    test "a non-Multi return, an out-of-range step name and a loose step are :handler_shape",
         ctx do
      for handler <- ["bad_return", "out_of_range_step", "loose_step"] do
        assert {:error, {:line, 20, :build}, :handler_shape, _} = rogue(ctx, handler), handler
      end

      assert written(ctx) == {0, 0, 0}
    end

    test "a handler that raises is reduced to :handler_raised; only ids are logged", ctx do
      log =
        capture_log(fn ->
          assert {:error, {:line, 20, :build}, :handler_raised, _} = rogue(ctx, "raises")
        end)

      assert log =~ "fixture_ledger_rogue"
      assert log =~ "raises"
      assert log =~ "RuntimeError"
      refute log =~ "secret detail"
    end

    test "a throw and an exit are reduced to :handler_raised, like a raise (SECURITY re-review)",
         ctx do
      for handler <- ["throws", "exits"] do
        log =
          capture_log(fn ->
            assert {:error, {:line, 20, :build}, :handler_raised, _} = rogue(ctx, handler)
          end)

        assert log =~ "fixture_ledger_rogue"
      end

      assert written(ctx) == {0, 0, 0}
    end

    test "a handler that keeps a write's steps but drops its :policy step is :handler_shape",
         ctx do
      # create/3 produced [..., {:line, 21, :policy}]; the returned Multi lacks the last one
      assert {:error, {:line, 20, :build}, :handler_shape, _} = rogue(ctx, "drop_policy")
      assert Fx.records(ctx.schema, "fxr_thing") == []
      assert written(ctx) == {0, 0, 0}
    end

    test "the handler's closed error atoms map to build reasons", ctx do
      assert {:error, {:line, 20, :build}, :handler_not_permitted, _} = rogue(ctx, "denies")
      assert {:error, {:line, 20, :build}, :handler_invalid_arguments, _} = rogue(ctx, "invalid")
    end

    test "S1: a forged context (prefix, handler) is refused; nothing is written anywhere", ctx do
      # a second tenant where the SAME rogue module is installed: with a trusting create/3 the
      # forged prefix would write there
      other = Mw.tenant!("gh2590-r4a-x")

      {:ok, _} =
        Installs.install("fixture_ledger_rogue", Ecto.UUID.generate(),
          prefix: other.schema,
          rationale: "GH 2590 R4a rogue (second tenant)"
        )

      {:ok, _} = EntityTypeInstance.get_or_create("fxr_thing", other.schema)

      forge_line =
        line("forge_prefix", %{"prefix" => %{"const" => other.schema}}, "fixture_ledger_rogue")

      assert {:error, {:line, 20, :build}, :handler_not_permitted, _} =
               run(ctx, forge_line, %{}, ctx.rogue_attrs)

      assert Fx.records(other.schema, "fxr_thing") == []
      assert Fx.records(ctx.schema, "fxr_thing") == []

      # the forged handler (another module's registration, targeting fxl_ledger)
      assert {:error, {:line, 20, :build}, :handler_not_permitted, _} =
               rogue(ctx, "forge_handler")

      assert Fx.records(ctx.schema, "fxl_ledger") == []
      assert written(ctx) == {0, 0, 0}
    end

    test "S2: a step with a live repo is refused, however Ecto.Multi is named", ctx do
      for handler <- [
            "run_full",
            "run_aliased",
            "run_imported",
            "insert_all_op",
            "run_after_create"
          ] do
        assert {:error, {:line, 20, :build}, :handler_shape, _} = rogue(ctx, handler), handler
      end

      # run_after_create made a legitimate create first: still nothing is committed
      assert Fx.records(ctx.schema, "fxr_thing") == []
      assert written(ctx) == {0, 0, 0}
    end

    test "a handler writing ANOTHER module's managed type is refused by the platform", ctx do
      assert {:error, {:line, 20, :build}, :handler_not_permitted, _} =
               rogue(ctx, "writes_foreign_type")

      assert written(ctx) == {0, 0, 0}
    end
  end

  # ── the API surface ─────────────────────────────────────────────────────────────────────────

  describe "the closed API" do
    test "HandlerWrites exports create/3 for handlers and a closed set of platform functions" do
      public = HandlerWrites.__info__(:functions) |> Enum.sort()

      # R4b adds the run-time authorization and the target resolution the engine's plan needs;
      # handler files may call none of them (scan H4: only `HandlerWrites.create/3`)
      assert public == [
               authorize_module_writes: 2,
               build_call: 4,
               create: 3,
               lock_types: 3,
               prepare_targets: 2,
               registered_targets: 1
             ]
    end

    test "the handler context carries no authority, repo or owner" do
      keys = HandlerContext.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert keys ==
               Enum.sort(~w(prefix instance_id origin node_id definition_id definition_version
                            line_index actor_id subject_id activator_id handler)a)

      refute Enum.any?(keys, &(&1 in [:authority, :owner, :repo, :manifest_hash]))
    end
  end
end
