defmodule Letflow.Plugs.ErrorCapture do
  @moduledoc """
  T-1951 (maintenance slice 3): registers one `before_send` callback that records every sent 5xx answer
  (503 excepted: admission shedding, `/ready` and the export's "unavailable" are designed refusals) through
  `Letflow.ErrorCapture.record_response/1`. A crash already recorded by `Letflow.Plugs.ApiPipeline.handle_errors/2`
  carries `conn.private[:letflow_error_captured]` and is not counted twice. The conn is returned unchanged;
  recording never raises (ETS only).
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, fn conn ->
      if conn.status in 500..599 and conn.status != 503 and
           conn.private[:letflow_error_captured] != true do
        Letflow.ErrorCapture.record_response(conn)
      end

      conn
    end)
  end
end
