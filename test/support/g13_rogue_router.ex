defmodule Letflow.Support.G13RogueRouter do
  @moduledoc """
  The SEEDED FAILING CASE of the G-13 security probe: a router shaped exactly
  like `Letflow.Plugs.ApiPipeline` BEFORE T-2658.

  It has the same parser list and the same 2 MB cap, but its
  `handle_errors/2` returns the connection unchanged -- the shape the pipeline
  had when a malformed body escaped as an unhandled error and the adapter
  answered a bare 500 for every API route.

  The probe drives this router through the SAME aggregate entry point
  (`Letflow.Support.G13Matrix.run/3`) and the SAME verdict
  (`Letflow.Support.G13Matrix.violations/1`) as the real tree, so a verdict
  that stopped working fails here instead of passing quietly. This module is
  never mounted: it exists to be probed.
  """

  use Plug.Router
  use Plug.ErrorHandler

  plug(Plug.Parsers,
    parsers: [
      :json,
      {:multipart, length: 26_214_400},
      Letflow.Plugs.CsvBodyParser,
      Letflow.Plugs.XlsxBodyParser,
      {Letflow.Plugs.LogoBodyParser, length: 524_289}
    ],
    json_decoder: Jason,
    length: 2_097_152
  )

  plug(:match)
  plug(:dispatch)

  match _ do
    Letflow.Api.Response.send_json(conn, 200, %{ok: true})
  end

  # The pre-T-2658 shape: the connection is returned unchanged, so the refusal
  # never becomes an answer and the error escapes the pipeline.
  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack}), do: conn
end
