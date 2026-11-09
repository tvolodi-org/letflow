defmodule Letflow.Plugs.AuthAttemptLimitTest do
  @moduledoc """
  GH T-1558 part 1 (design `state/tasks/T-1558/design.md`, test IDs A1..A13; A14 is the child
  count in `test/letflow/supervisor/infrastructure_test.exs`).

  Real `Letflow.Router`, real tenants. `async: false`: the limiter's ETS table is node-global.
  Each test empties it, overrides the config with tiny refill rates (real elapsed time is then
  negligible; nothing sleeps) and uses its own documentation address (RFC 5737) so tests never
  share a bucket.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Plugs.AuthAttemptLimit, as: Limiter
  alias Letflow.Plugs.AuthAttemptLimit.Bucket
  alias Letflow.TenantFixture

  @event [:letflow, :auth_attempt_limit, :outcome]
  @route "/api/v1/identity/tokens"

  def handle_event(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:outcome, metadata})

  setup do
    original = Application.fetch_env(:letflow, Limiter)
    Bucket.reset()

    Application.put_env(:letflow, Limiter,
      failure_capacity: 10,
      failure_refill_per_sec: 0.0001,
      request_capacity: 3,
      request_refill_per_sec: 0.0001,
      max_keys: 100_000,
      sweep_interval_ms: 30_000
    )

    on_exit(fn ->
      Bucket.reset()

      case original do
        {:ok, v} -> Application.put_env(:letflow, Limiter, v)
        :error -> Application.delete_env(:letflow, Limiter)
      end
    end)

    :ok
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp from(conn, ip), do: %{conn | remote_ip: ip}

  defp api_token_get(plaintext, slug, ip) do
    conn(:get, @route)
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", slug)
    |> from(ip)
    |> dispatch()
  end

  defp jwt_get(token, ip) do
    conn(:get, @route)
    |> put_req_header("authorization", "Bearer " <> token)
    |> from(ip)
    |> dispatch()
  end

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "aal-user-#{Ecto.UUID.generate()}",
      display_name: "Auth Attempt Limit User",
      email: "aal-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp admin_token!(tenant) do
    user = insert_user!(tenant)

    {:ok, %{token: token, plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    {token, plaintext}
  end

  defp retry_after(conn),
    do: conn |> get_resp_header("retry-after") |> hd() |> String.to_integer()

  test "A1: the 11th bad API token from one address is 429 with retry-after" do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "aal-a1")
    ip = {192, 0, 2, 1}
    bad = "lf_tok_" <> String.duplicate("a", 40)

    for _ <- 1..10, do: assert(api_token_get(bad, tenant.tenant.slug, ip).status == 401)

    conn = api_token_get(bad, tenant.tenant.slug, ip)
    assert conn.status == 429
    assert retry_after(conn) >= 1
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "A2: the 11th invalid JWT from one address is 429" do
    ip = {192, 0, 2, 2}
    for _ <- 1..10, do: assert(jwt_get("not-a-valid-jwt", ip).status == 401)
    assert jwt_get("not-a-valid-jwt", ip).status == 429
    # another address is unaffected
    assert jwt_get("not-a-valid-jwt", {192, 0, 2, 22}).status == 401
  end

  test "A3: good traffic is never counted; failures afterwards still get their full allowance" do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "aal-a3")
    {_t, good} = admin_token!(tenant)
    ip = {192, 0, 2, 3}

    for _ <- 1..30, do: assert(api_token_get(good, tenant.tenant.slug, ip).status == 200)
    assert Bucket.size() == 0

    for _ <- 1..10, do: assert(jwt_get("garbage", ip).status == 401)
    assert jwt_get("garbage", ip).status == 429
  end

  test "A4: requests without Authorization are not counted" do
    ip = {192, 0, 2, 4}

    for _ <- 1..20,
        do: assert(conn(:get, @route) |> from(ip) |> dispatch() |> Map.fetch!(:status) == 401)

    assert Bucket.size() == 0
  end

  test "A5: an expired API token is not counted" do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "aal-a5")
    {token, plaintext} = admin_token!(tenant)
    past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

    token
    |> Ecto.Changeset.change(%{expires_at: past})
    |> Repo.update!(prefix: tenant.schema_name)

    ip = {192, 0, 2, 5}

    for _ <- 1..20, do: assert(api_token_get(plaintext, tenant.tenant.slug, ip).status == 401)
    assert Bucket.size() == 0
  end

  test "A6: a refused address gets 429 before the body is parsed" do
    ip = {192, 0, 2, 6}
    for _ <- 1..10, do: jwt_get("garbage", ip)

    conn =
      conn(:post, "/api/v1/identity/anything", "{this is not json")
      |> put_req_header("content-type", "application/json")
      |> from(ip)
      |> dispatch()

    assert conn.status == 429
  end

  test "A7: the 4th GET /api/tenant-config from one address is 429; another address answers" do
    ip = {192, 0, 2, 7}

    for _ <- 1..3,
        do:
          assert(
            conn(:get, "/api/tenant-config") |> from(ip) |> dispatch() |> Map.fetch!(:status) !=
              429
          )

    conn = conn(:get, "/api/tenant-config") |> from(ip) |> dispatch()
    assert conn.status == 429
    assert retry_after(conn) >= 1

    assert conn(:get, "/api/tenant-config")
           |> from({192, 0, 2, 77})
           |> dispatch()
           |> Map.fetch!(:status) != 429
  end

  test "A8: the same for GET /api/mobile/tenant-config" do
    ip = {192, 0, 2, 8}

    for _ <- 1..3,
        do:
          assert(
            conn(:get, "/api/mobile/tenant-config")
            |> from(ip)
            |> dispatch()
            |> Map.fetch!(:status) != 429
          )

    conn = conn(:get, "/api/mobile/tenant-config") |> from(ip) |> dispatch()
    assert conn.status == 429
    assert retry_after(conn) >= 1

    assert conn(:get, "/api/mobile/tenant-config")
           |> from({192, 0, 2, 88})
           |> dispatch()
           |> Map.fetch!(:status) != 429
  end

  test "A9: the bucket refills with an injected clock; retry_after names the wait" do
    key = {:auth_attempt, :failures, {:v4, {192, 0, 2, 9}}}
    assert Bucket.consume(key, 2, 1, 0) == :ok
    assert Bucket.consume(key, 2, 1, 0) == :ok
    assert Bucket.consume(key, 2, 1, 0) == :rate_limited
    assert Bucket.peek(key, 2, 1, 0) == :rate_limited
    assert Bucket.retry_after(key, 2, 1, 0) == 1
    assert Bucket.peek(key, 2, 1, 1_000) == :ok
    assert Bucket.consume(key, 2, 1, 1_000) == :ok
  end

  test "A10: at max_keys a new address is refused, a live one is still answered, sweep frees full rows" do
    Application.put_env(:letflow, Limiter,
      failure_capacity: 2,
      failure_refill_per_sec: 1,
      request_capacity: 2,
      request_refill_per_sec: 1,
      max_keys: 2,
      sweep_interval_ms: 30_000
    )

    k = fn n -> {:auth_attempt, :failures, {:v4, {192, 0, 2, n}}} end
    assert Bucket.consume(k.(1), 2, 1, 0) == :ok
    assert Bucket.consume(k.(2), 2, 1, 0) == :ok
    assert Bucket.consume(k.(3), 2, 1, 0) == :rate_limited
    assert Bucket.peek(k.(3), 2, 1, 0) == :rate_limited
    assert Bucket.peek(k.(1), 2, 1, 0) == :ok
    assert Bucket.consume(k.(1), 2, 1, 0) == :ok

    assert Bucket.sweep(60_000) == 2
    assert Bucket.size() == 0
    assert Bucket.consume(k.(3), 2, 1, 60_000) == :ok
  end

  test "A11: cross-tenant token is a counted 401; the 429 body does not depend on the slug" do
    tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "aal-a11a")
    tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "aal-a11b")
    {_t, token_a} = admin_token!(tenant_a)
    ip = {192, 0, 2, 11}

    assert api_token_get(token_a, tenant_a.tenant.slug, ip).status == 200

    cross = api_token_get(token_a, tenant_b.tenant.slug, ip)
    assert cross.status == 401
    refute cross.resp_body =~ tenant_a.tenant.slug
    refute cross.resp_body =~ tenant_b.tenant.slug
    assert Bucket.size() == 1

    for _ <- 1..9, do: api_token_get(token_a, tenant_b.tenant.slug, ip)

    r_a = api_token_get(token_a, tenant_a.tenant.slug, ip)
    r_b = api_token_get(token_a, tenant_b.tenant.slug, ip)
    r_unknown = api_token_get(token_a, "no-such-tenant-slug", ip)
    assert [r_a.status, r_b.status, r_unknown.status] == [429, 429, 429]
    assert r_a.resp_body == r_b.resp_body
    assert r_a.resp_body == r_unknown.resp_body
  end

  test "A12: no token or slug in logs; telemetry carries only outcome and mode" do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "aal-a12")
    ip = {192, 0, 2, 12}
    bad = "lf_tok_" <> String.duplicate("b", 40)
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, @event, &__MODULE__.handle_event/4, self())

    log =
      capture_log([level: :info], fn ->
        for _ <- 1..11, do: api_token_get(bad, tenant.tenant.slug, ip)
      end)

    :telemetry.detach(id)

    refute log =~ bad
    refute log =~ tenant.tenant.slug
    assert_received {:outcome, metadata}
    assert metadata == %{outcome: :rate_limited, mode: :failures}
  end

  test "A13: LETFLOW_AUTH_FAILURES_PER_MIN parsing" do
    assert Limiter.parse_failures_per_min(nil) == :unset
    assert Limiter.parse_failures_per_min("  ") == :unset
    assert Limiter.parse_failures_per_min("25") == {:ok, 25}
    assert Limiter.parse_failures_per_min("0") == {:error, :invalid}
    assert Limiter.parse_failures_per_min("-3") == {:error, :invalid}
    assert Limiter.parse_failures_per_min("ten") == {:error, :invalid}
    assert Limiter.parse_failures_per_min("10x") == {:error, :invalid}
    assert_raise ArgumentError, fn -> Limiter.validate_config!(failure_capacity: 0) end
    assert :ok = Limiter.validate_config!([])
  end
end
