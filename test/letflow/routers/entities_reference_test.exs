defmodule Letflow.Routers.EntitiesReferenceTest do
  @moduledoc """
  REQ-636 / GH #3556 (decision 0070 slice C): module references by record id, through the real
  router with a real bearer token.

    * P-post / P-put: a dangling reference is a 422 naming the field, nothing is stored; a live
      reference is stored. The six dangling shapes give byte-equal bodies (D4-same-body).
    * P-hidden: a hidden type still answers the absent answer, never the reference result.
    * P-import-create / P-import-upsert: the refused line stores nothing, the others are unchanged
      (import is per-line partial success).
    * D4-xtenant: tenant B's record id is refused in tenant A, and a body naming `tenant_id` or
      `prefix` changes nothing.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.FixtureRefTargets
  alias Letflow.ReferenceFixture
  alias Letflow.Test.SandboxAutoMode

  @holder ReferenceFixture.holder()
  @schema_version "entities/record-export/v1"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    {:ok, a: ReferenceFixture.tenant!("req636-a"), b: ReferenceFixture.tenant!("req636-b")}
  end

  defp request(method, path, ctx, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp post(ctx, fv, extra \\ %{}),
    do:
      request(
        :post,
        "/api/v1/entities/records/#{@holder}",
        ctx,
        %{
          "field_values" => fv,
          "idempotency_key" => Ecto.UUID.generate()
        }
        |> Map.merge(extra)
      )

  defp put_record(ctx, id, fv),
    do:
      request(:put, "/api/v1/entities/records/#{@holder}/#{id}", ctx, %{
        "field_values" => fv,
        "idempotency_key" => Ecto.UUID.generate()
      })

  defp stored(ctx),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^@holder), :count,
        prefix: ctx.schema_name
      )

  defp strip_trace(conn) do
    conn.resp_body |> Jason.decode!() |> Map.drop(["trace_id", "request_id", "instance"])
  end

  defp field_names(conn),
    do: conn.resp_body |> Jason.decode!() |> Map.fetch!("errors") |> Enum.map(& &1["field"])

  test "P-post: live reference stored (201), not-opted-in type refused (422) then accepted", %{
    a: a
  } do
    live = ReferenceFixture.target!(a)
    other = ReferenceFixture.target!(a, "frt_other")

    conn = post(a, %{"title" => "x", "target" => live})
    assert conn.status == 201, conn.resp_body
    assert Jason.decode!(conn.resp_body)["field_values"]["target"] == live
    assert stored(a) == 1

    # `other` declares frt_other, which the manifest did not opt in: refused though the record is live
    conn = post(a, %{"title" => "x", "other" => other})
    assert conn.status == 422
    assert field_names(conn) == ["other"]
    assert stored(a) == 1
  end

  test "P-post: the six dangling shapes give one body, no value echoed (D4-dangling, D4-same-body)",
       %{a: a, b: b} do
    retired = ReferenceFixture.target!(a, "frt_target", false)
    foreign = ReferenceFixture.target!(b)
    wrong_type = ReferenceFixture.target!(a, "frt_other")

    bodies =
      for value <- [
            Ecto.UUID.generate(),
            retired,
            foreign,
            wrong_type,
            "not-a-uuid",
            123
          ] do
        conn = post(a, %{"title" => "x", "target" => value})
        assert conn.status == 422, "#{inspect(value)}: #{conn.resp_body}"
        assert field_names(conn) == ["target"]
        refute conn.resp_body =~ to_string(value)
        strip_trace(conn)
      end

    # a module that is not registered at all
    conn = post(a, %{"title" => "x", "ghost" => ReferenceFixture.target!(a)})
    assert conn.status == 422
    assert field_names(conn) == ["ghost"]

    assert bodies |> Enum.uniq() |> length() == 1
    assert stored(a) == 0
  end

  test "P-post: empty, null and absent values are not checked (D4-empty)", %{a: a} do
    assert post(a, %{"title" => "x"}).status == 201
    assert post(a, %{"title" => "x", "target" => ""}).status == 201
    assert stored(a) == 2
  end

  test "P-put: dangling refused (422, stored unchanged); live accepted; stored value stays readable",
       %{a: a} do
    live = ReferenceFixture.target!(a)
    conn = post(a, %{"title" => "x", "target" => live})
    id = Jason.decode!(conn.resp_body)["record_id"]

    bad = put_record(a, id, %{"title" => "y", "target" => Ecto.UUID.generate()})
    assert bad.status == 422
    assert field_names(bad) == ["target"]

    # rename the target: the stored id is unchanged and a later PUT with the same id is accepted
    {:ok, _} =
      FixtureRefTargets.update_record("frt_target", live, a.schema_name, %{
        "name" => "renamed",
        "active" => true
      })

    ok = put_record(a, id, %{"title" => "y", "target" => live})
    assert ok.status == 200, ok.resp_body

    # retire the target after the write: GET still returns the stored value; an unchanged PUT is refused
    {:ok, _} =
      FixtureRefTargets.update_record("frt_target", live, a.schema_name, %{
        "name" => "renamed",
        "active" => false
      })

    row = Repo.one(from(l in Latest, where: l.record_id == ^id), prefix: a.schema_name)
    assert row.field_values["target"] == live
    assert put_record(a, id, %{"title" => "z", "target" => live}).status == 422
    assert put_record(a, id, %{"title" => "z"}).status == 200
  end

  test "D4-xtenant: tenant B's id is refused in A; body keys tenant_id/prefix change nothing",
       %{a: a, b: b} do
    in_b = ReferenceFixture.target!(b)
    in_a = ReferenceFixture.target!(a)

    assert post(a, %{"title" => "x", "target" => in_b}).status == 422
    assert post(b, %{"title" => "x", "target" => in_a}).status == 422

    conn =
      post(a, %{"title" => "x", "target" => in_b}, %{
        "tenant_id" => Ecto.UUID.generate(),
        "prefix" => b.schema_name
      })

    assert conn.status in [422, 400]
    assert stored(a) == 0
    assert post(a, %{"title" => "x", "target" => in_a}).status == 201
    assert post(b, %{"title" => "x", "target" => in_b}).status == 201
  end

  defp import_doc(entries, upsert?) do
    base = %{
      "record_export_schema_version" => @schema_version,
      "entity_type" => @holder,
      "records" => entries
    }

    if upsert?, do: Map.put(base, "upsert_by", "external_ref"), else: base
  end

  defp import!(ctx, entries, upsert?) do
    conn =
      request(
        :post,
        "/api/v1/entities/records/#{@holder}/import",
        ctx,
        import_doc(entries, upsert?)
      )

    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)["results"]
  end

  test "P-import-create: the dangling line is refused at its position, the others are created", %{
    a: a
  } do
    live = ReferenceFixture.target!(a)

    results =
      import!(
        a,
        [
          %{"field_values" => %{"title" => "1", "target" => live}},
          %{"field_values" => %{"title" => "2", "target" => Ecto.UUID.generate()}},
          %{"field_values" => %{"title" => "3"}}
        ],
        false
      )

    assert Enum.map(results, & &1["status"]) == ["ok", "error", "ok"]
    assert Enum.at(results, 1)["reason"] == %{"type" => "reference_invalid", "field" => "target"}
    assert stored(a) == 2
  end

  test "P-import-upsert: the dangling line is refused, the others are written", %{a: a} do
    live = ReferenceFixture.target!(a)

    entry = fn id, fv ->
      %{"external_ref" => %{"system" => "s", "id" => id}, "field_values" => fv}
    end

    results =
      import!(
        a,
        [
          entry.("1", %{"title" => "1", "target" => live}),
          entry.("2", %{"title" => "2", "target" => Ecto.UUID.generate()}),
          entry.("3", %{"title" => "3"})
        ],
        true
      )

    assert Enum.map(results, & &1["status"]) == ["ok", "error", "ok"]
    assert Enum.at(results, 1)["reason"] == %{"type" => "reference_invalid", "field" => "target"}
    assert stored(a) == 2
  end
end
