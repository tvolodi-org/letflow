defmodule Letflow.Entities.HandlerWritesReadTest do
  @moduledoc """
  REQ-829 (decision 0073 D6, OQ-R4): the read facade `HandlerWrites.read/3` and `active?/3`, through
  real HUMAN_TASK completions of the `fixture_ledger_post` handlers `make_note`, `read_probe`,
  `read_maybe` and `post_reading` (their answers are written into a note, so the test reads them
  back from the committed rows).

  Tests: R-3 / R-4 the answers, R-5 the context, R-6 one table, no lock, no write, R-7 the dry
  build, R-8 tenant isolation. The declaration (R-1) and hash (R-2) tests are in
  `test/letflow/modules/write_handler_spec_test.exs`. `async: false`: module installs run DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.HandlerContext
  alias Letflow.Entities.HandlerWrites
  alias Letflow.Entities.Record.Latest
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore
  alias Letflow.LedgerPostFixture, as: PFx
  alias Letflow.Support.PlatformTenantFixture

  defp line(handler, args) do
    %{
      "module" => "fixture_ledger_post",
      "handler" => handler,
      "args" => Map.new(args, fn {name, value} -> {name, %{"const" => value}} end)
    }
  end

  # Creates one note of the tenant through a real completion and returns its record id.
  defp make_note!(ctx, note, active) do
    before = MapSet.new(note_ids(ctx.schema))
    task = PFx.more_task!(ctx, [line("make_note", %{"note" => note, "active" => active})])
    assert {:ok, _} = PFx.complete(task)
    [id] = MapSet.to_list(MapSet.difference(MapSet.new(note_ids(ctx.schema)), before))
    id
  end

  defp note_ids(schema) do
    from(r in Latest, where: r.entity_type == "fxlp_note", select: r.record_id)
    |> Repo.all(prefix: schema)
  end

  # Completes a `read_probe` line and returns the text it wrote into its note.
  defp probe(ctx, type, id) do
    before = MapSet.new(note_ids(ctx.schema))
    task = PFx.more_task!(ctx, [line("read_probe", %{"type" => type, "id" => id})])
    assert {:ok, _} = PFx.complete(task)
    [new] = MapSet.to_list(MapSet.difference(MapSet.new(note_ids(ctx.schema)), before))

    from(r in Latest, where: r.record_id == ^new, select: r.field_values)
    |> Repo.one!(prefix: ctx.schema)
    |> Map.fetch!("note")
  end

  setup do
    ctx = PFx.case!("req829-read", [line("plain", %{"note" => "seed"})])
    {:ok, ctx: ctx}
  end

  describe "R-3 / R-4 read/3 and active?/3 in a real completion" do
    test "a live record of a declared type: the map, and active? by the active field", %{ctx: ctx} do
      on = make_note!(ctx, "alpha", true)
      off = make_note!(ctx, "beta", false)

      assert probe(ctx, "fxlp_note", on) == "ok fxlp_note #{on} alpha active=true"
      assert probe(ctx, "fxlp_note", off) == "ok fxlp_note #{off} beta active=false"
    end

    test "not_found for a non-uuid id, an unknown id, another type and a soft-deleted record",
         %{ctx: ctx} do
      live = make_note!(ctx, "gone", true)

      from(r in Latest, where: r.record_id == ^live)
      |> Repo.update_all([set: [deleted: true]], prefix: ctx.schema)

      miss = "{:error, :not_found} active=false"
      assert probe(ctx, "fxlp_note", "not-a-uuid") == miss
      assert probe(ctx, "fxlp_note", Ecto.UUID.generate()) == miss
      assert probe(ctx, "fxlp_note", live) == miss
    end

    test "a record of another type is not_found, a type outside reads is read_not_registered",
         %{ctx: ctx} do
      other = make_note!(ctx, "typed", true)

      from(r in Latest, where: r.record_id == ^other)
      |> Repo.update_all([set: [entity_type: "fxl_ledger"]], prefix: ctx.schema)

      assert probe(ctx, "fxlp_note", other) == "{:error, :not_found} active=false"
      assert probe(ctx, "fxl_ledger", other) == "{:error, :read_not_registered} active=false"
    end
  end

  describe "R-5 the context" do
    test "no valid per-call token: invalid_write_command and false" do
      ctx = %HandlerContext{
        prefix: "tenant_x",
        instance_id: Ecto.UUID.generate(),
        node_id: "post",
        definition_id: Ecto.UUID.generate(),
        definition_version: "1.0.0",
        actor_id: Ecto.UUID.generate(),
        subject_id: Ecto.UUID.generate(),
        activator_id: Ecto.UUID.generate(),
        origin: {:task, Ecto.UUID.generate()},
        line_index: 0,
        handler: %{module_id: "fixture_ledger_post", name: "read_probe", targets: ["fxlp_note"]}
      }

      id = Ecto.UUID.generate()
      assert HandlerWrites.read(ctx, "fxlp_note", id) == {:error, :invalid_write_command}
      assert HandlerWrites.active?(ctx, "fxlp_note", id) == false

      # a forged token for a different context is refused as well
      Process.put({HandlerWrites, :call}, %{ctx: %{ctx | line_index: 1}, produced: []})
      assert HandlerWrites.read(ctx, "fxlp_note", id) == {:error, :invalid_write_command}
      assert HandlerWrites.read(%{}, "fxlp_note", id) == {:error, :invalid_write_command}
      assert HandlerWrites.read(nil, "fxlp_note", id) == {:error, :invalid_write_command}
      assert HandlerWrites.active?(nil, "fxlp_note", id) == false
    after
      Process.delete({HandlerWrites, :call})
    end
  end

  describe "R-6 no lock, no write, one schema" do
    test "each extra statement of a reading completion is a SELECT on entity_record_latest",
         %{ctx: ctx} do
      id = make_note!(ctx, "q", true)
      with_read = PFx.more_task!(ctx, [line("read_maybe", %{"id" => id, "do_read" => true})])
      without = PFx.more_task!(ctx, [line("read_maybe", %{"id" => id, "do_read" => false})])

      {{:ok, _}, queries_with} =
        PlatformTenantFixture.capture_repo_queries(fn -> PFx.complete(with_read) end)

      {{:ok, _}, queries_without} =
        PlatformTenantFixture.capture_repo_queries(fn -> PFx.complete(without) end)

      sqls = fn queries -> Enum.map(queries, &String.replace(&1.query, ~r/\s+/, " ")) end
      extra = sqls.(queries_with) -- sqls.(queries_without)

      assert extra != []

      for sql <- extra do
        assert sql =~ ~r/^SELECT /
        assert sql =~ ~s("#{ctx.schema}"."entity_record_latest")
        refute sql =~ ~r/FOR (UPDATE|SHARE)/i
        refute sql =~ ~r/ledger_/
        refute sql =~ ~r/INSERT|UPDATE|DELETE/
      end

      # the statements of the reading completion only grow by the read: one extra statement here
      assert length(extra) == 1
    end
  end

  describe "R-7 the dry build" do
    test "read/3 answers dry_build and active?/3 false, with no query", %{ctx: ctx} do
      posting = PFx.posting("receipt", "a", "5")
      line = line("post_reading", %{"posting" => posting})
      task = PFx.more_task!(ctx, [line])

      {:ok, handler} =
        Letflow.Modules.Catalog.write_handler("fixture_ledger_post", "post_reading")

      assert handler.reads == ["fxlp_note"]
      {:ok, hash} = Letflow.Modules.Catalog.manifest_hash("fixture_ledger_post")

      attrs = %{
        prefix: ctx.schema,
        instance_id: task.instance_id,
        origin: {:dispatch, Ecto.UUID.generate()},
        node_id: "svc",
        definition_id: task.definition.id,
        definition_version: task.definition.version,
        line_index: 0,
        actor_id: EventStore.platform_actor_id(),
        subject_id: ctx.completer.id,
        credential: :oidc,
        activator_id: ctx.completer.id,
        manifest_hash: hash,
        variable_labels: %{},
        ledger_consent: true
      }

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          HandlerWrites.dry_postings(attrs, line, %{}, [])
        end)

      assert {:ok, [cap]} = result
      assert is_map(cap.posting)
      assert queries == []
    end
  end

  describe "R-8 tenant isolation (INV-1)" do
    test "a record that exists only in tenant B is not_found in a completion of tenant A",
         %{ctx: ctx} do
      b = PFx.case!("req829-read-b", [line("plain", %{"note" => "seed"})])
      only_b = make_note!(b, "tenant-b-only", true)

      assert probe(b, "fxlp_note", only_b) == "ok fxlp_note #{only_b} tenant-b-only active=true"
      assert probe(ctx, "fxlp_note", only_b) == "{:error, :not_found} active=false"
      assert Fx.records(ctx.schema, "fxlp_note") |> Enum.all?(&(&1.record_id != only_b))
    end
  end
end
