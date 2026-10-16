defmodule Mix.Tasks.Letflow.AuditIdempotencySquats do
  @shortdoc "Read-only audit of pre-#2550 idempotency-key squats (GH #2597)"

  @moduledoc """
  GH #2597: lists `event_idempotency` rows that look like pre-#2550 squats, per tenant.
  Strictly read-only (see `Letflow.Idempotency.SquatAudit`).

  ## Usage

      mix letflow.audit_idempotency_squats

  No arguments. Prints one `FLAG` line per flagged row and one `FINDING` line per report-only row, a `TENANT` line per tenant and a `SUMMARY`
  line. Exits non-zero if any tenant could not be audited (not merely because flags exist).
  On a release use `bin/letflow rpc` instead; see `docs/runbooks/idempotency-key-squat-audit.md`.
  """

  use Mix.Task

  alias Letflow.Release.IdempotencySquats

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")

    case IdempotencySquats.audit() |> IdempotencySquats.audit_exit_code() do
      0 -> :ok
      code -> System.halt(code)
    end
  end
end
