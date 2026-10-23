defmodule Letflow.Api.ResponseTest do
  @moduledoc """
  Tests for `Letflow.Api.Response` (REQ-066, spec: `test/specs/REQ-066.md`).

  `Plug.Test`-driven, matching the convention already established in
  `test/letflow/router_test.exs` and `test/letflow/plugs/tenant_status_test.exs`.
  No database: `Letflow.Api.Response` is a conn-threading function library with no
  Ecto dependency, so plain `ExUnit.Case` is used rather than `Letflow.DataCase`.

  Content-type assertions here use the values MEASURED on the wire, including the
  `; charset=utf-8` suffix `Plug.Conn.put_resp_content_type/2` appends — an
  assertion against a bare `application/json` would fail against the real header.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Api.Response

  @json_ct "application/json; charset=utf-8"
  @problem_ct "application/problem+json; charset=utf-8"

  # See test/letflow/api/error_test.exs: nothing in config/*.exs sets
  # `:problems_base_uri`, so the compile_env default is what is compiled in.
  @base "https://bpm.example.com/problems/"

  # The exact 500 document `internal_error/1` must always produce, whatever the
  # underlying exception was (INV-4). Spelled out literally so a change to the
  # generic detail wording is a deliberate edit here, not an accident.
  @internal_body %{
    "type" => @base <> "internal-error",
    "title" => "Internal Server Error",
    "status" => 500,
    "detail" => "an unexpected error occurred",
    "trace_id" => ""
  }

  # Every ported error wrapper, with the arguments it needs beyond the conn and the
  # status it must send. Used by the "all wrappers" content-type case.
  @error_helpers [
    {:bad_request, ["d"], 400},
    {:unauthorized, ["d"], 401},
    {:forbidden, ["d"], 403},
    {:not_found, [], 404},
    {:conflict, ["d"], 409},
    {:unsupported_media_type, ["d"], 415},
    {:unprocessable, ["d"], 422},
    {:rate_limited, ["d"], 429},
    {:internal_error, [], 500},
    {:service_unavailable, ["d"], 503}
  ]

  defp req, do: conn(:get, "/")

  defp content_type(conn), do: get_resp_header(conn, "content-type")

  # The compiled documentation chunk — what a reader and `mix docs` actually see.
  defp moduledoc_for(module) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(module)
    doc
  end

  # ── AC5: success helpers ───────────────────────────────────────────────────

  describe "success helpers" do
    # REQ-066 AC2 — spec §2 case 14. Header-asserted, not inspected. MEASURED value
    # includes the charset suffix put_resp_content_type/2 appends.
    test "ok/2 sends 200 with the JSON content type" do
      conn = Response.ok(req(), %{status: "ok"})

      assert conn.status == 200
      assert content_type(conn) == [@json_ct]
      assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    end

    # REQ-066 AC5 — spec §2 case 23. Asserts the body survives as well as the status:
    # a helper that got 201 right while dropping the body would pass a status-only test.
    test "created/2 sends 201 with the encoded body" do
      conn = Response.created(req(), %{id: "inst-1", state: "running"})

      assert conn.status == 201
      assert content_type(conn) == [@json_ct]
      assert Jason.decode!(conn.resp_body) == %{"id" => "inst-1", "state" => "running"}
    end

    # REQ-066 AC5 — spec §2 case 24. The body must be the literal empty string.
    test "no_content/1 sends 204 with an empty body" do
      conn = Response.no_content(req())

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    # REQ-066 AC5 — spec §2 case 25. MEASURED: no content-type header is set at all,
    # because a 204 carries no representation. Most likely thing to be broken by a
    # later refactor funnelling no_content/1 through send_json/3.
    test "no_content/1 sets no content-type header" do
      assert content_type(Response.no_content(req())) == []
    end

    # REQ-066 AC5 — spec §2 case 26. send_json/3 is the shared primitive Letflow.Router
    # now delegates to; testing it at 202 proves it is genuinely status-parameterised
    # rather than incidentally correct at the two statuses its wrappers happen to use.
    test "send_json/3 honours an arbitrary status" do
      conn = Response.send_json(req(), 202, %{accepted: true})

      assert conn.status == 202
      assert content_type(conn) == [@json_ct]
      assert Jason.decode!(conn.resp_body) == %{"accepted" => true}
    end
  end

  # ── AC2: content-type split on the error side ──────────────────────────────

  describe "error helpers" do
    # REQ-066 AC2 — spec §2 case 15.
    test "not_found/1 sends the problem content type" do
      conn = Response.not_found(req())

      assert conn.status == 404
      assert content_type(conn) == [@problem_ct]
    end

    # REQ-066 AC2 — spec §2 case 16. AC2's guarantee is about the whole class of error
    # responses: a wrapper that bypassed send_problem/2 and set its own content type
    # would pass the single-representative case above and fail here.
    test "every wrapper sends problem+json at its own status" do
      for {name, args, status} <- @error_helpers do
        conn = apply(Response, name, [req() | args])

        assert conn.status == status, "#{name} sent #{conn.status}, expected #{status}"
        assert content_type(conn) == [@problem_ct], "#{name} sent #{inspect(content_type(conn))}"
      end
    end

    # REQ-066 AC1/AC2 — every wrapper must emit a full RFC 9457 document, not a bare
    # status. Complements error_test.exs, which proves the same for the pure builder:
    # this proves the wrapper actually routes through that builder.
    test "every wrapper sends a full problem document" do
      for {name, args, status} <- @error_helpers do
        body = Jason.decode!(apply(Response, name, [req() | args]).resp_body)

        assert body["status"] == status
        assert String.starts_with?(body["type"], @base)
        assert is_binary(body["title"]) and body["title"] != ""
        assert is_binary(body["detail"]) and body["detail"] != ""
      end
    end

    # REQ-066 — send_problem/2 is the primitive; an already-built document must be sent
    # at its OWN status, not at a status the sending function chooses.
    test "send_problem/2 sends at the document's status" do
      conn = Response.send_problem(req(), Error.conflict("already running"))

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["detail"] == "already running"
    end
  end

  # ── trace_id precedence (errors.zig:54, three branches) ────────────────────

  describe "trace_id resolution" do
    # REQ-066 — spec §2 case 27, branch 1. Both sources are set to DIFFERENT values, so
    # an implementation that always preferred conn.assigns would fail rather than
    # coincidentally pass.
    test "an explicit non-empty trace_id wins" do
      conn = assign(req(), :trace_id, "from-conn")
      problem = %{Error.bad_request("d") | trace_id: "from-document"}

      body = Jason.decode!(Response.send_problem(conn, problem).resp_body)

      assert body["trace_id"] == "from-document"
    end

    # REQ-066 — spec §2 case 28, branch 2: the conn-scoped stand-in for R-Co's
    # trace_context thread-local.
    test "conn assigns supply the trace_id when unset" do
      conn = assign(req(), :trace_id, "trace-abc-123")

      body = Jason.decode!(Response.bad_request(conn, "d").resp_body)

      assert body["trace_id"] == "trace-abc-123"
    end

    # REQ-066 — spec §2 case 29, branch 3. Guards against nil reaching the body as
    # JSON `null` instead of the "" errors.zig specifies.
    test "trace_id falls back to an empty string" do
      body = Jason.decode!(Response.bad_request(req(), "d").resp_body)

      assert body["trace_id"] == ""
      refute is_nil(body["trace_id"])
    end
  end

  # ── AC3 / INV-4: the 500 body never varies with the exception ──────────────

  # SECURITY-REVIEWER R1, F1: internal_error/2 sends the caller's fixed literal as the detail,
  # and nothing else of the 500 document changes.
  test "internal_error/2 sends the caller's fixed detail in the 500 document" do
    body = Jason.decode!(Response.internal_error(req(), "the tenant may exist").resp_body)

    assert body["type"] == @base <> "internal-error"
    assert body["status"] == 500
    assert body["detail"] == "the tenant may exist"
  end

  # Per the design (§0.3) INV-4 is tested by calling internal_error/1 directly from a
  # rescue clause. No catch-all Plug.ErrorHandler is wired by this requirement (that
  # belongs to a later router-pipeline requirement), so there is no live crash path to
  # drive and inventing one would test a mechanism that does not exist.
  @runtime_message "connection refused: password=hunter2 host=db.internal"
  @argument_message ~s(ERROR 42703: column "tenant_id" does not exist in SELECT * FROM events)

  defp internal_error_body_after_runtime_error do
    raise RuntimeError, @runtime_message
  rescue
    _e -> Response.internal_error(req()).resp_body
  end

  defp internal_error_body_after_argument_error do
    raise ArgumentError, @argument_message
  rescue
    _e -> Response.internal_error(req()).resp_body
  end

  # The leak half needs the seeded values to actually REACH an input the function
  # under test observes. `internal_error/1` is arity-1 and conn-only, so the conn is
  # that input and every field a leaking implementation could plausibly reach for
  # gets loaded here: assigns (the exception struct itself, its message, its module
  # name, the formatted stacktrace), a request header, and the request path/query.
  # `:trace_id` is deliberately NOT assigned — that assign is legitimately reflected
  # into the body by send_problem/2, so seeding it would prove nothing.
  defp leaky_conn(e, stacktrace) do
    conn(:get, "/api/v1/tenants/acme/instances?debug=hunter2&sql=SELECT+tenant_id")
    |> put_req_header("x-db-dsn", "postgres://app:hunter2@db.internal:5432/letflow")
    |> put_req_header("x-debug-flags", "stacktrace,verbose")
    |> assign(:error, e)
    |> assign(:exception_message, Exception.message(e))
    |> assign(:error_type, to_string(e.__struct__))
    |> assign(:stacktrace, Exception.format_stacktrace(stacktrace))
  end

  defp leaky_body_after_runtime_error do
    raise RuntimeError, @runtime_message
  rescue
    e -> Response.internal_error(leaky_conn(e, __STACKTRACE__)).resp_body
  end

  defp leaky_body_after_argument_error do
    raise ArgumentError, @argument_message
  rescue
    e -> Response.internal_error(leaky_conn(e, __STACKTRACE__)).resp_body
  end

  # A `refute String.contains?/2` on the raw JSON body alone would miss a leak whose
  # text contains a quote or a backslash, since Jason escapes those on the way out
  # (@argument_message contains `"tenant_id"`). The searched surface is therefore the
  # raw body PLUS every decoded string value, which undoes that escaping.
  defp leak_surface(body) do
    values =
      body
      |> Jason.decode!()
      |> Map.values()
      |> Enum.map_join("\n", &to_string/1)

    body <> "\n" <> values
  end

  # Seeded into BOTH conns by leaky_conn/2, so reachable in either case: the DSN
  # header supplies "hunter2"/"db.internal", the query string supplies
  # "SELECT"/"tenant_id", the :error_type assign supplies "Elixir.", and the
  # :stacktrace assign supplies both its formatted frames and (to an implementation
  # that dumped conn.assigns) the word "stacktrace" itself.
  @shared_forbidden ["hunter2", "db.internal", "SELECT", "tenant_id", "Elixir.", "stacktrace"]

  # Each case additionally forbids only what ITS OWN exception contributed. Listing
  # the ArgumentError's message against the RuntimeError body would be a decorative
  # refute — nothing in that call could have produced it.
  defp leak_cases do
    [
      {leak_surface(leaky_body_after_runtime_error()),
       [@runtime_message, "RuntimeError" | @shared_forbidden]},
      {leak_surface(leaky_body_after_argument_error()),
       [@argument_message, "ArgumentError" | @shared_forbidden]}
    ]
  end

  describe "internal_error and INV-4" do
    # REQ-066 AC3 — spec §2 case 17.
    test "a rescued RuntimeError yields the fixed body" do
      assert Jason.decode!(internal_error_body_after_runtime_error()) == @internal_body
    end

    # REQ-066 AC3 — spec §2 case 18: a different exception type, a completely
    # different distinctive message.
    test "a rescued ArgumentError yields the fixed body" do
      assert Jason.decode!(internal_error_body_after_argument_error()) == @internal_body
    end

    # REQ-066 AC3 — spec §2 case 19. This is the criterion's literal claim: the two
    # bodies are compared to EACH OTHER as raw strings, so it holds even if the
    # expected literal above were itself wrong.
    test "two exception types give byte-identical bodies" do
      assert internal_error_body_after_runtime_error() ==
               internal_error_body_after_argument_error()
    end

    # REQ-066 AC3 — spec §2 case 20. The leak-detection half of INV-4, distinct from
    # the identical-across-types half: two bodies can be identical to each other and
    # both still leak the same shared secret.
    test "no seeded exception material leaks into the body" do
      for {surface, forbidden} <- leak_cases() do
        for value <- forbidden do
          refute String.contains?(surface, value), "500 body leaked #{inspect(value)}"
        end
      end
    end

    # REQ-066 AC3 — spec §2 case 20b. The same claim stated positively and at maximum
    # strength: a conn loaded with the exception, its message, its module name, the
    # stacktrace, a fake DSN header and a secret-bearing query string still yields the
    # byte-identical fixed document a bare conn yields. Any reflection of ANY conn
    # field into the detail — not only the substrings enumerated above — breaks this.
    test "a fully seeded conn yields the same bytes as a bare conn" do
      assert leaky_body_after_runtime_error() == internal_error_body_after_runtime_error()
      assert leaky_body_after_argument_error() == internal_error_body_after_argument_error()
    end
  end

  # ── AC4 / INV-5: the 404 body is byte-identical on every path ──────────────

  # Fixed literals, not Ecto.UUID.generate/0 — nothing in this file may depend on
  # unseeded randomness (AC8).
  @missing_id "0f8c1a52-3d4b-4c7e-9a10-6b2e5d3f7c41"
  @other_tenant_id "b41d9e07-5a62-4f38-8c19-2e7a0d4b6f53"

  describe "not_found and INV-5" do
    # REQ-066 AC4 — spec §2 case 21. The two conns differ in everything a handler could
    # plausibly branch on: request path, and the cross-tenant conn additionally carries
    # tenant assigns naming a DIFFERENT tenant. The comparison is on the serialised
    # bodies as raw strings — asserting both are merely 404 would not prove the claim.
    test "never-existed and cross-tenant 404s match" do
      never_existed = Response.not_found(conn(:get, "/api/v1/instances/#{@missing_id}"))

      cross_tenant =
        conn(:get, "/api/v1/tenants/#{@other_tenant_id}/instances/#{@missing_id}")
        |> assign(:tenant_id, "acme")
        |> assign(:requested_tenant_id, @other_tenant_id)
        |> Response.not_found()

      assert never_existed.status == 404
      assert cross_tenant.status == 404
      assert never_existed.resp_body == cross_tenant.resp_body
      assert content_type(never_existed) == content_type(cross_tenant)
    end

    # REQ-066 AC4 — spec §2 case 22. The structural half: Letflow.Router's `match _`
    # catch-all routes through Response.not_found/1, so two unmatched routes driven
    # through the real router must produce bodies byte-identical to each other and to
    # the direct call. Without this, AC4 would be proven only for direct calls and a
    # future route hand-rendering its own 404 would go undetected.
    #
    # NOTE (REQ-070): After REQ-070 decomposed the router, /api/v1/* paths now forward
    # to Letflow.Plugs.ApiPipeline which runs AuthPipeline before routing. Unauthenticated
    # requests to /api/v1/* therefore receive 401 (auth-gated), not 404 (catch-all).
    # The top-level router's `match _` catch-all only fires for paths outside /api/v1/
    # and /health. Both `a` and `b` below use non-API paths to test the catch-all.
    test "the router catch-all emits the same body" do
      opts = Letflow.Router.init([])

      a = Letflow.Router.call(conn(:get, "/api/v2/instances/#{@missing_id}"), opts)
      b = Letflow.Router.call(conn(:get, "/definitely/not/a/route"), opts)
      direct = Response.not_found(req())

      assert a.status == 404
      assert b.status == 404
      assert a.resp_body == b.resp_body
      assert a.resp_body == direct.resp_body
    end
  end

  # ── AC6: the moduledoc records the translation and the divergence ──────────

  describe "moduledoc contract" do
    # REQ-066 AC6 — spec §2 case 30. Asserted against the compiled documentation chunk
    # (what a reader or `mix docs` actually gets), not against the source file text, so
    # the test survives a move or reformat and fails if the moduledoc is dropped in a
    # later refactor — which is the real risk AC6 guards.
    test "Response records the translation and divergence" do
      doc = moduledoc_for(Letflow.Api.Response)

      assert doc =~ "HandlerResult"
      assert doc =~ "not ported as a struct"
      assert doc =~ "Plug.Conn.t()"
      assert doc =~ "application/problem+json"
      assert doc =~ "diverges from R-Co"
      assert doc =~ "application/json"
    end

    # REQ-066 AC6 — the same obligations are restated on the Error module, which is
    # where a reader looking up the problem-document shape lands first.
    test "Error records the same translation notes" do
      doc = moduledoc_for(Letflow.Api.Error)

      assert doc =~ "HandlerResult"
      assert doc =~ "application/problem+json"
      assert doc =~ "INV-4"
      assert doc =~ "INV-5"
    end
  end

  # GH #2701 (REQ-516 S3) — record events carry `field_values`; the history item shaping drops
  # them for every caller, and no other event type is touched by the new arm.
  describe "public_event_payload/3 for entity record events (REQ-516 S3)" do
    @record_payload %{
      "entity_type" => "customer",
      "record_id" => "r-1",
      "field_values" => %{"name" => "Ada", "secret" => "s3"}
    }

    # R1 — ENTITY_RECORD_CREATED and ENTITY_RECORD_UPDATED return the payload without field_values.
    test "R1: ENTITY_RECORD_CREATED and ENTITY_RECORD_UPDATED drop field_values" do
      for event_type <- ["ENTITY_RECORD_CREATED", "ENTITY_RECORD_UPDATED"] do
        shaped = Response.public_event_payload(event_type, @record_payload, MapSet.new())

        refute Map.has_key?(shaped, "field_values")
        assert shaped == %{"entity_type" => "customer", "record_id" => "r-1"}
      end
    end

    test "R1: the drop holds whatever hidden set the caller holds" do
      shaped =
        Response.public_event_payload(
          "ENTITY_RECORD_UPDATED",
          @record_payload,
          MapSet.new(["secret"])
        )

      refute Map.has_key?(shaped, "field_values")
      refute shaped |> inspect() |> String.contains?("s3")
    end

    test "R1: other event types keep field_values unchanged" do
      shaped =
        Response.public_event_payload("ENTITY_RECORD_DELETED", @record_payload, MapSet.new())

      assert Map.has_key?(shaped, "field_values")

      other = Response.public_event_payload("INSTANCE_CREATED", @record_payload, MapSet.new())
      assert Map.has_key?(other, "field_values")
    end
  end
end
