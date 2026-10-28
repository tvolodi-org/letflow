defmodule Letflow.Routers.Entities.RecordWritesHookRoutesTest do
  @moduledoc """
  REQ-607 / GH #3413 part A, criterion C7, route clauses: through the full router a hooked write
  whose merged document (payload plus hook output) is out of the caller's scope answers the bytes
  the record routes already send for `scope_refused` (the by-id 404 of decision 0051 D7), and a
  managed type that has a binding row answers the constant 403 `entity_type_managed` with the
  runner never called. `async: false`: provisioned OIDC tenant, application env.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EntityTypeHooks.Binding
  alias Letflow.Support.ScopeSetFixture
  alias Letflow.Support.ScopeWritesFixture, as: W
  alias Letflow.Support.ScriptTaskFixture, as: S

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> %{calls: 0, reply: nil} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def reply(value), do: Agent.update(__MODULE__, &%{&1 | reply: value})
    def calls, do: Agent.get(__MODULE__, & &1.calls)

    def run(_source, _input, _opts) do
      Agent.update(__MODULE__, &%{&1 | calls: &1.calls + 1})
      Agent.get(__MODULE__, & &1.reply)
    end
  end

  setup do
    fx = "e3rt" |> W.provision!() |> S.with_hmac!()

    _ = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    previous = Application.fetch_env(:letflow, :entity_write_script_runner)
    Application.put_env(:letflow, :entity_write_script_runner, StubRunner)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :entity_write_script_runner, old)
        :error -> Application.delete_env(:letflow, :entity_write_script_runner)
      end
    end)

    {:ok, fx: fx}
  end

  defp bind!(fx, type, derived) do
    manifest = %{
      "input_schema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}},
      "output_schema" => %{
        "type" => "object",
        "properties" => Map.new(derived, &{&1, %{"type" => "string"}}),
        "additionalProperties" => false
      },
      "derived_fields" => derived,
      "fail_codes" => [],
      "limits" => %{"timeout_ms" => 5_000}
    }

    rule =
      S.published!(fx.schema_name, "d_#{type}", "return {}", manifest, hook_kind: "entity_write")

    Repo.insert!(
      %Binding{
        tenant_id: fx.tenant_id,
        entity_type: type,
        script_key: rule.key,
        script_version: rule.version,
        script_sha256: rule.sha256,
        bound_by: Ecto.UUID.generate()
      },
      prefix: fx.schema_name
    )

    rule
  end

  defp output(map),
    do:
      {:ok, %{output: map, stats: %{duration_us: 1, instructions_used: 1, heap_words_at_end: 1}}}

  test "C7-route-scope the merged out-of-scope value answers the by-id 404 bytes", %{fx: fx} do
    body = %{"field_values" => %{"name" => "c", "scope_node" => "sf-a"}}
    children = ScopeSetFixture.seed_children!(fx, fx.items)

    # the canonical 404 of a scoped caller: PUT of a nonexistent id (before any binding exists)
    canonical =
      fx
      |> W.request(:put, W.records_path("scoped_child", Ecto.UUID.generate()), body)
      |> W.norm()

    assert {404, _headers, _body} = canonical

    rule = bind!(fx, "scoped_child", ["item_id"])
    out_of_set = fx.items.b.record_id
    StubRunner.reply(output(%{"item_id" => out_of_set}))
    before = W.counts(fx)

    # the payload scope is in the set; the hook writes a reference to an item outside it
    conn = W.request(fx, :post, W.records_path("scoped_child", nil), body)

    assert W.norm(conn) == canonical
    assert StubRunner.calls() == 1
    refute conn.resp_body =~ rule.key
    refute conn.resp_body =~ out_of_set
    assert W.counts(fx) == before

    # the same on update of an in-scope record
    conn = W.request(fx, :put, W.records_path("scoped_child", children.ca.record_id), body)

    assert W.norm(conn) == canonical
    assert StubRunner.calls() == 2
    assert W.counts(fx) == before
  end

  test "C7-route-managed a managed type with a binding answers 403 and the runner is not called",
       %{fx: fx} do
    path = W.records_path("scoped_managed_item", nil)
    body = %{"field_values" => %{"name" => "x", "scope_node" => "sf-a"}}

    unbound = W.request(fx, :post, path, body)
    assert unbound.status == 403
    assert Jason.decode!(unbound.resp_body)["type"] =~ "entity-type-managed"
    expected = W.norm(unbound)

    bind!(fx, "scoped_managed_item", ["name"])
    StubRunner.reply(output(%{"name" => "from-hook"}))
    before = W.counts(fx)

    conn = W.request(fx, :post, path, body)

    assert W.norm(conn) == expected
    assert StubRunner.calls() == 0
    assert W.counts(fx) == before
  end
end
