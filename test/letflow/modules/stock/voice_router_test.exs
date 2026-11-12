Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.VoiceRouterTest do
  @moduledoc """
  REQ-741 / GH #3879: the two voice draft routes of module `stock` through the full `Letflow.Router` with
  real OIDC bearer tokens on committed tenants (Sandbox `:auto`, `async: false`). Provider calls go to
  the doubles of `Letflow.Support.VoiceDoubles`. Tests: V-ACL-1..5, V-TXT-1..4, V-AUD-1..5, V-CHN-1..2,
  V-FAIL-1..4, V-NIL-1..2, V-TEN-1..3 (see the design of T-1343).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.VoicePrompt
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture
  alias Letflow.Support.VoiceDoubles

  @max 10_485_760
  @m4a <<0, 0, 0, 24, "ftypM4A ", 0, 0, 0, 0>>
  @webm <<0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0>>

  setup do
    ctx = S.setup_oidc!([:a, :b, :s, :c])
    a = S.tenant!("stk-va", ctx.names.a)
    b = S.tenant!("stk-vb", ctx.names.b)

    Map.merge(ctx, %{
      a: a,
      b: b,
      ma: D.masters!(a.schema_name),
      mb: D.masters!(b.schema_name),
      tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
      tok_b: S.token(ctx, :b, ["TENANT_ADMIN"])
    })
  end

  defp strip(body), do: M.strip(body)

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp auth(conn, token, extra \\ []) do
    Enum.reduce(extra, Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token), fn
      {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v)
    end)
  end

  defp call(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp text(token, body, query \\ "", headers \\ []) do
    Plug.Test.conn(:post, S.base() <> "/voice/draft-text" <> query, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> auth(token, headers)
    |> call()
  end

  # A real multipart body: parts are `{name, filename | nil, data}`.
  defp multipart(parts) do
    boundary = "----lfvoice"

    body =
      Enum.map_join(parts, fn
        {name, nil, data} ->
          "--#{boundary}\r\ncontent-disposition: form-data; name=\"#{name}\"\r\n\r\n#{data}\r\n"

        {name, file, data} ->
          "--#{boundary}\r\ncontent-disposition: form-data; name=\"#{name}\"; filename=\"#{file}\"\r\n" <>
            "content-type: audio/webm\r\n\r\n#{data}\r\n"
      end) <> "--#{boundary}--\r\n"

    {"multipart/form-data; boundary=" <> boundary, body}
  end

  defp audio(token, parts, headers \\ [])

  defp audio(token, parts, headers) when is_list(parts) do
    {ct, body} = multipart(parts)

    Plug.Test.conn(:post, S.base() <> "/voice/draft", body)
    |> Plug.Conn.put_req_header("content-type", ct)
    |> auth(token, headers)
    |> call()
  end

  defp audio(token, data, lang), do: audio(token, [{"audio", "a.m4a", data}, {"lang", nil, lang}])

  defp m4a(size), do: @m4a <> :binary.copy(<<0>>, size - byte_size(@m4a))

  defp drain do
    receive do
      {tag, _, _, _} when tag == :speech -> drain()
      {:model, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  defp calls do
    receive do
      {:speech, _, _, _} = call -> [call | calls()]
      {:model, _, _} = call -> [call | calls()]
    after
      0 -> []
    end
  end

  defp snapshot(schema) do
    for table <- ["entity_record_latest", "events", "audit_entries"] do
      %{rows: [[n]]} = Letflow.Repo.query!("SELECT count(*) FROM \"#{schema}\".\"#{table}\"")
      n
    end
  end

  defp reasons(conn, status) do
    body = status!(conn, status)
    {body["reason"], body["source"], body["field"]}
  end

  defp item_code(m, schema) do
    {:ok, rec} = CatalogItems.lookup(schema, m.item)
    rec["code"]
  end

  defp loc_code(m, schema) do
    {:ok, rec} = Locations.lookup(schema, m.location)
    rec["code"]
  end

  describe "registration and access" do
    test "V-ACL-1 a tenant admin gets 200 on both routes", ctx do
      VoiceDoubles.install!()
      body = text(ctx.tok_a, %{"text" => "hello", "lang" => "ru"}) |> status!(200)

      assert Enum.sort(Map.keys(body)) ==
               ~w(dropped items kind location quantity to_location transcript)

      body = audio(ctx.tok_a, @m4a, "kk") |> status!(200)
      assert body["transcript"] == "transcript"
    end

    test "V-ACL-2 a task worker is forbidden on both routes", ctx do
      VoiceDoubles.install!()
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")

      for conn <- [text(tok, %{"text" => "x"}), audio(tok, @m4a, "ru")] do
        body = status!(conn, 403)
        assert body["title"] == "Forbidden" and body["detail"] == "insufficient permissions"
      end

      assert calls() == []
    end

    test "V-ACL-3/4/5 an API token, a scoped admin and a tenant without the module get one 404",
         ctx do
      VoiceDoubles.install!()
      S.tenant!("stk-vref", ctx.names.c, install: false)
      ref_tok = S.token(ctx, :c, ["TENANT_ADMIN"], sub: "ref-admin")

      reference =
        text(ref_tok, %{"text" => "x"}) |> status!(404) |> strip()

      assert audio(ref_tok, @m4a, "ru") |> status!(404) |> strip() == reference

      user = TokenMintFixture.role_holder!(ctx.a.schema_name, ["TENANT_ADMIN"])

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.a.schema_name
        )

      slug = Letflow.Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug

      s = S.tenant!("stk-vs", ctx.names.s)
      scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-writer")
      text(scoped, %{"text" => "x"}) |> status!(200)

      scoped_user =
        Letflow.Repo.one!(from(u in User, where: u.username == "scoped-writer"),
          prefix: s.schema_name
        )

      _ =
        RSG.raw_delete_rows!(
          s.schema_name,
          RSG.group_of!(s.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      :ok =
        RSG.raw_user_row!(s.schema_name, scoped_user.id, "TENANT_ADMIN", RSG.node!(s.schema_name))

      drain()

      for tok <- [plaintext, scoped] do
        conn = text(tok, %{"text" => "x"}, "", [{"x-tenant-slug", slug}])
        assert status!(conn, 404) |> strip() == reference

        conn =
          audio(tok, [{"audio", "a.m4a", @m4a}, {"lang", nil, "ru"}], [{"x-tenant-slug", slug}])

        assert status!(conn, 404) |> strip() == reference
      end

      assert calls() == []
    end
  end

  describe "typed route" do
    test "V-TXT-1 a missing, blank or non-string text is 422 field_invalid", ctx do
      VoiceDoubles.install!()

      for body <- [%{}, %{"text" => ""}, %{"text" => "   "}, %{"text" => 7}, %{"text" => ["a"]}] do
        assert reasons(text(ctx.tok_a, body), 422) == {"field_invalid", nil, "text"}
      end

      conn =
        Plug.Test.conn(:post, S.base() <> "/voice/draft-text", Jason.encode!(["a"]))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> auth(ctx.tok_a)
        |> call()

      assert reasons(conn, 422) == {"field_invalid", nil, "text"}
      assert calls() == []
    end

    test "V-TXT-2 any other key is 422 field_not_allowed", ctx do
      VoiceDoubles.install!()
      body = text(ctx.tok_a, %{"text" => "x", "tenant_id" => "t"}) |> status!(422)
      assert body["reason"] == "field_not_allowed" and body["field"] == "tenant_id"

      assert reasons(text(ctx.tok_a, %{"text" => "x", "foo" => 1}), 422) ==
               {"field_not_allowed", nil, "foo"}

      assert calls() == []
    end

    test "V-TXT-3 only ru and kk are languages", ctx do
      VoiceDoubles.install!()

      for lang <- ["en", "uz", "RU", 7] do
        assert reasons(text(ctx.tok_a, %{"text" => "x", "lang" => lang}), 422) ==
                 {"bad_language", nil, nil}
      end

      for body <- [
            %{"text" => "x", "lang" => "ru"},
            %{"text" => "x", "lang" => "kk"},
            %{"text" => "x"}
          ] do
        text(ctx.tok_a, body) |> status!(200)
      end
    end

    test "V-TXT-4 the transcript is the typed text byte for byte", ctx do
      VoiceDoubles.install!()
      typed = "  Принять 5 штук на склад  "
      body = text(ctx.tok_a, %{"text" => typed, "lang" => "ru"}) |> status!(200)
      assert body["transcript"] == typed
      assert_received {:model, _prompt, ^typed}
      refute_received {:speech, _, _, _}
    end
  end

  describe "audio route" do
    test "V-AUD-1 a missing audio part or a wrong language is 422", ctx do
      VoiceDoubles.install!()

      assert reasons(audio(ctx.tok_a, [{"lang", nil, "ru"}]), 422) ==
               {"field_invalid", nil, "audio"}

      assert reasons(audio(ctx.tok_a, [{"audio", nil, "plain"}, {"lang", nil, "ru"}]), 422) ==
               {"field_invalid", nil, "audio"}

      for lang <- ["en", "RU"] do
        assert reasons(audio(ctx.tok_a, @m4a, lang), 422) == {"bad_language", nil, nil}
      end

      assert reasons(audio(ctx.tok_a, [{"audio", "a.m4a", @m4a}]), 422) ==
               {"bad_language", nil, nil}

      assert reasons(
               audio(ctx.tok_a, [{"audio", "a.m4a", @m4a}, {"lang", nil, "ru"}, {"x", nil, "1"}]),
               422
             ) ==
               {"field_not_allowed", nil, "x"}

      assert calls() == []
    end

    test "V-AUD-2 a file over 10 MB, also 11 MB through the parser, is 413", ctx do
      VoiceDoubles.install!()

      for size <- [@max + 1, 11_000_000] do
        assert reasons(audio(ctx.tok_a, m4a(size), "ru"), 413) ==
                 {"audio_too_large", "speech", nil}
      end

      assert calls() == []
    end

    test "V-AUD-3 exactly 10 MB is accepted", ctx do
      VoiceDoubles.install!()
      audio(ctx.tok_a, m4a(@max), "ru") |> status!(200)
      assert_received {:speech, "audio/mp4", "ru", @max}
    end

    test "V-AUD-4 other formats are 415", ctx do
      VoiceDoubles.install!()

      for data <- ["ID3" <> :binary.copy(<<0>>, 32), <<0xFF, 0xFB, 0x90, 0>>, "just text here"] do
        assert reasons(audio(ctx.tok_a, data, "ru"), 415) == {"audio_format", "speech", nil}
      end

      assert calls() == []
    end

    test "V-AUD-5 the format comes from the bytes, not from the declared type", ctx do
      VoiceDoubles.install!()
      # the part is declared audio/webm by the helper
      audio(ctx.tok_a, @m4a, "kk") |> status!(200)
      assert_received {:speech, "audio/mp4", "kk", _}
      audio(ctx.tok_a, @webm, "ru") |> status!(200)
      assert_received {:speech, "audio/webm", "ru", _}
    end
  end

  describe "the chain" do
    test "V-CHN-1 the prompt holds the active records only", ctx do
      VoiceDoubles.install!()
      schema = ctx.a.schema_name
      n = System.unique_integer([:positive])
      uom = D.masters!(schema).uom

      inactive =
        Letflow.CatalogItemsFixture.item!(schema, "OFF#{n}", uom, %{"active" => false})

      {:ok, node} =
        Locations.create_node(
          schema,
          %{"code" => "GONE#{n}", "name" => "G", "node_kind" => "zone"},
          %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
        )

      {:ok, items} = CatalogItems.list_active(schema)
      {:ok, locs} = Locations.list_active(schema)
      refute Enum.any?(items, &(&1["code"] == "OFF#{n}"))
      assert Enum.any?(locs, &(&1["record_id"] == node["record_id"]))

      Letflow.Repo.query!(
        "UPDATE \"#{schema}\".entity_record_latest SET deleted = true WHERE record_id = $1",
        [Ecto.UUID.dump!(node["record_id"])]
      )

      answer =
        VoiceDoubles.answer(%{
          "item_codes" => ["OFF#{n}"],
          "location_words" => "gone",
          "location_code" => "GONE#{n}"
        })

      VoiceDoubles.install!(model: {:ok, answer})

      body = text(ctx.tok_a, %{"text" => "gone zone"}) |> status!(200)
      assert body["items"] == [] and body["location"] == nil

      assert %{"reason" => "unknown_item"} =
               Enum.find(body["dropped"], &(&1["field"] == "item_codes"))

      assert %{"reason" => "unknown_location"} =
               Enum.find(body["dropped"], &(&1["field"] == "location"))

      assert inactive.record_id

      assert_received {:model, prompt, _}
      refute prompt =~ "OFF#{n}"
      refute prompt =~ "GONE#{n}"

      {:ok, items} = CatalogItems.list_active(schema)
      {:ok, locs} = Locations.list_active(schema)
      uoms = Map.new(items, &{&1["base_uom_id"], &1})
      assert map_size(uoms) >= 1

      expected =
        VoicePrompt.build(
          Enum.map(items, fn r ->
            {:ok, u} = CatalogItems.lookup(schema, r["base_uom_id"])
            %{id: r["record_id"], code: r["code"], name: r["name"], base_unit: u["code"]}
          end),
          Enum.map(locs, &%{id: &1["record_id"], code: &1["code"], name: &1["name"]})
        )

      assert prompt == expected
    end

    test "V-CHN-2 a known item and location come back with ids", ctx do
      schema = ctx.a.schema_name
      ic = item_code(ctx.ma, schema)
      lc = loc_code(ctx.ma, schema)

      answer =
        VoiceDoubles.answer(%{
          "item_codes" => [ic],
          "location_words" => "mainstore",
          "location_code" => lc,
          "quantity" => 5
        })

      VoiceDoubles.install!(model: {:ok, answer}, speech: {:ok, "receive five to the main store"})
      body = audio(ctx.tok_a, @webm, "ru") |> status!(200)

      assert body["kind"] == "receipt" and body["quantity"] == "5"
      assert [%{"id" => id, "code" => ^ic}] = body["items"]
      assert id == ctx.ma.item
      assert %{"id" => lid, "code" => ^lc} = body["location"]
      assert lid == ctx.ma.location
      assert body["dropped"] == []
    end
  end

  describe "failures" do
    test "V-FAIL-1 speech off is 503 on audio only", ctx do
      VoiceDoubles.install!(speech_on: false)
      assert reasons(audio(ctx.tok_a, @m4a, "ru"), 503) == {"speech_off", "speech", nil}
      text(ctx.tok_a, %{"text" => "x"}) |> status!(200)
    end

    test "V-FAIL-2 model off is 200 with the transcript and llm_off", ctx do
      VoiceDoubles.install!(model_on: false)
      body = text(ctx.tok_a, %{"text" => "hi"}) |> status!(200)

      assert body == %{
               "kind" => "unknown",
               "items" => [],
               "location" => nil,
               "to_location" => nil,
               "quantity" => nil,
               "transcript" => "hi",
               "dropped" => [],
               "notice" => "llm_off"
             }

      body = audio(ctx.tok_a, @m4a, "ru") |> status!(200)
      assert body["transcript"] == "transcript" and body["notice"] == "llm_off"
      refute_received {:model, _, _}
    end

    test "V-FAIL-3 provider failures carry status, reason and source", ctx do
      cases = [
        {[speech: {:error, :provider_error}], :audio, 502, {"provider_error", "speech", nil}},
        {[speech: {:error, :provider_timeout}], :audio, 504, {"provider_timeout", "speech", nil}},
        {[speech: :raise], :audio, 502, {"provider_error", "speech", nil}},
        {[model: {:error, :provider_error}], :text, 502, {"provider_error", "llm", nil}},
        {[model: {:error, :provider_timeout}], :text, 504, {"provider_timeout", "llm", nil}},
        {[model: {:error, :refused}], :text, 502, {"refused", "llm", nil}},
        {[model: {:error, :truncated}], :text, 502, {"truncated", "llm", nil}},
        {[model: :raise], :text, 502, {"provider_error", "llm", nil}},
        {[model: {:ok, "not json at all"}], :text, 502, {"bad_answer", "llm", nil}}
      ]

      for {opts, route, status, expected} <- cases do
        VoiceDoubles.install!(opts)

        conn =
          case route do
            :audio -> audio(ctx.tok_a, @m4a, "ru")
            :text -> text(ctx.tok_a, %{"text" => "x"})
          end

        assert reasons(conn, status) == expected, inspect(opts)
      end
    end

    test "V-FAIL-4 no error body leaks the key, a provider body or catalog data", ctx do
      schema = ctx.a.schema_name
      codes = [item_code(ctx.ma, schema), loc_code(ctx.ma, schema)]

      for result <- [:raise, {:error, :provider_error}, {:ok, VoiceDoubles.sentinel()}] do
        VoiceDoubles.install!(model: result)
        conn = text(ctx.tok_a, %{"text" => "x"})
        assert conn.status == 502

        for secret <- [VoiceDoubles.api_key(), VoiceDoubles.sentinel() | codes],
            do: refute(conn.resp_body =~ secret)
      end
    end
  end

  describe "nothing is stored or logged" do
    test "V-NIL-1 no record, event or audit entry is written", ctx do
      schema = ctx.a.schema_name
      VoiceDoubles.install!()
      # the first request of a token may provision its user: warm up before counting
      text(ctx.tok_a, %{"text" => "warm"}) |> status!(200)
      before = snapshot(schema)
      text(ctx.tok_a, %{"text" => "x"}) |> status!(200)
      audio(ctx.tok_a, @m4a, "ru") |> status!(200)
      text(ctx.tok_a, %{"text" => ""}) |> status!(422)
      audio(ctx.tok_a, m4a(@max + 1), "ru") |> status!(413)
      VoiceDoubles.install!(model: :raise)
      text(ctx.tok_a, %{"text" => "x"}) |> status!(502)
      assert snapshot(schema) == before
    end

    test "V-NIL-2 the log holds no transcript, text, prompt or key", ctx do
      typed = "ZZ-typed-phrase-91"

      log =
        capture_log([level: :debug], fn ->
          VoiceDoubles.install!(speech: {:ok, "ZZ-spoken-phrase-92"})
          text(ctx.tok_a, %{"text" => typed}) |> status!(200)
          audio(ctx.tok_a, @m4a, "ru") |> status!(200)
          VoiceDoubles.install!(model: :raise)
          text(ctx.tok_a, %{"text" => typed}) |> status!(502)
        end)

      for secret <- [
            typed,
            "ZZ-spoken-phrase-92",
            VoiceDoubles.api_key(),
            VoiceDoubles.sentinel()
          ],
          do: refute(log =~ secret)

      {:ok, items} = CatalogItems.list_active(ctx.a.schema_name)
      for r <- items, do: refute(log =~ r["name"])
    end
  end

  describe "tenancy" do
    test "V-TEN-1 list_active returns the prefix's own records only", ctx do
      {:ok, a_items} = CatalogItems.list_active(ctx.a.schema_name)
      {:ok, b_items} = CatalogItems.list_active(ctx.b.schema_name)
      a_ids = MapSet.new(a_items, & &1["record_id"])
      assert a_ids != MapSet.new()
      assert MapSet.disjoint?(a_ids, MapSet.new(b_items, & &1["record_id"]))

      {:ok, a_locs} = Locations.list_active(ctx.a.schema_name)
      assert Enum.all?(a_locs, &(&1["entity_type"] == "location_node"))

      assert {:error, :not_found} = CatalogItems.list_active("no_such_schema")
      assert {:error, :not_found} = CatalogItems.list_active(nil)
      assert {:error, :not_found} = Locations.list_active(:x)
    end

    test "V-TEN-2 tenant B cannot reach A's codes", ctx do
      a_item = item_code(ctx.ma, ctx.a.schema_name)
      a_loc = loc_code(ctx.ma, ctx.a.schema_name)

      a_name =
        Letflow.Repo.get_by!(Letflow.Entities.Record.Latest, [record_id: ctx.ma.item],
          prefix: ctx.a.schema_name
        ).field_values["name"]

      answer =
        VoiceDoubles.answer(%{
          "item_codes" => [a_item],
          "location_words" => "x",
          "location_code" => a_loc
        })

      VoiceDoubles.install!(model: {:ok, answer})
      body = text(ctx.tok_b, %{"text" => "x marks"}) |> status!(200)

      assert body["items"] == [] and body["location"] == nil
      assert "unknown_item" in Enum.map(body["dropped"], & &1["reason"])
      assert_received {:model, prompt, _}
      refute prompt =~ a_item
      refute prompt =~ a_loc
      refute prompt =~ a_name
    end

    test "V-TEN-3 a tenant named in the query or a header changes nothing", ctx do
      VoiceDoubles.install!()
      a_item = item_code(ctx.ma, ctx.a.schema_name)
      slug = Letflow.Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug

      text(ctx.tok_b, %{"text" => "x"}, "?tenant_id=#{ctx.a.tenant_id}", [{"x-tenant-slug", slug}])
      |> status!(200)

      assert_received {:model, prompt, _}
      refute prompt =~ a_item
    end
  end
end
