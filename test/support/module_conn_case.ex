defmodule Letflow.ModuleConnCase do
  @moduledoc """
  CORE slice S9 (core-extraction-design section 6, row 27 of the inventory): test-only helpers
  that the router tests under `test/letflow/modules/**` each defined privately.

  Several shapes exist in the old copies; each keeps its own name, so no assertion changes:

    * `json/1`       -- decode the response body of a conn (21 identical copies).
    * `strip/1`      -- drop `"trace_id"` from an already decoded body map.
    * `strip_conn/1` -- decode a conn body, then drop `"trace_id"` (the `conn |> json |> Map.delete`
      copies).
    * `call/6`       -- one JSON request through the full `Letflow.Router` pipeline with a bearer
      token, the tenant slug and a caller-chosen trace id (the third shape family of `call/3-4`).

  This first slice moves the `codes` module directory. `async` stays the test file's own choice.
  """

  import Plug.Conn
  import Plug.Test

  @doc "Decode the JSON response body of `conn`."
  @spec json(Plug.Conn.t()) :: term()
  def json(conn), do: Jason.decode!(conn.resp_body)

  @doc "Drop the `\"trace_id\"` key from a decoded body map."
  @spec strip(map()) :: map()
  def strip(body), do: Map.delete(body, "trace_id")

  @doc "Decode `conn`'s JSON body and drop its `\"trace_id\"` key."
  @spec strip_conn(Plug.Conn.t()) :: map()
  def strip_conn(conn), do: conn |> json() |> strip()

  @doc """
  Send `body` as JSON with `method` to `base <> path` through `Letflow.Router`, authenticated
  with `user.plaintext` for tenant `user.slug`, carrying `trace_id` as `x-trace-id`.
  """
  @spec call(atom(), String.t(), String.t(), map(), term(), String.t()) :: Plug.Conn.t()
  def call(method, base, path, user, body, trace_id) do
    conn(method, base <> path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> put_req_header("x-trace-id", trace_id)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end
end
