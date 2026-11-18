defmodule Letflow.Routers.LoginDiscoveryTest do
  @moduledoc """
  REQ-437 (spec `test/specs/REQ-437.md`): the response-equivalence matrices of
  design `req434-email-first-login-directory.md` s10.1 (Mode A,
  `:uniform_plus_email`), s10.2 (Mode B, `:redirect_single`, the shipped default)
  and s10.2a, through the REAL `Letflow.Router` at `/api/login-discovery`.

  One table drives both modes: every input class is built, requested once with the
  request's whole footprint measured (status, content type, Repo queries, outcome
  events, `Dispatch.submit/3` calls, deliveries recorded by the notifier double)
  and compared with the matrix cell. The group tests then compare the BYTES
  (status, every response header, body) across the classes the matrix says are
  indistinguishable. Mount switch, chain order and client IP are in
  `login_discovery_mount_test.exs`; notifier failure isolation in
  `login_discovery/dispatch_test.exs`.

  Tenant roles (`prepare!/1`): `a` explicit `redirect_single`, `b` NULL, `c`
  `uniform_plus_email`, `d` inactive. `async: false` (global limiter table, app
  env, the notifier double).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn, only: [get_resp_header: 2]

  alias Letflow.LoginDirectory
  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.Test.LoginDirectoryFixture, as: Fx
  alias Letflow.Test.LoginDiscoveryHelpers, as: H

  @neutral ~s({"result":"accepted"})
  @json_ct ["application/json; charset=utf-8"]

  @seeded %{
    single_redirect: [:a],
    single_null: [:b],
    single_uniform: [:c],
    multi: [:a, :b],
    mixed: [:a, :c],
    inactive_only: [:d],
    active_plus_inactive: [:a, :d],
    uniform_plus_inactive: [:c, :d],
    multi_plus_inactive: [:a, :b, :d],
    unknown: []
  }

  @malformed [
    :m_missing_email,
    :m_non_string_number,
    :m_non_string_list,
    :m_non_string_map,
    :m_null_email,
    :m_empty_email,
    :m_10000_chars,
    :m_300_chars,
    :m_no_at,
    :m_text_plain,
    :m_form_encoded,
    :m_no_content_type,
    :m_invalid_json,
    :m_json_array,
    :m_json_string,
    :m_oversize_body,
    :m_blank_body
  ]

  @kinds Map.keys(@seeded) ++ @malformed

  setup_all do
    {:ok, world: H.provision_world!([:a, :b, :c, :d])}
  end

  setup do
    H.setup_limiter!([])
    H.put_mode!(:redirect_single)
    H.put_enabled!(true)
    Double.reset()
    Double.set_owner(self())
    on_exit(&Double.reset/0)
    H.await_idle()
    :ok
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp prepare!(w) do
    H.set_mode!(w.a, "redirect_single")
    H.set_mode!(w.c, "uniform_plus_email")
    H.set_status!(w.d, :inactive)
    :ok
  end

  defp seed(w, tenant_keys) do
    email = H.email()
    Enum.each(tenant_keys, &H.add_entry!(Map.fetch!(w, &1), email))
    email
  end

  defp json(email), do: Jason.encode!(%{"email" => email})

  # `known` is a real, matching address (single, NULL-mode tenant `b`): a malformed
  # request carrying it must NEVER match.
  defp malformed_request(:m_missing_email, k),
    do: fn -> H.post_raw(~s({"other":"#{k}"}), "application/json") end

  defp malformed_request(:m_non_string_number, _k), do: fn -> H.post_email(12_345) end
  defp malformed_request(:m_non_string_list, k), do: fn -> H.post_email([k]) end
  defp malformed_request(:m_non_string_map, k), do: fn -> H.post_email(%{"a" => k}) end
  defp malformed_request(:m_null_email, _k), do: fn -> H.post_email(nil) end
  defp malformed_request(:m_empty_email, _k), do: fn -> H.post_email("") end

  defp malformed_request(:m_10000_chars, _k),
    do: fn -> H.post_email(String.duplicate("a", 10_000) <> "@x.test") end

  defp malformed_request(:m_300_chars, _k),
    do: fn -> H.post_email(String.duplicate("a", 300) <> "@x.test") end

  defp malformed_request(:m_no_at, _k), do: fn -> H.post_email("plainaddress-without-at-sign") end
  defp malformed_request(:m_text_plain, k), do: fn -> H.post_raw(json(k), "text/plain") end

  defp malformed_request(:m_form_encoded, k),
    do: fn ->
      H.post_raw("email=" <> URI.encode_www_form(k), "application/x-www-form-urlencoded")
    end

  defp malformed_request(:m_no_content_type, k), do: fn -> H.post_raw(json(k), nil) end

  defp malformed_request(:m_invalid_json, _k),
    do: fn -> H.post_raw("{not json", "application/json") end

  defp malformed_request(:m_json_array, k),
    do: fn -> H.post_raw(~s(["#{k}"]), "application/json") end

  defp malformed_request(:m_json_string, k),
    do: fn -> H.post_raw(~s("#{k}"), "application/json") end

  defp malformed_request(:m_oversize_body, k),
    do: fn ->
      H.post_raw(
        Jason.encode!(%{"email" => k, "pad" => String.duplicate("x", 5_000)}),
        "application/json"
      )
    end

  defp malformed_request(:m_blank_body, _k), do: fn -> H.post_raw("", "application/json") end

  # {request_fun, email_typed_or_nil}
  defp build(kind, w) when is_map_key(@seeded, kind) do
    email = seed(w, Map.fetch!(@seeded, kind))
    {fn -> H.post_email(email) end, email}
  end

  defp build(kind, w) when kind in @malformed do
    known = seed(w, [:b])
    {malformed_request(kind, known), nil}
  end

  # {status, tenants delivered (by role)} -- design s10.1 / s10.2 / D-A.
  defp expect(kind, _mode) when kind in @malformed, do: {202, []}
  defp expect(:unknown, _mode), do: {202, []}
  defp expect(:inactive_only, _mode), do: {202, []}
  defp expect(:single_uniform, _mode), do: {202, [:c]}
  defp expect(:multi, _mode), do: {202, [:a, :b]}
  defp expect(:mixed, _mode), do: {202, [:a, :c]}
  defp expect(:uniform_plus_inactive, _mode), do: {202, [:c]}
  defp expect(:multi_plus_inactive, _mode), do: {202, [:a, :b]}
  defp expect(:single_redirect, :redirect_single), do: {200, []}
  defp expect(:single_null, :redirect_single), do: {200, []}
  defp expect(:active_plus_inactive, :redirect_single), do: {200, []}
  defp expect(:single_redirect, :uniform_plus_email), do: {202, [:a]}
  defp expect(:single_null, :uniform_plus_email), do: {202, [:b]}
  defp expect(:active_plus_inactive, :uniform_plus_email), do: {202, [:a]}

  # The single tenant a 200 discloses.
  defp disclosed(:single_redirect), do: :a
  defp disclosed(:single_null), do: :b
  defp disclosed(:active_plus_inactive), do: :a

  defp tenant_ref(w, key) do
    %{slug: w[key].slug, display_name: w[key].display_name, hostname: nil}
  end

  # Runs one request with its whole footprint measured.
  defp exercise(request) do
    {{{conn, outcomes}, queries}, submissions} =
      H.capture_submissions(fn -> H.capture_queries(fn -> H.capture_outcomes(request) end) end)

    H.await_idle()

    %{
      conn: conn,
      outcomes: outcomes,
      queries: queries,
      submissions: submissions,
      deliveries: H.deliveries()
    }
  end

  defp assert_neutral(conn) do
    assert conn.status == 202
    assert get_resp_header(conn, "content-type") == @json_ct
    assert conn.resp_body == @neutral
  end

  defp forbidden(w) do
    from_world =
      for {_k, t} <- w, v <- [t.tenant_id, t.schema_name, t.idp_realm_id], do: v

    from_world ++
      ~w(disclose login_disclosure_mode uniform_plus_email redirect_single authority realm idp_ count tenant_id)
  end

  defp refute_leaks(w, body) do
    for needle <- forbidden(w),
        do: refute(body =~ needle, "response leaked #{inspect(needle)}: #{body}")

    :ok
  end

  # ── the matrix table, both modes (s10.1, s10.2, D-A, AC per-tenant) ─────

  for mode <- [:redirect_single, :uniform_plus_email], kind <- @kinds do
    test "#{kind} under #{mode}: status, content type, footprint and deliveries match the matrix",
         %{world: w} do
      assert_cell(unquote(kind), unquote(mode), w)
    end
  end

  defp assert_cell(kind, mode, w) do
    H.put_mode!(mode)
    prepare!(w)
    {request, email} = build(kind, w)
    {status, delivered} = expect(kind, mode)

    r = exercise(request)

    assert r.conn.status == status
    assert get_resp_header(r.conn, "content-type") == @json_ct
    # structural timing: exactly one query, exactly one notifier submission, one event
    assert length(r.queries) == 1
    assert r.submissions == 1

    expected_outcome = if status == 200, do: :tenant, else: :accepted
    assert r.outcomes == [{%{count: 1}, %{outcome: expected_outcome}}]

    if status == 200 do
      slug = w[disclosed(kind)].slug
      name = w[disclosed(kind)].display_name

      assert Jason.decode!(r.conn.resp_body) ==
               %{"result" => "tenant", "tenant" => %{"slug" => slug, "display_name" => name}}

      assert r.conn.resp_body |> Jason.decode!() |> Map.keys() |> Enum.sort() == [
               "result",
               "tenant"
             ]

      assert r.conn.resp_body
             |> Jason.decode!()
             |> Map.fetch!("tenant")
             |> Map.keys()
             |> Enum.sort() ==
               ["display_name", "slug"]
    else
      assert r.conn.resp_body == @neutral
    end

    refute_leaks(w, r.conn.resp_body)

    case delivered do
      [] ->
        assert r.deliveries == []

      keys ->
        # exactly ONE delivery, of the typed (normalised) address, with the tenant maps
        # stripped to slug + display_name + hostname (nil without onboarding), in query order
        assert [{recipient, tenants}] = r.deliveries
        assert recipient == String.downcase(String.trim(email))
        assert tenants == Enum.map(keys, &tenant_ref(w, &1))

        assert Enum.all?(
                 tenants,
                 &(&1 |> Map.keys() |> Enum.sort() == [:display_name, :hostname, :slug])
               )
    end
  end

  # ── byte-level equivalence classes ──────────────────────────────────────

  @mode_b_neutral @kinds -- [:single_redirect, :single_null, :active_plus_inactive]

  test "Mode A: EVERY input class is byte-identical (status, every header, body)", %{world: w} do
    H.put_mode!(:uniform_plus_email)
    prepare!(w)

    fps =
      for kind <- @kinds do
        {request, _} = build(kind, w)
        {kind, H.fp(request.())}
      end

    assert [{_kind, reference} | rest] = fps
    assert reference.status == 202
    assert reference.body == @neutral

    for {kind, fp} <- rest,
        do: assert(fp == reference, "#{kind} differs from the Mode A neutral response")
  end

  test "Mode B: {multi, unknown, malformed, inactive-only, uniform-tenant single, ...} are byte-identical; the single match is deliberately distinguishable",
       %{world: w} do
    prepare!(w)

    fps =
      for kind <- @mode_b_neutral do
        {request, _} = build(kind, w)
        {kind, H.fp(request.())}
      end

    assert [{_kind, reference} | rest] = fps
    assert reference.status == 202 and reference.body == @neutral

    for {kind, fp} <- rest,
        do: assert(fp == reference, "#{kind} differs from the Mode B neutral group")

    {single, _} = build(:single_redirect, w)
    single_fp = H.fp(single.())
    assert single_fp.status == 200
    refute single_fp == reference
  end

  test "Mode B: active + inactive behaves exactly as the active-only case (byte-identical 200)",
       %{world: w} do
    prepare!(w)
    {only_active, _} = build(:single_redirect, w)
    {with_inactive, _} = build(:active_plus_inactive, w)
    assert H.fp(only_active.()) == H.fp(with_inactive.())
  end

  test "Mode B: the first neutral response and the lookup-failure response are byte-identical", %{
    world: w
  } do
    prepare!(w)
    {unknown, _} = build(:unknown, w)
    baseline = H.fp(unknown.())

    # `SET LOCAL search_path` makes the one lookup query fail (rolled back with the test)
    H.break_lookup!()
    r = exercise(unknown)

    assert H.fp(r.conn) == baseline
    assert length(r.queries) == 1, "the failing query is still ATTEMPTED exactly once"
    assert r.submissions == 1
    assert r.deliveries == []
    assert r.outcomes == [{%{count: 1}, %{outcome: :accepted}}]
  end

  test "Mode A: the lookup-failure response is the same neutral bytes, one attempted query, no delivery",
       %{world: w} do
    H.put_mode!(:uniform_plus_email)
    prepare!(w)
    {unknown, _} = build(:unknown, w)
    baseline = H.fp(unknown.())

    H.break_lookup!()
    r = exercise(unknown)
    assert H.fp(r.conn) == baseline
    assert length(r.queries) == 1
    assert r.deliveries == []
    assert r.outcomes == [{%{count: 1}, %{outcome: :accepted}}]
  end

  for mode <- [:redirect_single, :uniform_plus_email] do
    test "pepper unavailable under #{mode}: neutral 202 identical to unknown, the one query still runs, zero deliveries, :accepted",
         %{world: w} do
      mode = unquote(mode)
      H.put_mode!(mode)
      prepare!(w)
      {unknown, _} = build(:unknown, w)
      baseline = H.fp(unknown.())

      # no pepper configured: keys cannot be derived, the zero key is used (D27)
      Fx.swap_keys!(:unset, nil)
      log = capture_log(fn -> send(self(), {:r, exercise(fn -> H.post_email(H.email()) end)}) end)
      assert_received {:r, r}

      assert H.fp(r.conn) == baseline
      assert length(r.queries) == 1
      assert r.submissions == 1
      assert r.deliveries == []
      assert r.outcomes == [{%{count: 1}, %{outcome: :accepted}}]
      assert log =~ "key material unavailable"
    end
  end

  # ── malformed inputs that DO carry a known address never match ──────────

  test "Mode B: JSON content type with a charset parameter, any casing, and a padded address still resolve (positive control)",
       %{world: w} do
    prepare!(w)
    email = seed(w, [:b])

    for ct <- ["application/json", "application/json; charset=utf-8", "APPLICATION/JSON"] do
      conn = H.post_raw(json(email), ct)
      assert conn.status == 200, "content type #{ct}"
      assert Jason.decode!(conn.resp_body)["tenant"]["slug"] == w.b.slug
    end

    padded = H.post_email("  " <> String.upcase(email) <> "  ")
    assert padded.status == 200
    assert Jason.decode!(padded.resp_body)["tenant"]["slug"] == w.b.slug
  end

  test "Mode B: a known single address in any malformed envelope is the neutral response, never the 200",
       %{world: w} do
    prepare!(w)
    baseline = H.fp(H.post_email(H.email()))

    for kind <- @malformed do
      {request, nil} = build(kind, w)
      assert H.fp(request.()) == baseline, "#{kind} must be the neutral response"
    end
  end

  test "no malformed input produces 400, 415, 422 or 500 in either mode", %{world: w} do
    prepare!(w)

    for mode <- [:redirect_single, :uniform_plus_email], kind <- @malformed do
      H.put_mode!(mode)
      {request, nil} = build(kind, w)
      conn = request.()
      assert conn.status == 202, "#{kind} under #{mode} gave #{conn.status}"
    end
  end

  # ── response shape ──────────────────────────────────────────────────────

  test "every 200 and 202 carries the three hardening headers", %{world: w} do
    prepare!(w)

    for kind <- [:single_redirect, :unknown, :multi] do
      {request, _} = build(kind, w)
      conn = request.()
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end
  end

  test "the 200 body is exactly {result, tenant:{slug, display_name}} -- verbatim literal bytes",
       %{world: w} do
    prepare!(w)
    {request, _} = build(:single_null, w)
    conn = request.()

    assert conn.resp_body ==
             Jason.encode!(%{
               result: "tenant",
               tenant: %{slug: w.b.slug, display_name: w.b.display_name}
             })
  end

  # ── deployment mode resolution through the router ───────────────────────

  test "an unrecognised deployment mode term behaves as the conservative uniform mode (D28)", %{
    world: w
  } do
    prepare!(w)
    {request, _} = build(:single_redirect, w)

    for junk <- [:nonsense, "redirect_single", 1] do
      H.put_mode!(junk)
      assert_neutral(request.())
    end
  end

  test "a missing mode config is the ratified default :redirect_single (the single match is disclosed)",
       %{world: w} do
    prepare!(w)
    {request, _} = build(:single_redirect, w)

    H.delete_env!(Letflow.LoginDiscovery)
    assert request.().status == 200

    H.put_env!(Letflow.LoginDiscovery, max_body_bytes: 2048)
    assert request.().status == 200
  end

  test "the deployment mode is read at request time (a ceiling flip needs no restart)", %{
    world: w
  } do
    prepare!(w)
    {request, _} = build(:single_redirect, w)
    assert request.().status == 200
    H.put_mode!(:uniform_plus_email)
    assert request.().status == 202
    H.put_mode!(:redirect_single)
    assert request.().status == 200
  end

  test "the body bound is configurable: a known single address in a body just over the bound is the neutral class, under it the 200",
       %{world: w} do
    prepare!(w)
    email = seed(w, [:b])
    body = Jason.encode!(%{"email" => email, "pad" => String.duplicate("x", 40)})

    assert H.post_raw(body, "application/json").status == 200

    H.put_env!(Letflow.LoginDiscovery,
      mode: :redirect_single,
      max_body_bytes: byte_size(body) - 1
    )

    assert_neutral(H.post_raw(body, "application/json"))

    H.put_env!(Letflow.LoginDiscovery, mode: :redirect_single, max_body_bytes: byte_size(body))
    assert H.post_raw(body, "application/json").status == 200
  end

  # ── rotation (0043 D-C) ─────────────────────────────────────────────────

  test "a two-pepper configuration (one row under each key for one tenant) is still ONE 200 byte-identical to the one-pepper case",
       %{world: w} do
    prepare!(w)
    email = H.email()

    # one-pepper case: a row under the (only) current key
    H.add_entry!(w.b, email)
    one_pepper = H.fp(H.post_email(email))
    assert one_pepper.status == 200

    # rotate: current becomes pepper 2, the old pepper stays as previous; the tenant now
    # holds a row under EACH key
    old = Fx.pepper(1)
    new = Fx.pepper(2)
    Fx.swap_keys!({"new-r437", new}, {"cur-r437", old})
    normalised = String.downcase(email)
    Fx.insert_row!(w.b.tenant_id, Fx.key_under(new, normalised), "new-r437")
    Fx.insert_row!(w.b.tenant_id, Fx.key_under(old, normalised), "cur-r437")

    two_pepper = H.fp(H.post_email(email))
    assert two_pepper == one_pepper
  end

  # ── cross-tenant isolation (AC) ─────────────────────────────────────────

  test "tenants A and B holding the same address, C another: no tenant :prefix, only public tables, no tenant-schema side effect",
       %{world: w} do
    prepare!(w)
    shared = H.email()
    other = H.email()
    H.add_entry!(w.a, shared)
    H.add_entry!(w.b, shared)
    H.add_entry!(w.c, other)

    users_before = for k <- [:a, :b, :c], do: Fx.user_count(w[k].schema_name)

    {conn, queries} = H.capture_queries(fn -> H.post_email(shared) end)
    {conn_c, queries_c} = H.capture_queries(fn -> H.post_email(other) end)
    H.await_idle()

    # both are served from the global tables, never from a tenant schema
    for qs <- [queries, queries_c] do
      assert length(qs) == 1

      for meta <- qs do
        assert meta.source == "tenants"
        assert Keyword.get(meta.options, :prefix) == nil
        refute meta.query =~ ~r/"tenant_[0-9a-f]/
        refute meta.query =~ "tenant_schemas"
      end
    end

    # A and B share the address: multi match, neutral; C's single is uniform: neutral too
    assert_neutral(conn)
    assert_neutral(conn_c)

    # nothing from tenant A/B/C can be in the body, and no side effect in any schema
    refute_leaks(w, conn.resp_body)
    assert users_before == for(k <- [:a, :b, :c], do: Fx.user_count(w[k].schema_name))
  end

  # ── no 401 / 403 anywhere (AC) ──────────────────────────────────────────

  test "no 401 or 403 is producible: every matrix class, both modes, with and without an Authorization header",
       %{world: w} do
    prepare!(w)

    statuses =
      for mode <- [:redirect_single, :uniform_plus_email], kind <- @kinds do
        H.put_mode!(mode)
        {request, _} = build(kind, w)
        request.().status
      end

    assert Enum.all?(statuses, &(&1 in [200, 202]))

    # the same with a hostile Authorization header on the wire
    for kind <- [:single_redirect, :unknown, :multi] do
      {_request, email} = build(kind, w)

      conn =
        Plug.Test.conn(:post, H.mount(), json(email))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer not-a-token")
        |> H.run()

      assert conn.status in [200, 202]
    end

    # wrong methods / sub-paths are 404, never 401/403
    for method <- [:get, :put, :patch, :delete, :head], suffix <- ["", "/", "/x", "/x/y"] do
      conn = H.call(method, suffix)
      assert conn.status == 404
    end

    conn = H.call(:post, "/x")
    assert conn.status == 404
  end

  test "lib/letflow/plugs/auth_pipeline.ex is unchanged (git diff empty)" do
    case System.cmd(
           "git",
           ["diff", "--quiet", "HEAD", "--", "lib/letflow/plugs/auth_pipeline.ex"],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {out, code} -> flunk("auth_pipeline.ex differs from HEAD (git exit #{code}): #{out}")
    end
  end

  # ── outcome counters (C-1, C7) ──────────────────────────────────────────

  test "wrong method or sub-path on an enabled mount: :not_found, one event, zero queries, zero submissions" do
    for {method, suffix} <- [get: "", get: "/x", put: "", delete: "/", patch: "/x/y", post: "/x"] do
      {{{conn, outcomes}, queries}, submissions} =
        H.capture_submissions(fn ->
          H.capture_queries(fn -> H.capture_outcomes(fn -> H.call(method, suffix) end) end)
        end)

      assert conn.status == 404
      assert outcomes == [{%{count: 1}, %{outcome: :not_found}}]
      assert queries == []
      assert submissions == 0
    end
  end

  test "the enabled-mount 404 is byte-identical to the router catch-all for the same method" do
    for method <- [:get, :post, :put, :patch, :delete] do
      mounted = H.fp(H.call(method, "/x"))
      catch_all = H.fp(Plug.Test.conn(method, "/api/zz-not-mounted") |> H.run())
      assert mounted == catch_all, "#{method}"
    end
  end

  test "outcome metadata is ONLY `outcome` (no email, key, IP, slug, tenant id, count) for every class",
       %{world: w} do
    prepare!(w)

    for kind <- @kinds do
      {request, _} = build(kind, w)
      {_conn, outcomes} = H.capture_outcomes(request)
      H.await_idle()
      assert [{measurements, metadata}] = outcomes
      assert measurements == %{count: 1}
      assert Map.keys(metadata) == [:outcome]
      assert metadata.outcome in [:tenant, :accepted]
    end
  end

  test ":accepted is emitted for EVERY 202 (known, multi, unknown, malformed alike) and :tenant only for the 200",
       %{world: w} do
    prepare!(w)

    outcomes =
      for kind <- @kinds do
        {request, _} = build(kind, w)
        {conn, [{_, %{outcome: outcome}}]} = H.capture_outcomes(request)
        H.await_idle()
        {kind, conn.status, outcome}
      end

    for {kind, status, outcome} <- outcomes do
      if status == 200 do
        assert outcome == :tenant, "#{kind}"
      else
        assert outcome == :accepted, "#{kind}"
      end
    end

    assert Enum.count(outcomes, fn {_, s, _} -> s == 200 end) == 3
  end

  # ── INV-4 (AC: Logger at :debug over known / unknown / multi / malformed) ─

  test "INV-4: Logger output at :debug contains no email, no email key (hex/base64) and no raw body",
       %{world: w} do
    prepare!(w)
    H.debug_logging!()

    single = seed(w, [:b])
    multi = seed(w, [:a, :b])
    uniform = seed(w, [:c])
    unknown = H.email()
    raw_secret = "raw-body-marker-#{System.unique_integer([:positive])}"

    emails = [single, multi, uniform, unknown]
    keys = Enum.flat_map(emails, &H.keys!/1)

    log =
      capture_log([level: :debug], fn ->
        for e <- emails, do: H.post_email(e)
        H.post_raw(~s({"email":"#{raw_secret}@x.test","pad":"#{raw_secret}"}), "application/json")
        H.post_raw("{#{raw_secret}", "application/json")
        H.post_raw(json(single), "text/plain")
        H.post_email(String.duplicate("a", 10_000) <> "@x.test")
        Process.sleep(50)
        H.await_idle()
      end)

    for needle <- emails ++ [raw_secret] do
      refute log =~ needle, "log leaked #{inspect(needle)}"
    end

    for key <- keys,
        encoded <- [
          Base.encode16(key, case: :lower),
          Base.encode16(key, case: :upper),
          Base.encode64(key),
          Base.url_encode64(key),
          Base.url_encode64(key, padding: false),
          inspect(key, binaries: :as_binaries)
        ] do
      refute log =~ encoded, "log leaked a key"
    end
  end

  test "the lookup-failure path logs nothing identifying either", %{world: w} do
    prepare!(w)
    H.debug_logging!()
    email = seed(w, [:b])
    H.break_lookup!()

    log =
      capture_log([level: :debug], fn ->
        H.post_email(email)
        H.await_idle()
      end)

    refute log =~ email
    refute log =~ w.b.slug
    refute log =~ w.b.display_name
  end

  # ── mode vocabulary is one source ───────────────────────────────────────

  test "Letflow.LoginDiscovery.mode/0 is the single reader LoginDirectory.deployment_mode/0" do
    for value <- [:redirect_single, :uniform_plus_email, :nonsense, nil] do
      H.put_env!(Letflow.LoginDiscovery, mode: value)
      assert Letflow.LoginDiscovery.mode() == LoginDirectory.deployment_mode()
    end
  end
end
