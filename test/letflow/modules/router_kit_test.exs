defmodule Letflow.Modules.RouterKitTest do
  # Canary for core extraction S7a: the plumbing moved out of Org.Router.
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Letflow.Modules.RouterKit

  @uuid "6f1c2d1e-0a5b-4c6e-9d3a-1b2c3d4e5f60"

  defp conn(body, user_id \\ @uuid) do
    %{
      Plug.Test.conn(:post, "/x", %{})
      | body_params: body
    }
    |> assign(:scoped_opts, prefix: "tenant_abc")
    |> assign(:auth_context, %{user_id: user_id})
  end

  defp render(conn, result, status), do: send_resp(conn, status, inspect(result))

  describe "check_keys/2" do
    test "exact keys pass, extra and missing are named" do
      assert :ok = RouterKit.check_keys(%{"a" => 1}, ["a"])
      assert :ok = RouterKit.check_keys(%{}, [])
      assert {:error, {:field_not_allowed, "b"}} = RouterKit.check_keys(%{"b" => 1}, [])
      assert {:error, {:field_invalid, "a"}} = RouterKit.check_keys(%{}, ["a"])
    end
  end

  describe "pop_key/1" do
    test "splits the key off the body" do
      assert {:ok, "k1", %{"a" => 1}} = RouterKit.pop_key(%{"idempotency_key" => "k1", "a" => 1})
    end

    test "missing, blank, non-text, list body and non-map are field_invalid" do
      bad = {:error, {:field_invalid, "idempotency_key"}}
      assert bad == RouterKit.pop_key(%{})
      assert bad == RouterKit.pop_key(%{"idempotency_key" => "  "})
      assert bad == RouterKit.pop_key(%{"idempotency_key" => 5})
      assert bad == RouterKit.pop_key(%{"_json" => []})
      assert bad == RouterKit.pop_key("x")
    end
  end

  describe "elem_tag/1" do
    test "tuple tag, else :other" do
      assert :a == RouterKit.elem_tag({:a, 1})
      assert :other == RouterKit.elem_tag({})
      assert :other == RouterKit.elem_tag(:x)
    end
  end

  describe "with_request/3" do
    test "passes prefix, attrs and opts to the action" do
      conn = conn(%{"idempotency_key" => "k", "f" => 1})

      result =
        RouterKit.with_request(conn, &render/3, fn prefix, attrs, opts, c ->
          send_resp(c, 200, inspect({prefix, attrs, opts}))
        end)

      assert result.resp_body ==
               inspect({"tenant_abc", %{"f" => 1}, %{actor_id: @uuid, idempotency_key: "k"}})
    end

    test "a body refusal goes through the module's render function" do
      result = RouterKit.with_request(conn(%{}), &render/3, fn _, _, _, c -> c end)
      assert result.status == 200
      assert result.resp_body == inspect({:error, {:field_invalid, "idempotency_key"}})
    end

    test "a user id that is not a uuid is 403" do
      result = RouterKit.with_request(conn(%{}, "nope"), &render/3, fn _, _, _, c -> c end)
      assert result.status == 403
    end
  end

  describe "S7b: locations router uses the kit" do
    test "no private copy of the plumbing is left in the router" do
      src = File.read!("lib/letflow/modules/locations/router.ex")
      assert src =~ "RouterKit.with_request(conn, &render/3"
      assert src =~ "RouterKit.check_keys("
      refute src =~ "defp with_request"
      refute src =~ "defp pop_key"
      refute src =~ "defp check_keys"
      refute src =~ "defp elem_tag"
    end
  end
end
