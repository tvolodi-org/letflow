defmodule Letflow.Routers.EntitiesWriteTypeAccessTest do
  @moduledoc """
  GH #2784 PR A (design `lib/letflow/design/gh2784-write-routes-typeaccess.md` sections 2-5, 10):
  the record WRITE routes (`POST/PUT/DELETE /entities/records/...` and `POST .../import`) go
  through `Letflow.Entities.RecordAccess`.

    * T1: a type denied to the caller answers byte-identically to an ABSENT type, for a
      well-formed request (T1) and for malformed ones (T2: validation precedes the hidden answer
      exactly as for an absent type), for a managed type (T3) and for the import modes (T4).
    * T5: a denied request writes nothing (events, latest rows, synthetic type instances,
      idempotency keys, audit rows) and logs no warning.
    * T6: call-sequence parity (`:erlang.trace` on the four gate calls, Repo telemetry cut after
      the field-restrictions query).
    * T7: an allowed caller is unchanged.
    * T8: field restrictions on an open type (POST key 403, PUT blanket 403, DELETE response
      redacted, import per-entry `field_restricted`), T9 precedence, T10 `render_record_command/4`.

  Full pipeline (`Letflow.Router.call/2`, real bearer token), real Postgres, real commits, so
  `async: false` with the sandbox pinned to `:auto` for the whole test.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EntityWritesFixture
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  @schema_version "entities/record-export/v1"
  @secret "SECRETVALUE-7731"
  @restricted_detail "one or more requested fields are restricted for this caller"

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

        {:raw, raw} ->
          conn(method, path, raw) |> put_req_header("content-type", "application/json")

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
        username: "gh2784-user-#{Ecto.UUID.generate()}",
        display_name: "GH-2784 test user",
        email: "gh2784-#{Ecto.UUID.generate()}@example.com",
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

  defp seed_type!(ctx, name) do
    fields = [
      %{name: "customer_name", type: :string, required: true},
      %{name: "credit_limit", type: :string}
    ]

    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{name: name, display_name: name, fields: fields},
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition(name, ctx.user_id, "gh2784", ctx.schema_name)
    :ok
  end

  defp create_direct!(ctx, type, field_values) do
    {:ok, %{record: %Latest{} = record}} =
      Records.create_record(
        %{
          entity_type: type,
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
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

  defp insert_grant!(ctx, type, field) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(ctx.user_id),
          entity_type: type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  # status, the stable response headers, and the decoded body without the per-request trace id.
  defp norm(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _} -> name =~ ~r/id|trace|date|time/ end)
      |> Enum.sort()

    {conn.status, headers, conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")}
  end

  defp counts(ctx) do
    for table <-
          ~w(events entity_record_latest entity_type_instances event_idempotency audit_entries),
        into: %{} do
      {table, Repo.aggregate(table, :count, prefix: ctx.schema_name)}
    end
  end

  defp record_doc(type, entries) do
    %{
      "record_export_schema_version" => @schema_version,
      "entity_type" => type,
      "records" => entries
    }
  end

  defp entry(name, extra \\ %{}),
    do: %{"field_values" => Map.merge(%{"customer_name" => name}, extra)}

  defp upsert_entry(id, name, extra \\ %{}) do
    %{
      "external_ref" => %{"system" => "sap", "id" => id},
      "field_values" => Map.merge(%{"customer_name" => name}, extra)
    }
  end

  defp path(type), do: "/api/v1/entities/records/#{type}"
  defp path(type, id), do: "/api/v1/entities/records/#{type}/#{id}"

  # A denied caller (tenant D: type "customer" restricted, no grant, one pre-existing record)
  # and an absent one (tenant A: no such type at all). Both get the SAME path and body.
  defp denied_and_absent(slug) do
    denied = tenant_ctx("#{slug}-d")
    seed_type!(denied, "customer")
    seed_type!(denied, "lonely")
    record = create_direct!(denied, "customer", %{"customer_name" => "existing"})
    insert_type_restriction!(denied, "customer")
    insert_type_restriction!(denied, "lonely")

    absent = tenant_ctx("#{slug}-a")
    {denied, absent, record.record_id}
  end

  # ---- T1 / T2 / T4: denied == absent --------------------------------------------------------

  describe "T1: a well-formed request to a denied type is byte-identical to an absent type's" do
    test "POST, PUT, DELETE, import create (empty and non-empty) and import upsert" do
      {denied, absent, record_id} = denied_and_absent("gh2784-t1")
      body = %{"field_values" => %{"customer_name" => "N"}}

      requests = [
        {:post, path("customer"), body},
        {:put, path("customer", record_id), body},
        {:delete, path("customer", record_id), nil},
        {:post, path("customer") <> "/import", record_doc("customer", [entry("A")])},
        {:post, path("customer") <> "/import",
         record_doc("customer", [upsert_entry("1", "A")]) |> Map.put("upsert_by", "external_ref")},
        {:post, path("customer") <> "/import",
         record_doc("customer", []) |> Map.put("upsert_by", "external_ref")}
      ]

      for {method, p, b} <- requests do
        d = request(method, p, denied, b)
        a = request(method, p, absent, b)
        assert d.status == 404, "denied #{method} #{p}: #{d.status} #{d.resp_body}"
        assert norm(d) == norm(a), "#{method} #{p}: denied differs from absent"
      end

      # a different absent NAME in the same tenant answers the same too
      same_tenant_absent = request(:post, path("nonexistent"), denied, body)
      assert norm(request(:post, path("customer"), denied, body)) == norm(same_tenant_absent)
    end

    test "import create of an empty records array is 200 with no results for both" do
      {denied, absent, _} = denied_and_absent("gh2784-t1e")
      doc = record_doc("customer", [])
      p = path("customer") <> "/import"
      d = request(:post, p, denied, doc)
      a = request(:post, p, absent, doc)
      assert {200, _, %{"results" => []}} = norm(d)
      assert norm(d) == norm(a)
    end
  end

  describe "T2: validation errors precede the hidden answer exactly as for an absent type" do
    test "malformed requests give the same answer for a denied and an absent type" do
      {denied, absent, record_id} = denied_and_absent("gh2784-t2")
      doc = record_doc("customer", [entry("A")])

      cases = [
        {:post, path("customer"), {:raw, "[1]"}, 400},
        {:post, path("customer"), %{"idempotency_key" => "k"}, 422},
        {:post, path("customer"), %{"field_values" => %{}, "idempotency_key" => ""}, 422},
        {:put, path("customer", "not-a-uuid"), %{"field_values" => %{}}, 404},
        {:put, path("customer", record_id), %{"idempotency_key" => "k"}, 422},
        {:put, path("customer", record_id), {:raw, "[1]"}, 400},
        {:delete, path("customer", record_id) <> "?expected_last_event_global_seq=abc", nil, 400},
        {:delete, path("customer", "not-a-uuid"), nil, 404},
        {:post, path("customer") <> "/import", Map.put(doc, "record_export_schema_version", "x"),
         422},
        {:post, path("customer") <> "/import", Map.put(doc, "entity_type", "other"), 422},
        {:post, path("customer") <> "/import", Map.put(doc, "upsert_by", "nope"), 422},
        {:post, path("customer") <> "/import",
         Map.put(doc, "records", List.duplicate(entry("A"), 201)), 413}
      ]

      for {method, p, b, expected} <- cases do
        d = request(method, p, denied, b)
        a = request(method, p, absent, b)
        assert a.status == expected, "absent #{method} #{p}: #{a.status} #{a.resp_body}"
        assert norm(d) == norm(a), "#{method} #{p}: denied differs from absent"
      end
    end
  end

  describe "T3: a managed type" do
    setup do
      ctx = tenant_ctx("gh2784-t3")
      EntityWritesFixture.install_managed_fixture!(ctx.schema_name)
      absent = tenant_ctx("gh2784-t3a")
      %{ctx: ctx, absent: absent}
    end

    test "denied to the caller it is the absent answer (404), not the managed 403", %{
      ctx: ctx,
      absent: absent
    } do
      insert_type_restriction!(ctx, "fxm_unit")
      id = Ecto.UUID.generate()
      body = %{"field_values" => %{"name" => "N"}}

      for {method, p, b} <- [
            {:post, path("fxm_unit"), body},
            {:put, path("fxm_unit", id), body},
            {:delete, path("fxm_unit", id), nil},
            {:post, path("fxm_unit") <> "/import", record_doc("fxm_unit", [entry("A")])}
          ] do
        d = request(method, p, ctx, b)
        a = request(method, p, absent, b)
        assert d.status == 404, "denied managed #{method} #{p}: #{d.status} #{d.resp_body}"
        assert norm(d) == norm(a)
      end
    end

    test "visible to the caller it is the managed 403, before the body is read", %{ctx: ctx} do
      id = Ecto.UUID.generate()

      for {method, p} <- [
            {:post, path("fxm_unit")},
            {:put, path("fxm_unit", id)},
            {:delete, path("fxm_unit", id) <> "?expected_last_event_global_seq=abc"},
            {:post, path("fxm_unit") <> "/import"}
          ] do
        conn = request(method, p, ctx, {:raw, "[1]"})
        assert conn.status == 403, "#{method} #{p}: #{conn.status} #{conn.resp_body}"
        assert conn.resp_body =~ "managed"
      end
    end
  end

  describe "T4: import create on a denied type" do
    test "a two-entry import behaves as for an absent type" do
      {denied, absent, _} = denied_and_absent("gh2784-t4")
      p = path("customer") <> "/import"

      doc = record_doc("customer", [entry("A"), entry("B")])
      assert norm(request(:post, p, denied, doc)) == norm(request(:post, p, absent, doc))
      assert request(:post, p, denied, doc).status == 404
    end
  end

  # ---- T5: no side effects -------------------------------------------------------------------

  describe "T5: a denied request writes nothing" do
    test "no event, latest row, synthetic instance, idempotency key or audit row; no warning" do
      {denied, _absent, record_id} = denied_and_absent("gh2784-t5")
      before = counts(denied)
      body = %{"field_values" => %{"customer_name" => "N"}, "idempotency_key" => "k-2784"}

      log =
        capture_log(fn ->
          for {method, p, b} <- [
                {:post, path("customer"), body},
                {:post, path("lonely"), body},
                {:put, path("customer", record_id), body},
                {:delete, path("customer", record_id), nil},
                {:post, path("lonely") <> "/import", record_doc("lonely", [entry("A")])},
                {:post, path("lonely") <> "/import",
                 record_doc("lonely", [upsert_entry("1", "A")])
                 |> Map.put("upsert_by", "external_ref")}
              ] do
            assert request(method, p, denied, b).status == 404
          end
        end)

      assert counts(denied) == before
      refute log =~ "[warning]"
      refute log =~ "[error]"

      # the stored record is untouched
      assert %Latest{deleted: false} =
               Repo.one!(from(l in Latest, where: l.record_id == ^record_id),
                 prefix: denied.schema_name
               )
    end
  end

  # ---- T6: call-sequence parity --------------------------------------------------------------

  describe "T6: the gate makes the same calls, then the same statements" do
    @gate_calls [
      {Letflow.Entities.ManagedTypes, :owner_of, 2},
      {Letflow.Entities.TypeAccess, :authorized?, 3},
      {Letflow.Entities.Definitions, :get_active_definition_by_name, 2},
      {Letflow.Entities.Query.FieldGrants, :load_restrictions, 3}
    ]

    # A process never receives the trace messages of ITSELF, so a separate tracer process
    # collects them; the router is dispatched in-process, so the test pid is the traced one.
    defp traced_calls(fun) do
      for {m, _f, _a} <- @gate_calls, do: Code.ensure_loaded!(m)
      tracer = spawn_link(fn -> tracer_loop([]) end)
      for mfa <- @gate_calls, do: :erlang.trace_pattern(mfa, true, [])
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])

      try do
        fun.()
      after
        :erlang.trace(self(), false, [:call])
        for mfa <- @gate_calls, do: :erlang.trace_pattern(mfa, false, [])
      end

      :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, _ref} -> :ok
      after
        5_000 -> flunk("trace messages were not delivered")
      end

      send(tracer, {:collect, self()})

      receive do
        {:calls, calls} -> calls
      after
        5_000 -> flunk("tracer did not answer")
      end
    end

    defp tracer_loop(acc) do
      receive do
        {:trace, _pid, :call, {m, f, args}} -> tracer_loop([{m, f, length(args)} | acc])
        {:collect, from} -> send(from, {:calls, Enum.reverse(acc)})
      end
    end

    defp recorded_queries(schema, fun) do
      parent = self()
      handler = "gh2784-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, _config ->
          if self() == parent, do: send(parent, {:query, Map.get(metadata, :query, "")})
        end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

      drain_queries(schema, [])
    end

    defp drain_queries(schema, acc) do
      receive do
        {:query, q} -> drain_queries(schema, [String.replace(q, schema, "SCHEMA") | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "denied and absent: the four gate calls in order, then identical statements" do
      {denied, absent, _} = denied_and_absent("gh2784-t6")
      body = %{"field_values" => %{"customer_name" => "N"}}

      denied_calls = traced_calls(fn -> request(:post, path("customer"), denied, body) end)
      absent_calls = traced_calls(fn -> request(:post, path("customer"), absent, body) end)

      assert denied_calls == @gate_calls
      assert absent_calls == @gate_calls

      cut = fn queries ->
        index = Enum.find_index(queries, &(&1 =~ "entity_field_restrictions"))
        assert index, "the field-restrictions query (the last gate call) was not issued"
        Enum.drop(queries, index + 1)
      end

      d =
        recorded_queries(denied.schema_name, fn ->
          request(:post, path("customer"), denied, body)
        end)

      a =
        recorded_queries(absent.schema_name, fn ->
          request(:post, path("customer"), absent, body)
        end)

      assert cut.(d) == cut.(a)
    end
  end

  # ---- T7: allowed caller unchanged ----------------------------------------------------------

  describe "T7: an allowed caller is unchanged" do
    test "POST 201, PUT 200 replace, DELETE 200 with the real values; unrelated restriction rows" do
      ctx = tenant_ctx("gh2784-t7")
      seed_type!(ctx, "customer")
      seed_type!(ctx, "other")
      insert_type_restriction!(ctx, "other")
      insert_restriction!(ctx, "other", "credit_limit")

      created =
        request(:post, path("customer"), ctx, %{
          "field_values" => %{"customer_name" => "A", "credit_limit" => "7"}
        })

      assert created.status == 201

      assert %{"record_id" => id, "field_values" => %{"credit_limit" => "7"}} =
               Jason.decode!(created.resp_body)

      updated =
        request(:put, path("customer", id), ctx, %{"field_values" => %{"customer_name" => "B"}})

      assert updated.status == 200
      assert Jason.decode!(updated.resp_body)["field_values"] == %{"customer_name" => "B"}

      deleted = request(:delete, path("customer", id), ctx, nil)
      assert deleted.status == 200

      assert %{"deleted" => true, "field_values" => %{"customer_name" => "B"}} =
               Jason.decode!(deleted.resp_body)

      imported =
        request(:post, path("customer") <> "/import", ctx, record_doc("customer", [entry("C")]))

      assert imported.status == 200
      assert [%{"status" => "ok"}] = Jason.decode!(imported.resp_body)["results"]
    end
  end

  # ---- T8 / T9: field restrictions on an open type -------------------------------------------

  describe "F5: an absent record under a visible type" do
    test "PUT and DELETE of an unknown record id are the 404 they always were" do
      ctx = tenant_ctx("gh2784-f5")
      seed_type!(ctx, "customer")
      id = Ecto.UUID.generate()
      before = counts(ctx)

      put =
        request(:put, path("customer", id), ctx, %{"field_values" => %{"customer_name" => "Z"}})

      delete = request(:delete, path("customer", id), ctx, nil)
      assert put.status == 404
      assert delete.status == 404
      assert norm(put) == norm(delete)
      assert counts(ctx) == before
    end
  end

  describe "T8: an actor holding a restricted field" do
    setup do
      ctx = tenant_ctx("gh2784-t8")
      seed_type!(ctx, "customer")

      record =
        create_direct!(ctx, "customer", %{"customer_name" => "A", "credit_limit" => @secret})

      insert_restriction!(ctx, "customer", "credit_limit")
      %{ctx: ctx, record_id: record.record_id}
    end

    test "POST naming a restricted key is the constant 403, writes nothing; others are 201", %{
      ctx: ctx
    } do
      before = counts(ctx)

      conn =
        request(:post, path("customer"), ctx, %{
          "field_values" => %{"customer_name" => "N", "credit_limit" => "1"}
        })

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["detail"] == @restricted_detail
      refute conn.resp_body =~ "credit_limit"
      assert counts(ctx) == before

      ok =
        request(:post, path("customer"), ctx, %{"field_values" => %{"customer_name" => "N"}})

      assert ok.status == 201
    end

    test "PUT is a blanket 403 for any record and any body, after id and body validation", %{
      ctx: ctx,
      record_id: record_id
    } do
      before = counts(ctx)
      body = %{"field_values" => %{"customer_name" => "Z"}}

      live = request(:put, path("customer", record_id), ctx, body)
      random = request(:put, path("customer", Ecto.UUID.generate()), ctx, body)
      assert live.status == 403
      assert norm(live) == norm(random)
      assert Jason.decode!(live.resp_body)["detail"] == @restricted_detail

      assert request(:put, path("customer", "not-a-uuid"), ctx, body).status == 404
      assert request(:put, path("customer", record_id), ctx, {:raw, "[1]"}).status == 400

      assert request(:put, path("customer", record_id), ctx, %{"idempotency_key" => "k"}).status ==
               422

      assert counts(ctx) == before
    end

    test "POST naming a restricted key with the grant is 201 and shows the real value", %{
      ctx: ctx
    } do
      insert_grant!(ctx, "customer", "credit_limit")

      conn =
        request(:post, path("customer"), ctx, %{
          "field_values" => %{"customer_name" => "N", "credit_limit" => "1"}
        })

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["field_values"]["credit_limit"] == "1"
    end

    test "the 403 never names the restricted field in the response or the log", %{ctx: ctx} do
      log =
        capture_log(fn ->
          for {method, p, b} <- [
                {:post, path("customer"),
                 %{"field_values" => %{"customer_name" => "N", "credit_limit" => "1"}}},
                {:put, path("customer", Ecto.UUID.generate()),
                 %{"field_values" => %{"customer_name" => "N"}}}
              ] do
            conn = request(method, p, ctx, b)
            assert conn.status == 403
            refute conn.resp_body =~ "credit_limit"
          end
        end)

      refute log =~ "credit_limit"
    end

    test "PUT with the grant replaces the whole document", %{ctx: ctx, record_id: record_id} do
      insert_grant!(ctx, "customer", "credit_limit")

      conn =
        request(:put, path("customer", record_id), ctx, %{
          "field_values" => %{"customer_name" => "Z", "credit_limit" => "9"}
        })

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["field_values"]["credit_limit"] == "9"
    end

    test "DELETE answers 200 with the restricted value redacted, first and again", %{
      ctx: ctx,
      record_id: record_id
    } do
      for _attempt <- 1..2 do
        conn = request(:delete, path("customer", record_id), ctx, nil)
        assert conn.status == 200
        refute conn.resp_body =~ @secret
        body = Jason.decode!(conn.resp_body)
        assert body["field_values"]["credit_limit"] == "__field_redacted__"
        assert body["field_values"]["customer_name"] == "A"
        assert body["deleted"] == true
      end
    end

    test "DELETE by an actor holding the grant sees the real value", %{ctx: ctx, record_id: id} do
      insert_grant!(ctx, "customer", "credit_limit")
      conn = request(:delete, path("customer", id), ctx, nil)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["field_values"]["credit_limit"] == @secret
    end

    test "import create: the entry naming a restricted key is field_restricted, others created",
         %{ctx: ctx} do
      doc =
        record_doc("customer", [
          entry("A", %{"credit_limit" => "5"}),
          entry("B")
        ])

      conn = request(:post, path("customer") <> "/import", ctx, doc)
      assert conn.status == 200

      assert [
               %{"status" => "error", "reason" => %{"type" => "field_restricted"}},
               %{"status" => "ok"}
             ] = Jason.decode!(conn.resp_body)["results"]

      names =
        Repo.all(from(l in Latest, where: l.entity_type == "customer", select: l.field_values),
          prefix: ctx.schema_name
        )

      refute Enum.any?(names, &(&1["customer_name"] == "A" and &1["credit_limit"] == "5"))

      insert_grant!(ctx, "customer", "credit_limit")
      granted = request(:post, path("customer") <> "/import", ctx, doc)

      assert Enum.all?(Jason.decode!(granted.resp_body)["results"], &(&1["status"] == "ok"))
    end
  end

  describe "T9: precedence" do
    test "denied AND a restricted key in the body is the 404 path, not the 403" do
      {denied, absent, _} = denied_and_absent("gh2784-t9")
      insert_restriction!(denied, "customer", "credit_limit")
      body = %{"field_values" => %{"customer_name" => "N", "credit_limit" => "1"}}

      d = request(:post, path("customer"), denied, body)
      a = request(:post, path("customer"), absent, body)
      assert d.status == 404
      assert norm(d) == norm(a)
    end

    test "allowed with a restricted key and a malformed body: the validation error wins" do
      ctx = tenant_ctx("gh2784-t9b")
      seed_type!(ctx, "customer")
      insert_restriction!(ctx, "customer", "credit_limit")

      # a restricted key AND an invalid (empty) idempotency key: validation must win
      post =
        request(:post, path("customer"), ctx, %{
          "field_values" => %{"credit_limit" => "1"},
          "idempotency_key" => ""
        })

      put =
        request(:put, path("customer", Ecto.UUID.generate()), ctx, %{"idempotency_key" => "k"})

      assert post.status == 422
      assert put.status == 422
    end
  end

  # ---- T10: render_record_command/4 ----------------------------------------------------------

  describe "T10: render_record_command/4" do
    setup do
      ctx = tenant_ctx("gh2784-t10")
      seed_type!(ctx, "customer")

      record = %Latest{
        record_id: Ecto.UUID.generate(),
        entity_type: "customer",
        field_values: %{"customer_name" => "A", "credit_limit" => @secret},
        deleted: false,
        entity_def_version: <<1, 2>>,
        last_event_global_seq: 5
      }

      conn =
        conn(:get, "/")
        |> assign(:scoped_opts, prefix: ctx.schema_name)
        |> assign(:trace_id, "t10")

      %{conn: conn, record: record}
    end

    test "redacts the restricted keys on every success status when the set is non-empty", %{
      conn: conn,
      record: record
    } do
      restricted = MapSet.new(["credit_limit"])

      for status <- [:created, :ok] do
        out =
          Letflow.Routers.Entities.render_record_command(
            conn,
            {:ok, %{record: record}},
            status,
            restricted
          )

        refute out.resp_body =~ @secret
        fv = Jason.decode!(out.resp_body)["field_values"]
        assert fv == %{"customer_name" => "A", "credit_limit" => "__field_redacted__"}
      end
    end

    test "an empty set renders the stored values", %{conn: conn, record: record} do
      out =
        Letflow.Routers.Entities.render_record_command(
          conn,
          {:ok, %{record: record}},
          :ok,
          MapSet.new()
        )

      assert Jason.decode!(out.resp_body)["field_values"]["credit_limit"] == @secret
    end

    test "an error result ignores the set", %{conn: conn} do
      out =
        Letflow.Routers.Entities.render_record_command(
          conn,
          {:error, {:definition_not_found, "customer"}},
          :ok,
          MapSet.new(["credit_limit"])
        )

      assert out.status == 404
    end
  end
end
