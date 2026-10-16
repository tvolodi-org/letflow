defmodule Mix.Tasks.Letflow.RemediateIdempotencySquat do
  @shortdoc "Removes ONE flagged pre-#2550 idempotency-key squat row (GH #2597)"

  @moduledoc """
  GH #2597: removes the single flagged `event_idempotency` row for an exact key in one tenant,
  writing an `idempotency_squat.remediated` audit entry (see
  `Letflow.Idempotency.SquatRemediation`).

  ## Usage

      mix letflow.remediate_idempotency_squat <tenant_id> <exact key> <operator>

  Confirm the finding by hand first (runbook). Refuses a key the audit does not flag. Exits
  non-zero on any refusal or error; `already_clear` is success.
  """

  use Mix.Task

  alias Letflow.Release.IdempotencySquats

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run([tenant_id, key, operator]) do
    Mix.Task.run("app.start")

    result = IdempotencySquats.remediate(tenant_id, key, operator)

    case IdempotencySquats.remediate_exit_code(result) do
      0 -> :ok
      code -> System.halt(code)
    end
  end

  def run(_args) do
    Mix.raise("usage: mix letflow.remediate_idempotency_squat <tenant_id> <exact key> <operator>")
  end
end
