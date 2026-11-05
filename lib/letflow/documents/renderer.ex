defmodule Letflow.Documents.Renderer do
  @moduledoc """
  The renderer behaviour of versioned documents (REQ-623, decision 0075 R2, R6).

  `render/3` gets the `template_ref` of the document type, a projection and a meta map, and
  returns `{:ok, pdf_bytes, template_version}` (a non-empty string) or `{:error, term}`.

  The projection is the version's content restricted to the names the type declares
  (`declared_fields`), nothing else: a renderer never sees the stored row, the content hash or an
  undeclared field. A renderer that fails closed on a missing key returns `{:error, _}`.

  Whatever a renderer returns as an error, and whatever it raises, is never put into a log line,
  an audit entry or a return value of `Letflow.Documents.attach_artefact/2`: the caller sees only
  `{:error, :render_failed}` and the log carries a reason code from a closed set.
  """

  @callback render(template_ref :: String.t(), projection :: map(), meta :: map()) ::
              {:ok, binary(), template_version :: String.t()} | {:error, term()}
end
