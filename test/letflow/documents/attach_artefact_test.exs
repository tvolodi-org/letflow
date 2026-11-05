defmodule Letflow.Documents.AttachArtefactTest do
  @moduledoc """
  REQ-623 / GH #3474, `Letflow.Documents.attach_artefact/2` (decision 0075). Design:
  state/tasks/T-1280/design.md, tests N1, N2, T1, R1, F1..F3, S1, S2, P1, P2, X1, D1..D5, N3, I1.
  The lock proof (L1, L2) and the concurrent attach (R2) are in `attach_artefact_lock_test.exs`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Letflow.DocumentSqlFixture

  alias Letflow.Documents
  alias Letflow.Documents.TestRenderer
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths

  @actor "99999999-9999-4999-8999-999999999999"
  @secret "SENTINEL-CONTENT-VALUE"

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req623-at")
    {:ok, _} = Documents.register_type(schema, type_attrs(), %{actor_id: @actor})
    unit = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, schema)
    TestRenderer.install!()
    %{schema: schema, tenant_id: tenant_id, unit: unit}
  end

  defp type_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        key: "purchase_request",
        owner_module: "procurement",
        numbering_scope: :year,
        number_prefix: "PR",
        number_pad: 4,
        legal_entity_required: false,
        declared_fields: %{"_free" => ["note", "amount"]},
        sensitivity: %{"note" => :public, "amount" => :public},
        template_ref: TestRenderer.ref()
      },
      overrides
    )
  end

  defp issued!(ctx, content \\ %{"amount" => 10, "note" => @secret, "undeclared" => "hidden"}) do
    {:ok, %{document: d}} =
      Documents.create_draft(
        ctx.schema,
        %{type_key: "purchase_request", issuing_org_unit_id: ctx.unit, content: content},
        @actor
      )

    {:ok, %{version: v}} = Documents.issue(ctx.schema, %{document_id: d.id, actor_id: @actor})
    {d.id, v.version_no}
  end

  defp attach(ctx, {id, no}),
    do:
      Documents.attach_artefact(ctx.schema, %{document_id: id, version_no: no, actor_id: @actor})

  defp count(schema, tbl),
    do: exec!("SELECT count(*) FROM #{table(schema, tbl)}").rows |> hd() |> hd()

  defp audit(schema, action) do
    exec!(
      "SELECT after_state FROM #{table(schema, "audit_entries")} WHERE action = $1 ORDER BY timestamp, id",
      [action]
    ).rows
    |> List.flatten()
  end

  defp hash_of(schema, id),
    do:
      exec!(
        "SELECT artefact_hash FROM #{table(schema, "document_versions")} WHERE document_id = $1::uuid",
        [id]
      ).rows
      |> List.flatten()

  defp counting(test_pid, reply \\ {:ok, "%PDF-1.4 test", "tv1"}) do
    TestRenderer.set_fun(fn _ref, _projection, _meta ->
      send(test_pid, :called)
      reply
    end)
  end

  test "N1/N2: issue/2 never renders, attach_artefact/2 renders exactly once", ctx do
    counting(self())
    doc = issued!(ctx)
    refute_received :called
    assert {:ok, %{version: %{artefact_hash: hash}}} = attach(ctx, doc)
    assert is_binary(hash)
    assert_received :called
    refute_received :called
  end

  test "T1/S2: bytes are stored under their SHA-256, one audit entry with the listed keys", ctx do
    {id, _} = doc = issued!(ctx)
    assert {:ok, %{version: v}} = attach(ctx, doc)
    assert v.artefact_hash == Base.encode16(:crypto.hash(:sha256, "%PDF-1.4 test"), case: :lower)
    assert hash_of(ctx.schema, id) == [v.artefact_hash]

    assert [[bytes, size]] =
             exec!(
               "SELECT content, byte_size FROM #{table(ctx.schema, "repository_artifacts")} WHERE content_hash = $1",
               [:crypto.hash(:sha256, "%PDF-1.4 test")]
             ).rows

    assert bytes == "%PDF-1.4 test" and size == byte_size(bytes)

    assert [payload] = audit(ctx.schema, "document.artefact_attached")

    assert payload |> Map.keys() |> Enum.sort() ==
             ~w(artefact_hash byte_size content_hash document_id template_ref template_version type_key version_no)

    assert payload["template_version"] == "tv1" and payload["template_ref"] == "tpl.test"
    refute inspect(payload) =~ @secret
  end

  test "R1: a second call on an attached version renders nothing and writes nothing", ctx do
    counting(self())
    doc = issued!(ctx)
    assert {:ok, %{version: v1}} = attach(ctx, doc)
    assert_received :called
    assert {:ok, %{version: v2}} = attach(ctx, doc)
    refute_received :called
    assert v2.artefact_hash == v1.artefact_hash
    assert length(audit(ctx.schema, "document.artefact_attached")) == 1
    assert count(ctx.schema, "repository_artifacts") == 1
  end

  describe "a failed render" do
    defp assert_untouched(ctx, {id, _} = doc) do
      assert hash_of(ctx.schema, id) == [nil]
      assert count(ctx.schema, "repository_artifacts") == 0
      assert audit(ctx.schema, "document.artefact_attached") == []
      assert [[1]] = exec!("SELECT counter FROM #{table(ctx.schema, "document_sequences")}").rows

      # a later call attaches
      TestRenderer.set_fun(&TestRenderer.default/3)
      assert {:ok, %{version: %{artefact_hash: h}}} = attach(ctx, doc)
      assert is_binary(h)
    end

    test "F1: {:error, term}", ctx do
      doc = issued!(ctx)
      TestRenderer.set_fun(fn _, _, _ -> {:error, :boom} end)
      assert {:error, :render_failed} = attach(ctx, doc)
      assert_untouched(ctx, doc)
    end

    test "F2: raise, exit and throw never reach the caller", ctx do
      doc = issued!(ctx)

      for fun <- [
            fn _, _, _ -> raise "boom" end,
            fn _, _, _ -> exit(:boom) end,
            fn _, _, _ -> throw(:boom) end
          ] do
        TestRenderer.set_fun(fun)
        capture_log(fn -> assert {:error, :render_failed} = attach(ctx, doc) end)
      end

      assert_untouched(ctx, doc)
    end

    test "F3: no renderer, bad returns, empty bytes", ctx do
      doc = issued!(ctx)

      for reply <- [
            {:ok, "bytes"},
            {:ok, "bytes", ""},
            {:ok, "", "v1"},
            {:ok, :not_binary, "v1"},
            :ok
          ] do
        TestRenderer.set_fun(fn _, _, _ -> reply end)
        capture_log(fn -> assert {:error, :render_failed} = attach(ctx, doc) end)
      end

      Application.put_env(:letflow, :document_renderers, %{})
      capture_log(fn -> assert {:error, :render_failed} = attach(ctx, doc) end)
      assert_untouched_no_retry(ctx, doc)
    end

    defp assert_untouched_no_retry(ctx, {id, _}) do
      assert hash_of(ctx.schema, id) == [nil]
      assert count(ctx.schema, "repository_artifacts") == 0
    end

    test "F3b: a type without template_ref", ctx do
      {:ok, _} =
        Documents.register_type(
          ctx.schema,
          type_attrs(%{key: "no_template", template_ref: nil}),
          %{actor_id: @actor}
        )

      {:ok, %{document: d}} =
        Documents.create_draft(
          ctx.schema,
          %{type_key: "no_template", issuing_org_unit_id: ctx.unit, content: %{"note" => "x"}},
          @actor
        )

      {:ok, %{version: v}} = Documents.issue(ctx.schema, %{document_id: d.id, actor_id: @actor})
      capture_log(fn -> assert {:error, :render_failed} = attach(ctx, {d.id, v.version_no}) end)
      assert_untouched_no_retry(ctx, {d.id, 1})
    end

    test "S1: log and result carry a reason code only, never a content value", ctx do
      doc = issued!(ctx)
      TestRenderer.set_fun(fn _, projection, _ -> {:error, {:leak, projection["note"]}} end)
      log = capture_log(fn -> assert {:error, :render_failed} = attach(ctx, doc) end)
      assert log =~ "code=renderer_error"
      refute log =~ @secret

      TestRenderer.set_fun(fn _, projection, _ -> raise "leak #{projection["note"]}" end)
      log = capture_log(fn -> assert {:error, :render_failed} = attach(ctx, doc) end)
      assert log =~ "code=renderer_raised"
      refute log =~ @secret
    end
  end

  test "P1: the renderer gets only the declared fields and the four meta keys", ctx do
    test_pid = self()
    doc = issued!(ctx)

    TestRenderer.set_fun(fn ref, projection, meta ->
      send(test_pid, {:got, ref, projection, meta})
      {:ok, "%PDF", "v"}
    end)

    assert {:ok, _} = attach(ctx, doc)
    assert_received {:got, "tpl.test", projection, meta}
    assert projection == %{"amount" => 10, "note" => @secret}
    assert meta |> Map.keys() |> Enum.sort() == [:issued_at, :number, :period, :version_no]
    assert meta.number == 1 and meta.version_no == 1
  end

  test "P2: a renderer that fails closed on a missing key attaches nothing", ctx do
    doc = issued!(ctx, %{"note" => "only"})

    TestRenderer.set_fun(fn _, projection, _ ->
      case projection do
        %{"amount" => _} -> {:ok, "%PDF", "v"}
        _ -> {:error, :missing_amount}
      end
    end)

    capture_log(fn -> assert {:error, :render_failed} = attach(ctx, doc) end)
    assert hash_of(ctx.schema, elem(doc, 0)) == [nil]
  end

  test "X1: a field restricted after issue is never given to a renderer", ctx do
    {:ok, _} =
      Documents.register_type(
        ctx.schema,
        type_attrs(%{
          key: "person_doc",
          declared_fields: %{"person" => ["name"]},
          sensitivity: nil
        }),
        %{actor_id: @actor}
      )

    {:ok, %{document: d}} =
      Documents.create_draft(
        ctx.schema,
        %{type_key: "person_doc", issuing_org_unit_id: ctx.unit, content: %{"name" => "n"}},
        @actor
      )

    {:ok, %{version: v}} = Documents.issue(ctx.schema, %{document_id: d.id, actor_id: @actor})

    exec!(
      "INSERT INTO #{table(ctx.schema, "entity_field_restrictions")} (id, entity_type, field_name, inserted_at, updated_at) VALUES (gen_random_uuid(), 'person', 'name', now(), now())"
    )

    counting(self())

    log =
      capture_log(fn -> assert {:error, :render_failed} = attach(ctx, {d.id, v.version_no}) end)

    assert log =~ "code=restricted_field"
    refute_received :called
    assert hash_of(ctx.schema, d.id) == [nil]
  end

  describe "a version that is not issued" do
    test "D1: draft and D5: discarded", ctx do
      counting(self())

      {:ok, %{document: d}} =
        Documents.create_draft(
          ctx.schema,
          %{
            type_key: "purchase_request",
            issuing_org_unit_id: ctx.unit,
            content: %{"note" => "x"}
          },
          @actor
        )

      assert {:error, :not_issuable_for_artefact} = attach(ctx, {d.id, 1})
      {:ok, _} = Documents.discard_draft(ctx.schema, d.id, @actor)
      assert {:error, :not_issuable_for_artefact} = attach(ctx, {d.id, 1})
      refute_received :called
    end

    test "D2: superseded", ctx do
      counting(self())
      {id, 1} = issued!(ctx)
      {:ok, %{document: _, version: _}} = new_issued_version(ctx, id)
      assert {:error, :not_issuable_for_artefact} = attach(ctx, {id, 1})
      refute_received :called
      assert hash_of(ctx.schema, id) == [nil, nil]
    end

    test "D3: cancelled between issue and attach", ctx do
      counting(self())
      {id, no} = doc = issued!(ctx)

      {:ok, _} =
        Documents.cancel(ctx.schema, %{document_id: id, version_no: no, reason: "r"}, @actor)

      assert {:error, :not_issuable_for_artefact} = attach(ctx, doc)
      refute_received :called
      assert audit(ctx.schema, "document.artefact_attached") == []
    end

    test "D4: the locked re-check refuses a cancel that lands during the render", ctx do
      {id, no} = doc = issued!(ctx)

      TestRenderer.set_fun(fn _, _, _ ->
        {:ok, _} =
          Documents.cancel(ctx.schema, %{document_id: id, version_no: no, reason: "r"}, @actor)

        {:ok, "%PDF", "v"}
      end)

      assert {:error, :not_issuable_for_artefact} = attach(ctx, doc)
      assert hash_of(ctx.schema, id) == [nil]
      assert count(ctx.schema, "repository_artifacts") == 0
    end
  end

  defp new_issued_version(ctx, id) do
    {:ok, _draft} =
      Documents.new_version_from_current(ctx.schema, %{document_id: id, actor_id: @actor})

    Documents.issue(ctx.schema, %{document_id: id, actor_id: @actor})
  end

  test "N3: unknown, malformed and foreign ids are :not_found and render nothing", ctx do
    counting(self())
    {id, no} = issued!(ctx)
    other = provisioned_tenant!("req623-ot")

    for args <- [
          %{document_id: Ecto.UUID.generate(), version_no: 1, actor_id: @actor},
          %{document_id: id, version_no: 99, actor_id: @actor},
          %{document_id: "nope", version_no: no, actor_id: @actor},
          %{document_id: id, version_no: "1", actor_id: @actor}
        ] do
      assert {:error, :not_found} = Documents.attach_artefact(ctx.schema, args)
    end

    assert {:error, :not_found} =
             Documents.attach_artefact(other.schema_name, %{
               document_id: id,
               version_no: no,
               actor_id: @actor
             })

    refute_received :called
    assert hash_of(ctx.schema, id) == [nil]
  end

  test "I1: inside a caller's transaction it refuses before any read or render", ctx do
    counting(self())
    doc = issued!(ctx)

    Repo.transaction(fn ->
      assert {:error, :in_transaction} = attach(ctx, doc)
    end)

    refute_received :called
    assert hash_of(ctx.schema, elem(doc, 0)) == [nil]
  end

  test "the renderer override flag is compiled in the test config only" do
    assert Letflow.Documents.Renderers.override_enabled?()

    for file <- ~w(config/config.exs config/dev.exs config/prod.exs config/runtime.exs) do
      refute File.read!(file) =~ "document_renderers_override_enabled", file
    end
  end
end
