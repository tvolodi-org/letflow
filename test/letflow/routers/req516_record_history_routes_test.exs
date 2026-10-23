defmodule Letflow.Routers.Req516RecordHistoryRoutesTest do
  @moduledoc """
  REQ-516 S2 (GH #2701): `GET /entities/records/:entity_type/:record_id/history` through the full
  `Letflow.Router` (real bearer tokens, real tenant schema).

    * H1: the restricted value is absent for a caller without a grant and present with one;
    * H2: TENANT_AUDITOR reaches the route through `:EntitiesQuery`, masked without a grant;
    * H3: removing the restriction exposes the values history wrote while it applied (the
      consequence documented in docs/roles.md);
    * H4: a hidden record (cross-tenant, nonexistent, malformed, bad page_size) is the same 404;
    * H5: an oversized payload is read through `$ref`, masked, and pages without loss;
    * H6: the synthetic instance stays hidden on `/instances` (regression for GH #2702);
    * T1: the route is registered with `:EntitiesQuery`; T2: the docs and the moduledoc say so.

  The scoped-caller 404 (an out-of-scope record of a `:column` type) is in the
  `describe "scoped caller"` block at the end of this file.

  `async: false`: provisioned tenants and committed writes.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Support.RecordHistoryFixture, as: R
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopeWritesFixture, as: W

  @restricted "__field_redacted__"

  # ── Full-pipeline dispatch ───────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp get_json(t, token, path) do
    conn(:get, "/api/v1" <> path)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-tenant-slug", t.tenant.slug)
    |> dispatch()
  end

  defp history(t, token, record_id, query \\ ""),
    do: get_json(t, token, "/entities/records/#{R.type_name()}/#{record_id}/history#{query}")

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  # A problem document without its per-request `trace_id`, so two 404s compare equal.
  defp normalised(conn), do: conn |> body_of() |> Map.delete("trace_id")

  # H1 and H3 fixture: created with s3, then updated to s4.
  defp seed_history!(t) do
    record_id = R.record!(t, %{"title" => "case", "secret" => "s3"})
    :ok = R.update!(t, record_id, %{"title" => "case", "secret" => "s4"})
    record_id
  end

  defp items_secrets(conn) do
    body_of(conn)["items"] |> Enum.map(& &1["field_values"]["secret"])
  end

  # Follows next_cursor one item at a time and returns every item in order.
  defp collect_pages(t, token, record_id, cursor, acc) do
    query =
      if cursor,
        do: "?page_size=1&cursor=#{URI.encode_www_form(cursor)}",
        else: "?page_size=1"

    body = history(t, token, record_id, query) |> body_of()
    acc = acc ++ body["items"]

    case body["next_cursor"] do
      nil -> acc
      next -> collect_pages(t, token, record_id, next, acc)
    end
  end

  setup do
    t = R.tenant!("req516-routes")
    %{t: t}
  end

  # ══════════════════════════════════════════════════════════════════════
  # H1: masked without a grant, present with a grant
  # ══════════════════════════════════════════════════════════════════════

  describe "H1 restricted values in history" do
    test "a caller with no grant reads both events with the value masked", %{t: t} do
      record_id = seed_history!(t)
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      conn = history(t, token, record_id)

      assert conn.status == 200, conn.resp_body
      assert length(body_of(conn)["items"]) == 2
      assert items_secrets(conn) == [@restricted, @restricted]
      refute conn.resp_body =~ "s3"
      refute conn.resp_body =~ "s4"
    end

    test "a caller holding the grant reads the values", %{t: t} do
      record_id = seed_history!(t)
      user = R.user!(t)
      :ok = R.grant_secret!(t, user)
      token = R.token!(t, user, ["TENANT_ADMIN"])

      conn = history(t, token, record_id)

      assert conn.status == 200, conn.resp_body
      assert items_secrets(conn) == ["s3", "s4"]
    end

    test "every item carries the event fields and never the raw payload", %{t: t} do
      record_id = seed_history!(t)
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      [first | _] = body_of(history(t, token, record_id))["items"]

      assert Map.keys(first) |> Enum.sort() ==
               Enum.sort([
                 "event_id",
                 "event_type",
                 "sequence_number",
                 "created_at",
                 "actor_id",
                 "actor_display_name",
                 "entity_def_version",
                 "field_values"
               ])

      assert {:ok, _} = Ecto.UUID.cast(first["event_id"])
      assert first["event_type"] == "ENTITY_RECORD_CREATED"
      assert first["actor_display_name"] == "REQ-516 History Test User"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # H2: TENANT_AUDITOR reaches the route
  # ══════════════════════════════════════════════════════════════════════

  describe "H2 TENANT_AUDITOR" do
    test "reaches the route through :EntitiesQuery, masked without a grant and present with one",
         %{t: t} do
      record_id = seed_history!(t)
      plain = R.token!(t, R.user!(t), ["TENANT_AUDITOR"])
      granted_user = R.user!(t)
      :ok = R.grant_secret!(t, granted_user)
      granted = R.token!(t, granted_user, ["TENANT_AUDITOR"])

      masked = history(t, plain, record_id)
      assert masked.status == 200, masked.resp_body
      assert items_secrets(masked) == [@restricted, @restricted]

      present = history(t, granted, record_id)
      assert present.status == 200, present.resp_body
      assert items_secrets(present) == ["s3", "s4"]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # H3: the consequence of a restriction removed later
  # ══════════════════════════════════════════════════════════════════════

  describe "H3 a restriction removed later" do
    test "exposes the values history wrote while it applied", %{t: t} do
      record_id = seed_history!(t)
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])
      assert items_secrets(history(t, token, record_id)) == [@restricted, @restricted]

      :ok = R.remove_restrictions!(t)

      assert items_secrets(history(t, token, record_id)) == ["s3", "s4"]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # H4: a hidden record is the same 404 (INV-5, INV-10 cross-tenant)
  # ══════════════════════════════════════════════════════════════════════

  describe "H4 one 404 for every hidden record" do
    test "cross-tenant, nonexistent and malformed ids answer the same bytes", %{t: t} do
      other = R.tenant!("req516-other")
      other_record = seed_history!(other)
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      absent = history(t, token, Ecto.UUID.generate())
      malformed = history(t, token, "not-a-uuid")
      cross_tenant = history(t, token, other_record)

      assert absent.status == 404
      assert malformed.status == 404
      assert cross_tenant.status == 404

      assert normalised(cross_tenant) == normalised(absent)
      assert normalised(malformed) == normalised(absent)
    end

    test "visibility is decided before page_size: a bad page_size does not tell hidden from absent",
         %{t: t} do
      other = R.tenant!("req516-other-size")
      other_record = seed_history!(other)
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      cross_tenant = history(t, token, other_record, "?page_size=0")
      absent = history(t, token, Ecto.UUID.generate(), "?page_size=0")

      assert cross_tenant.status == 404
      assert normalised(cross_tenant) == normalised(absent)
    end

    test "a visible record with a bad page_size is a 400, not a 404", %{t: t} do
      record_id = seed_history!(t)
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      assert history(t, token, record_id, "?page_size=0").status == 400
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # H5: oversized payloads, deletion and paging
  # ══════════════════════════════════════════════════════════════════════

  describe "H5 oversized payloads and paging" do
    setup %{t: t} do
      # Above the 4096-byte inline boundary, so the create event's payload is stored as a $ref.
      big = String.duplicate("x", 5000)
      record_id = R.record!(t, %{"title" => "big", "secret" => big})
      :ok = R.update!(t, record_id, %{"title" => "big", "secret" => "s4"})
      :ok = R.delete!(t, record_id)
      %{record_id: record_id, big: big}
    end

    test "the oversized create is masked for a caller with no grant", %{
      t: t,
      record_id: record_id
    } do
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      conn = history(t, token, record_id, "?page_size=10")

      assert conn.status == 200, conn.resp_body
      assert [created, _updated, _deleted] = body_of(conn)["items"]
      assert created["field_values"]["secret"] == @restricted
      refute conn.resp_body =~ String.duplicate("x", 50)
      refute conn.resp_body =~ "$ref"
    end

    test "the oversized create is present for a caller with the grant", %{
      t: t,
      record_id: record_id,
      big: big
    } do
      user = R.user!(t)
      :ok = R.grant_secret!(t, user)
      token = R.token!(t, user, ["TENANT_ADMIN"])

      [created | _] = body_of(history(t, token, record_id, "?page_size=10"))["items"]

      assert created["field_values"]["secret"] == big
    end

    test "page_size=1 pages through every event once, in sequence order, with the cursor", %{
      t: t,
      record_id: record_id
    } do
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      pages = collect_pages(t, token, record_id, nil, [])

      sequence = Enum.map(pages, & &1["sequence_number"])
      assert length(sequence) == 3
      assert sequence == Enum.sort(sequence)
      assert length(Enum.uniq(sequence)) == 3
    end

    test "the deleted record's history is readable; the DELETED item has no field_values", %{
      t: t,
      record_id: record_id
    } do
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      deleted =
        history(t, token, record_id, "?page_size=10")
        |> body_of()
        |> Map.get("items")
        |> List.last()

      assert deleted["event_type"] == "ENTITY_RECORD_DELETED"
      refute Map.has_key?(deleted, "field_values")
    end

    test "no item carries $ref, external_ref or record_id", %{t: t, record_id: record_id} do
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      items = body_of(history(t, token, record_id, "?page_size=10"))["items"]

      for item <- items do
        refute Map.has_key?(item, "record_id")
        refute Map.has_key?(item, "external_ref")
        refute Map.has_key?(item, "$ref")
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # H6: the synthetic instance stays hidden on /instances (GH #2702)
  # ══════════════════════════════════════════════════════════════════════

  describe "H6 the synthetic instance stays hidden" do
    test "GET /instances/<synthetic id>/history is 404 and /instances omits it", %{t: t} do
      _record_id = seed_history!(t)
      {:ok, instance_id} = EntityTypeInstance.fetch_instance_id(R.type_name(), t.schema_name)
      token = R.token!(t, R.user!(t), ["TENANT_ADMIN"])

      direct = get_json(t, token, "/instances/#{instance_id}/history")
      listing = get_json(t, token, "/instances")

      assert direct.status == 404
      assert listing.status == 200
      refute listing.resp_body =~ instance_id
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # T1: the route is registered and gated by :EntitiesQuery
  # ══════════════════════════════════════════════════════════════════════

  describe "T1 route inventory" do
    test "the route is declared with :EntitiesQuery and resolves to that key" do
      assert {"GET", "/records/:entity_type/:record_id/history", :EntitiesQuery} in Letflow.Routers.Entities.__authz_routes__()

      assert Letflow.Api.Authorization.endpoint_policy_key(
               "GET",
               "/entities/records/:entity_type/:record_id/history"
             ) == :EntitiesQuery
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # T2: the docs say what the route does and what a later-removed restriction does
  # ══════════════════════════════════════════════════════════════════════

  describe "T2 docs pin" do
    @root Path.expand("../../..", __DIR__)

    test "docs/roles.md names the route and the consequence in its own paragraph" do
      roles = File.read!(Path.join(@root, "docs/roles.md"))

      assert roles =~ "GET /entities/records/:entity_type/:record_id/history"

      assert Enum.any?(String.split(roles, "\n\n"), fn paragraph ->
               paragraph =~ "removed later" and paragraph =~ "history"
             end)
    end

    test "the routers/instances.ex moduledoc no longer says the route is missing" do
      instances = File.read!(Path.join(@root, "lib/letflow/routers/instances.ex"))

      refute instances =~ "until REQ-516"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Scoped caller: an out-of-scope record of a :column type is the nonexistent record's 404
  # ══════════════════════════════════════════════════════════════════════

  describe "scoped caller" do
    setup do
      fx = W.provision!("r516-scoped-history")
      %{fx: fx}
    end

    test "an in-scope record answers 200; an out-of-scope one is the nonexistent record's 404", %{
      fx: fx
    } do
      in_scope =
        W.request(
          fx,
          :get,
          "/api/v1/entities/records/scoped_item/#{fx.items.a.record_id}/history",
          nil
        )

      out_of_scope =
        W.request(
          fx,
          :get,
          "/api/v1/entities/records/scoped_item/#{fx.items.b.record_id}/history",
          nil
        )

      absent =
        W.request(
          fx,
          :get,
          "/api/v1/entities/records/scoped_item/#{Ecto.UUID.generate()}/history",
          nil
        )

      assert in_scope.status == 200, in_scope.resp_body
      assert body_of(in_scope)["items"] != []
      assert out_of_scope.status == 404
      assert normalised(out_of_scope) == normalised(absent)
    end

    # H4b: `scoped_master` is declared :tenant_wide in fixture_scoped, so a scoped caller reads
    # any existing record of it (matching all_in_scope?/4); a nonexistent id is the same 404.
    test "a tenant-wide record answers 200 for a scoped caller; a nonexistent id is the same 404",
         %{fx: fx} do
      master = F.create!(fx.schema_name, "scoped_master", %{"name" => "master"})

      visible =
        W.request(
          fx,
          :get,
          "/api/v1/entities/records/scoped_master/#{master.record_id}/history",
          nil
        )

      absent_master =
        W.request(
          fx,
          :get,
          "/api/v1/entities/records/scoped_master/#{Ecto.UUID.generate()}/history",
          nil
        )

      absent_item =
        W.request(
          fx,
          :get,
          "/api/v1/entities/records/scoped_item/#{Ecto.UUID.generate()}/history",
          nil
        )

      assert visible.status == 200, visible.resp_body
      assert [%{"event_type" => "ENTITY_RECORD_CREATED"}] = body_of(visible)["items"]
      assert absent_master.status == 404
      assert normalised(absent_master) == normalised(absent_item)
    end
  end
end
