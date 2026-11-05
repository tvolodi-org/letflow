defmodule Letflow.Documents.TestRenderer do
  @moduledoc """
  A `Letflow.Documents.Renderer` for the REQ-623 tests. `install!/1` registers it for the template
  ref `"tpl.test"` (through the test-only registry override) and sets the function it runs; the
  default returns fixed PDF-looking bytes and a template version. Messages go to the test process
  via the function (it runs in the caller's process), never assertions: a raise inside a renderer
  is rescued as `:render_failed`.
  """

  @behaviour Letflow.Documents.Renderer

  @ref "tpl.test"

  def ref, do: @ref

  @impl true
  def render(template_ref, projection, meta) do
    fun = Application.get_env(:letflow, :doc_test_renderer_fun, &default/3)
    fun.(template_ref, projection, meta)
  end

  def default(_ref, _projection, _meta), do: {:ok, "%PDF-1.4 test", "tv1"}

  @doc "Registers the renderer for `\"tpl.test\"` for the calling test (undone on exit)."
  def install!(fun \\ &default/3) do
    Application.put_env(:letflow, :document_renderers, %{@ref => __MODULE__})
    Application.put_env(:letflow, :doc_test_renderer_fun, fun)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:letflow, :document_renderers)
      Application.delete_env(:letflow, :doc_test_renderer_fun)
    end)

    :ok
  end

  def set_fun(fun), do: Application.put_env(:letflow, :doc_test_renderer_fun, fun)
end
