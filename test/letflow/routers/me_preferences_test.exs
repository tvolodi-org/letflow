defmodule Letflow.Routers.MePreferencesTest do
  @moduledoc """
  T-1389: `GET`/`PUT /api/v1/me/preferences`, the per-user preferences store. Real Postgres, real
  tenant schemas, real API tokens through the real `Letflow.Router` (D-098).
  `async: false`: tenant provisioning and the platform pin are VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @path "/api/v1/me/preferences"
  @key "ui.document_layout"

  setup do
    Fixture.unpin!()
    %{a: a, b: b} = Fixture.two_tenants!()
    {:ok, a: a, b: b}
  end

  defp call(method, path, fixture, token, body) do
    method
    |> Fixture.api_conn(path, token, fixture.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  defp get_prefs(fixture, token), do: call(:get, @path, fixture, token, nil)
  defp put_prefs(fixture, token, body), do: call(:put, @path, fixture, token, body)
  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp layout(layout), do: %{"preferences" => %{@key => layout}}

  defp raw_rows(fixture) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT user_id::text, key, value FROM "#{fixture.schema_name}".user_preferences|
      )

    rows
  end

  defp audit_actions(fixture) do
    from(e in Entry, where: like(e.action, "user_preferences.%"), order_by: e.timestamp)
    |> Repo.all(prefix: fixture.schema_name)
  end

  test "P1 put then get; a second put overwrites the one row; the stored value is wrapped", %{
    a: a
  } do
    token = Fixture.mint_token!(a, ["TASK_WORKER"])

    assert get_prefs(a, token).status == 200
    assert json(get_prefs(a, token)) == %{"preferences" => %{}}

    put = put_prefs(a, token, layout("tabs"))
    assert put.status == 200, put.resp_body
    assert json(put) == %{"preferences" => %{@key => "tabs"}}
    assert json(get_prefs(a, token)) == %{"preferences" => %{@key => "tabs"}}
    assert [[_uid, @key, %{"v" => "tabs"}]] = raw_rows(a)

    assert put_prefs(a, token, layout("row")).status == 200
    assert json(get_prefs(a, token)) == %{"preferences" => %{@key => "row"}}
    assert [[_uid, @key, %{"v" => "row"}]] = raw_rows(a)
  end

  test "P2 another user of the same tenant cannot see it, and does not change it", %{a: a} do
    alice = Fixture.mint_token!(a, ["TASK_WORKER"])
    bob = Fixture.mint_token!(a, ["TASK_WORKER"])

    assert put_prefs(a, alice, layout("tabs")).status == 200
    assert json(get_prefs(a, bob)) == %{"preferences" => %{}}

    assert put_prefs(a, bob, layout("row")).status == 200
    assert json(get_prefs(a, alice)) == %{"preferences" => %{@key => "tabs"}}
    assert json(get_prefs(a, bob)) == %{"preferences" => %{@key => "row"}}
    assert length(raw_rows(a)) == 2
  end

  test "P3 a tenant admin reads nothing of others; no route takes a user id", %{a: a} do
    worker = Fixture.mint_token!(a, ["TASK_WORKER"])
    admin = Fixture.mint_token!(a, ["TENANT_ADMIN"])
    assert put_prefs(a, worker, layout("tabs")).status == 200

    assert json(get_prefs(a, admin)) == %{"preferences" => %{}}

    [[uid | _]] = raw_rows(a)
    # unmatched `/me/*` paths answer with the router's fixed refusal, never data
    assert call(:get, @path <> "/" <> uid, a, admin, nil).status in [403, 404]
    assert call(:put, @path <> "/" <> uid, a, admin, layout("row")).status in [403, 404]
    # a user id in the query or body is never read
    spoof = call(:get, @path <> "?user_id=" <> uid, a, admin, nil)
    assert json(spoof) == %{"preferences" => %{}}

    body = %{"user_id" => uid, "preferences" => %{@key => "row"}}
    assert put_prefs(a, admin, body).status == 200
    assert json(get_prefs(a, worker)) == %{"preferences" => %{@key => "tabs"}}
  end

  test "P4 tenant isolation: rows live in the caller's schema only", %{a: a, b: b} do
    ta = Fixture.mint_token!(a, ["TASK_WORKER"])
    tb = Fixture.mint_token!(b, ["TASK_WORKER"])

    assert put_prefs(a, ta, layout("tabs")).status == 200
    assert json(get_prefs(b, tb)) == %{"preferences" => %{}}
    assert raw_rows(b) == []
    assert length(raw_rows(a)) == 1

    # a token of tenant A presented against tenant B is no access to B's data
    cross = call(:get, @path, b, ta, nil)
    assert cross.status in [401, 403, 404]
    assert raw_rows(b) == []
  end

  test "P5 an unknown key is refused 422 naming the key; nothing is written", %{a: a} do
    token = Fixture.mint_token!(a, ["TASK_WORKER"])

    conn = put_prefs(a, token, %{"preferences" => %{"x.y" => "1"}})
    assert conn.status == 422
    assert conn.resp_body =~ "x.y"

    mixed = put_prefs(a, token, %{"preferences" => %{@key => "tabs", "x.y" => "1"}})
    assert mixed.status == 422
    assert raw_rows(a) == []
    assert audit_actions(a) == []
  end

  test "P6 an invalid layout is refused 422 and the stored value is unchanged", %{a: a} do
    token = Fixture.mint_token!(a, ["TASK_WORKER"])
    assert put_prefs(a, token, layout("tabs")).status == 200

    for bad <- ["grid", 1, ["tabs"], %{"v" => "tabs"}, true, ""] do
      conn = put_prefs(a, token, layout(bad))
      assert conn.status == 422, inspect(bad)
      assert conn.resp_body =~ @key
    end

    assert json(get_prefs(a, token)) == %{"preferences" => %{@key => "tabs"}}
  end

  test "P7 size limits: nine keys, a long value, hostile key bytes", %{a: a} do
    token = Fixture.mint_token!(a, ["TASK_WORKER"])

    nine = Map.new(1..9, fn i -> {"k#{i}", "x"} end)
    assert put_prefs(a, token, %{"preferences" => nine}).status == 422

    long = put_prefs(a, token, layout(String.duplicate("a", 300)))
    assert long.status == 422
    refute long.resp_body =~ String.duplicate("a", 100)

    hostile = "<script>alert(1)</script>"
    conn = put_prefs(a, token, %{"preferences" => %{hostile => "x"}})
    assert conn.status == 422
    refute conn.resp_body =~ "<script>"
    assert raw_rows(a) == []
  end

  test "P8 null resets the key and audits a reset; resetting an absent key is a no-op", %{a: a} do
    token = Fixture.mint_token!(a, ["TASK_WORKER"])

    assert put_prefs(a, token, layout(nil)).status == 200
    assert audit_actions(a) == []

    assert put_prefs(a, token, layout("tabs")).status == 200
    conn = put_prefs(a, token, layout(nil))
    assert conn.status == 200
    assert json(conn) == %{"preferences" => %{}}
    assert json(get_prefs(a, token)) == %{"preferences" => %{}}
    assert raw_rows(a) == []

    assert Enum.map(audit_actions(a), & &1.action) == [
             "user_preferences.set",
             "user_preferences.reset"
           ]
  end

  test "P9 one audit entry per change with plain before/after; a same-value put adds none", %{
    a: a
  } do
    token = Fixture.mint_token!(a, ["TASK_WORKER"])

    assert put_prefs(a, token, layout("tabs")).status == 200
    assert put_prefs(a, token, layout("tabs")).status == 200
    assert put_prefs(a, token, layout("row")).status == 200

    [first, second] = audit_actions(a)
    assert first.action == "user_preferences.set"
    assert first.before_state == nil
    assert first.after_state == %{"value" => "tabs"}
    assert second.before_state == %{"value" => "tabs"}
    assert second.after_state == %{"value" => "row"}
    assert first.resource_type == "user_preference"
    assert String.ends_with?(first.resource_id, ":" <> @key)

    assert {:ok, _} = Audit.verify_chain(a.schema_name)
  end

  test "P10 a body that is not a non-empty preferences object is refused 422", %{a: a} do
    token = Fixture.mint_token!(a, ["TASK_WORKER"])

    for body <- [
          %{},
          %{"preferences" => %{}},
          %{"preferences" => "tabs"},
          %{"preferences" => [1]},
          %{@key => "tabs"}
        ] do
      assert put_prefs(a, token, body).status == 422, inspect(body)
    end

    assert raw_rows(a) == []
  end

  test "P11 no token is 401; auditor and candidate may read and set their own", %{a: a} do
    assert Fixture.api_conn(
             :get,
             @path,
             "lf_tok_" <> String.duplicate("0", 64),
             a.tenant.slug,
             nil
           )
           |> Fixture.dispatch_api()
           |> Map.fetch!(:status) == 401

    for role <- ["TENANT_AUDITOR", "CANDIDATE"] do
      token = Fixture.mint_token!(a, [role])
      assert get_prefs(a, token).status == 200, role
      put = put_prefs(a, token, layout("tabs"))
      assert put.status == 200, "#{role}: #{put.resp_body}"
      assert json(get_prefs(a, token)) == %{"preferences" => %{@key => "tabs"}}
    end
  end
end
