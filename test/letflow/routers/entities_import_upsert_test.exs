defmodule Letflow.Routers.EntitiesImportUpsertTest do
  @moduledoc """
  GH #2659 / REQ-505 PR-3 (design `lib/letflow/design/gh2659-external-ref-idempotent-import.md`
  sections 4.5, 5, 6, 7 and 9; decisions 0057, 0060, 0061): the HTTP half of the idempotent
  upsert -- the optional `"upsert_by": "external_ref"` of
  `POST /api/v1/entities/records/:entity_type/import`.

  Full pipeline (`Letflow.Router.call/2`, real API-token bearer), real Postgres, real commits and
  several connections, so `async: false` with the sandbox pinned to `:auto` for the whole test.

    * T1: the same file twice -> one record per external id (`created` then `unchanged`, no new
      event); a changed value -> `updated`; append-only type re-run safe vs differing.
    * T2: WITHOUT `upsert_by` the route is unchanged (an entry `external_ref` is ignored, no ref is
      stored, the response has the same keys); in upsert mode a ref-less entry is a per-entry error.
    * T3: two systems with the same id, and one pair in two types, do not collide.
    * T4: per-entry partial failure, the 200 cap, duplicate ref in the file, soft-deleted ref.
    * T5: two concurrent imports of the same refs leave one record per ref.
    * T6: the same ref in two tenants does not collide.
    * T7: derived idempotency key (128 bytes for a 255 byte id), a within-file duplicate is never
      `idempotency_key_reuse`.
    * T9: a tenant below CREATED v2 gets a whole-request 503 from ONE schema-version read.
    * T12: the permission model (route gate alone; a caller without Import is refused).
    * T13/T14: TypeAccess denied = absent (404, same body); write-side field restrictions; the
      404 fold cannot be masked by a malformed first-entry ref.
    * No echo of a reference's system or id in any error entry or in any warning log.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ImportUpsert
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  @schema_version "entities/record-export/v1"
  @marker "leakmark"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    :ok
  end

  # ---- helpers -------------------------------------------------------------------------------

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp tenant_ctx(slug_prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2659-user-#{Ecto.UUID.generate()}",
        display_name: "GH-2659 test user",
        email: "gh2659-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      tenant_id: tenant.tenant_id,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp seed_type!(ctx, name, extra_fields \\ [], extra \\ %{}) do
    fields = [%{name: "customer_name", type: :string, required: true} | extra_fields]

    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: Map.merge(%{name: name, display_name: name, fields: fields}, extra),
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition(name, ctx.user_id, "gh2659", ctx.schema_name)
    :ok
  end

  defp ref(system, id), do: %{"system" => system, "id" => id}

  defp entry(system, id, name, extra \\ %{}) do
    %{
      "external_ref" => ref(system, id),
      "field_values" => Map.merge(%{"customer_name" => name}, extra)
    }
  end

  defp document(type, entries, upsert?) do
    base = %{
      "record_export_schema_version" => @schema_version,
      "entity_type" => type,
      "records" => entries
    }

    if upsert?, do: Map.put(base, "upsert_by", "external_ref"), else: base
  end

  defp import!(ctx, type, entries, upsert? \\ true) do
    request(
      :post,
      "/api/v1/entities/records/#{type}/import",
      ctx,
      document(type, entries, upsert?)
    )
  end

  defp results(conn) do
    assert conn.status == 200, "#{conn.status} #{conn.resp_body}"
    Jason.decode!(conn.resp_body)["results"]
  end

  defp outcomes(conn), do: conn |> results() |> Enum.map(&(&1["outcome"] || &1["reason"]["type"]))

  defp rows(ctx, type) do
    Repo.all(from(l in Latest, where: l.entity_type == ^type, order_by: l.inserted_at),
      prefix: ctx.schema_name
    )
  end

  defp event_count(ctx), do: Repo.aggregate(Event, :count, prefix: ctx.schema_name)

  defp types(ctx),
    do:
      Repo.all(from(e in Event, select: e.event_type, order_by: e.global_seq),
        prefix: ctx.schema_name
      )

  defp insert_restriction!(ctx, type, field) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp insert_grant!(ctx, field_type, field) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(ctx.user_id),
          entity_type: field_type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp insert_type_restriction!(ctx, type) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp strip_trace(conn), do: conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")

  # ---- T1 ------------------------------------------------------------------------------------

  describe "T1: the same file twice" do
    test "one record per external id: created, then unchanged with no new event; a change is updated" do
      ctx = tenant_ctx("gh2659-t1")
      seed_type!(ctx, "customer")

      file = [entry("sap", "1", "Acme"), entry("sap", "2", "Beta")]

      first = import!(ctx, "customer", file)
      assert outcomes(first) == ["created", "created"]
      assert [%{"external_ref" => %{"system" => "sap", "id" => "1"}} | _] = results(first)
      assert length(rows(ctx, "customer")) == 2
      events_after_first = event_count(ctx)

      second = import!(ctx, "customer", file)
      assert outcomes(second) == ["unchanged", "unchanged"]
      assert length(rows(ctx, "customer")) == 2
      assert event_count(ctx) == events_after_first

      # the record ids are the same records
      assert Enum.map(results(first), & &1["record_id"]) ==
               Enum.map(results(second), & &1["record_id"])

      third = import!(ctx, "customer", [entry("sap", "1", "Acme 2"), entry("sap", "2", "Beta")])
      assert outcomes(third) == ["updated", "unchanged"]
      assert length(rows(ctx, "customer")) == 2
      assert event_count(ctx) == events_after_first + 1
      assert List.last(types(ctx)) == "ENTITY_RECORD_UPDATED"
    end

    test "an append_only type: an identical re-run is unchanged, a differing value is entity_append_only" do
      ctx = tenant_ctx("gh2659-t1ao")
      seed_type!(ctx, "ledger", [], %{append_only: true})

      assert outcomes(import!(ctx, "ledger", [entry("sap", "1", "A")])) == ["created"]
      assert outcomes(import!(ctx, "ledger", [entry("sap", "1", "A")])) == ["unchanged"]

      assert outcomes(import!(ctx, "ledger", [entry("sap", "1", "B")])) == ["entity_append_only"]
      assert length(rows(ctx, "ledger")) == 1
    end

    test "T11: a strict decimal compares after normalisation" do
      ctx = tenant_ctx("gh2659-t11")

      seed_type!(ctx, "priced", [
        %{
          name: "qty",
          type: :decimal,
          decimal_precision: 10,
          decimal_scale: 2,
          decimal_strict: true
        }
      ])

      assert outcomes(import!(ctx, "priced", [entry("sap", "1", "A", %{"qty" => "12.5"})])) ==
               ["created"]

      assert outcomes(import!(ctx, "priced", [entry("sap", "1", "A", %{"qty" => "12.50"})])) ==
               ["unchanged"]
    end
  end

  # ---- T2 ------------------------------------------------------------------------------------

  describe "T2: records without external_ref" do
    test "WITHOUT upsert_by an entry external_ref is ignored: no ref stored, same response shape" do
      ctx = tenant_ctx("gh2659-t2")
      seed_type!(ctx, "customer")

      with_ref = import!(ctx, "customer", [entry("sap", "1", "A")], false)

      without_ref =
        import!(
          ctx,
          "customer",
          [%{"field_values" => %{"customer_name" => "A"}}],
          false
        )

      normalise = fn conn ->
        conn
        |> results()
        |> Enum.map(&Map.put(&1, "record_id", "X"))
        |> Jason.encode!()
      end

      assert normalise.(with_ref) == normalise.(without_ref)
      assert [%{"status" => "ok"} = ok] = results(with_ref)
      assert Enum.sort(Map.keys(ok)) == ["record_id", "source_record_id", "status"]

      assert Enum.all?(
               rows(ctx, "customer"),
               &(is_nil(&1.external_system) and is_nil(&1.external_id))
             )

      # twice WITHOUT upsert_by creates two records (today's contract)
      import!(ctx, "customer", [entry("sap", "1", "A")], false)
      assert length(rows(ctx, "customer")) == 3
    end

    test "in upsert mode a ref-less or malformed-ref entry is a per-entry error, the rest are written" do
      ctx = tenant_ctx("gh2659-t2b")
      seed_type!(ctx, "customer")

      entries = [
        entry("sap", "1", "A"),
        %{"field_values" => %{"customer_name" => "no ref"}},
        %{"external_ref" => %{"system" => "SAP UPPER", "id" => "x"}, "field_values" => %{}},
        entry("sap", "2", "B")
      ]

      assert outcomes(import!(ctx, "customer", entries)) ==
               ["created", "external_ref_invalid", "external_ref_invalid", "created"]

      assert length(rows(ctx, "customer")) == 2
    end

    test "an unknown upsert_by value is a 422 before anything is written" do
      ctx = tenant_ctx("gh2659-t2c")
      seed_type!(ctx, "customer")

      for bad <- ["other", nil, 1, true] do
        body = Map.put(document("customer", [entry("sap", "1", "A")], false), "upsert_by", bad)
        conn = request(:post, "/api/v1/entities/records/customer/import", ctx, body)
        assert conn.status == 422, "#{inspect(bad)}: #{conn.status}"
      end

      assert rows(ctx, "customer") == []
    end
  end

  # ---- T3 ------------------------------------------------------------------------------------

  describe "T3: scope of a reference" do
    test "two systems with the same id are two records, updated independently; one pair in two types too" do
      ctx = tenant_ctx("gh2659-t3")
      seed_type!(ctx, "customer")
      seed_type!(ctx, "supplier")

      assert outcomes(
               import!(ctx, "customer", [entry("onec", "42", "A"), entry("sap", "42", "B")])
             ) == ["created", "created"]

      assert outcomes(import!(ctx, "customer", [entry("sap", "42", "B2")])) == ["updated"]
      assert outcomes(import!(ctx, "supplier", [entry("sap", "42", "S")])) == ["created"]

      names = rows(ctx, "customer") |> Enum.map(& &1.field_values["customer_name"]) |> Enum.sort()
      assert names == ["A", "B2"]
      assert length(rows(ctx, "supplier")) == 1
    end
  end

  # ---- T4 ------------------------------------------------------------------------------------

  describe "T4: partial failure, cap, duplicates, deleted refs" do
    test "five entries with two bad: HTTP 200, per-entry report, three rows; the corrected file converges" do
      ctx = tenant_ctx("gh2659-t4")
      seed_type!(ctx, "customer")

      bad_values = %{"external_ref" => ref("sap", "3"), "field_values" => %{}}
      no_ref = %{"field_values" => %{"customer_name" => "x"}}

      conn =
        import!(ctx, "customer", [
          entry("sap", "1", "A"),
          bad_values,
          entry("sap", "2", "B"),
          no_ref,
          entry("sap", "4", "D")
        ])

      assert outcomes(conn) ==
               ["created", "record_payload_invalid", "created", "external_ref_invalid", "created"]

      assert length(rows(ctx, "customer")) == 3

      fixed =
        import!(ctx, "customer", [
          entry("sap", "1", "A"),
          entry("sap", "3", "C"),
          entry("sap", "2", "B"),
          entry("sap", "5", "E"),
          entry("sap", "4", "D")
        ])

      assert outcomes(fixed) == ["unchanged", "created", "unchanged", "created", "unchanged"]
      assert length(rows(ctx, "customer")) == 5
    end

    test "201 entries -> 413 and nothing is written" do
      ctx = tenant_ctx("gh2659-t4b")
      seed_type!(ctx, "customer")
      entries = for i <- 1..201, do: entry("sap", "#{i}", "N#{i}")

      assert import!(ctx, "customer", entries).status == 413
      assert rows(ctx, "customer") == []
    end

    test "a duplicate ref in the file: the second entry is duplicate_external_ref_in_request" do
      ctx = tenant_ctx("gh2659-t4c")
      seed_type!(ctx, "customer")

      conn =
        import!(ctx, "customer", [
          entry("sap", "1", "A"),
          entry("sap", "1", "DIFFERENT"),
          entry("sap", "1", "A")
        ])

      assert outcomes(conn) ==
               [
                 "created",
                 "duplicate_external_ref_in_request",
                 "duplicate_external_ref_in_request"
               ]

      assert [only] = rows(ctx, "customer")
      assert only.field_values["customer_name"] == "A"
    end

    test "a soft-deleted ref is external_ref_record_deleted: no event, no revival" do
      ctx = tenant_ctx("gh2659-t4d")
      seed_type!(ctx, "customer")
      [created] = results(import!(ctx, "customer", [entry("sap", "1", "A")]))

      {:ok, _} =
        Records.delete_record(
          %{
            entity_type: "customer",
            record_id: created["record_id"],
            actor_id: ctx.user_id,
            idempotency_key: Ecto.UUID.generate()
          },
          ctx.schema_name
        )

      before = event_count(ctx)

      assert outcomes(import!(ctx, "customer", [entry("sap", "1", "A")])) ==
               ["external_ref_record_deleted"]

      assert event_count(ctx) == before
      assert [%{deleted: true}] = rows(ctx, "customer")
    end
  end

  # ---- T5 ------------------------------------------------------------------------------------

  describe "T5: concurrent imports" do
    # The per-tenant admission plug of Letflow.Router caps concurrent requests of a tenant below the
    # test pool, so the two racing imports enter at the entities router itself (the handler under
    # test; the auth context is hand-assigned as in entities_managed_by_test.exs).
    defp import_direct!(ctx, type, entries) do
      conn(:post, "/records/#{type}/import")
      |> Map.put(:body_params, document(type, entries, true))
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: ctx.user_id,
        tenant_id: ctx.tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "gh2659-t5")
      |> Letflow.Routers.Entities.call(Letflow.Routers.Entities.init([]))
    end

    # A soak/integration check of the route, not the proof of the race arbiter: the deterministic
    # forced overlap (a third connection holds the type's sequence row, two creates queue, one
    # wins by the partial unique index, the other converges; deadlock and lock-timeout observed
    # through Repo telemetry) lives in the PR-2 domain test `records_upsert_by_external_ref_test.exs`
    # (describe "T5: concurrency"), which is what kills a naive check-then-insert. Here the second
    # import sends the SAME refs in REVERSE order so the two requests contend on each ref from
    # opposite ends; the HTTP layer must not add a 5xx or a duplicate on top of that.
    test "two imports of the same refs, one reversed, behind a barrier leave exactly one record per ref" do
      ctx = tenant_ctx("gh2659-t5")
      seed_type!(ctx, "customer")
      file = for i <- 1..6, do: entry("sap", "#{i}", "N#{i}")
      parent = self()

      tasks =
        for {n, entries} <- [{1, file}, {2, Enum.reverse(file)}] do
          Task.async(fn ->
            send(parent, {:ready, n})

            receive do
              :go -> import_direct!(ctx, "customer", entries)
            after
              10_000 -> :no_go
            end
          end)
        end

      for _ <- 1..2, do: assert_receive({:ready, _}, 5_000)
      for task <- tasks, do: send(task.pid, :go)

      convs = Enum.map(tasks, &Task.await(&1, 60_000))

      assert Enum.all?(convs, &(&1.status == 200)),
             inspect(Enum.map(convs, &{&1.status, &1.resp_body}))

      all = Enum.flat_map(convs, &results/1)

      assert Enum.count(all, &(&1["outcome"] == "created")) == 6
      assert Enum.all?(all, &(&1["outcome"] in ["created", "unchanged", "updated"]))
      assert length(rows(ctx, "customer")) == 6
    end
  end

  # ---- T6 ------------------------------------------------------------------------------------

  describe "T6: tenant isolation" do
    test "the same ref in two tenants is two records and tenant A never changes tenant B" do
      a = tenant_ctx("gh2659-t6a")
      b = tenant_ctx("gh2659-t6b")
      seed_type!(a, "customer")
      seed_type!(b, "customer")

      assert outcomes(import!(a, "customer", [entry("sap", "1", "A")])) == ["created"]
      assert outcomes(import!(b, "customer", [entry("sap", "1", "B")])) == ["created"]
      assert outcomes(import!(a, "customer", [entry("sap", "1", "A2")])) == ["updated"]

      assert [%{field_values: %{"customer_name" => "B"}}] = rows(b, "customer")
      assert [%{field_values: %{"customer_name" => "A2"}}] = rows(a, "customer")
    end
  end

  # ---- T7 ------------------------------------------------------------------------------------

  describe "T7: derived idempotency key (#2543)" do
    test "the key is exactly 128 bytes for any id, and a 255 byte id is accepted" do
      request_id = Ecto.UUID.generate()
      id = String.duplicate("a", 255)

      key = ImportUpsert.idempotency_key(request_id, %{system: "sap", id: id})
      assert byte_size(key) == 128
      assert String.starts_with?(key, "entities-record-import:#{request_id}:ext:")
      assert byte_size(ImportUpsert.idempotency_key(request_id, %{system: "s", id: "1"})) == 128

      assert key != ImportUpsert.idempotency_key(request_id, %{system: "sa", id: "p" <> id})

      ctx = tenant_ctx("gh2659-t7")
      seed_type!(ctx, "customer")
      assert outcomes(import!(ctx, "customer", [entry("sap", id, "A")])) == ["created"]
      assert outcomes(import!(ctx, "customer", [entry("sap", id, "A")])) == ["unchanged"]
    end

    test "within one file the same ref with different values is a duplicate, never idempotency_key_reuse" do
      ctx = tenant_ctx("gh2659-t7b")
      seed_type!(ctx, "customer")

      conn = import!(ctx, "customer", [entry("sap", "1", "A"), entry("sap", "1", "B")])
      assert outcomes(conn) == ["created", "duplicate_external_ref_in_request"]
      refute conn.resp_body =~ "idempotency_key_reuse"
    end

    test "WITHOUT upsert_by two entries sharing a record_id keep today's #2543 dedup" do
      ctx = tenant_ctx("gh2659-t7c")
      seed_type!(ctx, "customer")
      rid = Ecto.UUID.generate()

      entries = [
        %{"record_id" => rid, "field_values" => %{"customer_name" => "A"}},
        %{"record_id" => rid, "field_values" => %{"customer_name" => "A"}},
        %{"record_id" => rid, "field_values" => %{"customer_name" => "B"}}
      ]

      reasons =
        ctx
        |> import!("customer", entries, false)
        |> results()
        |> Enum.map(&(&1["reason"]["type"] || &1["status"]))

      assert reasons == ["ok", "ok", "idempotency_key_reuse"]
      assert length(rows(ctx, "customer")) == 1
    end
  end

  # ---- T9 ------------------------------------------------------------------------------------

  describe "T9: event schema version guard" do
    defp count_version_reads(fun) do
      parent = self()
      handler = "gh2659-version-reads-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, _config ->
          query = Map.get(metadata, :query, "")

          if self() == parent and query =~ "event_type_registry" and query =~ "max(" do
            send(parent, :version_read)
          end
        end,
        nil
      )

      try do
        result = fun.()
        {result, drain_version_reads(0)}
      after
        :telemetry.detach(handler)
      end
    end

    defp drain_version_reads(n) do
      receive do
        :version_read -> drain_version_reads(n + 1)
      after
        0 -> n
      end
    end

    test "one schema-version read per request, however many entries" do
      ctx = tenant_ctx("gh2659-t9a")
      seed_type!(ctx, "customer")
      file = for i <- 1..5, do: entry("sap", "#{i}", "N#{i}")

      {conn, reads} = count_version_reads(fn -> import!(ctx, "customer", file) end)
      assert length(results(conn)) == 5
      assert reads == 1
    end

    test "a tenant below CREATED v2 gets a whole-request 503 and nothing is written" do
      ctx = tenant_ctx("gh2659-t9b")
      seed_type!(ctx, "customer")

      Repo.update_all(
        from(e in "event_type_registry", where: e.name == "ENTITY_RECORD_CREATED"),
        [set: [schema_version: 1]],
        prefix: ctx.schema_name
      )

      before = event_count(ctx)

      {conn, reads} =
        count_version_reads(fn -> import!(ctx, "customer", [entry("sap", "1", "A")]) end)

      assert conn.status == 503
      assert conn.resp_body =~ "event_schema_outdated"
      assert reads == 1
      assert rows(ctx, "customer") == []
      assert event_count(ctx) == before

      # without upsert_by the route is unaffected by the version
      assert outcomes_ok(import!(ctx, "customer", [entry("sap", "1", "A")], false))
    end

    test "GH #2784: a denied type below CREATED v2 is the 404 of an absent type, not the 503" do
      ctx = tenant_ctx("gh2784-t9c")
      seed_type!(ctx, "customer")
      insert_type_restriction!(ctx, "customer")

      Repo.update_all(
        from(e in "event_type_registry", where: e.name == "ENTITY_RECORD_CREATED"),
        [set: [schema_version: 1]],
        prefix: ctx.schema_name
      )

      {denied, reads} =
        count_version_reads(fn -> import!(ctx, "customer", [entry("sap", "1", "A")]) end)

      absent = import!(ctx, "nonexistent_type", [entry("sap", "1", "A")])
      assert denied.status == 404
      assert reads == 1

      assert Map.drop(strip_trace(denied), ["instance"]) ==
               Map.drop(strip_trace(absent), ["instance"])
    end

    defp outcomes_ok(conn), do: Enum.all?(results(conn), &(&1["status"] == "ok"))
  end

  # ---- T12 -----------------------------------------------------------------------------------

  describe "T12: permission model" do
    test "a caller without EntitiesRecordsImport is refused with upsert_by exactly as without" do
      ctx = tenant_ctx("gh2659-t12", ["PROCESS_OPERATOR"])
      seed_type!(ctx, "customer")

      with_upsert = import!(ctx, "customer", [entry("sap", "1", "A")])
      without = import!(ctx, "customer", [entry("sap", "1", "A")], false)

      assert with_upsert.status == 403
      assert without.status == 403
      assert strip_trace(with_upsert) == strip_trace(without)
      assert rows(ctx, "customer") == []
    end

    test "the Import holder updates existing records by ref with the route gate alone" do
      ctx = tenant_ctx("gh2659-t12b")
      seed_type!(ctx, "customer")
      assert outcomes(import!(ctx, "customer", [entry("sap", "1", "A")])) == ["created"]
      assert outcomes(import!(ctx, "customer", [entry("sap", "1", "B")])) == ["updated"]
    end
  end

  # ---- T13 / T14 -----------------------------------------------------------------------------

  describe "T13/T14: TypeAccess, field restrictions, the 404 fold" do
    test "a type-denied caller gets the byte-identical 404 of an unknown type, nothing written" do
      ctx = tenant_ctx("gh2659-t13")
      seed_type!(ctx, "customer")
      insert_type_restriction!(ctx, "customer")

      denied = import!(ctx, "customer", [entry("sap", "1", "A")])
      absent = import!(ctx, "nonexistent_type", [entry("sap", "1", "A")])

      assert denied.status == 404
      assert absent.status == 404

      assert Map.drop(strip_trace(denied), ["instance"]) ==
               Map.drop(strip_trace(absent), ["instance"])

      assert rows(ctx, "customer") == []
    end

    test "T14: an unknown or denied type whose FIRST entry has a malformed ref is still a 404" do
      ctx = tenant_ctx("gh2659-t14")
      seed_type!(ctx, "customer")
      insert_type_restriction!(ctx, "customer")
      malformed = [%{"external_ref" => "not-a-map", "field_values" => %{}}]

      assert import!(ctx, "nonexistent_type", malformed).status == 404
      assert import!(ctx, "customer", malformed).status == 404
    end

    test "a field-restricted actor: restricted key refused; existing ref refused before any compare" do
      ctx = tenant_ctx("gh2659-t13b")
      seed_type!(ctx, "customer", [%{name: "credit_limit", type: :string}])

      # an existing record, created before the restriction exists
      assert outcomes(
               import!(ctx, "customer", [
                 entry("sap", "1", "A", %{"credit_limit" => "10"}),
                 entry("sap", "4", "D", %{"credit_limit" => "7"})
               ])
             ) == ["created", "created"]

      insert_restriction!(ctx, "customer", "credit_limit")
      before = event_count(ctx)

      conn =
        import!(ctx, "customer", [
          # restricted key on an absent ref
          entry("sap", "2", "B", %{"credit_limit" => "5"}),
          # identical to the stored record: must NOT answer unchanged (probe)
          entry("sap", "1", "A", %{"credit_limit" => "10"}),
          # different value, existing ref: must NOT be updated (erase)
          entry("sap", "4", "A2"),
          # absent ref, no restricted key: proceeds
          entry("sap", "3", "C")
        ])

      assert outcomes(conn) == [
               "field_restricted",
               "field_restricted",
               "field_restricted",
               "created"
             ]

      assert event_count(ctx) == before + 1
      assert length(rows(ctx, "customer")) == 3

      # GH #2784: the same actor WITHOUT upsert_by is now refused per entry too (the create-mode
      # import shares the restricted-key rule); an entry without the restricted key still proceeds
      plain =
        import!(
          ctx,
          "customer",
          [entry("sap", "9", "P", %{"credit_limit" => "1"}), entry("sap", "8", "Q")],
          false
        )

      assert [
               %{"status" => "error", "reason" => %{"type" => "field_restricted"}},
               %{"status" => "ok"}
             ] = results(plain)

      # a grant lifts the restriction
      insert_grant!(ctx, "customer", "credit_limit")

      assert outcomes(
               import!(ctx, "customer", [entry("sap", "1", "A", %{"credit_limit" => "10"})])
             ) ==
               ["unchanged"]
    end
  end

  # ---- no echo -------------------------------------------------------------------------------

  describe "no echo of a reference's system or id" do
    test "no error entry, and no warning log, carries the system or the id" do
      ctx = tenant_ctx("gh2659-leak")
      seed_type!(ctx, "customer")
      seed_type!(ctx, "ledger", [], %{append_only: true})

      sys = "#{@marker}-sys"
      id = "#{@marker}-id-777"

      [created] = results(import!(ctx, "customer", [entry(sys, id, "A")]))
      assert created["status"] == "ok"
      assert outcomes(import!(ctx, "ledger", [entry(sys, id, "A")])) == ["created"]

      {:ok, _} =
        Records.delete_record(
          %{
            entity_type: "customer",
            record_id: created["record_id"],
            actor_id: ctx.user_id,
            idempotency_key: Ecto.UUID.generate()
          },
          ctx.schema_name
        )

      log =
        capture_log([level: :warning], fn ->
          deleted = import!(ctx, "customer", [entry(sys, id, "A")])
          dup = import!(ctx, "customer", [entry(sys, "other", "A"), entry(sys, "other", "B")])

          invalid =
            import!(ctx, "customer", [
              %{"external_ref" => ref("#{@marker} BAD", id), "field_values" => %{}}
            ])

          append_only = import!(ctx, "ledger", [entry(sys, id, "DIFFERENT")])

          for conn <- [deleted, dup, invalid, append_only] do
            for %{"status" => "error"} = result <- results(conn) do
              refute String.downcase(Jason.encode!(result)) =~ @marker, inspect(result)
            end
          end

          send(
            self(),
            {:outcomes,
             [outcomes(deleted), outcomes(dup), outcomes(invalid), outcomes(append_only)]}
          )
        end)

      assert_received {:outcomes,
                       [
                         ["external_ref_record_deleted"],
                         ["created", "duplicate_external_ref_in_request"],
                         ["external_ref_invalid"],
                         ["entity_append_only"]
                       ]}

      refute String.downcase(log) =~ @marker
    end
  end

  describe "no echo, extended: more reasons, create/update paths, whole-request bodies" do
    test "field_restricted, record_payload_invalid, 413, 422 and 503 never carry the ref; no warning log does" do
      ctx = tenant_ctx("gh2659-leak2")
      seed_type!(ctx, "customer", [%{name: "credit_limit", type: :string}])
      sys = "#{@marker}-sys"
      id = "#{@marker}-id-888"

      log =
        capture_log([level: :warning], fn ->
          # create and update paths (an ok entry echoes its own ref by design; the log must not)
          assert outcomes(
                   import!(ctx, "customer", [entry(sys, id, "A", %{"credit_limit" => "1"})])
                 ) ==
                   ["created"]

          assert outcomes(
                   import!(ctx, "customer", [entry(sys, id, "B", %{"credit_limit" => "1"})])
                 ) ==
                   ["updated"]

          invalid =
            import!(ctx, "customer", [
              %{"external_ref" => ref(sys, id <> "2"), "field_values" => %{}}
            ])

          insert_restriction!(ctx, "customer", "credit_limit")

          restricted_key =
            import!(ctx, "customer", [entry(sys, id <> "3", "C", %{"credit_limit" => "1"})])

          restricted_existing =
            import!(ctx, "customer", [entry(sys, id, "B", %{"credit_limit" => "1"})])

          assert outcomes(invalid) == ["record_payload_invalid"]
          assert outcomes(restricted_key) == ["field_restricted"]
          assert outcomes(restricted_existing) == ["field_restricted"]

          for conn <- [invalid, restricted_key, restricted_existing] do
            refute String.downcase(conn.resp_body) =~ @marker, conn.resp_body
          end

          # whole-request answers
          too_many =
            import!(ctx, "customer", for(_ <- 1..201, do: entry(sys, id, "N")))

          bad_upsert =
            request(
              :post,
              "/api/v1/entities/records/customer/import",
              ctx,
              Map.put(document("customer", [entry(sys, id, "A")], false), "upsert_by", "other")
            )

          Repo.update_all(
            from(e in "event_type_registry", where: e.name == "ENTITY_RECORD_CREATED"),
            [set: [schema_version: 1]],
            prefix: ctx.schema_name
          )

          outdated = import!(ctx, "customer", [entry(sys, id, "A")])

          assert {too_many.status, bad_upsert.status, outdated.status} == {413, 422, 503}

          for conn <- [too_many, bad_upsert, outdated] do
            refute String.downcase(conn.resp_body) =~ @marker, conn.resp_body
          end
        end)

      refute String.downcase(log) =~ @marker
    end
  end

  describe "review follow-ups: boundaries and ordering" do
    test "WITHOUT upsert_by a malformed external_ref is still ignored: 200 and created" do
      ctx = tenant_ctx("gh2659-f2")
      seed_type!(ctx, "customer")

      conn =
        import!(
          ctx,
          "customer",
          [%{"external_ref" => "not-a-map", "field_values" => %{"customer_name" => "A"}}],
          false
        )

      assert [%{"status" => "ok"}] = results(conn)
      assert [%{external_system: nil, external_id: nil}] = rows(ctx, "customer")
    end

    test "exactly 200 entries are accepted (the cap boundary)" do
      ctx = tenant_ctx("gh2659-cap")
      seed_type!(ctx, "customer")
      entries = for i <- 1..200, do: entry("sap", "#{i}", "N#{i}")

      conn = import!(ctx, "customer", entries)
      assert length(results(conn)) == 200
      assert Enum.all?(results(conn), &(&1["outcome"] == "created"))
      assert length(rows(ctx, "customer")) == 200
    end

    test "a malformed first-entry ref on an allowed type is 200 with a per-entry error" do
      ctx = tenant_ctx("gh2659-first")
      seed_type!(ctx, "customer")

      conn =
        import!(ctx, "customer", [
          %{"external_ref" => "not-a-map", "field_values" => %{}},
          entry("sap", "1", "A")
        ])

      assert outcomes(conn) == ["external_ref_invalid", "created"]
    end

    test "an invalid upsert_by is a 422 even on an unknown type (the mode check precedes the type pre-check)" do
      ctx = tenant_ctx("gh2659-order")

      body =
        Map.put(
          document("nonexistent_type", [entry("sap", "1", "A")], false),
          "upsert_by",
          "other"
        )

      assert request(:post, "/api/v1/entities/records/nonexistent_type/import", ctx, body).status ==
               422
    end

    test "two changed entries both get a new UPDATED event" do
      ctx = tenant_ctx("gh2659-two-updates")
      seed_type!(ctx, "customer")

      assert outcomes(import!(ctx, "customer", [entry("sap", "1", "A"), entry("sap", "2", "B")])) ==
               ["created", "created"]

      before = event_count(ctx)

      assert outcomes(
               import!(ctx, "customer", [entry("sap", "1", "A2"), entry("sap", "2", "B2")])
             ) == ["updated", "updated"]

      assert event_count(ctx) == before + 2

      assert Enum.take(Enum.reverse(types(ctx)), 2) == [
               "ENTITY_RECORD_UPDATED",
               "ENTITY_RECORD_UPDATED"
             ]
    end
  end
end
