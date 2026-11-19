defmodule Letflow.Entities.HandlerWritesDocumentReadTest do
  @moduledoc """
  REQ-902 (decision 0073 D6, L7 part 2b): the document read facade
  `HandlerWrites.read_document_version/3`, through real HUMAN_TASK completions of the
  `fixture_ledger_post` handlers `read_doc`, `read_doc_off`, `read_doc_maybe` and `post_reading_doc`
  (their answers are written into a note, so the test reads them back from the committed rows).

  Tests: D-2 the answers, D-3 own module only and the context, D-4 no lock, no write, own schema,
  D-5 the dry build, D-6 tenant isolation (INV-1), D-7 the caller scan. The declaration (D-1) and hash
  tests are in `test/letflow/modules/write_handler_spec_test.exs`, the T-SC-4e negative control in
  `ledger_boundaries_test.exs`. `async: false`: module installs run DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Documents
  alias Letflow.Entities.HandlerContext
  alias Letflow.Entities.HandlerWrites
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore
  alias Letflow.LedgerPostFixture, as: PFx
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.PlatformTenantFixture

  @own "fxdoc_own"
  @foreign "fxdoc_foreign"

  # `PFx.line/2` adds a "note" argument that the read handlers do not declare.
  defp line(handler, args) do
    %{
      "module" => "fixture_ledger_post",
      "handler" => handler,
      "args" => Map.new(args, fn {name, value} -> {name, %{"const" => value}} end)
    }
  end

  defp type_attrs(key, owner) do
    %{
      key: key,
      owner_module: owner,
      numbering_scope: :year,
      number_prefix: "FX",
      number_pad: 4,
      legal_entity_required: false,
      declared_fields: %{}
    }
  end

  # A tenant with the fixture module installed, a unit and two registered document types.
  defp tenant!(slug) do
    ctx = PFx.case!(slug, [PFx.line("plain")])
    actor = ctx.completer.id

    {:ok, _} =
      Documents.register_type(ctx.schema, type_attrs(@own, "fixture_ledger_post"), %{
        actor_id: actor
      })

    {:ok, _} =
      Documents.register_type(ctx.schema, type_attrs(@foreign, "another_module"), %{
        actor_id: actor
      })

    unit = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, ctx.schema)
    Map.merge(ctx, %{actor: actor, unit: unit})
  end

  defp draft!(ctx, type, content) do
    {:ok, %{document: d}} =
      Documents.create_draft(
        ctx.schema,
        %{type_key: type, issuing_org_unit_id: ctx.unit, content: content},
        ctx.actor
      )

    d.id
  end

  defp issue!(ctx, id),
    do: {:ok, _} = Documents.issue(ctx.schema, %{document_id: id, actor_id: ctx.actor})

  # Document with v1 superseded and v2 issued (current).
  defp two_versions!(ctx, type \\ @own) do
    id = draft!(ctx, type, %{"amount" => 1})
    issue!(ctx, id)

    {:ok, _} =
      Documents.new_version_from_current(ctx.schema, %{document_id: id, actor_id: ctx.actor})

    {:ok, _} = Documents.edit_draft(ctx.schema, id, %{"amount" => 2}, ctx.actor)
    issue!(ctx, id)
    id
  end

  defp note_ids(schema) do
    from(r in Latest, where: r.entity_type == "fxlp_note", select: r.record_id)
    |> Repo.all(prefix: schema)
  end

  # Completes a line and returns the note the handler wrote (when it wrote one).
  defp run(ctx, handler, args) do
    before = MapSet.new(note_ids(ctx.schema))
    task = PFx.more_task!(ctx, [line(handler, args)])
    assert {:ok, _} = PFx.complete(task)

    case MapSet.to_list(MapSet.difference(MapSet.new(note_ids(ctx.schema)), before)) do
      [new] ->
        from(r in Latest, where: r.record_id == ^new, select: r.field_values)
        |> Repo.one!(prefix: ctx.schema)
        |> Map.fetch!("note")

      _none ->
        nil
    end
  end

  defp read(ctx, id, version_no, handler \\ "read_doc") do
    case run(ctx, handler, %{"document_id" => id, "version_no" => version_no}) do
      "ok " <> json -> {:ok, Jason.decode!(json)}
      other -> other
    end
  end

  defp version_row(ctx, id, no) do
    %{rows: [[vid, status, hash]]} =
      Repo.query!(
        "SELECT id, status, content_hash FROM \"#{ctx.schema}\".document_versions WHERE document_id = $1 AND version_no = $2",
        [Ecto.UUID.dump!(id), no]
      )

    {Ecto.UUID.cast!(vid), status, hash}
  end

  describe "D-2 answers in a real completion" do
    setup do
      {:ok, ctx: tenant!("req902-ans")}
    end

    test "issued current, superseded and cancelled versions answer every key", %{ctx: ctx} do
      id = two_versions!(ctx)

      assert {:ok, current} = read(ctx, id, 2)
      {vid2, "issued", hash2} = version_row(ctx, id, 2)

      assert current == %{
               "document_id" => id,
               "version_id" => vid2,
               "version_no" => 2,
               "type_key" => @own,
               "status" => "issued",
               "current" => true,
               "issuing_org_unit_id" => ctx.unit,
               "content" => %{"amount" => 2},
               "content_hash" => hash2
             }

      assert {:ok, old} = read(ctx, id, 1)
      {vid1, "superseded", hash1} = version_row(ctx, id, 1)

      assert old["status"] == "superseded"
      assert old["current"] == false
      assert old["version_id"] == vid1
      assert old["content"] == %{"amount" => 1}
      assert old["content_hash"] == hash1
      assert Map.keys(old) == Map.keys(current)

      cancelled = draft!(ctx, @own, %{"amount" => 3})
      issue!(ctx, cancelled)

      {:ok, _} =
        Documents.cancel(
          ctx.schema,
          %{document_id: cancelled, version_no: 1, reason: "test"},
          ctx.actor
        )

      assert {:ok, gone} = read(ctx, cancelled, 1)
      assert gone["status"] == "cancelled"
      assert gone["document_id"] == cancelled
      assert gone["content"] == %{"amount" => 3}
    end

    test "not_found for a bad id, version 0, a string version, an unknown id and an unknown version",
         %{ctx: ctx} do
      id = two_versions!(ctx)
      miss = "{:error, :not_found}"

      assert read(ctx, "not-a-uuid", 1) == miss
      assert read(ctx, id, 0) == miss
      assert read(ctx, id, "1") == miss
      assert read(ctx, Ecto.UUID.generate(), 1) == miss
      assert read(ctx, id, 99) == miss
    end
  end

  describe "D-3 own module only, registration and context" do
    setup do
      {:ok, ctx: tenant!("req902-own")}
    end

    test "a document of another owner_module is not_found; reads_documents false is read_not_registered",
         %{ctx: ctx} do
      foreign = two_versions!(ctx, @foreign)
      own = two_versions!(ctx)

      assert read(ctx, foreign, 2) == "{:error, :not_found}"
      assert {:ok, %{"type_key" => @own}} = read(ctx, own, 2)
      assert read(ctx, own, 2, "read_doc_off") == "{:error, :read_not_registered}"
    end

    test "a forged or absent context is invalid_write_command" do
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
        handler: %{module_id: "fixture_ledger_post", name: "read_doc", targets: ["fxlp_note"]}
      }

      id = Ecto.UUID.generate()
      assert HandlerWrites.read_document_version(ctx, id, 1) == {:error, :invalid_write_command}

      Process.put({HandlerWrites, :call}, %{ctx: %{ctx | line_index: 1}, produced: []})
      assert HandlerWrites.read_document_version(ctx, id, 1) == {:error, :invalid_write_command}
      assert HandlerWrites.read_document_version(%{}, id, 1) == {:error, :invalid_write_command}
      assert HandlerWrites.read_document_version(nil, id, 1) == {:error, :invalid_write_command}
    after
      Process.delete({HandlerWrites, :call})
    end
  end

  describe "D-4 no lock, no write, own schema" do
    test "each extra statement of a reading completion is a plain SELECT on the document tables" do
      ctx = tenant!("req902-qry")
      id = two_versions!(ctx)
      args = %{"document_id" => id, "version_no" => 2}

      # a first completion creates the lazy per-tenant rows both measured completions would share
      assert run(ctx, "read_doc_maybe", Map.put(args, "do_read", false)) == nil

      with_read =
        PFx.more_task!(ctx, [line("read_doc_maybe", Map.put(args, "do_read", true))])

      without = PFx.more_task!(ctx, [line("read_doc_maybe", Map.put(args, "do_read", false))])

      {{:ok, _}, queries_with} =
        PlatformTenantFixture.capture_repo_queries(fn -> PFx.complete(with_read) end)

      {{:ok, _}, queries_without} =
        PlatformTenantFixture.capture_repo_queries(fn -> PFx.complete(without) end)

      sqls = fn queries -> Enum.map(queries, &String.replace(&1.query, ~r/\s+/, " ")) end
      extra = sqls.(queries_with) -- sqls.(queries_without)
      allowed = ["documents", "document_versions", "document_types"]

      assert extra != []

      for sql <- extra do
        assert sql =~ ~r/^SELECT /
        refute sql =~ ~r/FOR (UPDATE|SHARE)/i
        refute sql =~ ~r/ledger_/
        refute sql =~ ~r/INSERT|UPDATE|DELETE/

        tables = Regex.scan(~r/"([^"]+)"\."([^"]+)"/, sql, capture: :all_but_first)
        assert tables != []

        assert Enum.all?(tables, fn [schema, table] ->
                 schema == ctx.schema and table in allowed
               end)
      end

      assert length(extra) == 1
    end
  end

  describe "D-5 the dry build" do
    test "read_document_version/3 answers dry_build with no query" do
      ctx = tenant!("req902-dry")
      posting = PFx.posting("receipt", "a", "5")
      line = line("post_reading_doc", %{"posting" => posting})
      task = PFx.more_task!(ctx, [line])

      {:ok, handler} =
        Letflow.Modules.Catalog.write_handler("fixture_ledger_post", "post_reading_doc")

      assert handler.reads_documents == true
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

  describe "D-6 tenant isolation (INV-1)" do
    test "an issued document that exists only in tenant A is not_found in a completion of tenant B" do
      a = tenant!("req902-iso-a")
      b = tenant!("req902-iso-b")
      only_a = two_versions!(a)
      only_b = two_versions!(b)

      assert {:ok, %{"document_id" => ^only_a, "version_no" => 2}} = read(a, only_a, 2)
      assert {:ok, %{"document_id" => ^only_b}} = read(b, only_b, 2)

      # same answer as for an id that exists nowhere: nothing about tenant A is revealed
      assert read(b, only_a, 2) == "{:error, :not_found}"
      assert read(b, only_a, 1) == "{:error, :not_found}"
      assert read(b, only_a, 2) == read(b, Ecto.UUID.generate(), 2)
    end
  end

  describe "D-7 the only caller" do
    test "Documents.read_version_for_module/4 is called only from HandlerWrites under lib/" do
      hits =
        for path <- Path.wildcard("lib/**/*.ex"),
            path != "lib/letflow/documents.ex",
            String.contains?(File.read!(path), "read_version_for_module"),
            do: path

      assert hits == ["lib/letflow/entities/handler_writes.ex"]
      refute function_exported?(HandlerWrites, :read_version_for_module, 4)
      assert function_exported?(HandlerWrites, :read_document_version, 3)

      source = File.read!("lib/letflow/documents.ex")
      assert length(Regex.scan(~r/read_version_for_module\(/, source)) == 3
    end
  end
end
