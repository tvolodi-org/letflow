defmodule Letflow.Entities.EntityPortImpl do
  @moduledoc """
  GH 2587 / REQ-499 PR A3 (decision 0054 open point 8): the ONE implementation of
  `Letflow.Engine.EntityPort`, injected through `config :letflow, :entity_port`.

  A delegating adapter: the read callback `prefetch/3` goes to `Letflow.Entities.ScriptReads`
  and the write callbacks (`prepare/2`, `validate_lines/2`, `multi/3`, `interpret_failure/2`) go to
  `Letflow.Entities.StepWrites`, so each keeps a single responsibility while the engine still
  sees exactly one behaviour, one injected module and one config key.
  """

  @behaviour Letflow.Engine.EntityPort

  alias Letflow.Entities.ScriptReads
  alias Letflow.Entities.StepWrites

  @impl Letflow.Engine.EntityPort
  defdelegate prefetch(prefix, reads, input_vars), to: ScriptReads

  @impl Letflow.Engine.EntityPort
  defdelegate prepare(lines, ctx), to: StepWrites

  @impl Letflow.Engine.EntityPort
  defdelegate validate_lines(lines, ctx), to: StepWrites

  @impl Letflow.Engine.EntityPort
  defdelegate multi(multi, lines, ctx), to: StepWrites

  @impl Letflow.Engine.EntityPort
  defdelegate interpret_failure(step, reason), to: StepWrites
end
