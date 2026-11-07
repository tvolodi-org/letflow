defmodule Letflow.Routers.MeUiLayoutTest do
  @moduledoc """
  T-1431: the preference key `ui.layout` through the real `PUT /api/v1/me/preferences` (D-098).
  The cases mirror `core/tools/test_prefs.js` of the design repo (`LFPrefs.sanitize`).
  `async: false`: tenant provisioning and the platform pin are VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.UserPreferences

  @path "/api/v1/me/preferences"
  @key "ui.layout"
  @empty %{"v" => 1, "shell" => %{"sidenav" => %{}}, "screens" => %{}}

  setup do
    Fixture.unpin!()
    %{a: a, b: b} = Fixture.two_tenants!()
    {:ok, a: a, b: b, token: Fixture.mint_token!(a, ["TASK_WORKER"])}
  end

  defp call(method, fixture, token, body) do
    method |> Fixture.api_conn(@path, token, fixture.tenant.slug, body) |> Fixture.dispatch_api()
  end

  defp put_raw(f, token, value), do: call(:put, f, token, %{"preferences" => %{@key => value}})
  defp put_doc(f, token, doc), do: put_raw(f, token, Jason.encode!(doc))

  # 200 expected; returns the decoded stored document
  defp saved(f, token, doc) do
    conn = put_doc(f, token, doc)
    assert conn.status == 200, conn.resp_body
    conn.resp_body |> Jason.decode!() |> get_in(["preferences", @key]) |> Jason.decode!()
  end

  defp stored_string(f, token) do
    call(:get, f, token, nil).resp_body |> Jason.decode!() |> get_in(["preferences", @key])
  end

  defp raw_rows(f) do
    %{rows: rows} =
      Repo.query!(~s|SELECT key, value FROM "#{f.schema_name}".user_preferences WHERE key = $1|, [
        @key
      ])

    rows
  end

  defp audit(f) do
    from(e in Entry, where: like(e.action, "user_preferences.%"), order_by: e.timestamp)
    |> Repo.all(prefix: f.schema_name)
  end

  test "L1 null and string documents give the empty contract", %{a: a, token: t} do
    assert saved(a, t, nil) == @empty
    assert saved(a, t, "x") == @empty
  end

  test "L2 unknown top-level keys are dropped", %{a: a, token: t} do
    doc = %{
      "v" => 1,
      "evil" => 1,
      "shell" => %{"sidenav" => %{"collapsed" => true, "w" => 250, "x" => 1}, "other" => 1},
      "screens" => %{}
    }

    assert saved(a, t, doc) |> Map.keys() |> Enum.sort() == ["screens", "shell", "v"]
  end

  test "L3 the shell whitelist", %{a: a, token: t} do
    doc = %{"shell" => %{"sidenav" => %{"collapsed" => true, "w" => 250, "x" => 1}}}
    assert saved(a, t, doc)["shell"] == %{"sidenav" => %{"collapsed" => true, "w" => 250}}
  end

  test "L4 the sidenav width is clamped", %{a: a, token: t} do
    assert saved(a, t, %{"shell" => %{"sidenav" => %{"w" => 9999}}})["shell"]["sidenav"]["w"] ==
             420

    assert saved(a, t, %{"shell" => %{"sidenav" => %{"w" => 10}}})["shell"]["sidenav"]["w"] ==
             160
  end

  test "L5 collapsed must be a boolean", %{a: a, token: t} do
    assert saved(a, t, %{"shell" => %{"sidenav" => %{"collapsed" => "yes"}}})["shell"]["sidenav"] ==
             %{}
  end

  test "L6 screens: id whitelist, rounding, indexes, column clamp, junk dropped", %{
    a: a,
    token: t
  } do
    doc = %{
      "screens" => %{
        "stock.journal" => %{
          "panes" => %{"details" => [38.26, nil]},
          "collapsed" => %{"row" => [0, 99, "a"]},
          "cols" => %{
            "ops" => %{"date" => 15.04, "doc" => "x", "Bad Id" => 5, "item" => 500}
          },
          "junk" => 1
        },
        "Bad Screen!" => %{"panes" => %{}},
        "" => %{}
      }
    }

    s = saved(a, t, doc)["screens"]
    assert Map.keys(s) == ["stock.journal"]
    assert s["stock.journal"]["panes"] == %{"details" => [38.3, nil]}
    assert s["stock.journal"]["collapsed"] == %{"row" => [0]}
    assert s["stock.journal"]["cols"] == %{"ops" => %{"date" => 15, "item" => 80}}
    refute Map.has_key?(s["stock.journal"], "junk")
  end

  test "L7 pane percent min and max", %{a: a, token: t} do
    one = fn n -> %{"screens" => %{"a" => %{"panes" => %{"x" => [n]}}}} end
    assert saved(a, t, one.(1))["screens"] == %{"a" => %{"panes" => %{"x" => [5]}}}
    assert saved(a, t, one.(99))["screens"]["a"]["panes"]["x"] == [85]
  end

  test "L8 at most 40 screens", %{a: a, token: t} do
    screens = Map.new(0..59, &{"s#{&1}", %{"panes" => %{"x" => [20]}}})
    assert map_size(saved(a, t, %{"screens" => screens})["screens"]) == 40
  end

  test "L9 at most 40 columns per table", %{a: a, token: t} do
    cols = Map.new(0..79, &{"c#{&1}", 10})
    doc = %{"screens" => %{"a" => %{"cols" => %{"t" => cols}}}}
    assert map_size(saved(a, t, doc)["screens"]["a"]["cols"]["t"]) == 40
  end

  defp fat do
    screens =
      Map.new(0..39, fn i ->
        cols =
          Map.new(0..23, fn tb ->
            {"table-#{tb}", Map.new(0..11, &{"column-#{&1}", 12.5})}
          end)

        {"screen-#{i}", %{"cols" => cols}}
      end)

    %{"screens" => screens}
  end

  test "L10 8 KB total: the fat document is refused raw, and sanitizes to at most 8192 bytes", %{
    a: a,
    token: t
  } do
    raw = Jason.encode!(fat())
    assert byte_size(raw) > 8192
    conn = put_raw(a, t, raw)
    assert conn.status == 422
    assert conn.resp_body =~ "preferences too large"
    assert raw_rows(a) == []

    out = UserPreferences.sanitize_layout(fat())
    assert byte_size(Jason.encode!(out)) <= 8192
    assert out["screens"] == %{}

    # raw under the cap, sanitized form stays under it too
    small = %{"screens" => Map.new(0..39, &{"s#{&1}", %{"cols" => %{"t" => %{"c" => 12.5}}}})}
    assert byte_size(Jason.encode!(small)) <= 8192
    assert byte_size(Jason.encode!(saved(a, t, small))) <= 8192
  end

  test "L11 round trip; a repeated identical put adds no audit entry", %{a: a, token: t} do
    doc = %{
      "shell" => %{"sidenav" => %{"w" => 256}},
      "screens" => %{"a" => %{"cols" => %{"t" => %{"c" => 29}}}}
    }

    saved(a, t, doc)
    first = stored_string(a, t)
    assert Jason.decode!(first)["screens"]["a"]["cols"]["t"]["c"] == 29
    saved(a, t, doc)
    assert stored_string(a, t) == first
    assert [%{action: "user_preferences.set"}] = audit(a)
  end

  test "B2 linesMode round trips through the route; garbage is dropped", %{a: a, token: t} do
    doc = %{"screens" => %{"s" => %{"linesMode" => "form"}, "u" => %{"linesMode" => "wide"}}}
    out = saved(a, t, doc)
    assert out["screens"] == %{"s" => %{"linesMode" => "form"}}
    assert Jason.decode!(stored_string(a, t))["screens"]["s"]["linesMode"] == "form"
  end

  test "L12 a non-string value is refused 422 and nothing is written", %{a: a, token: t} do
    conn = call(:put, a, t, %{"preferences" => %{@key => %{"v" => 1}}})
    assert conn.status == 422
    assert conn.resp_body =~ "invalid value for preference key: ui.layout"
    assert raw_rows(a) == []
  end

  test "L13 oversize: 8193 bytes refused, exactly 8192 accepted", %{a: a, token: t} do
    base = ~s|{"v":1,"pad":"|
    fill = fn n -> base <> String.duplicate("x", n - byte_size(base) - 2) <> ~s|"}| end
    assert byte_size(fill.(8192)) == 8192
    assert put_raw(a, t, fill.(8192)).status == 200
    conn = put_raw(a, t, fill.(8193))
    assert conn.status == 422
    assert conn.resp_body =~ "preferences too large"
  end

  test "L14 invalid JSON text is a 422, never a 500", %{a: a, token: t} do
    for text <- ["{not json", "1e999", "", "[1,"] do
      conn = put_raw(a, t, text)
      assert conn.status == 422, "#{text}: #{conn.resp_body}"
    end

    assert raw_rows(a) == []
  end

  test "L15 null resets the key and audits a reset", %{a: a, token: t} do
    saved(a, t, %{"shell" => %{"sidenav" => %{"w" => 200}}})
    assert call(:put, a, t, %{"preferences" => %{@key => nil}}).status == 200
    assert raw_rows(a) == []
    assert Enum.map(audit(a), & &1.action) == ["user_preferences.set", "user_preferences.reset"]
  end

  test "L16 another user and another tenant never see it", %{a: a, b: b, token: t} do
    saved(a, t, %{"shell" => %{"sidenav" => %{"w" => 200}}})
    other = Fixture.mint_token!(a, ["TASK_WORKER"])
    foreign = Fixture.mint_token!(b, ["TASK_WORKER"])
    assert stored_string(a, other) == nil
    assert stored_string(b, foreign) == nil
    assert raw_rows(b) == []
    assert [_] = raw_rows(a)
  end

  test "L17 stricter than JS: no coercion, regex anchors, huge numbers", %{a: a, token: t} do
    doc = %{
      "shell" => %{"sidenav" => %{"w" => "250"}},
      "screens" => %{
        "a\n" => %{"panes" => %{"x" => [20]}},
        "ok" => %{"cols" => %{"t" => %{"a" => true, "b" => "9", "c" => nil, "d" => 1.0e308}}}
      }
    }

    out = saved(a, t, doc)
    assert out["shell"]["sidenav"] == %{}
    assert out["screens"] == %{"ok" => %{"cols" => %{"t" => %{"d" => 80}}}}

    big = String.duplicate("9", 400)
    raw = ~s|{"shell":{"sidenav":{"w":#{big}}}}|
    conn = put_raw(a, t, raw)
    assert conn.status == 200, conn.resp_body
    assert stored_string(a, t) |> Jason.decode!() |> get_in(["shell", "sidenav", "w"]) == 420
  end

  test "L18 the stored row and the audit state carry the sanitized string", %{a: a, token: t} do
    saved(a, t, %{"evil" => 1, "shell" => %{"sidenav" => %{"w" => 200}}})
    s = stored_string(a, t)
    assert [[@key, %{"v" => ^s}]] = raw_rows(a)
    refute s =~ "evil"
    assert [%{after_state: %{"value" => ^s}}] = audit(a)
  end
end
