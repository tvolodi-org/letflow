defmodule Letflow.Api.ErrorTest do
  @moduledoc """
  Unit tests for `Letflow.Api.Error` (REQ-066, spec: `test/specs/REQ-066.md`).

  Pure — `Letflow.Api.Error` has no `Plug.Conn` dependency and no I/O, so per
  `docs/guides/test_developer_guide.md` §1 ("pure functions first") these are
  direct unit tests with no server and no database. The conn-threading half of
  REQ-066 lives in `test/letflow/api/response_test.exs`.

  Every assertion here is made against the **serialised JSON body**, not against
  the struct, so what is pinned is the wire contract a client actually receives.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Error

  # Nothing in config/*.exs sets `:problems_base_uri`, so `Application.compile_env/3`'s
  # own default is what is compiled into `Letflow.Api.Error`. Spelled out literally
  # rather than read back from the application env, so a change to the published
  # problem-type namespace has to be made deliberately here too.
  @base "https://bpm.example.com/problems/"

  # Serialise, then decode — asserting on the round-tripped JSON rather than on the
  # struct is what makes these tests cover the wire contract instead of the in-memory
  # shape.
  defp decode(%Error{} = problem), do: Jason.decode!(Error.serialise(problem))

  # AC1's three obligations in one place: the four RFC 9457 fields are present with
  # their expected values, and `type` is an ABSOLUTE URI. The absolute-URI check is
  # deliberately separate from the `type` string equality: a relative `type` would
  # still satisfy `type == @base <> slug` if the base itself were ever made relative,
  # while violating the criterion.
  defp assert_problem(problem, slug, title, status, detail) do
    decoded = decode(problem)

    assert decoded["type"] == @base <> slug
    assert decoded["title"] == title
    assert decoded["status"] == status
    assert decoded["detail"] == detail

    uri = URI.parse(decoded["type"])
    assert uri.scheme == "https"
    assert is_binary(uri.host) and uri.host != ""
    assert String.starts_with?(decoded["type"], "https://")

    decoded
  end

  describe "problem constructors" do
    # REQ-066 AC1 — spec §2 case 1.
    test "bad_request/1 builds the 400 document" do
      Error.bad_request("body was not valid JSON")
      |> assert_problem("bad-request", "Bad Request", 400, "body was not valid JSON")
    end

    # REQ-066 AC1 — spec §2 case 2.
    test "unauthorized/1 builds the 401 document" do
      Error.unauthorized("bearer token missing")
      |> assert_problem("unauthorized", "Unauthorized", 401, "bearer token missing")
    end

    # REQ-066 AC1 — spec §2 case 3.
    test "forbidden/1 builds the 403 document" do
      Error.forbidden("role does not permit this action")
      |> assert_problem("forbidden", "Forbidden", 403, "role does not permit this action")
    end

    # REQ-066 AC1 — spec §2 case 4. `not_found/0` takes no detail (INV-5), so the
    # detail asserted here is the module attribute baked into the function body.
    test "not_found/0 builds the 404 document" do
      Error.not_found()
      |> assert_problem("not-found", "Not Found", 404, "the requested resource was not found")
    end

    # REQ-066 AC1 — spec §2 case 5.
    test "conflict/1 builds the 409 document" do
      Error.conflict("instance already completed")
      |> assert_problem("conflict", "Conflict", 409, "instance already completed")
    end

    # REQ-066 AC1 — spec §2 case 6. Slug is hyphenated in full, per errors.zig.
    test "unsupported_media_type/1 builds the 415 document" do
      Error.unsupported_media_type("expected application/json")
      |> assert_problem(
        "unsupported-media-type",
        "Unsupported Media Type",
        415,
        "expected application/json"
      )
    end

    # REQ-066 AC1 — spec §2 case 7. Note the slug is "unprocessable-entity" while the
    # function is `unprocessable/1`; the slug follows errors.zig, not the function name.
    test "unprocessable/1 builds the 422 document" do
      Error.unprocessable("variable failed schema validation")
      |> assert_problem(
        "unprocessable-entity",
        "Unprocessable Entity",
        422,
        "variable failed schema validation"
      )
    end

    # REQ-066 AC1 — spec §2 case 8. MEASURED: the title is "Too Many Requests" verbatim
    # from errors.zig's problemRateLimited, NOT "Rate Limited" Title-Cased from the slug.
    test "rate_limited/1 builds the 429 document" do
      Error.rate_limited("quota exhausted")
      |> assert_problem("rate-limited", "Too Many Requests", 429, "quota exhausted")
    end

    # REQ-066 AC1 — spec §2 case 9. MEASURED: title is "Internal Server Error" verbatim
    # from errors.zig, not "Internal Error" derived from the "internal-error" slug.
    # `internal/0` takes no detail (INV-4).
    test "internal/0 builds the 500 document" do
      Error.internal()
      |> assert_problem(
        "internal-error",
        "Internal Server Error",
        500,
        "an unexpected error occurred"
      )
    end

    # SECURITY-REVIEWER R1, F1: a 500 whose detail names a committed tenant. The detail is the
    # caller's literal, sent unchanged; INV-4 holds because callers pass literals only.
    test "internal/1 builds the 500 document with the fixed detail it is given" do
      Error.internal("the tenant may exist")
      |> assert_problem("internal-error", "Internal Server Error", 500, "the tenant may exist")
    end

    # REQ-066 AC1 — spec §2 case 10.
    test "service_unavailable/1 builds the 503 document" do
      Error.service_unavailable("partition not yet attached")
      |> assert_problem(
        "service-unavailable",
        "Service Unavailable",
        503,
        "partition not yet attached"
      )
    end
  end

  describe "idempotency_key_reuse/0 (GH #2543)" do
    # Design D6: a constant 422 body with a fixed code; no argument, so no
    # original record data can ever reach it (INV-2, INV-4).
    test "idempotency_key_reuse/0 builds the 422 document" do
      decoded =
        Error.idempotency_key_reuse()
        |> assert_problem(
          "idempotency-key-reuse",
          "Idempotency Key Reused",
          422,
          "this idempotency_key was already used for a different request; send a new key"
        )

      assert decoded["code"] == "idempotency_key_reuse"

      assert decoded |> Map.keys() |> Enum.sort() ==
               ["code", "detail", "status", "title", "trace_id", "type"]
    end
  end

  describe "module transition problems (REQ-578)" do
    test "E1: dependents_installed and upgrade_required are 409 with a constant code" do
      dependents = decode(Error.module_dependents_installed(["b", "a"]))
      assert dependents["status"] == 409
      assert dependents["code"] == "dependents_installed"
      assert dependents["dependents"] == ["a", "b"]

      upgrade = decode(Error.module_upgrade_required())
      assert upgrade["status"] == 409
      assert upgrade["code"] == "upgrade_required"
    end

    test "E2: open_work_exists is 409 with a constant code and two counts, no ids" do
      open_work = decode(Error.module_open_work_exists(2, 3))
      assert open_work["status"] == 409
      assert open_work["code"] == "open_work_exists"
      assert open_work["open_instances"] == 2
      assert open_work["open_tasks"] == 3
    end
  end

  describe "serialisation contract" do
    # REQ-066 — spec §2 case 11. errors.zig's ProblemDetails carries a "" default for
    # trace_id and the requirement text calls it out explicitly. The ten constructor
    # tests above never look at trace_id, so a constructor that dropped the field
    # entirely would pass all of them and fail only here.
    test "trace_id defaults to an empty string" do
      decoded = decode(Error.bad_request("nope"))

      assert Map.has_key?(decoded, "trace_id")
      assert decoded["trace_id"] == ""
      refute is_nil(decoded["trace_id"])
    end

    # REQ-066 — spec §2 case 13. Guards the `@derive {Jason.Encoder, only: [...]}`
    # list: dropping a field from `only:` would shrink the wire contract while every
    # per-field assertion above still passed on the surviving fields.
    test "serialise/1 emits all five RFC 9457 keys" do
      keys = Error.conflict("x") |> decode() |> Map.keys() |> Enum.sort()

      assert keys == ["detail", "status", "title", "trace_id", "type"]
    end

    # REQ-066 — spec §2 case 12. errors.zig builds its body with std.fmt.allocPrint and
    # raw "{s}" interpolation, which does NOT escape quotes/backslashes — a detail
    # containing either produces invalid JSON there. Jason escapes properly; the design
    # (§0.1) records this as a deliberate correctness improvement that must not be
    # "fixed" back to raw interpolation. This test is what would catch that regression.
    test "serialise/1 escapes quotes and backslashes in detail" do
      detail = ~S(field "name" contains a \ backslash)

      body = Error.bad_request(detail) |> Error.serialise()

      assert Jason.decode!(body)["detail"] == detail
    end

    # REQ-066 — control characters are the other half of the escaping story: a raw
    # newline inside a JSON string literal is invalid JSON outright.
    test "serialise/1 escapes control characters in detail" do
      detail = "line one\nline two\ttabbed"

      assert Jason.decode!(Error.serialise(Error.bad_request(detail)))["detail"] == detail
    end
  end
end
