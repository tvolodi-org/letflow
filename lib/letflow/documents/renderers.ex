defmodule Letflow.Documents.Renderers do
  @moduledoc """
  The registry of document renderers (REQ-623, decision 0075 R6): `template_ref` to a module that
  implements `Letflow.Documents.Renderer`.

  The map is compiled in. It is empty in this slice: no module registers a renderer yet, so
  `Letflow.Documents.attach_artefact/2` outside tests answers `{:error, :render_failed}` (log code
  `no_renderer`) until a module adds `{"ref", Module}` to `@renderers`.

  Tests may replace the map through `Application.put_env(:letflow, :document_renderers, %{...})`.
  That override is read only when the compile-time flag `:document_renderers_override_enabled` is
  true; `config/test.exs` sets it and no other config file does, so no runtime setting or data can
  choose a module in dev or prod (INV-3).
  """

  # A list of {template_ref, module}; `Map.new/1` keeps the registry type open while the list is empty.
  @renderers []
  @override_enabled Application.compile_env(:letflow, :document_renderers_override_enabled, false)

  @doc "The renderer module for `template_ref`, or `:error`."
  @spec fetch(term()) :: {:ok, module()} | :error
  def fetch(template_ref) when is_binary(template_ref) do
    Map.fetch(registry(), template_ref)
  end

  def fetch(_other), do: :error

  if @override_enabled do
    defp registry, do: Application.get_env(:letflow, :document_renderers, Map.new(@renderers))
  else
    defp registry, do: Map.new(@renderers)
  end

  @doc false
  def override_enabled?, do: @override_enabled
end
