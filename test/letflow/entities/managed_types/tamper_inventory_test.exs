defmodule Letflow.Entities.ManagedTypes.TamperInventoryTest do
  @moduledoc """
  GH #2596 T-24..T-27 (AC7), design `lib/letflow/design/gh2596-exam-managed-types.md` section 8
  (spec `test/specs/GH2596-exam-managed.md`): the read-only tamper inventory infra runs BEFORE the
  stamp.

    * T-24: one real module write (a candidate starts a session) and one generic-route write
      (`POST /entities/records/session_answer` with a client key) on an UNSTAMPED tenant: only the
      generic event is listed, `evidence: :client_key`; the module's `session` / `session_question`
      events are absent.
    * T-25: the evidence variants (`:non_owner_actor`, `:import_key`, `:unrecognised_key_shape`,
      `:authoring_type` and the `scope` option), the per-tenant cap, the wrapper and the Mix task.
    * T-26: strictly read-only; findings carry ids only; the payload is never selected or logged.
    * T-27: the documented blind spot, characterised: a keyless generic write by the session's OWN
      user is NOT listed.

  Runs OUTSIDE the Ecto sandbox transaction (`async: false`; the fixture switches the sandbox to
  `:auto`): the inventory runs its own transaction and refuses to run inside one.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Plug.Conn

  alias Letflow.Entities.ManagedTypes.TamperInventory
  alias Letflow.Entities.Records
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Modules.Exam.Session
  alias Letflow.Release.ManagedTypes, as: Release
  alias Mix.Tasks.Letflow.ManagedTypesTamperInventory, as: InventoryTask

  @entities_opts Letflow.Routers.Entities.init([])
  @operator ["PROCESS_OPERATOR"]
  @admin ["TENANT_ADMIN"]

  @marker "MARKER-gh2596-payload-must-not-leak"

  # ── fixtures ────────────────────────────────────────────────────────────────────────────────

  # An UNSTAMPED exam tenant with every definition active, a candidate who started a session
  # through the module (events keyed by minted UUIDs, actor = the candidate), and an admin actor.
  setup do
    %{tenant_id: tenant_id, schema_name: schema} = Fx.full_tenant!("gh2596-inventory")
    content = Fx.build_exam!(schema)
    candidate = Fx.insert_user!(schema)
    admin = Fx.insert_user!(schema)

    {:ok, view} = Session.create(candidate.id, content.exam.record_id, schema)

    {:ok,
     tenant_id: tenant_id,
     schema: schema,
     session_id: view.id,
     candidate_id: candidate.id,
     admin_id: admin.id,
     question_id: content.question_id}
  end

  defp call_entities(ctx, actor_id, roles, method, path, body) do
    conn = Plug.Test.conn(method, path)

    conn =
      %{conn | body_params: body || %{}} |> put_req_header("content-type", "application/json")

    conn
    |> assign(:auth_context, %{user_id: actor_id, tenant_id: ctx.tenant_id, roles: roles})
    |> assign(:trace_id, "gh2596-inventory-trace")
    |> Letflow.Routers.Entities.call(@entities_opts)
  end

  defp answer_values(ctx, extra \\ %{}) do
    Map.merge(
      %{
        "session_id" => ctx.session_id,
        "question_id" => ctx.question_id,
        "saved_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "time_spent_seconds" => 1
      },
      extra
    )
  end

  # POST /records/session_answer; returns the new record id.
  defp generic_answer!(ctx, actor_id, roles, key, extra \\ %{}) do
    body = %{"field_values" => answer_values(ctx, extra)}
    body = if key, do: Map.put(body, "idempotency_key", key), else: body
    conn = call_entities(ctx, actor_id, roles, :post, "/records/session_answer", body)
    assert conn.status == 201, conn.resp_body
    Jason.decode!(conn.resp_body)["record_id"]
  end

  defp findings(ctx, opts \\ []) do
    report = TamperInventory.run_tenant(ctx.schema, opts)
    assert report.skipped == nil
    report
  end

  defp by_record(report), do: Map.new(report.findings, &{&1.record_id, &1})

  # ── T-24 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-24 (AC7): module writes are not listed, the generic write is" do
    test "only the generic client-keyed event is listed, with evidence :client_key", ctx do
      # Non-vacuity: the module's own writes exist.
      assert Repo.aggregate(
               from_latest("session"),
               :count,
               prefix: ctx.schema
             ) == 1

      assert Repo.aggregate(from_latest("session_question"), :count, prefix: ctx.schema) == 1

      id = generic_answer!(ctx, ctx.admin_id, @admin, "K-client-1")

      report = findings(ctx)

      assert [finding] = report.findings
      assert finding.entity_type == "session_answer"
      assert finding.record_id == id
      assert finding.event_type == "ENTITY_RECORD_CREATED"
      assert finding.actor_id == ctx.admin_id
      assert finding.evidence == :client_key
      assert finding.tenant_id == ctx.tenant_id
      assert %DateTime{} = finding.occurred_at
      refute report.truncated

      refute Enum.any?(report.findings, &(&1.entity_type in ["session", "session_question"]))
    end
  end

  # ── T-25 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-25 (AC7): evidence variants" do
    test "keyless admin write for another user's session -> :non_owner_actor; import -> :import_key; legacy raw key -> :unrecognised_key_shape",
         ctx do
      keyless = generic_answer!(ctx, ctx.admin_id, @operator, nil)

      import_doc = %{
        "record_export_schema_version" => "entities/record-export/v1",
        "entity_type" => "session_answer",
        "exported_at" => "2026-10-16T00:00:00Z",
        "records" => [
          %{
            "record_id" => Ecto.UUID.generate(),
            "field_values" => answer_values(ctx),
            "deleted" => false
          }
        ]
      }

      assert 200 ==
               call_entities(
                 ctx,
                 ctx.admin_id,
                 @admin,
                 :post,
                 "/records/session_answer/import",
                 import_doc
               ).status

      # A pre-#2550 raw client key: written straight through Records as :tenant (unstamped tenant).
      assert {:ok, %{record: legacy}} =
               Records.create_record(
                 %{
                   entity_type: "session_answer",
                   field_values: answer_values(ctx),
                   actor_id: ctx.candidate_id,
                   idempotency_key: "raw-legacy-key"
                 },
                 ctx.schema
               )

      report = findings(ctx)
      by_id = by_record(report)

      assert by_id[keyless].evidence == :non_owner_actor
      assert by_id[legacy.record_id].evidence == :unrecognised_key_shape

      assert [import_finding] = Enum.filter(report.findings, &(&1.evidence == :import_key))
      assert import_finding.entity_type == "session_answer"
      assert length(report.findings) == 3
    end

    test "an authoring-type write is absent under :runtime and listed as :authoring_type under :authoring and :all",
         ctx do
      body = %{
        "field_values" => %{"name" => %{"kk" => "k", "ru" => "r", "en" => "e"}, "sort_order" => 1}
      }

      created = call_entities(ctx, ctx.admin_id, @admin, :post, "/records/category", body)
      assert created.status == 201
      category_id = Jason.decode!(created.resp_body)["record_id"]

      runtime_answer = generic_answer!(ctx, ctx.admin_id, @admin, "K-both")

      runtime = findings(ctx, scope: :runtime)
      refute Enum.any?(runtime.findings, &(&1.entity_type == "category"))
      assert Map.has_key?(by_record(runtime), runtime_answer)

      authoring = findings(ctx, scope: :authoring)
      assert Enum.all?(authoring.findings, &(&1.evidence == :authoring_type))
      assert authoring.findings != []
      assert by_record(authoring)[category_id].entity_type == "category"
      refute Map.has_key?(by_record(authoring), runtime_answer)

      all = findings(ctx, scope: :all)
      assert by_record(all)[category_id].evidence == :authoring_type
      assert by_record(all)[runtime_answer].evidence == :client_key
    end

    test "the per-tenant cap truncates and says so", ctx do
      for n <- 1..3, do: generic_answer!(ctx, ctx.admin_id, @admin, "K-cap-#{n}")

      capped = findings(ctx, cap: 2)
      assert length(capped.findings) == 2
      assert capped.truncated

      uncapped = findings(ctx)
      assert length(uncapped.findings) == 3
      refute uncapped.truncated
    end

    test "run/1, the release wrapper and the Mix task cover the tenant and print ids and evidence only",
         ctx do
      id = generic_answer!(ctx, ctx.admin_id, @admin, "K-sweep")

      assert {:ok, %{scope: :runtime} = report} = TamperInventory.run([])
      mine = Enum.find(report.tenants, &(&1.schema_name == ctx.schema))
      assert [%{record_id: ^id, evidence: :client_key}] = mine.findings
      assert report.finding_total >= 1

      assert {:ok, %{scope: :runtime, tenants: tenants}} = Release.tamper_inventory([])
      assert Enum.any?(tenants, &(&1.schema_name == ctx.schema))

      # The wrapper forwards :module and :scope only.
      assert {:ok, %{scope: :all}} = Release.tamper_inventory(scope: :all, cap: 1)

      output = capture_io(fn -> InventoryTask.run([]) end)
      assert output =~ "tamper inventory (scope runtime)"
      assert output =~ "session_answer #{id} ENTITY_RECORD_CREATED actor=#{ctx.admin_id}"
      assert output =~ "evidence=client_key"

      assert_raise Mix.Error, ~r/usage: mix letflow.managed_types_tamper_inventory/, fn ->
        InventoryTask.run(["--scope", "everything"])
      end

      assert_raise Mix.Error, ~r/usage/, fn -> InventoryTask.run(["--bogus"]) end

      assert_raise Mix.Error, ~r/unsupported module/, fn ->
        InventoryTask.run(["--module", "other"])
      end
    end
  end

  # ── T-26 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-26 (AC7): read-only, ids only, no payload" do
    test "row counts and contents of events, entity_record_latest, entity_definitions and audit_entries are identical before and after",
         ctx do
      generic_answer!(ctx, ctx.admin_id, @admin, "K-ro", %{"text_answer" => @marker})

      before = snapshot(ctx.schema)
      assert [_] = findings(ctx).findings
      assert snapshot(ctx.schema) == before
      assert Enum.all?(Map.values(before), fn {count, _digest} -> count >= 0 end)
      assert elem(before.events, 0) > 0
    end

    test "the inventory runs in a READ ONLY transaction and issues only SELECT-shaped SQL (telemetry capture)",
         ctx do
      generic_answer!(ctx, ctx.admin_id, @admin, "K-sql")
      parent = self()
      handler = "gh2596-sql-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:letflow, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == parent, do: send(parent, {:sql, query})
        end,
        nil
      )

      try do
        assert [_] = findings(ctx).findings
      after
        :telemetry.detach(handler)
      end

      statements = drain_sql([])

      # The statement right after the transaction opens is SET TRANSACTION READ ONLY.
      assert [_ | after_begin] = Enum.drop_while(statements, &(&1 != "begin"))
      assert hd(after_begin) == "SET TRANSACTION READ ONLY"

      refute Enum.any?(
               statements,
               &Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP|CREATE)\b/i, &1)
             )

      select = Enum.find(statements, &(&1 =~ "events"))
      assert select

      # The SELECT list projects only JSON KEYS of the event body / record: never the column.
      [select_list | _] = String.split(select, ~r/\bFROM\b/, parts: 2)

      remaining =
        Regex.replace(~r/"(payload|field_values)"\s*->>\s*'[a-z_]+'/, select_list, "")

      refute remaining =~ ~r/"payload"/
      refute remaining =~ ~r/"field_values"/
    end

    test "the inventory module has no insert/update/delete call and no Logger call", _ctx do
      ast =
        "lib/letflow/entities/managed_types/tamper_inventory.ex"
        |> File.read!()
        |> Code.string_to_quoted!()

      {_ast, called} =
        Macro.prewalk(ast, [], fn
          {{:., _, [_receiver, name]}, _, args} = node, acc
          when is_atom(name) and is_list(args) ->
            {node, [name | acc]}

          {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
            {node, [name | acc]}

          node, acc ->
            {node, acc}
        end)

      writes = ~w(insert insert! insert_all update update! update_all delete delete! delete_all)a
      assert Enum.filter(called, &(&1 in writes)) == []
      refute :info in called or :debug in called or :warning in called or :error in called

      assert File.read!("lib/letflow/entities/managed_types/tamper_inventory.ex") =~
               "SET TRANSACTION READ ONLY"
    end

    test "a finding carries ids, the event type, the actor and a timestamp only; the seeded payload marker appears in no finding and no log line",
         ctx do
      generic_answer!(ctx, ctx.admin_id, @admin, "K-marker", %{"text_answer" => @marker})

      keyless_marker_id =
        generic_answer!(ctx, ctx.admin_id, @operator, nil, %{"text_answer" => @marker})

      {report, log} =
        with_log([level: :debug], fn -> findings(ctx) end)

      assert length(report.findings) == 2
      assert keyless_marker_id in Enum.map(report.findings, & &1.record_id)

      for finding <- report.findings do
        assert Enum.sort(Map.keys(finding)) ==
                 Enum.sort(
                   ~w(tenant_id entity_type record_id event_type actor_id occurred_at evidence)a
                 )
      end

      refute inspect(report, limit: :infinity, printable_limit: :infinity) =~ @marker
      refute log =~ @marker
    end
  end

  # ── T-27 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-27 (AC7): documented blind spot" do
    test "a keyless generic write by the session's OWN user is NOT listed (characterisation, not a guarantee)",
         ctx do
      blind = generic_answer!(ctx, ctx.candidate_id, @operator, nil)

      report = findings(ctx)
      refute Map.has_key?(by_record(report), blind)
      assert report.findings == []

      # The same write by someone else IS detected: the blind spot is the owner-actor case only.
      detected = generic_answer!(ctx, ctx.admin_id, @operator, nil)
      assert Map.has_key?(by_record(findings(ctx)), detected)
    end
  end

  # ── helpers (continued) ─────────────────────────────────────────────────────────────────────

  defp from_latest(type) do
    import Ecto.Query, only: [from: 2]
    from(l in Letflow.Entities.Record.Latest, where: l.entity_type == ^type)
  end

  defp drain_sql(acc) do
    receive do
      {:sql, query} -> drain_sql([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # {row count, content digest} per table.
  defp snapshot(schema) do
    for table <- ~w(events entity_record_latest entity_definitions audit_entries), into: %{} do
      %{rows: [[count, digest]]} =
        Repo.query!("""
        SELECT count(*), md5(coalesce(string_agg(t::text, '|' ORDER BY t::text), ''))
        FROM "#{schema}"."#{table}" t
        """)

      {String.to_atom(table), {count, digest}}
    end
  end
end
