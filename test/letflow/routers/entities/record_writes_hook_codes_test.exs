defmodule Letflow.Routers.Entities.RecordWritesHookCodesTest do
  @moduledoc """
  REQ-618 / GH #3445 (decision 0065 D6, slice E-4), criteria 5 and 6 at the route: the record create
  and update routes answer every hook code with the table's status and the constant body
  `{"error": "<code>"}`, none of them reaches the logged 500, and a token of another tenant naming a
  type that is defined and hooked only in tenant A gets the bytes of a type defined nowhere.

  The upsert record route does not exist (see `record_writes_hook_503_test.exs`): its half of the
  criteria is reported as unmeetable. The nearest HTTP surface of the upsert path is the import
  route's per-entry body, tested here for every code (P1) and across tenants (P2).

  Full pipeline (`Letflow.Router.call/2`, real API-token bearer). `async: false`: provisioned
  tenants and application env.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.EntityTypeHooks, as: Hooks
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Routers.Entities.RecordWrites
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @stats %{duration_us: 1, instructions_used: 1, heap_words_at_end: 1}

  # code => {status, expected "error" value}
  @table [
    script_failed: {422, "too_big"},
    script_error: {422, "script_error"},
    budget_exceeded: {422, "budget_exceeded"},
    memory_limit_exceeded: {422, "memory_limit_exceeded"},
    timeout: {422, "timeout"},
    output_invalid: {422, "output_invalid"},
    script_busy: {503, "script_busy"},
    script_rejected: {409, "script_rejected"},
    derived_value_conflict: {503, "derived_value_conflict"}
  ]

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> nil end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def reply(fun), do: Agent.update(__MODULE__, fn _ -> fun end)
    def run(_source, _input, _opts), do: Agent.get(__MODULE__, & &1).()
  end

  setup do
    a = tenant_ctx("e4a")
    b = tenant_ctx("e4b")

    P.active_definition!(a.schema, "tt", ["name", "total"])
    P.active_definition!(a.schema, "rd", ["name"])
    P.flag!(a.schema, "rd")
    P.active_definition!(a.schema, "invoice", ["name", "total"])

    rule = publish_rule!(a.schema, "derive_codes", with_reads?: true)
    bind!(a.schema, "tt", rule)
    bind!(a.schema, "invoice", rule)

    record = create!(a, "tt", %{"name" => "Ann"}, bound?: false)

    _ = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:entity_write_script_runner, StubRunner)

    {:ok, a: a, b: b, rule: rule, record_id: record}
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp tenant_ctx(prefix) do
    tenant = F.tenant!(prefix)
    schema = tenant.schema_name
    assert {:ok, _} = EventTypes.seed!(schema)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "#{prefix}-#{Ecto.UUID.generate()}",
        display_name: "E4 route test",
        email: "#{prefix}-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    %{schema: schema, slug: tenant.tenant.slug, plaintext: plaintext, user_id: user.id}
  end

  defp publish_rule!(schema, key, opts) do
    reads =
      if opts[:with_reads?],
        do: [
          P.field_read("rows", "rd", "name")
          |> Map.put("match", %{"field" => "name", "value_from" => "name"})
        ],
        else: []

    manifest = %{
      "input_schema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}},
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"total" => %{"type" => "string"}},
        "additionalProperties" => false
      },
      "derived_fields" => ["total"],
      "fail_codes" => ["too_big"],
      "limits" => %{"timeout_ms" => 5_000},
      "reads" => reads
    }

    F.published!(schema, key, "return { total = 'x' }", manifest, hook_kind: "entity_write")
  end

  defp bind!(schema, type, rule) do
    pin = %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

    assert {:ok, _} = Hooks.bind(schema, type, pin, P.actor())
  end

  defp create!(ctx, type, values, _opts) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: type,
          field_values: values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema
      )

    record.record_id
  end

  defp set_env(key, value) do
    previous = Application.fetch_env(:letflow, key)
    Application.put_env(:letflow, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, key, old)
        :error -> Application.delete_env(:letflow, key)
      end
    end)
  end

  defp request(method, path, ctx, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp ok_output(total \\ "T"), do: {:ok, %{output: %{"total" => total}, stats: @stats}}

  # Makes the next hooked write end in `code`.
  defp force(:script_failed, _ctx),
    do: StubRunner.reply(fn -> {:error, :script_failed, %{fail: %{code: "too_big"}}} end)

  defp force(:output_invalid, _ctx), do: StubRunner.reply(fn -> ok_output(5) end)

  defp force(:script_busy, _ctx),
    do: StubRunner.reply(fn -> {:error, :script_busy, %{}} end)

  defp force(:script_rejected, ctx) do
    StubRunner.reply(fn -> ok_output() end)
    P.kill_switch!(ctx.schema, true)
  end

  defp force(:derived_value_conflict, ctx) do
    StubRunner.reply(fn ->
      create!(ctx, "rd", %{"name" => "moved"}, [])
      ok_output()
    end)
  end

  defp force(code, _ctx), do: StubRunner.reply(fn -> {:error, code, %{}} end)

  defp create_request(ctx, type \\ "tt"),
    do:
      request(:post, "/api/v1/entities/records/#{type}", ctx, %{
        "field_values" => %{"name" => "Ann"}
      })

  defp update_request(ctx, record_id, type \\ "tt"),
    do:
      request(:put, "/api/v1/entities/records/#{type}/#{record_id}", ctx, %{
        "field_values" => %{"name" => "Ann"}
      })

  defp assert_hook_body(conn, status, error, rule) do
    assert conn.status == status, conn.resp_body
    assert conn.resp_body == Jason.encode!(%{"error" => error})

    for secret <- [rule.key, rule.sha256, "Ann", "SECRET"] do
      refute conn.resp_body =~ secret
    end
  end

  # ── criterion 5: status and body per code, per route ───────────────────────

  for {code, {status, error}} <- @table do
    test "R-create #{code} answers #{status} with the constant body", %{a: a, rule: rule} do
      force(unquote(code), a)

      log =
        capture_log(fn ->
          assert_hook_body(create_request(a), unquote(status), unquote(error), rule)
        end)

      # the logged 500 catch-all is not reached
      refute log =~ "entity record command failed"
    end

    test "R-update #{code} answers #{status} with the constant body", %{
      a: a,
      rule: rule,
      record_id: record_id
    } do
      force(unquote(code), a)

      log =
        capture_log(fn ->
          assert_hook_body(update_request(a, record_id), unquote(status), unquote(error), rule)
        end)

      refute log =~ "entity record command failed"
    end
  end

  test "T5-clauses the renderer has an explicit clause for every code" do
    for {code, {status, error}} <- @table do
      reason = if code == :script_failed, do: {:script_failed, error}, else: code

      log =
        capture_log(fn ->
          conn =
            RecordWrites.render_record_command(
              conn(:post, "/"),
              {:error, reason},
              :ok,
              MapSet.new()
            )

          assert conn.status == status
          assert Jason.decode!(conn.resp_body) == %{"error" => error}
        end)

      refute log =~ "entity record command failed"
    end
  end

  test "R-bodies the nine bodies are identical across the create and update routes", %{
    a: a,
    record_id: record_id
  } do
    for {code, _} <- @table do
      force(code, a)
      created = create_request(a)
      updated = update_request(a, record_id)
      assert {created.status, created.resp_body} == {updated.status, updated.resp_body}
    end
  end

  # ── P1: the nearest HTTP surface of the upsert path ────────────────────────

  for {code, _} <- @table do
    test "P1-import-entry #{code} is the constant per-entry internal_error", %{a: a, rule: rule} do
      force(unquote(code), a)

      conn =
        request(:post, "/api/v1/entities/records/tt/import", a, %{
          "record_export_schema_version" => "entities/record-export/v1",
          "entity_type" => "tt",
          "upsert_by" => "external_ref",
          "records" => [
            %{
              "external_ref" => %{"system" => "s", "id" => "1"},
              "field_values" => %{"name" => "Ann"}
            }
          ]
        })

      assert conn.status == 200, conn.resp_body

      assert [%{"status" => "error", "reason" => %{"type" => "internal_error"} = reason}] =
               Jason.decode!(conn.resp_body)["results"]

      assert map_size(reason) == 1

      for secret <- [rule.key, rule.sha256, "too_big", "SECRET"] do
        refute conn.resp_body =~ secret
      end
    end
  end

  # ── criterion 6: cross-tenant negative tests (INV-1, INV-5, INV-10) ────────

  describe "cross-tenant invoice" do
    setup %{b: b} do
      StubRunner.reply(fn -> flunk("a script ran for the other tenant") end)

      {:ok,
       nowhere: request(:post, "/api/v1/entities/records/nowhere", b, %{"field_values" => %{}})}
    end

    defp masked(conn, type),
      do: {conn.status, conn.resp_body |> String.replace(type, "TYPE") |> mask_trace()}

    defp mask_trace(body), do: Regex.replace(~r/"trace_id":"[^"]*"/, body, "\"trace_id\":\"T\"")

    test "X1-create B naming invoice gets the bytes of a type defined nowhere", %{
      b: b,
      nowhere: nowhere
    } do
      conn = create_request(b, "invoice")
      assert conn.status in [403, 404]
      assert masked(conn, "invoice") == masked(nowhere, "nowhere")
    end

    test "X2-update B naming invoice gets the bytes of a type defined nowhere", %{
      a: a,
      b: b
    } do
      StubRunner.reply(fn -> ok_output() end)
      id = create!(a, "invoice", %{"name" => "Ann"}, [])
      StubRunner.reply(fn -> flunk("a script ran for the other tenant") end)

      conn = update_request(b, id, "invoice")
      other = update_request(b, id, "nowhere")
      assert conn.status in [403, 404]
      assert masked(conn, "invoice") == masked(other, "nowhere")
    end

    test "P2-import B naming invoice gets the bytes of a type defined nowhere", %{b: b} do
      body = fn type ->
        request(:post, "/api/v1/entities/records/#{type}/import", b, %{
          "record_export_schema_version" => "entities/record-export/v1",
          "entity_type" => type,
          "upsert_by" => "external_ref",
          "records" => [
            %{
              "external_ref" => %{"system" => "s", "id" => "1"},
              "field_values" => %{"name" => "Ann"}
            }
          ]
        })
      end

      assert masked(body.("invoice"), "invoice") == masked(body.("nowhere"), "nowhere")
    end
  end
end
