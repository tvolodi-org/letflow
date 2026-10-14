defmodule Letflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # GH 2534 PR 7c-1 SECURITY note (design gh2534-7c-script-handler.md 5.1): every 7b/7c
    # script test seam is honoured only while :scripts_test_hooks is true, so a :prod node
    # refuses to start with it set (fixed text, no value echoed).
    case Letflow.Scripts.Runtime.boot_check(
           Application.get_env(:letflow, :config_env),
           Application.get_env(:letflow, :scripts_test_hooks, false)
         ) do
      :ok ->
        :ok

      {:error, :scripts_test_hooks_in_prod} ->
        raise "config :letflow, :scripts_test_hooks is true in :prod: refusing to start " <>
                "(it enables test-only script seams)."
    end

    # REQ-190 (design req190-secrets-core.md §6.2): redacts every log
    # event's metadata map via Letflow.Secrets.Redaction.redact_map/1
    # before it reaches any handler. Registered first, ahead of every
    # other child, so nothing below this line can log an unredacted
    # secret-shaped value before the filter is active. Idempotent-safe:
    # :logger.add_primary_filter/2 raises on a duplicate filter id, which
    # would only happen on a second Letflow.Application.start/2 call in
    # the same node -- not expected in normal operation (a release/test run
    # starts the application exactly once per node).
    :logger.add_primary_filter(
      :letflow_secrets_redaction,
      {&Letflow.Secrets.LogFilter.filter/2, %{}}
    )

    # REQ-219 (design req219-supervision-layering.md §2): the flat 20-child
    # list this module used to build directly is now layered into three
    # sibling supervisors -- Letflow.Supervisor.Infrastructure,
    # Letflow.Supervisor.Pollers, Letflow.Supervisor.Http -- each owning a
    # disjoint slice of the original 20 children (see each module's own
    # moduledoc for its exact children list and ordering guarantees).
    # Infrastructure MUST be listed before Pollers: Supervisor starts
    # children strictly in list order, one child's start_link/1 completing
    # before the next begins, so listing Infrastructure first is what makes
    # ISS-0429's "Obs.Alerts.TaskSupervisor registered before either
    # Poller's first tick" guarantee structural (a supervisor-boundary
    # guarantee, not merely a list-position fact) -- see
    # Letflow.Supervisor.Infrastructure's own moduledoc. :one_for_one here
    # (not :rest_for_one) is deliberate: every named-process infra child is
    # looked up BY NAME at its call sites, never by stored pid, so a rare
    # Infrastructure exit has no pid-based dependency reason to also
    # force-restart Pollers or Http; a Pollers crash-loop exhausting its own
    # restart intensity (Letflow.Supervisor.Pollers' own moduledoc) now
    # kills and restarts ONLY that one layer.
    #
    # ISS-0451 (design iss0451-poller-crash-budget-isolation.md §3.4a/§4):
    # Pollers' own child spec is `restart: :temporary` -- the top-level
    # Letflow.Supervisor structurally NEVER auto-restarts
    # Letflow.Supervisor.Pollers, for any exit, ever. This closes a
    # PERSISTENT (never-clearing) Poller fault's path to exhausting THIS
    # supervisor's own restart budget: without it, Pollers re-exhausts its
    # own 5/60 budget in ~24-30ms per cycle (measured), which cascades to
    # exhaust the top level's budget too and takes the whole application
    # down in well under a second. Letflow.Supervisor.PollersBreaker (added
    # below, right after Pollers) becomes the SOLE process that ever
    # restarts Pollers, via Supervisor.start_child/2 -- see that module's
    # own moduledoc for the full state machine. The children-list entry
    # below MUST use the 2-arg Supervisor.child_spec/2 call form (not a
    # bare {module, arg} 2-tuple, which Supervisor.init/2 normalizes as
    # "call module.child_spec(arg)" -- threading arg into start_link, not
    # into child-spec overrides -- and would silently NOT apply
    # `:temporary`; live-verified during this design's own rework, see the
    # design doc §3.4a).
    children = [
      Letflow.Supervisor.Infrastructure,
      # ISS-0993 (design iss0993-platform-scope-separation.md section 3): one-shot,
      # non-fatal check that the configured platform tenant is registered. Listed
      # right after Infrastructure (which owns Letflow.Repo); a temporary Task, so
      # it never blocks boot and never counts against this supervisor's restart
      # budget. Letflow.PlatformTenant.check_registration/0 never raises.
      Supervisor.child_spec({Task, &Letflow.PlatformTenant.check_registration/0},
        id: :platform_tenant_registration_check,
        restart: :temporary
      ),
      Supervisor.child_spec(Letflow.Supervisor.Pollers, restart: :temporary),
      Letflow.Supervisor.PollersBreaker,
      Letflow.Supervisor.Http
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    #
    # ISS-0451: max_restarts raised from the OTP default (3) to 5;
    # max_seconds stays at the OTP default (5). Pollers-attributable
    # restarts now consume exactly ZERO of this budget (restart: :temporary
    # above), so this budget is available entirely to
    # Infrastructure/Http/PollersBreaker (all :permanent). The +2 is pure
    # extra headroom for an unrelated coincidence of transient restarts
    # among those three landing in the same rolling window -- not sized
    # against any Pollers-consumption figure, since there is none. A
    # genuinely crash-looping Infrastructure or Http child still exhausts
    # this only-slightly-larger budget in the same order of magnitude of
    # time the OTP default would have, preserving REQ-219 decision 3's own
    # "a fault severe enough that taking the app down is still correct"
    # property for those children.
    opts = [strategy: :one_for_one, max_restarts: 5, max_seconds: 5, name: Letflow.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
