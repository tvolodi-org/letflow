defmodule Letflow.Routers.Entities.RecordWritesHook503Test do
  @moduledoc """
  REQ-607 / GH #3413 part A, criterion C6b: the record create and update routes answer 503 with one
  constant body for `:entity_write_contention` and `:derived_value_conflict`, and neither reaches the
  500 catch-all. Full pipeline (`Letflow.Router.call/2`, real API-token bearer).

  The two conditions are forced: contention by a read-phase exception (the `:entity_write_before_reads`
  seam raises a Postgrex lock error), the conflict by a runner stub that writes a read type on every
  attempt, so each fingerprint compare fails. The real lock timeout is part B's.

  The upsert record route does not exist: the only caller of `upsert_record_by_external_ref/4` that
  renders is the import route, whose per-entry body is the constant `internal_error` (see the last
  test). `async: false`: provisioned tenant, application env.
  """

  use Letflow.DataCase, async: false

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

  @detail "the write could not be completed; retry"

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
    tenant = F.tenant!("e3r")
    schema = tenant.schema_name
    assert {:ok, _} = EventTypes.seed!(schema)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "e3r-#{Ecto.UUID.generate()}",
        display_name: "E3 route test",
        email: "e3r-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    P.active_definition!(schema, "tt", ["name", "total"])
    P.active_definition!(schema, "rd", ["name"])
    P.flag!(schema, "rd")

    manifest = %{
      "input_schema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}},
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"total" => %{"type" => "string"}},
        "additionalProperties" => false
      },
      "derived_fields" => ["total"],
      "fail_codes" => [],
      "limits" => %{"timeout_ms" => 5_000},
      "reads" => [
        P.field_read("rows", "rd", "name")
        |> Map.put("match", %{"field" => "name", "value_from" => "name"})
      ]
    }

    rule =
      F.published!(schema, "derive_503", "return { total = 'x' }", manifest,
        hook_kind: "entity_write"
      )

    {:ok, record} =
      Records.create_record(
        %{
          entity_type: "tt",
          field_values: %{"name" => "Ann"},
          actor_id: user.id,
          idempotency_key: Ecto.UUID.generate()
        },
        schema
      )

    assert {:ok, _} =
             Hooks.bind(
               schema,
               "tt",
               %{
                 "script_key" => rule.key,
                 "script_version" => rule.version,
                 "script_sha256" => rule.sha256
               },
               P.actor()
             )

    _ = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:entity_write_script_runner, StubRunner)

    ctx = %{schema: schema, slug: tenant.tenant.slug, plaintext: plaintext, user_id: user.id}
    {:ok, ctx: ctx, rule: rule, record_id: record.record.record_id}
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

  defp ok_output,
    do:
      {:ok,
       %{
         output: %{"total" => "T"},
         stats: %{duration_us: 1, instructions_used: 1, heap_words_at_end: 1}
       }}

  defp force(:contention, _ctx) do
    set_env(:entity_write_before_reads, fn ->
      raise %Postgrex.Error{postgres: %{code: :lock_not_available, message: "SECRET-DETAIL"}}
    end)

    StubRunner.reply(fn -> ok_output() end)
  end

  defp force(:conflict, ctx) do
    StubRunner.reply(fn ->
      {:ok, _} =
        Records.create_record(
          %{
            entity_type: "rd",
            field_values: %{"name" => "moved"},
            actor_id: ctx.user_id,
            idempotency_key: Ecto.UUID.generate()
          },
          ctx.schema
        )

      ok_output()
    end)
  end

  defp assert_503(conn, rule, kind) do
    assert conn.status == 503, conn.resp_body

    # REQ-618 changed the conflict body to the D6 shape `{"error": "<code>"}`; the contention
    # body (not a D6 row) keeps its E-3 problem-JSON detail.
    case kind do
      :contention -> assert Jason.decode!(conn.resp_body)["detail"] == @detail
      :conflict -> assert Jason.decode!(conn.resp_body) == %{"error" => "derived_value_conflict"}
    end

    for secret <- [rule.key, rule.sha256, "Ann", "SECRET-DETAIL", "T\""] do
      refute conn.resp_body =~ secret
    end
  end

  for code <- [:contention, :conflict] do
    test "C6b-create-#{code} answers the constant 503", %{ctx: ctx, rule: rule} do
      force(unquote(code), ctx)

      conn =
        request(:post, "/api/v1/entities/records/tt", ctx, %{"field_values" => %{"name" => "Ann"}})

      assert_503(conn, rule, unquote(code))
    end

    test "C6b-update-#{code} answers the constant 503", %{
      ctx: ctx,
      rule: rule,
      record_id: record_id
    } do
      force(unquote(code), ctx)

      conn =
        request(:put, "/api/v1/entities/records/tt/#{record_id}", ctx, %{
          "field_values" => %{"name" => "Ann"}
        })

      assert_503(conn, rule, unquote(code))
    end
  end

  test "C6b-clause the renderer has an explicit clause for each code" do
    conn =
      RecordWrites.render_record_command(
        conn(:post, "/"),
        {:error, :entity_write_contention},
        :ok,
        MapSet.new()
      )

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["detail"] == @detail

    conn =
      RecordWrites.render_record_command(
        conn(:post, "/"),
        {:error, :derived_value_conflict},
        :ok,
        MapSet.new()
      )

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"error" => "derived_value_conflict"}
  end

  test "C6b-import-entry a hooked upsert entry answers the constant internal_error", %{
    ctx: ctx,
    rule: rule
  } do
    force(:contention, ctx)

    conn =
      request(:post, "/api/v1/entities/records/tt/import", ctx, %{
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

    for secret <- [rule.key, rule.sha256, "SECRET-DETAIL"] do
      refute conn.resp_body =~ secret
    end
  end
end
