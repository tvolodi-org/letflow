Code.require_file("../modules/stock/stock_fixture.exs", __DIR__)
Code.require_file("../modules/stock/documents_fixture.exs", __DIR__)
Code.require_file("../modules/catalog_items/catalog_items_fixture.exs", __DIR__)
Code.require_file("../modules/codes/codes_fixture.exs", __DIR__)

defmodule Letflow.Routers.SharedStockAccessVoiceTest do
  @moduledoc """
  K10 / REQ-911 (K9 of docs/status/qoimeks-old-client-compat.md section 5.3; decision 0091 section 11c):
  `POST /qoimeks/:slug/api/voice`, the old app's microphone call, through the full `Letflow.Router`
  over committed tenants. The speech and model answers are the doubles of `Letflow.Support.VoiceDoubles`
  (no provider is called). IDs follow the acceptance criteria: V1 the Draft shape, V2 no count by
  voice, V3 the old refusal texts, V4 authentication first, V5 own tenant only and nothing stored.
  `async: false`: committed tenants, VM-global config and buckets.
  """

  # impl_order: REQ-911
  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.CodesFixture, as: K
  alias Letflow.Identity.Tenant
  alias Letflow.Modules.Locations
  alias Letflow.Plugs.AuthAttemptLimit
  alias Letflow.Plugs.AuthAttemptLimit.Bucket
  alias Letflow.Repo
  alias Letflow.SharedStockAccess
  alias Letflow.StockDocsFixture, as: SD
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.VoiceDoubles

  @m4a <<0, 0, 0, 24, "ftypM4A ", 0, 0, 0, 0>>
  @webm <<0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0>>
  @cap 10_485_760
  @audio_required %{"error" => "audio file is required (max 10 MB)"}
  @phrase "move 3 of bolt from RA to RB"

  setup do
    ctx = S.setup_oidc!([:a, :b])
    a = S.tenant!("q911-a", ctx.names.a)
    b = S.tenant!("q911-b", ctx.names.b)

    originals = %{
      tenants: Application.fetch_env(:letflow, :shared_stock_access_tenants),
      limits: Application.fetch_env(:letflow, AuthAttemptLimit)
    }

    on_exit(fn ->
      restore(:shared_stock_access_tenants, originals.tenants)
      restore(AuthAttemptLimit, originals.limits)
      Bucket.reset()
    end)

    Application.put_env(:letflow, :shared_stock_access_tenants, [a.tenant.slug, b.tenant.slug])

    Application.put_env(:letflow, AuthAttemptLimit,
      failure_capacity: 1000,
      request_capacity: 1000
    )

    Bucket.reset()
    seeded = seed!(a)
    other = seed_other!(b)
    {:ok, a: a, b: b, seeded: seeded, other: other, va: access!(a), vb: access!(b)}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:letflow, key, value)
  defp restore(key, :error), do: Application.delete_env(:letflow, key)

  defp access!(fx) do
    {:ok, _kind, value} =
      SharedStockAccess.put(fx.schema_name, fx.tenant.slug, %{}, %{
        user_id: Ecto.UUID.generate(),
        trace_id: nil
      })

    value
  end

  defp fresh, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  # Items X-1 (default place RA, a barcode) and Y-1, places RA and RB. Names are spoken-looking words
  # that must never reach a log.
  defp seed!(fx) do
    s = fx.schema_name
    uom = Cat.uom!(s, "pcs")

    {:ok, ra} =
      Locations.create_node(
        s,
        %{"code" => "RA", "name" => "Rack Alpha", "node_kind" => "zone"},
        fresh()
      )

    {:ok, rb} =
      Locations.create_node(
        s,
        %{"code" => "RB", "name" => "Rack Bravo", "node_kind" => "zone"},
        fresh()
      )

    x =
      Cat.item!(s, "X-1", uom.record_id, %{
        "kind" => "material",
        "name" => "Zebrafish bolt",
        "default_location_id" => ra["record_id"]
      })

    y = Cat.item!(s, "Y-1", uom.record_id, %{"kind" => "material", "name" => "Quokka nut"})

    tag = K.tag!(s, "4870001112223", %{"status" => "assigned", "kind" => "barcode"})
    K.assign!(s, tag, "catalog_item", x.record_id)
    %{x: x, y: y, ra: ra, rb: rb}
  end

  defp seed_other!(fx) do
    s = fx.schema_name
    uom = Cat.uom!(s, "pcs")
    Cat.item!(s, "Z-9", uom.record_id, %{"kind" => "material", "name" => "Other tenant item"})
  end

  # -- the request ----------------------------------------------------------------------------------

  defp multipart(parts) do
    boundary = "----lfold"

    body =
      Enum.map_join(parts, fn
        {name, nil, data} ->
          "--#{boundary}\r\ncontent-disposition: form-data; name=\"#{name}\"\r\n\r\n#{data}\r\n"

        {name, file, data} ->
          "--#{boundary}\r\ncontent-disposition: form-data; name=\"#{name}\"; filename=\"#{file}\"\r\n" <>
            "content-type: audio/mp4\r\n\r\n#{data}\r\n"
      end) <> "--#{boundary}--\r\n"

    {"multipart/form-data; boundary=" <> boundary, body}
  end

  defp form(audio, lang), do: [{"audio", "a.m4a", audio}, {"lang", nil, lang}]

  defp post_form(fx, path, value, parts) do
    {ct, body} = multipart(parts)
    post(fx, path, value, body, ct)
  end

  defp post(fx, path, value, body, content_type) do
    conn =
      Plug.Test.conn(:post, "/qoimeks/#{fx.tenant.slug}#{path}", body)
      |> put_req_header("content-type", content_type)

    conn = if value, do: put_req_header(conn, "authorization", "Bearer " <> value), else: conn
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp voice(fx, value, parts), do: post_form(fx, "/api/voice", value, parts)
  defp voice(t, parts), do: voice(t.a, t.va, parts)

  defp get(fx, path, value) do
    Plug.Test.conn(:get, "/qoimeks/#{fx.tenant.slug}#{path}")
    |> put_req_header("authorization", "Bearer " <> value)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp ok!(conn) do
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
    body(conn)
  end

  defp catalog(t), do: get(t.a, "/api/catalog", t.va) |> ok!()
  defp sku(cat, code), do: Enum.find(cat["skus"], &(&1["code"] == code))
  defp place(cat, code), do: Enum.find(cat["locations"], &(&1["code"] == code))

  defp speech_calls do
    receive do
      {:speech, _ct, _lang, _size} -> 1 + speech_calls()
    after
      0 -> 0
    end
  end

  defp install!(opts), do: VoiceDoubles.install!(opts)

  defp answer(overrides), do: VoiceDoubles.answer(overrides)

  defp transfer_answer do
    answer(%{
      "kind" => "transfer",
      "item_codes" => ["X-1"],
      "location_words" => "RA",
      "location_code" => "RA",
      "to_location_words" => "RB",
      "to_location_code" => "RB",
      "quantity" => 3
    })
  end

  defp state(t) do
    s = t.a.schema_name
    %{rows: [[ledger]]} = Repo.query!(~s|SELECT count(*) FROM "#{s}".ledger_entry|)
    {SD.counts(s), ledger}
  end

  # -- V1 -------------------------------------------------------------------------------------------

  describe "V1 the Draft shape" do
    test "V1 a transfer: exactly six keys, rows equal to the catalog's, qty a number", t do
      install!(speech: {:ok, @phrase}, model: {:ok, transfer_answer()})
      cat = catalog(t)

      conn = voice(t, form(@m4a, "ru"))
      draft = ok!(conn)
      assert ["private, no-store"] == get_resp_header(conn, "cache-control")

      assert draft |> Map.keys() |> Enum.sort() ==
               ~w(kind location qty skus to_location transcript)

      assert draft["transcript"] == @phrase
      assert draft["kind"] == "transfer"
      assert draft["skus"] == [sku(cat, "X-1")]
      assert draft["location"] == place(cat, "RA")
      assert draft["to_location"] == place(cat, "RB")
      assert draft["qty"] === 3
      assert_received {:speech, "audio/mp4", "ru", _size}
    end

    test "V1 a receipt of two items with no place and no quantity: three keys, the model's order",
         t do
      install!(
        speech: {:ok, "receive bolt and nut"},
        model: {:ok, answer(%{"kind" => "receipt", "item_codes" => ["Y-1", "X-1"]})}
      )

      cat = catalog(t)
      draft = voice(t, form(@webm, "kk")) |> ok!()

      assert draft |> Map.keys() |> Enum.sort() == ~w(kind skus transcript)
      assert draft["kind"] == "receipt"
      assert draft["skus"] == [sku(cat, "Y-1"), sku(cat, "X-1")]
      assert_received {:speech, "audio/webm", "kk", _size}
    end

    test "V1 a fractional quantity is a JSON number and an issue keeps its kind", t do
      install!(
        speech: {:ok, "issue 2.5 of bolt from RA"},
        model:
          {:ok,
           answer(%{
             "kind" => "issue",
             "item_codes" => ["X-1"],
             "location_words" => "RA",
             "location_code" => "RA",
             "quantity" => 2.5
           })}
      )

      draft = voice(t, form(@m4a, "ru")) |> ok!()
      assert draft["kind"] == "issue"
      assert draft["qty"] === 2.5
      refute Map.has_key?(draft, "to_location")
    end
  end

  # -- V2 -------------------------------------------------------------------------------------------

  describe "V2 no count by voice" do
    test "V2 a count of 5 of X at A keeps the item and the place and drops kind and qty", t do
      install!(
        speech: {:ok, "count of 5 bolt at RA"},
        model:
          {:ok,
           answer(%{
             "kind" => "count",
             "item_codes" => ["X-1"],
             "location_words" => "RA",
             "location_code" => "RA",
             "quantity" => 5
           })}
      )

      cat = catalog(t)
      draft = voice(t, form(@m4a, "ru")) |> ok!()

      assert draft |> Map.keys() |> Enum.sort() == ~w(location skus transcript)
      assert draft["skus"] == [sku(cat, "X-1")]
      assert draft["location"] == place(cat, "RA")
    end

    test "V2 a draft of kind unknown has no kind key", t do
      install!(
        speech: {:ok, "hello there"},
        model: {:ok, answer(%{"kind" => "unknown"})}
      )

      draft = voice(t, form(@m4a, "ru")) |> ok!()
      assert draft |> Map.keys() |> Enum.sort() == ~w(skus transcript)
      assert draft["skus"] == []
    end
  end

  # -- V3 -------------------------------------------------------------------------------------------

  describe "V3 the old refusal texts" do
    defp refused(conn, status, expected) do
      assert {conn.status, body(conn)} == {status, expected}
      assert ["private, no-store"] == get_resp_header(conn, "cache-control")
    end

    test "V3 no audio part, a plain-text audio field, and a body that is not multipart", t do
      install!([])
      refused(voice(t, [{"lang", nil, "ru"}]), 400, @audio_required)
      refused(voice(t, [{"audio", nil, @m4a}, {"lang", nil, "ru"}]), 400, @audio_required)

      refused(
        post(t.a, "/api/voice", t.va, ~s({"lang":"ru"}), "application/json"),
        400,
        @audio_required
      )

      refused(post(t.a, "/api/voice", t.va, "", "text/plain"), 400, @audio_required)
      assert speech_calls() == 0
    end

    test "V3 a body over 10_485_760 bytes is refused and the speech provider is not called", t do
      install!([])
      big = @m4a <> :binary.copy(<<0>>, @cap)
      refused(voice(t, form(big, "ru")), 400, @audio_required)
      assert speech_calls() == 0
    end

    test "V3 lang kk2 and a missing lang", t do
      install!([])
      refused(voice(t, form(@m4a, "kk2")), 400, %{"error" => "lang must be ru or kk"})
      refused(voice(t, [{"audio", "a.m4a", @m4a}]), 400, %{"error" => "lang must be ru or kk"})
      assert speech_calls() == 0
    end

    test "V3 speech settings off is 503 with source speech", t do
      install!(speech_on: false)

      refused(voice(t, form(@m4a, "ru")), 503, %{
        "error" => "speech recognition is not configured on the server",
        "source" => "speech"
      })
    end

    test "V3 a speech failure, a timeout and audio of another format are 502 speech", t do
      failed = %{"error" => "speech recognition failed", "source" => "speech"}

      install!(speech: {:error, :provider_timeout})
      refused(voice(t, form(@m4a, "ru")), 502, failed)

      install!(speech: {:error, :refused})
      refused(voice(t, form(@m4a, "ru")), 502, failed)

      install!(speech: :raise)
      refused(voice(t, form(@m4a, "ru")), 502, failed)

      assert speech_calls() == 3

      install!(speech: {:ok, "x"})
      refused(voice(t, form("RIFF" <> :binary.copy(<<0>>, 16), "ru")), 502, failed)
      assert speech_calls() == 0
    end

    test "V3 an empty transcript is 422 nothing was said", t do
      for text <- ["", "   \n "] do
        install!(speech: {:ok, text})
        refused(voice(t, form(@m4a, "ru")), 422, %{"error" => "nothing was said"})
      end
    end

    test "V3 a model answer that is not JSON, a refusal and a raise are 502 llm", t do
      understood = %{"error" => "could not understand the phrase", "source" => "llm"}

      for model <- [
            {:ok, "I cannot help"},
            {:error, :truncated},
            {:error, :provider_timeout},
            :raise
          ] do
        install!(speech: {:ok, @phrase}, model: model)
        conn = voice(t, form(@m4a, "ru"))
        refused(conn, 502, understood)
        refute conn.resp_body =~ VoiceDoubles.sentinel()
      end
    end

    test "V3 with no model configured the answer is transcript and an empty skus", t do
      install!(speech: {:ok, @phrase}, model_on: false)
      draft = voice(t, form(@m4a, "ru")) |> ok!()
      assert draft == %{"transcript" => @phrase, "skus" => []}
    end

    test "V3 a crash in the builder is a plain 500 with no detail (INV-8)", t do
      install!(speech: {:ok, @phrase}, model: {:ok, transfer_answer()})
      Repo.query!(~s|DROP TABLE "#{t.a.schema_name}".catalog_item_int_ids|)

      conn = voice(t, form(@m4a, "ru"))
      assert {conn.status, body(conn)} == {500, %{"error" => "internal error"}}
    end
  end

  # -- V4 -------------------------------------------------------------------------------------------

  describe "V4 authentication first" do
    test "V4 no header, a wrong value and an unlisted slug are the byte-identical 401, with no speech call",
         t do
      install!([])
      big = form(@m4a <> :binary.copy(<<0>>, @cap), "ru")
      reference = get(t.a, "/api/catalog", "wrong-value")
      assert reference.status == 401

      for {fx, value} <- [{t.a, nil}, {t.a, "wrong-value"}, {t.a, t.vb}] do
        conn = post_form(fx, "/api/voice", value, big)
        assert conn.status == 401
        assert conn.resp_body == reference.resp_body
      end

      unlisted = %{t.a | tenant: %{t.a.tenant | slug: "not-listed-q911"}}
      conn = post_form(unlisted, "/api/voice", t.va, big)
      assert {conn.status, conn.resp_body} == {401, reference.resp_body}
      assert speech_calls() == 0
    end

    test "V4 a wrong value spends one failure token, an accepted call one request token", t do
      install!(speech: {:ok, @phrase}, model: {:ok, transfer_answer()})

      Application.put_env(:letflow, AuthAttemptLimit,
        failure_capacity: 1,
        request_capacity: 2,
        request_refill_per_sec: 0.0001
      )

      Bucket.reset()
      assert 401 == post_form(t.a, "/api/voice", "wrong-value", form(@m4a, "ru")).status
      limited = post_form(t.a, "/api/voice", "wrong-value", form(@m4a, "ru"))
      assert limited.status == 429

      Bucket.reset()
      assert 200 == voice(t, form(@m4a, "ru")).status
      assert 200 == voice(t, form(@m4a, "ru")).status
      assert 429 == voice(t, form(@m4a, "ru")).status
    end

    test "V4 scope enforcement on or shadow is 403 with no speech call", t do
      install!([])

      for mode <- [:shadow, :on] do
        from(x in Tenant, where: x.id == ^t.a.tenant_id)
        |> Repo.update_all(set: [scope_enforcement: mode])

        conn = voice(t, form(@m4a, "ru"))
        assert {conn.status, body(conn)} == {403, %{"error" => "scope_enforcement_active"}}
      end

      assert speech_calls() == 0
    end

    test "V4 POST /voice without /api stays the 404 and calls nothing", t do
      install!([])
      conn = post_form(t.a, "/voice", t.va, form(@m4a, "ru"))
      assert {conn.status, body(conn)} == {404, %{"error" => "not found"}}
      assert speech_calls() == 0
    end

    test "V4 other methods on /api/voice are the 404", t do
      conn = get(t.a, "/api/voice", t.va)
      assert {conn.status, body(conn)} == {404, %{"error" => "not found"}}
    end
  end

  # -- V5 -------------------------------------------------------------------------------------------

  describe "V5 own tenant only and nothing stored" do
    test "V5 a code that exists only in another tenant is not in skus", t do
      install!(
        speech: {:ok, "receive other item"},
        model: {:ok, answer(%{"kind" => "receipt", "item_codes" => ["Z-9", "X-1"]})}
      )

      cat = catalog(t)
      draft = voice(t, form(@m4a, "ru")) |> ok!()
      assert draft["skus"] == [sku(cat, "X-1")]
      refute Enum.any?(draft["skus"], &(&1["code"] == "Z-9"))

      # and B's own credential reaches B's item, not A's
      install!(
        speech: {:ok, "receive other item"},
        model: {:ok, answer(%{"kind" => "receipt", "item_codes" => ["X-1", "Z-9"]})}
      )

      drafted = voice(t.b, t.vb, form(@m4a, "ru")) |> ok!()
      assert Enum.map(drafted["skus"], & &1["code"]) == ["Z-9"]
      assert t.other.record_id
    end

    test "V5 every call writes no stock row, and the transcript and names are not logged", t do
      before = state(t)

      log =
        capture_log([level: :debug], fn ->
          install!(speech: {:ok, @phrase}, model: {:ok, transfer_answer()})
          ok!(voice(t, form(@m4a, "ru")))

          install!(speech: {:ok, "receive Zebrafish bolt"}, model: {:ok, "not json Quokka"})
          assert voice(t, form(@m4a, "ru")).status == 502

          install!(speech: {:ok, ""})
          assert voice(t, form(@m4a, "ru")).status == 422

          install!(speech: {:error, :refused})
          assert voice(t, form(@m4a, "kk")).status == 502
        end)

      assert state(t) == before

      for secret <- [@phrase, "Zebrafish", "Quokka", "Rack Alpha", VoiceDoubles.api_key()] do
        refute log =~ secret
      end
    end
  end
end
