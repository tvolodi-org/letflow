defmodule Letflow.Engine.PinResolverScriptTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC4 (decision 0053 D1, D3; C7; design
  `lib/letflow/design/gh2534-7c-script-handler.md` 4.3): the `:script` pin -- frozen
  `(key, version, sha256, resolved_id)` in INSTANCE_STARTED, untouched by a later publish; a
  retired version cannot be newly pinned; a revoked pinned version fails closed; never
  rebindable, never inherited.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine
  alias Letflow.Engine.PinRebind
  alias Letflow.Engine.PinResolver
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    %{t: F.tenant!("gh2534-7c-pin")}
  end

  defp started_pins(t, instance_id) do
    [started] = F.payloads(t.schema_name, instance_id, "INSTANCE_STARTED")
    started["pinned_versions"]
  end

  test "pin frozen across publish", %{t: t} do
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 1})
    v1 = b.rule

    assert %{
             "kind" => "script",
             "ref" => key,
             "version" => "1",
             "resolved_id" => resolved_id,
             "sha256" => sha,
             "source" => "resolved"
           } = Enum.find(started_pins(t, b.instance_id), &(&1["kind"] == "script"))

    assert {key, resolved_id, sha} == {v1.key, v1.id, v1.sha256}
    assert F.row!(t.schema_name, b.instance_id).script_sha256 == v1.sha256

    # version 2 is published and a new definition binds it ...
    v2 = F.published!(t.schema_name, v1.key, "return { total = 0 }", F.closed_manifest())
    assert v2.version == 2 and v2.sha256 != v1.sha256
    d2 = F.definition!(t.schema_name, F.script_graph(v1.key, 2), [])
    i2 = F.start!(t.schema_name, d2, %{"amount" => 1}, Ecto.UUID.generate())
    assert F.row!(t.schema_name, i2).script_version == 2

    # ... and the in-flight instance still runs version 1
    row1 = F.row!(t.schema_name, b.instance_id)
    F.make_due!(t.schema_name, row1)
    {:ok, claimed} = Letflow.Engine.ScriptTaskDispatcher.claim_next(t.schema_name)
    claimed = if claimed.id == row1.id, do: claimed, else: flunk("instance 1's row was not first")

    assert {:ok, :applied} =
             Letflow.Engine.ScriptTaskDispatcher.run_claimed(claimed, t.schema_name)

    [record] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")
    assert {record["script_version"], record["script_sha256"]} == {1, v1.sha256}
    assert F.projection(t.schema_name, b.instance_id).variables["total"] == 2
  end

  test "retired not pinnable", %{t: t} do
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 1})
    F.retire_raw!(t.schema_name, b.rule)
    key = b.rule.key

    assert {:error, {:unresolved_script_ref, ^key}} =
             Engine.create(
               %{
                 definition_id: b.definition.id,
                 initial_variables: %{"amount" => 1},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: "retired-#{key}"
               },
               prefix: t.schema_name
             )

    # an instance pinned BEFORE the retire still runs it (D1: published and retired run)
    assert {_row, {:ok, :applied}} = F.run_next!(t.schema_name)
  end

  test "revoked fails closed", %{t: t} do
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 1})
    F.revoke_raw!(t.schema_name, b.rule)

    {row, {:ok, :failed}} = F.run_next!(t.schema_name)
    done = F.reload(t.schema_name, row)
    assert {done.outcome, done.outcome_detail} == {"script_rejected", "script_revoked"}
  end

  test "rebind refuses script" do
    for kind <- ["script", :script] do
      attrs = %{
        entries: [%{kind: kind, ref: "pricing", version: "2"}],
        reason: "7c-1",
        actor_id: Ecto.UUID.generate(),
        idempotency_key: "rebind-#{System.unique_integer([:positive])}"
      }

      assert {:error, {:malformed_entry, 0, {:invalid_kind, ^kind}}} =
               PinRebind.rebind_pins(Ecto.UUID.generate(), attrs, prefix: "tenant_unused")
    end
  end

  test "a PINS_REBOUND script entry found anyway is ignored; sha256 is carried (pure)" do
    started = [
      %{
        "kind" => "script",
        "ref" => "k",
        "version" => "1",
        "resolved_id" => "r",
        "sha256" => "s",
        "source" => "resolved"
      }
    ]

    rebound = [
      %{
        event_id: Ecto.UUID.generate(),
        payload: %{"entries" => [%{"kind" => "script", "ref" => "k", "new_version" => "9"}]}
      }
    ]

    assert [%{kind: :script, version: "1", resolved_id: "r", sha256: "s"}] =
             PinResolver.merge_effective_pins(started, rebound, Ecto.UUID.generate())
  end

  test "child no inherit (pure)" do
    script_pin = fn version ->
      %{
        kind: :script,
        ref: "k",
        resolved_id: "r#{version}",
        version: version,
        source: :resolved,
        sha256: "s#{version}"
      }
    end

    vs = %{kind: :variable_schema, ref: "p", resolved_id: nil, version: "v", source: :resolved}
    parent = [Map.put(script_pin.("1"), :source_event_id, Ecto.UUID.generate())]

    # a child without the script binding inherits no script pin
    assert {:ok, [^vs], []} = PinResolver.apply_inheritance([vs], parent)

    # a child binding another version keeps its own (no replacement, no conflict, sha kept)
    own = script_pin.("2")
    assert {:ok, pins, []} = PinResolver.apply_inheritance([own, vs], parent)
    assert own in pins
  end
end
