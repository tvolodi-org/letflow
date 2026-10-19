defmodule Letflow.ScopeEnforcement.OnFlipGuardsTest do
  @moduledoc """
  REQ-519 slice 2f-b (GH #2535): `on` became settable. This file began in 2f-a as the proof that
  the door was shut (`dormant_on_test.exs`); it was renamed in 2f-b (REVIEWER step-22 F-4) and now
  pins the guards that must hold with the door open (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.1, 4.2, 4.9; SEC code-gate
  step-16 `pr_body_items.on_unsettable_statement`, now inverted):

    * `parse_mode/1` accepts exactly `"on"` beside `off` and `shadow`; `flip/4` reaches `on` only
      from `shadow` through the gate (`off -> on` is `:shadow_required` and audited as a refusal);
    * `PUT /tenant/scope-enforcement` with `mode: "on"` is a 409 (never a 200) from `off` and from
      a `shadow` tenant without evidence, also when the body carries a clock or thresholds; the
      same body with `mode: "shadow"` flips normally and those extra keys change nothing (never read);
    * the router builds the `flip/4` attrs from a LITERAL three-key map (`actor_id`, `reason`,
      `trace_id`), so a request can never supply `now` or a threshold, and no `lib/` file but
      the router calls `ScopeEnforcement.flip/4`;
    * the stage-1 flip paths are intact (the entry shapes of `off -> shadow` and `shadow -> off`,
      the audit vocabulary owned by `ScopeEnforcement`);
    * SEC C-5: a raise inside the flip transaction is a detail-free 500 with NO flag change and
      exactly ONE constant log line `scope_enforcement_flip_failed reason=<tag> exception=<module>`;
    * REVIEWER step-22 TS-1: the 409 mapping is an open union with a deliberate default, so a refusal
      tag the router does not know is a detail-free 500 with ONE constant log line (never a 200, never
      a body that echoes the tag), proven on an in-memory copy of the router whose `flip/4` call is
      replaced by a stub that answers a brand-new tag.

  `async: false`: committed writes, DDL (an audit fault trigger), VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Letflow.Audit.Entry
  alias Letflow.ScopeEnforcement
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.SyncScopeFixture

  @router Letflow.Routers.TenantScopeEnforcement
  @router_path "lib/letflow/routers/tenant_scope_enforcement.ex"
  @trace "req519-2fa-dormant-trace-0001"

  setup do
    Fixture.unpin!()
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp put(fx, body), do: put_via(@router, fx, body)

  defp put_via(router, fx, body) do
    :put
    |> Fixture.router_conn("/", fx, ["TENANT_ADMIN"], body)
    |> assign(:auth_context, %{
      user_id: fx.admin.id,
      tenant_id: fx.tenant_id,
      roles: ["TENANT_ADMIN"],
      credential: :oidc
    })
    |> assign(:trace_id, @trace)
    |> router.call(router.init([]))
  end

  defp get(fx) do
    :get
    |> Fixture.router_conn("/", fx, ["TENANT_ADMIN"], nil)
    |> assign(:auth_context, %{
      user_id: fx.admin.id,
      tenant_id: fx.tenant_id,
      roles: ["TENANT_ADMIN"],
      credential: :oidc
    })
    |> assign(:trace_id, @trace)
    |> @router.call(@router.init([]))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp mode!(fx) do
    {:ok, mode} = ScopeEnforcement.get_mode(fx.tenant_id)
    mode
  end

  defp flip_entries(fx) do
    F.entries(fx, "scope.enforcement_enabled") ++
      F.entries(fx, "scope.enforcement_disabled") ++ F.entries(fx, "scope.enforcement_refused")
  end

  # lib files with a CODE call of ScopeEnforcement.flip (comments and docs are not in the AST)
  defp flip_callers do
    for path <- Path.wildcard("lib/**/*.ex"),
        source = File.read!(path),
        source =~ "flip",
        calls_flip?(Code.string_to_quoted!(source, file: path)),
        do: path
  end

  defp calls_flip?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, acc -> {node, acc or flip_call?(node)} end)

    found?
  end

  defp flip_call?({{:., _, [{:__aliases__, _, parts}, :flip]}, _, _args}),
    do: List.last(parts) == :ScopeEnforcement

  defp flip_call?(_other), do: false

  # every `attrs = %{...}` literal of the router source, as its key list
  defp router_attrs_literals do
    {_ast, found} =
      @router_path
      |> File.read!()
      |> Code.string_to_quoted!(file: @router_path)
      |> Macro.prewalk([], fn
        {:=, _, [{:attrs, _, ctx}, {:%{}, _, pairs}]} = node, acc when is_atom(ctx) ->
          {node, [Keyword.keys(pairs) | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # --- on is settable only through the guarded flip -------------------------------------------

  describe "on is settable only through the guarded flip" do
    test "parse_mode/1 and modes/0 list on; stored_modes/0 is the same list" do
      assert ScopeEnforcement.modes() == [:off, :shadow, :on]
      assert ScopeEnforcement.stored_modes() == ScopeEnforcement.modes()
      assert ScopeEnforcement.parse_mode("off") == {:ok, :off}
      assert ScopeEnforcement.parse_mode("shadow") == {:ok, :shadow}
      assert ScopeEnforcement.parse_mode("on") == {:ok, :on}

      for value <- ["ON", "On", " on", "on ", :on, nil, 1, %{}, ["on"]] do
        assert ScopeEnforcement.parse_mode(value) == {:error, :invalid_mode}, inspect(value)
      end
    end

    test "flip(:on) from off is :shadow_required: no change, no flip entry, one refusal entry" do
      off = F.admin_tenant!("req519-d1a")
      attrs = Map.put(F.attrs(off, "req519 try on"), :now, ~U[2000-01-01 00:00:00Z])

      assert ScopeEnforcement.flip(off.tenant_id, off.schema_name, :on, attrs) ==
               {:error, :shadow_required}

      assert mode!(off) == :off
      assert F.entries(off, "scope.enforcement_enabled") == []
      assert F.entries(off, "scope.enforcement_disabled") == []
    end

    test "a non-DateTime clock in the attrs is never read: a shadow flip with each junk value succeeds" do
      for {junk, index} <- Enum.with_index(["2020-01-01", 12_345, nil, %{}, :now]) do
        fx = F.admin_tenant!("req519-d2-#{index}")
        attrs = Map.put(F.attrs(fx, nil), :now, junk)

        assert {:ok, %{mode: :shadow, previous: :off, changed: true}} =
                 ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs)

        assert mode!(fx) == :shadow
      end
    end

    test "PUT mode=on is a 409 from off and from a shadow tenant without evidence, extra body keys or not" do
      off = F.admin_tenant!("req519-d3a")
      shadow = F.shadow_tenant!("req519-d3b")

      bodies = [
        %{"mode" => "on"},
        %{"mode" => "on", "reason" => "req519 try on"},
        %{
          "mode" => "on",
          "now" => "2000-01-01T00:00:00Z",
          "min_days" => 1,
          "min_requests" => 1,
          "retention_days" => 1,
          "attrs" => %{"now" => "2000-01-01T00:00:00Z"}
        }
      ]

      for b <- bodies do
        conn = put(off, b)
        assert conn.status == 409, inspect(b)
        assert body(conn)["detail"] == "shadow_required"

        conn = put(shadow, b)
        assert conn.status == 409, inspect(b)
        assert body(conn)["detail"] == "enforcement_precondition_failed"
        assert "shadow_evidence_insufficient" in body(conn)["failed"]
      end

      assert mode!(off) == :off
      assert mode!(shadow) == :shadow

      assert F.entries(off, "scope.enforcement_enabled") == []
      assert F.entries(shadow, "scope.enforcement_disabled") == []
    end

    test "PUT mode=shadow with a clock and thresholds in the body flips normally and ignores them" do
      fx = F.admin_tenant!("req519-d4")

      conn =
        put(fx, %{
          "mode" => "shadow",
          "now" => "2000-01-01T00:00:00Z",
          "min_days" => 1,
          "min_requests" => 1
        })

      assert conn.status == 200
      assert body(conn) == %{"mode" => "shadow", "previous" => "off", "changed" => true}

      entry = F.latest_flip_entry!(fx)
      assert entry.action == "scope.enforcement_enabled"
      # the entry is stamped by the server clock, not by anything the body said
      assert abs(DateTime.diff(DateTime.utc_now(), entry.timestamp, :second)) < 300
      assert Enum.sort(Map.keys(entry.after_state)) == ["mode", "preconditions", "reason"]

      assert Letflow.ScopeEnforcement.ShadowWindow.thresholds() ==
               %{min_days: 7, min_requests: 100, retention_days: 90}
    end

    test "GET / lists off, shadow and on" do
      fx = F.admin_tenant!("req519-d5")

      assert body(get(fx)) == %{"mode" => "off", "available_modes" => ["off", "shadow", "on"]}
    end
  end

  describe "the source keeps the flip authority narrow" do
    test "the router builds the flip attrs from ONE literal map of exactly actor_id, reason, trace_id" do
      assert [keys] = router_attrs_literals()
      assert Enum.sort(keys) == [:actor_id, :reason, :trace_id]

      source = File.read!(@router_path)
      refute source =~ ~r/\bnow:/
      refute source =~ ":now"
      refute source =~ "min_days"
      refute source =~ "min_requests"
    end

    test "only the router calls ScopeEnforcement.flip/4 from lib/" do
      assert flip_callers() == [@router_path]
    end

    test "the source scan is live: it finds a seeded call and ignores comments and strings" do
      seeded = """
      defmodule Seeded do
        alias Letflow.ScopeEnforcement
        # ScopeEnforcement.flip(1, 2, 3, 4)
        @doc "ScopeEnforcement.flip(1, 2, 3, 4)"
        def go, do: ScopeEnforcement.flip(1, 2, :shadow, %{})
      end
      """

      commented = """
      defmodule Quiet do
        # ScopeEnforcement.flip(1, 2, 3, 4)
        @doc "ScopeEnforcement.flip(1, 2, 3, 4)"
        def go, do: :ok
      end
      """

      assert calls_flip?(Code.string_to_quoted!(seeded))
      refute calls_flip?(Code.string_to_quoted!(commented))
    end
  end

  # --- stage-1 behaviour after the flip_entry dispatch change ----------------------------------

  describe "the stage-1 flip entries are unchanged" do
    test "off -> shadow keeps its three-fact payload; shadow -> off carries only mode and reason" do
      fx = F.admin_tenant!("req519-d6")
      _ = F.flip!(fx, :shadow, nil)

      enabled = F.latest_flip_entry!(fx)
      assert enabled.action == "scope.enforcement_enabled"
      assert enabled.resource_type == "tenant"
      assert enabled.resource_id == fx.tenant_id
      assert enabled.before_state == %{"mode" => "off"}

      assert enabled.after_state == %{
               "mode" => "shadow",
               "reason" => nil,
               "preconditions" => %{
                 "bindings_without_row" => 0,
                 "org_consistency" => "ok",
                 "tokens_exceeding_owner" => 0
               }
             }

      _ = F.flip!(fx, :off, "req519 back to off")
      disabled = F.latest_flip_entry!(fx)
      assert disabled.action == "scope.enforcement_disabled"
      assert disabled.before_state == %{"mode" => "shadow"}
      assert disabled.after_state == %{"mode" => "off", "reason" => "req519 back to off"}
    end

    test "the audit vocabulary is owned by ScopeEnforcement and is what flip/4 writes" do
      assert ScopeEnforcement.flip_resource_type() == "tenant"

      assert ScopeEnforcement.flip_actions() ==
               ["scope.enforcement_enabled", "scope.enforcement_disabled"]

      fx = F.admin_tenant!("req519-d7")
      _ = F.flip!(fx, :shadow, nil)
      _ = F.flip!(fx, :off, "req519 vocabulary")

      entries = Entry |> Repo.all(prefix: fx.schema_name)

      flip_entries =
        Enum.filter(entries, &(&1.action in ScopeEnforcement.flip_actions()))

      assert length(flip_entries) == 2

      assert Enum.all?(
               flip_entries,
               &(&1.resource_type == ScopeEnforcement.flip_resource_type() and
                   &1.resource_id == fx.tenant_id)
             )
    end

    test "a same-mode request writes nothing and the refused-flip action is never used by it" do
      fx = F.admin_tenant!("req519-d8")
      _ = F.flip!(fx, :shadow, nil)
      before = flip_entries(fx)

      assert {:ok, %{mode: :shadow, previous: :shadow, changed: false}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, F.attrs(fx, nil))

      assert flip_entries(fx) == before
      assert F.entries(fx, "scope.enforcement_refused") == []
    end

    test "a refused off -> shadow stays UNAUDITED (AC 14: only refusals of `on` are recorded)" do
      fx = F.admin_tenant!("req519-d9")
      g = RSG.fresh_group!(fx.schema_name)

      _gap =
        RSG.raw_binding!(
          fx.schema_name,
          "PROCESS_OPERATOR",
          :platform_role,
          g.id
        )

      assert {:error, {:precondition_failed, [:bindings_without_row], _report}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, F.attrs(fx, nil))

      assert flip_entries(fx) == []
    end
  end

  # --- SEC C-5: the 500 path -------------------------------------------------------------------

  describe "C-5 a raise inside the flip transaction" do
    test "PUT answers a detail-free 500, changes no flag and logs ONE constant line" do
      fx = F.admin_tenant!("req519-c5")
      name = "req519_2fa_flip_fault"

      _ =
        SyncScopeFixture.create_audit_fault!(
          fx.schema_name,
          name,
          "NEW.action = 'scope.enforcement_enabled'"
        )

      try do
        {conn, log} = with_log(fn -> put(fx, %{"mode" => "shadow"}) end)

        assert conn.status == 500
        refute conn.resp_body =~ "injected"
        refute conn.resp_body =~ "Postgrex"
        refute conn.resp_body =~ fx.schema_name
        refute F.uuid_in?(conn.resp_body)

        lines = F.lines_with(log, "scope_enforcement_flip_failed")
        assert length(lines) == 1

        assert hd(lines) =~
                 "scope_enforcement_flip_failed reason=transaction_failed exception=Postgrex.Error"

        # reason tag and exception module only: no id, no schema, no message, no query text
        refute F.uuid_in?(hd(lines))
        refute hd(lines) =~ fx.schema_name
        refute hd(lines) =~ "injected"
      after
        SyncScopeFixture.drop_audit_fault!(fx.schema_name, name)
      end

      assert mode!(fx) == :off
      assert flip_entries(fx) == []
    end

    test "an ordinary 409 refusal does not log the failure line" do
      fx = F.admin_tenant!("req519-c5b")
      g = RSG.fresh_group!(fx.schema_name)

      _gap =
        RSG.raw_binding!(
          fx.schema_name,
          "PROCESS_OPERATOR",
          :platform_role,
          g.id
        )

      {conn, log} = with_log(fn -> put(fx, %{"mode" => "shadow"}) end)

      assert conn.status == 409
      assert F.lines_with(log, "scope_enforcement_flip_failed") == []
    end

    test "a successful flip does not log the failure line" do
      fx = F.admin_tenant!("req519-c5c")

      {conn, log} = with_log(fn -> put(fx, %{"mode" => "shadow"}) end)

      assert conn.status == 200
      assert F.lines_with(log, "scope_enforcement_flip_failed") == []
    end
  end

  # --- REVIEWER TS-1: an unknown refusal tag -----------------------------------------------------

  defmodule UnknownRefusalStub do
    @moduledoc false
    # Stands in for `ScopeEnforcement` in the in-memory router copy of the TS-1 test.
    def flip(_tenant_id, _prefix, _target, _attrs),
      do: {:error, {:brand_new_refusal_tag, "secret-detail-ts1"}}
  end

  describe "TS-1 the refusal mapping has a detail-free default" do
    @flip_call "ScopeEnforcement.flip(tenant_id(conn), prefix(conn), target, attrs)"
    @router_head "defmodule Letflow.Routers.TenantScopeEnforcement do"

    test "a refusal tag the router does not know is a detail-free 500 with ONE constant log line" do
      source = File.read!(@router_path)

      # the anchors must occur exactly once, or the copy would not be the router under test
      assert length(String.split(source, @flip_call)) == 2
      assert length(String.split(source, @router_head)) == 2

      patched =
        source
        |> String.replace(@router_head, "defmodule Letflow.Routers.TenantScopeEnforcementTs1 do")
        |> String.replace(
          @flip_call,
          "#{inspect(UnknownRefusalStub)}.flip(tenant_id(conn), prefix(conn), target, attrs)"
        )

      [{copy, _binary}] = Code.compile_string(patched, "tenant_scope_enforcement_ts1.ex")

      on_exit(fn ->
        :code.purge(copy)
        :code.delete(copy)
      end)

      fx = F.admin_tenant!("req519-ts1")

      {conn, log} = with_log(fn -> put_via(copy, fx, %{"mode" => "shadow"}) end)

      assert conn.status == 500
      refute conn.resp_body =~ "brand_new"
      refute conn.resp_body =~ "secret-detail-ts1"
      refute conn.resp_body =~ "refus"
      refute F.uuid_in?(conn.resp_body)

      lines =
        log
        |> F.lines_with("scope_enforcement_flip_failed")
        |> Enum.map(fn line ->
          [constant] = Regex.run(~r/scope_enforcement_flip_failed.*$/, line)
          constant
        end)

      assert lines == ["scope_enforcement_flip_failed reason=unknown exception=none"]

      refute log =~ "secret-detail-ts1"
      refute log =~ "brand_new"
      assert mode!(fx) == :off
    end
  end
end
